import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/project_cards.dart';
import 'package:omputer/project_carousel.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/ui.dart';
import 'package:omputer/working_avatar.dart';

class _NoRequests implements NativeAdapter {
  final calls = <String>[];
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    calls.add(method);
    throw StateError('Carousel navigation must not request $method');
  }
}

const _projects = <Json>[
  {'id': 'phone', 'name': 'Telefon uygulaması', 'goal': 'Android oturumlarını güvenle izle'},
  {'id': 'bridge', 'name': 'Yerel köprü', 'goal': 'Bilgisayarla yerel bağlantıyı koru'},
  {'id': 'notes', 'name': 'Proje hafızası', 'goal': 'Kararları kaynaklarıyla sakla'},
  {'id': 'files', 'name': 'Dosyalar', 'activity': {'goal': 'Gerçek proje dosyalarını incele'}},
  {'id': 'network', 'name': 'Ağ bağlantısı'},
];

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.controller, this.selected = 'phone', this.reduced = false, this.accessible = false, this.scale = 1});
  final OmputerController controller;
  final String selected;
  final bool reduced, accessible;
  final double scale;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<Project> projects = widget.controller.snapshot.projects;
  late String selected = widget.selected;
  final selections = <String>[];
  final navigator = GlobalKey<NavigatorState>();
  final scroll = ScrollController();
  bool hidden = false;
  bool ticking = true;
  bool allowAuto = true;
  int pauseSignal = 0;
  double height = 248;

  void setHidden(bool value) => setState(() => hidden = value);
  void setTicking(bool value) => setState(() => ticking = value);
  void setAuto(bool value) => setState(() => allowAuto = value);
  void pause() => setState(() => pauseSignal++);
  void replace(List<Project> value) => setState(() => projects = value);
  void select(String id) => setState(() => selected = id);
  void removeInPlace(String id) => setState(() => projects.removeWhere((project) => project.id == id));
  void setHeight(double value) => setState(() => height = value);

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    theme: omputerTheme(Brightness.light),
    home: Builder(builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: widget.reduced, accessibleNavigation: widget.accessible, textScaler: TextScaler.linear(widget.scale)),
      child: Scaffold(body: SingleChildScrollView(controller: scroll, child: Column(children: [
        Offstage(offstage: hidden, child: TickerMode(enabled: ticking, child: ProjectCarousel(
          controller: widget.controller,
          projects: projects,
          selectedProjectId: selected,
          autoAdvance: allowAuto,
          initiallyPaused: false,
          height: height,
          pauseSignal: pauseSignal,
          onSelected: (id) => setState(() { selected = id; selections.add(id); }),
        ))),
        const SizedBox(height: 1600),
      ]))),
    )),
  );
}

OmputerController _controller({List<Json> sessions = const [], bool connected = true, List<Json> projects = _projects}) =>
    OmputerController(adapter: _NoRequests())
      ..connection = ConnectionState.fromJson({'connected': connected})
      ..snapshot = Snapshot.fromJson({'projects': projects, 'sessions': sessions});

Future<void> _mount(WidgetTester tester, OmputerController controller, GlobalKey<_HarnessState> key, {String selected = 'phone', bool reduced = false, bool accessible = false, double scale = 1}) async {
  await tester.pumpWidget(_Harness(key: key, controller: controller, selected: selected, reduced: reduced, accessible: accessible, scale: scale));
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, OmputerController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

Finder _card(String id) => find.byKey(ValueKey('project-card:$id'));
Finder get _deck => find.byKey(const ValueKey('project-carousel-stage'));
Finder get _auto => find.byKey(const ValueKey('project-carousel-auto'));
Finder get _rail => find.byKey(const ValueKey('project-carousel-rail'));
Finder get _front => find.byWidgetPredicate((widget) => widget is ProjectOverviewCard && widget.selected);
String _frontId(WidgetTester tester) => tester.widget<ProjectOverviewCard>(_front).project.id;

Rect _paintRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(box.localToGlobal(Offset.zero), box.localToGlobal(box.size.bottomRight(Offset.zero)));
}

