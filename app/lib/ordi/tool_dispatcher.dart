import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:ordi_audio/ordi_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ai_brief.dart';
import '../models/recording_store.dart';
import '../models/reminder_scheduler.dart';
import '../models/speed_dial.dart';
import '../ui/time_format.dart';

/// Runs the things Ordi decides to do mid-conversation.
///
/// Every handler here is on a clock. Function calling on the Live model is
/// synchronous: from the moment the model issues a call until it is answered,
/// it generates nothing at all — no speech, no acknowledgement, nothing. So a
/// handler that waits on the network stalls the conversation for as long as
/// the network takes, and a handler that throws would stall it forever if
/// native weren't backstopping with a timeout. Anything slow is started and
/// left running; the model is answered immediately with what is already known.
class ToolDispatcher {
  ToolDispatcher({
    required this.brief,
    required this.recordings,
    required this.speedDial,
    required this.reminders,
    this.openStudyMode,
  }) {
    // A "tap to call" notification brings the app forward and lands here.
    reminders.onCallTapped = _launchTel;
  }

  final AiBrief brief;
  final RecordingStore recordings;
  final SpeedDial speedDial;
  final ReminderScheduler reminders;

  /// Opens study mode (or explains why it can't): whether it opened, and the
  /// sentence to say.
  final ({bool opened, String say}) Function()? openStudyMode;

  void attach() => OrdiAudio.onToolCall(handle);

  Future<Map<String, Object?>> handle(
    String name,
    Map<String, Object?> args,
  ) async {
    try {
      return switch (name) {
        // Ordi saying nothing is the whole of the answer.
        'stay_silent' => const {'result': 'ok'},
        'create_reminder' => await _createReminder(args),
        'update_reminder' => await _updateReminder(args),
        'cancel_reminder' => await _cancelReminder(args),
        'start_recording' => await _startRecording(args),
        'stop_recording' => await _stopRecording(),
        'recall_recording' => _recallRecording(args),
        'call_contact' => await _callContact(args),
        'list_reminders' => _listReminders(args),
        'cancel_all_reminders' => _cancelAllReminders(args),
        'list_recordings' => _listRecordings(),
        'delete_recording' => _deleteRecording(args),
        'list_contacts' => _listContacts(),
        'open_study_mode' => _studyMode(),
        _ => {'error': 'Unknown tool $name.'},
      };
    } catch (error) {
      // Never let this escape. An exception here becomes a FlutterError on the
      // native side, which turns into a useless error string for the model —
      // a plain sentence it can actually say is better.
      return {'error': 'That did not work: $error'};
    }
  }

  // MARK: - Reminders

  /// Works out when a reminder is for, from whichever fields the model used.
  ///
  /// Current servers pass `in_minutes` for anything relative to now, or a local
  /// `date` and `time` — separate fields with no room for a time zone, so the
  /// only reading is the person's own clock. Older servers pass one ISO `at`
  /// stamp, handled by [_fromStamp].
  ///
  /// [sameDayAs] is the reminder being moved, if any: "make that 3 pm" with no
  /// date keeps it on its own day rather than jumping it to today.
  static DateTime? _dueFrom(Map<String, Object?> args, {DateTime? sameDayAs}) {
    final minutes = args['in_minutes'];
    if (minutes is num && minutes > 0) {
      return DateTime.now().add(Duration(seconds: (minutes * 60).round()));
    }

    final time = (args['time'] as String? ?? '').trim();
    final tm = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(time);
    if (tm != null) {
      final now = DateTime.now();
      final hour = int.parse(tm.group(1)!);
      final minute = int.parse(tm.group(2)!);
      final date = (args['date'] as String? ?? '').trim();
      final dm = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(date);
      if (dm != null) {
        return DateTime(int.parse(dm.group(1)!), int.parse(dm.group(2)!),
            int.parse(dm.group(3)!), hour, minute);
      }
      // No date: the reminder's own day when moving one, otherwise today —
      // then the next day if that time has already gone by.
      final day = sameDayAs ?? now;
      var due = DateTime(day.year, day.month, day.day, hour, minute);
      if (!due.isAfter(now)) due = due.add(const Duration(days: 1));
      return due;
    }

    return _fromStamp(args['at']);
  }

