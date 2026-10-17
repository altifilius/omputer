import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';

class FakeNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final List<Json> requests = [];
  Completer<Object?>? messagePage;
  @override
  Stream<Object?> get events => stream.stream;
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    switch (method) {
      case 'pair':
        return {'deviceId': 'new-device', 'serverName': 'Second PC'};
      case 'connection':
      case 'connect':
        return {'paired': true, 'connected': true};
      case 'snapshot':
        return {'sequence': 1, 'projects': [], 'sessions': [], 'interactions': [], 'devices': []};
      case 'preferences':
        return {'theme': 'system'};
      case 'request':
        requests.add(arguments!);
        if ('${arguments['path']}'.contains('/messages')) return messagePage!.future;
        return {'success': true};
    }
    throw StateError('Unexpected native operation: $method');
  }
}

Json interaction({String status = 'pending', String? expiresAt}) => {'id': 'question', 'sessionId': 'session', 'projectId': 'project', 'method': 'select', 'title': 'Choose', 'status': status, if (expiresAt != null) 'expiresAt': expiresAt, 'options': [{'label': 'A'}]};

void main() {
  test('revoking another phone does not report this phone as revoked', () async {
    final native = FakeNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    native.stream.add({'type': 'event', 'data': {'type': 'device.revoked', 'data': {'id': 'another-phone', 'currentDevice': false}}});
    expect(controller.error, isNull);
    expect(controller.connection.connected, isTrue);
    native.stream.add({'type': 'event', 'data': {'type': 'device.revoked', 'data': {'id': 'this-phone', 'currentDevice': true}}});
    expect(controller.error, isNotNull);
    controller.dispose();
    await native.stream.close();
  });
  test('pairing a new PC discards old high watermark and conversation cache', () async {
    final native = FakeNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    controller.snapshot = Snapshot.fromJson({'sequence': 999, 'projects': [{'id': 'old-project', 'name': 'First PC'}], 'interactions': [interaction()]});
    controller.transcript('old-session').upsert(ChatMessage.fromJson({'id': 'old-message', 'role': 'user', 'sequence': 4, 'content': [{'type': 'text', 'text': 'first PC secret'}]}));
    await controller.pair('new-bundle', 'phone');
    native.stream.add({'type': 'snapshot', 'data': {'sequence': 2, 'projects': [{'id': 'new-project', 'name': 'Second PC'}]}});
    expect(controller.snapshot.projects.single.id, 'new-project');
    expect(controller.snapshot.interactions, isEmpty);
    expect(controller.transcript('old-session').ids, isEmpty);
    controller.dispose();
    await native.stream.close();
  });
  test('resolved desktop interaction never sends a stale mobile answer', () async {
    final native = FakeNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final opened = Interaction.fromJson(interaction());
    controller.snapshot = Snapshot.fromJson({'sequence': 8, 'interactions': [interaction(status: 'resolved')]});
    await expectLater(controller.respond(opened, {'value': 'A'}), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'stale_interaction')));
    expect(native.requests, isEmpty);
    controller.dispose();
    await native.stream.close();
  });

  test('expired interaction is not sent even before a server expiry event', () async {
    final native = FakeNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final value = interaction(expiresAt: DateTime.now().subtract(const Duration(seconds: 1)).toUtc().toIso8601String());
    controller.snapshot = Snapshot.fromJson({'interactions': [value]});
    await expectLater(controller.respond(Interaction.fromJson(value), {'value': 'A'}), throwsA(isA<ControllerFailure>()));
    expect(native.requests, isEmpty);
    controller.dispose();
    await native.stream.close();
  });

  test('late history page cannot overwrite a newer accumulated message', () async {
    final native = FakeNative()..messagePage = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final page = controller.loadMessages('session');
    native.stream.add({'type': 'event', 'data': {'type': 'message.upsert', 'sequence': 10, 'sessionId': 'session', 'data': {'id': 'message', 'role': 'assistant', 'sequence': 4, 'revision': 2, 'content': [{'type': 'text', 'text': 'complete'}]}}});
    native.messagePage!.complete({'messages': [{'id': 'message', 'role': 'assistant', 'sequence': 4, 'revision': 1, 'content': [{'type': 'text', 'text': 'partial'}]}], 'hasMore': false});
    await page;
    final transcript = controller.transcript('session');
    expect(transcript.ids, ['message']);
    expect(transcript.messages['message']!.value.content.single['text'], 'complete');
    expect(transcript.hasMore, isFalse);
    controller.dispose();
    await native.stream.close();
  });

  test('message replacement notifies only that message, not the full list', () {
    final store = Transcript();
    store.upsert(ChatMessage.fromJson({'id': 'a', 'role': 'assistant', 'sequence': 1, 'content': []}));
    var listChanges = 0, messageChanges = 0;
    store.addListener(() => listChanges++);
    store.messages['a']!.addListener(() => messageChanges++);
    store.upsert(ChatMessage.fromJson({'id': 'a', 'role': 'assistant', 'sequence': 2, 'content': [{'type': 'text', 'text': 'next'}]}));
    expect(listChanges, 0);
    expect(messageChanges, 1);
    store.dispose();
  });

  test('multi selection preserves option order and supports custom context', () {
    final answer = QuestionAnswer({'id': 'q', 'question': 'Which?', 'multi': true, 'options': [{'label': 'A'}, {'label': 'B'}, {'label': 'C'}]});
    answer.select('C', true);
    answer.select('A', true);
    answer.select('B', true);
    answer.select('B', false);
    answer.select('not-a-real-option', true);
    answer.customInput = ' Another approach ';
    answer.note = ' Keep existing data ';
    expect(answer.toJson(), {'id': 'q', 'question': 'Which?', 'options': ['A', 'B', 'C'], 'multi': true, 'selectedOptions': ['A', 'C'], 'customInput': 'Another approach', 'note': 'Keep existing data'});
  });

  test('single selection replaces rather than accumulates choices', () {
    final answer = QuestionAnswer({'id': 'q', 'question': 'Which?', 'options': [{'label': 'A'}, {'label': 'B'}]});
    expect(answer.valid, isFalse);
    answer.select('A', true);
    answer.select('B', true);
    expect(answer.selected, {'B'});
    expect(answer.valid, isTrue);
  });
}
