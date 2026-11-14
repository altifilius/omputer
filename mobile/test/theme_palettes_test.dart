import 'dart:math' as math;
import 'dart:ui' show CheckedState;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/day_night_switch.dart';
import 'package:omputer/main.dart';
import 'package:omputer/neumorphic.dart';
import 'package:omputer/theme_palettes.dart';
import 'package:omputer/ui.dart';
import 'package:omputer/settings.dart';
import 'phone_home_test.dart' show AppearanceNative;

double contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  return first > second ? (first + .05) / (second + .05) : (second + .05) / (first + .05);
}

(double, double, double) lab(Color color) {
  double linear(double channel) => channel <= .04045 ? channel / 12.92 : math.pow((channel + .055) / 1.055, 2.4).toDouble();
  final r = linear(color.r), g = linear(color.g), b = linear(color.b);
  double f(double value) => value > .008856 ? math.pow(value, 1 / 3).toDouble() : 7.787 * value + 16 / 116;
  final x = f((.4124564 * r + .3575761 * g + .1804375 * b) / .95047);
  final y = f(.2126729 * r + .7151522 * g + .0721750 * b);
  final z = f((.0193339 * r + .1191920 * g + .9503041 * b) / 1.08883);
  return (116 * y - 16, 500 * (x - y), 200 * (y - z));
}

double colorDistance(Color first, Color second) {
  final a = lab(first), b = lab(second);
  return math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2) + math.pow(a.$3 - b.$3, 2));
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
}

