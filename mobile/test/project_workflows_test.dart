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

class ComposerNative extends ProjectNative {
  ComposerNative({required this.withHistory, required this.withAttachments}) {
    if (withAttachments) drafts['session:session:session.prompt'] = {
      'text': 'Saved draft',
      'attachments': [for (var i = 0; i < 4; i++) {'type': 'image', 'mimeType': 'image/png', 'data': png}],
      'files': [{'path': 'lib/source.dart', 'text': 'Selected source', 'truncated': false}],
    };
  }
  static const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
  final bool withHistory, withAttachments;
  final drafts = <String, Json>{};
  final commands = <Json>[];
  Json get data => {'projects': [{'id': 'project', 'name': 'Project'}], 'sessions': [{'id': 'session', 'projectId': 'project', 'transport': 'rpc', 'status': 'running', 'model': {'name': 'Selected model', 'provider': 'local', 'id': 'model'}, 'thinkingLevel': 'high', 'capabilities': ['session.prompt', 'session.steer', 'session.follow_up', 'session.abort']}]};
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    if (method == 'draftLoad') return drafts[args!['key']];
    if (method == 'draftSave') { drafts['${args!['key']}'] = object(args['value']); return null; }
    if (method == 'draftDelete') { drafts.remove(args!['key']); return null; }
    if (method == 'draftList') return drafts;
    if (method == 'operationSave') return null;
    if (method == 'request') {
      if (args!['path'] == '/v1/snapshot') return data;
      if ('${args['path']}'.contains('/messages')) return {'messages': [if (withHistory) for (var i = 0; i < 30; i++) {'id': 'message-$i', 'role': 'assistant', 'sequence': i, 'content': 'Transcript message $i\nPreserved conversation history.'}], 'hasMore': false};
      if (args['path'] == '/v1/commands') { final body = object(args['body']); commands.add(body); return {'id': body['id'], 'success': true}; }
    }
    return super.invoke(method, args);
  }
}

void expectBottomComposer(WidgetTester tester, double usableBottom) {
  final input = find.byType(TextField);
  final send = find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
  final inputRect = tester.getRect(input);
  final sendRect = tester.getRect(send);
  expect(input.hitTestable(), findsOneWidget);
  expect(send.hitTestable(), findsOneWidget);
  expect(inputRect.top, greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom));
  expect(inputRect.height, greaterThanOrEqualTo(48), reason: 'The editable must retain a readable touch target when the IME consumes most of a short screen.');
  expect(inputRect.bottom, lessThanOrEqualTo(usableBottom));
  expect(sendRect.bottom, lessThanOrEqualTo(usableBottom));
  expect(usableBottom - inputRect.bottom, inInclusiveRange(0, 24), reason: 'The editable row belongs at the usable bottom, not at the top of a loose flex slot.');
  expect(usableBottom - sendRect.bottom, inInclusiveRange(0, 24));
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

  for (final layout in [
    (name: 'phone', size: const Size(393, 851), scale: 1.0, keyboard: 280.0),
    (name: 'short large-text phone', size: const Size(360, 640), scale: 2.0, keyboard: 220.0),
    (name: 'short phone with tall native keyboard', size: const Size(360, 640), scale: 1.0, keyboard: 310.0),
  ]) {
    for (final withHistory in [false, true]) {
      testWidgets('${layout.name} keeps editable and send at bottom with ${withHistory ? 'long transcript and attachments' : 'empty transcript'} before and after IME', (tester) async {
        tester.view.physicalSize = layout.size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
        addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); tester.view.resetPadding(); tester.view.resetViewInsets(); });
        final native = ComposerNative(withHistory: withHistory, withAttachments: withHistory);
        final controller = projectController(native)..snapshot = Snapshot.fromJson(native.data);
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(layout.scale)), child: child!), home: SessionScreen(controller: controller, sessionId: 'session')));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(RegExp('OMP’ye mesaj')), findsOneWidget);
        expectBottomComposer(tester, layout.size.height - 24);
        final input = find.byType(TextField);
        await tester.tap(input);
        await tester.enterText(input, 'Keep my keyboard draft');
        tester.view.padding = const FakeViewPadding(top: 48);
        tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
        await tester.pumpAndSettle();
        expectBottomComposer(tester, layout.size.height - layout.keyboard);
        expect(tester.widget<EditableText>(find.descendant(of: input, matching: find.byType(EditableText))).focusNode.hasFocus, isTrue);

        if (withHistory) {
          final tools = find.byKey(const PageStorageKey('composer:session'));
          final toolScroll = find.descendant(of: tools, matching: find.byType(Scrollable)).first;
          expect(tester.state<ScrollableState>(toolScroll).position.maxScrollExtent, greaterThan(0));
          final inputBottom = tester.getRect(input).bottom;
          for (final tooltip in ['Galeriden görsel ekle', 'Kameradan görsel ekle', 'Paylaşılan görselleri ekle', 'Taslağı sil', 'Eklenen görseli kaldır', 'Dosya bağlamını kaldır', 'Çalışmayı kes']) {
            final control = find.byTooltip(tooltip).first;
            await tester.ensureVisible(control);
            await tester.pumpAndSettle();
            expect(control.hitTestable(), findsOneWidget);
            expect(tester.getRect(input).bottom, closeTo(inputBottom, 1));
          }
          final fileAction = find.widgetWithText(TextButton, 'Dosya metni ekle');
          await tester.ensureVisible(fileAction);
          await tester.pumpAndSettle();
          expect(fileAction.hitTestable(), findsOneWidget);
          expect(native.drafts['session:session:session.prompt']?['text'], 'Keep my keyboard draft');
          expect(objects(native.drafts['session:session:session.prompt']?['attachments']), hasLength(4));
          expect(objects(native.drafts['session:session:session.prompt']?['files']).single['path'], 'lib/source.dart');
        }

        await tester.enterText(input, List.generate(10, (i) => 'Draft line $i').join('\n'));
        await tester.pumpAndSettle();
        expectBottomComposer(tester, layout.size.height - layout.keyboard);
        tester.view.viewInsets = const FakeViewPadding();
        tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
        await tester.pumpAndSettle();
        expectBottomComposer(tester, layout.size.height - 24);
        tester.view.padding = const FakeViewPadding(top: 48);
        tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
        await tester.pumpAndSettle();
        expectBottomComposer(tester, layout.size.height - layout.keyboard);
        await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded));
        await tester.pumpAndSettle();
        expect(native.commands.single['sessionId'], 'session');
        expect(native.commands.single['action'], 'session.prompt');
        expect(object(native.commands.single['payload'])['message'], startsWith('Draft line 0\nDraft line 1'));
        expect(objects(object(native.commands.single['payload'])['images']), hasLength(withHistory ? 4 : 0));
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await removeScreen(tester, controller);
      });
    }
  }
}
