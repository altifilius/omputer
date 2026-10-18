import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';

class ResetNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final page = Completer<Object?>();
  Completer<Object?>? refreshedPage;
  int messageRequests = 0;
  @override
  Stream<Object?> get events => stream.stream;
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'connection' || method == 'connect') return {'paired': true, 'connected': true};
    if (method == 'snapshot') return {'sequence': 1};
    if (method == 'preferences') return {'theme': 'system'};
    if (method == 'localState') return {'identity': 'pc:phone', 'sections': <String, dynamic>{}};
    if (method == 'operationList') return [];
    if (method == 'request' && '${arguments?['path']}'.contains('/messages')) {
      messageRequests++;
      return messageRequests == 1 ? page.future : refreshedPage!.future;
    }
    throw StateError('Unexpected $method');
  }
}

void main() {
  test('branch reset removes old messages and rejects an old in-flight page', () async {
    final native = ResetNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final transcript = controller.transcript('session');
    transcript.upsert(ChatMessage.fromJson({'id': 'old', 'sequence': 2, 'content': [{'type':'text','text':'old branch'}]}));
    final loading = controller.loadMessages('session');
    native.stream.add({'type':'event','data':{'type':'session.event','sessionId':'session','sequence':10,'data':{'type':'transcript_reset'}}});
    native.stream.add({'type':'event','data':{'type':'message.upsert','sessionId':'session','sequence':11,'data':{'id':'new','sequence':11,'content':[{'type':'text','text':'new branch'}]}}});
    native.page.complete({'messages':[{'id':'old','sequence':2,'content':[{'type':'text','text':'old branch'}]}],'hasMore':false});
    await loading;
    expect(transcript.ids, ['new']);
    expect(transcript.messages['new']!.value.content.single['text'], 'new branch');
    controller.dispose();
    await native.stream.close();
  });
  test('snapshot catchup rejects in-flight history and reloads an opened conversation', () async {
    final native = ResetNative()..refreshedPage = Completer<Object?>();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    final transcript = controller.transcript('session');
    transcript.upsert(ChatMessage.fromJson({'id':'stale','sequence':1,'content':[{'type':'text','text':'Old branch'}]}));
    final loading = controller.loadMessages('session');
    native.stream.add({'type':'history_reset','data':<String, Object?>{}});
    native.page.complete({'messages':[{'id':'stale','sequence':1,'content':[{'type':'text','text':'Old branch'}]}],'hasMore':false});
    await loading;
    expect(transcript.ids,isEmpty);
    native.refreshedPage!.complete({'messages':[{'id':'current','sequence':4,'content':[{'type':'text','text':'Current authoritative branch'}]}],'hasMore':false});
    await Future<void>.delayed(Duration.zero);
    expect(transcript.ids,['current']);
    expect(transcript.messages['current']!.value.content.single['text'],'Current authoritative branch');
    controller.dispose();
    await native.stream.close();
  });
}
