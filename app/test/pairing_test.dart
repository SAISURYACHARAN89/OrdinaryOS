import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ordi/models/pairing.dart';
import 'package:ordi/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_radio.dart';

const glasses = FoundDevice(id: 'AAAA', name: 'SM03', rssi: -50);

void main() {
  late List<String> events;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    events = [];
    OrdiBackend.stub = () async => const SessionToken(token: 't', model: 'm');
    OrdiBackend.diagSpy = events.add;
  });
  tearDown(() {
    OrdiBackend.stub = null;
    OrdiBackend.diagSpy = null;
  });

  Future<Map<String, dynamic>> saved() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString('pairing_v1') ?? '{}') as Map<String, dynamic>;
  }

  test('the Audios are found by their model name, however it is written', () {
    for (final name in ['SM03', 'sm03', 'SMO3', 'Ordinary SM03', 'SM03_BLE', 'SM03-1A2B']) {
      expect(Pairing.isAudios(name), isTrue, reason: name);
    }
    for (final name in ['JBL Flip 5', 'SM-G991B', 'AirPods', 'Ordinary Band', '']) {
      expect(Pairing.isAudios(name), isFalse, reason: name);
    }
    expect(Pairing.isBand('Ordinary Band'), isTrue);
    expect(Pairing.isBand('SM03'), isFalse);
  });

  testWidgets('a scan shows only the Audios, nearest first', (tester) async {
    final radio = FakeRadio(nearby: const [
      FoundDevice(id: '1', name: 'JBL Flip 5', rssi: -40),
      FoundDevice(id: '2', name: 'SM03', rssi: -70),
      FoundDevice(id: '3', name: 'Ordinary Band', rssi: -45),
      FoundDevice(id: '4', name: 'SMO3-LE', rssi: -52),
    ]);
    final pairing = Pairing(radio: radio);
    final lists = <List<String>>[];
    final sub = pairing.scan().listen((l) => lists.add([for (final d in l) d.name]));
    await tester.pump();
    expect(lists.last, ['SMO3-LE', 'SM03']);
    unawaited(sub.cancel());
    await tester.pump();

    final bands = <List<String>>[];
    final bandSub = pairing.scan(band: true).listen((l) => bands.add([for (final d in l) d.name]));
    await tester.pump();
    expect(bands.last, ['Ordinary Band']);
    unawaited(bandSub.cancel());
    await tester.pump();
    pairing.dispose();
  });

  testWidgets('connecting pairs the Audios, shows the real battery, and remembers them',
      (tester) async {
    final radio = FakeRadio()..level = 76;
    final pairing = Pairing(radio: radio);
    var done = false;
    Object? failed;
    pairing.connect(glasses, band: false).then((_) {
      done = true;
    }, onError: (Object e) {
      failed = e;
    });
    await tester.pump();
    // Someone is watching this attempt, so it gives up rather than hang.
    expect(radio.dials.single.timeout, const Duration(seconds: 15));
    expect(pairing.audiosConnected, isFalse);

    radio.say('AAAA', true);
    await tester.pump();
    await tester.pump();
    expect(failed, isNull);
    expect(done, isTrue);
    expect(pairing.audiosConnected, isTrue);
    expect(pairing.audiosBattery, 76);
    expect(pairing.audiosId, 'AAAA');
    expect(pairing.audiosName, 'SM03');
    expect((await tester.runAsync(saved))!['audiosId'], 'AAAA');
    expect(events, containsAll(['ble-up', 'ble-gatt', 'ble-battery']));
    pairing.dispose();
  });

  testWidgets('a first connection that fails is reported and nothing is remembered',
      (tester) async {
    final radio = FakeRadio();
    final pairing = Pairing(radio: radio);
    Object? failed;
    pairing.connect(glasses, band: false).then((_) {}, onError: (Object e) {
      failed = e;
    });
    await tester.pump();
    radio.say('AAAA', false);
    await tester.pump();
    expect(failed, isNotNull);
    expect(pairing.audiosId, isNull);
    expect(pairing.audiosConnected, isFalse);
    // Not paired, so nothing keeps trying behind the person's back.
    await tester.pump(const Duration(seconds: 30));
    expect(radio.dials.length, 1);
    pairing.dispose();
  });

  testWidgets('when the Audios drop they reconnect by themselves', (tester) async {
    final radio = FakeRadio();
    final pairing = Pairing(radio: radio);
    unawaited(pairing.connect(glasses, band: false));
    await tester.pump();
    radio.say('AAAA', true);
    await tester.pump();
    await tester.pump();
    expect(pairing.audiosBattery, 76);

    // Switched off, or out of range.
    radio.say('AAAA', false);
    await tester.pump();
    expect(pairing.audiosConnected, isFalse);
    expect(pairing.audiosBattery, -1, reason: 'no stale battery level');
    expect(pairing.audiosId, 'AAAA', reason: 'still paired');

    await tester.pump(const Duration(seconds: 2));
    expect(radio.dials.length, 2);
    // This attempt never gives up: it completes whenever they come back.
    expect(radio.dials.last.timeout, isNull);

    radio.level = 71;
    radio.say('AAAA', true);
    await tester.pump();
    await tester.pump();
    expect(pairing.audiosConnected, isTrue);
    expect(pairing.audiosBattery, 71);
    pairing.dispose();
  });

  testWidgets('at launch, remembered Audios connect without anyone asking', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pairing_v1': '{"done":true,"setup":"audiosOnly","audiosId":"AAAA","audiosName":"SM03"}',
    });
    final radio = FakeRadio();
    final pairing = Pairing(radio: radio);
    await tester.runAsync(pairing.load);
    await tester.pump();
    expect(pairing.audiosId, 'AAAA');
    expect(radio.dials.single, (id: 'AAAA', timeout: null));
    expect(pairing.audiosConnected, isFalse, reason: 'not until they answer');

    // (Loaded outside the test clock, so this is real time passing.)
    radio.say('AAAA', true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(pairing.audiosConnected, isTrue);
    expect(pairing.audiosBattery, 76);
    pairing.dispose();
  });

  testWidgets('the battery follows the Audios while they are connected', (tester) async {
    final radio = FakeRadio(answers: true)..level = 80;
    final pairing = Pairing(radio: radio);
    unawaited(pairing.connect(glasses, band: false));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(pairing.audiosBattery, 80);

    // They announce a change…
    radio.announced.add(79);
    await tester.pump();
    expect(pairing.audiosBattery, 79);

    // …and are asked again every minute in case they never do.
    radio.level = 77;
    await tester.pump(Pairing.batteryEvery + const Duration(seconds: 1));
    await tester.pump();
    expect(pairing.audiosBattery, 77);
    pairing.dispose();
  });

  testWidgets('Audios with no battery service show as connected, with no number',
      (tester) async {
    final radio = FakeRadio(answers: true)..level = null;
    final pairing = Pairing(radio: radio);
    unawaited(pairing.connect(glasses, band: false));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(pairing.audiosConnected, isTrue);
    expect(pairing.audiosBattery, -1);
    pairing.dispose();
  });

  testWidgets('forgetting the Audios lets go of them for good', (tester) async {
    final radio = FakeRadio(answers: true);
    final pairing = Pairing(radio: radio);
    unawaited(pairing.connect(glasses, band: false));
    await tester.pump();
    await tester.pump();
    expect(radio.holding('AAAA'), isTrue);

    await tester.runAsync(() => pairing.forget(band: false));
    expect(radio.holding('AAAA'), isFalse);
    expect(pairing.audiosId, isNull);
    expect(pairing.audiosConnected, isFalse);
    await tester.pump(const Duration(minutes: 2));
    expect(radio.dials.length, 1);
    pairing.dispose();
  });

  testWidgets('coming back to the app tries disconnected Audios at once', (tester) async {
    final radio = FakeRadio();
    final pairing = Pairing(radio: radio);
    unawaited(pairing.connect(glasses, band: false));
    await tester.pump();
    radio.say('AAAA', true);
    await tester.pump();
    await tester.pump();
    radio.say('AAAA', false);
    await tester.pump();
    final before = radio.dials.length;
    pairing.wake();
    expect(radio.dials.length, before + 1);
    // A connected pair is left alone.
    radio.say('AAAA', true);
    await tester.pump();
    await tester.pump();
    final connectedDials = radio.dials.length;
    pairing.wake();
    expect(radio.dials.length, connectedDials);
    pairing.dispose();
  });

  group('Audios the phone connects as a headset', () {
    testWidgets('are found among the phone\'s headsets, with no scan result at all',
        (tester) async {
      final radio = FakeRadio()..headsets = ['AirPods Pro', 'SM03'];
      final pairing = Pairing(radio: radio);
      final lists = <List<FoundDevice>>[];
      final sub = pairing.scan().listen(lists.add);
      await tester.pump();
      await tester.pump();
      expect([for (final d in lists.last) d.name], ['SM03']);
      expect(Pairing.isPhoneLinked(lists.last.single.id), isTrue);
      unawaited(sub.cancel());
      await tester.pump();
      pairing.dispose();
    });

    testWidgets('appear once they are switched on during the search', (tester) async {
      final radio = FakeRadio();
      final pairing = Pairing(radio: radio);
      final lists = <List<FoundDevice>>[];
      final sub = pairing.scan().listen(lists.add);
      await tester.pump(const Duration(seconds: 3));
      expect(lists, isEmpty);
      radio.headsets = ['SM03'];
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(lists.last.single.name, 'SM03');
      unawaited(sub.cancel());
      await tester.pump();
      pairing.dispose();
    });

    testWidgets('seen both ways, they are listed once', (tester) async {
      final radio = FakeRadio(nearby: const [FoundDevice(id: 'BBBB', name: 'SM03', rssi: -60)])
        ..headsets = ['SM03'];
      final pairing = Pairing(radio: radio);
      final lists = <List<FoundDevice>>[];
      final sub = pairing.scan().listen(lists.add);
      await tester.pump();
      await tester.pump();
      expect(lists.last.length, 1);
      expect(Pairing.isPhoneLinked(lists.last.single.id), isTrue);
      unawaited(sub.cancel());
      await tester.pump();
      pairing.dispose();
    });

    testWidgets('pair, show the real battery, and follow being switched off and on',
        (tester) async {
      final radio = FakeRadio()
        ..headsets = ['SM03']
        ..headsetBattery = 88;
      final pairing = Pairing(radio: radio);
      unawaited(pairing.connect(
          const FoundDevice(id: 'audio:SM03', name: 'SM03', rssi: -40), band: false));
      await tester.pump();
      await tester.pump();
      expect(pairing.audiosConnected, isTrue);
      expect(pairing.audiosBattery, 88);
      expect(pairing.audiosId, 'audio:SM03');
      expect(radio.batteryAskedFor.last, 'SM03');
      expect(radio.dials, isEmpty, reason: 'the phone holds this connection, not the app');

      // The battery drains.
      radio.headsetBattery = 86;
      await tester.pump(Pairing.phoneLinkEvery + const Duration(milliseconds: 100));
      await tester.pump();
      expect(pairing.audiosBattery, 86);

      // Switched off.
      radio.headsets = [];
      await tester.pump(Pairing.phoneLinkEvery);
      await tester.pump();
      expect(pairing.audiosConnected, isFalse);
      expect(pairing.audiosBattery, -1);
      expect(pairing.audiosId, 'audio:SM03', reason: 'still paired');

      // Switched on again: the phone reconnects them, and the app shows it.
      radio.headsets = ['SM03'];
      await tester.pump(Pairing.phoneLinkEvery);
      await tester.pump();
      expect(pairing.audiosConnected, isTrue);
      expect(pairing.audiosBattery, 86);
      expect(events, containsAll(['audio-up', 'audio-down', 'audio-battery']));
      pairing.dispose();
    });

    testWidgets('with no battery to read, show as connected with no number', (tester) async {
      final radio = FakeRadio()..headsets = ['SM03'];
      final pairing = Pairing(radio: radio);
      unawaited(pairing.connect(
          const FoundDevice(id: 'audio:SM03', name: 'SM03', rssi: -40), band: false));
      await tester.pump();
      await tester.pump();
      expect(pairing.audiosConnected, isTrue);
      expect(pairing.audiosBattery, -1);
      pairing.dispose();
    });

    testWidgets('switched off before being tapped, fail and are not remembered',
        (tester) async {
      final radio = FakeRadio();
      final pairing = Pairing(radio: radio);
      Object? failed;
      pairing
          .connect(const FoundDevice(id: 'audio:SM03', name: 'SM03', rssi: -40), band: false)
          .then((_) {}, onError: (Object e) {
        failed = e;
      });
      await tester.pump();
      await tester.pump();
      expect(failed, isNotNull);
      expect(pairing.audiosId, isNull);
      final asked = radio.batteryAskedFor.length;
      await tester.pump(const Duration(seconds: 30));
      expect(radio.batteryAskedFor.length, asked, reason: 'nothing keeps asking');
      pairing.dispose();
    });

    testWidgets('are followed again from launch, and let go when forgotten', (tester) async {
      SharedPreferences.setMockInitialValues({
        'pairing_v1': '{"done":true,"setup":"audiosOnly","audiosId":"audio:SM03","audiosName":"SM03"}',
      });
      final radio = FakeRadio()
        ..headsets = ['SM03']
        ..headsetBattery = 54;
      final pairing = Pairing(radio: radio);
      await tester.runAsync(pairing.load);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      expect(pairing.audiosConnected, isTrue);
      expect(pairing.audiosBattery, 54);

      await tester.runAsync(() => pairing.forget(band: false));
      expect(pairing.audiosId, isNull);
      expect(pairing.audiosConnected, isFalse);
      pairing.dispose();
    });
  });

  group('Audios the phone is not paired with yet (Android)', () {
    const nearby = FoundDevice(id: '11:22:33:44:55:66', name: 'SM03', rssi: -58);

    testWidgets('are found by searching for headsets', (tester) async {
      final radio = FakeRadio()
        ..unpaired = const [nearby, FoundDevice(id: 'AA:BB', name: 'Car Stereo', rssi: -50)];
      final pairing = Pairing(radio: radio);
      final lists = <List<FoundDevice>>[];
      final sub = pairing.scan().listen(lists.add);
      await tester.pump();
      await tester.pump();
      expect(radio.searches, 1);
      expect(lists.last.single.name, 'SM03');
      expect(Pairing.isUnpairedHeadset(lists.last.single.id), isTrue);
      unawaited(sub.cancel());
      await tester.pump();
      pairing.dispose();
    });

    testWidgets('are not searched for when it is the Band being set up', (tester) async {
      final radio = FakeRadio()..unpaired = const [nearby];
      final pairing = Pairing(radio: radio);
      final sub = pairing.scan(band: true).listen((_) {});
      await tester.pump();
      expect(radio.searches, 0);
      unawaited(sub.cancel());
      await tester.pump();
      pairing.dispose();
    });

    testWidgets('pair from inside the app, then count as connected by the phone',
        (tester) async {
      final radio = FakeRadio()
        ..unpaired = const [nearby]
        ..connectsAfterPairing = ['SM03']
        ..headsetBattery = 91;
      final pairing = Pairing(radio: radio);
      var done = false;
      pairing
          .connect(const FoundDevice(id: 'classic:11:22:33:44:55:66', name: 'SM03', rssi: -58),
              band: false)
          .then((_) {
        done = true;
      });
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(radio.pairedWith, ['11:22:33:44:55:66']);
      expect(done, isTrue);
      expect(pairing.audiosConnected, isTrue);
      expect(pairing.audiosBattery, 91);
      expect(pairing.audiosId, 'audio:SM03', reason: 'remembered as the phone\'s headset');
      pairing.dispose();
    });

    testWidgets('that take a few seconds to connect after pairing still succeed',
        (tester) async {
      final radio = FakeRadio();
      final pairing = Pairing(radio: radio);
      var done = false;
      pairing
          .connect(const FoundDevice(id: 'classic:11:22', name: 'SM03', rssi: -58), band: false)
          .then((_) {
        done = true;
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(done, isFalse);
      radio.headsets = ['SM03'];
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(done, isTrue);
      expect(pairing.audiosConnected, isTrue);
      pairing.dispose();
    });

    testWidgets('refused on the phone, fail and are not remembered', (tester) async {
      final radio = FakeRadio()..pairs = false;
      final pairing = Pairing(radio: radio);
      Object? failed;
      pairing
          .connect(const FoundDevice(id: 'classic:11:22', name: 'SM03', rssi: -58), band: false)
          .then((_) {}, onError: (Object e) {
        failed = e;
      });
      await tester.pump();
      await tester.pump();
      expect(failed, isNotNull);
      expect(pairing.audiosId, isNull);
      pairing.dispose();
    });

    testWidgets('paired but never connecting, fail after a wait', (tester) async {
      final radio = FakeRadio();
      final pairing = Pairing(radio: radio);
      Object? failed;
      pairing
          .connect(const FoundDevice(id: 'classic:11:22', name: 'SM03', rssi: -58), band: false)
          .then((_) {}, onError: (Object e) {
        failed = e;
      });
      await tester.pump();
      await tester.pump(Pairing.pairedWait + const Duration(seconds: 2));
      await tester.pump();
      expect(failed, isNotNull);
      expect(pairing.audiosId, isNull);
      pairing.dispose();
    });
  });

  testWidgets('connected Audios with no battery get one look at what they broadcast',
      (tester) async {
    final radio = FakeRadio()
      ..headsets = ['SM03']
      ..broadcasting = [
        {'key': 'x', 'name': '', 'rssi': -44, 'services': <String>[], 'connectable': 'available'},
      ];
    final pairing = Pairing(radio: radio);
    unawaited(pairing.connect(
        const FoundDevice(id: 'audio:SM03', name: 'SM03', rssi: -40), band: false));
    await tester.pump();
    await tester.pump();
    expect(radio.surveys, 0, reason: 'not while setup may still be searching');
    await tester.pump(Pairing.surveyAfter + const Duration(seconds: 1));
    expect(radio.surveys, 1);
    await tester.pump(const Duration(seconds: 9));
    expect(events, contains('ble-survey'));
    // Once is enough.
    await tester.pump(const Duration(minutes: 5));
    expect(radio.surveys, 1);
    pairing.dispose();
  });

  testWidgets('the stand-in Audios from before they were real are forgotten', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pairing_v1':
          '{"done":true,"setup":"audiosAndBand","audiosId":"demo:sm03","audiosName":"Ordinary SM03","bandId":"demo:band","bandName":"Ordinary Band"}',
    });
    final radio = FakeRadio();
    final pairing = Pairing(radio: radio);
    await tester.runAsync(pairing.load);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1600)));
    expect(pairing.done, isTrue);
    expect(pairing.audiosId, isNull);
    expect(pairing.audiosConnected, isFalse);
    expect(radio.dials, isEmpty);
    // The Band has no hardware yet and is still a stand-in.
    expect(pairing.bandId, 'demo:band');
    expect(pairing.bandConnected, isTrue);
    pairing.dispose();
  });
}
