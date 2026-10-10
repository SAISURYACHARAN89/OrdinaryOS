import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account/ai_consent_screen.dart';
import 'account/sign_in_flow.dart';
import 'home/home_screen.dart';
import 'models/account.dart';
import 'models/ai_consent.dart';
import 'models/ai_brief.dart';
import 'models/conversation_log.dart';
import 'models/device.dart';
import 'models/documents.dart';
import 'models/pairing.dart';
import 'models/study.dart';
import 'models/ordi_settings.dart';
import 'models/recording_store.dart';
import 'models/reminder_scheduler.dart';
import 'models/speed_dial.dart';
import 'ordi/ordi_controller.dart';
import 'ordi/tool_dispatcher.dart';
import 'session.dart';
import 'pairing/pairing_flow.dart';
import 'ui/surface.dart';
import 'study/study_screen.dart';
import 'ui/device_icons.dart';
import 'ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dark status-bar icons: the page is white, so light icons would vanish.
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  runApp(const OrdiApp());
}

class OrdiApp extends StatefulWidget {
  const OrdiApp({super.key});

  @override
  State<OrdiApp> createState() => _OrdiAppState();
}

class _OrdiAppState extends State<OrdiApp> with WidgetsBindingObserver {
  /// Created once, here, rather than inside a screen.
  ///
  /// Ordi is now one destination among several, so a screen-owned controller
  /// would stop the microphone every time you navigated away — quietly
  /// undoing the background listening. Owning it at the app root is what keeps
  /// "it keeps listening while I do other things" true.
  late final OrdiController _ordi = OrdiController(startGate: _micGate.future);

  /// Holds Ordi back — microphone prompt included — until setup has asked for
  /// the microphone on its own screen. Opens straight away for anyone who
  /// finished setup before.
  final Completer<void> _micGate = Completer<void>();

  void _openMicGate() {
    if (!_micGate.isCompleted) _micGate.complete();
  }

  /// Who is signed in and what they are allowed. Ordinary is for owners, so
  /// nothing starts — no microphone prompt, no session — until this says so.
  late final Account _account = Account.create();

  /// Whether they agreed to what Ordinary sends to Google. Without a yes no
  /// microphone is opened and no session is started.
  final AiConsent _consent = AiConsent();

  /// Ordinary may start once an owner is signed in, has agreed to how it
  /// answers, and setup is finished.
  void _maybeStart() {
    if (_account.hasAccess &&
        _consent.allowed &&
        _pairing.loaded &&
        _pairing.done) {
      _openMicGate();
    }
  }

  static const _consentNeeded =
      'Ordinary is off. To use it, allow Google Gemini in Settings.';
  bool _wasAllowed = false;

  /// Follows the answer being given, and being changed later in Settings.
  void _onConsentChanged() {
    final allowed = _consent.allowed;
    if (allowed && !_wasAllowed) {
      _maybeStart();
      if (_account.hasAccess) _ordi.reconnect();
    } else if (!allowed && _consent.decided) {
      // Said no, or took it back: nothing more is sent.
      _ordi.endSession(_consentNeeded);
    }
    _wasAllowed = allowed;
  }

  bool _hadAccess = false;
  bool _wasSpent = false;
  Timer? _refill;

  /// Reacts to sign-in, sign-out, losing access, and the daily allowance
  /// running out or refilling.
  void _onAccountChanged() {
    final access = _account.hasAccess;
    final spent = _account.outOfCredits;

    if (access && !_hadAccess) {
      _maybeStart();
      _ordi.reconnect();
    } else if (!access && _hadAccess) {
      // Whatever screen was open belongs to someone who is no longer here.
      _navigator.currentState?.popUntil((route) => route.isFirst);
      _ordi.endSession('Sign in to use Ordinary.');
    }

    if (access && spent && !_wasSpent) {
      _ordi.endSession(_limitMessage());
      _refill?.cancel();
      final at = _account.credits?.resetsAt;
      if (at != null) {
        final wait = at.difference(DateTime.now()) + const Duration(seconds: 5);
        _refill = Timer(wait.isNegative ? Duration.zero : wait,
            () => _account.refreshProfile());
      }
    } else if (access && !spent && _wasSpent) {
      _refill?.cancel();
      _ordi.reconnect();
    }

    _hadAccess = access;
    _wasSpent = access && spent;
  }

  String _limitMessage() {
    final at = _account.credits?.resetsAt;
    if (at == null) return "You've reached today's limit.";
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    return "You've reached today's limit. It resets at $hour:$minute "
        "${at.hour < 12 ? 'AM' : 'PM'}.";
  }