  /// Reads an ISO stamp from an older server.
  ///
  /// The model filled in the zone inconsistently: the right offset, none, a
  /// "Z" slapped on a local time, or a genuine conversion to UTC. With no zone,
  /// or with the phone's own offset, it is simply local. With any other zone
  /// both readings are tried — the stamp taken literally, and its digits taken
  /// as local — and a reading that lands in the past loses to one that lands in
  /// the future. That is the case that went wrong in practice: a reminder "in
  /// two minutes" at 11:48 PM in India came back as 18:19Z, and read as local
  /// that is 6:19 PM, already gone.
  static DateTime? _fromStamp(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final zone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').firstMatch(text);
    final wall = DateTime.tryParse(
        zone == null ? text : text.substring(0, zone.start));
    if (wall == null || zone == null) return wall;

    final literal = DateTime.tryParse(text)?.toLocal();
    if (literal == null) return wall;
    final now = DateTime.now().subtract(const Duration(minutes: 1));
    if (literal.isAtSameMomentAs(wall)) return wall;
    final wallFuture = wall.isAfter(now);
    final literalFuture = literal.isAfter(now);
    if (literalFuture && !wallFuture) return literal;
    if (wallFuture && !literalFuture) return wall;
    // Both plausible: the stamp says what it says.
    return literal;
  }

  Future<Map<String, Object?>> _createReminder(Map<String, Object?> args) async {
    final title = (args['title'] as String? ?? '').trim();
    if (title.isEmpty) return {'error': 'No reminder text was given.'};

    final due = _dueFrom(args);
    final existing = brief.find(title);
    final alreadyThere = existing != null &&
        existing.title.toLowerCase() == title.toLowerCase();

    final task = brief.add(title, at: due);

    if (due == null) {
      return {'result': 'Added "$title" to their list, with no time set.'};
    }
    if (!due.isAfter(DateTime.now())) {
      return {
        'result':
            'Added "$title", but the time given was in the past so nothing '
                'will fire. Ask them when they want it.',
      };
    }

    // `add` has already moved an existing reminder of the same name; this is
    // only about telling the model what really happened.
    unawaited(reminders.schedule(task));
    return {
      'result': alreadyThere
          ? 'That reminder already existed, so it was moved to ${dueLabel(due)}.'
          : 'Reminder set for ${dueLabel(due)}.',
    };
  }

  Future<Map<String, Object?>> _updateReminder(Map<String, Object?> args) async {
    final target = brief.find(args['title'] as String? ?? '');
    final due = _dueFrom(args, sameDayAs: target?.dueAt);
    if (due == null) {
      return {
        'error': 'No new time was given, so NOTHING was changed. Do not say '
            'it was. Ask them what time they want.',
      };
    }
    if (!due.isAfter(DateTime.now())) {
      return {
        'error': 'That time (${dueLabel(due)}) is already in the past, so '
            'NOTHING was changed. Do not say it was. Ask them when they want it.',
      };
    }
    final task = target;
    if (task == null) {
      return {
        'error': 'There is no reminder matching that, so NOTHING was moved. '
            'Do not say it was. Tell them, and offer to set a new one.',
      };
    }
    brief.reschedule(task, due);
    unawaited(reminders.schedule(task));
    return {'result': 'Moved "${task.title}" to ${dueLabel(due)}.'};
  }

  Future<Map<String, Object?>> _cancelReminder(Map<String, Object?> args) async {
    final task = brief.find(args['title'] as String? ?? '');
    if (task == null) {
      return {
        'error': 'There is no reminder matching that, so nothing was removed. '
            'Tell them.',
      };
    }
    brief.remove(task);
    unawaited(reminders.cancel(task.id));
    return {'result': 'Cancelled "${task.title}".'};
  }

