import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/project_files.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/memory_history.dart';
import 'package:omputer/diagnostics.dart';

class FilesNative implements NativeAdapter {
  final calls = <Json>[];
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    if (method != 'request') throw StateError('Unexpected $method');
    calls.add(args!);
    final uri = Uri.parse('${args['path']}');
    if (uri.path.endsWith('/tree')) {
      if (uri.queryParameters['cursor'] == '100') return {'entries': [{'path': 'tail.txt', 'name': 'tail.txt', 'kind': 'file'}], 'hasMore': false};
      if (uri.queryParameters['path'] == 'src') return {'entries': [{'path': 'src/main.rs', 'name': 'main.rs', 'kind': 'file'}], 'hasMore': false};
      return {'entries': [{'path': 'src', 'name': 'src', 'kind': 'directory'}], 'hasMore': true, 'nextCursor': 100};
    }
    if (uri.path.endsWith('/files')) return {'path': 'src/main.rs', 'text': 'first\nsecond\nthird', 'truncated': false};
    if (uri.path.endsWith('/changes')) return {'files': [{'path': 'src/main.rs', 'status': 'M'}], 'truncated': true};
    if (uri.path.endsWith('/diff')) return {'path': 'src/main.rs', 'text': '@@ -1 +1 @@\n-old\n+new', 'truncated': true, 'binary': false};
    if (uri.path.endsWith('/memory/history')) {
      if (uri.queryParameters['before'] == '5') return {'entries': [{'sequence': 4, 'revision': 1, 'origin': 'manual', 'memory': {'summary': 'Earlier memory'}}], 'hasMore': false};
      return {'entries': [{'sequence': 5, 'revision': 2, 'origin': 'agent', 'memory': {'summary': 'Current stored memory', 'goal': 'Actual goal'}}], 'hasMore': true, 'nextCursor': 5};
    }
    if (uri.path == '/v1/diagnostics') return {'components': {'running': {'native': {'version': '0.2.0', 'sha256': 'running-hash'}}, 'installed': {'native': {'version': '0.3.0', 'sha256': 'installed-hash'}}}, 'update': {'updatePending': true, 'blockers': [{'kind': 'running', 'reason': 'Active writer'}]}, 'backups': {'items': [{'id': 'local-backup', 'bytes': 512, 'journals': 2}]}};
    throw StateError('Unexpected request $args');
  }
}
OmputerController filesController(FilesNative native) => OmputerController(adapter: native)
  ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
  ..snapshot = Snapshot.fromJson({'projects': [{'id': 'p', 'name': 'Project'}]});

void main() {
  testWidgets('file tree uses bounded cursor pages and directory paths', (tester) async {
    final native = FilesNative();
    final c = filesController(native);
    await tester.pumpWidget(MaterialApp(home: ProjectFilesScreen(controller: c, project: c.snapshot.projects.single)));
    await tester.pumpAndSettle();
    expect(Uri.parse('${native.calls.first['path']}').queryParameters['limit'], '100');
    await tester.tap(find.text('Sonraki dosyaları yükle'));
    await tester.pumpAndSettle();
    expect(find.text('tail.txt'), findsOneWidget);
    expect(Uri.parse('${native.calls.last['path']}').queryParameters['cursor'], '100');
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('tail.txt'), findsNothing);
    expect(Uri.parse('${native.calls.last['path']}').queryParameters['path'], 'src');
    await tester.tap(find.text('main.rs'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilePreviewScreen>(find.byType(FilePreviewScreen)).initialPath, 'src/main.rs');
    expect(find.text('first\nsecond\nthird'), findsOneWidget);
    expect(native.calls.every((call) => call['method'] == 'GET'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose();
  });

  testWidgets('changed files open actual bounded read-only diff and expose truncation', (tester) async {
    final native = FilesNative();
    final c = filesController(native);
    await tester.pumpWidget(MaterialApp(home: ProjectFilesScreen(controller: c, project: c.snapshot.projects.single)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Değişen dosyalar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src/main.rs'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectDiffScreen), findsOneWidget);
    expect(find.text('@@ -1 +1 @@\n-old\n+new'), findsOneWidget);
    expect(find.text('Fark boyut sınırında kesildi. Tam farkı bilgisayarda incele.'), findsOneWidget);
    expect(native.calls.every((call) => call['method'] == 'GET'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose();
  });

  testWidgets('memory history pages by numeric sequence without changing current project', (tester) async {
    final native = FilesNative();
    final c = filesController(native);
    await tester.pumpWidget(MaterialApp(home: MemoryHistoryScreen(controller: c, project: c.snapshot.projects.single)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sürüm 2 · Ajan kaydı'));
    await tester.pumpAndSettle();
    expect(find.text('Current stored memory'), findsOneWidget);
    await tester.ensureVisible(find.text('Önceki sürümler'));
    await tester.tap(find.text('Önceki sürümler'));
    await tester.pumpAndSettle();
    expect(Uri.parse('${native.calls.last['path']}').queryParameters['before'], '5');
    expect(c.snapshot.projects.single.summary, isEmpty);
    expect(native.calls.every((call) => call['method'] == 'GET'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose();
  });

  testWidgets('diagnostics distinguishes installed and running versions with blockers', (tester) async {
    final native = FilesNative();
    final c = filesController(native);
    await tester.pumpWidget(MaterialApp(home: DiagnosticsScreen(controller: c)));
    await tester.pumpAndSettle();
    expect(find.text('running'), findsOneWidget);
    expect(find.text('installed'), findsOneWidget);
    expect(find.textContaining('running-hash'), findsOneWidget);
    expect(find.textContaining('installed-hash'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Active writer'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Active writer'), findsOneWidget);
    expect(find.text('Bilgisayarın bildirdiği etkin iş engeli yok.'), findsNothing);
    expect(native.calls.single['path'], '/v1/diagnostics');
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose();
  });
}