  /// The permissions step in setup: open the gate so Ordi asks for the
  /// microphone, wait for the answer, then ask for notifications.
  Future<void> _askPermissions() async {
    // The microphone exists to be sent to Google: without their yes to that,
    // it is not asked for.
    if (_consent.allowed) {
      _openMicGate();
      await _ordi.micPermission.timeout(const Duration(minutes: 2),
          onTimeout: () => false);
    }
    await _reminders.requestPermission();
  }

  /// What Ordi remembers. Lives at the same scope as the controller for the
  /// same reason — it needs to outlive the History screen and keep recording
  /// exchanges whether or not anyone is looking at it.
  final ConversationLog _log = ConversationLog();

  /// Tasks pulled out of finished conversations by the log above, plus the
  /// dated reminders Ordi is asked for out loud.
  final AiBrief _brief = AiBrief();

  /// Transcripts Ordi was explicitly told to capture.
  final RecordingStore _recordings = RecordingStore();

  /// Lives here, not in the dashboard that displays it: Ordi has to be able to
  /// call someone by voice whether or not that screen is mounted. Same reason
  /// the controller and the log are owned at this level.
  final SpeedDial _speedDial = SpeedDial();

  /// Voice and language, chosen in Settings and sent with each session.
  final OrdiSettings _settings = OrdiSettings();

  /// The paired devices and where Ordi runs, and the study notes for the Band.
  /// Here rather than on the dashboard so Ordi can answer "study mode" by
  /// voice from any screen.
  final Devices _devices = Devices();
  final StudyLibrary _study = StudyLibrary();

  /// First-launch setup and the Bluetooth link to the Audios and the Band.
  final Pairing _pairing = Pairing();

  /// PDFs Ordinary can answer from. Kept and searched on this phone.
  final DocumentLibrary _documents = DocumentLibrary();
  String _documentNames = '';

  /// A new or removed document changes what Ordinary is told it can search,
  /// and that is fixed when a session opens — so open a fresh one. The list
  /// arriving from disk at launch is not a change.
  void _onDocumentsChanged() {
    if (!_documents.loaded) return;
    final names = _documents.titles.join('\n');
    if (!_documentsLoaded) {
      _documentsLoaded = true;
      _documentNames = names;
      return;
    }
    if (names == _documentNames) return;
    _documentNames = names;
    _ordi.restart();
  }

  bool _documentsLoaded = false;

  /// The name in the profile is part of what a session is told when it opens,
  /// so a changed name needs a fresh one — otherwise Ordinary keeps the old
  /// answer until the session happens to end. The name arriving from disk at
  /// launch is not a change.
  String? _knownName;

  void _onSettingsChanged() {
    final name = _settings.name;
    // Not loaded yet: whatever arrives is the saved name, not a change.
    if (_knownName == null || name == _knownName) return;
    _knownName = name;
    _ordi.restart();
  }

  /// Lets a voice request open a screen without a `BuildContext` of its own.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  /// "Study mode" by voice. With the Band chosen it opens Study Mode; with the
  /// phone it explains where study mode lives. Returns whether it opened and
  /// the sentence for Ordi to say.
  ({bool opened, String say}) _openStudyMode() {
    // Someone set up with the Audios alone has no Band, whatever the hidden
    // selector last held (it defaults to the Band).
    if (!Pairing.bandAvailable) {
      return (
        opened: false,
        say: 'Study mode is made for the Ordinary Band, which is not out yet.',
      );
    }
    if (!_pairing.wantsBand || _devices.selected != OrdinaryDevice.band) {
      return (
        opened: false,
        say: 'The study mode is specific to your Ordinary Band. Connect your '
            'Band to use study mode and upload your notes in the app.',
      );
    }
    final nav = _navigator.currentState;
    if (nav == null) {
      return (opened: false, say: "Study mode couldn't be opened right now.");
    }
    nav.popUntil((route) => route.isFirst);
    nav.push(MaterialPageRoute(builder: (_) => StudyScreen(library: _study)));
    final chapters = _study.chapters;
    return (
      opened: true,
      say: chapters.isEmpty
          ? 'Study mode is open. There are no chapters yet — add your notes in '
              'the app and sync them to your Band.'
          : 'Study mode is open, with ${chapters.length} '
              '${chapters.length == 1 ? 'chapter' : 'chapters'}: '
              '${chapters.map((c) => c.name).join(', ')}.',
    );
  }

  late final ReminderScheduler _reminders = ReminderScheduler(
    speak: _ordi.speak,
  );

  late final ToolDispatcher _tools = ToolDispatcher(
    brief: _brief,
    recordings: _recordings,
    speedDial: _speedDial,
    reminders: _reminders,
    openStudyMode: _openStudyMode,
    documents: _documents,
  );

