import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/main.dart';
import 'package:omputer/models.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/project_files.dart';
import 'package:omputer/session.dart';
import 'package:omputer/ui.dart';

class NavigationNative implements NativeAdapter {
  final calls = <Json>[];
  final sections = <String, dynamic>{};
  int sharedImageReads = 0;
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    if (method == 'connection' || method == 'connect') return {'paired': true, 'connected': true};
    if (method == 'snapshot') return {'sequence': 0};
    if (method == 'preferences') return {'theme': 'light'};
    if (method == 'localState') return {'identity': 'test', 'sections': sections};
    if (method == 'operationList') return <Json>[];
    if (method == 'draftLoad') return null;
    if (method == 'draftSave' || method == 'draftDelete') return null;
    if (method == 'sharedImages') { sharedImageReads++; return <Json>[]; }
    if (method == 'localStateSet') {
      final section = sections.putIfAbsent('${args!['section']}', () => <String, dynamic>{}) as Json;
      section['${args['key']}'] = args['value'];
      return {'identity': 'test', 'sections': sections};
    }
    if (method != 'request') throw StateError('Unexpected $method');
    calls.add(args!);
    final uri = Uri.parse('${args['path']}');
    if (uri.path.endsWith('/operations')) return {'operations': [], 'hasMore': false};
    if (uri.path.endsWith('/messages')) return {'messages': [{'id': 'hit', 'role': 'assistant', 'sequence': 2, 'revision': 3, 'content': 'Matching content'}], 'hasMore': false};
    if (uri.path == '/v1/search') return {'results': [{'sessionId': 'session', 'messageId': 'hit', 'projectId': 'project', 'title': 'Exact indexed result', 'snippet': 'Matching content'}], 'hasMore': false};
    throw StateError('Unexpected request $args');
  }
}

OmputerController navigationController(NavigationNative native) => OmputerController(adapter: native)
  ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
  ..snapshot = Snapshot.fromJson({'sequence': 1, 'projects': [{'id': 'project', 'name': 'Proje', 'goal': List.filled(60, 'uzun hedef').join(' '), 'summary': 'Hidden durable memory', 'nextStep': 'Sıradaki gerçek adım', 'activity': {'sessionId': 'session', 'lastAssistantText': 'Hidden live answer'}}], 'sessions': [{'id': 'session', 'projectId': 'project', 'name': 'Unique session result', 'transport': 'bridge', 'status': 'idle', 'capabilities': ['session.prompt']}]});

Snapshot parallelSnapshot({bool terminal = false, bool updated = false}) {
  Json live(String id, String projectId, int minute) => {
    'id': id, 'projectId': projectId, 'name': 'Proje',
    'transport': terminal ? 'archive' : 'bridge',
    'status': terminal ? 'active-unbridged' : 'running',
    'writerConnected': !terminal,
    'updatedAt': '2026-10-28T12:${minute.toString().padLeft(2, '0')}:00Z',
    'capabilities': terminal ? <String>[] : ['session.prompt'],
  };
  final first = live('terminal-first-12345678', 'project', 2);
  final second = live('terminal-second-12345678', 'project', updated ? 5 : 1);
  return Snapshot.fromJson({
    'projects': [{'id': 'project', 'name': 'Proje'}, {'id': 'other', 'name': 'Başka proje'}],
    'sessions': [
      if (updated) second else first,
      if (updated) first else second,
      live('other-live', 'other', 3),
      {'id': 'past-one', 'projectId': 'project', 'name': 'Eski konuşma', 'transport': 'archive', 'status': 'closed'},
      {'id': 'past-two', 'projectId': 'project', 'name': 'Daha eski konuşma', 'transport': 'archive', 'status': 'closed'},
    ],
  });
}

