import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/joined_tabs.dart';
import 'package:omputer/neumorphic.dart';

const _tabs = [
  JoinedTab(id: 'projects', label: 'Projeler', icon: Icons.folder_outlined),
  JoinedTab(id: 'new', label: 'Yeni oturum', icon: Icons.add, action: true),
  JoinedTab(id: 'inbox', label: 'Gelen kutusu', icon: Icons.inbox_outlined, count: 7),
];

Widget _host({
  List<JoinedTab> tabs = _tabs,
  String selectedId = 'projects',
  ValueChanged<String>? onSelected,
  double width = 360,
  double scale = 1,
  Color? panelColor,
  bool reducedMotion = false,
  bool panelAbove = false,
  Brightness brightness = Brightness.light,
  Widget Function(Widget tabs)? wrap,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final palette = NeoPalette.forBrightness(brightness);
  return MaterialApp(
    theme: ThemeData(
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber, brightness: brightness),
      extensions: [palette],
    ),
    home: Scaffold(body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale),
        disableAnimations: reducedMotion),
      child: Directionality(
        textDirection: textDirection,
        child: Align(alignment: Alignment.topLeft, child: SizedBox(
          width: width,
          child: wrap?.call(NeoJoinedTabs(tabs: tabs, selectedId: selectedId,
            onSelected: onSelected ?? (_) {}, panelColor: panelColor,
            panelAbove: panelAbove))
            ?? NeoJoinedTabs(tabs: tabs, selectedId: selectedId,
              onSelected: onSelected ?? (_) {}, panelColor: panelColor,
              panelAbove: panelAbove),
        )),
      ),
    )),
  );
}

Finder _button(String label) => find.widgetWithText(TextButton, label);

FocusNode _focus(WidgetTester tester, String label) =>
  tester.widget<TextButton>(_button(label)).focusNode!;