  @override
  void initState() {
    super.initState();
    _ordi.sessionPrefs =
        () => (
          voice: _settings.chosen.name,
          accent: _settings.chosen.accent,
          language: _settings.language,
          name: _settings.name,
        );
    _ordi.prefsReady = _settings.load().then((_) => _knownName = _settings.name);
    _settings.addListener(_onSettingsChanged);
    _devices.load();
    _study.load();
    WidgetsBinding.instance.addObserver(this);
    OrdiBackend.documentTitles = () => _documents.titles;
    _documents.addListener(_onDocumentsChanged);
    _documents.load();
    OrdiBackend.account = _account;
    _hadAccess = _account.hasAccess;
    _wasSpent = _account.outOfCredits;
    _account.addListener(_onAccountChanged);
    _account.load().then((_) => _maybeStart());
    _consent.addListener(_onConsentChanged);
    _consent.load();
    _pairing.load().then((_) => _maybeStart());
    // Finishing setup any way at all — even skipping every step — lets Ordi
    // start, for a signed-in owner.
    _pairing.addListener(_maybeStart);
    _log.load();
    _brief.load().then((_) => _reminders.restore(_brief));
    _recordings.load();
    _speedDial.load();

    // Two consumers of the same finished turns. The log keeps exchanges with
    // an answer; the recording store keeps what the person said whether or not
    // Ordi replied, which is the whole of a meeting Ordi sat through silently.
    _ordi.onExchange = (question, answer) {
      // A typed question picked up from History belongs to that conversation.
      final into = _ordi.takeTypedTarget();
      _log.add(question, answer,
          into: into is ConversationSession ? into : null);
      _recordings.observe(question, answer);
      // Every sentence heard is paid for, answered or not, so each counts
      // towards the day's listening.
      _account.reportHeard();
      // One credit per answer Ordinary gives. Speech it stayed silent for
      // costs nothing, and neither does sitting through a recording.
      if (answer.trim().isNotEmpty && !_recordings.isRecording) {
        _account.reportAnswer();
      }
    };
    _ordi.memoryDigest = _log.recentDigest;
    // A recording has to keep transcribing through any silence.
    _ordi.keepSessionOpen = () => _recordings.isRecording;
    _log.onTasksExtracted = _brief.addExtracted;
    _recordings.onTasksExtracted = _brief.addExtracted;

    // A reminder created while the app is running gets scheduled the moment it
    // exists, rather than waiting for the next launch to be picked up.
    _brief.onScheduled = _reminders.schedule;
    _brief.onCancelled = (task) => _reminders.cancel(task.id);

    // Driven off the store's own state rather than off whoever started it:
    // recording can stop by voice, by the Stop control on the dashboard, or by
    // hitting its own duration cap, and a tick left running after any of those
    // would be a phantom buzz every ten seconds.
    _recordings.addListener(_syncRecordingTick);

    // A recording that hits its duration cap stops by itself; say so rather
    // than let it end unnoticed.
    _recordings.onAutoStopped = (_) {
      _reminders.showNotice('Recording stopped',
          'Ordinary stops recording after 3 hours. The transcript is in the app.');
      _ordi.speak('[ordi] remind: The recording stopped by itself after three '
          'hours. The transcript is in the app.');
    };

    _tools.attach();
  }

  /// A light tap every ten seconds while recording, so the person knows it is
  /// still running without a sound in the room.
  ///
  /// Haptic rather than the beep originally asked for: the microphone is open,
  /// so an audible tick would be transcribed into the very meeting it is meant
  /// to be quietly recording, and is loud enough to trip voice activity. A tap
  /// is invisible to the audio path and still works face-down in a pocket.
  Timer? _recordingTick;
  bool _ticking = false;

  void _syncRecordingTick() {
    final recording = _recordings.isRecording;
    if (recording == _ticking) return;
    _ticking = recording;

    _recordingTick?.cancel();
    _recordingTick = null;
    if (!recording) return;
    _recordingTick = Timer.periodic(
      const Duration(seconds: 10),
      (_) => HapticFeedback.lightImpact(),
    );
  }

