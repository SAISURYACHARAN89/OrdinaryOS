import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:ordi_audio/ordi_audio.dart' show OrdiAudio;

import '../models/pairing.dart';
import '../ui/device_icons.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// First-launch setup: choose Audios + Band or Audios alone, then find and
/// connect each over Bluetooth. Finishing — by connecting or by "Skip for now"
/// — lets the person into the app.
class PairingFlow extends StatefulWidget {
  const PairingFlow({
    super.key,
    required this.pairing,
    this.onClose,
    this.onAskPermissions,
  });

  final Pairing pairing;

  /// Shown as a close button when setup was reopened from Settings.
  final VoidCallback? onClose;

  /// Asks for the microphone and notifications. When null — setup reopened
  /// from Settings, where they were asked already — the step is skipped.
  final Future<void> Function()? onAskPermissions;

  @override
  State<PairingFlow> createState() => _PairingFlowState();
}

enum _Step { choose, permissions, audios, band, done }

class _PairingFlowState extends State<PairingFlow> {
  _Step _step = _Step.choose;

  Pairing get _p => widget.pairing;

  void _next() {
    setState(() {
      _step = switch (_step) {
        _Step.choose =>
          widget.onAskPermissions == null ? _Step.audios : _Step.permissions,
        _Step.permissions => _Step.audios,
        _Step.audios => _p.wantsBand ? _Step.band : _Step.done,
        _Step.band => _Step.done,
        _Step.done => _Step.done,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0.06, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: switch (_step) {
              _Step.choose => _ChooseStep(
                key: const ValueKey('choose'),
                pairing: _p,
                onClose: widget.onClose,
                onContinue: _next,
              ),
              _Step.permissions => _PermissionsStep(
                key: const ValueKey('permissions'),
                onAsk: widget.onAskPermissions!,
                onDone: _next,
              ),
              _Step.audios => _ScanStep(
                key: const ValueKey('audios'),
                pairing: _p,
                device: OrdinaryDevice.glasses,
                onDone: _next,
              ),
              _Step.band => _ScanStep(
                key: const ValueKey('band'),
                pairing: _p,
                device: OrdinaryDevice.band,
                onDone: _next,
              ),
              _Step.done => _DoneStep(
                key: const ValueKey('done'),
                pairing: _p,
                onEnter: _p.finish,
              ),
            },
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ choose

class _ChooseStep extends StatelessWidget {
  const _ChooseStep({
    super.key,
    required this.pairing,
    required this.onContinue,
    this.onClose,
  });

  final Pairing pairing;
  final VoidCallback onContinue;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pairing,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(
          Tokens.gutter,
          Tokens.x4,
          Tokens.gutter,
          Tokens.x5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 40,
              child: onClose == null
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: RoundIconButton(
                        icon: Icons.close_rounded,
                        onTap: onClose,
                      ),
                    ),
            ),
            const SizedBox(height: Tokens.x6),
            Text('Set up Ordinary', style: Tokens.display),
            const SizedBox(height: Tokens.x2),
            Text(
              'What are you pairing today?',
              style: Tokens.body.copyWith(fontSize: 16),
            ),
            const SizedBox(height: Tokens.x8),
            _Option(
              title: 'Audios + Band',
              subtitle: 'Your glasses and your Band',
              glyphs: const [OrdinaryDevice.glasses, OrdinaryDevice.band],
              selected: pairing.setup == PairingSetup.audiosAndBand,
              onTap: () => pairing.choose(PairingSetup.audiosAndBand),
            ),
            const SizedBox(height: Tokens.x3),
            _Option(
              title: 'Audios only',
              subtitle: 'Just your glasses',
              glyphs: const [OrdinaryDevice.glasses],
              selected: pairing.setup == PairingSetup.audiosOnly,
              onTap: () => pairing.choose(PairingSetup.audiosOnly),
            ),
            const Spacer(),
            InkButton(label: 'Continue', onPressed: onContinue),
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.title,
    required this.subtitle,
    required this.glyphs,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final List<OrdinaryDevice> glyphs;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? Tokens.accentInk : Tokens.text;
    return Surface(
      radius: Tokens.rMedium,
      fill: selected ? Tokens.text : Tokens.paper2,
      onTap: onTap,
      selected: selected,
      padding: const EdgeInsets.all(Tokens.x5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Tokens.title.copyWith(color: ink)),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Tokens.body.copyWith(
                    fontSize: 14,
                    color: selected
                        ? Tokens.accentInk.withValues(alpha: 0.7)
                        : Tokens.textSoft,
                  ),
                ),
              ],
            ),
          ),
          for (final g in glyphs)
            Padding(
              padding: const EdgeInsets.only(left: Tokens.x2),
              child: DeviceGlyph(device: g, size: 40, color: ink),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- permissions

/// Says why before iOS asks: the microphone for "Hey Ordi", notifications
/// for reminders. One button, then the system prompts appear one after the
/// other.
class _PermissionsStep extends StatefulWidget {
  const _PermissionsStep({
    super.key,
    required this.onAsk,
    required this.onDone,
  });

  final Future<void> Function() onAsk;
  final VoidCallback onDone;

  @override
  State<_PermissionsStep> createState() => _PermissionsStepState();
}

class _PermissionsStepState extends State<_PermissionsStep> {
  bool _asking = false;

  Future<void> _go() async {
    setState(() => _asking = true);
    try {
      await widget.onAsk();
    } finally {
      if (mounted) widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.gutter,
        Tokens.x4,
        Tokens.gutter,
        Tokens.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 40 + Tokens.x6),
          Text('Two quick things', style: Tokens.display),
          const SizedBox(height: Tokens.x8),
          const _Reason(
            icon: Icons.mic_none_rounded,
            title: 'Microphone',
            body:
                'Ordinary listens for "Hey Ordinary" and answers when you talk to it. '
                'Anything not said to Ordinary is ignored.',
          ),
          const SizedBox(height: Tokens.x3),
          const _Reason(
            icon: Icons.notifications_none_rounded,
            title: 'Notifications',
            body:
                'So your reminders reach you on time, even when the app is '
                'closed.',
          ),
          const Spacer(),
          InkButton(
            label: _asking ? 'Waiting…' : 'Continue',
            onPressed: _asking ? null : _go,
          ),
          TextButton(
            onPressed: _asking ? null : widget.onDone,
            child: Text(
              'Not now',
              style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
            ),
          ),
        ],
      ),
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Surface(
      radius: Tokens.rMedium,
      padding: const EdgeInsets.all(Tokens.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Tokens.paper,
              borderRadius: BorderRadius.circular(Tokens.rBadge),
            ),
            child: Icon(icon, size: 20, color: Tokens.text),
          ),
          const SizedBox(width: Tokens.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Tokens.heading),
                const SizedBox(height: 4),
                Text(body, style: Tokens.body.copyWith(fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- scan

enum _ScanState { searching, found, connecting, connected, nothing, problem }

class _ScanStep extends StatefulWidget {
  const _ScanStep({
    super.key,
    required this.pairing,
    required this.device,
    required this.onDone,
  });

  final Pairing pairing;
  final OrdinaryDevice device;
  final VoidCallback onDone;

  @override
  State<_ScanStep> createState() => _ScanStepState();
}

class _ScanStepState extends State<_ScanStep> {
  _ScanState _state = _ScanState.searching;
  List<FoundDevice> _found = const [];
  String? _problem;
  StreamSubscription<List<FoundDevice>>? _scan;
  StreamSubscription<BleStatus>? _status;

  bool get _band => widget.device == OrdinaryDevice.band;
  String get _name => _band ? 'Band' : 'Audios';

  /// The stand-in Band, once it has "appeared" (see [Pairing.demoBand]). The
  /// Audios are real and only ever come from the scan.
  FoundDevice? _demo;
  Timer? _demoTimer;
  List<FoundDevice> _real = const [];

  @override
  void initState() {
    super.initState();
    _watchStatus();
    if (!_band) return;
    _demoTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      if (_state == _ScanState.connecting || _state == _ScanState.connected) {
        return;
      }
      setState(() {
        _demo = Pairing.demoBand;
        _found = _merged();
        _problem = null;
        _state = _ScanState.found;
      });
    });
  }

  /// Real devices first, strongest signal first, then the stand-in.
  List<FoundDevice> _merged() => [..._real, ?_demo];

  Future<void> _watchStatus() async {
    // Android asks for the nearby-devices permission at runtime, and reports
    // "unauthorized" until it has been asked; iOS asks by itself on first use.
    if (Platform.isAndroid) await OrdiAudio.requestBluetooth();
    if (!mounted) return;
    _status = widget.pairing.status.listen(_onStatus, onError: (_) {});
  }

  void _onStatus(BleStatus status) {
    if (!mounted) return;
    switch (status) {
      case BleStatus.ready:
        if (_scan == null && _state != _ScanState.connected) _start();
      case BleStatus.poweredOff:
        _stopScan();
        setState(() {
          _state = _ScanState.problem;
          _problem =
              'Bluetooth is off. Turn it on in '
              '${Platform.isIOS ? 'Control Center' : 'Quick Settings'} to find '
              'your $_name.';
        });
      case BleStatus.unauthorized:
        _stopScan();
        setState(() {
          _state = _ScanState.problem;
          _problem =
              'Ordinary needs Bluetooth to find your $_name. Allow it '
              'in Settings › ${Platform.isIOS ? '' : 'Apps › '}Ordinary.';
        });
      case BleStatus.locationServicesDisabled:
        // Older Android versions scan only with Location switched on.
        _stopScan();
        setState(() {
          _state = _ScanState.problem;
          _problem = 'Turn on Location to let your phone find your $_name.';
        });
      case BleStatus.unsupported:
        setState(() {
          _state = _ScanState.problem;
          _problem = "This phone doesn't support Bluetooth Low Energy.";
        });
      default:
        break;
    }
  }

  void _start() {
    _stopScan();
    setState(() {
      _real = const [];
      _found = _merged();
      _state = _found.isEmpty ? _ScanState.searching : _ScanState.found;
      _problem = null;
    });
    _scan = widget.pairing.scan(band: _band).listen(
      (list) {
        if (!mounted || _state == _ScanState.connecting) return;
        setState(() {
          _real = list;
          _found = _merged();
          if (_found.isNotEmpty) _state = _ScanState.found;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _state = _ScanState.problem;
          _problem = 'Scanning stopped: $e';
        });
      },
      onDone: () {
        _scan = null;
        if (!mounted) return;
        if (_found.isEmpty && _state == _ScanState.searching) {
          setState(() => _state = _ScanState.nothing);
        }
      },
    );
  }

  void _stopScan() {
    _scan?.cancel();
    _scan = null;
  }

  Future<void> _connect(FoundDevice found) async {
    _stopScan();
    setState(() => _state = _ScanState.connecting);
    try {
      await widget.pairing.connect(found, band: _band);
      if (!mounted) return;
      setState(() => _state = _ScanState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _ScanState.problem;
        _problem =
            "Couldn't connect to ${found.name}. Keep it close and try "
            'again.';
      });
    }
  }

  @override
  void dispose() {
    _stopScan();
    _status?.cancel();
    _demoTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (title, hint) = switch (_state) {
      _ScanState.searching => (
        'Looking for your $_name',
        _band
            ? 'Wake your Band and keep it next to your phone.'
            : 'Switch your Audios on and keep them near your phone.',
      ),
      _ScanState.found => ('Found your $_name', 'Tap it to connect.'),
      _ScanState.connecting => ('Connecting…', 'This takes a few seconds.'),
      _ScanState.connected => ('Connected', 'Your $_name is ready.'),
      _ScanState.nothing => (
        "Couldn't find your $_name",
        _band
            ? 'Make sure it is switched on and close by, then try again.'
            : Platform.isIOS
                ? 'Switch them on. The first time, connect them in your '
                      "iPhone's Settings › Bluetooth by choosing SM03, then "
                      'come back and try again.'
                : 'Make sure they are switched on and close by, then try '
                      'again.',
      ),
      _ScanState.problem => ('Something needs attention', _problem ?? ''),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.gutter,
        Tokens.x4,
        Tokens.gutter,
        Tokens.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 40),
          Expanded(
            flex: 5,
            child: Center(
              child: _Radar(
                active:
                    _state == _ScanState.searching ||
                    _state == _ScanState.connecting,
                done: _state == _ScanState.connected,
                device: widget.device,
              ),
            ),
          ),
          Text(title, style: Tokens.title, textAlign: TextAlign.center),
          const SizedBox(height: Tokens.x2),
          Text(
            hint,
            style: Tokens.body.copyWith(fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Tokens.x5),
          Expanded(
            flex: 3,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _state == _ScanState.found
                  ? ListView(
                      key: const ValueKey('list'),
                      padding: EdgeInsets.zero,
                      children: [
                        for (final d in _found)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Tokens.x2),
                            child: Surface(
                              radius: 18,
                              onTap: () => _connect(d),
                              padding: const EdgeInsets.symmetric(
                                horizontal: Tokens.x4,
                                vertical: Tokens.x3,
                              ),
                              child: Row(
                                children: [
                                  DeviceGlyph(
                                    device: widget.device,
                                    size: 32,
                                    color: Tokens.text,
                                  ),
                                  const SizedBox(width: Tokens.x3),
                                  Expanded(
                                    child: Text(
                                      d.name,
                                      style: Tokens.bodyStrong,
                                    ),
                                  ),
                                  _SignalBars(rssi: d.rssi),
                                ],
                              ),
                            ),
                          ),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey('empty')),
            ),
          ),
          if (_state == _ScanState.nothing || _state == _ScanState.problem)
            Padding(
              padding: const EdgeInsets.only(bottom: Tokens.x2),
              child: InkButton(label: 'Try again', onPressed: _start),
            ),
          if (_state != _ScanState.connected)
            TextButton(
              onPressed: () {
                _stopScan();
                widget.onDone();
              },
              child: Text(
                'Skip for now',
                style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rings rippling out from the device while searching; a tick once connected.
class _Radar extends StatefulWidget {
  const _Radar({
    required this.active,
    required this.done,
    required this.device,
  });

  final bool active;
  final bool done;
  final OrdinaryDevice device;

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _Radar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat();
    if (!widget.active && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 220,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            if (widget.active)
              for (var i = 0; i < 3; i++)
                Builder(
                  builder: (context) {
                    final t = (_c.value + i / 3) % 1.0;
                    return Container(
                      width: 90 + 130 * t,
                      height: 90 + 130 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Tokens.text.withValues(alpha: 0.25 * (1 - t)),
                          width: 1.5,
                        ),
                      ),
                    );
                  },
                ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.done ? Tokens.text : Tokens.paper2,
              ),
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: widget.done
                    ? const Icon(
                        Icons.check_rounded,
                        key: ValueKey('tick'),
                        color: Tokens.accentInk,
                        size: 44,
                      )
                    : DeviceGlyph(
                        key: const ValueKey('glyph'),
                        device: widget.device,
                        size: 58,
                        color: Tokens.text,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.rssi});

  final int rssi;

  @override
  Widget build(BuildContext context) {
    // -50 dBm and stronger is right beside the phone; -90 is at the edge.
    final level = ((rssi + 95) / 15).clamp(0, 3).round();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: const EdgeInsets.only(left: 2),
            width: 4,
            height: 6.0 + 4 * i,
            decoration: BoxDecoration(
              color: i < math.max(level, 1) ? Tokens.text : Tokens.rule,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

// -------------------------------------------------------------------- done

class _DoneStep extends StatelessWidget {
  const _DoneStep({super.key, required this.pairing, required this.onEnter});

  final Pairing pairing;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('Audios', pairing.audiosId != null, OrdinaryDevice.glasses),
      if (pairing.wantsBand)
        ('Band', pairing.bandId != null, OrdinaryDevice.band),
    ];
    final any = rows.any((r) => r.$2);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Tokens.gutter,
        Tokens.x4,
        Tokens.gutter,
        Tokens.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 40 + Tokens.x6),
          Text(any ? "You're all set" : 'Almost there', style: Tokens.display),
          const SizedBox(height: Tokens.x2),
          Text(
            any
                ? 'Say "Hey Ordinary" any time.'
                : 'You can pair your devices later from Settings.',
            style: Tokens.body.copyWith(fontSize: 16),
          ),
          const SizedBox(height: Tokens.x8),
          for (final (name, paired, glyph) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: Tokens.x3),
              child: Surface(
                radius: Tokens.rMedium,
                padding: const EdgeInsets.all(Tokens.x4),
                child: Row(
                  children: [
                    DeviceGlyph(device: glyph, size: 40, color: Tokens.text),
                    const SizedBox(width: Tokens.x4),
                    Expanded(child: Text(name, style: Tokens.heading)),
                    Text(
                      paired ? 'Paired' : 'Not paired',
                      style: Tokens.bodyStrong.copyWith(
                        fontSize: 13,
                        color: paired ? Tokens.connected : Tokens.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Spacer(),
          InkButton(label: 'Enter Ordinary', onPressed: onEnter),
        ],
      ),
    );
  }
}
