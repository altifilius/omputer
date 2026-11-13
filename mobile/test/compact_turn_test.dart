import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/compact_turn.dart';
import 'package:omputer/models.dart';
import 'package:omputer/ui.dart';

ChatMessage message(String id, List<Json> blocks, {String role = 'assistant', String? stop,
  String? callId, String? toolName, bool error = false, int revision = 0}) => ChatMessage.fromJson({
  'id': id, 'role': role, 'content': blocks, 'stopReason': stop,
  'toolCallId': callId, 'toolName': toolName, 'isError': error, 'revision': revision,
});
Json text(String value, {String? phase, String? signature}) => {
  'type': 'text', 'text': value, if (phase != null) 'phase': phase,
  if (signature != null) 'textSignature': signature,
};
Json call(String id, String name) => {'type': 'toolCall', 'id': id, 'name': name,
  'arguments': {'command': 'SECRET_COMMAND', 'token': 'SECRET_ARGUMENT'}};
String signature(String phase) => jsonEncode({'v': 1, 'id': 'text-1', 'phase': phase});

Widget screen(List<ChatMessage> messages, {bool active = false, String? focus,
  double scale = 1, void Function(String, int?)? onOpenFile}) => MaterialApp(
  theme: omputerTheme(Brightness.dark),
  home: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: SingleChildScrollView(child: CompactTurnView(
      messages: messages, active: active, focusedMessageId: focus, onOpenFile: onOpenFile)))),
);

