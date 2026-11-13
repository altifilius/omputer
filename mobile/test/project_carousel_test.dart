import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/project_carousel.dart';
import 'package:omputer/projects.dart';
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
  const _Harness({super.key, required this.controller, this.autoRotate = false, this.reduced = false, this.accessible = false, this.scale = 1, this.scrollTail = false});
  final OmputerController controller;
  final bool autoRotate, reduced, accessible, scrollTail;
  final double scale;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<Project> projects = widget.controller.snapshot.projects;
  String selected = 'phone';
  final selections = <String>[];
  final scroll = ScrollController();
  bool ticker = true;

  void replace(List<Project> value) => setState(() => projects = value);

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff595bc4))),
    home: Builder(builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: widget.reduced, accessibleNavigation: widget.accessible, textScaler: TextScaler.linear(widget.scale)),
      child: Scaffold(body: SingleChildScrollView(
        controller: scroll,
        child: Column(children: [
          TickerMode(enabled: ticker, child: ProjectCarousel(
            controller: widget.controller,
            projects: projects,
            selectedProjectId: selected,
            autoRotate: widget.autoRotate,
            onSelected: (id) => setState(() { selected = id; selections.add(id); }),
          )),
          if (widget.scrollTail) const SizedBox(height: 1600),
        ]),
      )),
    )),
  );
}

OmputerController _controller({List<Json> sessions = const [], bool connected = true, List<Json> projects = _projects}) =>
    OmputerController(adapter: _NoRequests())
      ..connection = ConnectionState.fromJson({'connected': connected})
      ..snapshot = Snapshot.fromJson({'projects': projects, 'sessions': sessions});

