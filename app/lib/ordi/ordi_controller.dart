import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ordi_audio/ordi_audio.dart';

import '../session.dart';

/// What Ordi is doing, and how loud.
class Reading {
  const Reading(this.state, this.amplitude);

  final OrdiState state;
  final double amplitude;

  static const idle = Reading(OrdiState.idle, 0);
}

/// Owns the microphone, the Gemini session, and everything that keeps them
/// alive.
///
/// **Lives for the life of the app, not the life of a screen.** This used to
/// sit inside the Ordi screen's state, which was fine when Ordi was the only
/// screen. Now that Ordi is one destination among several, a screen-owned
/// controller would tear the microphone down every time you navigated away —
/// silently undoing the background listening that took real work to get right.
///
/// Everything here was moved rather than rewritten: the foreground wait before
/// opening the mic, the reconnect backoff, the permanent-versus-transient
/// refusal split, the Siri hand-off race guard. Those were each fixed against
/// a real failure on a real phone, and none of them should be re-derived.
class OrdiController with WidgetsBindingObserver, ChangeNotifier {
  OrdiController() {
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  /// Audio arrives ~50 times a second. It goes through its own notifier so the
  /// waveform repaints alone instead of rebuilding whatever screen is showing.
  final ValueNotifier<Reading> reading = ValueNotifier(Reading.idle);

  /// The words change a few times a second, the level fifty times. Sharing one
  /// notifier would repaint text at audio rate for nothing.
  final ValueNotifier<String> transcript = ValueNotifier('');

  /// Fires once per finished exchange with the question and Ordi's full
  /// answer. Set from outside (main.dart wires it to the conversation log) —
  /// this controller only reports the exchange, it does not decide what
  /// happens to it.
  void Function(String question, String answer)? onExchange;

  /// Called right before requesting a new session, so a short digest of past
  /// conversations can ride along in the system instruction. Left unset, no
  /// memory is sent and Ordi behaves exactly as it did before this existed.
  String Function()? memoryDigest;

  /// The person's chosen voice and language, read each time a session is
  /// requested. Left unset, the backend's own defaults apply.
  ({String voice, String accent, String language}) Function()? sessionPrefs;

  /// Completes once [sessionPrefs] is reading the saved choices rather than
  /// the defaults, so the very first session uses the right voice instead of
  /// racing the settings load at launch.
  Future<void>? prefsReady;

  StreamSubscription<AudioFrame>? _frames;

  /// The only thing that ever puts an error in front of the user: something is
  /// wrong and staying silent would look like a bug.
  String? problem;

  bool _connecting = false;
  bool _connected = false;
  bool _disposed = false;

  /// The latest checkpoint the server has handed out for resuming this
  /// conversation, if any. Offered on the *next* connect attempt only — read
  /// and cleared together in [_connect] — so a handle that turns out to be
  /// too stale to resume with costs at most one wasted attempt before things
  /// fall back to exactly today's behaviour: a fresh session, same as if this
  /// had never been added.
  String? _resumptionHandle;

  bool get connected => _connected;

  /// Says something in Ordi's own voice, right now, and reports whether it
  /// could. Used for reminders falling due while the app is alive.
  ///
  /// Goes through the live session rather than the on-device synthesiser that
  /// Study Mode uses, and that choice is load-bearing: echo cancellation is
  /// wired to the audio engine's own output, so anything spoken outside it
  /// comes straight back through the microphone. Ordi would hear the reminder
  /// as the user talking, cut itself off, and answer it. This way the audio is
  /// inside the canceller, in the right voice, and interruptible like any
  /// other reply.
  Future<bool> speak(String text) async {
    if (!_connected || text.trim().isEmpty) return false;
    await OrdiAudio.ask(text);
    return true;
  }

  /// The token request, with the person's current voice, accent and language.
  Future<SessionToken> _requestSession(String? resumeHandle) async {
    // Bounded: a stuck preferences read must delay the first session by at
    // most a moment, never stop Ordi from connecting at all.
    await prefsReady?.timeout(const Duration(milliseconds: 750),
        onTimeout: () {});
    final prefs = sessionPrefs?.call();
    return OrdiBackend.requestSession(
      memory: memoryDigest?.call(),
      resumeHandle: resumeHandle,
      voice: prefs?.voice,
      accent: prefs?.accent,
      language: prefs?.language,
    );
  }

  /// Opens a fresh session so a changed voice or language takes effect now
  /// rather than at the next natural reconnect, up to half an hour away — the
  /// voice is pinned into the session token, so there is no other way.
  ///
  /// Make-before-break: the new token is fetched while the old session is
  /// still up, and only then is the old one closed and the new one opened. The
  /// switch is therefore just "close, open" — the network round trip for the
  /// token is no longer added on top — and if the token cannot be had, the old
  /// session simply carries on and nothing is lost.
  ///
  /// Otherwise it reuses exactly the paths a dropped connection takes: the old
  /// socket is closed (which detaches its callbacks, so nothing stale can mark
  /// the new one dead) and [_connect] is called as usual. The resumption
  /// handle is dropped on purpose — resuming would carry the old session's
  /// voice. Capture is not touched.
  ///
  /// When [introduce] is set Ordi says one line in the new voice. That message
  /// is sent straight after connecting; the native layer holds it until the
  /// session is actually ready, so it is spoken as soon as it can be.
  /// Returns false when there was nothing to restart or it did not work.
  Future<bool> restart({bool introduce = false}) {
    // Latest request wins. Tapping through several voices in a row queues
    // them one behind another, and every one but the last is skipped as soon
    // as its turn comes — so the switch always lands on the voice tapped last,
    // and never runs two restarts on top of each other.
    final request = ++_restartRequests;
    final run = _restartQueue.then((_) => _restartNow(request, introduce));
    _restartQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  int _restartRequests = 0;
  Future<void> _restartQueue = Future.value();

  Future<bool> _restartNow(int request, bool introduce) async {
    if (request != _restartRequests) return false; // superseded
    if (_disposed || _frames == null || _connecting) return false;

    SessionToken session;
    try {
      session = await _requestSession(null);
    } on SessionRefused {
      return false;
    }
    // Something newer was asked for while the token was on its way; it will
    // fetch its own, so hand this one back unused rather than switch twice.
    if (_disposed || request != _restartRequests) return false;

    _retry?.cancel();
    _resumptionHandle = null;
    _connected = false;
    await OrdiAudio.disconnect();
    await _connect(prefetched: session);
    if (introduce && _connected && request == _restartRequests) {
      await speak('[ordi] hello');
    }
    return _connected;
  }

  /// Sessions do not last forever — the token expires and networks drop.
  /// Without this the first failure is permanent.
  Timer? _retry;
  int _attempts = 0;

  /// Tells "nothing is being produced" apart from "it is produced but not
  /// arriving", which is what identified the deaf-microphone bug.
  Timer? _heartbeat;
  int _frameCount = 0;
  double _lastAmplitude = 0;

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _heartbeat?.cancel();
    _frames?.cancel();
    reading.dispose();
    transcript.dispose();
    OrdiAudio.disconnect();
    OrdiAudio.stop();
    super.dispose();
  }

  void _update(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  // ------------------------------------------------------------------ boot

  Future<void> _boot() async {
    OrdiBackend.diag('boot');
    final granted = await OrdiAudio.requestPermission();
    OrdiBackend.diag('permission', granted);
    if (_disposed) return;

    if (!granted) {
      _update(() => problem =
          'Ordi needs the microphone to hear you.\nEnable it in Settings.');
      return;
    }

    _frames = OrdiAudio.frames.listen(_onFrame);
    OrdiBackend.diag('subscribed');

    // Opening the microphone while the app is still launching returns an
    // engine that reports success and then delivers no audio at all. Waiting
    // for the app to actually be frontmost is what fixed "I have to switch
    // apps and come back before it hears me".
    await _whenForeground();

    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) async {
      final native = await OrdiAudio.stats();
      OrdiBackend.diag('heartbeat', {
        'frames': _frameCount,
        'amp': _lastAmplitude.toStringAsFixed(3),
        'state': reading.value.state.name,
        'native': native.map((k, v) => MapEntry('$k', v)),
      });
      _frameCount = 0;
    });

    await _listen();
    await _connect();
  }

