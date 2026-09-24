import 'package:flutter/material.dart';

import 'tokens.dart';

/// A flat card: [Tokens.paper2] on the white page, no blur, no shadow, no
/// border. When it has an [onTap] it scales down slightly under the finger.
class Surface extends StatefulWidget {
  const Surface({
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
  final Color? fill;
  final VoidCallback? onTap;

  @override
  State<Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<Surface> {
  bool _pressed = false;

  /// A rapid double-tap could land a second tap before the first one's
  /// navigation had visibly started, pushing the destination twice.
  DateTime? _lastTapAt;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  void _handleTap() {
    final now = DateTime.now();
    final last = _lastTapAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastTapAt = now;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Animated so a card that changes fill — a selected voice, say — fades
    // between colours instead of snapping.
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.fill ?? Tokens.paper2,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: widget.child,
    );

    if (widget.onTap == null) return card;

    return GestureDetector(
      onTap: _handleTap,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
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

/// The app's ground: plain white.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: Tokens.paper, child: child);
  }
}

/// The top bar every pushed screen shares: a back chevron and a centred
/// serif title.
PreferredSizeWidget screenBar(
  BuildContext context, {
  Widget? title,
  String? text,
  List<Widget>? actions,
  VoidCallback? onBack,
}) {
  return AppBar(
    backgroundColor: Tokens.paper,
    surfaceTintColor: Colors.transparent,
    scrolledUnderElevation: 0,
    elevation: 0,
    leading: IconButton(
      icon: const Icon(Icons.chevron_left_rounded, color: Tokens.text, size: 30),
      onPressed: onBack ?? () => Navigator.of(context).maybePop(),
    ),
    title: title ??
        Text(text ?? '',
            style: Tokens.heading, maxLines: 1, overflow: TextOverflow.ellipsis),
    centerTitle: true,
    actions: actions,
  );
}

/// A round icon button. Centred explicitly — an icon in a bare box is left
/// wherever the text baseline puts it.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 34,
    this.iconSize = 18,
    this.filled = false,
    this.onPaper2 = false,
    this.iconColor,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;

  /// Solid ink with a white glyph, versus a grey disc with an ink glyph.
  final bool filled;

  /// For a button that sits on a grey card: a white disc with a faint glyph.
  final bool onPaper2;

  /// Overrides the glyph colour of an unfilled button.
  final Color? iconColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled
              ? Tokens.text
              : onPaper2
                  ? Tokens.paper
                  : Tokens.paper2,
        ),
        child: Icon(icon,
            size: iconSize,
            color: filled ? Tokens.accentInk : iconColor ?? Tokens.text),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The black "+" that floats at the bottom-right of the Study screens.
class InkFab extends StatelessWidget {
  const InkFab({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: FloatingActionButton(
        onPressed: onPressed,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        backgroundColor: Tokens.text,
        foregroundColor: Tokens.accentInk,
        shape: const CircleBorder(),
        child: const Icon(Icons.add_rounded, size: 26),
      ),
    );
  }
}

/// A full-width black pill button.
class InkButton extends StatelessWidget {
  const InkButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Tokens.text,
          foregroundColor: Tokens.accentInk,
          disabledBackgroundColor: Tokens.rule,
          disabledForegroundColor: Tokens.textFaint,
          padding: const EdgeInsets.symmetric(vertical: Tokens.x4),
          shape: const StadiumBorder(),
          textStyle: Tokens.bodyStrong,
        ),
        child: Text(label),
      ),
    );
  }
}

/// A screen's empty-state message.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Tokens.x6),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Tokens.body.copyWith(color: Tokens.textFaint),
        ),
      ),
    );
  }
}
