import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session.dart';

/// One finished exchange with Ordi — a question and its complete answer.
class ConversationEntry {
  const ConversationEntry({
    required this.at,
    required this.question,
    required this.answer,
  });

  final DateTime at;
  final String question;
  final String answer;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'question': question,
        'answer': answer,
      };

  factory ConversationEntry.fromJson(Map<String, dynamic> json) =>
      ConversationEntry(
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        question: json['question'] as String? ?? '',
        answer: json['answer'] as String? ?? '',
      );
}

/// One sitting — exchanges close enough together in time to be the same
/// conversation, per [ConversationLog.sessionGap]. [title] and [summary] are
/// null until the backend has actually summarised it; a session that hasn't
/// been finalised yet (still ongoing, or waiting its turn) just shows without
/// them rather than blocking on the call.
class ConversationSession {
  ConversationSession({
    required this.id,
    required DateTime startedAt,
  })  : startedAt = startedAt,
        endedAt = startedAt,
        entries = [];

  final String id;
  DateTime startedAt;
  DateTime endedAt;
  final List<ConversationEntry> entries;
  String? title;
  String? summary;

  /// What to call this session before (or if never) a summary comes back:
  /// the first thing actually asked, cut to one line — something to recognise
  /// it by, where "12 exchanges" said nothing at all.
  String get displayTitle {
    final given = title;
    if (given != null && given.trim().isNotEmpty) return given;
    for (final entry in entries) {
      final q = entry.question.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (q.isEmpty) continue;
      final line = q[0].toUpperCase() + q.substring(1);
      return line.length <= 60 ? line : '${line.substring(0, 57).trimRight()}…';
    }
    return entries.length == 1 ? '1 exchange' : '${entries.length} exchanges';
  }

  String get countLabel =>
      entries.length == 1 ? '1 exchange' : '${entries.length} exchanges';

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'title': title,
        'summary': summary,
      };

  factory ConversationSession.fromJson(Map<String, dynamic> json) {
    final startedAt =
        DateTime.tryParse(json['startedAt'] as String? ?? '') ??
            DateTime.now();
    final session = ConversationSession(
      id: json['id'] as String? ?? startedAt.millisecondsSinceEpoch.toString(),
      startedAt: startedAt,
    );
    session.endedAt =
        DateTime.tryParse(json['endedAt'] as String? ?? '') ?? startedAt;
    session.title = json['title'] as String?;
    session.summary = json['summary'] as String?;
    final rawEntries = json['entries'] as List<dynamic>? ?? const [];
    session.entries.addAll(
      rawEntries.map((e) => ConversationEntry.fromJson(e as Map<String, dynamic>)),
    );
    return session;
  }
}

/// What Ordi remembers of past conversations.
///
/// Exchanges close together in time are grouped into a [ConversationSession]
/// rather than kept as one flat list — a session is what the History screen
/// actually shows a title and summary for, with the individual exchanges one
/// level down. The same underlying data also drives [recentDigest], which
/// becomes a few sentences of context folded into a *new* session's system
/// instruction — that's the actual mechanism behind Ordi being able to answer
/// "what did we talk about yesterday evening": the exchange is right there in
/// its instructions when the session opens, not retrieved live mid-
/// conversation.
///
/// This is a recency digest, not real retrieval — there is no search over old
/// conversations, no relevance ranking, nothing that scales past a few dozen
/// recent exchanges. That matches what a personal voice assistant with one
/// user actually needs; a proper memory/RAG system would be solving a problem
/// this app doesn't have yet.
class ConversationLog extends ChangeNotifier {
  static const _prefsKey = 'conversation_sessions_v1';

  /// Exchanges more than this far apart start a new session. Five minutes is
  /// long enough that a pause mid-conversation doesn't fracture it, short
  /// enough that a session — and with it, anything extracted from it — shows
  /// up at a pace that still feels like the app is doing something, not like
  /// nothing happened.
  static const sessionGap = Duration(minutes: 5);

  /// Bounds how much this ever grows to — old sessions are dropped past this,
  /// oldest first. A personal assistant's conversation history is small text;
  /// this is generous headroom, not a real limit anyone should hit soon.
  static const _maxSessions = 200;

  /// Armed for exactly the moment the current session would go idle, rather
  /// than polling on a fixed interval — this does no work at all between
  /// exchanges and fires the instant the gap actually elapses instead of up
  /// to a poll-interval late. Cancelled and re-armed on every [add].
  Timer? _pendingFinalize;

  final List<ConversationSession> _sessions = [];

  /// Most recent first — the natural reading order for a history screen.
  List<ConversationSession> get sessions =>
      List.unmodifiable(_sessions.reversed);

