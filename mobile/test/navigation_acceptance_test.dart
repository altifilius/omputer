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

void main() {
  testWidgets('share picker cannot apply an old identity event after computer changes', (tester) async {
    final native = NavigationNative(); final c = navigationController(native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    c.pendingNavigation = {'sharedImages': true}; c.navigation.value = c.pendingNavigation;
    await tester.pumpAndSettle(); await tester.tap(find.text('Konuşma seç')); await tester.pumpAndSettle();
    c.localState = {'identity': 'other-computer', 'sections': {}};
    await tester.tap(find.text('Unique session result')); await tester.pumpAndSettle();
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
  testWidgets('overview uses explicit two-line goal and hides long content until expand', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: HomeScreen(controller: c)));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('overview-goal:project'))).maxLines, 2);
    expect(find.text('Hidden durable memory'), findsNothing);
    expect(find.text('Hidden live answer'), findsNothing);
    await tester.ensureVisible(find.text('Özeti genişlet'));
    await tester.tap(find.text('Özeti genişlet'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('overview-goal:project'))).maxLines, isNull);
    expect(find.text('Hidden durable memory'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('overview direct live access opens actual session in one tap', (tester) async {
    final native = NavigationNative();
    final c = navigationController(native);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await tester.ensureVisible(find.byKey(const ValueKey('recent:project')));
    await tester.tap(find.byKey(const ValueKey('recent:project')));
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'session');
    expect(find.byType(ProjectScreen), findsNothing);
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
