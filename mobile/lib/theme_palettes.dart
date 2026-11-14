import 'package:flutter/material.dart';
import 'neumorphic.dart';

/// Stable phone-wide IDs; appearance (system/light/dark) is stored separately.
enum AppColorTheme {
  omputer('omputer', 'Omputer', [Color(0xffe8edf2), Color(0xffc0c6cf), Color(0xff23272f), Color(0xfff3ca68), Color(0xffa87920)]),
  sage('sage', 'Adaçayı', [Color(0xffccd5ae), Color(0xffe9edc9), Color(0xfffefae0), Color(0xfffaedcd), Color(0xffd4a373)]),
  coast('coast', 'Okyanus', [Color(0xff8ecae6), Color(0xff219ebc), Color(0xff023047), Color(0xffffb703), Color(0xfffb8500)]),
  forest('forest', 'Orman', [Color(0xff01161e), Color(0xff124559), Color(0xff598392), Color(0xffaec3b0), Color(0xffeff6e0)]),
  midnight('midnight', 'Gece mavisi', [Color(0xff000814), Color(0xff001d3d), Color(0xff003566), Color(0xffffc300), Color(0xffffd60a)]),
  cherry('cherry', 'Vişne', [Color(0xffef233c), Color(0xffd5f2e3), Color(0xff73ba9b), Color(0xff003e1f), Color(0xffd90429)]),
  terracotta('terracotta', 'Kiremit', [Color(0xff562c2c), Color(0xfff2542d), Color(0xfff5dfbb), Color(0xff0e9594), Color(0xff127475)]),
  coral('coral', 'Mercan', [Color(0xffe63946), Color(0xfff1faee), Color(0xffa8dadc), Color(0xff457b9d), Color(0xff1d3557)]);

  const AppColorTheme(this.id, this.label, this.swatches);
  final String id, label;
  final List<Color> swatches;

  static AppColorTheme fromId(Object? id) => values.where((theme) => theme.id == id).firstOrNull ?? omputer;

  AppThemeColors colors(Brightness brightness) => _colors[(this, brightness)]!;
}

/// Each appearance is composed explicitly, not inverted from its counterpart.
@immutable
class AppThemeColors {
  const AppThemeColors({required this.base, required this.ink, required this.primary,
    required this.onPrimary, required this.primaryContainer, required this.onPrimaryContainer,
    required this.tertiary, required this.onTertiary, required this.tertiaryContainer,
    required this.onTertiaryContainer, this.lightSurfaces});

  final Color base, ink, primary, onPrimary, primaryContainer, onPrimaryContainer;
  final Color tertiary, onTertiary, tertiaryContainer, onTertiaryContainer;
  final NeoPalette? lightSurfaces;

  NeoPalette surfaces(Brightness brightness) {
    if (brightness == Brightness.light && lightSurfaces != null) return lightSurfaces!;
    final dark = brightness == Brightness.dark;
    return NeoPalette(
      base: base,
      raised: Color.lerp(base, Colors.white, dark ? .035 : .26)!,
      inset: Color.lerp(base, Colors.black, dark ? .10 : .025)!,
      light: Color.lerp(base, Colors.white, dark ? .09 : .85)!,
      shadow: Color.lerp(base, Colors.black, dark ? .40 : .16)!,
    );
  }
}

