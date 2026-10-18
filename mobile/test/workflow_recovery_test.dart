import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';

Json pending({String status = 'pending'}) => {'id': 'decision', 'sessionId': 'session', 'method': 'select', 'status': status, 'options': [{'label': 'A'}]};
Json message(String id, int sequence) => {'id': id, 'sequence': sequence, 'content': id};

class RecoveryNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final calls = <Json>[];
  Json cached = {'sequence': 1};
  Json connection = {'paired': true, 'connected': true};
  Json commandResult = {'success': true};
  Completer<Object?>? commandReply, snapshotReply;
  final pages = <Completer<Object?>>[];
  @override
  Stream<Object?> get events => stream.stream;
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'connection' || method == 'connect') return connection;
    if (method == 'snapshot') return cached;
    if (method == 'preferences') return {'theme': 'system', 'appVersion': '1.0.1', 'buildNumber': 2, 'protocol': 1};
    if (method == 'localState') return {'identity': 'recovery:phone', 'sections': {}};
    if (method == 'operationList') return <Json>[];
    if (method == 'operationSave') return null;
    if (method == 'request') {
      calls.add(arguments!);
      if (arguments['path'] == '/v1/commands') return commandReply?.future ?? commandResult;
      if (arguments['path'] == '/v1/snapshot') return snapshotReply?.future ?? cached;
      if ('${arguments['path']}'.contains('/messages')) {
        final page = Completer<Object?>();
        pages.add(page);
        return page.future;
      }
      if (arguments['method'] == 'PATCH') return {'id': 'project', ...object(arguments['body'])};
    }
    throw StateError('Unexpected $method $arguments');
  }
}

Future<void> close(OmputerController controller, RecoveryNative native) async {
  controller.dispose();
  await native.stream.close();
}

void main() {
  test('acknowledged answer settles latest snapshot without waiting for slow refresh', () async {
    final native = RecoveryNative()..commandReply = Completer<Object?>()..snapshotReply = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    controller.snapshot = Snapshot.fromJson({'sequence': 2, 'interactions': [pending()]});
    final opened = controller.snapshot.interactions.single;
    final response = controller.respond(opened, {'value': 'A'});
    native.stream.add({'type': 'snapshot', 'data': {'sequence': 3, 'interactions': [pending()]}});
    native.commandReply!.complete({'success': true});
    await response;
    expect(controller.snapshot.interactions.single.status, 'resolved');
    expect(controller.snapshot.pending, isEmpty);
    // A delayed native snapshot at the same watermark cannot reopen an accepted answer.
    native.stream.add({'type': 'snapshot', 'data': {'sequence': 3, 'interactions': [pending()]}});
    expect(controller.snapshot.pending, isEmpty);
    native.snapshotReply!.completeError(StateError('offline after acceptance'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot.pending, isEmpty);
    expect(controller.error, isNotNull);
    expect(native.calls.where((call) => call['path'] == '/v1/commands'), hasLength(1));
    await close(controller, native);
  });

  test('double response cannot send another command while first acknowledgement is pending', () async {
    final native = RecoveryNative()..commandReply = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    controller.snapshot = Snapshot.fromJson({'sequence': 2, 'interactions': [pending()]});
    final interaction = controller.snapshot.interactions.single;
    final first = controller.respond(interaction, {'value': 'A'});
    await expectLater(controller.respond(interaction, {'value': 'A'}), throwsA(isA<ControllerFailure>()));
    native.commandReply!.complete({'success': true});
    await first;
    expect(native.calls.where((call) => call['path'] == '/v1/commands'), hasLength(1));
    await close(controller, native);
  });

  test('rejected command preserves pending answer and allows a corrected response', () async {
    final native = RecoveryNative()..commandResult = {'accepted': false, 'error': {'code': 'invalid_answer', 'message': 'Invalid answer'}};
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    controller.snapshot = Snapshot.fromJson({'sequence': 2, 'interactions': [pending()]});
    final interaction = controller.snapshot.interactions.single;
    await expectLater(controller.respond(interaction, {'value': 'A'}), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'invalid_answer')));
    expect(controller.snapshot.pending, hasLength(1));
    native.commandResult = {'success': true};
    await controller.respond(interaction, {'value': 'A'});
    expect(controller.snapshot.pending, isEmpty);
    await close(controller, native);
  });

  test('resume restores cached project state and reloads open history without reopening pagination', () async {
    final native = RecoveryNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final loading = controller.loadMessages('session');
    native.pages.single.complete({'messages': [message('first', 1)], 'hasMore': false});
    await loading;
    native.cached = {'sequence': 2, 'projects': [{'id': 'project', 'summary': 'Updated while app paused'}]};
    await controller.reloadConnection();
    expect(controller.snapshot.project('project')!.summary, 'Updated while app paused');
    native.pages.last.complete({'messages': [message('latest', 2)], 'hasMore': true});
    await Future<void>.delayed(Duration.zero);
    final store = controller.transcript('session');
    expect(store.ids, ['first', 'latest']);
    expect(store.hasMore, isFalse);
    expect(controller.appVersion, '1.0.1');
    expect(controller.buildNumber, '2');
    await close(controller, native);
  });

  test('foreground reload fences an older in-flight page and automatically fetches current history', () async {
    final native = RecoveryNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final loading = controller.loadMessages('session');
    await controller.reloadConnection();
    native.pages.first.complete({'messages': [message('obsolete', 1)], 'hasMore': false});
    await loading;
    expect(native.pages, hasLength(2));
    native.pages.last.complete({'messages': [message('current', 2)], 'hasMore': false});
    await Future<void>.delayed(Duration.zero);
    expect(controller.transcript('session').ids, ['current']);
    await close(controller, native);
  });

  test('successful checkpoint save does not become a failure when subsequent snapshot stalls', () async {
    final native = RecoveryNative()..snapshotReply = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    controller.snapshot = Snapshot.fromJson({'sequence': 1, 'projects': [{'id': 'project', 'summary': 'Before'}]});
    await controller.updateProject('project', {'summary': 'Saved'});
    expect(controller.snapshot.project('project')!.summary, 'Saved');
    native.snapshotReply!.completeError(StateError('Network disconnected'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot.project('project')!.summary, 'Saved');
    await close(controller, native);
  });
}
