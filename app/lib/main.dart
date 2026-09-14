import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'home/home_screen.dart';
import 'models/ai_brief.dart';
import 'models/conversation_log.dart';
import 'ordi/ordi_controller.dart';
import 'ui/tokens.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dark status-bar icons: the app is a light theme now, so light icons would
  // vanish against the page background.
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  // Non-blocking disk-to-RAM shader preload — the OS window still presents on
  // frame 1, but the first card the user actually sees isn't the one paying
  // for a cold shader compile.
  await LiquidGlassWidgets.initialize();
  runApp(LiquidGlassWidgets.wrap(
    child: const OrdiApp(),
    // MaterialApp's ThemeMode doesn't reach this package on its own — without
    // this, glass shadows/borders can pick the OS's brightness instead of the
    // app's, which happens to matter here since the app is pinned to light
    // regardless of device setting.
    brightnessResolver: Theme.maybeBrightnessOf,
  ));
}

class OrdiApp extends StatefulWidget {
  const OrdiApp({super.key});

  @override
  State<OrdiApp> createState() => _OrdiAppState();
}

class _OrdiAppState extends State<OrdiApp> {
  /// Created once, here, rather than inside a screen.
  ///
  /// Ordi is now one destination among several, so a screen-owned controller
  /// would stop the microphone every time you navigated away — quietly
  /// undoing the background listening. Owning it at the app root is what keeps
  /// "it keeps listening while I do other things" true.
  late final OrdiController _ordi = OrdiController();

  /// What Ordi remembers. Lives at the same scope as the controller for the
  /// same reason — it needs to outlive the History screen and keep recording
  /// exchanges whether or not anyone is looking at it.
  final ConversationLog _log = ConversationLog();

  /// Tasks pulled out of finished conversations by the log above.
  final AiBrief _brief = AiBrief();

  @override
  void initState() {
    super.initState();
    _log.load();
    _brief.load();
    _ordi.onExchange = _log.add;
    _ordi.memoryDigest = _log.recentDigest;
    _log.onTasksExtracted = _brief.addExtracted;
  }

  @override
  void dispose() {
    _ordi.dispose();
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ordinary OS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Tokens.ink,
        useMaterial3: true,
        fontFamily: '.SF Pro Text',
        splashFactory: NoSplash.splashFactory,
      ),
      home: OrdiScope(
        controller: _ordi,
        log: _log,
        brief: _brief,
        child: const HomeScreen(),
      ),
    );
  }
}

/// Makes the controller and its two derived stores reachable from any screen
/// without threading them through every constructor.
class OrdiScope extends InheritedWidget {
  const OrdiScope({
    super.key,
    required this.controller,
    required this.log,
    required this.brief,
    required super.child,
  });

  final OrdiController controller;
  final ConversationLog log;
  final AiBrief brief;

  static OrdiController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OrdiScope>();
    assert(scope != null, 'No OrdiScope above this widget.');
    return scope!.controller;
  }

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

  @override
  bool updateShouldNotify(OrdiScope oldWidget) =>
      controller != oldWidget.controller ||
      log != oldWidget.log ||
      brief != oldWidget.brief;
}
