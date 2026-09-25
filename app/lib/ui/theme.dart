import 'package:flutter/material.dart';

import '../data/settings_store.dart' show Appearance;

/// Design tokens, docs/KONZEPT.md "Design" table. Day and night are the
/// only two palettes. Which one a screen uses is decided by
/// [resolveFadenTokens]: the night view (display brightness below 30 %,
/// decision E54) always gets [night]; otherwise the "Erscheinungsbild"
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

  /// Errors (failed download, playback error). Not in the KONZEPT.md
  /// table; decision E45: a red that keeps 4.5:1 on [grund], warm at
  /// night.
  final Color fehler;

  const FadenTokens({
    required this.grund,
    required this.tinte,
    required this.tinteLeise,
    required this.faden,
    required this.knoten,
    required this.fehler,
  });

  static const day = FadenTokens(
    grund: Color(0xFFEEF0F3),
    tinte: Color(0xFF1C2130),
    tinteLeise: Color(0xFF5E6577),
    faden: Color(0xFF3346A8),
    knoten: Color(0xFF1C2130),
    fehler: Color(0xFFB3261E),
  );

  static const night = FadenTokens(
    grund: Color(0xFF000000),
    tinte: Color(0xFF9A8F80),
    tinteLeise: Color(0xFF7D7366),
    faden: Color(0xFFE0A03A),
    knoten: Color(0xFFF2C879),
    fehler: Color(0xFFD9745A),
  );

  bool get isDark => grund.computeLuminance() < 0.5;

  /// Rest of the thread (KONZEPT.md "Faden": "Rest in tinte-leise mit 40 %
  /// Deckkraft"); 60 % at night, where 40 % on black all but vanished
  /// (decision E53). Opaque, so overlapping edges never add up.
  Color get tinteLeiseFaden => Color.alphaBlend(tinteLeise.withValues(alpha: isDark ? 0.6 : 0.4), grund);

  /// A quiet raised surface (search field, selected segment background,
  /// cover placeholder): a thin veil of [tinte] over [grund], so it stays
  /// black-ish at night and never adds a new hue.
  Color get flaeche => Color.alphaBlend(tinte.withValues(alpha: isDark ? 0.10 : 0.06), grund);

  /// Secondary text on [flaeche] (search field, offline hint, grouped
  /// settings rows). By day [tinteLeise] keeps 4.5:1 there; at night it
  /// drops to 4.15:1 on the raised surface, so it takes [tinte] instead
  /// (decision E65).
  Color get leiseAufFlaeche => isDark ? tinte : tinteLeise;

  /// Hairlines and borders.
  Color get linie => Color.alphaBlend(tinteLeise.withValues(alpha: 0.35), grund);

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
    Color? fehler,
  }) =>
      FadenTokens(
        grund: grund ?? this.grund,
        tinte: tinte ?? this.tinte,
        tinteLeise: tinteLeise ?? this.tinteLeise,
        faden: faden ?? this.faden,
        knoten: knoten ?? this.knoten,
        fehler: fehler ?? this.fehler,
      );

  /// No colour blending: KONZEPT.md "Bewegung" allows no decorative
  /// animation, so a theme change switches the token set outright.
  @override
  FadenTokens lerp(covariant FadenTokens? other, double t) =>
      (other == null || t < 0.5) ? this : other;
}

/// The token set for a screen (decision E28): the night view ([nightMode],
/// E54) overrides everything; otherwise [appearance] decides, with
/// [Appearance.system] following [platformBrightness]. "Dunkel" reuses the
/// night tokens, but only the look -- the night layout (cover hidden,
/// title and chapter dimmed) stays tied to [nightMode] in
/// ui/player_screen.dart.
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

