import 'package:flutter/material.dart';

/// Design tokens for the Ordinary app.
///
/// Everything visual references this file. Raw hex values and magic numbers in
/// widgets are how a UI drifts out of alignment one commit at a time.
///
/// Light theme, matching Apple's own light-mode surfaces (Health, Settings,
/// Control Center): a soft grey page, white cards, near-black text, and colour
/// used only where it carries meaning — the green connected dot and nothing
/// else. Real Liquid Glass refracts and lenses the content behind it using
/// Apple's own renderer, which Flutter cannot reach, so the illusion here is
/// built from blur plus a soft shadow plus a hairline border — on a light
/// background the shadow is doing most of the work a coloured edge did on
/// dark, because a light border on a light card is nearly invisible.
class Tokens {
  const Tokens._();

  // ---------------------------------------------------------------- colour

  /// The page. Apple's systemGroupedBackground — a soft grey rather than pure
  /// white, so that white cards sitting on it actually read as raised.
  static const Color ink = Color(0xFFF2F2F7);
  static const Color inkRaised = Color(0xFFFFFFFF);

  /// The hairline. On a light card, a light border disappears — this is a
  /// soft black at low opacity, the same trick Apple's own cards use.
  static const Color edgeLit = Color(0x14000000);   // 8%
  static const Color edgeShade = Color(0x08000000); // 3%

  // Text, from Apple's label/secondaryLabel/tertiaryLabel scale.
  static const Color text = Color(0xFF1C1C1E);
  static const Color textSoft = Color(0x993C3C43);  // ~60%
  static const Color textFaint = Color(0x603C3C43); // ~38%

  /// Status. The one colour this UI carries deliberately — everything else is
  /// grayscale, so the connected dot means something the moment you see it.
  static const Color connected = Color(0xFF34C759);
  static const Color danger = Color(0xFFFF3B30);

  /// One accent, used only for selection — never decoration.
  static const Color accent = Color(0xFF0A84FF);

  // --------------------------------------------------------------- spacing

  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x10 = 40;

  /// The page gutter. Every full-width element aligns to this.
  static const double gutter = 20;

  // ---------------------------------------------------------------- shape

  static const double rSmall = 14;
  static const double rMedium = 22;
  static const double rLarge = 28;
  static const double rPill = 999;

  /// How hard the backdrop is blurred.
  static const double blur = 24;

  // ------------------------------------------------------------ typography

  /// System font throughout — on iOS that resolves to SF, which is half of
  /// why Apple's UI looks like Apple's UI.
  static TextStyle get display => const TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        color: text,
        height: 1.1,
      );

  static TextStyle get title => const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
        color: text,
      );

  static TextStyle get heading => const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: text,
      );

  static TextStyle get body => const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: textSoft,
        height: 1.4,
      );

  /// Percentages and balances. Tight tracking so large numerals sit together
  /// rather than sprawling.
  static TextStyle get numeral => const TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: -1.0,
        color: text,
        fontFeatures: [FontFeature.tabularFigures()],
      );

  static TextStyle get label => const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.1,
        color: textFaint,
      );

  static TextStyle get caption => const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: textFaint,
      );
}
