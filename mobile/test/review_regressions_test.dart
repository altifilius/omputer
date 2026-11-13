import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/interactions.dart';
import 'package:omputer/session.dart';
import 'package:omputer/session_controls.dart';
import 'controller_durability_test.dart' as fixture;

class PausedDraftNative extends fixture.DurableNative {
  Completer<void>? reading;
  Completer<Object?>? paused;
  @override
  Future<Object?> invoke(String method, [Json? arguments]) {
    if (method == 'draftLoad' && paused != null) {
      final reply = paused!;
      paused = null;
      reading?.complete();
      return reply.future;
    }
    return super.invoke(method, arguments);
  }
}

Json projectData({int sequence = 1, String? epoch, String summary = ''}) => {
  'sequence': sequence,
  if (epoch != null) 'journalEpoch': epoch,
  'projects': [{'id': 'project', 'name': 'Regression project', 'summary': summary}],
};

Future<OmputerController> open(fixture.DurableNative native) async {
  final controller = OmputerController(adapter: native);
  await controller.initialize();
  return controller;
}

Future<void> close(WidgetTester tester, OmputerController controller, fixture.DurableNative native) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await native.stream.close();
}

Future<void> revealCreationControl(WidgetTester tester, Finder target, {double delta = 160}) async {
  await tester.scrollUntilVisible(target, delta, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('queued decision edits cannot cross a pairing identity change', (tester) async {
    final native = PausedDraftNative()..data = {
      'sequence': 1,
      'interactions': [{'id': 'decision', 'sessionId': 'session', 'method': 'input', 'title': 'Pending input', 'status': 'pending'}],
    };
    final controller = await open(native);
    await tester.pumpWidget(MaterialApp(home: InteractionScreen(controller: controller, interactionId: 'decision')));
    await tester.pumpAndSettle();
    native.reading = Completer<void>();
    final oldRead = Completer<Object?>();
    native.paused = oldRead;
    await tester.enterText(find.byType(TextField), 'First computer answer');
    await tester.pump();
    expect(native.reading!.isCompleted, isTrue);
    await tester.enterText(find.byType(TextField), 'Private later edit for first computer');
    await controller.pair('replacement-bundle', 'Phone');
    await tester.pumpAndSettle();
    oldRead.complete(null);
    await tester.pumpAndSettle();
    expect(native.drafts[native.identity]?['decision:decision'], isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(native.requests.where((entry) => entry['method'] == 'POST'), isEmpty);
    await close(tester, controller, native);
  });

  testWidgets('new-session restoration never replaces an edit made after its read began', (tester) async {
    final native = fixture.DurableNative()..data = projectData();
    final controller = await open(native);
    native.draftPage = Completer<Object?>();
    await tester.pumpWidget(MaterialApp(home: NewSessionScreen(controller: controller, projectId: 'project')));
    await tester.pump();
    final prompt = find.byType(TextField).last;
    await tester.enterText(prompt, 'Newly typed prompt');
    native.draftPage!.complete({'name': 'Previous name', 'prompt': 'Previous prompt'});
    native.draftPage = null;
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(prompt).controller!.text, 'Newly typed prompt');
    expect((await controller.loadDraft('new:project'))!['prompt'], 'Newly typed prompt');
    await close(tester, controller, native);
  });

  for (final lostAck in [false, true]) {
    testWidgets('${lostAck ? 'unknown' : 'running'} new-session start cannot repeat and late success retires only its submitted draft', (tester) async {
      final native = fixture.DurableNative()..data = projectData()..accepted = true..loseAck = lostAck;
      final controller = await open(native);
      await tester.pumpWidget(MaterialApp(home: NewSessionScreen(controller: controller, projectId: 'project')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'One intended initial prompt');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final start = find.widgetWithText(FilledButton, 'Oturumu başlat');
      await revealCreationControl(tester, start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.byType(OperationsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await revealCreationControl(tester, start);
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      await revealCreationControl(tester, find.text('İşlem sonucunu kontrol et'), delta: -160);
      expect(find.text('Yeni oturum isteğinin sonucu bekleniyor. Aynı istek yeniden gönderilmez.'), findsOneWidget);
      expect(find.text('İşlem sonucunu kontrol et'), findsOneWidget);
      expect(find.text('Oluşturulan oturumu aç'), findsNothing);
      expect(native.requests.where((r) => r['method'] == 'POST'), hasLength(1));
      final record = native.remote.values.single;
      record['status'] = 'succeeded';
      record['result'] = {'id': record['id'], 'success': true, 'data': {'sessionId': 'created-session'}};
      await controller.reconcileOperations();
      await tester.pumpAndSettle();
      await revealCreationControl(tester, find.byKey(const ValueKey('new-session-prompt')));
      expect(await controller.loadDraft('new:project'), isNull);
      expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty);
      expect(find.text('Oluşturulan oturumu aç'), findsNothing);
      expect(find.text('İşlem sonucunu kontrol et'), findsNothing);
      await revealCreationControl(tester, start);
      expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
      expect(native.requests.where((r) => r['method'] == 'POST'), hasLength(1));
      await close(tester, controller, native);
    });
  }

  test('new-session final acknowledgment preserves later edits across controller restart', () async {
    final native = fixture.DurableNative()..data = projectData()..accepted = true;
    var controller = await open(native);
    final submitted = {'name': 'Original name', 'prompt': 'Original prompt'};
    await expectLater(controller.startSession('project', submitted), throwsA(isA<CommandAccepted>()));
    final id = '${controller.operations.single['id']}';
    final newer = {'name': 'Next session', 'prompt': 'A different unsent prompt'};
    await controller.saveDraft('new:project', newer);
    controller.dispose();
    native.remote[id]!['status'] = 'succeeded';
    native.remote[id]!['result'] = {'id': id, 'success': true, 'data': {'sessionId': 'created-session'}};
    controller = await open(native);
    await controller.reconcileOperations();
    expect(OmputerController.newSessionDraft(await controller.loadDraft('new:project')), newer);
    expect(controller.operations.single['draftEffect'], 'retained');
    expect(OmputerController.createdSessionId(controller.operations.single), 'created-session');
    expect(native.requests.where((r) => r['method'] == 'POST'), hasLength(1));
    controller.dispose();
    await native.stream.close();
  });

  test('legacy failed unknown result stays unresolved until an actual final outcome is known', () async {
    final native = fixture.DurableNative()..data = projectData();
    native.pending['legacy'] = {'id': 'legacy', 'action': 'session.prompt', 'status': 'failed', 'result': {'success': false, 'status': 'failed', 'error': {'code': 'outcome_unknown'}}};
    native.requestHandler = (request) async => {'id': 'legacy', 'action': 'session.prompt', 'status': 'unknown'};
    final controller = await open(native);
    await controller.reconcileOperations();
    expect(controller.operations.single['status'], 'unknown');
    expect(native.requests.where((r) => r['method'] == 'POST'), isEmpty);
    controller.dispose();
    await native.stream.close();
  });

  test('final update overlapping a running result schedules a fresh outcome read', () async {
    final native = fixture.DurableNative()..data = projectData()..accepted = true;
    final controller = await open(native);
    await expectLater(controller.command('session.compact', sessionId: 'session'), throwsA(isA<CommandAccepted>()));
    final id = controller.operations.single['id'] as String;
    final requested = Completer<void>();
    final oldReply = Completer<Object?>();
    var reads = 0;
    native.requestHandler = (request) {
      expect(request['path'], '/v1/commands/$id');
      reads++;
      if (reads == 1) { requested.complete(); return oldReply.future; }
      return Future.value(fixture.copy(native.remote[id]!));
    };
    final oldPage = fixture.copy(native.remote[id]!);
    final work = controller.reconcileOperations();
    await requested.future;
    native.remote[id]!['status'] = 'succeeded';
    native.stream.add({'type': 'event', 'data': {'type': 'operation.updated', 'data': {'id': id}}});
    oldReply.complete(oldPage);
    await work;
    expect(controller.operations.single['status'], 'succeeded');
    expect(reads, 2);
    controller.dispose();
    await native.stream.close();
  });

  test('authenticated changed journal epoch replaces lower watermark and fences older requests and events', () async {
    final native = fixture.DurableNative()..data = projectData(sequence: 51, epoch: 'before-restore', summary: 'Old cached summary');
    final controller = await open(native);
    final history = controller.retainTranscript('session');
    history.upsert(ChatMessage.fromJson({'id': 'obsolete', 'sequence': 40, 'content': 'Old branch'}));
    final oldPage = Completer<Object?>();
    var messageReads = 0;
    native.requestHandler = (request) async {
      if ('${request['path']}'.contains('/messages')) {
        messageReads++;
        if (messageReads == 1) return oldPage.future;
        return {'messages': [{'id': 'restored', 'sequence': 2, 'content': 'Restored history'}], 'hasMore': false};
      }
      if (request['path'] == '/v1/snapshot') return native.data;
      throw StateError('Unexpected request $request');
    };
    final inFlight = controller.loadMessages('session');
    native.data = {...projectData(sequence: 3, epoch: 'after-restore', summary: 'Restored summary'), 'interactions': [{'id': 'new-decision', 'status': 'pending'}]};
    native.stream.add({'type': 'snapshot', 'data': native.data});
    oldPage.complete({'messages': [{'id': 'late-old', 'sequence': 50, 'content': 'Must not return'}], 'hasMore': false});
    await inFlight;
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot.sequence, 3);
    expect(controller.snapshot.project('project')!.summary, 'Restored summary');
    expect(controller.snapshot.pending.single.id, 'new-decision');
    expect(history.ids, ['restored']);
    native.stream.add({'type': 'snapshot', 'data': projectData(sequence: 60, epoch: 'before-restore', summary: 'Late retired snapshot')});
    native.stream.add({'type': 'event', 'data': {'journalEpoch': 'before-restore', 'type': 'message.upsert', 'sessionId': 'session', 'data': {'id': 'retired', 'sequence': 61}}});
    expect(controller.snapshot.project('project')!.summary, 'Restored summary');
    expect(history.ids, ['restored']);
    controller.releaseTranscript('session');
    controller.dispose();
    await native.stream.close();
  });

  test('restore during an acknowledged draft read never deletes the preserved draft', () async {
    final native = PausedDraftNative()..data = projectData(epoch: 'before')..accepted = true;
    final controller = await open(native);
    await expectLater(controller.startSession('project', {'prompt': 'Keep this draft'}), throwsA(isA<CommandAccepted>()));
    final id = '${controller.operations.single['id']}';
    final saved = await controller.loadDraft('new:project');
    native.remote[id]!['status'] = 'succeeded';
    native.reading = Completer<void>();
    final reply = Completer<Object?>(); native.paused = reply;
    final result = controller.operation(id);
    await native.reading!.future;
    native.data = projectData(sequence: 0, epoch: 'restored');
    native.stream.add({'type': 'snapshot', 'data': native.data});
    reply.complete(saved);
    try { await result; } on ControllerFailure catch (failure) { expect(failure.code, 'history_changed'); }
    expect(await controller.loadDraft('new:project'), saved);
    expect(native.requests.where((entry) => entry['method'] == 'POST'), hasLength(1));
    controller.dispose(); await native.stream.close();
  });

  test('legacy submission binds to authenticated current epoch before applying a final result', () async {
    final native = fixture.DurableNative()..data = projectData(epoch: 'current')..accepted = true;
    final value = {'name': '', 'prompt': 'Already sent', '_revision': 'legacy-revision'};
    native.drafts[native.identity] = {'new:project': value};
    native.pending['legacy-submission'] = {'id': 'legacy-submission', 'action': 'session.start', 'status': 'unknown', 'identity': native.identity,
      'draftSubmission': {'key': 'new:project', 'value': value}, 'request': {'id': 'legacy-submission', 'action': 'session.start', 'payload': {'projectId': 'project', 'prompt': 'Already sent'}}};
    native.remote['legacy-submission'] = {'id': 'legacy-submission', 'action': 'session.start', 'status': 'succeeded', 'result': {'success': true, 'data': {'sessionId': 'created'}}};
    final controller = await open(native);
    await controller.reconcileOperations();
    expect(await controller.loadDraft('new:project'), isNull);
    expect(controller.operations.single['journalEpoch'], 'current');
    expect(controller.operations.single['draftEffect'], 'cleared');
    expect(native.requests.where((entry) => entry['method'] == 'POST'), isEmpty);
    controller.dispose(); await native.stream.close();
  });
}
