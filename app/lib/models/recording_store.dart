import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session.dart';

/// One thing someone said while a recording was running.
class RecordingUtterance {
  RecordingUtterance({required this.at, required this.text});

  final DateTime at;
  final String text;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'text': text,
      };

  factory RecordingUtterance.fromJson(Map<String, dynamic> json) =>
      RecordingUtterance(
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        text: json['text'] as String? ?? '',
      );
}

/// A captured stretch of conversation — a meeting, a call, a day.
class Recording {
  Recording({
    required this.id,
    required this.startedAt,
    this.label,
    DateTime? endedAt,
    List<RecordingUtterance>? utterances,
    this.title,
    this.summary,
  })  : endedAt = endedAt ?? startedAt,
        utterances = utterances ?? [];

  final String id;
  final String? label;
  final DateTime startedAt;
  DateTime endedAt;
  final List<RecordingUtterance> utterances;

  /// Filled in after the fact by the summariser. Null until it comes back, and
  /// permanently null if it never does — nothing depends on it existing.
  String? title;
  String? summary;

  bool get isEmpty => utterances.isEmpty;

  String get transcript => utterances.map((u) => u.text).join('\n');

  Map<String, dynamic> toJson() => {
        'id': id,
        if (label != null) 'label': label,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'utterances': utterances.map((u) => u.toJson()).toList(),
        if (title != null) 'title': title,
        if (summary != null) 'summary': summary,
      };

  factory Recording.fromJson(Map<String, dynamic> json) => Recording(
        id: json['id'] as String? ?? '0',
        label: json['label'] as String?,
        startedAt:
            DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
        endedAt: DateTime.tryParse(json['endedAt'] as String? ?? ''),
        utterances: (json['utterances'] as List<dynamic>? ?? [])
            .map((e) => RecordingUtterance.fromJson(e as Map<String, dynamic>))
            .toList(),
        title: json['title'] as String?,
        summary: json['summary'] as String?,
      );
}

/// Transcripts Ordi was explicitly asked to capture.
///
/// This is a second consumer of the same per-turn transcripts that build the
/// conversation history, not a second microphone. Nothing here touches audio:
/// the Live session already transcribes the user's speech, so "recording" is
/// only a question of keeping what is normally thrown away when Ordi doesn't
/// answer. That is why it costs nothing extra to run and why it stops dead
/// when the session does.
class RecordingStore extends ChangeNotifier {
  static const _prefsKey = 'recordings_v1';

  /// A long meeting is tens of thousands of characters and every write
  /// rewrites the whole preferences plist, so recordings are bounded at both
  /// ends: this much text per recording, that many recordings kept.
  static const _maxCharsPerRecording = 24000;
  static const _maxRecordings = 20;

  /// Hard stop for a runaway "record my day". The session is billed for as
  /// long as it is open, and a recording nobody remembered to stop is the
  /// expensive failure mode here.
  static const maxDuration = Duration(hours: 3);

  /// Written every few seconds at meeting pace, which is far too often for a
  /// whole-file rewrite. Coalesced instead, and always flushed on stop.
  static const _persistDebounce = Duration(seconds: 10);

  final List<Recording> _recordings = [];
  Recording? _active;
  Timer? _persistTimer;
  Timer? _autoStop;

  /// Most recent first.
  List<Recording> get recordings => List.unmodifiable(_recordings.reversed);

  bool get isRecording => _active != null;
  Recording? get active => _active;
  String? get activeLabel => _active?.label;

