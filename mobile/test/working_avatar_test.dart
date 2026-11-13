import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/working_avatar.dart';

Widget _host({
  bool running = true,
  bool disableAnimations = false,
  bool accessibleNavigation = false,
  bool tickerEnabled = true,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        accessibleNavigation: accessibleNavigation,
      ),
      child: Theme(
        data: ThemeData(colorSchemeSeed: Colors.indigo),
        child: TickerMode(
          enabled: tickerEnabled,
          child: Center(child: WorkingAvatar(running: running, size: 64)),
        ),
      ),
    ),
  );
}

Future<List<int>> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(
      of: find.byType(WorkingAvatar),
      matching: find.byType(RepaintBoundary),
    ),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data!.buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void> _expectStill(WidgetTester tester) async {
  final initial = await _pixels(tester);
  expect(tester.binding.transientCallbackCount, 0);
  await tester.pump(const Duration(milliseconds: 173));
  expect(await _pixels(tester), orderedEquals(initial));
  await tester.pump(const Duration(milliseconds: 219));
  expect(await _pixels(tester), orderedEquals(initial));
  expect(tester.binding.transientCallbackCount, 0);
}

Future<void> _expectMoving(WidgetTester tester) async {
  await tester.pump();
  final initial = await _pixels(tester);
  expect(tester.binding.transientCallbackCount, greaterThan(0));
  await tester.pump(const Duration(milliseconds: 137));
  expect(await _pixels(tester), isNot(orderedEquals(initial)));
}

void main() {
  testWidgets('inactive avatar is static and exposes its inactive status',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(running: false));

    expect(find.bySemanticsLabel('Oturum çalışmıyor'), findsOneWidget);
    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsNothing);
    await _expectStill(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('reduced motion stays static without hiding running semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(disableAnimations: true));

    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsOneWidget);
    await _expectStill(tester);
    await tester.pumpWidget(_host(accessibleNavigation: true));
    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsOneWidget);
    await _expectStill(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('mounted running changes stop and restart painting and ticking',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(running: false));
    final mountedState = tester.state(find.byType(WorkingAvatar));
    await _expectStill(tester);

    await tester.pumpWidget(_host(running: true));
    expect(tester.state(find.byType(WorkingAvatar)), same(mountedState));
    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsOneWidget);
    await _expectMoving(tester);

    await tester.pumpWidget(_host(running: false));
    expect(tester.state(find.byType(WorkingAvatar)), same(mountedState));
    expect(find.bySemanticsLabel('Oturum çalışmıyor'), findsOneWidget);
    await _expectStill(tester);

    await tester.pumpWidget(_host(running: true));
    expect(tester.state(find.byType(WorkingAvatar)), same(mountedState));
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('motion preferences and TickerMode update while mounted',
      (tester) async {
    await tester.pumpWidget(_host());
    final mountedState = tester.state(find.byType(WorkingAvatar));
    await _expectMoving(tester);

    await tester.pumpWidget(_host(disableAnimations: true));
    expect(tester.state(find.byType(WorkingAvatar)), same(mountedState));
    await _expectStill(tester);
    await tester.pumpWidget(_host(accessibleNavigation: true));
    await _expectStill(tester);
    await tester.pumpWidget(_host(tickerEnabled: false));
    await _expectStill(tester);
    await tester.pumpWidget(_host());
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('background lifecycle stops motion and resume restarts it',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await tester.pumpWidget(_host());
    await _expectMoving(tester);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      await _expectStill(tester);
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
