import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/day_night_switch.dart';

Widget _host({required bool dark, ValueChanged<bool>? onChanged,
  bool reducedMotion = false, bool accessibleNavigation = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion,
      accessibleNavigation: accessibleNavigation),
    child: Scaffold(body: Center(child: DayNightSwitch(
      dark: dark, onChanged: onChanged,
    ))),
  ),
);

void main() {
  testWidgets('day and night paint the reference sky and celestial bodies', (tester) async {
    Future<Color> paintedPixel(int x, int y) async {
      final customPaint = tester.widget<CustomPaint>(find.descendant(
        of: find.byType(DayNightSwitch), matching: find.byType(CustomPaint),
      ));
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(4);
      customPaint.painter!.paint(canvas, const Size(72, 48));
      final picture = recorder.endRecording();
      final image = await picture.toImage(288, 192);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final offset = ((y * 4) * 288 + x * 4) * 4;
      final color = Color.fromARGB(bytes.getUint8(offset + 3),
        bytes.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
      image.dispose();
      picture.dispose();
      return color;
    }

    await tester.pumpWidget(_host(dark: false, onChanged: (_) {}, reducedMotion: true));
    expect(await tester.runAsync(() => paintedPixel(50, 12)), const Color(0xff3d7eae));
    expect(await tester.runAsync(() => paintedPixel(16, 24)), const Color(0xffecca2f));
    expect(await tester.runAsync(() => paintedPixel(60, 34)), const Color(0xfff3fdff));
    await tester.pumpWidget(_host(dark: true, onChanged: (_) {}, reducedMotion: true));
    expect(await tester.runAsync(() => paintedPixel(4, 24)), const Color(0xff1d1f2c));
    expect(await tester.runAsync(() => paintedPixel(56, 24)), const Color(0xffc4c9d1));
    expect(await tester.runAsync(() => paintedPixel(51, 26)), const Color(0xff959db1));
    final star = await tester.runAsync(() => paintedPixel(20, 29));
    expect(star!.r, greaterThan(.9));
    expect(star.g, greaterThan(.9));
    expect(star.b, greaterThan(.9));
  });

  testWidgets('tap requests one change and waits for the controlled prop', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <bool>[];
    await tester.pumpWidget(_host(dark: false, onChanged: changes.add));
    expect(tester.getSize(find.byType(DayNightSwitch)), const Size(72, 48));
    await tester.tap(find.byType(DayNightSwitch));
    await tester.pump();
    expect(changes, [true]);
    expect(tester.getSemantics(find.byType(DayNightSwitch)),
      matchesSemantics(label: 'Karanlık mod', hasToggledState: true,
        isToggled: false, hasEnabledState: true, isEnabled: true,
        isFocusable: true, hasTapAction: true));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(_host(dark: true, onChanged: changes.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DayNightSwitch));
    expect(changes, [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('external updates change semantics without firing callbacks', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <bool>[];
    await tester.pumpWidget(_host(dark: false, onChanged: changes.add));
    await tester.pumpWidget(_host(dark: true, onChanged: changes.add));
    expect(tester.getSemantics(find.byType(DayNightSwitch)),
      matchesSemantics(label: 'Karanlık mod', hasToggledState: true,
        isToggled: true, hasEnabledState: true, isEnabled: true,
        isFocusable: true, hasTapAction: true));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('Space and Enter each invoke one native focused action immediately', (tester) async {
    var dark = false;
    final changes = <bool>[];
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) => Scaffold(body: DayNightSwitch(
        dark: dark,
        onChanged: (value) => setState(() {
          dark = value;
          changes.add(value);
        }),
      )),
    )));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(changes, [true]);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(changes, [true, false]);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('assistive tap is a single immediate switch action', (tester) async {
    final semantics = tester.ensureSemantics();
    var dark = false;
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) => Scaffold(body: DayNightSwitch(
        dark: dark,
        onChanged: (value) => setState(() { dark = value; calls++; }),
      )),
    )));
    tester.semantics.tap(find.semantics.byLabel('Karanlık mod'));
    await tester.pump();
    expect(calls, 1);
    expect(dark, isTrue);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.bySemanticsLabel('Karanlık mod'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  for (final accessibleNavigation in [false, true]) {
    testWidgets('${accessibleNavigation ? 'accessible navigation' : 'reduced motion'} changes immediately', (tester) async {
      await tester.pumpWidget(_host(dark: false, onChanged: (_) {},
        reducedMotion: !accessibleNavigation, accessibleNavigation: accessibleNavigation));
      await tester.pumpWidget(_host(dark: true, onChanged: (_) {},
        reducedMotion: !accessibleNavigation, accessibleNavigation: accessibleNavigation));
      expect(tester.hasRunningAnimations, isFalse);
    });
  }

  testWidgets('disabled has no semantic action or keyboard/pointer activation', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(dark: true));
    expect(tester.getSemantics(find.byType(DayNightSwitch)),
      matchesSemantics(label: 'Karanlık mod', hasToggledState: true,
        isToggled: true, hasEnabledState: true, isEnabled: false));
    await tester.tap(find.byType(DayNightSwitch));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('rapid reversals settle at the latest external value without callbacks', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <bool>[];
    await tester.pumpWidget(_host(dark: false, onChanged: changes.add));
    await tester.pumpWidget(_host(dark: true, onChanged: changes.add));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(_host(dark: false, onChanged: changes.add));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(_host(dark: true, onChanged: changes.add));
    await tester.pump(const Duration(milliseconds: 260));
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.getSemantics(find.byType(DayNightSwitch)),
      matchesSemantics(label: 'Karanlık mod', hasToggledState: true,
        isToggled: true, hasEnabledState: true, isEnabled: true,
        isFocusable: true, hasTapAction: true));
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });
}
