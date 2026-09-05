import 'package:flutter/material.dart';

/// The words Ordi is saying, as it says them.
///
/// Answers arrive as a growing stream of fragments, so this is a window that
/// follows the end of the text rather than a block that keeps expanding. Older
/// lines scroll up and dissolve at the top edge instead of being cut off — a
/// hard clip reads as broken, a fade reads as deliberate.
///
/// It stays deliberately quiet. The orb is the thing being looked at; the text
/// is there for a noisy room, sound off, or re-reading an explanation.
class SpokenText extends StatefulWidget {
  const SpokenText({
    super.key,
    required this.text,
    this.maxHeight = 132,
  });

  final String text;

  /// About five lines. Past that the fade does the work.
  final double maxHeight;

  @override
  State<SpokenText> createState() => _SpokenTextState();
}

class _SpokenTextState extends State<SpokenText> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(SpokenText old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text) _follow();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keep the newest words in view. Jumping rather than animating: fragments
  /// land several times a second, and overlapping scroll animations fight each
  /// other into visible stutter.
  void _follow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.text.isEmpty;

    return AnimatedOpacity(
      opacity: empty ? 0 : 1,
      duration: const Duration(milliseconds: 280),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // Transparent at the very top through to solid a third of the way
            // down: older text thins out as it leaves rather than vanishing.
            colors: [Colors.transparent, Colors.black, Colors.black],
            stops: [0.0, 0.34, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: SingleChildScrollView(
            controller: _scroll,
            // The text follows itself; dragging it is not the point.
            physics: const NeverScrollableScrollPhysics(),
            child: Text(
              widget.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 16,
                height: 1.45,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
