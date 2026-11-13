import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/project_cards.dart';
import 'package:omputer/ui.dart';
import 'package:omputer/working_avatar.dart';

class _LocalPins implements NativeAdapter {
  final calls = <(String, Json?)>[];
  bool fail = false;

  @override
  Stream<Object?> get events => const Stream.empty();

  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    calls.add((method, arguments));
    if (fail) throw StateError('Yerel kayıt yapılamadı');
    if (method != 'localStateSet') throw StateError('Unexpected request: $method');
    return {'sections': {arguments!['section']: {arguments['key']: arguments['value']}}};
  }
}

const _project = <String, dynamic>{
  'id': 'phone',
  'name': 'Telefon uygulaması',
  'goal': 'Android oturumlarını güvenle izle',
};

OmputerController _controller({
  List<Json> projects = const [_project],
  List<Json> sessions = const [],
  List<Json> interactions = const [],
  bool connected = true,
}) => OmputerController(adapter: _LocalPins())
    ..connection = ConnectionState.fromJson({'connected': connected})
    ..snapshot = Snapshot.fromJson({'projects': projects, 'sessions': sessions, 'interactions': interactions});

Future<void> _mount(WidgetTester tester, OmputerController controller, {
  bool selected = false,
  bool expanded = false,
  bool animateAvatar = true,
  bool dense = false,
  double denseHeight = 192,
  Brightness brightness = Brightness.light,
  double scale = 1,
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: omputerTheme(brightness),
    home: Builder(builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: SingleChildScrollView(child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final project = controller.snapshot.projects.first;
          final card = ProjectOverviewCard(
            controller: controller,
            project: project,
            summary: projectSummaries(controller, [project])[project.id]!,
            selected: selected,
            expanded: expanded,
            animateAvatar: animateAvatar,
            dense: dense,
            onTap: onTap ?? () {},
          );
          return Padding(padding: const EdgeInsets.all(20), child: dense
              ? SizedBox(height: denseHeight, child: card)
              : expanded ? SizedBox(height: 360, child: card) : card);
        },
      ))),
    )),
  ));
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, OmputerController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  test('shared summaries aggregate real project IDs in one snapshot pass', () {
    final controller = _controller(projects: [
      {..._project, 'pendingCount': 2, 'activity': {'pendingCount': 3}},
      {'id': 'other', 'name': 'Başka proje'},
    ], sessions: [
      {'id': 'foreground', 'projectId': 'phone', 'transport': 'rpc', 'writerConnected': true, 'status': 'running', 'workState': 'running'},
      {'id': 'background', 'projectId': 'phone', 'transport': 'rpc', 'writerConnected': true, 'status': 'idle', 'workState': 'background'},
      {'id': 'archive', 'projectId': 'phone', 'transport': 'archive', 'status': 'closed'},
      {'id': 'unbridged', 'projectId': 'phone', 'transport': 'archive', 'status': 'active-unbridged'},
      {'id': 'other-session', 'projectId': 'other', 'transport': 'rpc', 'writerConnected': true, 'status': 'waiting', 'workState': 'human_wait'},
      {'id': 'unknown', 'projectId': 'unknown', 'transport': 'rpc', 'writerConnected': true, 'status': 'running'},
    ], interactions: [
      {'id': 'pending', 'projectId': 'phone'},
      {'id': 'resolved', 'projectId': 'phone', 'status': 'resolved'},
      {'id': 'expired', 'projectId': 'phone', 'expiresAt': '2000-01-01T00:00:00Z'},
      {'id': 'other-question', 'projectId': 'other'},
    ]);
    final summaries = projectSummaries(controller, controller.snapshot.projects);
    expect(summaries.keys, ['phone', 'other']);
    expect(summaries['phone']!.open, 3);
    expect(summaries['phone']!.pending, 3);
    expect(summaries['phone']!.working, isTrue);
    expect(summaries['phone']!.status, 'Çalışıyor');
    expect(summaries['other']!.open, 1);
    expect(summaries['other']!.pending, 1);
    expect(summaries['other']!.working, isFalse);
    expect(summaries['other']!.status, 'Yanıt bekliyor');
    controller.dispose();
  });

  for (final (session, expected) in <(Json, String)>[
    ({'writerConnected': true, 'status': 'idle', 'workState': 'background'}, 'Arka plan işi sürüyor'),
    ({'writerConnected': true, 'status': 'waiting', 'workState': 'background'}, 'Arka plan işi sürüyor'),
    ({'writerConnected': true, 'status': 'idle', 'workState': 'human_wait'}, 'Yanıt bekliyor'),
    ({'writerConnected': true, 'status': 'idle', 'workState': 'settled'}, 'Tur tamamlandı'),
    ({'writerConnected': false, 'status': 'running', 'workState': 'running'}, 'Oturum bağlantısı kesik'),
  ]) {
    test('summary preserves $expected without inferring work from a process', () {
      final controller = _controller(sessions: [
        {'id': 'session', 'projectId': 'phone', 'transport': 'rpc', ...session},
      ]);
      final summary = projectSummaries(controller, controller.snapshot.projects)['phone']!;
      expect(summary.status, expected);
      expect(summary.working, expected == 'Arka plan işi sürüyor');
      controller.dispose();
    });
  }

  test('offline writer loses work state and does not manufacture an empty project', () {
    final controller = _controller(connected: false, sessions: [
      {'id': 'session', 'projectId': 'phone', 'transport': 'rpc', 'status': 'running', 'writerConnected': true, 'workState': 'running'},
    ]);
    final summary = projectSummaries(controller, controller.snapshot.projects)['phone']!;
    expect(summary.open, 1);
    expect(summary.working, isFalse);
    expect(summary.status, 'Bağlantı kesik');
    controller.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('$brightness card shows continuity instead of goal or session inventory', (tester) async {
      final controller = _controller(projects: [
        {..._project, 'summary': 'Klavye düzeltmesi tamamlandı; emülatör kontrolü kaldı'},
      ], sessions: [
        {'id': 'session', 'projectId': 'phone', 'name': 'Must not become a session row', 'transport': 'rpc', 'status': 'running', 'writerConnected': true, 'workState': 'running'},
      ]);
      await _mount(tester, controller, brightness: brightness, selected: true);
      expect(find.text('Klavye düzeltmesi tamamlandı; emülatör kontrolü kaldı'), findsOneWidget);
      expect(find.text(_project['goal']! as String), findsNothing);
      expect(find.text('1 açık oturum'), findsNothing);
      expect(find.text('Projeyi aç'), findsNothing);
      expect(find.byType(WorkingAvatar), findsOneWidget);
      final avatar = tester.getRect(find.byType(WorkingAvatar));
      final title = tester.getRect(find.text('Telefon uygulaması'));
      final preview = tester.getRect(find.text('Klavye düzeltmesi tamamlandı; emülatör kontrolü kaldı'));
      expect(avatar.width, greaterThan(40));
      expect(avatar.right, lessThan(title.left));
      expect(avatar.bottom, lessThanOrEqualTo(preview.top));
      expect(preview.left, lessThan(title.left));
      await _dispose(tester, controller);
    });
  }

  testWidgets('newer activity supplies continuation while fresh durable memory stays authoritative', (tester) async {
    final controller = _controller(projects: [
      {..._project, 'summary': 'Eski özet', 'memoryUpdatedAt': '2026-11-12T12:00:00Z',
        'activity': {'updatedAt': '2026-11-13T12:00:00Z', 'nextStep': 'Son test hatasını düzelt', 'lastAssistantText': 'Gereksiz uzun cevap'}},
    ]);
    await _mount(tester, controller);
    expect(find.text('Son test hatasını düzelt'), findsOneWidget);
    expect(find.text('Eski özet'), findsNothing);
    controller.snapshot = Snapshot.fromJson({'projects': [
      {..._project, 'summary': 'Son hata giderildi; paket hazır', 'memoryUpdatedAt': '2026-11-13T13:00:00Z',
        'activity': {'updatedAt': '2026-11-13T12:00:00Z', 'nextStep': 'Son test hatasını düzelt'}},
    ]});
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Son hata giderildi; paket hazır'), findsOneWidget);
    expect(find.text('Son test hatasını düzelt'), findsNothing);
    await _dispose(tester, controller);
  });

  testWidgets('missing continuity is honest rather than substituting the project goal', (tester) async {
    final controller = _controller();
    await _mount(tester, controller);
    expect(find.text('Son durum henüz kaydedilmedi'), findsOneWidget);
    expect(find.text(_project['goal']! as String), findsNothing);
    await _dispose(tester, controller);
  });

  testWidgets('pin writes exact local project key without activating the card', (tester) async {
    final controller = _controller();
    var taps = 0;
    await _mount(tester, controller, onTap: () => taps++);
    final pin = find.byKey(const ValueKey('project-pin:phone'));
    expect(tester.getSize(pin).shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(pin);
    await tester.pump();
    final adapter = controller.native as _LocalPins;
    expect(adapter.calls, hasLength(1));
    expect(adapter.calls.single.$1, 'localStateSet');
    expect(adapter.calls.single.$2, {'section': 'pins', 'key': 'project:phone', 'value': true});
    expect(find.byTooltip('Proje sabitlemesini kaldır'), findsOneWidget);
    expect(taps, 0);
    await tester.tap(pin);
    await tester.pump();
    expect(adapter.calls.last.$2, {'section': 'pins', 'key': 'project:phone', 'value': false});
    await tester.tap(find.text('Telefon uygulaması'));
    await tester.pump();
    expect(taps, 1);
    await _dispose(tester, controller);
  });

  testWidgets('failed pin remains unchanged and surfaces the native action error', (tester) async {
    final controller = _controller();
    (controller.native as _LocalPins).fail = true;
    await _mount(tester, controller);
    await tester.tap(find.byKey(const ValueKey('project-pin:phone')));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Yerel kayıt yapılamadı'), findsOneWidget);
    expect(find.byTooltip('Projeyi sabitle'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dispose(tester, controller);
  });

  for (final width in [280.0, 360.0, 393.0]) {
    testWidgets('$width dp list card grows for long text at two hundred percent', (tester) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _controller(projects: [
        {..._project, 'name': 'Uzun proje adı ve kaynak oturumları', 'summary': 'Son düzenleme tamamlandı; açık kalan doğrulamalar var'},
      ]);
      await _mount(tester, controller, selected: true, scale: 2);
      expect(tester.takeException(), isNull);
      expect(find.text('Uzun proje adı ve kaynak oturumları'), findsOneWidget);
      final card = tester.getRect(find.byType(ProjectOverviewCard));
      final pin = tester.getRect(find.byKey(const ValueKey('project-pin:phone')));
      expect(card.contains(pin.center), isTrue);
      expect(card.left, 20);
      expect(card.right, width - 20);
      await _dispose(tester, controller);
    });
  }
  for (final width in [280.0, 360.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('dense $width dp card keeps continuity and pin reachable at ${scale * 100} percent', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _controller(projects: [
          {..._project, 'name': 'Uzun proje adı ve kaynak oturumları', 'summary': 'Son düzenleme tamamlandı; açık kalan doğrulamalar var'},
        ], sessions: [
          {'id': 'real-session', 'projectId': 'phone', 'transport': 'rpc', 'status': 'running', 'workState': 'running', 'writerConnected': true},
        ]);
        var taps = 0;
        await _mount(tester, controller, selected: true, dense: true, denseHeight: 160, scale: scale, onTap: () => taps++);
        expect(tester.getSize(find.byType(ProjectOverviewCard)).height, 160);
        expect(find.text('Uzun proje adı ve kaynak oturumları'), findsOneWidget);
        final avatar = tester.getRect(find.byType(WorkingAvatar));
        final title = tester.getRect(find.text('Uzun proje adı ve kaynak oturumları'));
        expect(avatar.right, lessThan(title.left));
        expect(title.right, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('project-pin:phone'))).left));
        expect(tester.takeException(), isNull);
        final preview = find.text('Son düzenleme tamamlandı; açık kalan doğrulamalar var');
        await Scrollable.ensureVisible(tester.element(preview), alignment: 1);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(ProjectOverviewCard)).contains(tester.getCenter(preview)), isTrue);
        final scroll = find.byKey(const ValueKey('project-card-scroll:phone'));
        await tester.drag(scroll, const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 500));
        final pin = find.byKey(const ValueKey('project-pin:phone'));
        await Scrollable.ensureVisible(tester.element(pin), alignment: 0);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(ProjectOverviewCard)).contains(tester.getCenter(pin)), isTrue);
        await tester.tap(pin);
        await tester.pump();
        expect((controller.native as _LocalPins).calls.single.$2, {'section': 'pins', 'key': 'project:phone', 'value': true});
        expect(taps, 0);
        expect(tester.takeException(), isNull);
        await _dispose(tester, controller);
      });
    }
  }
}