  /// Fires when a recording stops on its own rather than by request, so the
  /// app can tell the user instead of silently having stopped.
  void Function(Recording recording)? onAutoStopped;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as List<dynamic>;
    _recordings
      ..clear()
      ..addAll(
        decoded.map((e) => Recording.fromJson(e as Map<String, dynamic>)),
      );
    notifyListeners();
  }

  /// Begins capturing. Starting while already recording keeps the current one
  /// rather than silently discarding what has been captured so far.
  Recording start({String? label}) {
    final current = _active;
    if (current != null) return current;

    final now = DateTime.now();
    final recording = Recording(
      id: now.millisecondsSinceEpoch.toString(),
      startedAt: now,
      label: (label != null && label.trim().isNotEmpty) ? label.trim() : null,
    );
    _recordings.add(recording);
    while (_recordings.length > _maxRecordings) {
      _recordings.removeAt(0);
    }
    _active = recording;

    _autoStop?.cancel();
    _autoStop = Timer(maxDuration, () {
      final stopped = stop();
      if (stopped != null) onAutoStopped?.call(stopped);
    });

    notifyListeners();
    _schedulePersist();
    return recording;
  }

  /// Ends the running recording and kicks off summarisation in the background.
  /// Returns null if nothing was running.
  Recording? stop() {
    final recording = _active;
    if (recording == null) return null;

    _active = null;
    _autoStop?.cancel();
    _autoStop = null;
    recording.endedAt = DateTime.now();

    notifyListeners();
    _flush();
    _summarise(recording);
    return recording;
  }

  /// Called for every finished turn. Only the person's own words are kept —
  /// Ordi is supposed to be silent while recording, and its occasional
  /// interjection is not part of the meeting.
  void observe(String question, String answer) {
    final recording = _active;
    if (recording == null) return;
    final text = question.trim();
    if (text.isEmpty) return;

    recording.utterances.add(RecordingUtterance(at: DateTime.now(), text: text));
    recording.endedAt = DateTime.now();
    _trim(recording);
    notifyListeners();
    _schedulePersist();
  }

  /// Drops the oldest utterances once a recording outgrows its budget. The
  /// tail is what a summary and a recall question both actually want.
  void _trim(Recording recording) {
    var total = 0;
    for (final utterance in recording.utterances) {
      total += utterance.text.length;
    }
    while (total > _maxCharsPerRecording && recording.utterances.length > 1) {
      total -= recording.utterances.removeAt(0).text.length;
    }
  }

  /// Finds what the user meant by "my last conversation" or a label they used.
  Recording? find(String which) {
    if (_recordings.isEmpty) return null;
    final needle = which.trim().toLowerCase();

    if (needle.isEmpty ||
        needle.contains('last') ||
        needle.contains('recent') ||
        needle.contains('previous')) {
      return _mostRecentFinished();
    }

    for (final recording in _recordings.reversed) {
      final label = recording.label?.toLowerCase();
      final title = recording.title?.toLowerCase();
      if ((label != null && (label.contains(needle) || needle.contains(label))) ||
          (title != null && title.contains(needle))) {
        return recording;
      }
    }
    return _mostRecentFinished();
  }

  Recording? _mostRecentFinished() {
    for (final recording in _recordings.reversed) {
      if (!identical(recording, _active)) return recording;
    }
    return null;
  }

  /// Summarise in the background. Nothing waits on this — a recording without
  /// a summary still has its full transcript, which is the part that matters.
  void _summarise(Recording recording) {
    if (recording.isEmpty) return;
    () async {
      final full = recording.transcript;
      final clipped = full.length > 6000 ? full.substring(full.length - 6000) : full;
      final insights = await OrdiBackend.requestSessionInsights(clipped);
      if (insights == null) return;
      recording.title = insights.title;
      recording.summary = insights.summary;
      notifyListeners();
      _flush();
      if (insights.tasks.isNotEmpty) onTasksExtracted?.call(insights.tasks);
    }();
  }

  /// Wired to the AI Brief, the same way `ConversationLog` is — a meeting that
  /// produced action items is the obvious reason to have recorded it.
  void Function(List<String> tasks)? onTasksExtracted;

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _flush);
  }

  /// Forces a write. Called on stop and when the app goes to the background,
  /// where a pending debounce would otherwise be lost.
  Future<void> flush() => _flush();

  Future<void> _flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_recordings.map((r) => r.toJson()).toList()),
    );
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _autoStop?.cancel();
    super.dispose();
  }
}
