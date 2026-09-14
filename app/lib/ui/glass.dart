import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'tokens.dart';

/// A pane of real, shader-driven liquid glass.
///
/// This replaces an earlier hand-built version on top of `oc_liquid_glass`,
/// dropped after two of its limitations turned out to be unfixable from the
/// outside: the specular rim lit a shape from two opposing directions at
/// once with no way to use just one, and the shader's own backdrop sampling
/// had no clip, so refraction bled into whatever sat a few pixels below a
/// card — the reason refraction ended up disabled entirely for a while.
/// `liquid_glass_widgets` (github.com/sdegenaar/liquid_glass_widgets) solves
/// both properly: real texture-capture backdrop isolation per layer, and a
/// specular model that doesn't need to be neutered to look right.
///
/// Each card renders with `useOwnLayer: true` rather than joining a shared
/// `AdaptiveLiquidGlassLayer` — cards here are scattered across a scrolling
/// list, not a fixed cluster meant to visually merge, so there's nothing to
/// gain from grouping them and real cost (a shared layer re-renders together)
/// to lose.
///
/// Quality is [GlassQuality.minimal] — a `BackdropFilter` blur plus a
/// specular rim stroke, zero fragment-shader invocations — rather than
/// [GlassQuality.standard]'s real refraction shader. The package's own docs
/// call this out specifically: many simultaneous `standard`-quality cards in
/// one scrolling list is real, measurable GPU cost, and this dashboard runs
/// six to eight of these at once. `minimal` reads as "a high-quality frosted
/// panel" per the docs, which is the right trade for a *list* of cards —
/// reserve `standard`/`premium` for a single non-scrolling focal surface if
/// one is ever added, not for content that repeats down a list.
class GlassSurface extends StatefulWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = Tokens.rMedium,
    this.padding = const EdgeInsets.all(Tokens.x4),
    this.fill,
    this.onTap,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;

  /// Escape hatch to override the glass tint entirely. Leave null for the
  /// standard light tint.
  final Color? fill;
  final VoidCallback? onTap;

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  bool _pressed = false;

  /// Guards against a rapid double-tap firing [onTap] twice — with a
  /// shader-backed card, a slow frame between the two taps was enough of a
  /// window that a second tap could land before the first one's navigation
  /// had visually started, pushing the destination screen twice.
  DateTime? _lastTapAt;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  void _handleTap() {
    final now = DateTime.now();
    final last = _lastTapAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastTapAt = now;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final card = GlassCard(
      shape: LiquidRoundedSuperellipse(borderRadius: widget.radius),
      padding: EdgeInsets.zero,
      useOwnLayer: true,
      quality: GlassQuality.minimal,
      settings: LiquidGlassSettings(
        glassColor: widget.fill ?? Colors.white.withValues(alpha: 0.34),
        thickness: 24,
        blur: 5,
        refractiveIndex: 1.2,
        lightIntensity: 0.55,
      ),
      child: Padding(padding: widget.padding, child: widget.child),
    );

    if (widget.onTap == null) return card;

    return GestureDetector(
      onTap: _handleTap,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      // deferToChild (the default) only counts as a hit where the child
      // itself is hit-testable at that exact point — with a shader-backed
      // render object that isn't guaranteed to match the visual bounds pixel
      // for pixel. opaque makes the whole card's bounding box tappable
      // regardless, which is what "the touch doesn't register near the
      // edges" actually needed.
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: card,
      ),
    );
  }
}

/// The app's ground.
///
/// A plain soft grey — an Apple light surface does not need decoration behind
/// it, and glass now has something better than a flat colour to refract
/// anyway: whatever passes behind a panel as the page scrolls.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: Tokens.ink, child: child);
  }
}
