import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';

Json copy(Json value) => object(jsonDecode(jsonEncode(value)));

class DurableNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final pending = <String, Json>{};
  final remote = <String, Json>{};
  final drafts = <String, Map<String, Json>>{};
  final sections = <String, Json>{};
  final calls = <String>[];
  final requests = <Json>[];
  String identity = 'first:phone';
  bool loseAck = false, accepted = false, failSave = false;
  Completer<Object?>? draftPage;
  Future<Object?> Function(Json)? requestHandler;
  Json data = {'sequence': 1};
  @override
  Stream<Object?> get events => stream.stream;
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    calls.add(method);
    switch (method) {
      case 'connection':
      case 'connect': return {'paired': true, 'connected': true, 'identity': identity};
      case 'snapshot': return data;
      case 'preferences': return {'theme': 'system'};
      case 'localState': return {'identity': identity, 'sections': sections[identity] ?? {}};
      case 'localStateSet':
        final state = sections.putIfAbsent(identity, () => {});
        final section = state.putIfAbsent(arguments!['section'] as String, () => <String, dynamic>{}) as Json;
        section[arguments['key'] as String] = arguments['value'];
        return {'identity': identity, 'sections': copy(state)};
      case 'draftSave':
        drafts.putIfAbsent(identity, () => {})[arguments!['key'] as String] = copy(object(arguments['value']));
        return null;
      case 'draftLoad': return draftPage?.future ?? drafts[identity]?[arguments!['key']];
      case 'draftList': return drafts[identity] ?? <String, Json>{};
      case 'draftDelete': drafts[identity]?.remove(arguments!['key']); return null;
      case 'operationSave':
        if (failSave) throw PlatformException(code: 'storage_failed', message: 'Disk full');
        final value = copy(object(arguments!['operation']));
        if (value['request'] != null) expectSync(value['id'], object(value['request'])['id']);
        pending[value['id'] as String] = value;
        return null;
      case 'operationList': return pending.values.map(copy).toList();
      case 'pair': identity = 'second:phone'; pending.clear(); return {};
      case 'pickImages': return [{'id': 'e20c4db4-cbbe-49cf-b69e-ed8a4d2b8879', 'mimeType': 'image/png', 'data': 'aGVsbG8=', 'bytes': 5, 'width': 1, 'height': 1}];
      case 'sharedImages': return [];
      case 'removeAttachment': return null;
      case 'request':
        requests.add(copy(arguments!));
        if (requestHandler != null) return requestHandler!(arguments);
        final path = arguments['path'] as String;
        if (path == '/v1/snapshot') return data;
        if (path == '/v1/commands') {
          final body = object(arguments['body']);
          final id = body['id'] as String;
          expectSync(pending[id]?['request'], body, reason: 'UUID and exact request are durable before dispatch');
          remote[id] = {'id': id, 'action': body['action'], 'sessionId': body['sessionId'], 'status': accepted ? 'running' : 'succeeded', 'result': {'id': id, 'success': true, 'data': {'value': 42}}};
          if (loseAck) throw PlatformException(code: 'timeout', message: 'Lost acknowledgement');
          return accepted ? {'id': id, 'success': true, 'accepted': true, 'status': 'running'} : remote[id]!['result'];
        }
        if (path.startsWith('/v1/commands/')) {
          final id = path.split('/').last;
          if (!remote.containsKey(id)) throw PlatformException(code: 'not_found');
          return copy(remote[id]!);
        }
        if (path.contains('/messages')) return {'messages': [], 'hasMore': false};
        throw StateError('Unexpected request $arguments');
    }
    throw StateError('Unexpected native method $method');
  }
}

Json liveSession({String journal = 'journal', String binding = 'binding'}) => {
  'id': 'session', 'transport': 'bridge', 'status': 'idle', 'writerConnected': true,
  'journalId': journal, 'providerSessionId': 'provider', 'bindingRevision': binding,
  'capabilities': ['session.command', 'session.control', 'session.prompt'],
};