/// The whole Material theme from one token set (decision E45): every
/// ColorScheme role and every TextTheme slot is defined, so no Material
/// default (lavender surfaces, 24 sp dialog titles, a beige SnackBar at
/// night) leaks through. Sizes stay on the 28/20/17/14 scale; there is no
/// ink ripple (iOS-like), and switches, radios and the time picker are the
/// adaptive/Cupertino ones (settings_screen.dart).
ThemeData buildFadenTheme(FadenTokens tokens) {
  final brightness = tokens.isDark ? Brightness.dark : Brightness.light;
  final dark = tokens.isDark;
  // SnackBars sit on an inverse surface. By day that is dark ink with the
  // thread colour lightened for the action; at night a dark warm surface
  // instead of an inverted (bright) one, so the undo hint stays dim.
  final inverseSurface = dark ? const Color(0xFF1E1A15) : tokens.tinte;
  final onInverseSurface = dark ? tokens.tinte : tokens.grund;
  final inversePrimary = dark ? tokens.faden : const Color(0xFFB8C3FF);
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: tokens.faden,
    onPrimary: tokens.grund,
    primaryContainer: Color.alphaBlend(tokens.faden.withValues(alpha: 0.16), tokens.grund),
    onPrimaryContainer: tokens.tinte,
    primaryFixed: tokens.faden,
    onPrimaryFixed: tokens.grund,
    secondary: tokens.tinteLeise,
    onSecondary: tokens.grund,
    secondaryContainer: Color.alphaBlend(tokens.faden.withValues(alpha: 0.16), tokens.grund),
    onSecondaryContainer: tokens.tinte,
    tertiary: tokens.knoten,
    onTertiary: tokens.grund,
    error: tokens.fehler,
    onError: tokens.grund,
    errorContainer: Color.alphaBlend(tokens.fehler.withValues(alpha: 0.14), tokens.grund),
    onErrorContainer: tokens.tinte,
    surface: tokens.grund,
    onSurface: tokens.tinte,
    onSurfaceVariant: tokens.tinteLeise,
    surfaceDim: tokens.grund,
    surfaceBright: tokens.grund,
    surfaceContainerLowest: tokens.grund,
    surfaceContainerLow: tokens.grund,
    surfaceContainer: tokens.grund,
    surfaceContainerHigh: tokens.flaeche,
    surfaceContainerHighest: tokens.flaeche,
    surfaceTint: Colors.transparent,
    outline: tokens.tinteLeise,
    outlineVariant: tokens.linie,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: inverseSurface,
    onInverseSurface: onInverseSurface,
    inversePrimary: inversePrimary,
  );
  TextStyle style(double size, Color color, {FontWeight? weight}) =>
      TextStyle(fontFamily: fadenFontFamily, fontSize: size, color: color, fontWeight: weight, height: 1.25);
  final textTheme = TextTheme(
    displayLarge: style(FadenTypeSizes.display, tokens.tinte),
    displayMedium: style(FadenTypeSizes.display, tokens.tinte),
    displaySmall: style(FadenTypeSizes.display, tokens.tinte),
    headlineLarge: style(FadenTypeSizes.display, tokens.tinte),
    headlineMedium: style(FadenTypeSizes.title, tokens.tinte),
    headlineSmall: style(FadenTypeSizes.title, tokens.tinte),
    titleLarge: style(FadenTypeSizes.title, tokens.tinte),
    titleMedium: style(FadenTypeSizes.body, tokens.tinte),
    titleSmall: style(FadenTypeSizes.body, tokens.tinte),
    bodyLarge: style(FadenTypeSizes.body, tokens.tinte),
    bodyMedium: style(FadenTypeSizes.body, tokens.tinte),
    bodySmall: style(FadenTypeSizes.caption, tokens.tinteLeise),
    labelLarge: style(FadenTypeSizes.body, tokens.tinte),
    labelMedium: style(FadenTypeSizes.caption, tokens.tinte),
    labelSmall: style(FadenTypeSizes.caption, tokens.tinte),
  );
  final minTap = const Size(fadenMinTapTarget, fadenMinTapTarget);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: tokens.grund,
    canvasColor: tokens.grund,
    fontFamily: fadenFontFamily,
    textTheme: textTheme,
    // iOS feel: no ink ripple; a pressed control only dims a little.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: tokens.tinte.withValues(alpha: 0.06),
    hoverColor: Colors.transparent,
    dividerColor: tokens.linie,
    dividerTheme: DividerThemeData(color: tokens.linie, thickness: 0.5, space: 1),
    iconTheme: IconThemeData(color: tokens.tinte, size: 24),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.grund,
      foregroundColor: tokens.tinte,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleTextStyle: style(FadenTypeSizes.body, tokens.tinte, weight: FontWeight.w700),
      iconTheme: IconThemeData(color: tokens.tinte),
      actionsIconTheme: IconThemeData(color: tokens.tinte),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: tokens.tinteLeise,
      textColor: tokens.tinte,
      titleTextStyle: style(FadenTypeSizes.body, tokens.tinte),
      subtitleTextStyle: style(FadenTypeSizes.caption, tokens.tinteLeise),
      leadingAndTrailingTextStyle: style(FadenTypeSizes.body, tokens.tinteLeise),
      minTileHeight: fadenMinTapTarget,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: inverseSurface,
      contentTextStyle: style(FadenTypeSizes.body, onInverseSurface),
      actionTextColor: inversePrimary,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF14110E) : tokens.grund,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: style(FadenTypeSizes.title, tokens.tinte, weight: FontWeight.w700),
      contentTextStyle: style(FadenTypeSizes.body, tokens.tinte),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.grund,
      modalBackgroundColor: tokens.grund,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF14110E) : tokens.grund,
      surfaceTintColor: Colors.transparent,
      textStyle: style(FadenTypeSizes.body, tokens.tinte),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: tokens.faden,
      circularTrackColor: tokens.tinteLeiseFaden,
      linearTrackColor: tokens.tinteLeiseFaden,
      refreshBackgroundColor: tokens.grund,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: tokens.faden,
      inactiveTrackColor: tokens.tinteLeiseFaden,
      thumbColor: tokens.knoten,
      overlayColor: Colors.transparent,
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? tokens.grund : tokens.tinteLeise,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? tokens.faden : tokens.flaeche,
      ),
      trackOutlineColor: WidgetStateProperty.all(tokens.linie),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.all(tokens.faden)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.flaeche,
      // On the filled field ([FadenTokens.flaeche]), E65.
      labelStyle: style(FadenTypeSizes.body, tokens.leiseAufFlaeche),
      floatingLabelStyle: style(FadenTypeSizes.caption, tokens.leiseAufFlaeche),
      hintStyle: style(FadenTypeSizes.body, tokens.leiseAufFlaeche),
      prefixIconColor: tokens.leiseAufFlaeche,
      suffixIconColor: tokens.leiseAufFlaeche,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: tokens.faden, width: 1.5),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tokens.faden,
      selectionColor: tokens.faden.withValues(alpha: 0.3),
      selectionHandleColor: tokens.faden,
    ),
    // By day a filled button; with the night colours only a ring in
    // `faden`, like the main button (KONZEPT.md "Hauptbutton"), so no lit
    // amber surface glows in the dark (decision E65).
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: dark ? Colors.transparent : tokens.faden,
        foregroundColor: dark ? tokens.faden : tokens.grund,
        minimumSize: minTap,
        side: dark ? BorderSide(color: tokens.faden, width: 1.5) : null,
        textStyle: style(FadenTypeSizes.body, dark ? tokens.faden : tokens.grund, weight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.faden,
        minimumSize: minTap,
        side: BorderSide(color: tokens.linie),
        textStyle: style(FadenTypeSizes.body, tokens.faden),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: tokens.faden,
        minimumSize: minTap,
        textStyle: style(FadenTypeSizes.body, tokens.faden),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: tokens.tinte, minimumSize: minTap),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: inverseSurface, borderRadius: BorderRadius.circular(8)),
      textStyle: style(FadenTypeSizes.caption, onInverseSurface),
    ),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    adaptations: [_CupertinoSwitchColors(tokens)],
    extensions: [tokens],
  );
}