const _colors = <(AppColorTheme, Brightness), AppThemeColors>{
  (AppColorTheme.omputer, Brightness.light): AppThemeColors(
    base: Color(0xffe8edf2), ink: Color(0xff252c35),
    primary: Color(0xff292e37), onPrimary: Color(0xffffffff),
    primaryContainer: Color(0xffd5dde8), onPrimaryContainer: Color(0xff23272f),
    tertiary: Color(0xff292e37), onTertiary: Color(0xffffffff),
    tertiaryContainer: Color(0xffd5dde8), onTertiaryContainer: Color(0xff23272f),
  ),
  (AppColorTheme.omputer, Brightness.dark): AppThemeColors(
    base: Color(0xff23272f), ink: Color(0xfff1f3f5),
    primary: Color(0xfff3ca68), onPrimary: Color(0xff272016),
    primaryContainer: Color(0xff463c28), onPrimaryContainer: Color(0xffffe3a2),
    tertiary: Color(0xfff3ca68), onTertiary: Color(0xff23272f),
    tertiaryContainer: Color(0xff463c28), onTertiaryContainer: Color(0xffffe3a2),
  ),
  (AppColorTheme.sage, Brightness.light): AppThemeColors(
    base: Color(0xffe5dfc4), ink: Color(0xff303a2e),
    lightSurfaces: NeoPalette(base: Color(0xffe5dfc4), raised: Color(0xfffefae0), inset: Color(0xffccd5ae), light: Color(0xfffffef0), shadow: Color(0xffb5bd94)),
    primary: Color(0xff47572f), onPrimary: Color(0xfffefae0),
    primaryContainer: Color(0xffe9edc9), onPrimaryContainer: Color(0xff303b20),
    tertiary: Color(0xff80542e), onTertiary: Color(0xfffefae0),
    tertiaryContainer: Color(0xfffaedcd), onTertiaryContainer: Color(0xff562f12),
  ),
  (AppColorTheme.sage, Brightness.dark): AppThemeColors(
    base: Color(0xff282c23), ink: Color(0xfff0f1df),
    primary: Color(0xffccd5ae), onPrimary: Color(0xff252e1c),
    primaryContainer: Color(0xff3d4631), onPrimaryContainer: Color(0xffe9edc9),
    tertiary: Color(0xffd4a373), onTertiary: Color(0xff392515),
    tertiaryContainer: Color(0xff4c3b2c), onTertiaryContainer: Color(0xfffaedcd),
  ),
  (AppColorTheme.coast, Brightness.light): AppThemeColors(
    base: Color(0xffc6e4f1), ink: Color(0xff023047),
    lightSurfaces: NeoPalette(base: Color(0xffc6e4f1), raised: Color(0xffe1f4fb), inset: Color(0xffafd4e5), light: Color(0xfff4fcff), shadow: Color(0xff8daebf)),
    primary: Color(0xff014b66), onPrimary: Color(0xffffffff),
    primaryContainer: Color(0xffbcdfe9), onPrimaryContainer: Color(0xff023047),
    tertiary: Color(0xffa94f00), onTertiary: Color(0xffffffff),
    tertiaryContainer: Color(0xffffe1a7), onTertiaryContainer: Color(0xff633600),
  ),
  (AppColorTheme.coast, Brightness.dark): AppThemeColors(
    base: Color(0xff1c2a30), ink: Color(0xffe5f2f7),
    primary: Color(0xff8ecae6), onPrimary: Color(0xff023047),
    primaryContainer: Color(0xff244955), onPrimaryContainer: Color(0xffcbeaf6),
    tertiary: Color(0xffffb703), onTertiary: Color(0xff422b00),
    tertiaryContainer: Color(0xff50402a), onTertiaryContainer: Color(0xffffe1a7),
  ),
  (AppColorTheme.forest, Brightness.light): AppThemeColors(
    base: Color(0xffc8d7c0), ink: Color(0xff01161e),
    lightSurfaces: NeoPalette(base: Color(0xffc8d7c0), raised: Color(0xffe5efd8), inset: Color(0xffadc4a6), light: Color(0xfff4fae9), shadow: Color(0xff8da285)),
    primary: Color(0xff124559), onPrimary: Color(0xffeff6e0),
    primaryContainer: Color(0xffd5e2d3), onPrimaryContainer: Color(0xff124559),
    tertiary: Color(0xff3f6673), onTertiary: Color(0xffeff6e0),
    tertiaryContainer: Color(0xffd1e2e6), onTertiaryContainer: Color(0xff123c4a),
  ),
  (AppColorTheme.forest, Brightness.dark): AppThemeColors(
    base: Color(0xff1c292b), ink: Color(0xffeff6e0),
    primary: Color(0xffaec3b0), onPrimary: Color(0xff01161e),
    primaryContainer: Color(0xff314a48), onPrimaryContainer: Color(0xffe2eedc),
    tertiary: Color(0xff91b6c4), onTertiary: Color(0xff01161e),
    tertiaryContainer: Color(0xff284954), onTertiaryContainer: Color(0xffd1e2e6),
  ),
  (AppColorTheme.midnight, Brightness.light): AppThemeColors(
    base: Color(0xfff3e4a5), ink: Color(0xff001d3d),
    lightSurfaces: NeoPalette(base: Color(0xfff3e4a5), raised: Color(0xfffff3c4), inset: Color(0xffe3cf83), light: Color(0xfffffbeb), shadow: Color(0xffbfae6d)),
    primary: Color(0xff003566), onPrimary: Color(0xffffffff),
    primaryContainer: Color(0xffcbd9e8), onPrimaryContainer: Color(0xff001d3d),
    tertiary: Color(0xff795b00), onTertiary: Color(0xfffff8df),
    tertiaryContainer: Color(0xffffedb0), onTertiaryContainer: Color(0xff4d3900),
  ),
  (AppColorTheme.midnight, Brightness.dark): AppThemeColors(
    base: Color(0xff101d2b), ink: Color(0xffe5ebf2),
    primary: Color(0xffffd60a), onPrimary: Color(0xff000814),
    primaryContainer: Color(0xff334562), onPrimaryContainer: Color(0xffe5ebf2),
    tertiary: Color(0xffffc300), onTertiary: Color(0xff001d3d),
    tertiaryContainer: Color(0xff4d4020), onTertiaryContainer: Color(0xffffedb0),
  ),
  (AppColorTheme.cherry, Brightness.light): AppThemeColors(
    base: Color(0xffefd9df), ink: Color(0xff3d1c28),
    lightSurfaces: NeoPalette(base: Color(0xffefd9df), raised: Color(0xfffff0f2), inset: Color(0xffdfbdc8), light: Color(0xfffff9fa), shadow: Color(0xffbda0aa)),
    primary: Color(0xff97041f), onPrimary: Color(0xffffffff),
    primaryContainer: Color(0xffffdade), onPrimaryContainer: Color(0xff690015),
    tertiary: Color(0xff003e1f), onTertiary: Color(0xffd5f2e3),
    tertiaryContainer: Color(0xffd5f2e3), onTertiaryContainer: Color(0xff003e1f),
  ),
  (AppColorTheme.cherry, Brightness.dark): AppThemeColors(
    base: Color(0xff1b2923), ink: Color(0xffe4f3e9),
    primary: Color(0xffff7c8c), onPrimary: Color(0xff3a0610),
    primaryContainer: Color(0xff502730), onPrimaryContainer: Color(0xffffdae0),
    tertiary: Color(0xff73ba9b), onTertiary: Color(0xff003e1f),
    tertiaryContainer: Color(0xff244a38), onTertiaryContainer: Color(0xffd5f2e3),
  ),
  (AppColorTheme.terracotta, Brightness.light): AppThemeColors(
    base: Color(0xffe9d1b4), ink: Color(0xff562c2c),
    lightSurfaces: NeoPalette(base: Color(0xffe9d1b4), raised: Color(0xfff5dfbb), inset: Color(0xffd6b89a), light: Color(0xfffff2db), shadow: Color(0xffb3987d)),
    primary: Color(0xff74291e), onPrimary: Color(0xfffff5e8),
    primaryContainer: Color(0xfff4cbbb), onPrimaryContainer: Color(0xff562c2c),
    tertiary: Color(0xff127475), onTertiary: Color(0xfff5f6ee),
    tertiaryContainer: Color(0xffbfe5de), onTertiaryContainer: Color(0xff083e3d),
  ),
  (AppColorTheme.terracotta, Brightness.dark): AppThemeColors(
    base: Color(0xff2e2623), ink: Color(0xfff5dfbb),
    primary: Color(0xfff9997f), onPrimary: Color(0xff562c2c),
    primaryContainer: Color(0xff57382f), onPrimaryContainer: Color(0xfff5dfbb),
    tertiary: Color(0xff69c5c0), onTertiary: Color(0xff083e3d),
    tertiaryContainer: Color(0xff194746), onTertiaryContainer: Color(0xffc6eae2),
  ),
  (AppColorTheme.coral, Brightness.light): AppThemeColors(
    base: Color(0xffd4e9e5), ink: Color(0xff1d3557),
    lightSurfaces: NeoPalette(base: Color(0xffd4e9e5), raised: Color(0xfff1faee), inset: Color(0xffacd2cf), light: Color(0xfff5fffb), shadow: Color(0xff91b7b2)),
    primary: Color(0xff294d72), onPrimary: Color(0xfff1faee),
    primaryContainer: Color(0xffa8dadc), onPrimaryContainer: Color(0xff1d3557),
    tertiary: Color(0xffb92334), onTertiary: Color(0xfff1faee),
    tertiaryContainer: Color(0xffffdadc), onTertiaryContainer: Color(0xff60121e),
  ),
  (AppColorTheme.coral, Brightness.dark): AppThemeColors(
    base: Color(0xff222c38), ink: Color(0xfff1faee),
    primary: Color(0xffff939a), onPrimary: Color(0xff52141d),
    primaryContainer: Color(0xff55343d), onPrimaryContainer: Color(0xffffdadc),
    tertiary: Color(0xffa8dadc), onTertiary: Color(0xff1d3557),
    tertiaryContainer: Color(0xff304f63), onTertiaryContainer: Color(0xffd4f0ed),
  ),
};
