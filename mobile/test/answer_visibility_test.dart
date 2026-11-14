import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session.dart';
import 'package:omputer/ui.dart';

Json reference(int n, {int revision = 1, int? sourceRevision}) => {
  'messageId': 'answer-$n', 'revision': revision, 'sequence': n * 2,
  if (sourceRevision != null) 'sourceRevision': sourceRevision,
  'ordinal': n, 'preview': 'Yanıt $n', 'timestamp': '2026-11-14T12:00:00Z',
};
Json answer(int n, {int revision = 1, String? text}) => {
  'id': 'answer-$n', 'role': 'assistant', 'revision': revision,
  'sequence': n * 2, 'stopReason': 'stop',
  'content': [{'type': 'text', 'text': text ?? 'Yanıt $n', 'phase': 'final_answer'}],
};

class VisibilityNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final calls = <Json>[];
  Json sections = {};
  bool failRead = false;
  int? pendingBefore;
  Completer<Json>? pendingPage;
  int count = 3, latestRevision = 1;
  final sourceRevisions = <int, int>{};
  String epoch = 'epoch-one', generation = 'history-one';
  final messages = <Json>[
    for (var n = 1; n <= 3; n++) ...[
      {'id': 'user-$n', 'role': 'user', 'sequence': n * 2 - 1, 'revision': 1, 'content': 'İstek $n'},
      answer(n),
    ],
  ];
  Json get data => {
    'journalEpoch': epoch, 'sequence': 100,
    'projects': [{'id': 'project', 'name': 'Proje'}],
    'sessions': [{
      'id': 'session', 'projectId': 'project', 'name': 'Konuşma',
      'transport': 'rpc', 'status': 'idle', 'writerConnected': true,
      'workState': 'settled', 'capabilities': ['session.prompt'],
      'answerSummary': {'generation': generation, 'count': count,
        'latest': reference(count, revision: latestRevision, sourceRevision: sourceRevisions[count])},
    }],
  };
  Iterable<Json> get reads => calls.where((call) => call['method'] == 'answerRead');
  Iterable<Json> get readers => calls.where((call) => call['method'] == 'answerReader');
  @override Stream<Object?> get events => stream.stream;
  @override Future<Object?> invoke(String method, [Json? args]) async {
    calls.add({'method': method, ...?args});
    switch (method) {
      case 'connection': case 'connect': return {'paired': true, 'connected': true};
      case 'snapshot': return data;
      case 'preferences': return {'theme': 'light'};
      case 'localState': return {'identity': 'pc:phone', 'sections': sections};
      case 'operationList': case 'sharedImages': return [];
      case 'draftLoad': return null;
      case 'draftSave': case 'draftDelete': case 'answerReader': return null;
      case 'answerRead':
        if (failRead) throw PlatformException(code: 'storage', message: 'Disk dolu');
        sections = {...sections, 'read': {...object(sections['read']), 'session:session': {
          'journalEpoch': args!['expectedJournalEpoch'], 'generation': args['generation'],
          for (final key in ['messageId', 'revision', 'sequence', 'ordinal']) key: args[key],
        }}};
        return {'identity': 'pc:phone', 'sections': sections};
      case 'request':
        final uri = Uri.parse('${args!['path']}');
        if (uri.path == '/v1/snapshot') return data;
        if (uri.path.endsWith('/messages')) {
          final before = int.tryParse(uri.queryParameters['before'] ?? '');
          if (pendingPage != null && before == pendingBefore) return pendingPage!.future;
          final eligible = messages.where((m) => before == null || (m['sequence'] as int) < before).toList();
          final start = (eligible.length - 50).clamp(0, eligible.length);
          return {'messages': eligible.sublist(start), 'hasMore': start > 0};
        }
        if (uri.path.endsWith('/answers')) {
          final after = int.parse(uri.queryParameters['after'] ?? '0');
          final end = (after + 100).clamp(0, count);
          return {'generation': generation, 'count': count,
            'answers': [for (var n = after + 1; n <= end; n++) reference(n, revision: n == count ? latestRevision : 1, sourceRevision: sourceRevisions[n])],
            'hasMore': end < count};
        }
        throw StateError('Unexpected request $args');
    }
    throw StateError('Unexpected native method $method');
  }
  void snapshot() => stream.add({'type': 'snapshot', 'data': data});
  void upsert(Json message) {
    messages.removeWhere((m) => m['id'] == message['id']); messages.add(message);
    messages.sort((a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int));
    stream.add({'type': 'event', 'data': {'type': 'message.upsert', 'sessionId': 'session',
      'journalEpoch': epoch, 'data': {'message': message}}});
  }
}

