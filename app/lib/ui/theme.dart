import 'package:flutter/material.dart';

import 'tokens.dart';

/// The app-wide theme: white page, ink primary, Libre Franklin body text.
/// Headings pick up Playfair Display through [Tokens] rather than here.
ThemeData ordiTheme() {
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: Tokens.paper,
    useMaterial3: true,
    fontFamily: Tokens.bodyFamily,
    colorScheme: const ColorScheme.light(
      primary: Tokens.text,
      onPrimary: Tokens.accentInk,
      surface: Tokens.paper,
      onSurface: Tokens.text,
      error: Tokens.danger,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Tokens.text,
      selectionColor: Tokens.rule,
      selectionHandleColor: Tokens.text,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Tokens.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.rMedium),
      ),
      titleTextStyle: Tokens.heading,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Tokens.text,
        textStyle: Tokens.bodyStrong,
      ),
    ),
    splashFactory: NoSplash.splashFactory,
  );
}
