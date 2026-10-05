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
        OrdinaryDevice.glasses => 'Audios',
        OrdinaryDevice.mobile => 'Mobile',
        OrdinaryDevice.band => 'Band',
      };
}

/// The glasses and the Band as product photos; the phone as a line drawing.
///
/// The photos are black products on transparent backgrounds. On a light
/// surface they show as they are; when the requested colour is light (a
/// selected, ink-filled card) they become a silhouette in that colour so they
/// don't vanish into the fill.
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
    final photo = switch (device) {
      OrdinaryDevice.glasses => 'assets/devices/glasses.png',
      OrdinaryDevice.band => 'assets/devices/band.png',
      OrdinaryDevice.mobile => null,
    };
    if (photo == null) {
      return SizedBox(
        width: size,
        height: size * 0.6,
        child: CustomPaint(painter: _PhonePainter(resolved)),
      );
    }
    Widget image = Image.asset(
      photo,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    );
    if (resolved.computeLuminance() > 0.5) {
      image = ColorFiltered(
        colorFilter: ColorFilter.mode(resolved, BlendMode.srcIn),
        child: image,
      );
    }
    return SizedBox(width: size, height: size * 0.6, child: image);
  }
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