void main() {
  test('lost ACK retains original UUID and relaunch reconciles GET without replay', () async {
    final native = DurableNative()..loseAck = true;
    final first = OmputerController(adapter: native);
    await first.initialize();
    await expectLater(first.command('session.bash', sessionId: 'session', payload: {'command': 'rm /explicit-user-target'}), throwsA(isA<CommandUncertain>()));
    final saved = native.pending.values.single;
    final id = saved['id'] as String;
    expect(saved['status'], 'unknown');
    expect(object(saved['request'])['payload'], {'command': 'rm /explicit-user-target'});
    first.dispose();
    final second = OmputerController(adapter: native);
    await second.initialize();
    expect(second.operations.single['id'], id);
    expect(second.operations.single['status'], 'succeeded');
    expect(native.requests.where((request) => request['method'] == 'POST'), hasLength(1));
    expect(native.requests.last['path'], '/v1/commands/$id');
    second.dispose();
    await native.stream.close();
  });

  test('server outcome_unknown response remains uncertain rather than failed and cannot authorize replay', () async {
    final native = DurableNative();
    native.requestHandler = (request) async {
      final body = object(request['body']);
      return {'id': body['id'], 'status': 'unknown', 'success': false, 'error': {'code': 'outcome_unknown', 'message': 'Server restarted before command outcome was recorded'}};
    };
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await expectLater(controller.command('session.bash', sessionId: 'session', payload: {'command': 'one-shot'}), throwsA(isA<CommandUncertain>()));
    expect(controller.operations.single['status'], 'unknown');
    expect(native.pending.values.single['status'], 'unknown');
    expect(native.requests.where((request) => request['method'] == 'POST'), hasLength(1));
    controller.dispose();
    await native.stream.close();
  });

  test('unknown UUID missing on server remains unknown and never resubmits', () async {
    final native = DurableNative()..loseAck = true;
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await expectLater(controller.command('session.bash', payload: {'command': 'one-shot'}), throwsA(isA<CommandUncertain>()));
    native.remote.clear();
    await controller.reconcileOperations();
    await controller.reconcileOperations();
    expect(controller.operations.single['status'], 'unknown');
    expect(native.requests.where((request) => request['method'] == 'POST'), hasLength(1));
    controller.dispose();
    await native.stream.close();
  });

  test('failed native durability prevents even the first POST', () async {
    final native = DurableNative()..failSave = true;
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await expectLater(controller.command('session.bash', payload: {'command': 'one-shot'}), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'storage_failed')));
    expect(native.requests, isEmpty);
    expect(controller.operations, isEmpty);
    controller.dispose();
    await native.stream.close();
  });

  test('running ACK is explicit acceptance rather than successful completion', () async {
    final native = DurableNative()..accepted = true;
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await expectLater(controller.command('session.compact', sessionId: 'session'), throwsA(isA<CommandAccepted>().having((e) => e.operation['status'], 'status', 'running')));
    expect(controller.operationsFor('session').single['status'], 'running');
    final id = controller.operations.single['id'] as String;
    native.remote[id]!['status'] = 'succeeded';
    await controller.reconcileOperations();
    expect(controller.operations.single['status'], 'succeeded');
    native.remote[id]!['status'] = 'running';
    await controller.operation(id);
    expect(controller.operations.single['status'], 'succeeded', reason: 'Late server/cache state cannot reopen a final operation');
    controller.dispose();
    await native.stream.close();
  });

  test('accepted interaction is restored from durable operation across late snapshots', () async {
    final native = DurableNative()..data = {'sequence': 2, 'interactions': [{'id': 'decision', 'status': 'pending', 'sessionId': 'session'}]};
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.respond(controller.snapshot.interaction('decision')!, {'selectedOptions': <String>[]});
    native.stream.add({'type': 'snapshot', 'data': {'sequence': 3, 'interactions': [{'id': 'decision', 'status': 'resolved'}]}});
    native.stream.add({'type': 'snapshot', 'data': {'sequence': 4, 'interactions': [{'id': 'decision', 'status': 'pending'}]}});
    expect(controller.snapshot.interaction('decision')!.status, 'resolved');
    expect(controller.snapshot.interaction('decision')!.response, {'selectedOptions': <String>[]});
    controller.dispose();
    final restored = OmputerController(adapter: native);
    await restored.initialize();
    expect(restored.snapshot.interaction('decision')!.status, 'resolved');
    expect(restored.snapshot.interaction('decision')!.response, {'selectedOptions': <String>[]});
    restored.dispose();
    await native.stream.close();
  });

  test('drafts and metadata are scoped by paired identity and stale loads are fenced', () async {
    final native = DurableNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.saveDraft('session:same:prompt', {'text': 'First PC secret', 'attachments': ['image']});
    await controller.updateLocalState('pins', 'same', true);
    final oldLoad = Completer<Object?>();
    native.draftPage = oldLoad;
    final loading = controller.loadDraft('session:same:prompt');
    final staleAssertion = expectLater(loading, throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'connection_changed')));
    await controller.pair('new-bundle', 'Phone');
    oldLoad.complete({'text': 'First PC secret'});
    await staleAssertion;
    native.draftPage = null;
    expect(await controller.loadDraft('session:same:prompt'), isNull);
    expect(object(controller.localState['sections'])['pins'], isNull);
    await controller.saveDraft('session:same:prompt', {'text': 'Second PC draft'});
    expect(native.drafts['first:phone']!['session:same:prompt']!['text'], 'First PC secret');
    expect(native.drafts['second:phone']!['session:same:prompt']!['text'], 'Second PC draft');
    controller.dispose();
    await native.stream.close();
  });
  test('decision and new-session drafts retain their complete fields across relaunch', () async {
    final native = DurableNative();
    final first = OmputerController(adapter: native);
    await first.initialize();
    final decision = {'text': 'Input draft', 'selected': 'A', 'questions': [{'id': 'q', 'selected': ['B'], 'customSelected': true, 'customInput': 'Custom answer', 'note': 'Keep context'}]};
    final newSession = {'name': 'Unsent session', 'prompt': 'Unsent first message', 'model': {'provider': 'local', 'id': 'chosen-model'}};
    await first.saveDraft('decision:question', decision);
    await first.saveDraft('new:project', newSession);
    first.dispose();
    final restored = OmputerController(adapter: native);
    await restored.initialize();
    expect((await restored.loadDraft('decision:question'))!..remove('_revision'), decision);
    expect((await restored.loadDraft('new:project'))!..remove('_revision'), newSession);
    restored.dispose();
    await native.stream.close();
  });

  test('retained active transcript survives bounded inactive eviction and pair fencing', () async {
    final native = DurableNative();
    final controller = OmputerController(adapter: native, maxInactiveTranscripts: 2);
    await controller.initialize();
    final active = controller.retainTranscript('active');
    final message = ChatMessage.fromJson({'id': 'm', 'sequence': 1, 'content': 'Live'});
    active.upsert(message);
    var updates = 0;
    active.messages['m']!.addListener(() => updates++);
    for (var i = 0; i < 100; i++) { controller.transcript('inactive-$i').upsert(ChatMessage.fromJson({'id': 'old', 'sequence': 1})); }
    expect(identical(controller.transcript('active'), active), isTrue);
    active.upsert(ChatMessage.fromJson({'id': 'm', 'sequence': 2, 'content': 'Still live'}));
    expect(updates, 1);
    expect(controller.transcript('inactive-0').ids, isEmpty);
    await controller.pair('new-bundle', 'Phone');
    expect(active.ids, isEmpty);
    expect(identical(controller.transcript('active'), active), isTrue);
    controller.releaseTranscript('active');
    controller.dispose();
    await native.stream.close();
  });

  test('catalog identity, risk and expected binding guard actual command submission', () async {
    final native = DurableNative()..data = {'sequence': 1, 'sessions': [liveSession()]};
    native.requestHandler = (request) async {
      if ('${request['path']}'.contains('/control?')) return {'journalId': 'journal', 'bindingRevision': 'binding', 'catalogRevision': 'catalog', 'commands': [{'id': 'builtin:compact', 'available': true, 'risk': 'destructive', 'requiresIdle': true}]};
      if (request['path'] == '/v1/commands') return {'id': object(request['body'])['id'], 'success': true};
      throw StateError('Unexpected $request');
    };
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await expectLater(controller.executeCommand('session', 'builtin:compact', ''), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'confirmation_required')));
    await expectLater(controller.executeCommand('session', 'builtin:compact', '', catalogRevision: 'stale', confirmed: true), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'stale_catalog')));
    await expectLater(controller.executeCommand('session', 'missing', '', confirmed: true), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'unsupported_command')));
    expect(native.requests.where((request) => request['method'] == 'POST'), isEmpty);
    await controller.executeCommand('session', 'builtin:compact', 'focus', catalogRevision: 'catalog', confirmed: true);
    final payload = object(object(native.requests.last['body'])['payload']);
    expect(payload['expectedJournalId'], 'journal');
    expect(payload['expectedBindingRevision'], 'binding');
    expect(payload['catalogRevision'], 'catalog');
    expect(payload['args'], 'focus');
    controller.dispose();
    await native.stream.close();
  });

  test('control query preserves encoded identity and typed arguments', () async {
    final native = DurableNative()..data = {'sequence': 1, 'sessions': [{...liveSession(), 'id': 'a/b'}]};
    native.requestHandler = (request) async => {'models': [{'provider': 'target', 'id': 'model'}]};
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    expect((await controller.models(sessionId: 'a/b')).single.key, 'target/model');
    await controller.controls('a/b', 'queue', arguments: {'include': ['one', 'two'], 'before': 3});
    expect('${native.requests.last['path']}', startsWith('/v1/sessions/a%2Fb/control?'));
    final query = Uri.parse(native.requests.last['path'] as String).queryParameters;
    expect(query['view'], 'queue');
    expect(jsonDecode(query['include']!), ['one', 'two']);
    expect(query['before'], '3');
    controller.dispose();
    await native.stream.close();
  });
  test('unresolved decision cannot create another UUID after lost ACK', () async {
    final native = DurableNative()..loseAck = true..data = {'sequence': 1, 'interactions': [{'id': 'd', 'sessionId': 'session', 'status': 'pending'}]};
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final decision = controller.snapshot.interaction('d')!;
    await expectLater(controller.respond(decision, {'value': 'A'}), throwsA(isA<CommandUncertain>()));
    await expectLater(controller.respond(decision, {'value': 'A'}), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'stale_interaction')));
    expect(native.requests.where((request) => request['method'] == 'POST'), hasLength(1));
    await controller.reconcileOperations();
    expect(decision.status, 'resolved');
    controller.dispose();
    await native.stream.close();
  });

  test('memory writes carry optimistic revision and file helpers preserve paging', () async {
    final native = DurableNative()..data = {'sequence': 1, 'projects': [{'id': 'p', 'memoryRevision': 9}]};
    native.requestHandler = (request) async {
      if (request['method'] == 'PATCH') return {'id': 'p', 'memoryRevision': 10};
      if (request['path'] == '/v1/snapshot') return native.data;
      return {'hasMore': true, 'nextCursor': 7, 'entries': [], 'files': []};
    };
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.updateProject('p', {'summary': 'New memory'});
    final patch = native.requests.firstWhere((request) => request['method'] == 'PATCH');
    expect(object(patch['body'])['expectedMemoryRevision'], 9);
    final page = await controller.projectTree('p', path: 'folder/a b', cursor: 7);
    expect(page['nextCursor'], 7);
    final treeQuery = Uri.parse(native.requests.last['path'] as String).queryParameters;
    expect(treeQuery['cursor'], '7');
    expect(treeQuery['path'], 'folder/a b');
    await controller.memoryHistory('p', before: 123);
    expect(Uri.parse(native.requests.last['path'] as String).queryParameters['before'], '123');
    await controller.search('a b', sessionId: 'session', cursor: 4);
    final searchQuery = Uri.parse(native.requests.last['path'] as String).queryParameters;
    expect(searchQuery['query'], 'a b');
    expect(searchQuery['cursor'], '4');
    controller.dispose();
    await native.stream.close();
  });

  test('attachment helpers retain native prepared bytes and explicit removal', () async {
    final native = DurableNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final images = await controller.pickImages(camera: true);
    expect(images.single['data'], 'aGVsbG8=');
    expect(images.single['mimeType'], 'image/png');
    expect(await controller.consumeSharedImages(), isEmpty);
    await controller.releaseAttachments(images);
    expect(native.calls, containsAllInOrder(['pickImages', 'sharedImages', 'removeAttachment']));
    controller.dispose();
    await native.stream.close();
  });

  test('failed live turn still permits identity-bound high-level controls', () async {
    final native = DurableNative()..data = {'sequence': 1, 'sessions': [{...liveSession(), 'status': 'failed', 'turnError': 'Provider error'}]};
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.control('session', 'plan.cancel', confirmed: true);
    final payload = object(object(native.requests.last['body'])['payload']);
    expect(payload['expectedJournalId'], 'journal');
    expect(payload['expectedBindingRevision'], 'binding');
    expect(payload['control'], 'plan.cancel');
    expect(controller.snapshot.session('session')!.canSendMessages, isTrue);
    controller.dispose();
    await native.stream.close();
  });
  test('operation history and output keep explicit pagination metadata', () async {
    final native = DurableNative();
    native.requestHandler = (request) async {
      final path = request['path'] as String;
      if (path.contains('/operations?')) return {'operations': [{'id': 'remote', 'action': 'session.compact', 'status': 'succeeded', 'sessionId': 'session', 'sequence': 7}], 'hasMore': true, 'nextCursor': 7};
      if (path.contains('/output?')) return {'items': [{'sequence': 8, 'kind': 'stdout', 'text': 'result'}], 'hasMore': true, 'truncated': false};
      throw StateError('Unexpected $request');
    };
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final page = await controller.loadOperations('session', before: 10, limit: 1);
    expect(page['hasMore'], isTrue);
    expect(page['nextCursor'], 7);
    expect(controller.operationsFor('session').single['id'], 'remote');
    expect(native.pending['remote']!['status'], 'succeeded');
    final output = await controller.operationOutput('remote', after: 7, limit: 1);
    expect(objects(output['items']).single['sequence'], 8);
    expect(output['hasMore'], isTrue);
    final query = Uri.parse(native.requests.last['path'] as String).queryParameters;
    expect(query['after'], '7');
    expect(query['limit'], '1');
    controller.dispose();
    await native.stream.close();
  });
}