Future<void> _choose(WidgetTester tester, int index, int count) async {
  final rail = tester.getRect(_rail);
  final y = rail.top + 16 + (count == 1 ? 0 : index / (count - 1)) * (rail.height - 32);
  await tester.tapAt(Offset(rail.center.dx, y));
  await tester.pump();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  Focus.of(tester.element(_deck)).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _advance(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await _settle(tester);
}

void main() {
  testWidgets('default paused entry keeps sessions stable until explicit play', (tester) async {
    final controller = _controller();
    final selections = <String>[];
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(
      body: ProjectCarousel(controller: controller, projects: controller.snapshot.projects,
        selectedProjectId: 'phone', onSelected: selections.add),
    )));
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(_frontId(tester), 'phone');expect(selections,isEmpty);
    expect(find.byTooltip('Oynat'),findsOneWidget);
    await tester.tap(_auto);await tester.pump();
    await _advance(tester);
    expect(_frontId(tester),'bridge');expect(selections,['bridge']);
    await _dispose(tester,controller);
  });

  testWidgets('upright neighbors remain layered and every card slides downward after six seconds', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'notes');
    final stage = tester.getRect(_deck);
    final front = _paintRect(tester, _card('notes'));
    final above = _paintRect(tester, _card('files'));
    final below = _paintRect(tester, _card('bridge'));
    expect(stage.height, 248);
    expect(front.height, 192);
    expect(front.top - stage.top, 28);
    expect(above.top - stage.top, closeTo(9.76, .01));
    expect(below.top - stage.top, closeTo(57.76, .01));
    expect(above.width, closeTo(front.width * .94, .01));
    expect(below.bottom, greaterThan(front.bottom));
    expect(above.intersect(stage).top, lessThan(front.top));
    expect(find.byIcon(Icons.expand_less_rounded), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    final before = {for (final id in ['phone', 'bridge', 'notes', 'files', 'network']) id: tester.getTopLeft(_card(id)).dy};
    await tester.pump(const Duration(milliseconds: 5999));
    expect(tester.getTopLeft(_card('notes')).dy, front.top);
    expect(key.currentState!.selections, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // There is no page-sized gap or replacement: the actual neighboring
    // content follows the same downward trajectory, upright, in depth.
    for (final id in ['bridge', 'notes', 'files', 'network']) {
      expect(tester.getTopLeft(_card(id)).dy, greaterThan(before[id]!));
    }
    expect(tester.getTopLeft(_card('files')).dy, lessThan(front.top));
    // Flutter's interpolation simulation completes strictly after its duration;
    // at exactly 40 + 240ms it paints the endpoint but has not scheduled dwell.
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pump();
    expect(_frontId(tester), 'files');
    expect(key.currentState!.selections, ['files']);
    expect(tester.getTopLeft(_card('files')).dy, front.top);
    await _advance(tester);
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['files', 'network']);
    expect(find.byTooltip('Başa dön'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['files', 'network']);
    await tester.tap(_auto);
    await tester.pump();
    expect(_frontId(tester), 'phone');
    expect(key.currentState!.selections, ['files', 'network', 'phone']);
    await tester.pump(const Duration(seconds: 30));
    expect(_frontId(tester), 'phone');
    await _dispose(tester, controller);
  });

  testWidgets('rail endpoints and scrubbing select directly with no intermediate callbacks', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    expect(tester.getSize(_rail).width, 48);
    final rail = tester.getRect(_rail);
    await tester.tapAt(Offset(rail.center.dx, rail.bottom - 16));
    await tester.pump();
    expect(_frontId(tester), 'network');
    expect(find.text('5/5'), findsOneWidget);
    expect(key.currentState!.selections, ['network']);
    expect(find.byTooltip('Başa dön'), findsOneWidget);
    await tester.tapAt(Offset(rail.center.dx, rail.top + 16));
    await tester.pump();
    expect(_frontId(tester), 'phone');
    final gesture = await tester.startGesture(Offset(rail.center.dx, rail.top + 16));
    await gesture.moveTo(Offset(rail.center.dx, rail.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(_frontId(tester), 'notes');
    expect(key.currentState!.selections, ['network', 'phone', 'notes']);
    await tester.pump(const Duration(seconds: 60));
    expect(_frontId(tester), 'notes');
    await _dispose(tester, controller);
  });

  testWidgets('direct selection and front tap open exact real project without requests', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await _choose(tester, 1, 5);
    await _settle(tester);
    expect(key.currentState!.selections, ['bridge']);
    expect(find.text('Yerel köprü'), findsOneWidget);
    expect(find.text('Bilgisayarla yerel bağlantıyı koru'), findsOneWidget);
    await tester.tap(find.text('Yerel köprü'));
    await _settle(tester);
    expect(tester.widget<ProjectScreen>(find.byType(ProjectScreen)).projectId, 'bridge');
    expect((controller.native as _NoRequests).calls, isEmpty);
    await _dispose(tester, controller);
  });

  testWidgets('visible back layers cannot open a different project', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'notes');
    final stage = tester.getRect(_deck);
    // The exposed back strip must not fall through to its card's InkWell.
    await tester.tapAt(Offset(stage.center.dx, stage.bottom - 16));
    await tester.pump();
    expect(find.byType(ProjectScreen), findsNothing);
    expect(_frontId(tester), 'notes');
    expect(key.currentState!.selections, isEmpty);
    await tester.tapAt(tester.getTopLeft(_card('notes')) + const Offset(24, 24));
    await _settle(tester);
    expect(tester.widget<ProjectScreen>(find.byType(ProjectScreen)).projectId, 'notes');
    expect((controller.native as _NoRequests).calls, isEmpty);
    await _dispose(tester, controller);
  });

  testWidgets('rail follows fractional finger phase without animated catchup', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'notes');
    final rail = tester.getRect(_rail);
    final frontTop = tester.getTopLeft(_card('notes')).dy;
    final gesture = await tester.startGesture(rail.center);
    final y = rail.top + 16 + .6875 * (rail.height - 32);
    await gesture.moveTo(Offset(rail.center.dx, y));
    await tester.pump();
    expect(_frontId(tester), 'files');
    expect(tester.getTopLeft(_card('notes')).dy - frontTop, closeTo(22.32, .1));
    expect(key.currentState!.selections, ['files']);
    await gesture.moveTo(Offset(rail.center.dx, rail.bottom - 16));
    await tester.pump();
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['files', 'network']);
    await gesture.up();
    await tester.pump();
    expect(key.currentState!.selections, ['files', 'network']);
    await tester.pump(const Duration(seconds: 30));
    expect(_frontId(tester), 'network');
    await _dispose(tester, controller);
  });

  testWidgets('manual downward page gesture pauses and never wraps at endpoints', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    final cardScroll = tester.state<ScrollableState>(find.descendant(
      of: find.byKey(const ValueKey('project-card-scroll:phone')),
      matching: find.byType(Scrollable),
    ));
    expect(cardScroll.position.maxScrollExtent, 0, reason: 'A fitting card must leave vertical gestures to the pager');
    await tester.drag(_deck, const Offset(0, 180));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    expect(key.currentState!.selections, ['bridge']);
    expect(find.byTooltip('Oynat'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    expect(_frontId(tester), 'bridge');
    await _key(tester, LogicalKeyboardKey.home);
    await _settle(tester);
    await tester.drag(_deck, const Offset(0, -180));
    await tester.pump(const Duration(milliseconds: 800));
    expect(_frontId(tester), 'phone');
    expect(key.currentState!.selections, ['bridge', 'phone']);
    await _dispose(tester, controller);
  });

  testWidgets('pause signal and data updates stay paused until explicit fresh play', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await tester.pump(const Duration(seconds: 5));
    key.currentState!.pause();
    await tester.pump();
    controller.notifyListeners();
    await tester.pump(const Duration(minutes: 1));
    expect(key.currentState!.selections, isEmpty);
    expect(find.byTooltip('Oynat'), findsOneWidget);
    await tester.tap(_auto);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(key.currentState!.selections, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(key.currentState!.selections, ['bridge']);
    await _dispose(tester, controller);
  });

  for (final mode in ['offstage', 'ticker', 'scroll', 'input', 'lifecycle', 'route']) {
    testWidgets('$mode gate suspends and restarts a full dwell without catchup', (tester) async {
      final controller = _controller();
      final key = GlobalKey<_HarnessState>();
      await _mount(tester, controller, key);
      await tester.pump(const Duration(seconds: 5));
      final state = key.currentState!;
      if (mode == 'offstage') state.setHidden(true);
      if (mode == 'ticker') state.setTicking(false);
      if (mode == 'scroll') state.scroll.jumpTo(240);
      if (mode == 'input') state.setAuto(false);
      if (mode == 'lifecycle') tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      if (mode == 'route') state.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Başka ekran'))));
      await _settle(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(state.selections, isEmpty);
      if (mode == 'offstage') state.setHidden(false);
      if (mode == 'ticker') state.setTicking(true);
      if (mode == 'scroll') state.scroll.jumpTo(0);
      if (mode == 'input') state.setAuto(true);
      if (mode == 'lifecycle') tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (mode == 'route') state.navigator.currentState!.pop();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(state.selections, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(state.selections, ['bridge']);
      await _dispose(tester, controller);
    });
  }

  for (final setting in ['reduced', 'accessible']) {
    testWidgets('$setting disables autoplay but selects immediately and finitely', (tester) async {
      final controller = _controller(projects: _projects.take(2).toList());
      final key = GlobalKey<_HarnessState>();
      await _mount(tester, controller, key, reduced: setting == 'reduced', accessible: setting == 'accessible');
      await tester.pump(const Duration(minutes: 1));
      expect(key.currentState!.selections, isEmpty);
      expect(tester.widget<IconButton>(_auto).onPressed, isNull);
      await _choose(tester, 1, 2);
      await tester.pump();
      expect(_frontId(tester), 'bridge');
      expect(tester.getTopLeft(_card('bridge')).dy, 28);
      expect(find.byTooltip('Başa dön'), findsOneWidget);
      await _choose(tester, 0, 2);
      await tester.pump();
      expect(_frontId(tester), 'phone');
      expect(key.currentState!.selections, ['bridge', 'phone']);
      await _dispose(tester, controller);
    });
  }

  testWidgets('keyboard and adjustable rail semantics select instantly and pause', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    Focus.of(tester.element(_deck)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    expect(tester.getTopLeft(_card('bridge')).dy, 28);
    tester.semantics.increase(find.semantics.byAction(SemanticsAction.increase));
    await tester.pump();
    expect(_frontId(tester), 'notes');
    tester.semantics.decrease(find.semantics.byAction(SemanticsAction.decrease));
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(_frontId(tester), 'network');
    expect(find.semantics.byAction(SemanticsAction.increase), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(_frontId(tester), 'phone');
    expect(find.semantics.byAction(SemanticsAction.decrease), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(key.currentState!.selections, ['bridge', 'notes', 'bridge', 'network', 'phone']);
    await _dispose(tester, controller);
    semantics.dispose();
  });

  testWidgets('filtering away the selected project reconciles silently and remains finite', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'notes');
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final state = key.currentState!;
    final reported = List<String>.of(state.selections);
    state.replace(controller.snapshot.projects.take(1).toList());
    await tester.pump();
    expect(_frontId(tester), 'phone');
    expect(find.text('1/1'), findsOneWidget);
    expect(state.selections, reported);
    await tester.pump(const Duration(seconds: 30));
    expect(_frontId(tester), 'phone');
    expect(state.selections, reported);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });


  testWidgets('parent changes reorder removal and in-place updates preserve silent stable IDs', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'notes');
    final state = key.currentState!;
    expect(_frontId(tester), 'notes');
    state.select('bridge');
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    state.replace(controller.snapshot.projects.reversed.toList());
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    expect(find.text('4/5'), findsOneWidget);
    // Mutate the same source list: cached IDs must not trust list identity.
    state.removeInPlace('phone');
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    expect(find.text('4/4'), findsOneWidget);
    expect(state.selections, isEmpty);
    state.replace([]);
    await tester.pump();
    expect(_deck, findsNothing);
    state.replace(controller.snapshot.projects.take(1).toList());
    await tester.pump();
    expect(_frontId(tester), 'phone');
    expect(tester.widget<IconButton>(_auto).onPressed, isNull);
    expect(state.selections, isEmpty);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });

  testWidgets('real data refreshes summary and same-ID card content without resetting selection', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'bridge');
    controller.snapshot = Snapshot.fromJson({'projects': [
      _projects.first,
      {..._projects[1], 'name': 'Güncel köprü', 'pendingCount': 3},
      ..._projects.skip(2),
    ], 'sessions': [
      {'id': 'work', 'projectId': 'bridge', 'transport': 'rpc', 'status': 'running', 'workState': 'running', 'writerConnected': true},
    ]});
    controller.notifyListeners();
    key.currentState!.replace(controller.snapshot.projects);
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    expect(find.text('Güncel köprü'), findsOneWidget);
    expect(find.text('3 karar bekliyor'), findsOneWidget);
    expect(find.text('1 açık oturum'), findsOneWidget);
    expect(find.byType(WorkingAvatar), findsOneWidget);
    controller.connection = ConnectionState.fromJson({'connected': false});
    controller.notifyListeners();
    await tester.pump();
    expect(find.descendant(of: _front, matching: find.text('Bağlantı kesik')), findsOneWidget);
    expect(find.byType(WorkingAvatar), findsNothing);
    expect(key.currentState!.selections, isEmpty);
    await _dispose(tester, controller);
  });

  for (final width in [280.0, 360.0]) {
    testWidgets('$width dp bounded deck keeps controls and scrollable content at 200 percent', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _controller(projects: [
        {..._projects.first, 'name': 'Uzun proje adı ve kaynak oturumları', 'goal': 'Uzun hedef açıklaması bütün sistem metin ölçeklerinde okunabilir kalır', 'pendingCount': 12},
        _projects[1],
      ]);
      final key = GlobalKey<_HarnessState>();
      await _mount(tester, controller, key, scale: 2);
      expect(tester.getSize(find.byType(ProjectCarousel)).height, 248);
      expect(tester.getSize(_front).height, 192);
      expect(tester.takeException(), isNull);
      final scroll = find.byKey(const ValueKey('project-card-scroll:phone'));
      await tester.drag(scroll, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('12 karar bekliyor'), findsOneWidget);
      final pin = find.byKey(const ValueKey('project-pin:phone'));
      expect(tester.getRect(_front).contains(tester.getCenter(pin)), isTrue);
      for (final control in [_auto, _rail]) {
        expect(tester.getSize(control).width, greaterThanOrEqualTo(48));
      }
      await _choose(tester, 1, 2);
      await _settle(tester);
      expect(_frontId(tester), 'bridge');
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    });
  }

  testWidgets('short Home viewport stays at 216 total and rapid controls do not restart auto', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    key.currentState!.setHeight(216);
    await tester.pump();
    expect(tester.getSize(find.byType(ProjectCarousel)).height, 216);
    expect(tester.getSize(_deck).height, 216);
    expect(tester.getSize(_front).height, 160);
    await _choose(tester, 1, 5);
    await _choose(tester, 2, 5);
    await _settle(tester);
    expect(_frontId(tester), 'notes');
    final selected = List<String>.of(key.currentState!.selections);
    await tester.pump(const Duration(minutes: 1));
    expect(key.currentState!.selections, selected);
    expect(_frontId(tester), 'notes');
    expect(find.byTooltip('Oynat'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });

  testWidgets('five hundred real projects keep real layered content bounded during scrubbing', (tester) async {
    final controller = _controller(projects: [
      for (var i = 0; i < 500; i++) {'id': 'project-$i', 'name': 'Proje $i', 'goal': 'Yerel çalışma'},
    ]);
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'project-250');
    expect(_frontId(tester), 'project-250');
    expect(find.byType(ProjectOverviewCard).evaluate().length, 5);
    final rail = tester.getRect(_rail);
    await tester.tapAt(Offset(rail.center.dx, rail.bottom - 16));
    await tester.pump();
    expect(_frontId(tester), 'project-499');
    expect(key.currentState!.selections, ['project-499']);
    expect(find.byType(ProjectOverviewCard).evaluate().length, lessThanOrEqualTo(5));
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });
}
