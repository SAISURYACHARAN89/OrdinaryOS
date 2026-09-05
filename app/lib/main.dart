import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ordi_audio/ordi_audio.dart';

import 'orb.dart';
import 'spoken_text.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const OrdiApp());
}

class OrdiApp extends StatelessWidget {
  const OrdiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ordi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF07080C),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

/// What the orb is showing right now.
class _Reading {
  const _Reading(this.state, this.amplitude);

  final OrbState state;
  final double amplitude;

  static const idle = _Reading(OrbState.idle, 0);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Audio arrives ~50 times a second. Pushing that through setState would
  // rebuild the whole screen at 50Hz for values only the orb consumes, so it
  // goes through a notifier and repaints the orb alone.
  final ValueNotifier<_Reading> _reading = ValueNotifier(_Reading.idle);

  // Separate notifier: the words change a few times a second, the level
  // changes fifty times a second. Sharing one would repaint the text at
  // audio rate for no reason.
  final ValueNotifier<String> _transcript = ValueNotifier('');

  StreamSubscription<AudioFrame>? _frames;

  /// The only thing that ever puts words on this screen: something is wrong
  /// and staying silent would look like a bug.
  String? _problem;

  /// Guards against overlapping session requests. Boot and the first resume
  /// both fire on launch, and two connects means the second kills the first
  /// mid-send.
  bool _connecting = false;
  bool _connected = false;

  /// Sessions do not last forever: the token expires after ten minutes, and
  /// networks drop. Without this the first failure is permanent — Ordi goes
  /// quiet and only comes back if the app is backgrounded and reopened.
  Timer? _retry;
  int _attempts = 0;