void main() {
  test('light palettes remain distinguishable across the actual reading surfaces', () {
    final palettes = AppColorTheme.values.where((palette) => palette != AppColorTheme.omputer).toList();
    for (var i = 0; i < palettes.length; i++) {
      final a = omputerTheme(Brightness.light, colorTheme: palettes[i]).extension<NeoPalette>()!;
      expect(a.raised.computeLuminance(), greaterThan(a.base.computeLuminance()));
      expect(a.base.computeLuminance(), greaterThan(a.inset.computeLuminance()));
      for (var j = i + 1; j < palettes.length; j++) {
        final b = omputerTheme(Brightness.light, colorTheme: palettes[j]).extension<NeoPalette>()!;
        final separation = (colorDistance(a.base, b.base) + colorDistance(a.raised, b.raised) + colorDistance(a.inset, b.inset)) / 3;
        expect(separation, greaterThanOrEqualTo(8), reason: '${palettes[i].label} and ${palettes[j].label} must not collapse into the same pale material');
      }
    }
  });

  testWidgets('palette disclosure keeps native focus, expanded state and selection after collapse', (tester) async {
    tester.view.physicalSize = const Size(360, 780); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AppearanceNative()..theme = 'light';
    final controller = OmputerController(adapter: native)..theme = 'light';
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(ListenableBuilder(listenable: controller, builder: (context, _) => MaterialApp(
      theme: omputerTheme(Brightness.light, colorTheme: controller.colorTheme),
      home: Scaffold(body: SettingsScreen(controller: controller)),
    )));
    final toggle = find.byKey(const PageStorageKey('settings-color-theme'));
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Renk teması'), findsOneWidget);
    expect(tester.getSemantics(toggle).label, 'Renk teması');
    expect(tester.getSemantics(toggle).value, 'Omputer');
    expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isExpanded.toBoolOrNull(), isFalse);
    expect(find.byKey(const ValueKey('color-theme-sage')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); await tester.pumpAndSettle();
    expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isExpanded.toBoolOrNull(), isTrue);
    final sage = find.byKey(const ValueKey('color-theme-sage'));
    await reveal(tester, sage); await tester.tap(sage); await tester.pumpAndSettle();
    expect(controller.colorTheme, AppColorTheme.sage);
    await reveal(tester, toggle); await tester.tap(toggle); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('color-theme-sage')), findsNothing);
    expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isExpanded.toBoolOrNull(), isFalse);
    expect(controller.colorTheme, AppColorTheme.sage);
    expect(native.calls.where((method) => method == 'colorTheme'), hasLength(1));
    expect(native.calls.where((method) => method == 'theme'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); semantics.dispose(); controller.dispose();
  });
  for (final palette in AppColorTheme.values) {
    for (final brightness in Brightness.values) {
      test('${palette.id} ${brightness.name} keeps readable semantic pairs and focus', () {
        final theme = omputerTheme(brightness, colorTheme: palette);
        final scheme = theme.colorScheme, neo = theme.extension<NeoPalette>()!;
        for (final surface in [neo.base, neo.raised, neo.inset]) {
          expect(contrast(scheme.onSurface, surface), greaterThanOrEqualTo(4.5));
          expect(contrast(scheme.onSurfaceVariant, surface), greaterThanOrEqualTo(4.5));
          expect(contrast(scheme.primary, surface), greaterThanOrEqualTo(4.5));
          expect(contrast(scheme.outline, surface), greaterThanOrEqualTo(3));
        }
        for (final pair in [
          (scheme.primary, scheme.onPrimary),
          (scheme.primaryContainer, scheme.onPrimaryContainer),
          (scheme.secondary, scheme.onSecondary),
          (scheme.secondaryContainer, scheme.onSecondaryContainer),
          (scheme.tertiary, scheme.onTertiary),
          (scheme.tertiaryContainer, scheme.onTertiaryContainer),
          (scheme.error, scheme.onError),
          (scheme.errorContainer, scheme.onErrorContainer),
        ]) {
          expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
        }
      });
    }
  }

  test('restored palette and appearance remain independent across controller restarts', () async {
    final native = AppearanceNative()..theme = 'system';
    var controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.setColorTheme(AppColorTheme.coral);
    controller.dispose();
    controller = OmputerController(adapter: native);
    await controller.initialize();
    expect(controller.colorTheme, AppColorTheme.coral);
    expect(controller.theme, 'system');
    await controller.setTheme('dark');
    expect(controller.colorTheme, AppColorTheme.coral);
    native.fail = true;
    await expectLater(controller.setColorTheme(AppColorTheme.sage), throwsA(isA<ControllerFailure>()));
    expect(controller.colorTheme, AppColorTheme.coral);
    expect(controller.theme, 'dark');
    controller.dispose();
  });

  testWidgets('settings selection applies to the open route and header brightness preserves palette', (tester) async {
    tester.view.physicalSize = const Size(393, 852); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AppearanceNative()..theme = 'light';
    final controller = OmputerController(adapter: native);
    await tester.pumpWidget(OmputerApp(controller: controller));
    await tester.pumpAndSettle();
    final switchBounds = tester.getRect(find.byType(DayNightSwitch));
    await tester.tap(find.byTooltip('Ayarlar'));
    await tester.pumpAndSettle();
    final paletteMenu = find.byKey(const PageStorageKey('settings-color-theme'));
    await reveal(tester, paletteMenu);
    await tester.tap(find.text('Renk teması'));
    await tester.pumpAndSettle();
    for (final palette in AppColorTheme.values.where((value) => value != AppColorTheme.omputer)) {
      final option = find.byKey(ValueKey('color-theme-${palette.id}'));
      await reveal(tester, option);
      expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(controller.colorTheme, palette);
      expect(controller.theme, 'light');
      expect(Theme.of(tester.element(option)).colorScheme.primary, palette.colors(Brightness.light).primary);
    }
    native.fail = true;
    final sage = find.byKey(const ValueKey('color-theme-sage'));
    await reveal(tester, sage);
    await tester.tap(sage); await tester.pumpAndSettle();
    expect(find.textContaining('Kayıt yazılamadı'), findsOneWidget);
    expect(controller.colorTheme, AppColorTheme.coral);
    native.fail = false;
    await tester.tap(find.byType(BackButton)); await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(DayNightSwitch)), switchBounds);
    await tester.tap(find.byType(DayNightSwitch)); await tester.pumpAndSettle();
    expect(controller.theme, 'dark');
    expect(controller.colorTheme, AppColorTheme.coral);
    expect(Theme.of(tester.element(find.byType(HomeScreen))).colorScheme.primary, AppColorTheme.coral.colors(Brightness.dark).primary);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large-text palette choices retain keyboard and assistive selection', (tester) async {
    tester.view.physicalSize = const Size(320, 740); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final native = AppearanceNative()..theme = 'dark';
    final controller = OmputerController(adapter: native);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(OmputerApp(controller: controller)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ayarlar')); await tester.pumpAndSettle();
    final menu = find.byKey(const PageStorageKey('settings-color-theme'));
    await reveal(tester, menu); await tester.tap(find.text('Renk teması')); await tester.pumpAndSettle();
    final option = find.byKey(const ValueKey('color-theme-coral'));
    await reveal(tester, option);
    final radio = tester.widget<RadioListTile<AppColorTheme>>(option);
    final node = tester.widget<ListTile>(find.descendant(of: option, matching: find.byType(ListTile))).focusNode!;
    node.requestFocus(); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); await tester.pumpAndSettle();
    expect(radio.enabled, isTrue);
    expect(controller.colorTheme, AppColorTheme.coral);
    expect(tester.getSemantics(option).getSemanticsData().flagsCollection.isChecked, CheckedState.isTrue);
    final coast = find.byKey(const ValueKey('color-theme-coast'));
    await reveal(tester, coast);
    tester.semantics.tap(find.semantics.byLabel('Okyanus'));
    await tester.pumpAndSettle();
    expect(controller.colorTheme, AppColorTheme.coast);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink()); semantics.dispose();
  });
}
