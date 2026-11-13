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

Future<void> _finishAuto(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1201));
  await tester.pump();
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
  await tester.pump(const Duration(seconds: 7));
  await _finishAuto(tester);
}

void main() {
  testWidgets('default deck waits seven idle seconds and slides slowly without play controls', (tester) async {
    final controller = _controller();
    final selections = <String>[];
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(
      body: ProjectCarousel(controller: controller, projects: controller.snapshot.projects,
        selectedProjectId: 'phone', onSelected: selections.add),
    )));
    await tester.pump();
    expect(_auto, findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byIcon(Icons.replay_rounded), findsNothing);
    final top = tester.getTopLeft(_card('phone')).dy;
    await tester.pump(const Duration(milliseconds: 6999));
    expect(tester.getTopLeft(_card('phone')).dy, top);
    expect(selections, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final earlyTop = tester.getTopLeft(_card('phone')).dy;
    expect(earlyTop, greaterThan(top));
    expect(_frontId(tester), 'phone');
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getTopLeft(_card('phone')).dy, greaterThan(earlyTop));
    expect(tester.getTopLeft(_card('bridge')).dy, lessThan(top));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    expect(selections, ['bridge']);
    final settledTop = tester.getTopLeft(_card('bridge')).dy;
    await tester.pump(const Duration(milliseconds: 6999));
    expect(tester.getTopLeft(_card('bridge')).dy, settledTop);
    expect(selections, ['bridge']);
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(_frontId(tester), 'notes');
    expect(selections, ['bridge', 'notes']);
    await _dispose(tester, controller);
  });

  testWidgets('automatic progress stops at the last project and manual navigation remains finite', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'files');
    await _advance(tester);
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['network']);
    expect(_auto, findsNothing);
    await tester.pump(const Duration(minutes: 2));
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['network']);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_frontId(tester), 'network');
    await _key(tester, LogicalKeyboardKey.home);
    expect(_frontId(tester), 'phone');
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_frontId(tester), 'phone');
    expect(key.currentState!.selections, ['network', 'phone']);
    await _advance(tester);
    expect(_frontId(tester), 'bridge');
    await _dispose(tester, controller);
  });

  testWidgets('rail endpoints and scrubbing select directly then restart idle countdown', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await _choose(tester, 4, 5);
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['network']);
    await _choose(tester, 0, 5);
    expect(_frontId(tester), 'phone');
    final rail = tester.getRect(_rail);
    final gesture = await tester.startGesture(Offset(rail.center.dx, rail.top + 16));
    await gesture.moveTo(rail.center);
    await tester.pump();
    expect(_frontId(tester), 'notes');
    await tester.pump(const Duration(seconds: 30));
    expect(_frontId(tester), 'notes');
    await gesture.up();
    await tester.pump();
    expect(key.currentState!.selections, ['network', 'phone', 'notes']);
    await tester.pump(const Duration(milliseconds: 6999));
    expect(_frontId(tester), 'notes');
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(_frontId(tester), 'files');
    expect(key.currentState!.selections, ['network', 'phone', 'notes', 'files']);
    await _dispose(tester, controller);
  });

  testWidgets('direct selection and front tap open exact real project without requests', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await _choose(tester, 1, 5);
    await _settle(tester);
    expect(key.currentState!.selections, ['bridge']);
    expect(_frontId(tester), 'bridge');
    await tester.tapAt(tester.getCenter(_card('bridge')));
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
    expect(tester.getTopLeft(_card('notes')).dy, greaterThan(frontTop));
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

  testWidgets('manual downward drag settles quickly and idle resumes without wrapping', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await tester.drag(_deck, const Offset(0, 100));
    await _settle(tester);
    expect(_frontId(tester), 'bridge');
    expect(key.currentState!.selections, ['bridge']);
    await tester.pump(const Duration(milliseconds: 6699));
    expect(_frontId(tester), 'bridge');
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(_frontId(tester), 'notes');
    await _key(tester, LogicalKeyboardKey.home);
    await tester.drag(_deck, const Offset(0, -180));
    await _settle(tester);
    expect(_frontId(tester), 'phone');
    await _key(tester, LogicalKeyboardKey.end);
    await tester.drag(_deck, const Offset(0, 180));
    await _settle(tester);
    expect(_frontId(tester), 'network');
    expect(key.currentState!.selections, ['bridge', 'notes', 'phone', 'network']);
    await _dispose(tester, controller);
  });

  testWidgets('parent interaction signal cancels motion immediately and starts a fresh idle dwell', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    key.currentState!.pause();
    await tester.pump();
    final interruptedTop = tester.getTopLeft(_card('phone')).dy;
    controller.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 6999));
    expect(tester.getTopLeft(_card('phone')).dy, interruptedTop);
    expect(key.currentState!.selections, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(_frontId(tester), 'bridge');
    expect(key.currentState!.selections, ['bridge']);
    await _dispose(tester, controller);
  });

  for (final release in ['up', 'cancel']) {
    testWidgets('touch $release freezes an active step and waits after the final held pointer', (tester) async {
      final controller = _controller();
      final key = GlobalKey<_HarnessState>();
      await _mount(tester, controller, key);
      final initialTop = tester.getTopLeft(_card('phone')).dy;
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final movingTop = tester.getTopLeft(_card('phone')).dy;
      final first = await tester.startGesture(tester.getCenter(_deck), pointer: 1);
      await tester.pump();
      final stoppedTop = tester.getTopLeft(_card('phone')).dy;
      expect(stoppedTop, greaterThan(initialTop));
      expect(stoppedTop, movingTop);
      final rail = tester.getRect(_rail);
      final second = await tester.startGesture(Offset(rail.center.dx, tester.getRect(_deck).top + 4), pointer: 2);
      await tester.pump();
      final heldTop = tester.getTopLeft(_card('phone')).dy;
      await tester.pump(const Duration(seconds: 30));
      expect(tester.getTopLeft(_card('phone')).dy, heldTop);
      if (release == 'up') {
        await first.up();
      } else {
        await first.cancel();
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(_frontId(tester), 'phone');
      expect(key.currentState!.selections, isEmpty);
      await second.cancel();
      await tester.pump();
      final releasedTop = tester.getTopLeft(_card('phone')).dy;
      await tester.pump(const Duration(milliseconds: 6999));
      expect(tester.getTopLeft(_card('phone')).dy, releasedTop);
      await tester.pump(const Duration(milliseconds: 1));
      await _finishAuto(tester);
      expect(_frontId(tester), 'bridge');
      expect(key.currentState!.selections, ['bridge']);
      await _dispose(tester, controller);
    });
  }

  testWidgets('held keyboard input suppresses autoplay until release and fresh idle dwell', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    Focus.of(tester.element(_deck)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_frontId(tester), 'bridge');
    await tester.pump(const Duration(seconds: 30));
    expect(key.currentState!.selections, ['bridge']);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 6999));
    expect(key.currentState!.selections, ['bridge']);
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(_frontId(tester), 'notes');
    expect(key.currentState!.selections, ['bridge', 'notes']);
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
      if (mode == 'route') state.navigator.currentState!.push(PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondary) => const Scaffold(body: Text('Başka ekran')),
        transitionDuration: Duration.zero, reverseTransitionDuration: Duration.zero,
      ));
      await _settle(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(state.selections, isEmpty);
      if (mode == 'offstage') state.setHidden(false);
      if (mode == 'ticker') state.setTicking(true);
      if (mode == 'scroll') state.scroll.jumpTo(0);
      if (mode == 'input') state.setAuto(true);
      if (mode == 'lifecycle') tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (mode == 'route') state.navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 6999));
      expect(state.selections, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await _finishAuto(tester);
      expect(state.selections, ['bridge']);
      await _dispose(tester, controller);
    });
  }

  for (final mode in ['offstage', 'ticker', 'scroll', 'input', 'lifecycle', 'route']) {
    testWidgets('$mode gate interrupts an active step with no hidden catchup', (tester) async {
      final controller = _controller();
      final key = GlobalKey<_HarnessState>();
      await _mount(tester, controller, key);
      await tester.pump(const Duration(seconds: 7));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final state = key.currentState!;
      if (mode == 'offstage') state.setHidden(true);
      if (mode == 'ticker') state.setTicking(false);
      if (mode == 'scroll') state.scroll.jumpTo(240);
      if (mode == 'input') state.setAuto(false);
      if (mode == 'lifecycle') tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      if (mode == 'route') state.navigator.currentState!.push(PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondary) => const Scaffold(body: Text('Başka ekran')),
        transitionDuration: Duration.zero, reverseTransitionDuration: Duration.zero,
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(state.selections, isEmpty);
      if (mode == 'offstage') state.setHidden(false);
      if (mode == 'ticker') state.setTicking(true);
      if (mode == 'scroll') state.scroll.jumpTo(0);
      if (mode == 'input') state.setAuto(true);
      if (mode == 'lifecycle') tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (mode == 'route') state.navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      final stoppedTop = tester.getTopLeft(_card('phone')).dy;
      await tester.pump(const Duration(milliseconds: 6999));
      expect(tester.getTopLeft(_card('phone')).dy, stoppedTop);
      expect(state.selections, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await _finishAuto(tester);
      expect(_frontId(tester), 'bridge');
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
      expect(_auto, findsNothing);
      await _choose(tester, 1, 2);
      await tester.pump();
      expect(_frontId(tester), 'bridge');
      await _choose(tester, 0, 2);
      await tester.pump();
      expect(_frontId(tester), 'phone');
      expect(key.currentState!.selections, ['bridge', 'phone']);
      await _dispose(tester, controller);
    });
  }

  testWidgets('keyboard and adjustable rail semantics select instantly then restart idle', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    Focus.of(tester.element(_deck)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_frontId(tester), 'bridge');
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
    final manualSelections = ['bridge', 'notes', 'bridge', 'network', 'phone'];
    expect(key.currentState!.selections, manualSelections);
    await tester.pump(const Duration(milliseconds: 6999));
    expect(_frontId(tester), 'phone');
    expect(key.currentState!.selections, manualSelections);
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(key.currentState!.selections, [...manualSelections, 'bridge']);
    await _dispose(tester, controller);
    semantics.dispose();
  });

  testWidgets('filtering away the selected project reconciles silently and remains finite', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, selected: 'notes');
    await tester.pump(const Duration(seconds: 7));
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
    expect(_auto, findsNothing);
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
    final refreshed = tester.widget<ProjectOverviewCard>(_front);
    expect(refreshed.project.name, 'Güncel köprü');
    expect(refreshed.summary.pending, 3);
    expect(refreshed.summary.open, 1);
    expect(refreshed.summary.working, isTrue);
    expect(find.byType(WorkingAvatar), findsOneWidget);
    controller.connection = ConnectionState.fromJson({'connected': false});
    controller.notifyListeners();
    await tester.pump();
    expect(tester.widget<ProjectOverviewCard>(_front).summary.working, isFalse);
    expect(find.byType(WorkingAvatar), findsNothing);
    expect(key.currentState!.selections, isEmpty);
    await _dispose(tester, controller);
  });

  for (final width in [280.0, 360.0]) {
    testWidgets('$width dp deck keeps selection and rail usable at 200 percent text', (tester) async {
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
      expect(tester.takeException(), isNull);
      expect(_frontId(tester), 'phone');
      expect(tester.getSize(_rail).width, greaterThanOrEqualTo(48));
      expect(_auto, findsNothing);
      await _choose(tester, 1, 2);
      await _settle(tester);
      expect(_frontId(tester), 'bridge');
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    });
  }

  testWidgets('short viewport and rapid controls reset a full idle countdown', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    key.currentState!.setHeight(216);
    await tester.pump();
    expect(tester.getSize(find.byType(ProjectCarousel)).height, 216);
    await _choose(tester, 1, 5);
    await tester.pump(const Duration(seconds: 6));
    await _choose(tester, 2, 5);
    expect(_frontId(tester), 'notes');
    expect(key.currentState!.selections, ['bridge', 'notes']);
    await tester.pump(const Duration(milliseconds: 6999));
    expect(key.currentState!.selections, ['bridge', 'notes']);
    await tester.pump(const Duration(milliseconds: 1));
    await _finishAuto(tester);
    expect(_frontId(tester), 'files');
    expect(key.currentState!.selections, ['bridge', 'notes', 'files']);
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
    await _key(tester, LogicalKeyboardKey.home);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ProjectOverviewCard).evaluate().length, lessThanOrEqualTo(5));
      final cards = tester.widgetList<ProjectOverviewCard>(find.byType(ProjectOverviewCard));
      for (final card in cards) {
        expect(card.project, same(controller.snapshot.projects.firstWhere((project) => project.id == card.project.id)));
      }
    }
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(_frontId(tester), 'project-1');
    expect(key.currentState!.selections, ['project-499', 'project-0', 'project-1']);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });
}
