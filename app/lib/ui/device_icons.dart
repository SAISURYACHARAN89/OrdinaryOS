import 'package:flutter/material.dart';

import 'tokens.dart';

/// Which Ordinary device something refers to.
///
/// Two different questions use this: which wearables are paired (the glasses
/// and the Band, shown as cards) and where Ordi's processing runs (the phone
/// or the Band, chosen with the selector — see [computeTargets]).
enum OrdinaryDevice {
  glasses,
  mobile,
  band;

  /// The choices for where Ordi runs.
  static const computeTargets = [mobile, band];
}

extension OrdinaryDeviceLabel on OrdinaryDevice {
  String get label => switch (this) {
        OrdinaryDevice.glasses => 'Glasses',
        OrdinaryDevice.mobile => 'Mobile',
        OrdinaryDevice.band => 'Band',
      };
}

/// Line drawings of the two products.
///
/// Drawn rather than shipped as assets: they sit at several sizes and pick up
/// the surrounding text colour, which a fixed-colour PNG cannot do. Both are
/// drawn front-on and left-right symmetric, matching how a system glyph reads
/// at a glance rather than as an illustration.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph({
    super.key,
    required this.device,
    this.size = 56,
    this.color,
  });

  final OrdinaryDevice device;
  final double size;

  /// Falls back to the ambient [IconTheme] when unset, so it can sit inside
  /// anything that tints icons.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? Tokens.text;
    return SizedBox(
      width: size,
      height: size * 0.6,
      child: CustomPaint(
        painter: switch (device) {
          OrdinaryDevice.glasses => _GlassesPainter(resolved),
          OrdinaryDevice.mobile => _PhonePainter(resolved),
          OrdinaryDevice.band => _BandPainter(resolved),
        },
      ),
    );
  }
}

class _GlassesPainter extends CustomPainter {
  _GlassesPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    // Front-on, symmetric: two lenses and a bridge, with short temple stubs
    // angling back at the outer edges. This is the shape a system glyph would
    // use — nothing about it depends on which side you look from.
    final lensW = w * 0.32;
    final lensH = h * 0.62;
    final lensY = h * 0.19;
    final bridgeGap = w * 0.10;

    final leftLens = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.06, lensY, lensW, lensH),
      Radius.circular(lensH * 0.34),
    );
    final rightLens = RRect.fromRectAndRadius(
      Rect.fromLTWH(w - w * 0.06 - lensW, lensY, lensW, lensH),
      Radius.circular(lensH * 0.34),
    );
    canvas.drawRRect(leftLens, stroke);
    canvas.drawRRect(rightLens, stroke);

    final centre = h * (0.19 + 0.62 / 2);
    canvas.drawLine(
      Offset(w * 0.06 + lensW + bridgeGap * 0.15, centre),
      Offset(w * 0.94 - lensW - bridgeGap * 0.15, centre),
      stroke,
    );

    // Temple stubs — just enough to read as glasses rather than goggles.
    canvas.drawLine(
      Offset(w * 0.06, lensY + lensH * 0.3),
      Offset(0, lensY + lensH * 0.15),
      stroke,
    );
    canvas.drawLine(
      Offset(w * 0.94, lensY + lensH * 0.3),
      Offset(w, lensY + lensH * 0.15),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_GlassesPainter old) => old.color != color;
}

/// A phone, upright and centred in the same box the other glyphs use, with
/// the same stroke weight so the two cards read as a pair.
class _PhonePainter extends CustomPainter {
  _PhonePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.13 * 0.75
      ..strokeCap = StrokeCap.round;

    final bodyH = h * 0.96;
    final bodyW = bodyH * 0.52;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(size.width / 2, h / 2), width: bodyW, height: bodyH),
      Radius.circular(bodyW * 0.26),
    );
    canvas.drawRRect(body, stroke);

    // The speaker slot at the top.
    final slotY = body.top + bodyH * 0.14;
    canvas.drawLine(
      Offset(size.width / 2 - bodyW * 0.14, slotY),
      Offset(size.width / 2 + bodyW * 0.14, slotY),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_PhonePainter old) => old.color != color;
}

class _BandPainter extends CustomPainter {
  _BandPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.13
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;

    // A flat, symmetric capsule for the strap with a small rounded square for
    // the module — the reduced, glyph-like version of a fitness band, seen
    // from directly above rather than at an angle.
    final strap = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.06, h * 0.30, w * 0.88, h * 0.40),
      Radius.circular(h * 0.20),
    );
    canvas.drawRRect(strap, stroke);

    final module = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(w / 2, h / 2),
        width: h * 0.58,
        height: h * 0.58,
      ),
      Radius.circular(h * 0.14),
    );
    canvas.drawRRect(module, stroke);
  }

  @override
  bool shouldRepaint(_BandPainter old) => old.color != color;
}
