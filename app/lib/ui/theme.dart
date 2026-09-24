import 'package:flutter/material.dart';

/// Design tokens, docs/KONZEPT.md "Design" table. Day and night are two
/// fixed palettes chosen by the app's own night-mode logic
/// (signals/night.dart: night window or a running sleep timer), never by
/// the OS "dark mode" setting -- KONZEPT.md ties night mode to the sleep
/// use case, not to system theme.
class FadenTokens {
  final Color grund; // background
  final Color tinte; // text
  final Color tinteLeise; // secondary text
  final Color faden; // thread, main button
  final Color knoten; // current position

  const FadenTokens({
    required this.grund,
    required this.tinte,
    required this.tinteLeise,
    required this.faden,
    required this.knoten,
  });

  static const day = FadenTokens(
    grund: Color(0xFFEEF0F3),
    tinte: Color(0xFF1C2130),
    tinteLeise: Color(0xFF5E6577),
    faden: Color(0xFF3346A8),
    knoten: Color(0xFF1C2130),
  );

  static const night = FadenTokens(
    grund: Color(0xFF000000),
    tinte: Color(0xFF9A8F80),
    tinteLeise: Color(0xFF7D7366),
    faden: Color(0xFFE0A03A),
    knoten: Color(0xFFF2C879),
  );

  /// Rest of the thread (KONZEPT.md "Faden": "Rest in tinte-leise mit 40 %
  /// Deckkraft").
  Color get tinteLeiseFaden => tinteLeise.withValues(alpha: 0.4);
}

/// Font family bundled in pubspec.yaml (assets/fonts, OFL license in
/// assets/fonts/OFL.txt). KONZEPT.md asks for "Atkinson Hyperlegible Next"
/// specifically with "Atkinson Hyperlegible" as a documented fallback; the
/// exact family was obtainable in this sandbox (see decision E15 in
/// docs/ARCHITEKTUR.md section 13), so no fallback substitution was needed.
const String fadenFontFamily = 'Atkinson Hyperlegible Next';

/// Type sizes, KONZEPT.md "Design": "Größen 28, 20, 17, 14 sp."
class FadenTypeSizes {
  const FadenTypeSizes._();

  static const display = 28.0;
  static const title = 20.0;
  static const body = 17.0;
  static const caption = 14.0;
}

/// Minimum tap target, KONZEPT.md "Layout": "Alle Tippziele mindestens 56
/// dp."
const double fadenMinTapTarget = 56.0;

/// Minimum main-button size, KONZEPT.md "Hauptbutton": "mindestens 88 dp."
const double fadenMainButtonSize = 88.0;

ThemeData buildFadenTheme(FadenTokens tokens) {
  final brightness = tokens.grund.computeLuminance() > 0.5 ? Brightness.light : Brightness.dark;
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: tokens.faden,
    onPrimary: tokens.grund,
    secondary: tokens.tinteLeise,
    onSecondary: tokens.grund,
    error: const Color(0xFFB3261E),
    onError: tokens.grund,
    surface: tokens.grund,
    onSurface: tokens.tinte,
  );
  final textTheme = TextTheme(
    headlineLarge: TextStyle(fontSize: FadenTypeSizes.display, color: tokens.tinte),
    titleLarge: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte),
    bodyLarge: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte),
    bodyMedium: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte),
    bodySmall: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: tokens.grund,
    fontFamily: fadenFontFamily,
    textTheme: textTheme,
    // KONZEPT.md "Bewegung": "keine Deko-Animationen; die System-Einstellung
    // 'Bewegung reduzieren' gilt" -- pages still transition, but without an
    // app-specific flourish; page transitions are the platform default,
    // which already respects the OS reduce-motion setting.
    visualDensity: VisualDensity.standard,
  );
}