  /// Fires with whatever tasks a just-finalised session turned up. Set from
  /// outside (main.dart wires it to the AI Brief) — this log only reports
  /// what it found, it doesn't decide what happens to it.
  void Function(List<String> tasks)? onTasksExtracted;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw) as List<dynamic>;
    _sessions
      ..clear()
      ..addAll(
        decoded.map(
            (e) => ConversationSession.fromJson(e as Map<String, dynamic>)),
      );
    notifyListeners();
    // Timers don't survive the app being closed — if the last session was
    // already stale when this loaded (closed mid-gap, reopened later), this
    // is what finalises it instead of waiting for a follow-up that already
    // should have counted as a new session.
    finalizeIfIdle();
    retryMissingTitles();
    _armAutoFinalize();
  }

  void add(String question, String answer) {
    if (question.trim().isEmpty || answer.trim().isEmpty) return;
    final now = DateTime.now();
    final entry = ConversationEntry(at: now, question: question, answer: answer);

    final current = _sessions.isEmpty ? null : _sessions.last;
    if (current != null && now.difference(current.endedAt) <= sessionGap) {
      current.entries.add(entry);
      current.endedAt = now;
    } else {
      // The previous session, if there was one, just became definitively
      // finished — this is what lets it get a title without anyone having to
      // open History for it.
      _finalize(current);
      final session = ConversationSession(
        id: now.millisecondsSinceEpoch.toString(),
        startedAt: now,
      )..entries.add(entry);
      _sessions.add(session);
      while (_sessions.length > _maxSessions) {
        _sessions.removeAt(0);
      }
    }
    notifyListeners();
    _persist();
    _armAutoFinalize();
  }

  /// Catches the current session going quiet without anything ever starting
  /// a new one to close it. [_armAutoFinalize] is what normally calls this
  /// at the right moment on its own; it's also called directly from
  /// `_openHistory` and from [load], so opening History or relaunching the
  /// app still catches a session that's already overdue.
  void finalizeIfIdle() {
    if (_sessions.isEmpty) return;
    final last = _sessions.last;
    if (last.title != null) return;
    if (DateTime.now().difference(last.endedAt) < sessionGap) return;
    _finalize(last);
  }

  /// Schedules [finalizeIfIdle] for exactly when the current session would
  /// next go idle. Safe to call unconditionally — it no-ops once the session
  /// is already finalised, and each call replaces whatever was armed before,
  /// so extending a session by talking again simply pushes the deadline out
  /// rather than leaving a stale timer that fires too early.
  void _armAutoFinalize() {
    _pendingFinalize?.cancel();
    if (_sessions.isEmpty) return;
    final last = _sessions.last;
    if (last.title != null) return;
    final dueIn = sessionGap - DateTime.now().difference(last.endedAt);
    _pendingFinalize =
        Timer(dueIn.isNegative ? Duration.zero : dueIn, finalizeIfIdle);
  }

  /// Fire-and-forget by design — this is background enrichment, not
  /// something anything is waiting on. A session with no title just doesn't
  /// have one yet; nothing about the app depends on it succeeding.
  /// Session ids with a summary request on the way, so a retry never doubles
  /// up on one already in flight.
  final Set<String> _finalizing = {};

  void _finalize(ConversationSession? session) {
    if (session == null || session.title != null) return;
    if (!_finalizing.add(session.id)) return;
    () async {
      try {
        final transcript = session.entries
            .map((e) => 'User: ${e.question}\nOrdi: ${e.answer}')
            .join('\n\n');
        final insights = await OrdiBackend.requestSessionInsights(transcript);
        if (insights == null) return;
        session.title = insights.title;
        session.summary = insights.summary;
        notifyListeners();
        _persist();
        if (insights.tasks.isNotEmpty) onTasksExtracted?.call(insights.tasks);
      } finally {
        _finalizing.remove(session.id);
      }
    }();
  }

  /// Deletes one session and everything said in it.
  void remove(ConversationSession session) {
    if (!_sessions.remove(session)) return;
    notifyListeners();
    _persist();
  }

  /// Asks again for every finished session still without a title.
  ///
  /// A failed summary used to be final: the request went out once, and if the
  /// model was busy that session showed "12 exchanges" for good. Called at
  /// launch and whenever History is opened. The session still in progress is
  /// left alone — it is summarised when it ends.
  void retryMissingTitles() {
    final now = DateTime.now();
    for (final session in List.of(_sessions)) {
      if (session.title != null) continue;
      final ongoing = identical(session, _sessions.last) &&
          now.difference(session.endedAt) < sessionGap;
      if (!ongoing) _finalize(session);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_sessions.map((s) => s.toJson()).toList()),
    );
  }

  @override
  void dispose() {
    _pendingFinalize?.cancel();
    super.dispose();
  }

  /// A short, plain-text summary of the last [maxEntries] exchanges across
  /// all sessions, each truncated so a handful of long answers can't blow out
  /// the digest (and with it, the size — and cost — of every new session's
  /// opening prompt).
  ///
  /// Returns '' when there is nothing yet, which the backend treats as "send
  /// no memory at all" rather than an empty section in the prompt.
  String recentDigest({int maxEntries = 6, int maxCharsPerField = 160}) {
    final all = _sessions.expand((s) => s.entries).toList();
    if (all.isEmpty) return '';
    final recent = all.reversed.take(maxEntries).toList().reversed;
    final lines = recent.map((entry) {
      final when = _describe(entry.at);
      final q = _truncate(entry.question, maxCharsPerField);
      final a = _truncate(entry.answer, maxCharsPerField);
      return '$when, they asked: "$q" — you answered: "$a".';
    });
    return lines.join(' ');
  }

  String _truncate(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) return trimmed;
    return '${trimmed.substring(0, maxChars).trimRight()}…';
  }

  /// "Yesterday evening", "this morning", "on Tuesday afternoon" — coarse on
  /// purpose. This is what lets Ordi answer in the same loose terms a person
  /// would use asking about it, rather than a bare timestamp it would have to
  /// translate itself.
  String _describe(DateTime at) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfThat = DateTime(at.year, at.month, at.day);
    final dayDiff = startOfToday.difference(startOfThat).inDays;

    final partOfDay = switch (at.hour) {
      >= 5 && < 12 => 'morning',
      >= 12 && < 17 => 'afternoon',
      >= 17 && < 21 => 'evening',
      _ => 'night',
    };

    return switch (dayDiff) {
      0 => 'earlier today ($partOfDay)',
      1 => 'yesterday $partOfDay',
      _ when dayDiff < 7 => '${_weekday(at.weekday)} $partOfDay',
      _ => 'on ${at.year}-${at.month.toString().padLeft(2, '0')}-'
          '${at.day.toString().padLeft(2, '0')}',
    };
  }

  String _weekday(int weekday) => const [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ][weekday - 1];
}
