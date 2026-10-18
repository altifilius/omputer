import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session.dart';
import 'package:omputer/session_controls.dart';
import 'controller_durability_test.dart' as fixture;

const promptKey = 'session:session:session.prompt';
const importedId = 'e20c4db4-cbbe-49cf-b69e-ed8a4d2b8879';
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
Json image({bool imported = false}) => {'type': 'image', if (imported) 'id': importedId, 'mimeType': 'image/png', 'data': png, 'bytes': 68};
Json draft(String text, {List<Json> images = const [], List<Json> files = const []}) => {'text': text, 'attachments': images, 'files': files};

class DraftNative extends fixture.DurableNative {
  DraftNative() {
    data = {'sequence': 1, 'projects': [{'id': 'project', 'name': 'Project'}], 'sessions': [{...fixture.liveSession(), 'projectId': 'project', 'name': 'Live', 'capabilities': ['session.prompt', 'session.steer', 'session.follow_up', 'session.control', 'session.command']}]};
    requestHandler = (request) async {
      final path = '${request['path']}';
      if (path == '/v1/snapshot') return data;
      if (path.contains('/messages')) return {'messages': [], 'hasMore': false};
      if (path.contains('/control?')) return {'leafId': 'source', 'tree': [{'entry': {'id': 'source', 'type': 'message'}, 'children': []}]};
      if (path.contains('/operations?')) return {'operations': remote.values.map(fixture.copy).toList(), 'hasMore': false};
      if (path.contains('/output?')) return {'items': [], 'hasMore': false};
      if (path == '/v1/commands') {
        final body = object(request['body']);
        final id = '${body['id']}';
        expectSync(pending[id]?['request'], body, reason: 'Persist exact UUID and request before the one POST');
        final branch = object(body['payload'])['control'] == 'branch';
        final result = {'id': id, 'success': !reject, if (reject) 'error': {'code': 'stale_identity', 'message': 'Session changed'}, 'data': branch ? branchResult : <String, dynamic>{}};
        remote[id] = {'id': id, 'sessionId': body['sessionId'], 'action': body['action'], 'status': reject ? 'failed' : accepted ? 'running' : 'succeeded', 'result': result};
        if (loseAck) throw PlatformException(code: 'timeout', message: 'Lost acknowledgement');
        return accepted ? {'id': id, 'success': true, 'accepted': true, 'status': 'running'} : result;
      }
      if (path.startsWith('/v1/commands/')) {
        final id = path.split('/').last;
        if (!remote.containsKey(id)) throw PlatformException(code: 'not_found');
        return fixture.copy(remote[id]!);
      }
      throw StateError('Unexpected request $request');
    };
  }
  Json branchResult = {'selectedText': 'Original selected prompt', 'selectedImages': [image()], 'cancelled': false, 'journalId': 'branched-journal', 'bindingRevision': 'binding', 'sessionFile': '/actual/branch.jsonl', 'leafId': 'branch-leaf'};
  final removed = <String>[];
  bool reject = false, failDraft = false;
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'draftSave' && failDraft) throw PlatformException(code: 'storage_failed', message: 'Draft storage full');
    if (method == 'removeAttachment') removed.add('${arguments!['id']}');
    return super.invoke(method, arguments);
  }
  Map<String, Json> get saved => drafts[identity] ?? <String, Json>{};
  void succeed() { remote.values.single['status'] = 'succeeded'; }
  int get posts => requests.where((request) => request['method'] == 'POST').length;
}