  // MARK: - Study mode

  /// The sentence and the fact kept apart, so the model has nothing to read
  /// out but the sentence — given one string holding both, it once said the
  /// instruction aloud.
  Map<String, Object?> _studyMode() {
    final r = openStudyMode?.call() ??
        (opened: false, say: 'Study mode is not available right now.');
    return {'opened': r.opened, 'say_this': r.say};
  }

  // MARK: - Reading and bulk changes

  static bool _isToday(DateTime t) {
    final now = DateTime.now();
    return t.year == now.year && t.month == now.month && t.day == now.day;
  }

  /// Everything on the list, not just the last one — the model was answering
  /// "what are my reminders today" with only the reminder it had just set,
  /// because that was all it remembered. It now reads the list itself.
  Map<String, Object?> _listReminders(Map<String, Object?> args) {
    final scope = (args['scope'] as String? ?? 'all').toLowerCase();
    final now = DateTime.now();
    final open = brief.tasks.where((t) => !t.done).toList();
    final picked = switch (scope) {
      'today' => open.where((t) => t.dueAt != null && _isToday(t.dueAt!)),
      'upcoming' => open.where((t) => t.dueAt != null && t.dueAt!.isAfter(now)),
      _ => open,
    }
        .toList()
      ..sort((a, b) {
        if (a.dueAt == null) return b.dueAt == null ? 0 : 1;
        if (b.dueAt == null) return -1;
        return a.dueAt!.compareTo(b.dueAt!);
      });
    if (picked.isEmpty) {
      return {
        'result': scope == 'today'
            ? 'Nothing is set for today.'
            : 'There are no reminders or tasks on the list.',
      };
    }
    final lines = picked
        .map((t) => t.dueAt == null
            ? '${t.title} (no time)'
            : '${t.title} — ${dueLabel(t.dueAt!)}')
        .join('; ');
    return {'result': '${picked.length} in total: $lines.'};
  }

  Map<String, Object?> _cancelAllReminders(Map<String, Object?> args) {
    final scope = (args['scope'] as String? ?? 'all').toLowerCase();
    final targets = brief.tasks
        .where((t) =>
            scope != 'today' || (t.dueAt != null && _isToday(t.dueAt!)))
        .toList();
    if (targets.isEmpty) {
      return {'result': 'There was nothing to delete, so nothing changed.'};
    }
    for (final task in targets) {
      brief.remove(task);
      unawaited(reminders.cancel(task.id));
    }
    return {
      'result': 'Deleted ${targets.length} '
          '${targets.length == 1 ? 'reminder' : 'reminders'}'
          '${scope == 'today' ? ' for today' : ''}.',
    };
  }

  Map<String, Object?> _listRecordings() {
    final all = recordings.recordings.reversed.toList();
    if (all.isEmpty) return {'result': 'There are no recordings yet.'};
    final lines = all.take(10).map((r) {
      final name = r.title ?? r.label ?? 'Untitled recording';
      final live = identical(r, recordings.active) ? ' (recording now)' : '';
      return '$name, ${dayTimeLabel(r.startedAt)}$live';
    }).join('; ');
    return {
      'result': '${all.length} '
          '${all.length == 1 ? 'recording' : 'recordings'}, newest first: $lines.',
    };
  }

  Map<String, Object?> _deleteRecording(Map<String, Object?> args) {
    final which = (args['which'] as String? ?? '').trim().toLowerCase();
    if (which == 'all' || which == 'everything') {
      final all = List.of(recordings.recordings);
      if (all.isEmpty) return {'result': 'There were no recordings to delete.'};
      for (final r in all) {
        recordings.remove(r);
      }
      return {'result': 'Deleted all ${all.length} recordings.'};
    }
    final target = recordings.find(which.isEmpty ? 'last' : which);
    if (target == null) {
      return {'error': 'No recording matches that, so NOTHING was deleted.'};
    }
    recordings.remove(target);
    return {
      'result': 'Deleted "${target.title ?? target.label ?? 'the recording'}".',
    };
  }

