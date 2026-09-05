import 'dart:math' as math;
import 'package:flutter/material.dart';

/// What Ordi is doing. The orb reads differently for each.
enum OrbState { idle, listening, thinking, speaking }

/// The living orb.
///
/// [amplitude] is 0..1 and is meant to be driven by real audio — mic level
/// while listening, playback level while speaking. Until the audio pipeline
/// exists it can be left at 0 and the orb still breathes on its own.
class Orb extends StatefulWidget {
  const Orb({
    super.key,
    this.state = OrbState.idle,
    this.amplitude = 0.0,
    this.size = 260,
  });

  final OrbState state;
  final double amplitude;
  final double size;

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with SingleTickerProviderStateMixin {
  late final AnimationController _clock;

  // Amplitude is smoothed so the orb never snaps between frames — raw mic
  // levels are far too jittery to drive geometry directly.
  double _smoothed = 0.0;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _clock,
      builder: (context, _) {
        // Ease toward the target rather than jumping to it.
        _smoothed += (widget.amplitude.clamp(0.0, 1.0) - _smoothed) * 0.18;
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(
            t: _clock.value * 2 * math.pi,
            state: widget.state,
            amplitude: _smoothed,
          ),
        );
      },
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.t,
    required this.state,
    required this.amplitude,
  });

  final double t;
  final OrbState state;
  final double amplitude;

  // Warm core through amber to a violet rim — deliberately not the blue/white
  // every other voice assistant uses.
  static const _core = Color(0xFFFFE4BC);
  static const _mid = Color(0xFFFF8F5C);
  static const _rim = Color(0xFF8B5CF6);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final base = size.width * 0.34;

    final motion = _motionFor(state);
    final breath = 1 + math.sin(t * motion.breathRate) * motion.breathDepth;
    final radius = base * breath * (1 + amplitude * motion.reactivity);

    _paintGlow(canvas, center, radius, motion);
    final path = _bodyPath(center, radius, motion);
    _paintBody(canvas, path, center, radius, motion);
    _paintHighlight(canvas, center, radius);
  }

  /// Radius perturbed by a few harmonics at unrelated frequencies, so the
  /// silhouette never repeats exactly and reads as alive rather than looped.
  Path _bodyPath(Offset center, double radius, _Motion m) {
    const steps = 160;
    final wobble = m.wobble + amplitude * m.reactivity * 0.5;
    final path = Path();

    for (var i = 0; i <= steps; i++) {
      final a = (i / steps) * 2 * math.pi;
      final d = 1 +
          math.sin(a * 3 + t * 1.3 * m.speed) * wobble +
          math.sin(a * 5 - t * 0.9 * m.speed) * wobble * 0.55 +
          math.sin(a * 2 + t * 1.9 * m.speed) * wobble * 0.35;
      final r = radius * d;
      final p = Offset(center.dx + math.cos(a) * r, center.dy + math.sin(a) * r);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  void _paintGlow(Canvas canvas, Offset center, double radius, _Motion m) {
    // Two passes: a wide ambient bloom, then a tighter warmer one.
    canvas.drawCircle(
      center,
      radius * 1.9,
      Paint()
        ..color = _mid.withValues(alpha: 0.10 + amplitude * 0.10)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.75),
    );
    canvas.drawCircle(
      center,
      radius * 1.25,
      Paint()
        ..color = _mid.withValues(alpha: 0.20 + amplitude * 0.18)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.35),
    );
  }

  void _paintBody(
      Canvas canvas, Path path, Offset center, double radius, _Motion m) {
    final shader = RadialGradient(
      center: const Alignment(-0.28, -0.34),
      radius: 0.95,
      colors: [_core, _mid, _rim],
      stops: const [0.0, 0.48, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius * 1.15));

    canvas.drawPath(path, Paint()..shader = shader);

    // Rim light keeps the edge from going muddy against the dark ground.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = _core.withValues(alpha: 0.30 + amplitude * 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  void _paintHighlight(Canvas canvas, Offset center, double radius) {
    final o = Offset(center.dx - radius * 0.30, center.dy - radius * 0.36);
    canvas.drawCircle(
      o,
      radius * 0.30,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.20)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.30),
    );
  }

  _Motion _motionFor(OrbState s) => switch (s) {
        // Barely moving. Present, not demanding attention.
        OrbState.idle =>
          const _Motion(breathRate: .55, breathDepth: .030, wobble: .012, speed: .5, reactivity: .00),
        // Open and attentive, geometry driven by the user's voice.
        OrbState.listening =>
          const _Motion(breathRate: 1.10, breathDepth: .022, wobble: .020, speed: 1.2, reactivity: .30),
        // Tighter and quicker — visibly working, deliberately not a spinner.
        OrbState.thinking =>
          const _Motion(breathRate: 2.40, breathDepth: .045, wobble: .045, speed: 2.4, reactivity: .00),
        // Driven by playback level so the orb moves with Ordi's own voice.
        OrbState.speaking =>
          const _Motion(breathRate: 1.30, breathDepth: .028, wobble: .026, speed: 1.5, reactivity: .34),
      };

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.t != t || old.state != state || old.amplitude != amplitude;
}

class _Motion {
  const _Motion({
    required this.breathRate,
    required this.breathDepth,
    required this.wobble,
    required this.speed,
    required this.reactivity,
  });

  final double breathRate;
  final double breathDepth;
  final double wobble;
  final double speed;

  /// How strongly live audio deforms and brightens the orb.
  final double reactivity;
}