  /// Recordings save on a short delay while they run; write now if the app is
  /// going away, so the last few seconds are not lost.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _recordings.flush();
    }
    // Back in the app: a plan bought on the website, or an allowance that
    // refilled overnight, shows up without signing in again.
    if (state == AppLifecycleState.resumed) {
      _account.refreshProfile();
      // And Audios that were switched on while the app was away connect now.
      _pairing.wake();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTick?.cancel();
    _refill?.cancel();
    _documents.removeListener(_onDocumentsChanged);
    _documents.dispose();
    OrdiBackend.documentTitles = null;
    _account.removeListener(_onAccountChanged);
    if (OrdiBackend.account == _account) OrdiBackend.account = null;
    _account.dispose();
    _consent.dispose();
    _recordings.removeListener(_syncRecordingTick);
    _ordi.dispose();
    _log.dispose();
    _reminders.dispose();
    _recordings.dispose();
    _speedDial.dispose();
    _settings.removeListener(_onSettingsChanged);
    _settings.dispose();
    _devices.dispose();
    _study.dispose();
    _pairing.dispose();
    _brief.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ordinary OS',
      debugShowCheckedModeBanner: false,
      theme: ordiTheme(),
      navigatorKey: _navigator,
      // Above the navigator, so every screen — pushed ones included — can
      // reach the controller and the stores.
      builder: (context, child) => OrdiScope(
        controller: _ordi,
        log: _log,
        brief: _brief,
        recordings: _recordings,
        speedDial: _speedDial,
        settings: _settings,
        devices: _devices,
        study: _study,
        pairing: _pairing,
        account: _account,
        consent: _consent,
        documents: _documents,
        // Large iPhone text sizes still scale the app, but not so far that
        // fixed-size circles and pills break apart.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: child!,
        ),
      ),
      // Setup comes first: until it is finished — by pairing or by skipping —
      // the app shows it instead of the dashboard.
      // Sign-in comes before everything: Ordinary is for owners. Then setup,
      // until it is finished — by pairing or by skipping — then the dashboard.
      home: AnimatedBuilder(
        animation: Listenable.merge([_pairing, _account, _consent]),
        builder: (context, _) {
          if (_account.status == AccountStatus.loading ||
              !_pairing.loaded ||
              !_consent.loaded) {
            return const Backdrop(child: SizedBox.expand());
          }
          if (!_account.signedIn) return SignInFlow(account: _account);
          if (!_account.hasAccess) return NoAccessScreen(account: _account);
          // Before setup and before any listening: what goes to Google, and
          // whether that is all right.
          if (!_consent.decided) return AiConsentScreen(consent: _consent);
          return _pairing.done
              ? const HomeScreen()
              : PairingFlow(
                  pairing: _pairing,
                  onClose: _pairing.reopened ? _pairing.close : null,
                  onAskPermissions: _askPermissions,
                );
        },
      ),
    );
  }
}

/// Makes the controller and its derived stores reachable from any screen
/// without threading them through every constructor.
class OrdiScope extends InheritedWidget {
  const OrdiScope({
    super.key,
    required this.controller,
    required this.log,
    required this.brief,
    required this.recordings,
    required this.speedDial,
    required this.settings,
    required this.devices,
    required this.study,
    required this.pairing,
    required this.account,
    required this.consent,
    required this.documents,
    required super.child,
  });

  final OrdiController controller;
  final ConversationLog log;
  final AiBrief brief;
  final RecordingStore recordings;
  final SpeedDial speedDial;
  final OrdiSettings settings;
  final Devices devices;
  final StudyLibrary study;
  final Pairing pairing;
  final Account account;
  final AiConsent consent;
  final DocumentLibrary documents;

  /// Their answer about Google Gemini, or null outside the app.
  static AiConsent? maybeConsentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrdiScope>()?.consent;

  /// The controller, or null outside the app (a screen built on its own in a
  /// test).
  static OrdiController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrdiScope>()?.controller;

  static OrdiController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.controller;
  }

  /// The conversation log, or null outside the app.
  static ConversationLog? maybeLogOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrdiScope>()?.log;

  static ConversationLog logOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.log;
  }

  static AiBrief briefOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.brief;
  }

  static RecordingStore recordingsOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.recordings;
  }

  static SpeedDial speedDialOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.speedDial;
  }

  static Devices devicesOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.devices;
  }

  static StudyLibrary studyOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.study;
  }

  static Pairing pairingOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.pairing;
  }

  /// The document library, or null outside the app (a screen built on its
  /// own in a test).
  static DocumentLibrary? maybeDocumentsOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrdiScope>()?.documents;

  static DocumentLibrary documentsOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.documents;
  }

  static Account accountOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.account;
  }

  static OrdiSettings settingsOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.settings;
  }

  @override
  bool updateShouldNotify(OrdiScope oldWidget) =>
      controller != oldWidget.controller ||
      log != oldWidget.log ||
      brief != oldWidget.brief ||
      recordings != oldWidget.recordings ||
      speedDial != oldWidget.speedDial ||
      settings != oldWidget.settings ||
      devices != oldWidget.devices ||
      study != oldWidget.study ||
      pairing != oldWidget.pairing ||
      account != oldWidget.account ||
      documents != oldWidget.documents;
}
