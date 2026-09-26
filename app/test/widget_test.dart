import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ordi_audio/ordi_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ordi/main.dart';
import 'package:ordi/models/ai_brief.dart';
import 'package:ordi/models/conversation_log.dart';
import 'package:ordi/ordi/ordi_controller.dart';
import 'package:ordi/ordi/waveform.dart';
import 'package:ordi/session.dart';

/// Stands in for the native engine. Ordi is driven entirely by what the
/// platform sends, so the tests drive the platform.
class FakeAudio {
  FakeAudio({this.permission = true});

  final bool permission;
  MockStreamHandlerEventSink? _sink;
  final List<String> calls = [];
  Map<Object?, Object?>? connectArgs;

  static const _methods = MethodChannel('ordi/audio');
  static const _events = EventChannel('ordi/audio/events');

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    OrdiAudio.resetForTesting();
    _messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call.method);
      if (call.method == 'connect') {
        connectArgs = (call.arguments as Map).cast<Object?, Object?>();
      }
      return switch (call.method) {
        'requestPermission' => permission,
        'isRunning' => true,
        'stats' => <String, Object?>{'taps': 10, 'running': true},
        'takePendingQuestion' => <String, Object?>{
            'text': '',
            'intentRanAt': 0.0,
          },
        _ => null,
      };
    });
    _messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        // Block bodies, not arrows: an arrow returns the assigned value, which
        // the channel then tries to encode as a reply.
        onListen: (_, sink) {
          _sink = sink;
        },
        onCancel: (_) {
          _sink = null;
        },
      ),
    );
  }

  void remove() {
    _messenger.setMockMethodCallHandler(_methods, null);
    _messenger.setMockStreamHandler(_events, null);
    OrdiAudio.resetForTesting();
  }

  /// Emits one reading, exactly as the Swift side would. Fails loudly rather
  /// than dropping the event — a silent no-op here makes tests pass for the
  /// wrong reason.
  void emit({
    required String state,
    double amplitude = 0,
    String transcript = '',
    String? error,
    String? exchangeQuestion,
    String? exchangeAnswer,
  }) {
    final sink = _sink;
    if (sink == null) {
      throw StateError('Nothing is listening to ordi/audio/events yet.');
    }
    sink.success(<String, Object?>{
      'state': state,
      'amplitude': amplitude,
      'transcript': transcript,
      'error': ?error,
      'exchangeQuestion': ?exchangeQuestion,
      'exchangeAnswer': ?exchangeAnswer,
    });
  }
}