void main() {
  test('block phase and JSON v1 signature preserve final text in mixed payloads', () {
    final result = projectCompactTurn([message('a', [
      text('SECRET_COMMENTARY', signature: signature('commentary')),
      {'type': 'thinking', 'thinking': 'SECRET_THINKING'},
      text('Birinci yanıt', signature: signature('final_answer')),
      text('SECRET_COMMENTARY_2', phase: 'commentary'),
      text('Sorunuz burada', phase: 'final_answer'),
      call('c', 'read'),
    ], stop: 'toolUse')]);
    expect(result.copyText, 'Birinci yanıt\n\nSorunuz burada');
    expect(result.operations.map((step) => step.label), [
      'Çalışma güncellendi', 'Düşünme', 'Çalışma güncellendi', 'Araç · read',
    ]);
    expect(result.operations.last.state, CompactOperationState.unknown);
  });

  test('unknown and malformed signatures remain legacy text without question heuristics', () {
    final signatures = ['not json', '{', '[]', jsonEncode({'v': 2, 'id': 'x', 'phase': 'commentary'}),
      jsonEncode({'v': 1, 'id': 'x', 'phase': 'something_else'}), jsonEncode({'phase': 'commentary'})];
    final result = projectCompactTurn([
      for (var i = 0; i < signatures.length; i++) message('$i', [text('Yanıt $i', signature: signatures[i])]),
      message('question', [text('Nasıl devam edelim?')]),
    ]);
    expect(result.answers.length, signatures.length + 1);
    expect(result.operations, isEmpty);
    expect(result.copyText, contains('Nasıl devam edelim?'));
  });

  test('toolUse and embedded toolcalls suppress unmarked progress but explicit final survives', () {
    final result = projectCompactTurn([
      message('a', [text('SECRET_PROGRESS')], stop: 'toolUse'),
      message('b', [text('SECRET_PROGRESS_2'), call('c', 'bash'), text('Son yanıt', phase: 'final_answer')]),
      message('c', [text('Eski biçim yanıt')], stop: 'stop'),
    ], active: true);
    expect(result.copyText, 'Son yanıt\n\nEski biçim yanıt');
    expect(result.operations.where((step) => step.kind == 'commentary').length, 2);
    expect(result.operations.last.state, CompactOperationState.pending);
    expect(projectCompactTurn([message('x', [call('x', 'bash')])]).operations.single.state,
      CompactOperationState.unknown);
  });

  test('results match at call positions despite reverse completion or partial result-first pages', () {
    final result = projectCompactTurn([
      message('calls', [call('a', 'read'), call('b', 'write')], stop: 'toolUse'),
      message('b-result', [text('SECRET_RESULT_B')], role: 'toolResult', callId: 'b', error: true),
      message('a-result', [text('SECRET_RESULT_A')], role: 'toolResult', callId: 'a'),
    ]);
    expect(result.operations.map((step) => step.label), ['Araç · read', 'Araç · write']);
    expect(result.operations.map((step) => step.state), [CompactOperationState.completed, CompactOperationState.error]);
    expect(result.operations.first.messageIds, ['calls', 'a-result']);
    expect(result.operations.last.messageIds, ['calls', 'b-result']);
    expect(result.copyText, isEmpty);
    final resultFirst = projectCompactTurn([
      message('result', [text('SECRET_RESULT')], role: 'toolResult', callId: 'c'),
      message('call', [call('c', 'read')]),
    ]);
    expect(resultFirst.operations.length, 1);
    expect(resultFirst.operations.single.messageIds, ['call', 'result']);
  });

  test('reasoning collapses contiguous duplicates but not across an answer or tool', () {
    final result = projectCompactTurn([
      message('a', [
        {'type': 'thinking', 'thinking': 'SECRET_ONE'},
        {'type': 'reasoning', 'text': 'SECRET_TWO'},
        {'type': 'redactedThinking', 'data': 'SECRET_THREE'},
        text('Yanıt', phase: 'final_answer'),
        {'type': 'thinking', 'thinking': 'SECRET_FOUR'},
        call('c', 'read'),
        {'type': 'thinking', 'thinking': 'SECRET_FIVE'},
      ]),
      message('b', [{'type': 'reasoning', 'text': 'SECRET_SIX'}]),
    ]);
    expect(result.operations.map((step) => step.label), ['Düşünme', 'Düşünme', 'Araç · read', 'Düşünme']);
    expect(result.operations.last.messageIds, ['a', 'b']);
    expect(result.copyText, 'Yanıt');
  });

  test('limited interrupted and error endings retain answer and truthful statuses', () {
    final result = projectCompactTurn([
      message('limited', [text('Kısmi yanıt')], stop: 'length'),
      message('interrupted', [text('Kesilmeden önceki yanıt')], stop: 'aborted'),
      message('error', [text('Hata öncesi yanıt')], stop: 'error'),
    ]);
    expect(result.answers.length, 3);
    expect(result.operations.map((step) => step.state), [CompactOperationState.limited,
      CompactOperationState.interrupted, CompactOperationState.error]);
    expect(result.operations.any((step) => step.state == CompactOperationState.completed), isFalse);
  });

  test('result images and unknown role payloads never become answer material', () {
    final result = projectCompactTurn([
      message('result', [text('SECRET_RESULT'), {'type': 'image', 'data': 'SECRET_IMAGE'}], role: 'toolResult', toolName: 'read'),
      message('system', [text('SECRET_SYSTEM')], role: 'system'),
      message('unknown', [{'type': 'customType', 'content': {'secret': 'SECRET_CUSTOM'}}]),
      message('unsafe-name', [call('unsafe', 'echo SECRET_COMMAND')]),
    ]);
    expect(result.answers, isEmpty);
    expect(result.operations.map((step) => step.label), ['Araç · read', 'Kayıt · system', 'İçerik · customType', 'Araç · Araç çağrısı']);
    expect(result.copyText, isEmpty);
  });

  test('projection never mutates raw messages or nested tool payloads', () {
    final raw = <String, dynamic>{'id': 'a', 'role': 'assistant', 'content': [
      {'type': 'reasoning', 'text': 'SECRET_THINKING'}, call('c', 'read'),
      text('Son yanıt', signature: signature('final_answer')),
    ], 'stopReason': 'toolUse'};
    final input = ChatMessage.fromJson(raw);
    final before = jsonEncode(raw);
    final blocksBefore = jsonEncode(input.content);
    projectCompactTurn([input], active: true);
    expect(jsonEncode(raw), before);
    expect(jsonEncode(input.content), blocksBefore);
  });

  test('grouping retains individual users and AI identity over partial pages append and reset', () {
    final all = <ChatMessage>[
      message('u0', [text('İstem')], role: 'user'),
      for (var i = 1; i <= 53; i++) message('a$i', [text('Yanıt $i')]),
      message('u1', [text('İkinci istem')], role: 'user'),
      message('u2', [text('Ayrı istem')], role: 'user'),
      message('next', [text('Yeni yanıt')]),
    ];
    final notifiers = {for (final item in all) item.id: ValueNotifier(item)};
    addTearDown(() { for (final item in notifiers.values) { item.dispose(); } });
    final partial = all.sublist(4, 54);
    expect(partial.length, 50);
    final page = compactConversationEntries(partial.map((item) => item.id).toList(), notifiers);
    expect(page.single.id, 'a4');
    expect(page.single.messageIds.length, 50);
    final loaded = compactMessageEntries(all.sublist(0, 54));
    expect(loaded.map((entry) => entry.id), ['u0', 'a1']);
    final appended = compactMessageEntries(all);
    expect(appended.map((entry) => entry.id), ['u0', 'a1', 'u1', 'u2', 'next']);
    expect(appended.map((entry) => entry.isUser), [true, false, true, true, false]);
    expect(appended[1].messageIds.length, 53);
    final wrapped = compactConversationEntries(all.map((item) => item.id).toList(), notifiers);
    expect(wrapped.map((entry) => entry.messageIds), appended.map((entry) => entry.messageIds));
    expect(compactMessageEntries([all.last]).single.messageIds, ['next']);
    expect(compactConversationEntries([], notifiers), isEmpty);
    expect(compactConversationEntries(['missing', 'next'], notifiers).single.id, 'next');
  });

  testWidgets('expanded flow semantics and answer copy never expose private operation payloads', (tester) async {
    final semantics = tester.ensureSemantics();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (method) async {
      if (method.method == 'Clipboard.setData') copied = (method.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final messages = [
      message('a', [{'type': 'reasoning', 'text': 'SECRET_THINKING'},
        text('SECRET_COMMENTARY', phase: 'commentary'), call('c', 'read'), text('Görünen yanıt', phase: 'final_answer')]),
      message('r', [text('SECRET_RESULT')], role: 'toolResult', callId: 'c'),
    ];
    await tester.pumpWidget(screen(messages));
    expect(find.text('İşlem akışı · 3'), findsOneWidget);
    expect(find.text('Düşünme'), findsNothing);
    await tester.tap(find.text('İşlem akışı · 3'));
    await tester.pump();
    expect(find.text('Düşünme'), findsOneWidget);
    expect(find.text('Araç · read'), findsOneWidget);
    expect(find.byTooltip('Yanıtı kopyala'), findsOneWidget);
    await tester.tap(find.byTooltip('Yanıtı kopyala'));
    await tester.pump();
    expect(copied, 'Görünen yanıt');
    final semanticsText = tester.getSemantics(find.byType(CompactTurnView)).toStringDeep();
    expect(semanticsText, isNot(contains('SECRET_')));
    expect(find.textContaining('SECRET_'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('collapsed errors and missing results remain visible with no invented answer', (tester) async {
    await tester.pumpWidget(screen([
      message('calls', [call('missing', 'read'), call('error', 'write')]),
      message('error', [text('SECRET_ERROR_RESULT')], role: 'toolResult', callId: 'error', error: true),
    ]));
    expect(find.textContaining('1 hata'), findsOneWidget);
    expect(find.textContaining('1 sonuç kaydı yok'), findsOneWidget);
    expect(find.text('Yanıt hazırlanıyor'), findsNothing);
    expect(find.byTooltip('Yanıtı kopyala'), findsNothing);
  });

  testWidgets('active view shows last three ordered steps then all safe steps when expanded', (tester) async {
    await tester.pumpWidget(screen([message('a', [for (var i = 0; i < 5; i++) call('$i', 'tool$i')])], active: true));
    expect(find.text('2 önceki işlem'), findsOneWidget);
    expect(find.text('Araç · tool0'), findsNothing);
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('5.'), findsOneWidget);
    expect(find.text('Yanıt hazırlanıyor'), findsOneWidget);
    await tester.tap(find.text('İşlem akışı · 5'));
    await tester.pump();
    expect(find.text('Araç · tool0'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    await tester.pumpWidget(screen([message('a', [for (var i = 0; i < 5; i++) call('$i', 'tool$i')])]));
    expect(find.text('Araç · tool0'), findsNothing);
    expect(find.textContaining('5 sonuç kaydı yok'), findsOneWidget);
  });

  testWidgets('hidden result focus exposes exact safe source and operation order', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(screen([
      message('a', [call('one', 'read'), call('two', 'write')]),
      message('r', [text('SECRET_RESULT')], role: 'toolResult', callId: 'one'),
    ], focus: 'r'));
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('Araç · read'), findsOneWidget);
    final anchor = find.byKey(const ValueKey('compact-message:r'));
    expect(anchor, findsOneWidget);
    expect(tester.getSemantics(anchor).getSemanticsData().identifier, 'message:r');
    expect(find.bySemanticsLabel(RegExp('Seçili mesaj, işlem 1')), findsOneWidget);
    expect(find.textContaining('SECRET_'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('revised live message remount shows final answer without stale projection', (tester) async {
    await tester.pumpWidget(screen([message('a', [text('SECRET_PROGRESS', phase: 'commentary')], revision: 1)], active: true));
    expect(find.text('Yanıt hazırlanıyor'), findsOneWidget);
    await tester.pumpWidget(screen([message('a', [text('Canlı son yanıt', signature: signature('final_answer'))], stop: 'stop', revision: 2)]));
    expect(find.text('Yanıt hazırlanıyor'), findsNothing);
    expect(find.textContaining('Canlı son yanıt'), findsOneWidget);
    expect(find.byTooltip('Yanıtı kopyala'), findsOneWidget);
  });

  testWidgets('answer links retain exact project path and line', (tester) async {
    String? path;
    int? line;
    await tester.pumpWidget(screen([message('a', [text('[Kaynağı aç](lib/main.dart#L42)')])],
      onOpenFile: (value, number) { path = value; line = number; }));
    await tester.tap(find.text('Kaynağı aç'));
    await tester.pump();
    expect(path, 'lib/main.dart');
    expect(line, 42);
  });

  testWidgets('one response source menu preserves each exact answer message link', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (method) async {
      if (method.method == 'Clipboard.setData') copied = (method.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(screen([
      message('first-answer', [text('İlk yanıt', phase: 'final_answer')]),
      message('second-answer', [text('İkinci yanıt', phase: 'final_answer')]),
    ]));
    expect(find.byTooltip('Yanıtı kopyala'), findsOneWidget);
    await tester.tap(find.byTooltip('Yanıt kaynağının bağlantısını kopyala'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yanıt kaynağı 2'));
    await tester.pumpAndSettle();
    expect(copied, 'omputer://message/second-answer');
  });

  testWidgets('200 percent text wraps flow labels and answers on a phone without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(screen([
      message('a', [text('Bu yanıt dar telefonda büyük yazı boyutunda da okunabilir kalır.'), call('c', 'long_tool_operation_name')], stop: 'length'),
    ], focus: 'a', scale: 2));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Bu yanıt'), findsNothing); // Unmarked tool-call text is progress.
    await tester.pumpWidget(screen([message('a', [text('Bu yanıt dar telefonda büyük yazı boyutunda da okunabilir kalır.', phase: 'final_answer'), call('c', 'long_tool_operation_name')], stop: 'length')], focus: 'a', scale: 2));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Bu yanıt'), findsOneWidget);
  });
}