  Map<String, Object?> _listContacts() {
    final contacts = speedDial.contacts;
    if (contacts.isEmpty) {
      return {
        'result': 'Speed dial is empty. They can add people on the home screen.',
      };
    }
    return {
      'result': 'On speed dial: ${contacts.map((c) => c.name).join(', ')}.',
    };
  }

  // MARK: - Recording

  Future<Map<String, Object?>> _startRecording(Map<String, Object?> args) async {
    if (recordings.isRecording) {
      return {'result': 'Already recording — nothing changed.'};
    }
    recordings.start(label: args['label'] as String?);
    // Recording runs in the background and changes nothing about Ordi: it
    // keeps answering whenever it is addressed. One firm tap so the person
    // feels it start.
    unawaited(HapticFeedback.mediumImpact());
    return {
      'result': 'Recording started. Confirm it in one short sentence, then '
          'carry on exactly as usual.',
    };
  }

  Future<Map<String, Object?>> _stopRecording() async {
    final recording = recordings.stop();

    if (recording == null) return {'result': 'Nothing was being recorded.'};
    if (recording.isEmpty) {
      return {'result': 'Stopped. Nothing was picked up, so there is no summary.'};
    }

    // Summarising is a network round-trip and the conversation is frozen until
    // this returns, so it is left running in the background and the model is
    // given the raw tail to talk from now. The summary lands in the app, and
    // recall_recording will have it by the time anyone asks again.
    final utterances = recording.utterances;
    final tail = utterances
        .sublist(utterances.length > 12 ? utterances.length - 12 : 0)
        .map((u) => u.text)
        .join(' ');

    return {
      'result': 'Stopped after ${_spokenDuration(recording)}, '
          '${utterances.length} things said. '
          'Give them a two-sentence summary of this, and mention the full '
          'transcript is in the app: $tail',
    };
  }

  Map<String, Object?> _recallRecording(Map<String, Object?> args) {
    final recording = recordings.find(args['which'] as String? ?? 'last');
    if (recording == null) {
      return {'result': 'There are no recordings yet.'};
    }

    final when = dayTimeLabel(recording.startedAt);
    final summary = recording.summary;
    if (summary != null) {
      return {
        'result': '${recording.title ?? 'Recording'}, from $when. $summary',
      };
    }

    // Not summarised yet — either it just stopped or the call failed. The raw
    // tail is still perfectly usable, and better than making them wait.
    final utterances = recording.utterances;
    if (utterances.isEmpty) {
      return {'result': 'That recording from $when is empty.'};
    }
    final tail = utterances
        .sublist(utterances.length > 15 ? utterances.length - 15 : 0)
        .map((u) => u.text)
        .join(' ');
    return {
      'result': 'From $when, not summarised yet — here is what was said, '
          'summarise it for them: $tail',
    };
  }

  String _spokenDuration(Recording recording) {
    final minutes = recording.endedAt.difference(recording.startedAt).inMinutes;
    if (minutes < 1) return 'less than a minute';
    if (minutes == 1) return 'a minute';
    return '$minutes minutes';
  }

  // MARK: - Calling

  Future<Map<String, Object?>> _callContact(Map<String, Object?> args) async {
    final name = (args['name'] as String? ?? '').trim();
    if (name.isEmpty) return {'error': 'No name was given.'};

    final match = _matchSpeedDial(name) ?? await _matchAddressBook(name);
    if (match == null) {
      return {
        'result': 'No contact matching "$name" was found. Tell them that, and '
            'that they can add someone to speed dial on the home screen.',
      };
    }
    if (match.dialNumber.isEmpty) {
      return {
        'result': '${match.name} has no usable phone number saved. Tell them.',
      };
    }
    return _dial(match);
  }

