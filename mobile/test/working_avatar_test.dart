import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/working_avatar.dart';

// Decode the actual asset outside FakeAsync, then replay those decoded frames
// through Flutter's normal MultiFrameImageStreamCompleter in the fake clock.
// Only the test adapter stores all frames; production decodes incrementally.
Future<_DecodedGifCodec> _decodeGif() async {
  final data = await rootBundle.load('assets/sisyphus-working.gif');
  final codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    targetWidth: 256,
  );
  final frames = <ui.FrameInfo>[];
  try {
    expect(codec.frameCount, 12);
    expect(codec.repetitionCount, -1);
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame();
      expect(frame.duration, const Duration(milliseconds: 140));
      frames.add(frame);
    }
    return _DecodedGifCodec(frames, codec.repetitionCount);
  } finally {
    codec.dispose();
  }
}

class _DecodedGifCodec implements ui.Codec {
  _DecodedGifCodec(this.frames, this.repetitionCount);

  final List<ui.FrameInfo> frames;
  int next = 0;

  @override
  int get frameCount => frames.length;

  @override
  final int repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    final frame = frames[next];
    next = (next + 1) % frames.length;
    return SynchronousFuture(_DecodedFrame(frame.image.clone(), frame.duration));
  }

  @override
  void dispose() {
    for (final frame in frames) {
      frame.image.dispose();
    }
  }
}

class _DecodedFrame implements ui.FrameInfo {
  _DecodedFrame(this.image, this.duration);

  @override
  final ui.Image image;

  @override
  final Duration duration;
}

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
      child: TickerMode(
        enabled: tickerEnabled,
        child: Center(child: WorkingAvatar(running: running, size: 64)),
      ),
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  TestWidgetsFlutterBinding binding,
  Widget widget,
) async {
  const provider = ResizeImage(AssetImage('assets/sisyphus-working.gif'), width: 256);
  final codec = (await tester.runAsync(_decodeGif))!;
  final key = (await tester.runAsync(
    () => provider.obtainKey(const ImageConfiguration(devicePixelRatio: 1)),
  ))!;
  binding.imageCache.putIfAbsent(
    key,
    () => MultiFrameImageStreamCompleter(
      codec: SynchronousFuture(codec),
      scale: 1,
    ),
  );
  await tester.pumpWidget(widget);
  await tester.pump();
  expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
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
  await tester.pump(const Duration(milliseconds: 420));
  expect(await _pixels(tester), orderedEquals(initial));
  await tester.pump(const Duration(milliseconds: 560));
  expect(await _pixels(tester), orderedEquals(initial));
}

Future<void> _expectMoving(WidgetTester tester) async {
  final initial = await _pixels(tester);
  await tester.pump(const Duration(milliseconds: 140));
  await tester.pump();
  expect(await _pixels(tester), isNot(orderedEquals(initial)));
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.imageCache.clear();
    binding.imageCache.clearLiveImages();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    binding.imageCache.clear();
    binding.imageCache.clearLiveImages();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('inactive avatar shows supplied still art and inactive semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester, binding, _host(running: false));
    expect(find.bySemanticsLabel('Oturum çalışmıyor'), findsOneWidget);
    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsNothing);
    expect(tester.getSize(find.byType(Image)), const Size(64, 64));
    final pixels = await _pixels(tester);
    expect(pixels.where((component) => component != 0), isNotEmpty);
    await _expectStill(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('real GIF moves at its cadence and mounted running changes stop it',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester, binding, _host());
    final state = tester.state(find.byType(WorkingAvatar));
    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsOneWidget);
    final initial = await _pixels(tester);
    await tester.pump(const Duration(milliseconds: 139));
    expect(await _pixels(tester), orderedEquals(initial));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(await _pixels(tester), isNot(orderedEquals(initial)));
    await tester.pumpWidget(_host(running: false));
    expect(tester.state(find.byType(WorkingAvatar)), same(state));
    expect(find.bySemanticsLabel('Oturum çalışmıyor'), findsOneWidget);
    await _expectStill(tester);
    await tester.pumpWidget(_host());
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('initial reduced motion stays still without hiding running status',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester, binding, _host(disableAnimations: true));
    expect(find.bySemanticsLabel('Oturum çalışıyor'), findsOneWidget);
    await _expectStill(tester);
    await tester.pumpWidget(_host(accessibleNavigation: true));
    await _expectStill(tester);
    await tester.pumpWidget(_host());
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('motion preferences and ancestor TickerMode gate mounted GIF',
      (tester) async {
    await _mount(tester, binding, _host());
    final state = tester.state(find.byType(WorkingAvatar));
    await _expectMoving(tester);
    for (final host in [
      _host(disableAnimations: true),
      _host(accessibleNavigation: true),
      _host(tickerEnabled: false),
    ]) {
      await tester.pumpWidget(host);
      expect(tester.state(find.byType(WorkingAvatar)), same(state));
      await _expectStill(tester);
    }
    await tester.pumpWidget(_host());
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('every background lifecycle state stops and resume restarts GIF',
      (tester) async {
    await _mount(tester, binding, _host());
    await _expectMoving(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      await _expectStill(tester);
    }
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a covering nonopaque route pauses GIF until it is popped',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await _mount(
      tester,
      binding,
      MaterialApp(navigatorKey: navigator, home: _host()),
    );
    await _expectMoving(tester);
    navigator.currentState!.push(PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    ));
    await tester.pump();
    await _expectStill(tester);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump();
    await _expectMoving(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
