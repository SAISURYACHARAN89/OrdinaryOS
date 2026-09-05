import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ordi_audio/ordi_audio.dart';

import 'package:ordi/main.dart';
import 'package:ordi/orb.dart';
import 'package:ordi/session.dart';

/// Stands in for the native engine. The orb is driven entirely by what the
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
    });
  }
}

/// Lets platform messages land, then paints. pumpAndSettle is not an option —
/// the orb animates forever.
Future<void> settle(WidgetTester tester) async {
  await tester.idle();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

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
}) async {
  await tester.runAsync(() async {
    audio.emit(
      state: state,
      amplitude: amplitude,
      transcript: transcript,
      error: error,
    );
    await Future<void>.delayed(Duration.zero);
  });
  await settle(tester);
}

void main() {
  late FakeAudio audio;

  setUp(() {
    // Never let a widget test make a real network call.
    OrdiBackend.stub = () async =>
        const SessionToken(token: 'test-token', model: 'test-model');
  });

  tearDown(() {
    audio.remove();
    OrdiBackend.stub = null;
  });

  group('with the microphone available', () {
    setUp(() => audio = FakeAudio()..install());

    testWidgets('app boots and shows the orb', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(find.byType(Orb), findsOneWidget);
    });

    testWidgets('orb starts idle', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(tester.widget<Orb>(find.byType(Orb)).state, OrbState.idle);
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

    testWidgets('every native state reaches the orb', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      const mapping = {
        'listening': OrbState.listening,
        'thinking': OrbState.thinking,
        'speaking': OrbState.speaking,
        'idle': OrbState.idle,
      };

      for (final entry in mapping.entries) {
        await send(tester, audio, state: entry.key, amplitude: 0.5);
        expect(
          tester.widget<Orb>(find.byType(Orb)).state,
          entry.value,
          reason: 'native "${entry.key}" should map to ${entry.value}',
        );
      }
    });

    testWidgets('amplitude reaches the orb', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await send(tester, audio, state: 'listening', amplitude: 0.62);
      expect(
        tester.widget<Orb>(find.byType(Orb)).amplitude,
        closeTo(0.62, 0.001),
      );
    });

    testWidgets('shows no words at all while idle', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      // The transcript widget always exists; what matters is that nothing is
      // readable on screen when Ordi is resting.
      final visible = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => (t.data ?? '').isNotEmpty);
      expect(visible, isEmpty);
    });

    testWidgets('speaking puts Ordi\'s words on screen', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await send(tester, audio,
          state: 'speaking', transcript: 'The capital of France is Paris.');
      expect(find.text('The capital of France is Paris.'), findsOneWidget);
    });

    testWidgets('a new question clears the previous answer', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await send(tester, audio, state: 'speaking', transcript: 'Paris.');
      expect(find.text('Paris.'), findsOneWidget);

      // Native clears the transcript when the user starts a new turn.
      await send(tester, audio, state: 'listening', transcript: '');
      expect(find.text('Paris.'), findsNothing);
    });

    testWidgets('a native error is surfaced to the user', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      await send(tester, audio, state: 'idle', error: 'Connection closed: nope');
      expect(find.textContaining('Connection closed'), findsOneWidget);
    });
  });

  group('when the backend refuses', () {
    setUp(() {
      audio = FakeAudio()..install();
      OrdiBackend.stub = () async => throw SessionRefused('Daily limit reached.');
    });

    testWidgets('says so instead of failing silently', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(find.textContaining('Daily limit'), findsOneWidget);
    });

    testWidgets('capture still runs, so the orb stays alive', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(audio.calls, contains('start'));
      expect(find.byType(Orb), findsOneWidget);
    });
  });

  group('without the microphone', () {
    setUp(() => audio = FakeAudio(permission: false)..install());

    testWidgets('explains itself rather than sitting silently', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(find.textContaining('microphone'), findsOneWidget);
    });

    testWidgets('does not try to start capture or connect', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);
      expect(audio.calls, isNot(contains('start')));
      expect(audio.calls, isNot(contains('connect')));
    });
  });

  group('with no native implementation at all', () {
    // Android has none yet. The app must degrade to a quiet orb, not crash.
    setUp(() {
      audio = FakeAudio();
      OrdiAudio.resetForTesting();
    });

    testWidgets('still renders and stays idle', (tester) async {
      await tester.pumpWidget(const OrdiApp());
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(tester.widget<Orb>(find.byType(Orb)).state, OrbState.idle);
    });
  });

  testWidgets('orb renders in every state without throwing', (tester) async {
    audio = FakeAudio()..install();
    for (final state in OrbState.values) {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Orb(state: state, amplitude: 0.5))),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: 'threw in $state');
    }
  });
}
