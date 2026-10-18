import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/session.dart';
import 'package:omputer/ui.dart';

class ProjectNative implements NativeAdapter {
  final calls = <Json>[];
  Completer<Object?>? fileReply;
  bool conflict = false;
  final sections = <String, dynamic>{};
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    if (method == 'draftLoad') return null;
    if (method == 'draftSave' || method == 'draftDelete' || method == 'removeAttachment') return null;
    if (method == 'localStateSet') { final section = sections.putIfAbsent('${args!['section']}', () => <String, dynamic>{}) as Json; section['${args['key']}'] = args['value']; return {'identity': 'test', 'sections': sections}; }
    if (method == 'sharedImages') return <Json>[];
    if (method != 'request') throw StateError('Unexpected $method');
    calls.add(args!);
    if ('${args['path']}'.contains('/files?')) return fileReply?.future ?? {'text': 'File A'};
    if ('${args['path']}'.contains('/messages')) return {'messages': [], 'hasMore': false};
    if ('${args['path']}'.contains('/memory/history')) return {'entries': [{'sequence': 3, 'revision': 2, 'origin': 'agent', 'memory': {'goal': 'New server goal', 'summary': 'New server summary', 'nextStep': 'New server next step', 'decisions': ['New decision'], 'sourceSessionId': 'missing-session'}}], 'hasMore': false};
    if (args['method'] == 'PATCH') { if (conflict) throw ControllerFailure('Changed elsewhere', 'memory_conflict'); return {'id': 'project', ...object(args['body'])}; }
    if (args['path'] == '/v1/snapshot') return {'sequence': 0};
    throw StateError('Unexpected request $args');
  }
}

OmputerController projectController(ProjectNative native) => OmputerController(adapter: native)
  ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
  ..snapshot = Snapshot.fromJson({'sequence': 1, 'projects': [{'id': 'project', 'name': 'Project', 'sourceSessionId': 'missing-session', 'summary': 'Original'}]});

Future<void> removeScreen(WidgetTester tester, OmputerController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  testWidgets('checkpoint with source outside snapshot stays editable and preserves its source', (tester) async {
    final native = ProjectNative();
    final controller = projectController(native);
    await tester.pumpWidget(MaterialApp(home: CheckpointEditor(controller: controller, project: controller.snapshot.projects.single)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).at(1), 'Updated');
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Hafızayı kaydet'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, 'Hafızayı kaydet'));
    await tester.pumpAndSettle();
    final patch = native.calls.singleWhere((call) => call['method'] == 'PATCH');
    expect(object(patch['body'])['sourceSessionId'], 'missing-session');
    expect(object(patch['body'])['summary'], 'Updated');
    expect(object(patch['body'])['expectedMemoryRevision'], 0);
    await removeScreen(tester, controller);
  });
  testWidgets('Android Back keeps an edited checkpoint until discard is confirmed', (tester) async {
    final native = ProjectNative();
    final controller = projectController(native);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CheckpointEditor(controller: controller, project: controller.snapshot.projects.single))), child: const Text('Open editor'))))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Unsaved goal');
    tester.testTextInput.hide();
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Vazgeç'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 'Unsaved goal');
    expect(native.calls.where((call) => call['method'] == 'PATCH'), isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Değişiklikleri bırak'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckpointEditor), findsNothing);
    await removeScreen(tester, controller);
  });

  testWidgets('stale checkpoint conflict keeps draft and disables overwrite', (tester) async {
    final native = ProjectNative()..conflict = true;
    final controller = projectController(native);
    await tester.pumpWidget(MaterialApp(home: CheckpointEditor(controller: controller, project: controller.snapshot.projects.single)));
    await tester.enterText(find.byType(TextField).at(1), 'My unsaved revision');
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Hafızayı kaydet'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, 'Hafızayı kaydet'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Hafızayı kaydet'), 200, scrollable: find.byType(Scrollable).first);
    expect(native.calls.where((call) => call['method'] == 'PATCH'), hasLength(1));
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Hafızayı kaydet')).onPressed, isNull);
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text, 'My unsaved revision');
    expect(find.byType(CheckpointEditor), findsOneWidget);
    expect(controller.snapshot.projects.single.summary, 'Original');
    await removeScreen(tester, controller);
  });

  testWidgets('conflict merge defaults to latest fields and changes revision only after explicit acceptance', (tester) async {
    final native = ProjectNative()..conflict = true;
    final controller = projectController(native);
    await tester.pumpWidget(MaterialApp(home: CheckpointEditor(controller: controller, project: controller.snapshot.projects.single)));
    await tester.enterText(find.byType(TextField).at(1), 'My unsaved revision');
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Hafızayı kaydet'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, 'Hafızayı kaydet'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Güncel sürümü getir'), -250, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Güncel sürümü getir'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Alanları karşılaştır ve birleştir'));
    await tester.tap(find.text('Alanları karşılaştır ve birleştir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Seçilen alanlarla düzenle'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text, 'New server summary');
    native.conflict = false;
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Hafızayı kaydet'), 250, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, 'Hafızayı kaydet'));
    await tester.pumpAndSettle();
    final patches = native.calls.where((call) => call['method'] == 'PATCH').toList();
    expect(object(patches.first['body'])['expectedMemoryRevision'], 0);
    expect(object(patches.last['body'])['expectedMemoryRevision'], 2);
    expect(object(patches.last['body'])['summary'], 'New server summary');
    await removeScreen(tester, controller);
  });

  testWidgets('file preview clears old contents and blocks duplicate keyboard submission during load', (tester) async {
    final native = ProjectNative();
    final controller = projectController(native);
    await tester.pumpWidget(MaterialApp(home: FilePreviewScreen(controller: controller, project: controller.snapshot.projects.single)));
    final field = find.byType(TextField);
    await tester.enterText(field, 'a.txt');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('File A'), findsOneWidget);
    native.fileReply = Completer<Object?>();
    await tester.enterText(field, 'b.txt');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('File A'), findsNothing);
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(native.calls.where((call) => '${call['path']}'.contains('/files?')), hasLength(2));
    native.fileReply!.completeError(StateError('File does not exist'));
    await tester.pumpAndSettle();
    expect(find.text('File A'), findsNothing);
    expect(tester.widget<TextField>(field).enabled, isTrue);
    await removeScreen(tester, controller);
  });

  testWidgets('new session reacts to disconnect without losing typed draft', (tester) async {
    final native = ProjectNative();
    final controller = projectController(native);
    await tester.pumpWidget(MaterialApp(home: NewSessionScreen(controller: controller, projectId: 'project')));
    await tester.enterText(find.byType(TextField).last, 'Keep my prompt');
    tester.testTextInput.hide();
    controller.connection = ConnectionState.fromJson({'paired': true, 'connected': false});
    controller.notifyListeners();
    await tester.pump();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Oturumu başlat'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Oturumu başlat')).onPressed, isNull);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'Keep my prompt');
    await removeScreen(tester, controller);
  });

  testWidgets('composer has an accessible name and remains scrollable at large font with keyboard', (tester) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final native = ProjectNative();
    final controller = projectController(native);
    controller.snapshot = Snapshot.fromJson({'sessions': [{'id': 'session', 'transport': 'rpc', 'status': 'idle', 'capabilities': ['session.prompt']}]});
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2), viewInsets: const EdgeInsets.only(bottom: 280)), child: child!), home: SessionScreen(controller: controller, sessionId: 'session')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('OMP’ye mesaj')), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await removeScreen(tester, controller);
  });
}