/// Lets platform messages land, then paints. pumpAndSettle is not an option —
/// the waveform animates forever.
Future<void> settle(WidgetTester tester) async {
  await tester.idle();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// First-launch setup already finished (skipped), so tests land on the
/// dashboard rather than the pairing screen.
const setUpDone = <String, Object>{
  'pairing_v1': '{"done":true,"setup":"audiosAndBand"}',
};

/// Sends one reading and lets it arrive.
///
/// The hop from the mock sink back into Dart is genuinely asynchronous, which
/// the fake clock inside a widget test will not advance on its own — hence
/// runAsync rather than another pump.
Future<void> send(
  WidgetTester tester,
  FakeAudio audio, {
  required String state,
  double amplitude = 0,
  String transcript = '',
  String? error,
  String? exchangeQuestion,
  String? exchangeAnswer,
}) async {
  await tester.runAsync(() async {
    audio.emit(
      state: state,
      amplitude: amplitude,
      transcript: transcript,
      error: error,
      exchangeQuestion: exchangeQuestion,
      exchangeAnswer: exchangeAnswer,
    );
    await Future<void>.delayed(Duration.zero);
  });
  await settle(tester);
}

/// Ordi lives behind the dashboard now, so most tests have to walk there.
Future<void> openOrdi(WidgetTester tester) async {
  // The label sits inside the card; the tap target is the card's overlay, so
  // the finder can legitimately miss the text's own box.
  await tester.tap(find.text('Conversate'), warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await settle(tester);
}

void main() {
  late FakeAudio audio;

  setUp(() {
    SharedPreferences.setMockInitialValues(setUpDone);
    // Never let a widget test make a real network call.
    OrdiBackend.stub = () async =>
        const SessionToken(token: 'test-token', model: 'test-model');
    // Summarising a finished session is fire-and-forget background work —
    // returning null here is exactly what a real failure looks like from the
    // log's point of view, and keeps tests from reaching the network.
    OrdiBackend.insightsStub = (transcript) async => null;
  });

  tearDown(() {
    audio.remove();
    OrdiBackend.stub = null;
    OrdiBackend.insightsStub = null;
  });

  group('the dashboard', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('cards show the Audios and the Band; the selector is Mobile / Band',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      // The two wearables. Nothing is paired in a test, so each invites
      // pairing rather than showing a made-up battery.
      expect(find.text('AUDIOS'), findsOneWidget);
      expect(find.text('BAND'), findsOneWidget);
      expect(find.text('Tap to pair'), findsNWidgets(2));
      expect(find.textContaining('%'), findsNothing);
      // Where Ordi runs: the phone or the Band.
      expect(find.text('Mobile'), findsOneWidget);
      expect(find.text('Band'), findsOneWidget);
    });

    testWidgets('a first launch shows setup instead of the dashboard',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(find.text('Set up Ordinary'), findsOneWidget);
      expect(find.text('Audios + Band'), findsOneWidget);
      expect(find.text('Audios only'), findsOneWidget);
      expect(find.text('Conversate'), findsNothing);
    });

    testWidgets('with the Audios alone there is no Band choice or Study Mode',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'pairing_v1': '{"done":true,"setup":"audiosOnly"}',
      });
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(find.text('Add a Band'), findsOneWidget);
      expect(find.text('Mobile'), findsNothing);
      expect(find.text('Study Mode'), findsNothing);
    });

    testWidgets('Study Mode and sync are offered only with the Band selected',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      // Band is the default.
      expect(find.text('Study Mode'), findsOneWidget);
      expect(find.text('Sync'), findsOneWidget);

      await tester.tap(find.text('Mobile'));
      await tester.pumpAndSettle();
      expect(find.text('Study Mode'), findsNothing);
      expect(find.text('Sync'), findsNothing);
      expect(find.text('Conversate'), findsOneWidget);
      expect(find.text('Recordings'), findsOneWidget);

      await tester.tap(find.text('Band'));
      await tester.pumpAndSettle();
      expect(find.text('Study Mode'), findsOneWidget);
    });

    testWidgets('speed dial opens to show each name and number', (tester) async {
      SharedPreferences.setMockInitialValues({
        ...setUpDone,
        'speed_dial_contacts_v1':
            '[{"name":"Sai Surya Charan","phone":"+91 98765 43210"}]',
      });
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();

      // Folded: the initial and the first name, no number.
      expect(find.text('S'), findsOneWidget);
      expect(find.text('Sai'), findsOneWidget);
      expect(find.text('+91 98765 43210'), findsNothing);

      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      expect(find.text('Sai Surya Charan'), findsOneWidget);
      expect(find.text('+91 98765 43210'), findsOneWidget);
      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
    });

    testWidgets('shows identity and balance', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(find.text('Ordinary'), findsOneWidget);
      // Credits are a plain grouped number in a pill — no bolt icon.
      expect(find.text('1,350'), findsOneWidget);
      expect(find.byIcon(Icons.bolt_rounded), findsNothing);
    });

    testWidgets('the O beside the credits opens settings with voices and languages',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await tester.tap(find.text('O'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Settings'), findsOneWidget);
      // Profile and credits come first.
      expect(find.text('PROFILE'), findsOneWidget);
      expect(find.text('CREDITS'), findsOneWidget);
      expect(find.text('1,350'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Puck'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Charon'), findsOneWidget);
      expect(find.text('Puck'), findsOneWidget);
      // The languages sit below the fold of a lazily built list.
      await tester.scrollUntilVisible(find.text('தமிழ்'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('हिन्दी'), findsOneWidget);
      expect(find.text('தமிழ்'), findsOneWidget);
    });

    testWidgets('tapping a voice loads, then shows it speaking, then settles',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await tester.tap(find.text('O'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final controller = tester
          .widget<OrdiScope>(find.byType(OrdiScope).first)
          .controller;

      // Voices sit below Profile, Credits and Devices.
      await tester.ensureVisible(find.text('Puck'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Puck'));
      await tester.pump(const Duration(milliseconds: 50));
      // Switching: the tile is showing its loader, and there is no status text.
      expect(find.byKey(const ValueKey('loading')), findsOneWidget);
      expect(find.textContaining('Switching'), findsNothing);
      // Let the switch itself finish; the sample starts after that.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      // Ordi starts saying the sample.
      controller.reading.value = const Reading(OrdiState.speaking, 0.6);
      await tester.pump(); // rebuild
      await tester.pump(const Duration(milliseconds: 250)); // cross-fade
      expect(find.byKey(const ValueKey('speaking')), findsOneWidget);
      expect(find.byKey(const ValueKey('loading')), findsNothing);

      // A pause inside a sentence does not end it…
      controller.reading.value = const Reading(OrdiState.idle, 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('speaking')), findsOneWidget);
      // …but the sample finishing does, leaving the tick.
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('speaking')), findsNothing);
      expect(find.byKey(const ValueKey('tick')), findsOneWidget);
    });

    testWidgets('offers the ways in', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(find.textContaining('Study'), findsOneWidget);
      expect(find.text('Conversate'), findsOneWidget);
      expect(find.text('SPEED DIAL'), findsOneWidget);
    });

    testWidgets('shows an empty state until Ordi extracts a task',
        (tester) async {
      // Tasks are real now, pulled from finished conversations — there is no
      // seed content, so a fresh app has none yet. The tick-off interaction
      // itself is covered at the model level, in the AiBrief group below.
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      // The dashboard is a lazy list and the task section is its last item, so
      // it is only built once scrolled to — the Recordings card added above it
      // is what pushed it past the test viewport.
      final empty = find.textContaining('pull tasks out of your conversations');
      await tester.scrollUntilVisible(empty, 200);
      expect(empty, findsOneWidget);
    });
  });

  group('speed dial', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('add button opens the contact picker without crashing',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_contacts'),
        (call) async => null,
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('flutter_contacts'), null);
      });

      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('study mode', () {
    setUp(() {
      audio = FakeAudio()..install();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (call) async => 1,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    });

    testWidgets('a chapter and a note added there are both reachable',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await tester.tap(find.text('Study Mode'), warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Biology');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Biology'), findsOneWidget);

      await tester.tap(find.text('Biology'), warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      // Note authoring is a two-step wizard now: name first, then content.
      // The Next/Save buttons are enabled based on the controller's value,
      // so a pump is needed between entering text and tapping — otherwise
      // the tap can land while the button is still disabled from stale state.
      await tester.enterText(find.byType(TextField).first, 'Cell structure');
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first,
          'Mitochondria is the powerhouse of the cell.');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Cell structure'), findsOneWidget);
    });
  });

  group('history', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('reachable from the small icon on Conversate', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await tester.tap(find.byIcon(Icons.history_rounded));
      await tester.pumpAndSettle();

      expect(find.text('History'), findsOneWidget);
    });

    testWidgets(
        'a finished exchange is recorded and its detail is reachable',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      // This is the pair the native side sends on the one frame where a turn
      // just finished — everything downstream (the log, both screens) is
      // exercised by nothing more than that single frame arriving.
      await send(
        tester,
        audio,
        state: 'idle',
        exchangeQuestion: 'What is the capital of France?',
        exchangeAnswer: 'The capital of France is Paris.',
      );

      await tester.tap(find.byIcon(Icons.history_rounded));
      await tester.pumpAndSettle();

      // Untitled — the stubbed backend returns null, same as a real failure
      // would — so the row is named after the first question asked, with the
      // exchange count underneath.
      final sessionRow = find.text('What is the capital of France?');
      expect(sessionRow, findsOneWidget);
      expect(find.textContaining('1 exchange'), findsOneWidget);

      // As elsewhere in this file: the label sits inside a GlassSurface
      // card, whose own full-card tap overlay is what actually receives the
      // tap, not the text's own box.
      await tester.tap(sessionRow, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Once as the screen title, once as the question itself.
      expect(find.text('What is the capital of France?'), findsNWidgets(2));
      expect(find.text('The capital of France is Paris.'), findsOneWidget);
    });
  });

  group('AiBrief', () {
    test('addExtracted skips duplicates case-insensitively', () {
      final brief = AiBrief();
      brief.addExtracted(['Call mom', 'call MOM', 'Buy milk']);
      expect(brief.tasks.map((t) => t.title), ['Call mom', 'Buy milk']);
    });

    test('toggle flips done without touching anything else', () {
      final brief = AiBrief();
      brief.addExtracted(['Call mom']);
      expect(brief.tasks.single.done, isFalse);

      brief.toggle(0);
      expect(brief.tasks.single.done, isTrue);

      brief.toggle(0);
      expect(brief.tasks.single.done, isFalse);
    });
  });

  group('ConversationLog', () {
    test('a session can be deleted', () {
      final log = ConversationLog();
      addTearDown(log.dispose);
      log.add('What time is it?', "It's noon.");
      log.remove(log.sessions.single);
      expect(log.sessions, isEmpty);
    });

    test('a finished session that never got a title is asked for again', () async {
      final old = DateTime.now().subtract(const Duration(hours: 2)).toIso8601String();
      SharedPreferences.setMockInitialValues({
        ...setUpDone,
        'conversation_sessions_v1': '[{"id":"1","startedAt":"$old","endedAt":"$old",'
            '"entries":[{"at":"$old","question":"capital of France?","answer":"Paris."}]}]',
      });
      var asked = 0;
      OrdiBackend.insightsStub = (transcript) async {
        asked++;
        return const SessionInsights(title: 'France', summary: 'Asked about Paris.', tasks: []);
      };
      final log = ConversationLog();
      addTearDown(log.dispose);
      await log.load();
      await Future<void>.delayed(Duration.zero);
      expect(asked, 1);
      expect(log.sessions.single.title, 'France');

      // Opening History again does not ask a second time.
      log.retryMissingTitles();
      await Future<void>.delayed(Duration.zero);
      expect(asked, 1);
    });

    test('exchanges close together in time join the same session', () {
      final log = ConversationLog();
      addTearDown(log.dispose);
      log.add('What time is it?', "It's noon.");
      log.add('And in Tokyo?', "It's 9 PM there.");

      expect(log.sessions.length, 1);
      expect(log.sessions.single.entries.length, 2);
    });
  });

  group('audio, regardless of which screen is showing', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('switching voice fetches the new token before closing the old session',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      final controller = tester
          .widget<OrdiScope>(find.byType(OrdiScope).first)
          .controller;
      expect(controller.connected, isTrue);
      audio.calls.clear();

      var tokenRequests = 0;
      OrdiBackend.stub = () async {
        // At the moment the token is being fetched, nothing has been torn down.
        expect(audio.calls, isNot(contains('disconnect')));
        tokenRequests++;
        return const SessionToken(token: 'new-token', model: 'test-model');
      };

      final ok = await tester.runAsync(() => controller.restart(introduce: true));
      expect(ok, isTrue);
      expect(tokenRequests, 1);
      // Close then open, in that order, and then the hello — sent only after
      // the connect so the native layer can hold it until the session is ready.
      expect(audio.calls, containsAllInOrder(['disconnect', 'connect', 'ask']));
    });

    testWidgets('tapping through several voices quickly lands on the last one, once',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      final controller = tester
          .widget<OrdiScope>(find.byType(OrdiScope).first)
          .controller;
      audio.calls.clear();

      var tokenRequests = 0;
      OrdiBackend.stub = () async {
        tokenRequests++;
        return const SessionToken(token: 'new-token', model: 'test-model');
      };

      final results = await tester.runAsync(() => Future.wait([
            controller.restart(introduce: true),
            controller.restart(introduce: true),
            controller.restart(introduce: true),
          ]));

      // The two it overtook stand down; the last one does the switch — one
      // token, one reconnect, one hello.
      expect(results, [false, false, true]);
      expect(tokenRequests, 1);
      expect(audio.calls.where((c) => c == 'connect'), hasLength(1));
      expect(audio.calls.where((c) => c == 'ask'), hasLength(1));
    });

    testWidgets('switching voice with no token available leaves the session alone',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      final controller = tester
          .widget<OrdiScope>(find.byType(OrdiScope).first)
          .controller;
      audio.calls.clear();

      OrdiBackend.stub = () async => throw SessionRefused('offline');
      final ok = await tester.runAsync(() => controller.restart(introduce: true));

      expect(ok, isFalse);
      expect(controller.connected, isTrue);
      expect(audio.calls, isNot(contains('disconnect')));
    });

    testWidgets('asks permission, starts capture, then connects',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(
        audio.calls,
        containsAllInOrder(['requestPermission', 'start', 'connect']),
      );
    });

    testWidgets('passes the backend token through to the engine',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(audio.connectArgs?['token'], 'test-token');
      expect(audio.connectArgs?['model'], 'test-model');
    });

    testWidgets('starts listening without opening Ordi', (tester) async {
      // The whole point of owning the controller at the app root: the
      // microphone runs from launch, not from visiting a screen.
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(audio.calls, contains('start'));
      expect(find.byType(Waveform), findsNothing);
    });
  });

  group('the Ordi screen', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('opens from Conversate', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      expect(find.byType(Waveform), findsOneWidget);
    });

    testWidgets('every native state reaches the waveform', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      for (final state in OrdiState.values) {
        await send(tester, audio, state: state.name, amplitude: 0.5);
        expect(
          tester.widget<Waveform>(find.byType(Waveform)).state,
          state,
          reason: 'native "${state.name}" should reach the waveform',
        );
      }
    });

    testWidgets('amplitude reaches the waveform', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      await send(tester, audio, state: 'listening', amplitude: 0.62);
      expect(
        tester.widget<Waveform>(find.byType(Waveform)).amplitude,
        closeTo(0.62, 0.001),
      );
    });

    testWidgets('speaking puts Ordi\'s words on screen', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      await send(tester, audio,
          state: 'speaking', transcript: 'The capital of France is Paris.');
      expect(find.text('The capital of France is Paris.'), findsOneWidget);
    });

    testWidgets('a new question clears the previous answer', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      await send(tester, audio, state: 'speaking', transcript: 'Paris.');
      expect(find.text('Paris.'), findsOneWidget);

      await send(tester, audio, state: 'listening', transcript: '');
      expect(find.text('Paris.'), findsNothing);
    });

    testWidgets('renders in every state without throwing', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      for (final state in OrdiState.values) {
        await send(tester, audio, state: state.name, amplitude: 0.5);
        expect(tester.takeException(), isNull, reason: 'threw in $state');
      }
    });
  });

  group('when a session dies', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('asks for a new one instead of going quiet', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      final before = audio.calls.where((c) => c == 'connect').length;
      expect(before, 1);

      await send(tester, audio,
          state: 'idle', error: 'Connection closed: token expired');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      final after = audio.calls.where((c) => c == 'connect').length;
      expect(after, greaterThan(before),
          reason: 'a dead session must be replaced, not left silent');
    });

    testWidgets('one dropped session stays quiet', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      await send(tester, audio, state: 'idle', error: 'Connection closed: blip');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      expect(find.textContaining('Connection closed'), findsNothing);
    });

    testWidgets('a failure that will not clear eventually reaches the user',
        (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);

      OrdiBackend.stub = () async => throw SessionRefused('Backend unreachable.');

      await send(tester, audio, state: 'idle', error: 'Connection closed: gone');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 16));
        await settle(tester);
      }
      expect(find.textContaining('Backend unreachable'), findsOneWidget);
    });
  });

  group('without the microphone', () {
    setUp(() => audio = FakeAudio(permission: false)..install());

    testWidgets('does not try to start capture or connect', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(audio.calls, isNot(contains('start')));
      expect(audio.calls, isNot(contains('connect')));
    });

    testWidgets('explains itself on the Ordi screen', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      await openOrdi(tester);
      expect(find.textContaining('microphone'), findsOneWidget);
    });
  });

  group('with no native implementation at all', () {
    // Android has none yet. The app must degrade quietly, not crash.
    setUp(() {
      audio = FakeAudio();
      OrdiAudio.resetForTesting();
    });

    testWidgets('the dashboard still renders', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Ordinary'), findsOneWidget);
    });
  });
}
