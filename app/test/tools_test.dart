import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:fake_async/fake_async.dart';
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

  group('reminders leave the list on their own', () {
    test('ten seconds after being ticked off, unless unticked first', () {
      fakeAsync((clock) {
        final brief = AiBrief();
        final cancelled = <String>[];
        brief.onCancelled = (t) => cancelled.add(t.title);
        brief.add('Call mom');
        brief.add('Buy milk');

        brief.toggle(0);
        expect(cancelled, ['Call mom']); // its alert is withdrawn straight away
        clock.elapse(const Duration(seconds: 9));
        expect(brief.tasks, hasLength(2)); // still showing, can be unticked

        brief.toggle(1); // tick Buy milk…
        clock.elapse(const Duration(seconds: 2));
        expect(brief.tasks.map((t) => t.title), ['Buy milk']);

        brief.toggle(0); // …and untick it again in time
        clock.elapse(const Duration(seconds: 30));
        expect(brief.tasks.map((t) => t.title), ['Buy milk']);
      });
    });

    test('ten seconds after its reminder has gone off', () {
      fakeAsync((clock) {
        final brief = AiBrief();
        brief.add('Stretch', at: DateTime.now().add(const Duration(minutes: 1)));
        brief.add('Undated');
        clock.elapse(const Duration(minutes: 1, seconds: 5));
        expect(brief.tasks, hasLength(2));
        clock.elapse(const Duration(seconds: 6));
        expect(brief.tasks.map((t) => t.title), ['Undated']);
      });
    });

    test('a reminder given a time already past stays until dealt with', () {
      fakeAsync((clock) {
        final brief = AiBrief();
        brief.add('Late', at: DateTime.now().subtract(const Duration(hours: 1)));
        clock.elapse(const Duration(minutes: 5));
        expect(brief.tasks, hasLength(1));
      });
    });

    test('on launch, finished and already-alerted ones are gone', () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'ai_brief_tasks_v1': '[{"title":"Done","id":1,"done":true},'
            '{"title":"Went off","id":2,"dueAt":"${now.subtract(const Duration(hours: 2)).toIso8601String()}"},'
            '{"title":"Later","id":3,"dueAt":"${now.add(const Duration(hours: 2)).toIso8601String()}"},'
            '{"title":"Undated","id":4}]',
      });
      final brief = AiBrief();
      await brief.load();
      expect(brief.tasks.map((t) => t.title), ['Later', 'Undated']);
      brief.dispose();
    });

    test('editing renames, reschedules, and clears a time', () {
      final brief = AiBrief();
      final scheduled = <DateTime?>[];
      final cancelled = <int>[];
      brief.onScheduled = (t) => scheduled.add(t.dueAt);
      brief.onCancelled = (t) => cancelled.add(t.id);
      final task = brief.add('Call mom');
      final at = DateTime.now().add(const Duration(hours: 3));

      brief.edit(task, title: '  Call mum ', dueAt: at);
      expect(task.title, 'Call mum');
      expect(task.dueAt, at);
      expect(scheduled, [at]);

      brief.edit(task, clearDue: true);
      expect(task.dueAt, isNull);
      expect(cancelled, [task.id]);
      brief.dispose();
    });
  });

  group('RecordingStore', () {
    test('keeps what was said even when Ordi answered with nothing', () {
      final store = RecordingStore()..start(label: 'standup');
      store.observe('we ship on friday', '');
      store.observe('   ', ''); // whitespace is not speech
      expect(store.active!.utterances.map((u) => u.text), ['we ship on friday']);
    });

    test('a recording can be deleted, including the one running', () {
      final store = RecordingStore();
      final first = store.start(label: 'a');
      store.observe('one', '');
      store.stop();
      final second = store.start(label: 'b');
      store.remove(first);
      expect(store.recordings, [second]);
      store.remove(second);
      expect(store.recordings, isEmpty);
      expect(store.isRecording, isFalse);
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
    late ToolDispatcher tools;

    setUp(() {
      brief = AiBrief();
      recordings = RecordingStore();
      speedDial = SpeedDial();
      reminders = ReminderScheduler(speak: (_) async => false);
      tools = ToolDispatcher(
        brief: brief,
        recordings: recordings,
        speedDial: speedDial,
        reminders: reminders,
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

    group('reminder times', () {
      DateTime dueOf() => brief.tasks.single.dueAt!;

      test('in_minutes counts from now', () async {
        await tools.handle('create_reminder', {'title': 'Water', 'in_minutes': 2});
        final left = dueOf().difference(DateTime.now()).inSeconds;
        expect(left, inInclusiveRange(110, 120));
      });

      test('a time of day with no date is the next time that comes round',
          () async {
        final now = DateTime.now();
        final later = now.add(const Duration(hours: 1));
        final hhmm = '${later.hour.toString().padLeft(2, '0')}:'
            '${later.minute.toString().padLeft(2, '0')}';
        await tools.handle('create_reminder', {'title': 'Soon', 'time': hhmm});
        expect([dueOf().hour, dueOf().minute], [later.hour, later.minute]);
        expect(dueOf().isAfter(now), isTrue);

        final earlier = now.subtract(const Duration(hours: 1));
        final past = '${earlier.hour.toString().padLeft(2, '0')}:'
            '${earlier.minute.toString().padLeft(2, '0')}';
        brief.remove(brief.tasks.single);
        await tools.handle('create_reminder', {'title': 'Tomorrow', 'time': past});
        expect(dueOf().isAfter(now), isTrue, reason: 'rolled to tomorrow');
      });

      test('a date and time are read as local, with no zone to get wrong',
          () async {
        final d = DateTime.now().add(const Duration(days: 2));
        final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        await tools.handle('create_reminder', {'title': 'Trip', 'date': date, 'time': '15:00'});
        expect(dueOf(), DateTime(d.year, d.month, d.day, 15));
      });

      test('an older server\'s stamp converted to UTC still lands at the right moment',
          () async {
        // The bug: "in two minutes" came back as the UTC time, and the digits
        // read as local put it hours in the past.
        final target = DateTime.now().add(const Duration(minutes: 2));
        final stamp = target.toUtc().toIso8601String().split('.').first;
        await tools.handle('create_reminder', {'title': 'Water', 'at': '${stamp}Z'});
        expect(dueOf().difference(target).inSeconds.abs(), lessThan(2));
      });

      test('an older server\'s stamp with no zone is local', () async {
        final d = DateTime.now().add(const Duration(days: 1));
        final wall = DateTime(d.year, d.month, d.day, 15);
        await tools.handle('create_reminder',
            {'title': 'Bins', 'at': wall.toIso8601String().split('.').first});
        expect(dueOf(), wall);
      });

      test('moving to a time with no date keeps the reminder on its own day',
          () async {
        final d = DateTime.now().add(const Duration(days: 3));
        final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        await tools.handle('create_reminder', {'title': 'Rent', 'date': date, 'time': '09:00'});
        await tools.handle('update_reminder', {'title': 'last', 'time': '15:00'});
        expect(dueOf(), DateTime(d.year, d.month, d.day, 15));
      });

      test('a refused move says plainly that nothing changed', () async {
        await tools.handle('create_reminder', {'title': 'Call mom', 'in_minutes': 60});
        final out = await tools.handle('update_reminder', {
          'title': 'last',
          'date': '2020-01-01',
          'time': '10:00',
        });
        expect(out['error'], contains('NOTHING was changed'));
      });
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
      expect(start['result'], startsWith('Recording started'));
      expect(recordings.isRecording, isTrue);

      // Ordi keeps working while it records: overheard speech is kept, and so
      // is a reply Ordi gives when someone does address it.
      await tools.handle('stay_silent', {});
      recordings.observe('we ship on friday', '');
      recordings.observe('QA needs two days', '');
      recordings.observe('Ordi what time is it', 'It is four pm.');
      final said = recordings.active!.utterances;
      expect(said.map((u) => u.text),
          ['we ship on friday', 'QA needs two days', 'Ordi what time is it', 'It is four pm.']);
      expect(said.last.fromOrdi, isTrue);
      expect(recordings.active!.transcript, endsWith('Ordi: It is four pm.'));

      final stop = await tools.handle('stop_recording', {});
      expect(recordings.isRecording, isFalse);
      expect(stop['result'], contains('4 things said'));
      expect(stop['result'], contains('we ship on friday'));

      // No summary has come back yet, so recall falls back to the raw words
      // rather than making the person wait or inventing one.
      final recall = await tools.handle('recall_recording', {'which': 'last'});
      expect(recall['result'], contains('not summarised yet'));
      expect(recall['result'], contains('QA needs two days'));
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