Future<OmputerController> mountSession(WidgetTester tester, VisibilityNative native, {String? initialMessageId, bool firstUnread = false, Future<void> Function(OmputerController)? beforeMount}) async {
  tester.view.physicalSize = const Size(400, 900); tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final c = OmputerController(adapter: native); await c.initialize();
  if (firstUnread) initialMessageId = (await c.firstUnreadAnswer(c.snapshot.sessions.single))!.messageId;
  await beforeMount?.call(c);
  await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: SessionScreen(controller: c, sessionId: 'session', initialMessageId: initialMessageId)));
  await tester.pumpAndSettle();
  return c;
}
Future<void> unmountSession(WidgetTester tester, OmputerController c, VisibilityNative native) async {
  await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  c.dispose(); await native.stream.close();
}

void main() {
  testWidgets('only post-layout visible latest answer persists exact read position', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native);
    expect(native.reads, isNotEmpty);
    final read = native.reads.last;
    expect(read['messageId'], 'answer-3'); expect(read['ordinal'], 3);
    expect(read['revision'], 1); expect(read['expectedJournalEpoch'], 'epoch-one');
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 0);
    expect(native.readers.last['atLatest'], isTrue);
    await unmountSession(tester, c, native);
  });
  testWidgets('first unread target advances only to the exact visible answer', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native, firstUnread: true);
    expect(native.reads, isNotEmpty);
    expect(native.reads.map((call) => call['ordinal']), everyElement(1));
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 2);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    expect(find.text('Yanıt 1'), findsOneWidget);
    expect(find.text('Yanıt 3'), findsNothing);
    await unmountSession(tester, c, native);
  });
  testWidgets('deep first unread opens a bounded exact sequence window rather than twenty-page search', (tester) async {
    final native = VisibilityNative()..count = 650;
    native.messages..clear()..addAll([
      for (var n = 1; n <= native.count; n++) ...[
        {'id': 'user-$n', 'role': 'user', 'sequence': n * 2 - 1, 'revision': 1, 'content': 'İstek $n'},
        answer(n),
      ],
    ]);
    final c = await mountSession(tester, native, firstUnread: true);
    expect(find.text('Yanıt 1'), findsOneWidget);
    expect(native.reads, isNotEmpty);
    expect(native.reads.map((call) => call['ordinal']), everyElement(1));
    final pages = native.calls.where((call) => '${call['path']}'.contains('/messages')).toList();
    expect(pages.length, lessThanOrEqualTo(2));
    expect(pages.any((call) => Uri.parse('${call['path']}').queryParameters['before'] == '3'), isTrue);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 649);
    await unmountSession(tester, c, native);
  });
  testWidgets('reopening after a deep target keeps intervening history reachable from the live window', (tester) async {
    final native = VisibilityNative()..count = 650;
    native.messages..clear()..addAll([
      for (var n = 1; n <= native.count; n++) ...[
        {'id': 'user-$n', 'role': 'user', 'sequence': n * 2 - 1, 'revision': 1, 'content': 'İstek $n'},
        answer(n),
      ],
    ]);
    final liveStart = native.messages[native.messages.length - 50]['sequence'];
    final c = await mountSession(tester, native, firstUnread: true);
    expect(find.text('Yanıt 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light),
      home: SessionScreen(controller: c, sessionId: 'session')));
    await tester.pumpAndSettle();
    expect(c.transcript('session').hasMore, isTrue,
      reason: 'The live window still has intervening messages before it.');
    final list = find.byType(ListView).first;
    await tester.scrollUntilVisible(find.text('Önceki mesajları yükle'), 600,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first);
    await tester.tap(find.text('Önceki mesajları yükle')); await tester.pumpAndSettle();
    final pages = native.calls.where((call) => '${call['path']}'.contains('/messages')).toList();
    expect(Uri.parse('${pages.last['path']}').queryParameters['before'], '$liveStart');
    expect(c.transcript('session').messages.containsKey('answer-625'), isTrue);
    expect(pages.length, lessThanOrEqualTo(4));
    expect(tester.takeException(), isNull);
    await unmountSession(tester, c, native);
  });
  for (final failure in [false, true]) {
    testWidgets('reopened session loads latest after disposed gap loader ${failure ? 'fails' : 'completes'}', (tester) async {
      final native = VisibilityNative()..count = 60;
      native.messages..clear()..addAll([
        for (var n = 1; n <= native.count; n++) ...[
          {'id': 'user-$n', 'role': 'user', 'sequence': n * 2 - 1, 'revision': 1, 'content': 'İstek $n'},
          answer(n),
        ],
      ]);
      final c = await mountSession(tester, native, firstUnread: true);
      await tester.tap(find.byTooltip('Canlı son mesaja dön')); await tester.pumpAndSettle();
      final list = find.byType(ListView).first;
      await tester.scrollUntilVisible(find.text('Önceki mesajları yükle'), 600,
        scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first);
      final pending = Completer<Json>();
      native.pendingBefore = native.messages[native.messages.length - 50]['sequence'] as int;
      native.pendingPage = pending;
      await tester.tap(find.text('Önceki mesajları yükle')); await tester.pump();
      final transcript = c.transcript('session');
      expect(transcript.loading, isTrue);
      await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light),
        home: SessionScreen(controller: c, sessionId: 'session')));
      await tester.pump();
      expect(identical(c.transcript('session'), transcript), isTrue);
      if (failure) {
        pending.completeError(PlatformException(code: 'old_gap', message: 'Önceki ekranın isteği'));
      } else {
        pending.complete({'messages': [answer(35)], 'hasMore': true});
      }
      await tester.pump(); await tester.pump(const Duration(milliseconds: 100));
      expect(transcript.loaded, isTrue, reason: 'A replacement reader must load latest after the previous route releases its request.');
      expect(transcript.loading, isFalse);
      expect(transcript.refreshAfterLoad, isFalse);
      expect(transcript.messages.containsKey('answer-60'), isTrue);
      expect(transcript.messages.containsKey('answer-35'), isFalse);
      expect(transcript.hasMore, isTrue);
      expect(native.calls.where((call) => '${call['path']}' == '/v1/sessions/session/messages?limit=50'), hasLength(2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await unmountSession(tester, c, native);
    });
  }
  for (final reset in ['history_reset', 'epoch']) {
    testWidgets('pending live-gap page drains replacement history after $reset', (tester) async {
      final native = VisibilityNative()..count = 60;
      native.messages..clear()..addAll([
        for (var n = 1; n <= native.count; n++) ...[
          {'id': 'user-$n', 'role': 'user', 'sequence': n * 2 - 1, 'revision': 1, 'content': 'İstek $n'},
          answer(n),
        ],
      ]);
      final c = await mountSession(tester, native, firstUnread: true);
      await tester.tap(find.byTooltip('Canlı son mesaja dön')); await tester.pumpAndSettle();
      final list = find.byType(ListView).first;
      await tester.scrollUntilVisible(find.text('Önceki mesajları yükle'), 600,
        scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first);
      final pending = Completer<Json>();
      native.pendingBefore = native.messages[native.messages.length - 50]['sequence'] as int;
      native.pendingPage = pending;
      await tester.tap(find.text('Önceki mesajları yükle')); await tester.pump();
      final transcript = c.transcript('session');
      expect(transcript.loading, isTrue);
      native.messages..clear()..add(answer(60, text: 'Yeni geçmiş yanıtı'));
      if (reset == 'epoch') {
        native.epoch = 'epoch-two'; native.generation = 'history-two'; native.snapshot();
      } else {
        native.stream.add({'type': 'history_reset', 'data': <String, dynamic>{}});
      }
      await tester.pump();
      expect(transcript.refreshAfterLoad, isTrue);
      if (reset == 'epoch') {
        pending.complete({'messages': [answer(35)], 'hasMore': true});
      } else {
        pending.completeError(PlatformException(code: 'stale_page', message: 'Eski geçmiş'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Yeni geçmiş yanıtı'), findsOneWidget);
      expect(transcript.ids, ['answer-60']);
      expect(transcript.loaded, isTrue);
      expect(transcript.loading, isFalse);
      expect(transcript.refreshAfterLoad, isFalse);
      expect(tester.takeException(), isNull);
      await unmountSession(tester, c, native);
    });
  }
  testWidgets('first unread focuses the answer in a source with long thinking and tool flow', (tester) async {
    final native = VisibilityNative();
    native.messages[1] = {
      ...answer(1), 'content': [
        {'type': 'thinking', 'thinking': 'SECRET_THINKING'},
        for (var n = 0; n < 30; n++)
          {'type': 'toolCall', 'id': 'call-$n', 'name': 'read', 'arguments': {'path': 'SECRET_PATH'}},
        {'type': 'text', 'text': 'Yanıt 1', 'phase': 'final_answer'},
      ],
    };
    final c = await mountSession(tester, native, firstUnread: true);
    expect(find.text('Yanıt 1').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('answer-end:answer-1')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(native.reads.map((call) => call['ordinal']), [1]);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 2);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    expect(find.text('Düşünme'), findsNothing);
    expect(find.textContaining('SECRET_'), findsNothing);
    await unmountSession(tester, c, native);
  });
  testWidgets('long first unread remains unread until its own end intersects the viewport', (tester) async {
    final native = VisibilityNative();
    native.messages[1] = answer(1, text: List.generate(60, (n) => 'Uzun yanıt satırı $n.').join('\n\n'));
    final c = await mountSession(tester, native, firstUnread: true);
    expect(find.byKey(const ValueKey('answer-end:answer-1')), findsOneWidget);
    expect(native.reads, isEmpty);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 3);
    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.controller!.offset, greaterThan(80));
    list.controller!.jumpTo(0); await tester.pumpAndSettle();
    expect(native.reads.single['ordinal'], 1);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 2);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    await unmountSession(tester, c, native);
  });
  testWidgets('latest summary revision is not read until that exact revision is rendered', (tester) async {
    final native = VisibilityNative()..latestRevision = 2;
    native.messages.removeWhere((message) => message['id'] != 'answer-3');
    final c = await mountSession(tester, native);
    expect(native.reads, isEmpty);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    native.upsert(answer(3, revision: 2, text: 'Düzeltilmiş yanıt'));
    await tester.pumpAndSettle();
    expect(native.reads.single['revision'], 2);
    expect(native.readers.last['atLatest'], isTrue);
    native.upsert(answer(3, revision: 2, text: 'Düzeltilmiş yanıt'));
    await tester.pumpAndSettle();
    expect(native.reads.length, 1);
    await unmountSession(tester, c, native);
  });
  for (final alreadyRead in [false, true]) {
    testWidgets('metadata-only latest source revision uses semantic read revision, already read: $alreadyRead', (tester) async {
      final native = VisibilityNative();
      native.sourceRevisions[3] = 2;
      native.messages..clear()..add(answer(3, revision: 2));
      if (alreadyRead) native.sections = {'read': {'session:session': {
        'journalEpoch': native.epoch, 'generation': native.generation, ...reference(3),
      }}};
      final c = await mountSession(tester, native);
      expect(native.readers, isNotEmpty);
      expect(native.readers.last['atLatest'], isTrue);
      if (alreadyRead) {
        expect(native.reads, isEmpty);
      } else {
        expect(native.reads.single['revision'], 1);
        expect(native.reads.single.containsKey('sourceRevision'), isFalse);
      }
      expect(c.answerReadMarker('session')['revision'], 1);
      expect(c.unreadAnswerCount(c.snapshot.sessions.single), 0);
      await unmountSession(tester, c, native);
    });
  }
  testWidgets('older metadata-only source refreshes a cached reference before semantic read', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native, firstUnread: true, beforeMount: (c) async {
      expect(c.cachedAnswerReference(c.snapshot.sessions.single, 'answer-1')!.sourceRevision, 1);
      native.sourceRevisions[1] = 2;
      native.messages[1] = answer(1, revision: 2);
    });
    expect(native.reads, isNotEmpty);
    expect(native.reads.single['messageId'], 'answer-1');
    expect(native.reads.single['revision'], 1);
    expect(native.reads.single.containsKey('sourceRevision'), isFalse);
    expect(c.cachedAnswerReference(c.snapshot.sessions.single, 'answer-1')!.sourceRevision, 2);
    expect(c.answerReadMarker('session')['revision'], 1);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 2);
    expect(native.calls.where((call) => '${call['path']}'.contains('/answers')).length, 2);
    native.snapshot(); await tester.pumpAndSettle();
    expect(native.calls.where((call) => '${call['path']}'.contains('/answers')).length, 2);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    await unmountSession(tester, c, native);
  });
  testWidgets('background and dialog-covered routes clear their owner and do not read incoming revisions', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native);
    final owner = native.readers.last['owner'];
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(native.readers.last['owner'], owner);
    expect(native.readers.last['atLatest'], isFalse);
    native.latestRevision = 2; native.snapshot(); native.upsert(answer(3, revision: 2));
    await tester.pumpAndSettle();
    expect(native.reads.length, 1);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(native.reads.last['revision'], 2);
    final context = tester.element(find.byType(SessionScreen));
    unawaited(showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('Örtü'))));
    await tester.pumpAndSettle();
    expect(native.readers.last['atLatest'], isFalse);
    native.latestRevision = 3; native.snapshot(); native.upsert(answer(3, revision: 3));
    await tester.pumpAndSettle();
    expect(native.reads.length, 2);
    Navigator.of(tester.element(find.text('Örtü'))).pop(); await tester.pumpAndSettle();
    expect(native.reads.last['revision'], 3);
    expect(native.readers.last['atLatest'], isTrue);
    await unmountSession(tester, c, native);
  });
  testWidgets('an uncached older answer resolves its reference without reading later sources in its turn', (tester) async {
    final native = VisibilityNative();
    native.messages.removeWhere((message) => message['id'] == 'user-2' || message['id'] == 'user-3');
    final c = await mountSession(tester, native, initialMessageId: 'answer-1');
    expect(native.reads, isNotEmpty);
    expect(native.reads.map((call) => call['ordinal']), everyElement(1));
    expect(find.text('Yanıt 3'), findsNothing);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 2);
    await unmountSession(tester, c, native);
  });
  testWidgets('read persistence failure stays unread without automatic retry on rebuild', (tester) async {
    final native = VisibilityNative()..failRead = true;
    final c = await mountSession(tester, native);
    expect(native.reads.length, 1);
    expect(find.textContaining('Disk dolu'), findsOneWidget);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 3);
    native.failRead = false;
    native.snapshot(); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(native.reads.length, 1);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); await tester.pumpAndSettle();
    expect(native.reads.length, 2);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 0);
    expect(find.textContaining('Disk dolu'), findsNothing);
    await unmountSession(tester, c, native);
  });
  testWidgets('scrolling to an uncached older source reads only that visible source', (tester) async {
    final native = VisibilityNative()..latestRevision = 2;
    native.messages[5] = answer(3, text: List.generate(12, (n) => 'Son yanıtın satırı $n.').join('\n\n'));
    final c = await mountSession(tester, native);
    expect(native.reads, isEmpty);
    tester.widget<ListView>(find.byType(ListView).first).controller!.jumpTo(400); await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('answer-end:answer-2'))), alignment: .5);
    await tester.pumpAndSettle();
    expect(native.reads, isNotEmpty);
    expect(native.reads.last['ordinal'], 2);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 1);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    await unmountSession(tester, c, native);
  });
  testWidgets('a missing initial target stays unread instead of falling back to latest', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native, initialMessageId: 'missing-answer');
    expect(find.textContaining('Aranan mesaj geçmişte bulunamadı'), findsOneWidget);
    expect(native.reads, isEmpty);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 3);
    await unmountSession(tester, c, native);
  });
  testWidgets('new answers and revised latest while focused on old history remain unread', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native, firstUnread: true);
    native.count = 4; native.snapshot(); native.upsert(answer(4));
    await tester.pumpAndSettle();
    native.latestRevision = 2; native.snapshot(); native.upsert(answer(4, revision: 2));
    await tester.pumpAndSettle();
    expect(native.reads.map((call) => call['ordinal']), everyElement(1));
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 3);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    expect(find.text('Yanıt 4'), findsNothing);
    await unmountSession(tester, c, native);
  });
  testWidgets('disposing clears only its reader owner and schedules no new reads', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native);
    final owner = native.readers.last['owner'];
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
    expect(native.readers.last['owner'], owner); expect(native.readers.last['atLatest'], isFalse);
    final calls = native.calls.length;
    native.latestRevision = 2; native.snapshot(); native.upsert(answer(3, revision: 2));
    await tester.pumpAndSettle();
    expect(native.calls.length, calls);
    c.dispose(); await native.stream.close();
  });
  testWidgets('a branch reset cannot replace the selected old answer with a read of new latest', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native, firstUnread: true);
    native.generation = 'history-two';
    native.messages.clear();
    c.transcript('session').reset();
    native.snapshot(); native.upsert(answer(3));
    await tester.pumpAndSettle();
    expect(native.reads.map((call) => call['generation']), everyElement('history-one'));
    expect(c.unreadAnswerCount(c.snapshot.sessions.single), 3);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    expect(find.textContaining('geçmişi değişti'), findsOneWidget);
    await unmountSession(tester, c, native);
  });
  testWidgets('legacy user-message search finishes positioning without reading a later answer', (tester) async {
    final native = VisibilityNative();
    final c = await mountSession(tester, native, initialMessageId: 'user-1');
    expect(find.text('İstek 1').hitTestable(), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(native.reads, isEmpty);
    expect(native.readers.where((call) => call['atLatest'] == true), isEmpty);
    await unmountSession(tester, c, native);
  });
}
