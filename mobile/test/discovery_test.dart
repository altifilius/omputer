import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';

class DiscoveryNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final calls = <(String, Json?)>[];
  Completer<Object?>? selectedRequest, selectedPoll;
  bool approved = false;
  @override
  Stream<Object?> get events => stream.stream;
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    calls.add((method, args));
    switch (method) {
      case 'connection': return {'paired': approved, 'connected': approved};
      case 'connect': return {'paired': approved, 'connected': approved};
      case 'snapshot': return {'sequence': 1, 'projects': approved ? [{'id': 'new-project', 'name': 'New PC'}] : []};
      case 'preferences': return {'theme': 'system'};
      case 'localState': return {'identity': approved ? 'test-server:test-device' : null, 'sections': <String, dynamic>{}};
      case 'localStateSet': return {'identity': approved ? 'test-server:test-device' : null, 'sections': <String, dynamic>{}};
      case 'operationList': return <Json>[];
      case 'sharedImages': return <Json>[];
      case 'operationSave':
      case 'operationRemove': return null;
      case 'notifications': return true;
      case 'discover': return {'scanning': args!['enabled']};
      case 'pairRequest': return selectedRequest?.future ?? {'requestId': 'request', 'verificationCode': '123456', 'serverName': 'PC', 'fingerprint': 'pin'};
      case 'pairPoll': return selectedPoll?.future ?? {'status': approved ? 'approved' : 'pending'};
      case 'pairCancel': return null;
      case 'request': return {'sequence': 1, 'projects': [{'id': 'new-project', 'name': 'New PC'}]};
    }
    throw StateError('Unexpected method $method');
  }
}

void main() {
  test('selection passes discovered identity only and pending never pairs', () async {
    final native = DiscoveryNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    native.stream.add({'type': 'discovery', 'data': {'scanning': true, 'computers': [{'id': 'pc-a', 'name': 'Desk', 'url': 'https://192.168.1.7:8787', 'fingerprint': 'pin'}]}});
    expect(controller.computers.single['id'], 'pc-a');
    await controller.requestPair('pc-a', 'Phone', background: true);
    final args = native.calls.firstWhere((call) => call.$1 == 'pairRequest').$2!;
    expect(args, {'computerId': 'pc-a', 'name': 'Phone', 'background': true});
    expect(args.containsKey('url'), isFalse);
    expect(controller.pairing!['verificationCode'], '123456');
    expect(await controller.pollPair(), 'pending');
    expect(controller.connection.paired, isFalse);
    expect(controller.pairing!.containsKey('claimSecret'), isFalse);
    controller.dispose(); await native.stream.close();
  });
  test('cancelled in-flight request cannot restore approval screen', () async {
    final native = DiscoveryNative()..selectedRequest = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final request = controller.requestPair('pc-a', 'Phone');
    await controller.cancelPair();
    native.selectedRequest!.complete({'requestId': 'old', 'verificationCode': '111111'});
    await request;
    expect(controller.pairing, isNull);
    expect(controller.pairingStatus, 'idle');
    controller.dispose(); await native.stream.close();
  });
  test('approved pairing resets previous computer sequence and transcript', () async {
    final native = DiscoveryNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    controller.snapshot = Snapshot.fromJson({'sequence': 999, 'projects': [{'id': 'old', 'name': 'Old PC'}]});
    controller.transcript('old').upsert(ChatMessage.fromJson({'id': 'secret', 'role': 'user', 'sequence': 1}));
    await controller.requestPair('pc-a', 'Phone');
    native.approved = true;
    expect(await controller.pollPair(), 'approved');
    expect(controller.connection.paired, isTrue);
    expect(controller.snapshot.projects.single.id, 'new-project');
    expect(controller.transcript('old').ids, isEmpty);
    controller.dispose(); await native.stream.close();
  });
  test('denied request remains unpaired and exposes terminal status', () async {
    final native = DiscoveryNative()..selectedPoll = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.requestPair('pc-a', 'Phone');
    native.selectedPoll!.complete({'status': 'denied'});
    expect(await controller.pollPair(), 'denied');
    expect(controller.connection.paired, isFalse);
    controller.dispose(); await native.stream.close();
  });
  test('cancelled in-flight poll cannot apply old computer approval', () async {
    final native = DiscoveryNative()..selectedPoll = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await controller.requestPair('pc-a', 'Phone');
    final poll = controller.pollPair();
    await controller.cancelPair();
    native.selectedPoll!.complete({'status': 'approved'});
    expect(await poll, 'cancelled');
    expect(controller.connection.paired, isFalse);
    expect(controller.pairingStatus, 'idle');
    controller.dispose(); await native.stream.close();
  });
}