void main() {
  testWidgets('share picker cannot apply an old identity event after computer changes', (tester) async {
    final native = NavigationNative(); final c = navigationController(native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    c.pendingNavigation = {'sharedImages': true}; c.navigation.value = c.pendingNavigation;
    await tester.pumpAndSettle(); await tester.tap(find.text('Konuşma seç')); await tester.pumpAndSettle();
    c.localState = {'identity': 'other-computer', 'sections': {}};
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Unique session result'))); await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsNothing); expect(native.sharedImageReads, 0);
    expect(native.calls.where((call) => call['method'] == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('native share error stays on reading route and shows recovery without sending', (tester) async {
    final native = NavigationNative(); final c = navigationController(native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomeScreen));
    openScreen(context, const Scaffold(body: Text('Current reading route'))); await tester.pumpAndSettle();
    c.pendingNavigation = {'shareError': 'Unsupported image format'}; c.navigation.value = c.pendingNavigation;
    await tester.pumpAndSettle();
    expect(find.textContaining('Unsupported image format'), findsOneWidget);
    await tester.tap(find.text('Kapat')); await tester.pumpAndSettle();
    expect(find.text('Current reading route'), findsOneWidget);
    expect(native.sharedImageReads, 0); expect(native.calls.where((call) => call['method'] == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('native shared image notice preserves typed composer and only offers explicit add', (tester) async {
    final native = NavigationNative(); final c = navigationController(native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    openScreen(tester.element(find.byType(HomeScreen)), SessionScreen(controller: c, sessionId: 'session')); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep my unsent draft'); await tester.pumpAndSettle();
    c.pendingNavigation = {'sharedImages': true}; c.navigation.value = c.pendingNavigation;
    await tester.pumpAndSettle();
    expect(find.text('Paylaşılan görseller hazır'), findsOneWidget);
    await tester.tap(find.text('Konuşmaya dön')); await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep my unsent draft');
    expect(native.sharedImageReads, 0); expect(native.calls.where((call) => call['method'] == 'POST'), isEmpty);
    expect(find.byTooltip('Paylaşılan görselleri ekle'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('shared images outside conversation offer session picker without leaving current route', (tester) async {
    final native = NavigationNative(); final c = navigationController(native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    openScreen(tester.element(find.byType(HomeScreen)), const Scaffold(body: Text('Preserved project reading'))); await tester.pumpAndSettle();
    c.pendingNavigation = {'sharedImages': true}; c.navigation.value = c.pendingNavigation;
    await tester.pumpAndSettle(); await tester.tap(find.text('Konuşma seç')); await tester.pumpAndSettle();
    expect(find.text('Görseller için konuşma seç'), findsOneWidget);
    await tester.tap(find.text('Unique session result')); await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsOneWidget); expect(native.sharedImageReads, 0);
    await tester.binding.handlePopRoute(); await tester.pumpAndSettle(); expect(find.text('Preserved project reading'), findsOneWidget);
    expect(native.calls.where((call) => call['method'] == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('overview expands and collapses project context without leaving home', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: HomeScreen(controller: c)));
    await tester.pump();
    expect(find.text('Hidden durable memory'), findsNothing);
    expect(find.text('Hidden live answer'), findsNothing);
    await tester.ensureVisible(find.text('Özeti genişlet'));
    await tester.tap(find.text('Özeti genişlet'));
    await tester.pump();
    expect(find.text('Hidden durable memory'), findsOneWidget);
    expect(find.text('Hidden live answer'), findsOneWidget);
    expect(find.byType(ProjectScreen), findsNothing);
    await tester.ensureVisible(find.text('Özeti daralt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Özeti daralt'));
    await tester.pump();
    expect(find.text('Hidden durable memory'), findsNothing);
    expect(find.text('Hidden live answer'), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('overview direct live access opens actual session in one tap', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await tester.ensureVisible(find.byKey(const ValueKey('session')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('session')), matching: find.byType(ListTile)));
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'session');
    expect(find.byType(ProjectScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  for (final terminal in [false, true]) {
    testWidgets('overview selects both same-name ${terminal ? 'terminal-open' : 'bridged'} sessions by identity and retains order', (tester) async {
      tester.view.physicalSize = const Size(540, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final native = NavigationNative();
      final c = navigationController(native)..snapshot = parallelSnapshot(terminal: terminal);
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: HomeScreen(controller: c)));
      await tester.pump();
      final project = find.byKey(const ValueKey('project'));
      Finder rows() => find.descendant(of: project, matching: find.byType(LocalSessionRow));
      List<String> ids() => tester.widgetList<LocalSessionRow>(rows()).map((row) => row.session.id).toList();
      expect(ids(), ['terminal-first-12345678', 'terminal-second-12345678']);
      final labels = <String, String>{};
      for (final row in tester.widgetList<LocalSessionRow>(rows())) {
        final tile = tester.widget<ListTile>(find.descendant(of: find.byKey(row.key!), matching: find.byType(ListTile)));
        labels[row.session.id] = ((tile.subtitle! as Column).children.last as Text).data!;
      }
      expect(labels.values.toSet(), hasLength(2));
      expect(find.byKey(const ValueKey('recent:project')), findsNothing);
      expect(find.text('Eski konuşma'), findsNothing);
      c.snapshot = parallelSnapshot(terminal: terminal, updated: true);
      c.notifyListeners();
      await tester.pump();
      expect(ids(), ['terminal-first-12345678', 'terminal-second-12345678']);
      for (final id in ids()) {
        final row = find.byKey(ValueKey(id));
        await tester.ensureVisible(row);
        final tileFinder = find.descendant(of: row, matching: find.byType(ListTile));
        final tile = tester.widget<ListTile>(tileFinder);
        expect(((tile.subtitle! as Column).children.last as Text).data, labels[id]);
        await tester.tap(tileFinder);
        await tester.pumpAndSettle();
        expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, id);
        expect(find.byType(ProjectScreen), findsNothing);
        expect(native.calls.any((call) => Uri.parse('${call['path']}').path == '/v1/sessions/$id/messages'), isTrue);
        if (terminal) {
          expect(find.byType(TextField), findsNothing);
          expect(find.byKey(const ValueKey('session-resume')), findsNothing);
          expect(c.snapshot.session(id)!.writerConnected, isFalse);
          expect(c.snapshot.session(id)!.canSendMessages, isFalse);
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets('overview search does not duplicate project sessions and honors live and pinned filters', (tester) async {
    tester.view.physicalSize = const Size(540, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = navigationController(NavigationNative())..snapshot = parallelSnapshot(terminal: true);
    c.localState = {'identity': 'test', 'sections': {'pins': {'project:project': true}}};
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await tester.enterText(find.byType(TextField), 'Proje');
    await tester.pump();
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row) => row.session.id).toSet(), {'terminal-first-12345678', 'terminal-second-12345678', 'other-live'});
    expect(find.byType(LocalSessionRow), findsNWidgets(3));
    expect(find.byKey(const ValueKey('search:terminal-first-12345678')), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Canlı oturumu olan'));
    await tester.pump();
    expect(find.byKey(const ValueKey('project')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Sabitlenen'));
    await tester.pump();
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row) => row.session.id).toList(), ['terminal-first-12345678', 'terminal-second-12345678']);
    expect(find.byKey(const ValueKey('other')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('project live filter includes terminal-open sessions and history remains separately selectable', (tester) async {
    tester.view.physicalSize = const Size(540, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = navigationController(NavigationNative())..snapshot = parallelSnapshot(terminal: true);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    final project = find.byKey(const ValueKey('project'));
    await tester.tap(find.descendant(of: project, matching: find.text('Projeyi aç')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Canlı'));
    await tester.pump();
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row) => row.session.id).toList(), ['terminal-first-12345678', 'terminal-second-12345678']);
    final references = tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row) {
      final tile = tester.widget<ListTile>(find.descendant(of: find.byKey(row.key!), matching: find.byType(ListTile)));
      return ((tile.subtitle! as Column).children.last as Text).data;
    }).toSet();
    expect(references, hasLength(2));
    await tester.tap(find.widgetWithText(FilterChip, 'Geçmiş'));
    await tester.pump();
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row) => row.session.id).toSet(), {'past-one', 'past-two'});
    await tester.tap(find.text('Eski konuşma'));
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'past-one');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('archive-only project retains recent history shortcut without dumping history rows', (tester) async {
    final c = navigationController(NavigationNative())..snapshot = Snapshot.fromJson({
      'projects': [{'id': 'project', 'name': 'Proje'}],
      'sessions': [
        {'id': 'older', 'projectId': 'project', 'name': 'Older', 'transport': 'archive', 'status': 'closed', 'updatedAt': '2026-10-27T12:00:00Z'},
        {'id': 'latest', 'projectId': 'project', 'name': 'Latest', 'transport': 'archive', 'status': 'closed', 'updatedAt': '2026-10-28T12:00:00Z'},
      ],
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    expect(find.byType(LocalSessionRow), findsNothing);
    final recent = find.byKey(const ValueKey('recent:project'));
    await tester.ensureVisible(recent);
    await tester.tap(recent);
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'latest');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('overview session-name search returns direct session row not only its project', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await tester.enterText(find.byType(TextField), 'Unique session');
    await tester.pump();
    expect(find.byType(LocalSessionRow), findsOneWidget);
    expect(find.byType(ProjectOverviewRow), findsNothing);
    await tester.tap(find.text('Unique session result'));
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'session');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('indexed content search opens matching session and exact message link', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(home: SessionSearchScreen(controller: c, projectId: 'project', initialQuery: 'Matching')));
    await tester.pumpAndSettle();
    final request = Uri.parse('${native.calls.single['path']}');
    expect(request.queryParameters['projectId'], 'project');
    expect(request.queryParameters['limit'], '50');
    await tester.tap(find.text('Exact indexed result'));
    await tester.pumpAndSettle();
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.sessionId, 'session');
    expect(screen.initialMessageId, 'hit');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('project sessions are before collapsed long activity and durable memory', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(home: ProjectScreen(controller: c, projectId: 'project')));
    await tester.pump();
    expect(find.byType(LocalSessionRow), findsOneWidget);
    expect(find.text('Hidden durable memory'), findsNothing);
    expect(find.text('Hidden live answer'), findsNothing);
    expect(tester.getTopLeft(find.text('Oturumlar')).dy, lessThan(tester.getTopLeft(find.text('Son kaldığın yer')).dy));
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('pins persist by identity without moving row and read marker tracks message revision', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    final transcript = c.transcript('session');
    transcript.upsert(ChatMessage.fromJson({'id': 'latest', 'sequence': 5, 'revision': 2, 'content': 'Latest actual content'}));
    c.localState = {'identity': 'test', 'sections': {'read': {'session:session': {'messageId': 'latest', 'revision': 1}}}};
    await tester.pumpWidget(MaterialApp(home: ProjectScreen(controller: c, projectId: 'project')));
    await tester.pump();
    expect(find.textContaining('Okunmadı'), findsOneWidget);
    final position = tester.getTopLeft(find.byType(LocalSessionRow));
    await tester.tap(find.byTooltip('Oturumu sabitle'));
    await tester.pumpAndSettle();
    expect(object(object(c.localState['sections'])['pins'])['session:session'], isTrue);
    expect(tester.getTopLeft(find.byType(LocalSessionRow)), position);
    await c.updateLocalState('read', 'session:session', {'messageId': 'latest', 'revision': 2});
    await tester.pump();
    expect(find.textContaining('Okundu'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose();
  });

  test('local file references preserve line and reject remote or escaping paths', () {
    expect(localFileReference('src/main.rs#L42'), ('src/main.rs', 42));
    expect(localFileReference('src/main.rs:12:3'), ('src/main.rs', 12));
    expect(localFileReference('../secrets'), isNull);
    expect(localFileReference('%2e%2e/secrets'), isNull);
    expect(localFileReference('/etc/passwd'), isNull);
    expect(localFileReference('https://example.com/file'), isNull);
  });
}
