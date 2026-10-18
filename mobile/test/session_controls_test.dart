import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session.dart';
import 'package:omputer/session_controls.dart';

class ControlsNative implements NativeAdapter {
  final commands = <Json>[];
  final drafts = <String, Json>{};
  final persisted = <Json>[];
  Json view = {};
  final controlRequests = <Uri>[];
  Future<Object?> Function(Uri)? controlReply;
  Json catalog = {'catalogRevision': 'r1', 'journalId': 'journal', 'bindingRevision': 'binding', 'commands': [
    {'id': 'read', 'name': 'inspect', 'aliases': ['look'], 'description': 'Inspect actual state', 'source': 'builtin', 'risk': 'read', 'available': true, 'inputHint': 'Optional target'},
    {'id': 'locked', 'name': 'blocked', 'aliases': [], 'description': 'Needs idle', 'source': 'extension', 'risk': 'execute', 'available': false, 'unavailableReason': 'Working now'},
  ]};
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'operationSave') { persisted.add(object(arguments!['operation'])); return null; }
    if (method == 'draftLoad') return drafts[arguments!['key']];
    if (method == 'draftSave') { drafts['${arguments!['key']}'] = object(arguments['value']); return null; }
    if (method == 'draftDelete') { drafts.remove(arguments!['key']); return null; }
    if (method == 'draftList') return drafts;
    if (method == 'localStateSet') return {'identity': 'pc', 'sections': {}};
    if (method == 'operationList') return [];
    if (method == 'request') {
      final path = '${arguments!['path']}';
      if (path.contains('view=commands')) return catalog;
      if (path.contains('/control?')) { final uri = Uri.parse(path); controlRequests.add(uri); return controlReply == null ? view : controlReply!(uri); }
      if (path.contains('/messages')) return {'messages': [], 'hasMore': false};
      if (path == '/v1/snapshot') return snapshot;
      if (path == '/v1/commands') { commands.add(object(arguments['body'])); return {'success': true, 'id': object(arguments['body'])['id'], 'data': {}}; }
      if (path.contains('/operations')) return {'operations': [], 'hasMore': false};
      if (path.contains('/output')) return {'items': [{'sequence': 1, 'kind': 'stdout', 'text': 'Actual streamed operation output'}], 'hasMore': false};
      if (path.startsWith('/v1/commands/')) return {'id': path.split('/').last, 'action': 'session.compact', 'status': 'succeeded', 'result': {'summary': 'Actual compact result'}};
    }
    throw StateError('Unexpected $method $arguments');
  }
}
Json get snapshot => {'sequence': 1, 'projects': [{'id': 'project', 'name': 'Project'}], 'sessions': [{'id': 'session', 'projectId': 'project', 'name': 'Live', 'transport': 'rpc', 'status': 'idle', 'writerConnected': true, 'journalId': 'journal', 'bindingRevision': 'binding', 'capabilities': ['session.command', 'session.control', 'session.prompt']}]};
OmputerController makeController(ControlsNative native) => OmputerController(adapter: native)..snapshot = Snapshot.fromJson(snapshot)..connection = ConnectionState.fromJson({'paired': true, 'connected': true})..localState = {'identity': 'pc', 'sections': {}};
Future<void> close(WidgetTester tester, OmputerController c) async { await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); }