Future<void> _mount(WidgetTester tester, OmputerController controller, GlobalKey<_HarnessState> key, {bool auto = false, bool reduced = false, bool accessible = false, double scale = 1, bool scrollTail = false}) async {
  await tester.pumpWidget(_Harness(key: key, controller: controller, autoRotate: auto, reduced: reduced, accessible: accessible, scale: scale, scrollTail: scrollTail));
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, OmputerController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

Finder _card(String id) => find.byKey(ValueKey('project-card:$id'));
Finder get _next => find.byKey(const ValueKey('project-carousel-next'));
Finder get _previous => find.byKey(const ValueKey('project-carousel-previous'));

void main() {
  testWidgets('next selects exact id and front tap opens that ProjectScreen without requests', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    await tester.tap(_next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(key.currentState!.selected, 'bridge');
    expect(key.currentState!.selections, ['bridge']);
    await tester.tap(_card('bridge'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(tester.widget<ProjectScreen>(find.byType(ProjectScreen)).projectId, 'bridge');
    expect((controller.native as _NoRequests).calls, isEmpty);
    await _dispose(tester, controller);
  });

  testWidgets('a visible side card selects before opening on its next tap', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    // The next face sits to the right; tap its exposed edge, not the front card.
    await tester.tapAt(tester.getCenter(_card('bridge')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(key.currentState!.selected, 'bridge');
    expect(find.byType(ProjectScreen), findsNothing);
    await tester.tap(_card('bridge'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(tester.widget<ProjectScreen>(find.byType(ProjectScreen)).projectId, 'bridge');
    await _dispose(tester, controller);
  });

  testWidgets('horizontal drag pauses auto and snaps to the nearest real project', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, auto: true);
    await tester.drag(find.byKey(const ValueKey('project-carousel-stage')), const Offset(-224, 0));
    await tester.pump(const Duration(milliseconds: 260));
    expect(key.currentState!.selected, 'bridge');
    await tester.pump(const Duration(seconds: 5));
    expect(key.currentState!.selected, 'bridge');
    expect(find.byTooltip('Döndürmeyi başlat'), findsOneWidget);
    await _dispose(tester, controller);
  });

  testWidgets('covered route pauses auto even under a nonopaque page', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, auto: true);
    final context = tester.element(find.byType(ProjectCarousel));
    final navigator = Navigator.of(context);
    unawaited(navigator.push(PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (context, animation, secondaryAnimation) => const Material(type: MaterialType.transparency, child: Center(child: Text('Salt okunur katman'))),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 6));
    expect(key.currentState!.selected, 'phone');
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 300));
    await _dispose(tester, controller);
  });

  testWidgets('payload reorder preserves selected project identity', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, reduced: true);
    await tester.tap(_next);
    await tester.pump();
    key.currentState!.replace(controller.snapshot.projects.reversed.toList());
    await tester.pump();
    expect(key.currentState!.selected, 'bridge');
    expect(key.currentState!.selections, ['bridge']);
    expect(tester.getSemantics(_card('bridge')).getSemanticsData().hasFlag(SemanticsFlag.isSelected), isTrue);
    await _dispose(tester, controller);
    semantics.dispose();
  });

  testWidgets('filtered removal selects first remaining identity and empty list is safe', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, reduced: true);
    key.currentState!.replace(controller.snapshot.projects.skip(2).toList());
    await tester.pump();
    await tester.pump();
    expect(key.currentState!.selected, 'notes');
    expect(find.text('1 / 3'), findsOneWidget);
    key.currentState!.replace([]);
    await tester.pump();
    expect(find.byKey(const ValueKey('project-carousel-stage')), findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });

  testWidgets('small phone with 200 percent text has no layout overflow', (tester) async {
    tester.view.physicalSize = const Size(280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _controller(projects: [
      {..._projects.first, 'name': 'Uzun proje adı ve kaynak oturumları', 'goal': 'Uzun hedef açıklaması bütün sistem metin ölçeklerinde okunabilir kalır', 'pendingCount': 12},
      _projects[1],
    ]);
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, scale: 2, reduced: true);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(_next);
    await tester.tap(_next);
    await tester.pump();
    expect(key.currentState!.selected, 'bridge');
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });

  testWidgets('reduced motion keyboard selects immediately and settles', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, auto: true, reduced: true);
    final node = Focus.of(tester.element(find.byKey(const ValueKey('project-carousel-stage'))));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.selected, 'bridge');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(key.currentState!.selected, 'phone');
    expect(tester.widget<Transform>(find.ancestor(of: _card('phone'), matching: find.byType(Transform)).first).transform, Matrix4.identity());
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _dispose(tester, controller);
  });

  testWidgets('front semantics increase and decrease select instantly', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, reduced: true);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(tester.getSemantics(_card('phone')).id, SemanticsAction.increase);
    await tester.pump();
    expect(key.currentState!.selected, 'bridge');
    tester.binding.pipelineOwner.semanticsOwner!.performAction(tester.getSemantics(_card('bridge')).id, SemanticsAction.decrease);
    await tester.pump();
    expect(key.currentState!.selected, 'phone');
    await _dispose(tester, controller);
    semantics.dispose();
  });

  testWidgets('waiting with async work and disconnected snapshots never run the avatar', (tester) async {
    final controller = _controller(sessions: [
      {'id': 'session', 'projectId': 'phone', 'transport': 'rpc', 'status': 'waiting', 'workState': 'human_wait', 'writerConnected': true, 'hasPendingAsyncWork': true},
    ]);
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    expect(find.byType(WorkingAvatar), findsNothing);
    expect(find.text('Yanıt bekliyor'), findsOneWidget);
    controller.snapshot = Snapshot.fromJson({'projects': _projects, 'sessions': [
      {'id': 'session', 'projectId': 'phone', 'transport': 'rpc', 'status': 'running', 'workState': 'running', 'writerConnected': true},
    ]});
    controller.connection = ConnectionState.fromJson({'connected': false});
    controller.notifyListeners();
    await tester.pump();
    expect(find.byType(WorkingAvatar), findsNothing);
    expect(find.text('Bağlantı kesik'), findsWidgets);
    await _dispose(tester, controller);
  });

  testWidgets('only foreground project with a connected working writer animates', (tester) async {
    final controller = _controller(sessions: [
      for (final project in _projects) {'id': 'session-${project['id']}', 'projectId': project['id'], 'writerConnected': true, 'workState': 'running', 'transport': 'rpc', 'status': 'running'},
    ]);
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key);
    final avatars = tester.widgetList<WorkingAvatar>(find.byType(WorkingAvatar)).where((avatar) => avatar.running);
    expect(avatars, hasLength(1));
    expect(find.descendant(of: _card('phone'), matching: find.byType(WorkingAvatar)), findsOneWidget);
    await _dispose(tester, controller);
  });

  testWidgets('20 second auto revolution pauses on interaction and can be resumed', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, auto: true);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(key.currentState!.selected, 'network');
    await tester.tap(_next);
    await tester.pump(const Duration(milliseconds: 260));
    final pausedId = key.currentState!.selected;
    await tester.pump(const Duration(seconds: 5));
    expect(key.currentState!.selected, pausedId);
    await tester.tap(find.byTooltip('Döndürmeyi başlat'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(key.currentState!.selected, isNot(pausedId));
    await _dispose(tester, controller);
  });

  testWidgets('offscreen lifecycle and TickerMode stop auto rotation', (tester) async {
    final controller = _controller();
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, auto: true, scrollTail: true);
    key.currentState!.scroll.jumpTo(700);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(key.currentState!.selected, 'phone');
    key.currentState!.scroll.jumpTo(0);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 6));
    expect(key.currentState!.selected, 'phone');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    key.currentState!.setState(() => key.currentState!.ticker = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(key.currentState!.selected, 'phone');
    await _dispose(tester, controller);
  });

  testWidgets('accessibility disables auto and single project controls remain safely disabled', (tester) async {
    final controller = _controller(projects: [_projects.first]);
    final key = GlobalKey<_HarnessState>();
    await _mount(tester, controller, key, auto: true, accessible: true);
    await tester.pump(const Duration(seconds: 25));
    expect(key.currentState!.selections, isEmpty);
    expect(tester.widget<IconButton>(_next).onPressed, isNull);
    expect(tester.widget<IconButton>(_previous).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('project-carousel-play'))).onPressed, isNull);
    await _dispose(tester, controller);
  });
}
