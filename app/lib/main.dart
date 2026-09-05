import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ordi_audio/ordi_audio.dart';

import 'orb.dart';
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

  StreamSubscription<AudioFrame>? _frames;

  /// The only thing that ever puts words on this screen: something is wrong
  /// and staying silent would look like a bug.
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frames?.cancel();
    _reading.dispose();
    OrdiAudio.disconnect();
    OrdiAudio.stop();
    super.dispose();
  }

  Future<void> _boot() async {
    final granted = await OrdiAudio.requestPermission();
    if (!mounted) return;

    if (!granted) {
      setState(() => _problem =
          'Ordi needs the microphone to hear you.\nEnable it in Settings.');
      return;
    }

    _frames = OrdiAudio.frames.listen(_onFrame);
    await _listen();
    await _connect();
  }

  Future<void> _listen() async {
    try {
      await OrdiAudio.start();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _problem = error.message ?? 'The microphone is busy.');
    }
  }

  /// Fetch a permit from our backend, then let the phone talk to Google
  /// directly with it.
  Future<void> _connect() async {
    try {
      final session = await OrdiBackend.requestSession();
      await OrdiAudio.connect(token: session.token, model: session.model);
      if (mounted && _problem != null) setState(() => _problem = null);
    } on SessionRefused catch (error) {
      if (!mounted) return;
      setState(() => _problem = error.message);
    }
  }

  void _onFrame(AudioFrame frame) {
    if (frame.error != null && frame.error != _problem) {
      // Errors are rare; a setState here is fine, unlike the level.
      setState(() => _problem = frame.error);
    }
    _reading.value = _Reading(_orbState(frame.state), frame.amplitude);
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
    switch (state) {
      case AppLifecycleState.resumed:
        if (_problem == null || _frames != null) {
          _listen().then((_) => _connect());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        OrdiAudio.disconnect();
        OrdiAudio.stop();
        _reading.value = _Reading.idle;
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
