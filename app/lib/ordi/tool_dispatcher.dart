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
    required this.setRecordingMode,
  }) {
    // Recording can end by voice, by the Stop control on the dashboard, or by
    // hitting its duration cap. Un-muting is keyed off the store rather than
    // off any one of those paths, so none of them can leave Ordi silenced.
    recordings.addListener(_onRecordingsChanged);
    // A "tap to call" notification brings the app forward and lands here.
    reminders.onCallTapped = _launchTel;
  }

  final AiBrief brief;
  final RecordingStore recordings;
  final SpeedDial speedDial;
  final ReminderScheduler reminders;

  /// Tells the engine to drop Ordi's audio instead of playing it. Belt and
  /// braces behind the prompt's own instruction to stay quiet while recording.
  final Future<void> Function(bool recording) setRecordingMode;

  void attach() => OrdiAudio.onToolCall(handle);

  Future<Map<String, Object?>> handle(
    String name,
    Map<String, Object?> args,
  ) async {
    try {
      return switch (name) {
        'stay_silent' => await _staySilent(),
        'create_reminder' => await _createReminder(args),
        'update_reminder' => await _updateReminder(args),
        'cancel_reminder' => await _cancelReminder(args),
        'start_recording' => await _startRecording(args),
        'stop_recording' => await _stopRecording(),
        'recall_recording' => _recallRecording(args),
        'call_contact' => await _callContact(args),
        _ => {'error': 'Unknown tool $name.'},
      };
    } catch (error) {
      // Never let this escape. An exception here becomes a FlutterError on the
      // native side, which turns into a useless error string for the model —
      // a plain sentence it can actually say is better.
      return {'error': 'That did not work: $error'};
    }
  }

  // MARK: - Silence

  bool _muted = false;

  void _onRecordingsChanged() {
    if (_muted && !recordings.isRecording) {
      _muted = false;
      setRecordingMode(false);
    }
  }

  /// The model is staying quiet. If a recording is running, that is the cue to
  /// start dropping its audio for real — anything it says from here on is it
  /// breaking its own instructions, and over an hour-long meeting that happens.
  /// Guarded so the platform call is made once per recording, not once per
  /// overheard sentence.
  Future<Map<String, Object?>> _staySilent() async {
    if (recordings.isRecording && !_muted) {
      _muted = true;
      await setRecordingMode(true);
    }
    return const {'result': 'ok'};
  }

  // MARK: - Reminders

  /// Reads a time the model produced as the person's own wall-clock time.
  ///
  /// The model is told the local time with its offset, yet hands times back
  /// with the right offset sometimes, none at other times, and — seen in
  /// testing — occasionally a "+00:00" that is simply wrong. Honouring that
  /// would shift a 3 pm reminder by five and a half hours, so the offset is
  /// discarded and the date and time read as local. The person said "three
  /// o'clock" where they are; that is the only meaning it ever has.
  static DateTime? _localTime(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final bare = text.replaceFirst(RegExp(r'(Z|[+-]\d{2}:?\d{2})$'), '');
    return DateTime.tryParse(bare);
  }

  Future<Map<String, Object?>> _createReminder(Map<String, Object?> args) async {
    final title = (args['title'] as String? ?? '').trim();
    if (title.isEmpty) return {'error': 'No reminder text was given.'};

    final due = _localTime(args['at']);
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
    final due = _localTime(args['at']);
    if (due == null) {
      return {'error': 'No new time was given. Ask them what time they want.'};
    }
    if (!due.isAfter(DateTime.now())) {
      return {
        'error': 'That time is already in the past, so nothing was changed. '
            'Ask them when they want it.',
      };
    }
    final task = brief.find(args['title'] as String? ?? '');
    if (task == null) {
      return {
        'error': 'There is no reminder matching that, so nothing was moved. '
            'Tell them, and offer to set a new one.',
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

  // MARK: - Recording

  Future<Map<String, Object?>> _startRecording(Map<String, Object?> args) async {
    if (recordings.isRecording) {
      return {'result': 'Already recording — nothing changed.'};
    }
    recordings.start(label: args['label'] as String?);
    // Deliberately *not* dropping Ordi's audio yet: the model is about to say
    // its one-line confirmation, and silencing playback now would swallow the
    // only proof — before the first haptic tick, ten seconds away — that
    // recording began. Playback is muted on the first stay_silent instead,
    // which is the model itself signalling it has gone into note-taking mode.
    // One firm tap now so the person feels it start.
    unawaited(HapticFeedback.mediumImpact());
    return {
      'result':
          'Recording. Say one short sentence confirming it, then stay silent '
              'until they stop it.',
    };
  }

  Future<Map<String, Object?>> _stopRecording() async {
    // Un-muting happens in [_onRecordingsChanged], as stop() notifies.
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