  bool get _inForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Starts the call, and returns what to tell the model about how it went.
  ///
  /// iOS gives an app no way to place a cellular call by itself. The most it can
  /// do is open the dialler, and iOS then shows its own "Call …?" sheet that
  /// the person has to tap — for every app, with no exception. It also refuses
  /// to open the dialler at all for an app in the background, which is where
  /// Ordi normally is when someone says "call Charan" with the phone in a
  /// pocket; then a notification stands in, and tapping it does the opening.
  ///
  /// The launch happens *after* the answer is returned, never before: opening
  /// the dialler backgrounds the app immediately, and awaiting it would risk the
  /// tool response never being written — and an unanswered tool call is a
  /// conversation that never resumes.
  Future<Map<String, Object?>> _dial(SpeedDialContact contact) async {
    final number = contact.dialNumber;

    if (_inForeground) {
      scheduleMicrotask(() => _launchTel(number));
      return {
        'result': 'Opening the phone to call ${contact.name}. iOS will ask them '
            'to tap Call to confirm, once. Say so in one short sentence.',
      };
    }

    final shown = await reminders.showCallPrompt(contact.name, number);
    return shown
        ? {
            'result': 'The phone is in the background so a call cannot be started '
                'directly. A notification "Call ${contact.name}" has been shown; '
                'tell them to tap it.',
          }
        : {
            'result': 'The phone is in the background and notifications are off, '
                'so the call could not be started. Tell them to open the app and '
                'tap ${contact.name} on speed dial.',
          };
  }

  Future<void> _launchTel(String number) async {
    if (number.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$number'));
    } catch (_) {
      // The dialler either opens or there isn't one. Nothing to recover to.
    }
  }

  SpeedDialContact? _matchSpeedDial(String name) {
    final needle = _normalise(name);
    if (needle.isEmpty) return null;

    for (final contact in speedDial.contacts) {
      if (_normalise(contact.name) == needle) return contact;
    }
    for (final contact in speedDial.contacts) {
      final haystack = _normalise(contact.name);
      if (haystack.contains(needle) || needle.contains(haystack)) return contact;
    }
    // "Charan" should find "Sai Surya Charan", so try each word on its own.
    for (final contact in speedDial.contacts) {
      for (final word in _normalise(contact.name).split(' ')) {
        if (word.isNotEmpty && (word == needle || word.startsWith(needle))) {
          return contact;
        }
      }
    }
    return null;
  }

  /// Falls back to the full address book, which needs real contacts
  /// permission — unlike the system picker the dashboard uses. Asked for only
  /// when speed dial came up empty, so someone who never voice-dials an
  /// unsaved name is never prompted.
  Future<SpeedDialContact?> _matchAddressBook(String name) async {
    try {
      // `limited` is iOS 18's "share only some contacts" grant — still a yes,
      // it just means the list below is shorter than the whole address book.
      final status =
          await FlutterContacts.permissions.request(PermissionType.read);
      if (status != PermissionStatus.granted &&
          status != PermissionStatus.limited) {
        return null;
      }
      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.phone},
      );
      final needle = _normalise(name);

      for (final contact in contacts) {
        if (contact.phones.isEmpty) continue;
        final displayName = contact.displayName ?? '';
        final haystack = _normalise(displayName);
        final words = haystack.split(' ');
        final hit = haystack == needle ||
            haystack.contains(needle) ||
            words.any((w) => w.isNotEmpty && w.startsWith(needle));
        if (hit) {
          return SpeedDialContact(
            name: displayName,
            phone: contact.phones.first.number,
          );
        }
      }
    } on PlatformException {
      // Permission refused, or no contacts implementation. Either way there is
      // nothing to match against.
    } catch (_) {
      // Same.
    }
    return null;
  }

  String _normalise(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();
}
