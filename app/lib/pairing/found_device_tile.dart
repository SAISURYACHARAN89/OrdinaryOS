import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pairing.dart';
import '../ui/device_icons.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// Where a found device is in being connected.
enum TileLink { idle, connecting, connected }

/// One device found by a scan: its glyph, its Bluetooth name, and either its
/// signal strength or how connecting to it is going.
class FoundDeviceTile extends StatelessWidget {
  const FoundDeviceTile({
    super.key,
    required this.found,
    required this.device,
    required this.link,
    this.onTap,
  });

  final FoundDevice found;
  final OrdinaryDevice device;
  final TileLink link;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final trailing = switch (link) {
      TileLink.idle => _SignalBars(rssi: found.rssi),
      TileLink.connecting => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Tokens.text),
      ),
      TileLink.connected => Text(
        'Connected',
        style: Tokens.bodyStrong.copyWith(
          fontSize: 13,
          color: Tokens.connected,
        ),
      ),
    };
    return Semantics(
      button: link == TileLink.idle,
      label: switch (link) {
        TileLink.idle => '${found.name}, tap to connect',
        TileLink.connecting => '${found.name}, connecting',
        TileLink.connected => '${found.name}, connected',
      },
      excludeSemantics: true,
      child: Surface(
        radius: 18,
        onTap: link == TileLink.idle ? onTap : null,
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.x4,
          vertical: Tokens.x3,
        ),
        child: Row(
          children: [
            DeviceGlyph(device: device, size: 32, color: Tokens.text),
            const SizedBox(width: Tokens.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(found.name, style: Tokens.bodyStrong),
                  Text(
                    'Nearby',
                    style: Tokens.body.copyWith(
                      fontSize: 12,
                      color: Tokens.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(key: ValueKey(link), child: trailing),
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
      mainAxisSize: MainAxisSize.min,
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
