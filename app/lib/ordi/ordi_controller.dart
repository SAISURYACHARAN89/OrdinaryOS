import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
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
  OrdiController({this.startGate}) {
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  /// When set, nothing starts — not even the microphone permission prompt —
  /// until this completes. First-launch setup uses it to ask for the
  /// microphone on its own screen, with an explanation, instead of iOS
  /// popping the prompt over whatever happens to be showing at launch.
  final Future<void>? startGate;

  /// Completes with whether the microphone was allowed, once asked.
  Future<bool> get micPermission => _micPermission.future;
  final Completer<bool> _micPermission = Completer<bool>();

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
  ({String voice, String accent, String language, String name}) Function()?
      sessionPrefs;

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

  /// True when the person has refused the microphone — something only they
  /// can fix, in iOS Settings, unlike every other problem here.
  bool micDenied = false;
  bool _disposed = false;

  /// The latest checkpoint the server has handed out for resuming this
  /// conversation, if any. Offered on the *next* connect attempt only — read
  /// and cleared together in [_connect] — so a handle that turns out to be
  /// too stale to resume with costs at most one wasted attempt before things
  /// fall back to exactly today's behaviour: a fresh session, same as if this
  /// had never been added.
  String? _resumptionHandle;

  /// A session is open — or Ordinary is on standby, which the person should
  /// not be able to tell apart from one: it is listening, and the first word
  /// opens a session that hears what was said.
  bool get connected => _connected || _standby;

  // ------------------------------------------------------------ standby

  /// On standby there is no session: the microphone is still listening on the
  /// phone, and the first sound opens one. See [_maybeStandBy].
  bool _standby = false;
  bool get onStandby => _standby;

  /// When someone was last heard, or Ordinary last spoke.
  DateTime _lastSoundAt = clock.now();
  String? _lastRoute;

  /// A level this high, for this many frames in a row (about a fifth of a
  /// second), is someone making a sound: the same bar the engine uses.
  static const soundLevel = 0.14;
  static const soundFrames = 2;
  int _loudFrames = 0;

  /// How long nothing has to be said before the session is released.
  static const standbyAfter = Duration(seconds: 60);

  /// Says a session must stay open whatever the silence — a recording in
  /// progress has to keep transcribing.
  bool Function()? keepSessionOpen;

  /// Only so many sessions can be open at once across everyone using
  /// Ordinary, and a session sitting in a silent room holds one of them for
  /// nothing. So after a quiet minute it is closed. The microphone keeps
  /// running on the phone; the first sound opens a new session, and the last
  /// few seconds of audio are replayed into it, so "Hey Ordinary…" said out of
  /// the silence is heard from its first word. The conversation is resumed
  /// from its checkpoint unless it had gone stale anyway.
  void _maybeStandBy() {
    if (_disposed || _held || !_connected || _connecting || _standby) return;
    if (reading.value.state != OrdiState.idle) return;
    if (keepSessionOpen?.call() ?? false) return;
    final now = clock.now();
    if (now.difference(_lastSoundAt) < standbyAfter) return;

    // Nobody has addressed Ordinary for a while either: what the session
    // holds is room noise, not a conversation worth resuming.
    if (now.difference(_lastAddressedAt) >= freshAfter) {
      _resumptionHandle = null;
      _turnsSinceFresh = 0;
    }
    OrdiBackend.diag('standby');
    _standby = true;
    _connected = false;
    _retry?.cancel();
    OrdiAudio.disconnect();
  }

  /// Someone spoke while on standby: open a session for them.
  void _leaveStandby() {
    if (!_standby) return;
    _standby = false;
    _lastSoundAt = clock.now();
    OrdiBackend.diag('standby-wake');
    _connect();
  }

  /// A question typed in a chat, waiting for its answer, and the conversation
  /// (a `ConversationSession`) it continues, if any.
  String? _typed;
  Object? _typedInto;

  /// What was on screen when the question was typed (the last answer lingers
  /// until the next one starts), whether a reply has begun since, and the
  /// timer that gives up on one that never does.
  String _typedBaseline = '';
  bool _typedAnswered = false;
  Timer? _typedTimer;

  /// Handed to whoever records the finished exchange, once: the conversation
  /// a typed question was asked in, or null for a spoken one.
  Object? takeTypedTarget() {
    final into = _typedInto;
    _typedInto = null;
    return into;
  }

  /// Whether spoken replies are switched off, so a typed chat can be read in
  /// a quiet place. The answer still arrives as text.
  bool repliesMuted = false;

  Future<void> setRepliesMuted(bool value) async {
    if (repliesMuted == value) return;
    repliesMuted = value;
    _update(() {});
    await OrdiAudio.setRecording(value);
  }

  /// Asks Ordinary a question that was typed rather than spoken. It answers
  /// as it would aloud — the words arrive on [transcript] — and the exchange
  /// is recorded like any other, into [into] if given. Returns false when
  /// there is no session to ask it in (signed out, permission withdrawn, no
  /// connection), with the reason in [problem].
  ///
  /// [context] is a few words of what was said earlier in a conversation
  /// being picked up again, which a new session has no other way to know.
  Future<bool> askText(String text, {Object? into, String? context}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _disposed || _ended) return false;
    if (_standby) {
      _standby = false;
      _lastSoundAt = clock.now();
    }
    if (!_connected) {
      await _connect();
      // Another attempt may already be under way: wait for it a moment.
      for (var i = 0; i < 100 && _connecting && !_connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (!_connected || _disposed || _ended) return false;
    _typed = trimmed;
    _typedInto = into;
    _typedBaseline = transcript.value;
    _typedAnswered = false;
    // A question the model chooses not to answer leaves nothing to record;
    // forget it rather than let it label some later, spoken exchange.
    _typedTimer?.cancel();
    _typedTimer = Timer(const Duration(seconds: 45), () {
      _typed = null;
      _typedInto = null;
    });
    _lastAddressedAt = clock.now();
    _lastSoundAt = clock.now();
    // Said to Ordinary by name, so the wake gate opens and its tools may run.
    final said = context == null || context.trim().isEmpty
        ? 'Hey Ordinary, $trimmed'
        : 'Hey Ordinary, ($context) $trimmed';
    await OrdiAudio.ask(said);
    return true;
  }

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
    if (text.trim().isEmpty) return false;
    if (_standby) {
      // A reminder falling due in a quiet room: open a session to say it.
      _standby = false;
      _lastSoundAt = clock.now();
      await _connect();
    }
    if (!_connected) return false;
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
      name: prefs?.name,
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
    _standby = false;
    _lastSoundAt = clock.now();
    _turnsSinceFresh = 0;
    await OrdiAudio.disconnect();
    await _connect(prefetched: session);
    if (introduce && _connected && request == _restartRequests) {
      await speak('[ordi] hello');
    }
    return _connected;
  }

  /// Closes the live session and shows [message] in its place — today's
  /// credits are used up, or the person signed out. Waits for Ordinary to
  /// finish what it is saying, so the answer that used the last credit is
  /// heard in full. The microphone stays as it was; nothing is streamed
  /// without a session.
  Future<void> endSession(String message) async {
    for (var i = 0; i < 150; i++) {
      if (_disposed || reading.value.state != OrdiState.speaking) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_disposed) return;
    _retry?.cancel();
    _resumptionHandle = null;
    _connected = false;
    _standby = false;
    _ended = true;
    await OrdiAudio.disconnect();
    // Ended on purpose — signed out, the Gemini permission withdrawn, or the
    // day's allowance used up — so nothing is listening either. Without this
    // the session closed but the microphone stayed open on the phone, with
    // its indicator and its "listening" notification, while the screen said
    // Ordinary had stopped.
    _off = true;
    OrdiBackend.diag('mic-off');
    await OrdiAudio.stop();
    _update(() => problem = message);
  }

  /// True from [endSession] until [reconnect]: the microphone is closed on
  /// purpose, so the watchdog and the app coming back to the front must not
  /// reopen it.
  bool _off = false;

  /// Set by [endSession]: nothing reopens a session until [reconnect].
  bool _ended = false;

  /// Opens a session again after [endSession] — the allowance refilled, or
  /// the person signed back in. Does nothing if one is already open or Ordinary
  /// has not started listening yet.
  Future<void> reconnect() async {
    _ended = false;
    if (_off) {
      _off = false;
      _lastTaps = null;
      _stalledBeats = 0;
      if (!_disposed && !_held && _frames != null) await _listen();
    }
    if (_disposed || _connected || _frames == null || _held) return;
    _standby = false;
    _lastSoundAt = clock.now();
    _attempts = 0;
    if (problem != null) _update(() => problem = null);
    await _connect();
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
    final gate = startGate;
    if (gate != null) await gate;
    if (_disposed) return;
    OrdiBackend.diag('boot');
    final granted = await OrdiAudio.requestPermission();
    OrdiBackend.diag('permission', granted);
    if (!_micPermission.isCompleted) _micPermission.complete(granted);
    if (_disposed) return;

    if (!granted) {
      _update(() {
        micDenied = true;
        problem = 'Ordinary needs the microphone to hear you.\nEnable it in Settings.';
      });
      return;
    }
    await _startListening();
  }

  /// Everything after the microphone is allowed. Also run when someone turns
  /// the microphone on in iOS Settings and comes back — see
  /// [didChangeAppLifecycleState] — so no relaunch is needed.
  Future<void> _startListening() async {
    if (_frames != null) return;
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
      // Said once each time it changes: whether sound is on the phone or on a
      // Bluetooth headset is the first question when the Audios misbehave.
      final route = native['route'];
      if (route is String && route != _lastRoute) {
        _lastRoute = route;
        OrdiBackend.diag('audio-route', route);
      }
      await _checkMicAlive(native);
      _maybeStartFresh();
      _maybeStandBy();
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

  // ----------------------------------------------------------- freshening

  /// Turns heard since this session started from scratch.
  int _turnsSinceFresh = 0;

  /// When Ordinary last spoke to, or answered, the person.
  DateTime _lastAddressedAt = clock.now();

  /// How long without being spoken to before the overheard history is
  /// dropped, and how much of it there has to be to bother.
  static const freshAfter = Duration(minutes: 2);
  static const freshMinTurns = 3;

  /// Measured: every turn re-bills the whole session history, and every
  /// sentence overheard in the room is a turn — so a session that has sat in a
  /// busy room for an hour charges for the whole hour's chatter again on each
  /// new sentence. Once nobody has spoken to Ordinary for a couple of minutes
  /// that history is only room noise, so start a fresh session (no resumption
  /// handle) and let it go. What was actually said to Ordinary still carries
  /// over through [memoryDigest]. Uses [restart], so the new session is
  /// fetched before the old one closes and nothing is missed; only runs when
  /// idle, never mid-reply, while dictation holds the mic, or while connecting.
  void _maybeStartFresh() {
    if (_disposed || _held || !_connected || _connecting) return;
    if (_turnsSinceFresh < freshMinTurns) return;
    if (reading.value.state != OrdiState.idle) return;
    if (clock.now().difference(_lastAddressedAt) < freshAfter) return;
    OrdiBackend.diag('fresh-session', {'turns': _turnsSinceFresh});
    _turnsSinceFresh = 0;
    restart();
  }

  // ------------------------------------------------------------- recovery

  int? _lastTaps;
  int _stalledBeats = 0;

  /// The last line of defence for a deaf microphone. The native side now
  /// rebuilds itself after interruptions and audio-session changes, but if the
  /// microphone still stops delivering buffers for two heartbeats (~10 s),
  /// restart it from here rather than waiting for the app to be reopened.
  Future<void> _checkMicAlive(Map<Object?, Object?> native) async {
    final taps = (native['taps'] as num?)?.toInt();
    if (taps == null || _held || _off || _disposed) return;
    final last = _lastTaps;
    _stalledBeats = last != null && taps == last ? _stalledBeats + 1 : 0;
    _lastTaps = taps;
    if (_stalledBeats < 2) return;
    _stalledBeats = 0;
    _lastTaps = null;
    OrdiBackend.diag('revive', native.map((k, v) => MapEntry('$k', v)));
    await OrdiAudio.stop();
    if (!_held && !_disposed) await _listen();
  }

  /// Back from iOS Settings: if the microphone is allowed now, start.
  Future<void> _recheckMicrophone() async {
    final granted = await OrdiAudio.requestPermission();
    if (!granted || _disposed) return;
    _update(() {
      micDenied = false;
      problem = null;
    });
    await _startListening();
  }

  /// True while something else is using the microphone — dictating a note.
  bool _held = false;

  /// Hands the microphone over to something else, such as note dictation,
  /// which configures the shared audio session its own way and, when it
  /// stops, shuts it down. Ordi stops listening until [releaseListening].
  Future<void> holdListening() async {
    if (_held || _frames == null) return;
    _held = true;
    OrdiBackend.diag('mic-held');
    await OrdiAudio.stop();
  }

  /// Takes the microphone back. Starting re-applies Ordi's own voice-chat
  /// session, echo cancellation included, whatever the other user left it as.
  Future<void> releaseListening() async {
    if (!_held) return;
    _held = false;
    _lastTaps = null;
    _stalledBeats = 0;
    OrdiBackend.diag('mic-released');
    if (!_disposed && _frames != null && !_off) await _listen();
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
    if (_connecting || _connected || _ended) return;
    // Whatever asked for a session, standby is over.
    _standby = false;
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
      // Listeners showing "Listening for Hey Ordinary" / "Connecting" need to know.
      _update(() {});
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
    final wasConnected = _connected;
    _connected = false;
    if (wasConnected) _update(() {});
    _retry?.cancel();

    // Google allows only so many sessions at once across everyone. Being
    // turned away for that is not a fault to show in raw form, and hammering
    // it will not free a place: say so plainly and wait longer between tries.
    final busy = reason != null &&
        (reason.contains('quota') || reason.contains('RESOURCE_EXHAUSTED'));
    final backoff = busy ? const [3, 6, 12, 20, 30] : const [1, 2, 4, 8, 15];
    final wait = Duration(seconds: backoff[min(_attempts, backoff.length - 1)]);
    _attempts += 1;

    if (busy) {
      OrdiBackend.diag('busy', {'attempt': _attempts});
      const message = 'Ordinary is busy right now. Trying again…';
      if (problem != message) _update(() => problem = message);
    } else if (_attempts > 3 && reason != null && problem != reason) {
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

    // On standby, or once a session was ended on purpose, there is no session
    // to lose: a late error from the one just closed must not reopen it.
    if (frame.error != null && !_standby && !_ended) {
      _scheduleReconnect(frame.error);
    }

    // Any sound — the person, or Ordinary answering — resets the quiet clock,
    // and on standby it is what opens a session again. The level is checked
    // as well as the state: the engine's own "listening" only starts after a
    // spell of real quiet, so in a room with a steady hum it can sit on idle
    // while someone is plainly talking.
    _loudFrames = frame.amplitude >= soundLevel ? _loudFrames + 1 : 0;
    if (frame.state != OrdiState.idle || _loudFrames >= soundFrames) {
      _lastSoundAt = clock.now();
      if (_standby) _leaveStandby();
    }

    if (frame.state != reading.value.state) {
      OrdiBackend.diag('state', frame.state.name);
    }
    reading.value = Reading(frame.state, frame.amplitude);
    if (frame.transcript != transcript.value) {
      transcript.value = frame.transcript;
    }

    var question = frame.exchangeQuestion;
    final answer = frame.exchangeAnswer;
    // A question that was typed has no speech transcript; the text itself is
    // what was asked — whatever the microphone made of the room meanwhile.
    if (answer != null && _typed != null) {
      question = _typed;
    }

    // The engine only reports an exchange for something that was spoken, so a
    // typed question's answer is recorded here, once the reply has finished.
    if (_typed != null && answer == null) {
      final text = transcript.value.trim();
      if (frame.state == OrdiState.speaking ||
          (text.isNotEmpty && text != _typedBaseline.trim())) {
        _typedAnswered = true;
      }
      // Idle again after answering: the reply is over, and the words on
      // screen are all of it.
      if (_typedAnswered && frame.state == OrdiState.idle && text.isNotEmpty) {
        final asked = _typed!;
        _typed = null;
        _typedTimer?.cancel();
        onExchange?.call(asked, text);
        _typedInto = null;
        _turnsSinceFresh++;
        _lastAddressedAt = clock.now();
      }
    }

    if (question != null && answer != null) {
      onExchange?.call(question, answer);
      _typed = null;
      _typedTimer?.cancel();
      _typedInto = null;
      // Every finished turn is re-billed as history on every later turn.
      // Count them, and note when Ordinary was actually talking to someone.
      _turnsSinceFresh++;
      if (answer.trim().isNotEmpty) _lastAddressedAt = clock.now();
    }
    if (frame.state == OrdiState.speaking) _lastAddressedAt = clock.now();

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
        if (micDenied) _recheckMicrophone();
        // Audio was never stopped, so this only repairs a session that died
        // while we were away; both calls are no-ops when things are healthy.
        if (_frames != null && !_held && !_off) {
          // Opening the app is as good a sign as speaking that a session is
          // about to be wanted.
          _lastSoundAt = clock.now();
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