void main() {
  testWidgets('entry pages use bounded source cursors and refresh replaces without duplicates', (tester) async {
    final native = ControlsNative();
    native.controlReply = (uri) async => uri.queryParameters['offset'] == '0'
      ? {'entries': [{'id': 'first', 'type': 'message'}], 'hasMore': true, 'nextOffset': 200}
      : {'entries': [{'id': 'first', 'type': 'message'}, {'id': 'older', 'type': 'message'}], 'hasMore': false};
    final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'entries', title: 'Entries')));
    await tester.pumpAndSettle();
    expect(native.controlRequests.single.queryParameters['limit'], '200');
    await tester.tap(find.text('Sonraki kayıtları yükle')); await tester.pumpAndSettle();
    expect(native.controlRequests.last.queryParameters['offset'], '200');
    expect(find.text('message · first'), findsOneWidget); expect(find.text('message · older'), findsOneWidget);
    await tester.tap(find.byTooltip('Görünümü yenile')); await tester.pumpAndSettle();
    expect(native.controlRequests.last.queryParameters['offset'], '0');
    expect(find.text('message · older'), findsNothing);
    expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('failed and identity-stale entry pages preserve prior useful rows', (tester) async {
    final native = ControlsNative()..view = {'entries': [{'id': 'kept', 'type': 'message'}], 'hasMore': true, 'nextOffset': 200};
    final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'entries', title: 'Entries')));
    await tester.pumpAndSettle();
    native.controlReply = (_) async => throw StateError('Host ownership rejected');
    await tester.tap(find.text('Sonraki kayıtları yükle')); await tester.pumpAndSettle();
    expect(find.textContaining('Host ownership rejected'), findsOneWidget); expect(find.text('message · kept'), findsOneWidget);
    final delayed = Completer<Object?>(); native.controlReply = (_) => delayed.future;
    await tester.tap(find.text('Sonraki kayıtları yükle')); await tester.pump();
    c.localState = {'identity': 'different-pc', 'sections': {}};
    delayed.complete({'entries': [{'id': 'wrong-pc', 'type': 'message'}], 'hasMore': false});
    await tester.pumpAndSettle();
    expect(find.text('message · wrong-pc'), findsNothing); expect(find.text('message · kept'), findsOneWidget);
    await close(tester, c);
  });
  testWidgets('child history appends distinct rows by byte cursor and reset replaces', (tester) async {
    final native = ControlsNative(); var reset = false;
    native.controlReply = (uri) async => uri.queryParameters['fromByte'] == '0'
      ? {'sessionFile': '/owned/child.jsonl', 'messages': [{'id': 'a', 'role': 'assistant', 'content': 'First child answer'}], 'nextByte': 100, 'hasMore': true}
      : reset
        ? {'sessionFile': '/owned/child.jsonl', 'messages': [{'id': 'c', 'role': 'assistant', 'content': 'Reset child answer'}], 'reset': true, 'nextByte': 50, 'hasMore': false}
        : {'sessionFile': '/owned/child.jsonl', 'messages': [{'id': 'a', 'role': 'assistant', 'content': 'First child answer'}, {'id': 'b', 'role': 'assistant', 'content': 'Second child answer'}], 'nextByte': 200, 'hasMore': true};
    final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'agentMessages', title: 'Child', arguments: {'agentId': 'owned-child'})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonraki ajan mesajlarını yükle')); await tester.pumpAndSettle();
    expect(native.controlRequests.last.queryParameters['fromByte'], '100'); expect(native.controlRequests.last.queryParameters['agentId'], 'owned-child');
    expect(find.text('First child answer'), findsOneWidget); expect(find.text('Second child answer'), findsOneWidget);
    reset = true;
    await tester.ensureVisible(find.text('Sonraki ajan mesajlarını yükle')); await tester.tap(find.text('Sonraki ajan mesajlarını yükle')); await tester.pumpAndSettle();
    expect(native.controlRequests.last.queryParameters['fromByte'], '200');
    expect(find.text('First child answer'), findsNothing); expect(find.text('Reset child answer'), findsOneWidget);
    expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('child rows without IDs append by cursor and ownership denial remains visible', (tester) async {
    final native = ControlsNative(); var denied = false;
    native.controlReply = (uri) async {
      if (denied) throw ControllerFailure('Agent does not belong to this session', 'forbidden');
      final first = uri.queryParameters['fromByte'] == '0';
      return {'sessionFile': '/owned/child.jsonl', 'messages': [{'role': 'assistant', 'content': first ? 'Cursor first answer' : 'Cursor next answer'}], 'nextByte': first ? 40 : 80, 'hasMore': true};
    };
    final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'agentMessages', title: 'Child', arguments: {'agentId': 'target-child'})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonraki ajan mesajlarını yükle')); await tester.pumpAndSettle();
    expect(find.text('Cursor first answer'), findsOneWidget); expect(find.text('Cursor next answer'), findsOneWidget);
    denied = true;
    await tester.ensureVisible(find.text('Sonraki ajan mesajlarını yükle')); await tester.tap(find.text('Sonraki ajan mesajlarını yükle')); await tester.pumpAndSettle();
    expect(find.textContaining('Agent does not belong'), findsOneWidget);
    expect(find.text('Cursor first answer'), findsOneWidget); expect(find.text('Cursor next answer'), findsOneWidget);
    expect(native.controlRequests.every((uri) => uri.queryParameters['agentId'] == 'target-child'), isTrue);
    denied = false;
    await tester.tap(find.byTooltip('Görünümü yenile')); await tester.pumpAndSettle();
    expect(native.controlRequests.last.queryParameters['fromByte'], '0'); expect(find.text('Cursor next answer'), findsNothing);
    expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('palette filters aliases and explicitly executes revision-bound command', (tester) async {
    final native = ControlsNative(); final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: CommandPalette(controller: c, sessionId: 'session', onLocal: (_) async {})));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'look'); await tester.pump();
    expect(find.text('/inspect'), findsOneWidget); expect(find.text('/blocked'), findsNothing);
    await tester.tap(find.text('/inspect')); await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'target');
    expect(native.commands, isEmpty);
    await tester.tap(find.text('/inspect çalıştır')); await tester.pumpAndSettle();
    expect(native.commands.single['action'], 'session.command');
    final payload = object(native.commands.single['payload']);
    expect(payload['commandId'], 'read'); expect(payload['catalogRevision'], 'r1'); expect(payload['args'], 'target'); expect(payload['expectedJournalId'], 'journal');
    await close(tester, c);
  });
  testWidgets('disabled command shows reason and cannot be sent', (tester) async {
    final native = ControlsNative(); final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: CommandPalette(controller: c, sessionId: 'session', onLocal: (_) async {})));
    await tester.pumpAndSettle(); await tester.tap(find.text('/blocked')); await tester.pump();
    expect(find.textContaining('Working now'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '/blocked çalıştır')).onPressed, isNull);
    expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('typing initial slash discovers commands without submitting unknown input', (tester) async {
    final native = ControlsNative(); final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: c, sessionId: 'session'))); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/not-a-command'); await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget); expect(native.commands, isEmpty);
    expect(find.textContaining('Bilinmeyen /'), findsOneWidget);
    await tester.pageBack(); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '/not-a-command');
    expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('composer process restoration uses identity-scoped native draft', (tester) async {
    final native = ControlsNative()..drafts['session:session:session.prompt'] = {'text': 'Saved unsent text', 'attachments': []}; final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: c, sessionId: 'session'))); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Saved unsent text');
    await tester.enterText(find.byType(TextField), 'Changed draft'); await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: c, sessionId: 'session'))); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Changed draft'); expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('restored slash draft does not open a palette and typed command arguments survive discovery', (tester) async {
    final native = ControlsNative()..drafts['session:session:session.prompt'] = {'text': '/inspect saved', 'attachments': [], 'files': []};
    final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: c, sessionId: 'session'))); await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
    await tester.enterText(find.byType(TextField), 'ordinary text'); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/inspect target with spaces'); await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget);
    await tester.tap(find.text('/inspect')); await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'target with spaces');
    expect(native.commands, isEmpty);
    await close(tester, c);
  });
  testWidgets('plan approval binds exactly the reviewed revision', (tester) async {
    final native = ControlsNative()..view = {'state': {'active': true}, 'review': {'title': 'Reviewed plan', 'planContent': 'Do the real work', 'revision': 'sha-reviewed'}}; final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'plan', title: 'Plan'))); await tester.pumpAndSettle();
    final approve = find.text('Planı onayla ve uygula'); await tester.ensureVisible(approve); await tester.tap(approve); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Onayla')); await tester.pumpAndSettle();
    final payload = object(native.commands.single['payload']); expect(payload['control'], 'plan.approve'); expect(object(payload['arguments'])['revision'], 'sha-reviewed'); expect(payload['confirmed'], true); await close(tester, c);
  });
  testWidgets('queue promotion uses actual host message instead of invented row id', (tester) async {
    final native = ControlsNative()..view = {'steering': ['Real queued text'], 'followUp': []}; final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'queue', title: 'Queue'))); await tester.pumpAndSettle();
    await tester.tap(find.text('Öne al')); await tester.pumpAndSettle();
    final payload = object(native.commands.single['payload']); expect(payload['control'], 'queue.promote'); expect(object(payload['arguments']), {'message': 'Real queued text'}); await close(tester, c);
  });
  testWidgets('tree details stay selectable when an expanded entry is collapsed and reopened', (tester) async {
    final native = ControlsNative()..view = {'entries': [{'id': 'source', 'type': 'message', 'text': 'Actual selected tree entry'}]};
    final c = makeController(native);
    await tester.pumpWidget(MaterialApp(home: SessionControlScreen(controller: c, sessionId: 'session', view: 'entries', title: 'Entries'))); await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('message · source')); await tester.pumpAndSettle();
      expect(find.byKey(const PageStorageKey('detail:entry:source')), findsOneWidget);
      expect(find.text('Buradan dal aç'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('message · source')); await tester.pumpAndSettle();
    }
    expect(native.commands, isEmpty); await close(tester, c);
  });
  testWidgets('operation result and streamed output keep separate selection storage on reopen', (tester) async {
    final native = ControlsNative(); final c = makeController(native);
    const operation = <String, dynamic>{'id': 'operation-one', 'action': 'session.compact', 'status': 'succeeded', 'result': {'summary': 'Actual compact result'}};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [OperationOutput(controller: c, operation: operation)])))); await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('session.compact · succeeded')); await tester.pumpAndSettle();
      expect(find.byKey(const PageStorageKey('operation:operation-one:result')), findsOneWidget);
      expect(find.byKey(const PageStorageKey('operation:operation-one:output:1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('session.compact · succeeded')); await tester.pumpAndSettle();
    }
    await close(tester, c);
  });
}
