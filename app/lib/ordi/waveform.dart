import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ordi_audio/ordi_audio.dart';

import '../ui/tokens.dart';

/// Ordi, drawn as a line rather than an orb.
///
/// The glowing orange orb was replaced deliberately: it read as a toy, and the
/// glow fought everything else on screen. What mattered about it was that it
/// visibly responded to the voice, so that is what survives — bars that move
/// with real amplitude, in monochrome.
///
/// Each state has its own behaviour, because "is it hearing me / thinking /
/// answering" has to be readable at a glance with no text:
///
///   idle      — a nearly flat line, barely breathing
///   listening — bars driven by microphone level
///   thinking  — a pulse rippling outward from the centre, not a spinner
///   speaking  — bars driven by playback level, so it moves with Ordi's voice
///
/// The bar pattern is generated as a function of distance from the centre bar,
/// not of absolute position — a wave keyed to absolute index looks lopsided at
/// any given instant even though the widget itself sits centred on screen.
/// Mirroring around the centre is what makes it read as centred rather than
/// merely be positioned there.
class Waveform extends StatefulWidget {
  const Waveform({
    super.key,
    this.state = OrdiState.idle,
    this.amplitude = 0,
    this.width = 260,
    this.height = 64,
  });

  final OrdiState state;

  /// 0..1, already mapped from dBFS natively.
  final double amplitude;

  final double width;
  final double height;

  @override
  State<Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<Waveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;

  /// Raw levels jump far too hard between frames to drive geometry directly,
  /// so the drawn value eases toward the real one.
  double _smoothed = 0;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: _clock,
        builder: (context, _) {
          final target = widget.amplitude.clamp(0.0, 1.0);
          // Rises quickly so speech feels immediate, falls slowly so the line
          // does not flicker between syllables.
          final rate = target > _smoothed ? 0.35 : 0.12;
          _smoothed += (target - _smoothed) * rate;

          return CustomPaint(
            size: Size(widget.width, widget.height),
            painter: _WaveformPainter(
              t: _clock.value * 2 * math.pi,
              state: widget.state,
              amplitude: _smoothed,
            ),
          );
        },
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.t,
    required this.state,
    required this.amplitude,
  });

  final double t;
  final OrdiState state;
  final double amplitude;

  /// Odd, so there is a true centre bar rather than a seam between two.
  static const int _bars = 41;
  static const int _centre = _bars ~/ 2;

  @override
  void paint(Canvas canvas, Size size) {
    final centreY = size.height / 2;
    final gap = size.width / (_bars - 1);
    final barWidth = math.max(2.0, gap * 0.30);

    for (var i = 0; i < _bars; i++) {
      final x = i * gap;

      // Distance from the centre bar, 0 in the middle rising to 1 at the
      // ends. Every calculation below is a function of this, never of the raw
      // index — that is what keeps the shape mirror-symmetric.
      final d = (i - _centre).abs() / _centre;
      final taper = math.cos(d * math.pi / 2).clamp(0.0, 1.0);

      final h = _heightFor(d, taper) * size.height;
      final opacity = _opacityFor(taper);

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, centreY),
          width: barWidth,
          height: math.max(barWidth, h),
        ),
        Radius.circular(barWidth),
      );

      canvas.drawRRect(
        rect,
        Paint()..color = Tokens.text.withValues(alpha: opacity),
      );
    }
  }

  double _heightFor(double d, double taper) {
    switch (state) {
      case OrdiState.idle:
        // Present, not demanding attention: a slow shallow swell, uniform
        // across the line rather than travelling.
        final breath = math.sin(t * 0.6);
        return (0.045 + breath * 0.012) * taper;

      case OrdiState.listening:
      case OrdiState.speaking:
        // Driven by the voice. Two harmonics of distance-from-centre at
        // unrelated frequencies keep the bars from moving as one flat block,
        // while staying identical on both sides of the centre.
        final wobble = math.sin(t * 2.1 + d * 6.0) * 0.35 +
            math.sin(t * 3.3 - d * 4.2) * 0.22;
        final drive = amplitude * (0.72 + wobble * amplitude);
        return (0.05 + drive * 0.80) * taper;

      case OrdiState.thinking:
        // A ring travelling outward from the centre and looping back —
        // deliberately not a spinner, and unambiguously centred since it
        // originates there.
        final radius = (t * 0.5) % 1.0;
        final crest = math.exp(-math.pow(d - radius, 2) * 26);
        return (0.05 + crest * 0.34) * taper;
    }
  }

  double _opacityFor(double taper) {
    final base = switch (state) {
      OrdiState.idle => 0.28,
      OrdiState.listening => 0.55 + amplitude * 0.40,
      OrdiState.thinking => 0.50,
      OrdiState.speaking => 0.60 + amplitude * 0.35,
    };
    return (base * (0.35 + taper * 0.65)).clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.t != t || old.state != state || old.amplitude != amplitude;
}
