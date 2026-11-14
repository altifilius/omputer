import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/interactions.dart';
import 'package:omputer/main.dart';
import 'package:omputer/models.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/session.dart';
import 'package:omputer/settings.dart';
import 'package:omputer/ui.dart';

Json answerRef(int ordinal, {int revision = 1}) => {
  'messageId': 'answer-$ordinal', 'revision': revision, 'sequence': ordinal * 2,
  'ordinal': ordinal, 'preview': 'Kaydedilmiş yanıt $ordinal',
  'timestamp': '2026-11-14T12:0$ordinal:00Z',
};
Json answerSession(String id, String projectId, {int count = 3, String generation = 'history-one', int revision = 1}) => {
  'id': id, 'projectId': projectId, 'name': 'Oturum $id', 'transport': 'rpc',
  'status': 'idle', 'writerConnected': true, 'workState': 'settled',
  'capabilities': ['session.prompt'],
  'answerSummary': {'generation': generation, 'count': count, 'latest': count == 0 ? null : answerRef(count, revision: revision)},
};
class AnswerNative implements NativeAdapter {
  final stream = StreamController<Object?>.broadcast(sync: true);
  final calls = <Json>[];
  Json sections = {};
  bool failRead = false;
  bool missingAnswer = false;
  Completer<Object?>? delayedRead;
  Completer<Object?>? delayedPreference;
  Completer<Object?>? delayedAnswers;
  Json? answerPage;
  Json data = {
    'journalEpoch': 'epoch-one', 'sequence': 10,
    'projects': [{'id': 'first', 'name': 'İlk proje'}, {'id': 'second', 'name': 'Diğer proje'}],
    'sessions': [answerSession('one', 'first'), answerSession('two', 'second', count: 1)],
    'interactions': [{'id': 'question', 'sessionId': 'one', 'projectId': 'first', 'title': 'Önce bu karar', 'method': 'input', 'status': 'pending'}],
  };
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
        if (failRead) throw PlatformException(code: 'storage', message: 'Okuma konumu kaydedilemedi');
        if (delayedRead != null) return delayedRead!.future;
        final read = object(sections['read']);
        read['session:${args!['sessionId']}'] = {
          'journalEpoch': args['expectedJournalEpoch'], 'generation': args['generation'],
          for (final key in ['messageId', 'revision', 'sequence', 'ordinal']) key: args[key],
        };
        sections = {...sections, 'read': read};
        return {'identity': 'pc:phone', 'sections': sections};
      case 'localStateSet':
        if (delayedPreference != null) return delayedPreference!.future;
        sections = {...sections, '${args!['section']}': {...object(sections[args['section']]), '${args['key']}': args['value']}};
        return {'identity': 'pc:phone', 'sections': sections};
      case 'request':
        final uri = Uri.parse('${args!['path']}');
        if (uri.path.endsWith('/answers')) {
          if (delayedAnswers != null) return delayedAnswers!.future;
          if (answerPage != null) return answerPage;
          final after = int.parse(uri.queryParameters['after'] ?? '0');
          return {'generation': 'history-one', 'count': 3, 'answers': [if (after < 3 && !missingAnswer) answerRef(after + 1)], 'hasMore': after + 1 < 3};
        }
        if (uri.path.endsWith('/messages')) return {'messages': [
          for (var n = 1; n <= 3; n++) ...[
            {'id': 'user-$n', 'role': 'user', 'sequence': n * 2 - 1, 'revision': 1, 'content': 'İstek $n'},
            {'role': 'assistant', ...answerRef(n), 'id': 'answer-$n', 'stopReason': 'stop', 'content': [{'type': 'text', 'text': 'Kaydedilmiş yanıt $n', 'phase': 'final_answer'}]},
          ],
        ], 'hasMore': false};
        if (uri.path == '/v1/snapshot') return data;
        throw StateError('Unexpected request $args');
    }
    throw StateError('Unexpected native method $method');
  }
}
Future<OmputerController> answerController(AnswerNative native) async {
  final c = OmputerController(adapter: native);
  await c.initialize();
  return c;
}
void main() {
  test('unread count uses answer ordinal and revision within exact epoch and generation', () {
    final summary = AnswerSummary.fromJson(object(answerSession('one', 'first')['answerSummary']));
    Json marker(int ordinal, {int revision = 1}) => {'journalEpoch': 'epoch-one', 'generation': 'history-one', ...answerRef(ordinal, revision: revision)};
    expect(summary.unreadCount({}, 'epoch-one'), 3);
    expect(summary.unreadCount(marker(1), 'epoch-one'), 2);
    expect(summary.unreadCount(marker(3), 'epoch-one'), 0);
    expect(summary.unreadCount(marker(4), 'epoch-one'), 3);
    expect(summary.unreadCount({...marker(3), 'sequence': 999}, 'epoch-one'), 1);
    expect(summary.unreadCount(marker(3), 'epoch-two'), 3);
    expect(summary.unreadCount({...marker(3), 'generation': 'other-history'}, 'epoch-one'), 3);
    final revised = AnswerSummary.fromJson(object(answerSession('one', 'first', revision: 2)['answerSummary']));
    expect(revised.unreadCount(marker(3), 'epoch-one'), 1);
    expect(revised.unreadCount(marker(3, revision: 2), 'epoch-one'), 0);
  });
  test('source-only revision preserves semantic unread position and round trips exact source', () {
    final original = answerRef(3);
    final metadata = {...original, 'sourceRevision': 2};
    final reference = AnswerReference.fromJson(metadata);
    expect(reference.toJson(), {...AnswerReference.fromJson(original).toJson(), 'sourceRevision': 2});
    final summary = AnswerSummary.fromJson({'generation': 'history-one', 'count': 3, 'latest': metadata});
    expect(summary.unreadCount({'journalEpoch': 'epoch-one', 'generation': 'history-one', ...original}, 'epoch-one'), 0);
    final corrected = AnswerSummary.fromJson({'generation': 'history-one', 'count': 3, 'latest': {...answerRef(3, revision: 3)}});
    expect(corrected.unreadCount({'journalEpoch': 'epoch-one', 'generation': 'history-one', ...original}, 'epoch-one'), 1);
  });
  test('source revision cache cannot regress when an older overlapping page completes late', () async {
    final native = AnswerNative()..delayedAnswers = Completer<Object?>();
    final c = await answerController(native);
    final pending = c.answerReferences(c.snapshot.sessions.first);
    final revisedSession = answerSession('one', 'first');
    revisedSession['answerSummary'] = {'generation': 'history-one', 'count': 3, 'latest': {...answerRef(3), 'sourceRevision': 2}};
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 11, 'sessions': [revisedSession]}});
    native.delayedAnswers!.complete({'generation': 'history-one', 'count': 3, 'answers': [answerRef(1), answerRef(2), answerRef(3)], 'hasMore': false});
    final references = await pending;
    expect(references.last.toJson()['sourceRevision'], 2);
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 12, 'sessions': [answerSession('one', 'first', count: 4)]}});
    expect(c.cachedAnswerReference(c.snapshot.sessions.first, 'answer-3')!.toJson()['sourceRevision'], 2);
    c.dispose(); await native.stream.close();
  });
  test('explicit source refresh bypasses an older cached metadata revision', () async {
    final native = AnswerNative()..answerPage = {'generation': 'history-one', 'count': 3,
      'answers': [answerRef(1), answerRef(2), answerRef(3)], 'hasMore': false};
    final c = await answerController(native);
    final session = c.snapshot.sessions.first;
    await c.answerReferences(session);
    native.answerPage = {'generation': 'history-one', 'count': 3,
      'answers': [{...answerRef(1), 'sourceRevision': 2}, answerRef(2), answerRef(3)], 'hasMore': false};
    expect((await c.answerReferences(session)).first.toJson()['sourceRevision'], isNull);
    final refreshed = await c.answerReferences(session, refresh: true);
    expect(refreshed.first.toJson()['sourceRevision'], 2);
    expect(refreshed.first.revision, 1);
    expect(native.calls.where((call) => '${call['path']}'.contains('/answers')), hasLength(2));
    c.dispose(); await native.stream.close();
  });
  test('refreshed latest source wins while semantic summary has not caught up', () async {
    final native = AnswerNative()..answerPage = {'generation': 'history-one', 'count': 3,
      'answers': [answerRef(1), answerRef(2), {...answerRef(3), 'sourceRevision': 2}], 'hasMore': false};
    final c = await answerController(native);
    final session = c.snapshot.sessions.first;
    final refs = await c.answerReferences(session, refresh: true);
    expect(refs.last.toJson()['sourceRevision'], 2);
    expect(c.cachedAnswerReference(session, 'answer-3')!.toJson()['sourceRevision'], 2);
    expect(c.cachedAnswerReference(session, 'answer-3')!.revision, 1);
    c.dispose(); await native.stream.close();
  });
  test('cached answer pages stop before an ordinal gap rather than jumping to latest', () async {
    final native = AnswerNative()..answerPage = {'generation': 'history-one', 'count': 3,
      'answers': [answerRef(1)], 'hasMore': true};
    final c = await answerController(native);
    final session = c.snapshot.sessions.first;
    await c.answerReferences(session);
    expect((await c.answerReferences(session)).map((ref) => ref.ordinal), [1]);
    native.answerPage = {'generation': 'history-one', 'count': 3, 'answers': [answerRef(2), answerRef(3)], 'hasMore': false};
    expect((await c.answerReferences(session, after: 1)).map((ref) => ref.ordinal), [2, 3]);
    c.dispose(); await native.stream.close();
  });
  test('first unread reference is cached by epoch and history generation without transcript loading', () async {
    final native = AnswerNative(); final c = await answerController(native);
    final first = await c.firstUnreadAnswer(c.snapshot.sessions.first);
    expect(first?.messageId, 'answer-1');
    final again = await c.firstUnreadAnswer(c.snapshot.sessions.first);
    expect(again?.messageId, 'answer-1');
    expect(native.calls.where((v) => '${v['path']}'.contains('/answers')).length, 1);
    expect(c.loadedTranscript('one'), isNull);
    c.dispose(); await native.stream.close();
  });
  test('late read acknowledgement cannot replace newer local preferences or read position', () async {
    final native = AnswerNative()..delayedRead = Completer<Object?>();
    final c = await answerController(native);
    final read = c.markAnswerRead(c.snapshot.sessions.first, AnswerReference.fromJson(answerRef(1)));
    c.localState = {'identity': 'pc:phone', 'sections': {'pins': {'session:one': true}, 'read': {'session:one': {
      'journalEpoch': 'epoch-one', 'generation': 'history-one', ...answerRef(3),
    }}}};
    native.delayedRead!.complete({'identity': 'pc:phone', 'sections': {'read': {'session:one': {
      'journalEpoch': 'epoch-one', 'generation': 'history-one', ...answerRef(1),
    }}}});
    await read;
    expect(object(object(c.localState['sections'])['pins'])['session:one'], isTrue);
    expect(c.unreadAnswerCount(c.snapshot.sessions.first), 0);
    c.dispose(); await native.stream.close();
  });
  test('same generation revised summary replaces cached reference and keeps it on later append', () async {
    final native = AnswerNative()..answerPage = {'generation': 'history-one', 'count': 3, 'answers': [answerRef(1), answerRef(2), answerRef(3)], 'hasMore': false};
    final c = await answerController(native);
    await c.answerReferences(c.snapshot.sessions.first);
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 11, 'sessions': [answerSession('one', 'first', revision: 2)]}});
    final revised = await c.answerReferences(c.snapshot.sessions.first, after: 2);
    expect(revised.first.revision, 2);
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 12, 'sessions': [answerSession('one', 'first', count: 4)]}});
    expect(c.cachedAnswerReference(c.snapshot.sessions.first, 'answer-3')?.revision, 2);
    c.dispose(); await native.stream.close();
  });
  test('overlapping earlier answer page survives bounded cache eviction', () async {
    final native = AnswerNative()..data['sessions'] = [answerSession('one', 'first', count: 500)];
    final c = await answerController(native);
    final session = c.snapshot.sessions.first;
    for (final after in [100, 200, 300]) {
      native.answerPage = {'generation': 'history-one', 'count': 500, 'answers': [
        for (var ordinal = after + 1; ordinal <= after + 100; ordinal++) answerRef(ordinal, revision: ordinal == 150 ? 2 : 1),
      ], 'hasMore': true};
      final page = await c.answerReferences(session, after: after);
      expect(page.map((answer) => answer.ordinal), [for (var ordinal = after + 1; ordinal <= after + 100; ordinal++) ordinal]);
    }
    expect(c.cachedAnswerReference(session, 'answer-101'), isNull);
    expect(c.cachedAnswerReference(session, 'answer-150')?.revision, 2);
    native.answerPage = {'generation': 'history-one', 'count': 500, 'answers': [
      for (var ordinal = 101; ordinal <= 200; ordinal++) answerRef(ordinal),
    ], 'hasMore': true};
    final earlier = await c.answerReferences(session, after: 100);
    expect(earlier.map((answer) => answer.messageId), [for (var ordinal = 101; ordinal <= 200; ordinal++) 'answer-$ordinal']);
    expect(earlier.firstWhere((answer) => answer.ordinal == 150).revision, 2);
    final requests = native.calls.where((call) => '${call['path']}'.contains('/answers')).toList();
    expect(requests.map((call) => Uri.parse('${call['path']}').queryParameters['after']), ['100', '200', '300', '100']);
    expect(requests.every((call) => Uri.parse('${call['path']}').queryParameters['limit'] == '100'), isTrue);
    expect([for (var ordinal = 1; ordinal <= 500; ordinal++) c.cachedAnswerReference(session, 'answer-$ordinal')].whereType<AnswerReference>(), hasLength(256));
    c.dispose(); await native.stream.close();
  });
  test('snapshot answer appends keep reference cache bounded', () async {
    final native = AnswerNative()..data['sessions'] = [answerSession('one', 'first', count: 300)];
    final c = await answerController(native);
    for (final after in [0, 100, 200]) {
      native.answerPage = {'generation': 'history-one', 'count': 300, 'answers': [
        for (var ordinal = after + 1; ordinal <= after + 100; ordinal++) answerRef(ordinal),
      ], 'hasMore': after < 200};
      await c.answerReferences(c.snapshot.sessions.first, after: after);
    }
    expect([for (var ordinal = 1; ordinal <= 300; ordinal++) c.cachedAnswerReference(c.snapshot.sessions.first, 'answer-$ordinal')].whereType<AnswerReference>(), hasLength(256));
    for (var ordinal = 301; ordinal <= 600; ordinal++) {
      native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': ordinal, 'sessions': [answerSession('one', 'first', count: ordinal)]}});
    }
    final session = c.snapshot.sessions.first;
    expect([for (var ordinal = 1; ordinal <= 600; ordinal++) c.cachedAnswerReference(session, 'answer-$ordinal')].whereType<AnswerReference>(), hasLength(256));
    expect(c.cachedAnswerReference(session, 'answer-300'), isNull);
    expect(c.cachedAnswerReference(session, 'answer-600')?.ordinal, 600);
    c.dispose(); await native.stream.close();
  });
  test('nonempty answer page cannot skip the first unread ordinal', () async {
    final native = AnswerNative()..answerPage = {'generation': 'history-one', 'count': 3, 'answers': [answerRef(3)], 'hasMore': false};
    final c = await answerController(native);
    await expectLater(c.firstUnreadAnswer(c.snapshot.sessions.first), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'answer_unavailable')));
    expect(c.unreadAnswerCount(c.snapshot.sessions.first), 3);
    c.dispose(); await native.stream.close();
  });
  test('cached first unread from an old branch cannot open after snapshot replacement', () async {
    final native = AnswerNative(); final c = await answerController(native);
    final old = c.snapshot.sessions.first;
    await c.firstUnreadAnswer(old);
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 11, 'sessions': [answerSession('one', 'first', generation: 'new-history')]}});
    await expectLater(c.firstUnreadAnswer(old), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'history_changed')));
    c.dispose(); await native.stream.close();
  });
  test('late pin acknowledgement does not reopen an already read answer', () async {
    final native = AnswerNative()..delayedPreference = Completer<Object?>();
    final c = await answerController(native);
    final pin = c.updateLocalState('pins', 'session:one', true);
    await c.markAnswerRead(c.snapshot.sessions.first, c.snapshot.sessions.first.answerSummary!.latest!);
    native.delayedPreference!.complete({'identity': 'pc:phone', 'sections': {'pins': {'session:one': true}}});
    await pin;
    expect(c.unreadAnswerCount(c.snapshot.sessions.first), 0);
    expect(object(object(c.localState['sections'])['pins'])['session:one'], isTrue);
    c.dispose(); await native.stream.close();
  });
  test('missing exact source stays unread and stale acknowledgement cannot cross restored epoch', () async {
    final native = AnswerNative()..missingAnswer = true; final c = await answerController(native);
    await expectLater(c.firstUnreadAnswer(c.snapshot.sessions.first), throwsA(isA<ControllerFailure>().having((e) => e.code, 'code', 'answer_unavailable')));
    expect(c.unreadAnswerCount(c.snapshot.sessions.first), 3);
    native.delayedRead = Completer<Object?>();
    final read = c.markAnswerRead(c.snapshot.sessions.first, c.snapshot.sessions.first.answerSummary!.latest!);
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'journalEpoch': 'restored', 'sequence': 2}});
    native.delayedRead!.complete({'identity': 'pc:phone', 'sections': {'read': {'session:one': {'journalEpoch': 'epoch-one', 'generation': 'history-one', ...answerRef(3)}}}});
    await read;
    expect(c.snapshot.journalEpoch, 'restored'); expect(c.unreadAnswerCount(c.snapshot.sessions.first), 3);
    c.dispose(); await native.stream.close();
  });
  testWidgets('unopened session shows persisted final answer and unread state without loading transcript', (tester) async {
    final native = AnswerNative(); final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: LocalSessionRow(controller: c, session: c.snapshot.sessions.first))));
    await tester.pumpAndSettle();
    expect(find.text('Kaydedilmiş yanıt 3'), findsOneWidget);
    expect(find.textContaining('Okunmadı'), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);
    expect(c.loadedTranscript('one'), isNull);
    expect(native.calls.where((v) => v['method'] == 'request'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('inbox keeps decisions above grouped answers from every project without marking read', (tester) async {
    tester.view.physicalSize = const Size(393, 1400); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AnswerNative(); final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: c))));
    await tester.pumpAndSettle();
    expect(find.text('Yeni yanıtlar · 4'), findsOneWidget);
    expect(find.text('3 yeni yanıt'), findsOneWidget);
    expect(find.textContaining('Diğer proje'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Önce bu karar')).dy, lessThan(tester.getTopLeft(find.text('Yeni yanıtlar · 4')).dy));
    expect(native.calls.where((v) => v['method'] == 'answerRead'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('explicit read persists exact latest revision and a failed write keeps inbox unread', (tester) async {
    tester.view.physicalSize = const Size(393, 1400); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AnswerNative()..failRead = true; final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: c))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Okundu işaretle').first); await tester.pumpAndSettle();
    expect(find.text('3 yeni yanıt'), findsOneWidget);
    expect(find.textContaining('Okuma konumu kaydedilemedi'), findsOneWidget);
    native.failRead = false;
    await tester.pump(const Duration(seconds: 9)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Okundu işaretle').first); await tester.pumpAndSettle();
    expect(find.text('3 yeni yanıt'), findsNothing);
    final marker = object(object(native.sections['read'])['session:one']);
    expect(marker['ordinal'], 3); expect(marker['generation'], 'history-one'); expect(marker['journalEpoch'], 'epoch-one');
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose();
    final restarted = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: restarted))));
    await tester.pumpAndSettle(); expect(find.text('3 yeni yanıt'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink()); restarted.dispose(); await native.stream.close();
  });
  testWidgets('inbox first unread opens exact source', (tester) async {
    tester.view.physicalSize = const Size(393, 1400); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AnswerNative(); final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: c))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oturum one')); await tester.pumpAndSettle();
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.sessionId, 'one'); expect(screen.initialMessageId, 'answer-1');
    expect(native.calls.any((v) => '${v['path']}'.contains('after=0')), isTrue);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('delayed inbox lookup retains exact initiating session when list order changes', (tester) async {
    tester.view.physicalSize = const Size(393, 1400); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AnswerNative()..delayedAnswers = Completer<Object?>(); final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: c))));
    await tester.pumpAndSettle(); await tester.tap(find.text('Oturum one')); await tester.pump();
    final other = answerSession('two', 'second', count: 4);
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 11, 'sessions': [other, answerSession('one', 'first')]}});
    await tester.pump();
    native.delayedAnswers!.complete({'generation': 'history-one', 'count': 3, 'answers': [answerRef(1)], 'hasMore': true});
    await tester.pumpAndSettle();
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.sessionId, 'one'); expect(screen.initialMessageId, 'answer-1');
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('delayed inbox lookup survives a newly unread session prepended', (tester) async {
    tester.view.physicalSize = const Size(393, 1400); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AnswerNative()..delayedAnswers = Completer<Object?>(); final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: c))));
    await tester.pumpAndSettle(); await tester.tap(find.text('Oturum one')); await tester.pump();
    native.stream.add({'type': 'snapshot', 'data': {...native.data, 'sequence': 11, 'sessions': [
      ...objects(native.data['sessions']), answerSession('three', 'second', count: 4),
    ]}});
    await tester.pump();
    expect(tester.getTopLeft(find.text('Oturum three')).dy, lessThan(tester.getTopLeft(find.text('Oturum one')).dy));
    native.delayedAnswers!.complete({'generation': 'history-one', 'count': 3, 'answers': [answerRef(1)], 'hasMore': true});
    await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsOneWidget);
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.sessionId, 'one'); expect(screen.initialMessageId, 'answer-1');
    expect(screen.initialAnswer?.messageId, 'answer-1');
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('notification scope label includes decisions and new answers', (tester) async {
    tester.view.physicalSize = const Size(393, 1400); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final native = AnswerNative(); final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: SettingsScreen(controller: c)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Karar ve yanıt bildirimlerini göster'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Karar ve yanıt bildirimlerini göster'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('old PC exposes preview but explicitly reports missing unread capability', (tester) async {
    final native = AnswerNative()..data['sessions'] = [{'id': 'one', 'projectId': 'first', 'name': 'Eski oturum', 'lastAssistantText': 'Eski PC son yanıtı'}];
    final c = await answerController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: InboxScreen(controller: c))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Yeni yanıt takibi için bilgisayar uygulamasını güncelle'), findsOneWidget);
    expect(find.text('Yeni yanıtlar'), findsOneWidget);
    expect(find.text('Yeni yanıtlar · 0'), findsNothing);
    expect(find.text('Okunmamış yeni yanıt yok.'), findsNothing);
    expect(find.text('Okunmamış yanıt bilgisi bu bilgisayarda kullanılamıyor.'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: LocalSessionRow(controller: c, session: c.snapshot.sessions.first))));
    await tester.pumpAndSettle(); expect(find.text('Eski PC son yanıtı'), findsOneWidget);
    expect(native.calls.where((v) => v['method'] == 'answerRead'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
  });
  testWidgets('a delayed answer notification cannot cover a newer decision navigation', (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final native = AnswerNative()..delayedAnswers = Completer<Object?>(); final c = OmputerController(adapter: native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    native.stream.add({'type': 'navigate', 'data': {'sessionId': 'one', 'answer': true}}); await tester.pump(); await tester.pump();
    native.stream.add({'type': 'navigate', 'data': {'interactionId': 'question'}}); await tester.pumpAndSettle();
    expect(find.byType(InteractionScreen), findsOneWidget);
    native.delayedAnswers!.complete({'generation': 'history-one', 'count': 3, 'answers': [answerRef(1)], 'hasMore': true});
    await tester.pumpAndSettle();
    expect(find.byType(InteractionScreen), findsOneWidget); expect(find.byType(SessionScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink()); await native.stream.close();
  });
  testWidgets('Android answer navigation resolves first unread instead of silently opening latest', (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final native = AnswerNative(); final c = OmputerController(adapter: native);
    await tester.pumpWidget(OmputerApp(controller: c)); await tester.pumpAndSettle();
    native.stream.add({'type': 'navigate', 'data': {'sessionId': 'one', 'answer': true}});
    await tester.pumpAndSettle();
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).initialMessageId, 'answer-1');
    await tester.pumpWidget(const SizedBox.shrink()); await native.stream.close();
  });
  for (final brightness in Brightness.values) {
    testWidgets('answer inbox retains actions at 320dp and 200 percent in $brightness', (tester) async {
      tester.view.physicalSize = const Size(320, 900); tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
      final native = AnswerNative(); final c = await answerController(native);
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(brightness), home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2)), child: Scaffold(body: InboxScreen(controller: c)))));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('answer-read:one')), 150, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('answer-read:one')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink()); c.dispose(); await native.stream.close();
    });
  }
}