  /// Resolves once the app is genuinely frontmost. A null lifecycle state
  /// means the platform has not reported one — true in widget tests, and not
  /// a reason to block.
  Future<void> _whenForeground() async {
    bool ready() {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    }

    if (ready()) return;
    OrdiBackend.diag(
        'waiting-for-foreground', WidgetsBinding.instance.lifecycleState?.name);

    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_disposed || ready()) return;
    }
  }

  Future<void> _listen() async {
    try {
      await OrdiAudio.start();
      OrdiBackend.diag('mic-started');
    } on PlatformException catch (error) {
      OrdiBackend.diag('mic-failed', error.message);
      _update(() => problem = error.message ?? 'The microphone is busy.');
    }
  }

  // --------------------------------------------------------------- session

  /// Fetch a permit from our backend, then let the phone talk to Google
  /// directly with it.
  Future<void> _connect({SessionToken? prefetched}) async {
    if (_connecting || _connected) return;
    _connecting = true;
    // Used at most once: if this attempt doesn't pan out, the next one goes
    // in with no handle at all rather than retrying the same one.
    final handle = _resumptionHandle;
    _resumptionHandle = null;
    try {
      final session = prefetched ?? await _requestSession(handle);
      OrdiBackend.diag('resuming', handle != null);
      await OrdiAudio.connect(token: session.token, model: session.model);
      _connected = true;
      _attempts = 0;
      OrdiBackend.diag('connected');
      await _askPendingQuestion();
      if (problem != null) _update(() => problem = null);
    } on SessionRefused catch (error) {
      if (error.permanent) {
        // Retrying a spent cap or a wrong key cannot succeed — say so now.
        _connected = false;
        _update(() => problem = error.message);
      } else {
        _scheduleReconnect(error.message);
      }
    } finally {
      _connecting = false;
    }
  }

  /// Guards connecting and resuming from racing each other for a Siri
  /// question: reading it clears it, so the loser finds nothing and the
  /// question would be silently dropped.
  bool _collecting = false;

  Future<void> _askPendingQuestion() async {
    if (_collecting) return;
    _collecting = true;
    try {
      final pending = await OrdiAudio.takePendingQuestion();
      OrdiBackend.diag('siri-check', {
        'found': pending.text != null,
        'intentRan': pending.intentRanAt > 0,
      });
      final question = pending.text;
      if (question == null) return;
      await OrdiAudio.ask(question);
    } finally {
      _collecting = false;
    }
  }

  /// Back off, then try again.
  ///
  /// Most drops are an expired token or a moment of bad signal. Recovering
  /// quietly beats showing an error for something that fixes itself in a
  /// second, so the message only appears once failures stop looking transient.
  void _scheduleReconnect([String? reason]) {
    OrdiBackend.diag('reconnect', {'attempt': _attempts, 'why': reason});
    _connected = false;
    _retry?.cancel();

    const backoff = [1, 2, 4, 8, 15];
    final wait = Duration(seconds: backoff[min(_attempts, backoff.length - 1)]);
    _attempts += 1;

    if (_attempts > 3 && reason != null && problem != reason) {
      _update(() => problem = reason);
    }

    _retry = Timer(wait, () {
      if (!_disposed) _connect();
    });
  }

  // ----------------------------------------------------------------- audio

  void _onFrame(AudioFrame frame) {
    if (_frameCount == 0) {
      OrdiBackend.diag('frame', {
        'state': frame.state.name,
        'amp': frame.amplitude.toStringAsFixed(3),
      });
    }
    _frameCount += 1;
    _lastAmplitude = frame.amplitude;

    if (frame.wake) {
      OrdiBackend.diag('wake-word');
      if (!_connected) _connect();
    }

    if (frame.error != null) {
      _scheduleReconnect(frame.error);
    }

    if (frame.state != reading.value.state) {
      OrdiBackend.diag('state', frame.state.name);
    }
    reading.value = Reading(frame.state, frame.amplitude);
    if (frame.transcript != transcript.value) {
      transcript.value = frame.transcript;
    }

    final question = frame.exchangeQuestion;
    final answer = frame.exchangeAnswer;
    if (question != null && answer != null) {
      onExchange?.call(question, answer);
    }

    if (frame.resumptionHandle != null) {
      _resumptionHandle = frame.resumptionHandle;
    }
  }

  // ------------------------------------------------------------- lifecycle

  /// Deliberately keeps listening in the background. With
  /// `UIBackgroundModes: audio` the session survives leaving the foreground,
  /// which is what makes Ordi available while the app sits in the switcher.
  ///
  /// It is not free: the microphone stays open and audio keeps streaming at
  /// roughly $0.005/min whether or not anyone is talking.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    OrdiBackend.diag('lifecycle', state.name);
    switch (state) {
      case AppLifecycleState.resumed:
        _attempts = 0;
        // Audio was never stopped, so this only repairs a session that died
        // while we were away; both calls are no-ops when things are healthy.
        if (_frames != null) {
          _listen().then((_) => _connect());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        break;

      case AppLifecycleState.detached:
        _retry?.cancel();
        OrdiAudio.disconnect();
        OrdiAudio.stop();
        _connected = false;
        reading.value = Reading.idle;
        transcript.value = '';
    }
  }
}
