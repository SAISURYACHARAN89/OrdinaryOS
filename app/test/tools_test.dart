import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:ordi/models/ai_brief.dart';
import 'package:ordi/models/recording_store.dart';
import 'package:ordi/models/reminder_scheduler.dart';
import 'package:ordi/models/speed_dial.dart';
import 'package:ordi/ordi/tool_dispatcher.dart';
import 'package:ordi/ui/time_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BriefTask', () {
    test('a record from before tasks had times or ids still loads', () {
      // What ai_brief_tasks_v1 held before this change.
      final task = BriefTask.fromJson({'title': 'Call the dentist', 'done': true});
      expect(task.title, 'Call the dentist');
      expect(task.done, isTrue);
      expect(task.dueAt, isNull);
      expect(task.id, isNonNegative);
      // Derived from the title, so it must not change between launches.
      expect(BriefTask.fromJson({'title': 'Call the dentist'}).id, task.id);
    });

    test('a dated task survives a round trip', () {
      final due = DateTime(2026, 9, 20, 16);
      final back = BriefTask.fromJson(
        BriefTask(title: 'Bins', id: 7, dueAt: due).toJson(),
      );
      expect(back.dueAt, due);
      expect(back.id, 7);
    });
  });

  group('AiBrief', () {
    test('add dedupes case-insensitively and hands back the existing task', () {
      final brief = AiBrief();
      final first = brief.add('Call the dentist');
      final again = brief.add('  call the DENTIST ');
      expect(identical(first, again), isTrue);
      expect(brief.tasks, hasLength(1));
    });

    test('only dated, pending, future tasks are upcoming, soonest first', () {
      final brief = AiBrief();
      final now = DateTime.now();
      brief.add('later', at: now.add(const Duration(hours: 5)));
      brief.add('sooner', at: now.add(const Duration(hours: 1)));
      brief.add('undated');
      brief.add('past', at: now.subtract(const Duration(hours: 1)));
      final done = brief.add('finished', at: now.add(const Duration(hours: 2)));
      done.done = true;

      expect(brief.upcoming.map((t) => t.title), ['sooner', 'later']);
    });

    test('onScheduled fires for dated tasks only', () {
      final brief = AiBrief();
      final scheduled = <String>[];
      brief.onScheduled = (t) => scheduled.add(t.title);
      brief.add('undated');
      brief.add('dated', at: DateTime.now().add(const Duration(hours: 1)));
      expect(scheduled, ['dated']);
    });

    test('extracted tasks get distinct ids', () {
      final brief = AiBrief()..addExtracted(['a', 'b', 'c']);
      expect(brief.tasks.map((t) => t.id).toSet(), hasLength(3));
    });
  });

  group('RecordingStore', () {
    test('keeps what was said even when Ordi answered with nothing', () {
      final store = RecordingStore()..start(label: 'standup');
      store.observe('we ship on friday', '');
      store.observe('   ', ''); // whitespace is not speech
      expect(store.active!.utterances.map((u) => u.text), ['we ship on friday']);
    });

    test('ignores everything while nothing is recording', () {
      final store = RecordingStore();
      store.observe('hello', '');
      expect(store.recordings, isEmpty);
    });

    test('starting twice keeps the recording in progress', () {
      final store = RecordingStore();
      final first = store.start(label: 'a');
      store.observe('one', '');
      final second = store.start(label: 'b');
      expect(identical(first, second), isTrue);
      expect(second.utterances, hasLength(1));
    });

    test('drops the oldest speech first once over budget', () {
      final store = RecordingStore()..start();
      final chunk = 'x' * 5000;
      for (var i = 0; i < 10; i++) {
        store.observe('$i$chunk', '');
      }
      final kept = store.active!.utterances;
      expect(kept.fold<int>(0, (n, u) => n + u.text.length),
          lessThanOrEqualTo(24000));
      // The tail survives; the head is what goes.
      expect(kept.last.text.startsWith('9'), isTrue);
      expect(kept.first.text.startsWith('0'), isFalse);
    });

    test('find resolves "last" to the newest finished recording', () {
      final store = RecordingStore();
      store.start(label: 'standup');
      store.observe('a', '');
      store.stop();
      store.start(label: 'lunch');
      store.observe('b', '');
      store.stop();

      expect(store.find('last')!.label, 'lunch');
      expect(store.find('my last conversation')!.label, 'lunch');
      expect(store.find('standup')!.label, 'standup');
    });

    test('find does not return the recording still in progress as "last"', () {
      final store = RecordingStore();
      store.start(label: 'done');
      store.observe('a', '');
      store.stop();
      store.start(label: 'running');
      expect(store.find('last')!.label, 'done');
    });

    test('a recording survives a save and load', () async {
      final store = RecordingStore()..start(label: 'standup');
      store.observe('we ship on friday', '');
      store.stop();
      await store.flush();

      final reloaded = RecordingStore();
      await reloaded.load();
      expect(reloaded.recordings, hasLength(1));
      expect(reloaded.recordings.first.label, 'standup');
      expect(reloaded.recordings.first.utterances.single.text,
          'we ship on friday');
    });
  });

  group('dueLabel', () {
    test('says today, tomorrow, and a weekday the way a person would', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 18);
      expect(dueLabel(today), 'today at 6:00 PM');
      expect(dueLabel(today.add(const Duration(days: 1))), 'tomorrow at 6:00 PM');
      expect(dueLabel(today.add(const Duration(days: 3))), startsWith('on '));
    });

    test('a date far ahead is not announced as a bare weekday', () {
      final far = DateTime.now().add(const Duration(days: 200));
      expect(dueLabel(far), contains(far.day.toString()));
    });
  });

  group('ToolDispatcher', () {
    late AiBrief brief;
    late RecordingStore recordings;
    late SpeedDial speedDial;
    late ReminderScheduler reminders;
    late List<bool> recordingModes;
    late ToolDispatcher tools;

    setUp(() {
      brief = AiBrief();
      recordings = RecordingStore();
      speedDial = SpeedDial();
      reminders = ReminderScheduler(speak: (_) async => false);
      recordingModes = [];
      tools = ToolDispatcher(
        brief: brief,
        recordings: recordings,
        speedDial: speedDial,
        reminders: reminders,
        setRecordingMode: (on) async => recordingModes.add(on),
      );
    });

    tearDown(() => reminders.dispose());

    test('stay_silent always succeeds and does nothing', () async {
      expect(await tools.handle('stay_silent', {}), {'result': 'ok'});
      expect(brief.tasks, isEmpty);
    });

    test('an unknown tool is answered, not thrown', () async {
      final out = await tools.handle('launch_missiles', {});
      expect(out['error'], contains('Unknown tool'));
    });

    test('create_reminder with a time adds a dated task and says when', () async {
      final at = DateTime.now().add(const Duration(days: 1));
      final out = await tools.handle('create_reminder', {
        'title': 'Call the dentist',
        'at': at.toIso8601String(),
      });
      expect(out['result'], startsWith('Reminder set for tomorrow'));
      expect(brief.tasks.single.title, 'Call the dentist');
      expect(brief.tasks.single.dueAt, isNotNull);
    });

    test('a time is read as the person\'s own wall clock, whatever offset it carries',
        () async {
      // The model has been seen labelling a local 3 pm as +00:00. Honouring the
      // label would fire it five and a half hours late on an Indian phone.
      final day = DateTime.now().add(const Duration(days: 1));
      final wall = '${day.year.toString().padLeft(4, '0')}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}T15:00:00';
      for (final suffix in ['', 'Z', '+00:00', '+05:30', '-08:00']) {
        brief.remove(brief.tasks.isEmpty ? BriefTask(title: '', id: 0) : brief.tasks.first);
        await tools.handle('create_reminder', {'title': 'Bins', 'at': '$wall$suffix'});
        final due = brief.tasks.single.dueAt!;
        expect([due.hour, due.minute], [15, 0], reason: 'suffix "$suffix"');
      }
    });

    test('create_reminder without a time is still saved, honestly', () async {
      final out = await tools.handle('create_reminder', {'title': 'Renew passport'});
      expect(out['result'], contains('no time set'));
      expect(brief.tasks.single.dueAt, isNull);
    });

    test('create_reminder in the past says nothing will fire', () async {
      final out = await tools.handle('create_reminder', {
        'title': 'Too late',
        'at': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      });
      expect(out['result'], contains('in the past'));
    });

    test('create_reminder with a garbage time is saved undated, not dropped',
        () async {
      final out = await tools.handle('create_reminder', {
        'title': 'Whenever',
        'at': 'sometime soonish',
      });
      expect(out['result'], contains('no time set'));
      expect(brief.tasks, hasLength(1));
    });

    test('create_reminder with no title is refused', () async {
      final out = await tools.handle('create_reminder', {'title': '  '});
      expect(out.containsKey('error'), isTrue);
      expect(brief.tasks, isEmpty);
    });

    group('moving and cancelling reminders', () {
      String at(int daysAhead, int hour) {
        final d = DateTime.now().add(Duration(days: daysAhead));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}T${hour.toString().padLeft(2, '0')}:00:00';
      }

      test('asking again for the same reminder at a new time moves it',
          () async {
        // The reported bug: "set it for ten", then "make it three" — Ordi said
        // it had moved, and the list still said ten.
        await tools.handle('create_reminder', {'title': 'Call mom', 'at': at(1, 10)});
        final out = await tools.handle('create_reminder', {'title': 'Call mom', 'at': at(1, 15)});
        expect(brief.tasks, hasLength(1));
        expect(brief.tasks.single.dueAt!.hour, 15);
        expect(out['result'], contains('moved'));
      });

      test('update_reminder moves "last" without being told which', () async {
        await tools.handle('create_reminder', {'title': 'Call mom', 'at': at(1, 10)});
        final out = await tools.handle('update_reminder', {'title': 'last', 'at': at(1, 15)});
        expect(out['result'], startsWith('Moved "Call mom"'));
        expect(brief.tasks.single.dueAt!.hour, 15);
      });

      test('update_reminder finds a reminder from a looser description',
          () async {
        await tools.handle('create_reminder', {'title': 'Call the dentist', 'at': at(1, 10)});
        await tools.handle('create_reminder', {'title': 'Take out the bins', 'at': at(1, 20)});
        await tools.handle('update_reminder', {'title': 'the dentist call', 'at': at(2, 9)});
        final dentist = brief.tasks.firstWhere((t) => t.title == 'Call the dentist');
        final bins = brief.tasks.firstWhere((t) => t.title == 'Take out the bins');
        expect(dentist.dueAt!.hour, 9);
        expect(bins.dueAt!.hour, 20);
      });

      test('update_reminder for something that does not exist says so',
          () async {
        final out = await tools.handle('update_reminder', {'title': 'call mom', 'at': at(1, 15)});
        expect(out.containsKey('error'), isTrue);
        expect(brief.tasks, isEmpty);
      });

      test('update_reminder refuses a time already past', () async {
        await tools.handle('create_reminder', {'title': 'Call mom', 'at': at(1, 10)});
        final out = await tools.handle('update_reminder', {'title': 'last', 'at': at(-1, 10)});
        expect(out.containsKey('error'), isTrue);
        expect(brief.tasks.single.dueAt!.hour, 10);
      });

      test('cancel_reminder removes it, and reports honestly when it cannot',
          () async {
        await tools.handle('create_reminder', {'title': 'Call mom', 'at': at(1, 10)});
        final ok = await tools.handle('cancel_reminder', {'title': 'call mom'});
        expect(ok['result'], startsWith('Cancelled'));
        expect(brief.tasks, isEmpty);
        final missing = await tools.handle('cancel_reminder', {'title': 'call mom'});
        expect(missing.containsKey('error'), isTrue);
      });

      test('finished tasks are never the target of a move', () async {
        final done = brief.add('Call mom', at: DateTime.now().add(const Duration(days: 1)));
        done.done = true;
        final out = await tools.handle('update_reminder', {'title': 'last', 'at': at(1, 15)});
        expect(out.containsKey('error'), isTrue);
      });
    });

    test('recording start, capture, stop, and recall', () async {
      final start = await tools.handle('start_recording', {'label': 'standup'});
      expect(start['result'], startsWith('Recording'));
      // Not muted yet — the model still has to say "I'm recording".
      expect(recordingModes, isEmpty);
      expect(recordings.isRecording, isTrue);

      // Its first stay_silent is what starts the muting, and only once.
      await tools.handle('stay_silent', {});
      await tools.handle('stay_silent', {});
      expect(recordingModes, [true]);

      recordings.observe('we ship on friday', '');
      recordings.observe('QA needs two days', '');

      final stop = await tools.handle('stop_recording', {});
      expect(recordingModes, [true, false]);
      expect(recordings.isRecording, isFalse);
      expect(stop['result'], contains('2 things said'));
      expect(stop['result'], contains('we ship on friday'));

      // No summary has come back yet, so recall falls back to the raw words
      // rather than making the person wait or inventing one.
      final recall = await tools.handle('recall_recording', {'which': 'last'});
      expect(recall['result'], contains('not summarised yet'));
      expect(recall['result'], contains('QA needs two days'));
    });

    test('a recording stopped from the dashboard un-mutes, and re-mutes next time',
        () async {
      await tools.handle('start_recording', {});
      await tools.handle('stay_silent', {});
      expect(recordingModes, [true]);

      // Stopped by the Stop button, not by voice.
      recordings.stop();
      expect(recordingModes, [true, false]);

      // The next recording must be able to mute again.
      await tools.handle('start_recording', {});
      await tools.handle('stay_silent', {});
      expect(recordingModes, [true, false, true]);
    });

    test('stay_silent outside a recording never touches playback', () async {
      await tools.handle('stay_silent', {});
      expect(recordingModes, isEmpty);
    });

    test('recall says so when there is nothing to recall', () async {
      final out = await tools.handle('recall_recording', {'which': 'last'});
      expect(out['result'], contains('no recordings'));
    });

    test('stopping when nothing is recording is not an error', () async {
      final out = await tools.handle('stop_recording', {});
      expect(out['result'], contains('Nothing was being recorded'));
    });

    test('call_contact matches a first name against a full one', () async {
      speedDial.add(const SpeedDialContact(name: 'Sai Surya Charan', phone: '+911'));
      final out = await tools.handle('call_contact', {'name': 'charan'});
      expect(out['result'], startsWith('Opening the phone to call Sai Surya Charan'));
    });

    test('call_contact is case and punctuation insensitive', () async {
      speedDial.add(const SpeedDialContact(name: "Mom", phone: '+912'));
      final out = await tools.handle('call_contact', {'name': ' MOM! '});
      expect(out['result'], startsWith('Opening the phone to call Mom'));
    });

    test('a number is cleaned for the dialler', () {
      String dial(String raw) => SpeedDialContact(name: 'x', phone: raw).dialNumber;
      expect(dial('+91 98765 43210'), '+919876543210');
      expect(dial('(555) 123-4567'), '5551234567');
      expect(dial('  098765-43210 '), '09876543210');
      expect(dial('+1 (555) 123-4567,,2'), '+15551234567,,2');
      expect(dial('no digits'), '');
    });

    test('a contact with no usable number is reported, not dialled', () async {
      speedDial.add(const SpeedDialContact(name: 'Ghost', phone: 'n/a'));
      final out = await tools.handle('call_contact', {'name': 'ghost'});
      expect(out['result'], contains('no usable phone number'));
    });

    test('with the app in the background it does not claim to be dialling',
        () async {
      speedDial.add(const SpeedDialContact(name: 'Mom', phone: '+912'));
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(() => TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));

      final out = await tools.handle('call_contact', {'name': 'mom'});
      expect(out['result'], contains('background'));
      expect(out['result'], isNot(startsWith('Opening the phone')));
    });

    test('call_contact with no name is refused', () async {
      final out = await tools.handle('call_contact', {'name': ''});
      expect(out.containsKey('error'), isTrue);
    });
  });
}