Future<Color Function(int x, int y)> _pixels(WidgetTester tester, GlobalKey key) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final width = image.width;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      return (int x, int y) {
        final index = (y * width + x) * 4;
        return Color.fromARGB(bytes[index + 3], bytes[index], bytes[index + 1], bytes[index + 2]);
      };
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('selection is controlled and selected destinations do not emit', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <String>[];
    await tester.pumpWidget(_host(onSelected: changes.add));
    await tester.tap(_button('Projeler'));
    expect(changes, isEmpty);
    await tester.tap(_button('Gelen kutusu'));
    await tester.pump();
    expect(changes, ['inbox']);
    expect(tester.getSemantics(find.bySemanticsLabel('Projeler'))
      .getSemanticsData().flagsCollection.isSelected.toBoolOrNull(), isTrue);
    expect(tester.getSemantics(find.bySemanticsLabel('Gelen kutusu, 7 öğe'))
      .getSemanticsData().flagsCollection.isSelected.toBoolOrNull(), isFalse);
    await tester.pumpWidget(_host(selectedId: 'inbox', onSelected: changes.add));
    expect(changes, ['inbox']);
    expect(tester.getSemantics(find.bySemanticsLabel('Gelen kutusu, 7 öğe'))
      .getSemanticsData().flagsCollection.isSelected.toBoolOrNull(), isTrue);
    await tester.tap(_button('Gelen kutusu'));
    expect(changes, ['inbox']);
    semantics.dispose();
  });

  testWidgets('new session always invokes once without becoming a destination', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <String>[];
    await tester.pumpWidget(_host(selectedId: 'new', onSelected: changes.add));
    final action = tester.getSemantics(find.bySemanticsLabel('Yeni oturum'));
    final flags = action.getSemanticsData().flagsCollection;
    expect(flags.isButton, isTrue);
    expect(flags.isSelected.toBoolOrNull(), isNull);
    expect(flags.isToggled.toBoolOrNull(), isNull);
    expect(flags.isInMutuallyExclusiveGroup, isFalse);
    await tester.tap(_button('Yeni oturum'));
    await tester.tap(_button('Yeni oturum'));
    expect(changes, ['new', 'new']);
    semantics.dispose();
  });

  testWidgets('one semantic node per control exposes selection count and native focus', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <String>[];
    await tester.pumpWidget(_host(onSelected: changes.add));
    expect(find.bySemanticsLabel('Projeler'), findsOneWidget);
    expect(find.bySemanticsLabel('Yeni oturum'), findsOneWidget);
    expect(find.bySemanticsLabel('Gelen kutusu, 7 öğe'), findsOneWidget);
    final destination = tester.getSemantics(find.bySemanticsLabel('Gelen kutusu, 7 öğe'));
    final flags = destination.getSemanticsData().flagsCollection;
    expect(flags.isInMutuallyExclusiveGroup, isTrue);
    expect(flags.isSelected.toBoolOrNull(), isFalse);
    expect(flags.isFocused.toBoolOrNull(), isFalse);
    expect(destination.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    tester.semantics.tap(find.semantics.byLabel('Gelen kutusu, 7 öğe'));
    await tester.pump();
    expect(changes, ['inbox']);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focus(tester, 'Projeler').hasFocus, isTrue);
    expect(tester.getSemantics(find.bySemanticsLabel('Projeler'))
      .getSemanticsData().flagsCollection.isFocused.toBoolOrNull(), isTrue);
    final button = tester.widget<TextButton>(_button('Projeler'));
    final focusedSide = button.style!.side!.resolve({WidgetState.focused})!;
    expect(focusedSide.width, 2);
    expect(focusedSide.color, Theme.of(tester.element(_button('Projeler'))).colorScheme.primary);
    expect(button.style!.animationDuration, Duration.zero);
    semantics.dispose();
  });

  for (final reducedMotion in [false, true]) {
    testWidgets('arrows move focus only and Space/Enter each activate once, reduced=$reducedMotion', (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(_host(onSelected: changes.add, reducedMotion: reducedMotion));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focus(tester, 'Yeni oturum').hasFocus, isTrue);
      expect(changes, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(changes, ['new']);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(changes, ['new', 'new']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(changes, ['new', 'new', 'inbox']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focus(tester, 'Projeler').hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(changes, ['new', 'new', 'inbox']);
    });
  }

  testWidgets('disabled tabs have no tap action, callback or keyboard stop', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <String>[];
    await tester.pumpWidget(_host(tabs: const [
      JoinedTab(id: 'all', label: 'Tümü'),
      JoinedTab(id: 'live', label: 'Canlı', enabled: false, count: 2),
      JoinedTab(id: 'pinned', label: 'Sabitlenen'),
    ], selectedId: 'all', onSelected: changes.add));
    final disabled = tester.getSemantics(find.bySemanticsLabel('Canlı, 2 öğe'));
    final flags = disabled.getSemanticsData().flagsCollection;
    expect(flags.isEnabled.toBoolOrNull(), isFalse);
    expect(flags.isFocused.toBoolOrNull(), isNull);
    expect(disabled.getSemanticsData().hasAction(ui.SemanticsAction.tap), isFalse);
    expect(tester.widget<TextButton>(_button('Canlı')).onPressed, isNull);
    await tester.tap(_button('Canlı'));
    expect(changes, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_focus(tester, 'Sabitlenen').hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(changes, ['pinned']);
    semantics.dispose();
  });

  testWidgets('RTL arrows follow visual column order', (tester) async {
    await tester.pumpWidget(_host(textDirection: TextDirection.rtl));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_focus(tester, 'Yeni oturum').hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_focus(tester, 'Projeler').hasFocus, isTrue);
  });

  for (final width in [360.0, 280.0]) {
    for (final tabs in [
      _tabs,
      const [
        JoinedTab(id: 'all', label: 'Tümü'),
        JoinedTab(id: 'live', label: 'Canlı', count: 12),
        JoinedTab(id: 'pinned', label: 'Sabitlenen'),
      ],
    ]) {
      testWidgets('equal columns and full labels at ${width}dp / 200%, ${tabs.first.id}', (tester) async {
        await tester.pumpWidget(_host(width: width, scale: 2, tabs: tabs,
          selectedId: tabs.first.id));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final sizes = tabs.map((tab) => tester.getSize(_button(tab.label))).toList();
        for (final size in sizes) {
          expect(size.width, closeTo(width / tabs.length, .01));
          expect(size.height, greaterThanOrEqualTo(48));
          expect(size.height, sizes.first.height);
        }
        for (final tab in tabs) {
          final text = tester.widget<Text>(find.text(tab.label));
          expect(text.maxLines, isNull);
          expect(text.overflow, isNot(TextOverflow.ellipsis));
          final paragraph = tester.renderObject<RenderParagraph>(find.text(tab.label));
          expect(paragraph.didExceedMaxLines, isFalse);
        }
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('paint joins top-rounded tab, concave shoulders and exact panel, $brightness', (tester) async {
      final key = GlobalKey();
      final panel = brightness == Brightness.dark
        ? const Color(0xff30343a) : const Color(0xfff4f5f6);
      await tester.pumpWidget(_host(width: 300, brightness: brightness,
        selectedId: 'new-filter', panelColor: panel,
        tabs: const [
          JoinedTab(id: 'all', label: 'Tümü'),
          JoinedTab(id: 'new-filter', label: 'Canlı'),
          JoinedTab(id: 'pinned', label: 'Sabitlenen'),
        ], wrap: (tabs) => RepaintBoundary(key: key, child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [tabs, SizedBox(height: 32, child: ColoredBox(color: panel,
            child: const SizedBox.expand()))],
        ))));
      await tester.pumpAndSettle();
      final height = tester.getSize(find.byType(NeoJoinedTabs)).height.round();
      final pixel = await _pixels(tester, key);
      expect(pixel(150, 8), panel);
      expect(pixel(109, 5), isNot(panel)); // Rounded top corner, not a rectangle.
      expect(pixel(101, height - 14), isNot(panel)); // Outside the concave shoulder.
      expect(pixel(112, height - 14), panel);
      for (final x in [0, 40, 100, 150, 200, 260, 299]) {
        expect(pixel(x, height - 6), panel); // Full-width panel strip.
        expect(pixel(x, height - 1), panel);
        expect(pixel(x, height), panel); // No seam at the content boundary.
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final selectedId in ['all', 'live', 'pinned']) {
      testWidgets('upward $selectedId opens into content without a full-width band, $brightness', (tester) async {
        final key = GlobalKey();
        final panel = brightness == Brightness.dark
          ? const Color(0xff30343a) : const Color(0xfff4f5f6);
        await tester.pumpWidget(_host(width: 300, brightness: brightness,
          selectedId: selectedId, panelColor: panel, panelAbove: true,
          tabs: const [
            JoinedTab(id: 'all', label: 'Tümü'),
            JoinedTab(id: 'live', label: 'Canlı'),
            JoinedTab(id: 'pinned', label: 'Sabitlenen'),
          ], wrap: (tabs) => RepaintBoundary(key: key, child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [SizedBox(height: 32, child: ColoredBox(color: panel,
              child: const SizedBox.expand())), tabs],
          ))));
        await tester.pumpAndSettle();
        final pixel = await _pixels(tester, key);
        final index = ['all', 'live', 'pinned'].indexOf(selectedId);
        final selectedX = index * 100 + 50;
        for (final y in [30, 31, 32, 33, 34, 36]) {
          expect(pixel(selectedX, y), panel, reason: 'No line or shadow may close the selected tab at the body boundary');
        }
        for (var column = 0; column < 3; column++) {
          if (column == index) continue;
          expect(pixel(column * 100 + 50, 34), isNot(panel),
            reason: 'Inactive tabs start recessed immediately, without a raised connector strip');
        }
      });
    }

    for (final panelAbove in [false, true]) {
      testWidgets('inset lighting stays top-left for panelAbove=$panelAbove, $brightness', (tester) async {
        final key = GlobalKey();
        await tester.pumpWidget(_host(width: 300, brightness: brightness,
          panelAbove: panelAbove, selectedId: 'inbox',
          wrap: (tabs) => RepaintBoundary(key: key, child: tabs)));
        await tester.pumpAndSettle();
        final height = tester.getSize(find.byType(NeoJoinedTabs)).height.round();
        final pixel = await _pixels(tester, key);
        final inset = NeoPalette.forBrightness(brightness).inset.computeLuminance();
        const top = 2;
        final bottom = panelAbove ? height - 3 : height - 15;
        expect(pixel(50, top).computeLuminance(), lessThan(inset));
        expect(pixel(50, bottom).computeLuminance(), greaterThan(inset));
      });
    }
  }

  testWidgets('upward paint leaves labels, semantic order and keyboard native', (tester) async {
    final semantics = tester.ensureSemantics();
    final changes = <String>[];
    await tester.pumpWidget(_host(panelAbove: true, onSelected: changes.add));
    final projects = tester.getRect(_button('Projeler'));
    final action = tester.getRect(_button('Yeni oturum'));
    final inbox = tester.getRect(_button('Gelen kutusu'));
    expect(projects.left, lessThan(action.left));
    expect(action.left, lessThan(inbox.left));
    expect(action.top, projects.top);
    expect(inbox.top, projects.top);
    expect(find.descendant(of: find.byType(NeoJoinedTabs), matching: find.byType(Transform)), findsNothing);
    expect(tester.getSemantics(find.bySemanticsLabel('Projeler'))
      .getSemanticsData().flagsCollection.isSelected.toBoolOrNull(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(changes, ['new']);
    expect(_focus(tester, 'Yeni oturum').hasFocus, isTrue);
    semantics.dispose();
  });

  testWidgets('default raised panel is exact and action IDs never paint selected', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(_host(width: 300, selectedId: 'new',
      wrap: (tabs) => RepaintBoundary(key: key, child: tabs)));
    await tester.pumpAndSettle();
    final height = tester.getSize(find.byType(NeoJoinedTabs)).height.round();
    final pixel = await _pixels(tester, key);
    final palette = NeoPalette.forBrightness(Brightness.light);
    expect(pixel(150, height - 2), palette.raised);
    expect(pixel(150, 8), isNot(palette.raised));
    expect(pixel(50, 8), isNot(palette.raised));
    expect(pixel(250, 8), isNot(palette.raised));
  });
}