  // Counts what actually arrives from native, so "the orb is dead" can be told
  // apart from "the orb is fine but nothing is being sent to it".
  Timer? _heartbeat;
  int _frameCount = 0;
  double _lastAmplitude = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _heartbeat?.cancel();
    _frames?.cancel();
    _reading.dispose();
    _transcript.dispose();
    OrdiAudio.disconnect();
    OrdiAudio.stop();
    super.dispose();
  }

  Future<void> _boot() async {
    OrdiBackend.diag('boot');
    final granted = await OrdiAudio.requestPermission();
    OrdiBackend.diag('permission', granted);
    if (!mounted) return;

    if (!granted) {
      setState(() => _problem =
          'Ordi needs the microphone to hear you.\nEnable it in Settings.');
      return;
    }

    _frames = OrdiAudio.frames.listen(_onFrame);
    OrdiBackend.diag('subscribed');

    // Starting the microphone while the app is still launching gives back an
    // engine that reports success and then delivers no audio at all. That is
    // why switching away and back used to be the only way to wake Ordi up.
    // Wait for the app to actually be in front before opening the mic.
    await _whenForeground();
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) async {
      final native = await OrdiAudio.stats();
      OrdiBackend.diag('heartbeat', {
        'frames': _frameCount,
        'amp': _lastAmplitude.toStringAsFixed(3),
        'orb': _reading.value.state.name,
        'native': native.map((k, v) => MapEntry('$k', v)),
      });
      _frameCount = 0;
    });
    await _listen();
    await _connect();
  }

  /// Resolves once the app is genuinely frontmost.
  ///
  /// On a cold launch the lifecycle state is often still `inactive` when boot
  /// runs, and audio started in that window never produces input.
  Future<void> _whenForeground() async {
    // Null means the platform has not reported a state — true in widget tests,
    // and not a reason to block.
    bool ready() {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    }

    if (ready()) return;
    OrdiBackend.diag('waiting-for-foreground',
        WidgetsBinding.instance.lifecycleState?.name);

    // Poll briefly rather than wiring a completer through the observer: this
    // runs once, at launch, and never on the audio path.
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      if (ready()) return;
    }
  }

  Future<void> _listen() async {
    try {
      await OrdiAudio.start();
      OrdiBackend.diag('mic-started');
    } on PlatformException catch (error) {
      OrdiBackend.diag('mic-failed', error.message);
      if (!mounted) return;
      setState(() => _problem = error.message ?? 'The microphone is busy.');
    }
  }

  /// Fetch a permit from our backend, then let the phone talk to Google
  /// directly with it.
  Future<void> _connect() async {
    if (_connecting || _connected) return;
    _connecting = true;
    try {
      final session = await OrdiBackend.requestSession();
      await OrdiAudio.connect(token: session.token, model: session.model);
      _connected = true;
      _attempts = 0;
      OrdiBackend.diag('connected');
      await _askPendingQuestion();
      if (mounted && _problem != null) setState(() => _problem = null);
    } on SessionRefused catch (error) {
      if (error.permanent) {
        // Nothing to wait for — say so now.
        _connected = false;
        if (mounted) setState(() => _problem = error.message);
      } else {
        _scheduleReconnect(error.message);
      }
    } finally {
      _connecting = false;
    }
  }

  /// If Siri collected a question before the app was running, ask it now that
  /// there is a session to ask it through.
  /// Guards the two callers below from racing each other: connecting and
  /// resuming both want to collect a Siri question, and they can arrive
  /// milliseconds apart. Reading clears the value, so whichever loses the race
  /// finds nothing and the question is silently dropped.
  bool _collecting = false;

  Future<void> _askPendingQuestion() async {
    if (_collecting) return;
    _collecting = true;
    try {
      await _collectAndAsk();
    } finally {
      _collecting = false;
    }
  }

  Future<void> _collectAndAsk() async {
    final pending = await OrdiAudio.takePendingQuestion();
    OrdiBackend.diag('siri-check', {
      'found': pending.text != null,
      'intentRan': pending.intentRanAt > 0,
    });
    final question = pending.text;
    if (question == null) return;
    await OrdiAudio.ask(question);
  }

  /// Back off, then try again.
  ///
  /// Most drops are a expired token or a moment of bad signal, and recovering
  /// silently is far better than showing the user an error for something that
  /// fixes itself in a second. The message only appears once it stops looking
  /// transient — otherwise every ten-minute token refresh would flash a
  /// warning at someone mid-conversation.
  void _scheduleReconnect([String? reason]) {
    OrdiBackend.diag('reconnect', {'attempt': _attempts, 'why': reason});
    _connected = false;
    _retry?.cancel();

    const backoff = [1, 2, 4, 8, 15];
    final wait = Duration(seconds: backoff[min(_attempts, backoff.length - 1)]);
    _attempts += 1;

    if (_attempts > 3 && reason != null && mounted && _problem != reason) {
      setState(() => _problem = reason);
    }

    _retry = Timer(wait, () {
      if (mounted) _connect();
    });
  }

  void _onFrame(AudioFrame frame) {
    if (_frameCount == 0) {
      OrdiBackend.diag('frame', {
        'state': frame.state.name,
        'amp': frame.amplitude.toStringAsFixed(3),
      });
    }
    _frameCount += 1;
    _lastAmplitude = frame.amplitude;

    if (frame.error != null) {
      // The session is gone. Get another one rather than sitting silent.
      _scheduleReconnect(frame.error);
    }
    final next = _orbState(frame.state);
    if (next != _reading.value.state) {
      OrdiBackend.diag('state', next.name);
    }
    _reading.value = _Reading(next, frame.amplitude);
    if (frame.transcript != _transcript.value) {
      _transcript.value = frame.transcript;
    }
  }

  static OrbState _orbState(OrdiState state) => switch (state) {
        OrdiState.idle => OrbState.idle,
        OrdiState.listening => OrbState.listening,
        OrdiState.thinking => OrbState.thinking,
        OrdiState.speaking => OrbState.speaking,
      };

  /// Hold the microphone only while the app is actually in front. Keeping the
  /// session open in the background drains battery and, on iOS, risks the
  /// system tearing it down in ways harder to recover from than a clean
  /// restart.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    OrdiBackend.diag('lifecycle', state.name);
    switch (state) {
      case AppLifecycleState.resumed:
        _attempts = 0;
        if (_frames != null) {
          _listen().then((_) async {
            await _connect();
            // Siri may have handed us a question while we were away.
            await _askPendingQuestion();
          });
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _retry?.cancel();
        OrdiAudio.disconnect();
        OrdiAudio.stop();
        _connected = false;
        _reading.value = _Reading.idle;
        _transcript.value = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 0.9,
            colors: [Color(0xFF0E1018), Color(0xFF07080C)],
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: ValueListenableBuilder<_Reading>(
                valueListenable: _reading,
                builder: (context, reading, _) => Orb(
                  state: reading.state,
                  amplitude: reading.amplitude,
                  size: MediaQuery.sizeOf(context).width * 0.72,
                ),
              ),
            ),
            // What Ordi is saying, as it says it. A window that follows the
            // end of the answer — older lines scroll up and dissolve rather
            // than the block growing until it crowds the orb.
            Positioned(
              left: 30,
              right: 30,
              bottom: 88,
              child: ValueListenableBuilder<String>(
                valueListenable: _transcript,
                builder: (context, text, _) => SpokenText(text: text),
              ),
            ),
            if (_problem != null)
              Positioned(
                left: 32,
                right: 32,
                bottom: 64,
                child: Text(
                  _problem!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
