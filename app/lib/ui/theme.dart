import 'package:flutter/material.dart';

import '../data/settings_store.dart' show Appearance;

/// Design tokens, docs/KONZEPT.md "Design" table. Day and night are the
/// only two palettes. Which one a screen uses is decided by
/// [resolveFadenTokens]: Nachtmodus (signals/night.dart: night window or a
/// running sleep timer) always gets [night]; otherwise the "Erscheinungsbild"
/// setting picks [day] ("Hell"), [night] ("Dunkel") or follows the phone
/// ("Wie iPhone") -- decision E28 in docs/ARCHITEKTUR.md section 13.
///
/// Also a [ThemeExtension], so widgets below a Faden theme read the
/// current set with [FadenTokens.of] instead of hard-coding one.
class FadenTokens extends ThemeExtension<FadenTokens> {
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

  /// The token set of the surrounding theme (see [buildFadenTheme]); day
  /// if none is set, e.g. in a bare test widget.
  static FadenTokens of(BuildContext context) =>
      Theme.of(context).extension<FadenTokens>() ?? day;

  @override
  FadenTokens copyWith({
    Color? grund,
    Color? tinte,
    Color? tinteLeise,
    Color? faden,
    Color? knoten,
  }) =>
      FadenTokens(
        grund: grund ?? this.grund,
        tinte: tinte ?? this.tinte,
        tinteLeise: tinteLeise ?? this.tinteLeise,
        faden: faden ?? this.faden,
        knoten: knoten ?? this.knoten,
      );

  /// No colour blending: KONZEPT.md "Bewegung" allows no decorative
  /// animation, so a theme change switches the token set outright.
  @override
  FadenTokens lerp(covariant FadenTokens? other, double t) =>
      (other == null || t < 0.5) ? this : other;
}

/// The token set for a screen (decision E28): Nachtmodus ([nightMode])
/// overrides everything; otherwise [appearance] decides, with
/// [Appearance.system] following [platformBrightness]. "Dunkel" reuses the
/// night tokens, but only the look -- the Nachtmodus *behaviour* (cover
/// hidden, button lock) stays tied to [nightMode] in ui/player_screen.dart.
FadenTokens resolveFadenTokens({
  required Appearance appearance,
  required Brightness platformBrightness,
  required bool nightMode,
}) {
  if (nightMode) return FadenTokens.night;
  switch (appearance) {
    case Appearance.light:
      return FadenTokens.day;
    case Appearance.dark:
      return FadenTokens.night;
    case Appearance.system:
      return platformBrightness == Brightness.dark ? FadenTokens.night : FadenTokens.day;
  }
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
    extensions: [tokens],
  );
}