/// On iOS the adaptive switch drops the Material [SwitchThemeData] and
/// falls back to the system green (Flutter's default adaptation), the
/// brightest thing on a black night screen. This keeps it in the token
/// colours (decision E65): the track in [FadenTokens.faden] when on, a
/// quiet thread-rest grey when off; the thumb stays light by day and
/// dims to [FadenTokens.tinte] at night.
class _CupertinoSwitchColors extends Adaptation<SwitchThemeData> {
  final FadenTokens tokens;

  const _CupertinoSwitchColors(this.tokens);

  @override
  SwitchThemeData adapt(ThemeData theme, SwitchThemeData defaultValue) {
    switch (theme.platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        final thumb = tokens.isDark ? tokens.tinte : Colors.white;
        return SwitchThemeData(
          thumbColor: WidgetStateProperty.all(thumb),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? tokens.faden : tokens.tinteLeiseFaden,
          ),
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return defaultValue;
    }
  }
}

final Map<FadenTokens, ThemeData> _themeCache = {};

/// [buildFadenTheme], built once per token set: the player rebuilds often
/// and hands its theme to the sheets it opens (a stable instance keeps
/// those from rebuilding for nothing).
ThemeData fadenThemeFor(FadenTokens tokens) => _themeCache.putIfAbsent(tokens, () => buildFadenTheme(tokens));
