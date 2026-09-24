import 'package:flutter/material.dart';

/// Design tokens for the Ordinary app — the "Terracotta Field" system, in its
/// monochrome revision (see `design.md` at the repo root).
///
/// Everything visual references this file. Raw hex values and magic numbers in
/// widgets are how a UI drifts out of alignment one commit at a time.
///
/// Pure black on white with a single light-grey card fill. There is no brand
/// hue: every "selected / primary" fill is solid ink, and the only colour in
/// the app is the green connected dot and the red recording / delete signal.
/// Cards are flat — no blur, no shadow, no border.
class Tokens {
  const Tokens._();

  // ---------------------------------------------------------------- colour

  /// The page.
  static const Color paper = Color(0xFFFFFFFF);

  /// Card and tile fill, sitting on [paper].
  static const Color paper2 = Color(0xFFF4F4F4);

  /// Hairlines — strong and quiet.
  static const Color rule = Color(0xFFE2E2E2);
  static const Color ruleSoft = Color(0xFFECECEC);

  /// Primary text, icons, and every "accent" fill.
  static const Color text = Color(0xFF111111);
  static const Color textSoft = Color(0xFF4A4A4A);
  static const Color textFaint = Color(0xFF8A8A8A);

  /// Content drawn on top of an ink fill.
  static const Color accentInk = Color(0xFFFFFFFF);

  /// Status only — never decorative, never for headings or brand moments.
  static const Color connected = Color(0xFF348F4F);
  static const Color danger = Color(0xFFC8393A);

  /// The one accent is ink itself.
  static const Color accent = text;

  // Names the rest of the app was written against. They now point at the new
  // palette so a screen that hasn't been restyled still renders correctly.
  static const Color ink = paper;
  static const Color inkRaised = paper2;
  static const Color edgeLit = rule;
  static const Color edgeShade = ruleSoft;

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

  static const double rBadge = 15;
  static const double rSmall = 14;
  static const double rMedium = 22;
  static const double rLarge = 28;
  static const double rPill = 999;

  // ------------------------------------------------------------ typography

  /// Headings and titles: a high-contrast classic serif.
  static const String displayFamily = 'Playfair Display';

  /// Everything else: a plain grotesque with a classic feel.
  static const String bodyFamily = 'Libre Franklin';

  // Both faces are variable fonts, so the weight has to be requested on the
  // axis as well as through `fontWeight` (which only picks a named instance
  // on a static family).
  static List<FontVariation> _wght(double w) => [FontVariation('wght', w)];

  static TextStyle get display => TextStyle(
        fontFamily: displayFamily,
        fontSize: 34,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: -0.6,
        color: text,
        height: 1.1,
      );

  static TextStyle get title => TextStyle(
        fontFamily: displayFamily,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: -0.3,
        color: text,
        height: 1.15,
      );

  static TextStyle get heading => TextStyle(
        fontFamily: displayFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: -0.1,
        color: text,
        height: 1.2,
      );

  static TextStyle get body => TextStyle(
        fontFamily: bodyFamily,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        fontVariations: _wght(400),
        color: textSoft,
        height: 1.4,
      );

  /// Body-size text that has to read as a label or a value rather than prose.
  static TextStyle get bodyStrong => TextStyle(
        fontFamily: bodyFamily,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        color: text,
        height: 1.3,
      );

  /// Balances and counts.
  static TextStyle get numeral => TextStyle(
        fontFamily: bodyFamily,
        fontSize: 26,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: -0.6,
        color: text,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Small section labels — set the text in upper case at the call site.
  static TextStyle get label => TextStyle(
        fontFamily: bodyFamily,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        fontVariations: _wght(600),
        letterSpacing: 1.0,
        color: textFaint,
      );

  /// Timestamps and counts.
  static TextStyle get caption => TextStyle(
        fontFamily: bodyFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        fontVariations: _wght(500),
        letterSpacing: 0.2,
        color: textFaint,
      );
}