Future<OmputerController> open(DraftNative native) async {
  final controller = OmputerController(adapter: native);
  await controller.initialize();
  return controller;
}
Future<void> close(OmputerController controller, DraftNative native) async { controller.dispose(); await native.stream.close(); }
Future<void> submit(OmputerController controller, Json value, {String mode = 'session.prompt'}) => controller.submitDraft('session', mode, value, {'message': value['text'], if (objects(value['attachments']).isNotEmpty) 'images': objects(value['attachments'])}).then((_) {});
Future<void> branch(OmputerController controller) => controller.control('session', 'branch', arguments: {'entryId': 'source'}, confirmed: true).then((_) {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('successful branch restores prepared text and images on the same visible session once', () async {
    final native = DraftNative(); final controller = await open(native);
    await branch(controller);
    final restored = await controller.loadDraft(promptKey);
    expect(restored?['text'], 'Original selected prompt');
    expect(objects(restored?['attachments']).single['data'], png);
    expect(objects(restored?['attachments']).single.containsKey('id'), isFalse);
    expect(controller.snapshot.sessions.single.id, 'session');
    expect(native.saved.keys, [promptKey]);
    await controller.saveDraft(promptKey, draft('Edited after restore'));
    await controller.operation('${controller.operations.single['id']}');
    expect((await controller.loadDraft(promptKey))?['text'], 'Edited after restore');
    expect(native.posts, 1);
    await close(controller, native);
  });

  for (final outcome in ['cancelled', 'failed', 'stale']) {
    test('$outcome branch never changes an unsent prompt', () async {
      final native = DraftNative(); final controller = await open(native);
      await controller.saveDraft(promptKey, draft('Keep this unsent text', images: [image(imported: true)]));
      final before = await controller.loadDraft(promptKey);
      if (outcome == 'cancelled') native.branchResult['cancelled'] = true;
      if (outcome == 'failed') native.reject = true;
      if (outcome == 'stale') {
        native.accepted = true;
        await expectLater(branch(controller), throwsA(isA<CommandAccepted>()));
        native.succeed();
        controller.snapshot = Snapshot.fromJson({'sequence': 3, 'sessions': [fixture.liveSession(journal: 'other-journal', binding: 'other-binding')]});
        await controller.reconcileOperations();
      } else if (outcome == 'failed') {
        await expectLater(branch(controller), throwsA(isA<ControllerFailure>()));
      } else { await branch(controller); }
      expect(await controller.loadDraft(promptKey), before);
      expect(native.removed, isEmpty);
      expect(controller.pendingBranchDrafts('session'), isEmpty);
      await close(controller, native);
    });
  }

  test('existing unsent branch conflict preserves both until explicit reviewed replacement', () async {
    final native = DraftNative(); final controller = await open(native);
    await controller.saveDraft(promptKey, draft('My unrelated draft', images: [image(imported: true)]));
    await branch(controller);
    final operation = controller.pendingBranchDrafts('session').single;
    expect((await controller.loadDraft(promptKey))?['text'], 'My unrelated draft');
    expect((await controller.loadDraft('${operation['branchDraftKey']}'))?['text'], 'Original selected prompt');
    final reviewed = await controller.loadDraft(promptKey);
    await controller.saveDraft(promptKey, draft('Changed during review'));
    await expectLater(controller.restoreBranchDraft('${operation['id']}', expected: reviewed), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'draft_changed')));
    expect((await controller.loadDraft(promptKey))?['text'], 'Changed during review');
    await controller.restoreBranchDraft('${operation['id']}', expected: await controller.loadDraft(promptKey));
    expect((await controller.loadDraft(promptKey))?['text'], 'Original selected prompt');
    expect(controller.pendingBranchDrafts('session'), isEmpty);
    expect(native.posts, 1);
    await close(controller, native);
  });

  for (final lost in [false, true]) {
    test('${lost ? 'unknown' : 'running'} branch completing after relaunch waits for review without replacing newer edits', () async {
      final native = DraftNative()..accepted = !lost..loseAck = lost;
      final first = await open(native);
      await expectLater(branch(first), throwsA(lost ? isA<CommandUncertain>() : isA<CommandAccepted>()));
      expect(await first.loadDraft(promptKey), isNull);
      await first.saveDraft(promptKey, draft('New prompt after acceptance'));
      first.dispose(); native.succeed();
      final restored = await open(native);
      expect((await restored.loadDraft(promptKey))?['text'], 'New prompt after acceptance');
      final operation = restored.pendingBranchDrafts('session').single;
      expect((await restored.loadDraft('${operation['branchDraftKey']}'))?['text'], 'Original selected prompt');
      await restored.operation('${operation['id']}');
      expect((await restored.loadDraft(promptKey))?['text'], 'New prompt after acceptance');
      expect(native.posts, 1);
      await close(restored, native);
    });
  }

  for (final lost in [false, true]) {
    test('${lost ? 'unknown' : 'running'} ACK retains exact draft until final succeeds after relaunch', () async {
      final native = DraftNative()..accepted = !lost..loseAck = lost;
      final first = await open(native);
      final value = draft('Submitted exact prompt', images: [image(imported: true)], files: [{'path': 'lib/source.dart', 'text': 'selected source', 'truncated': false}]);
      await expectLater(submit(first, value), throwsA(lost ? isA<CommandUncertain>() : isA<CommandAccepted>()));
      expect((await first.loadDraft(promptKey))?['text'], 'Submitted exact prompt');
      expect(native.removed, isEmpty);
      await expectLater(submit(first, value), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'submission_pending')));
      first.dispose(); native.succeed();
      final restored = await open(native);
      expect(await restored.loadDraft(promptKey), isNull);
      expect(native.removed, [importedId]);
      expect(native.posts, 1);
      await close(restored, native);
    });
  }

  for (final changed in ['text', 'images', 'files', 'same-content-new-revision', 'mode']) {
    test('$changed edits survive late success with the original UUID after relaunch', () async {
      final native = DraftNative()..accepted = true;
      final first = await open(native);
      final original = draft('Submitted', images: [image(imported: true)], files: [{'path': 'a', 'text': 'before'}]);
      await expectLater(submit(first, original), throwsA(isA<CommandAccepted>()));
      final newer = draft(changed == 'text' ? 'New text' : 'Submitted', images: changed == 'images' ? [image()] : [image(imported: true)], files: [{'path': 'a', 'text': changed == 'files' ? 'new file text' : 'before'}]);
      final key = changed == 'mode' ? 'session:session:session.steer' : promptKey;
      await first.saveDraft(key, newer);
      final expected = await first.loadDraft(key);
      first.dispose(); native.succeed();
      final restored = await open(native);
      expect(await restored.loadDraft(key), expected);
      await restored.operation('${restored.operations.single['id']}');
      expect(await restored.loadDraft(key), expected);
      if (changed == 'mode') expect(await restored.loadDraft(promptKey), isNull);
      expect(native.posts, 1);
      await close(restored, native);
    });
  }

  test('successful ACK frees imported resources only after the last unsent reference is removed', () async {
    final native = DraftNative(); final controller = await open(native);
    const other = 'session:other:session.follow_up';
    await controller.saveDraft(other, draft('Unsent elsewhere', images: [image(imported: true)]));
    await submit(controller, draft('Send here', images: [image(imported: true)]));
    expect(await controller.loadDraft(promptKey), isNull);
    expect(native.removed, isEmpty);
    expect(objects((await controller.loadDraft(other))?['attachments']).single['data'], png);
    await controller.deleteDraft(other);
    expect(native.removed, [importedId]);
    await branch(controller);
    await controller.deleteDraft(promptKey);
    expect(native.removed, [importedId], reason: 'Host-returned image data has no imported native id');
    await close(controller, native);
  });

  test('failed live turn still submits and clears only the acknowledged prompt draft', () async {
    final native = DraftNative();
    final session = {...fixture.liveSession(), 'status': 'failed', 'turnError': 'Previous provider failed'};
    native.data = {'sequence': 2, 'sessions': [session]};
    final controller = await open(native);
    await submit(controller, draft('Continue after the failed turn'));
    expect(controller.snapshot.session('session')!.canSendMessages, isTrue);
    expect(await controller.loadDraft(promptKey), isNull);
    expect(object(object(native.requests.firstWhere((request) => request['method'] == 'POST')['body'])['payload'])['message'], 'Continue after the failed turn');
    expect(native.posts, 1);
    await close(controller, native);
  });

  test('same journal but different binding is stale and cannot restore a replayed branch', () async {
    final native = DraftNative()..accepted = true; final controller = await open(native);
    await expectLater(branch(controller), throwsA(isA<CommandAccepted>()));
    native.succeed();
    controller.snapshot = Snapshot.fromJson({'sequence': 3, 'sessions': [fixture.liveSession(journal: 'branched-journal', binding: 'later-binding')]});
    await controller.reconcileOperations();
    expect(await controller.loadDraft(promptKey), isNull);
    expect(controller.operations.single['draftEffect'], 'stale');
    expect(controller.pendingBranchDrafts('session'), isEmpty);
    await close(controller, native);
  });

  test('final recorded success with interrupted draft cleanup is recovered on process start', () async {
    final native = DraftNative()..accepted = true; final first = await open(native);
    await expectLater(submit(first, draft('Accepted earlier', images: [image(imported: true)])), throwsA(isA<CommandAccepted>()));
    final id = '${first.operations.single['id']}';
    native.pending[id]!['status'] = 'succeeded';
    native.pending[id]!['result'] = {'success': true, 'id': id};
    first.dispose();
    final restored = await open(native);
    expect(await restored.loadDraft(promptKey), isNull);
    expect(restored.operations.single['draftEffect'], 'cleared');
    expect(native.removed, [importedId]);
    expect(native.posts, 1);
    await close(restored, native);
  });

  test('image preparation bounds actual count, decoded bytes and encoded content without native ids', () async {
    final native = DraftNative(); final controller = await open(native);
    final prepared = await controller.prepareImages([image()]);
    expect(prepared.single['width'], 1); expect(prepared.single['height'], 1);
    expect(prepared.single['bytes'], greaterThan(0)); expect(prepared.single.containsKey('id'), isFalse);
    await expectLater(controller.prepareImages(List.generate(9, (_) => image())), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'image_limit')));
    await expectLater(controller.prepareImages([{'mimeType': 'image/png', 'data': 'A' * 1398108}]), throwsA(isA<ControllerFailure>()));
    await expectLater(controller.prepareImages([{'mimeType': 'image/svg+xml', 'data': png}]), throwsA(isA<ControllerFailure>()));
    await expectLater(controller.prepareImages([{'mimeType': 'image/png', 'data': 'aGVsbG8='}]), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'invalid_image')));
    expect(native.removed, isEmpty);
    await close(controller, native);
  });

  test('preparation and storage failures preserve the current draft and surface actual error', () async {
    final native = DraftNative(); final controller = await open(native);
    await controller.saveDraft(promptKey, draft('Do not lose this draft'));
    native.branchResult['selectedImages'] = [{'mimeType': 'image/png', 'data': 'not base64'}];
    await expectLater(branch(controller), throwsA(isA<CommandUncertain>()));
    expect((await controller.loadDraft(promptKey))?['text'], 'Do not lose this draft');
    expect(controller.pendingBranchDrafts('session'), isEmpty);
    native.branchResult['selectedImages'] = [image()];
    native.failDraft = true;
    await expectLater(branch(controller), throwsA(isA<CommandUncertain>()));
    expect((await controller.loadDraft(promptKey))?['text'], 'Do not lose this draft');
    expect(native.posts, 2);
    await close(controller, native);
  });

  testWidgets('tree branch returns text and image into the exact mounted composer, not another session', (tester) async {
    final native = DraftNative(); final controller = await open(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session'))); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Oturum kontrolleri')); await tester.pumpAndSettle();
    await tester.tap(find.text('Konuşma ağacı')); await tester.pumpAndSettle();
    await tester.tap(find.text('message · source')); await tester.pumpAndSettle();
    final branchButton = find.text('Buradan dal aç'); await tester.ensureVisible(branchButton); await tester.tap(branchButton); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Onayla')); await tester.pumpAndSettle();
    expect(find.byType(SessionControlScreen), findsNothing);
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'session');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Original selected prompt');
    expect(find.byTooltip('Eklenen görseli kaldır'), findsOneWidget);
    expect(native.saved[promptKey]?['text'], 'Original selected prompt');
    await tester.enterText(find.byType(TextField), 'Typed after restore'); await tester.pumpAndSettle();
    await controller.operation('${controller.operations.single['id']}'); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Typed after restore');
    await tester.pumpWidget(const SizedBox.shrink()); await close(controller, native);
  });

  testWidgets('restored prompt draft does not reset an active steer composer with unrelated typed text', (tester) async {
    final native = DraftNative(); final controller = await open(native);
    await controller.updateLocalState('lastMode', 'session:session', 'session.steer');
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session'))); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep my steering edit'); await tester.pumpAndSettle();
    final restoring = branch(controller); await tester.pumpAndSettle(); await restoring; await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep my steering edit');
    expect((await controller.loadDraft(promptKey))?['text'], 'Original selected prompt');
    expect((await controller.loadDraft('session:session:session.steer'))?['text'], 'Keep my steering edit');
    expect(controller.snapshot.sessions.single.id, 'session');
    await tester.pumpWidget(const SizedBox.shrink()); await close(controller, native);
  });

  testWidgets('mounted composer clears final ACK snapshot but keeps later typing and unrelated mode', (tester) async {
    final native = DraftNative()..accepted = true; final controller = await open(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session'))); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Submitted'); await tester.pumpAndSettle();
    await expectLater(submit(controller, draft('Submitted')), throwsA(isA<CommandAccepted>()));
    native.succeed(); await controller.reconcileOperations(); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.enterText(find.byType(TextField), 'New unsent edit'); await tester.pumpAndSettle();
    await controller.operation('${controller.operations.single['id']}'); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'New unsent edit');
    await tester.pumpWidget(const SizedBox.shrink()); await close(controller, native);
  });

  testWidgets('late branch is discoverable and explicit keep-both never resets typed edits', (tester) async {
    final native = DraftNative()..accepted = true; final controller = await open(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session'))); await tester.pumpAndSettle();
    await expectLater(branch(controller), throwsA(isA<CommandAccepted>()));
    await tester.enterText(find.byType(TextField), 'Typed while branch ran'); await tester.pumpAndSettle();
    native.succeed(); final reconciling = controller.reconcileOperations(); await tester.pumpAndSettle(); await reconciling; await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Typed while branch ran');
    final review = find.text('İncele'); await tester.ensureVisible(review); await tester.tap(review); await tester.pumpAndSettle();
    expect(find.text('Dal istemini geri yükle'), findsOneWidget);
    expect(find.text('Original selected prompt'), findsOneWidget);
    await tester.tap(find.text('İkisini de koru')); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Typed while branch ran');
    expect(controller.pendingBranchDrafts('session'), hasLength(1));
    await tester.ensureVisible(find.text('İncele')); await tester.tap(find.text('İncele')); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'İstemi geri yükle')); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Original selected prompt');
    expect(find.byTooltip('Eklenen görseli kaldır'), findsOneWidget);
    expect(native.posts, 1);
    await tester.pumpWidget(const SizedBox.shrink()); await close(controller, native);
  });
  testWidgets('branch review and composer remain scrollable at 200 percent with a visible keyboard', (tester) async {
    tester.view.physicalSize = const Size(800, 600); tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); tester.view.resetViewInsets(); });
    final native = DraftNative()..accepted = true; final controller = await open(native);
    await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!), home: SessionScreen(controller: controller, sessionId: 'session'))); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep typed keyboard draft'); await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 180); await tester.pumpAndSettle();
    await expectLater(branch(controller), throwsA(isA<CommandAccepted>()));
    native.succeed(); final reconciling = controller.reconcileOperations(); await tester.pumpAndSettle(); await reconciling; await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final composer = find.byKey(const PageStorageKey('composer:session'));
    final composerRect = tester.getRect(composer);
    expect(composerRect.height, greaterThan(0)); expect(composerRect.bottom, lessThanOrEqualTo(420));
    final review = find.text('İncele'); await tester.ensureVisible(review); await tester.pumpAndSettle();
    expect(review.hitTestable(), findsOneWidget);
    await tester.tap(review); await tester.pumpAndSettle();
    expect(find.text('Original selected prompt'), findsOneWidget);
    await tester.tap(find.text('İkisini de koru')); await tester.pumpAndSettle();
    await tester.ensureVisible(review); await tester.pumpAndSettle();
    expect(review.hitTestable(), findsOneWidget); expect(tester.takeException(), isNull);
    await tester.tap(review); await tester.pumpAndSettle();
    await tester.tap(find.text('İkisini de koru')); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField)); await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep typed keyboard draft');
    expect(native.posts, 1); expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink()); await close(controller, native);
  });
}
