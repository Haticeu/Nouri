import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Taze" look: fresh, vivid green on light mint. In the dark: warm graphite
/// (no green tint) with a lime accent and thin-bordered cards, so it doesn't
/// look like a messaging app. Follows the device's light/dark setting.

/// Colours that aren't part of Material's scheme: water and macro accents.
@immutable
class NouriColors extends ThemeExtension<NouriColors> {
  const NouriColors({
    required this.water,
    required this.waterSoft,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.track,
    required this.link,
  });

  final Color water; // glass fill, water accents
  final Color waterSoft; // empty glass / water card background
  final Color protein;
  final Color carbs;
  final Color fat;
  final Color track; // empty part of progress bars and rings
  final Color link; // green for text on light surfaces (readable contrast)

  static const light = NouriColors(
    water: Color(0xFF1E88FF),
    waterSoft: Color(0xFFE3F0FF),
    protein: Color(0xFF16B355),
    carbs: Color(0xFFFF8A1F),
    fat: Color(0xFF7C5CFF),
    track: Color(0xFFE4F2E9),
    link: Color(0xFF13803F),
  );

  static const dark = NouriColors(
    water: Color(0xFF5CB3FF),
    waterSoft: Color(0xFF1C2530),
    protein: Color(0xFFC6F36B),
    carbs: Color(0xFFFFB067),
    fat: Color(0xFFB4A0FF),
    track: Color(0xFF2E2D29),
    link: Color(0xFFCDEF7E),
  );

  @override
  NouriColors copyWith({Color? water, Color? waterSoft, Color? protein, Color? carbs, Color? fat, Color? track, Color? link}) =>
      NouriColors(
        water: water ?? this.water,
        waterSoft: waterSoft ?? this.waterSoft,
        protein: protein ?? this.protein,
        carbs: carbs ?? this.carbs,
        fat: fat ?? this.fat,
        track: track ?? this.track,
        link: link ?? this.link,
      );

  @override
  NouriColors lerp(NouriColors? other, double t) {
    if (other == null) return this;
    return NouriColors(
      water: Color.lerp(water, other.water, t)!,
      waterSoft: Color.lerp(waterSoft, other.waterSoft, t)!,
      protein: Color.lerp(protein, other.protein, t)!,
      carbs: Color.lerp(carbs, other.carbs, t)!,
      fat: Color.lerp(fat, other.fat, t)!,
      track: Color.lerp(track, other.track, t)!,
      link: Color.lerp(link, other.link, t)!,
    );
  }
}

extension NouriTheme on BuildContext {
  NouriColors get nouri => Theme.of(this).extension<NouriColors>()!;
}

ThemeData nouriTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final extra = dark ? NouriColors.dark : NouriColors.light;

  // Vivid green with near-black green text on it: bright AND readable.
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF22C55E),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  ).copyWith(
    // Dark: lime on warm graphite (light: vivid green on mint).
    primary: dark ? const Color(0xFFC6F36B) : const Color(0xFF1DBF5B),
    onPrimary: dark ? const Color(0xFF1C2400) : const Color(0xFF032611),
    primaryContainer: dark ? const Color(0xFF353F17) : const Color(0xFFD9F7E4),
    onPrimaryContainer: dark ? const Color(0xFFE6FAB8) : const Color(0xFF0A4D24),
    secondaryContainer: dark ? const Color(0xFF2F2B24) : null,
    onSecondaryContainer: dark ? const Color(0xFFF1E5D3) : null,
    tertiaryContainer: dark ? const Color(0xFF3A2C1E) : null,
    onTertiaryContainer: dark ? const Color(0xFFFFDDBB) : null,
    surface: dark ? const Color(0xFF151513) : const Color(0xFFF1F8F3),
    onSurface: dark ? const Color(0xFFEDEBE6) : const Color(0xFF12241A),
    onSurfaceVariant: dark ? const Color(0xFFADA9A0) : const Color(0xFF526459),
    surfaceContainerLowest: dark ? const Color(0xFF1E1E1B) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF22221F) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF262623) : const Color(0xFFF7FBF8),
    surfaceContainerHigh: dark ? const Color(0xFF2C2C28) : const Color(0xFFEDF5EF),
    surfaceContainerHighest: dark ? const Color(0xFF34342F) : const Color(0xFFE3EEE6),
    outline: dark ? const Color(0xFF6E6B63) : null,
    outlineVariant: dark ? const Color(0xFF34332E) : const Color(0xFFD3E5D9),
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final text = GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final rounded16 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
    ),
    extensions: [extra],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, fontSize: 22),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: dark ? 0 : 1,
      shadowColor: const Color(0x1412241A),
      // Dark cards get a thin border instead of a shadow.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: dark ? BorderSide(color: scheme.outlineVariant) : BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: rounded16,
        minimumSize: const Size(48, 48),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: rounded16, minimumSize: const Size(48, 48), foregroundColor: extra.link),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: extra.link, textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      height: 72,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => text.labelMedium?.copyWith(
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
            color: s.contains(WidgetState.selected) ? extra.link : scheme.onSurfaceVariant,
          )),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      selectedLabelTextStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w800, color: extra.link),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
    ),
    tabBarTheme: TabBarThemeData(labelColor: extra.link, indicatorColor: scheme.primary, dividerColor: scheme.outlineVariant),
    chipTheme: base.chipTheme.copyWith(shape: const StadiumBorder(), side: BorderSide(color: scheme.outlineVariant)),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: extra.track),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
