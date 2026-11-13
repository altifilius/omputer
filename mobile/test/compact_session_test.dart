import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/compact_turn.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session.dart';
import 'package:omputer/ui.dart';
import 'session_access_test.dart' show SessionAccessNative, controllerFor, snapshotData, sessionData;

class TurnNative extends SessionAccessNative {
  TurnNative() : super(snapshotData(sessionData('running', ['session.prompt'], transport: 'rpc')));
  final rows = <Json>[
    {'id':'prompt','role':'user','sequence':1,'content':'Kaydı kontrol et'},
    {'id':'progress','role':'assistant','sequence':2,'stopReason':'toolUse','content':[
      {'type':'thinking','thinking':'Private reasoning must not render'},
      {'type':'text','text':'Internal progress must not render','textSignature':'{"v":1,"id":"progress","phase":"commentary"}'},
      {'type':'toolCall','id':'call','name':'read','arguments':{'path':'secret-path'}},
    ]},
    {'id':'result','role':'toolResult','sequence':3,'toolCallId':'call','toolName':'read','content':'Raw result must not render'},
    {'id':'answer','role':'assistant','sequence':4,'revision':1,'stopReason':'stop','content':[{'type':'text','text':'Cevap hazır','textSignature':'{"v":1,"id":"answer","phase":"final_answer"}'}]},
  ];
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method=='request' && '${arguments?['path']}'.contains('/messages')) return {'messages':rows,'hasMore':false};
    return super.invoke(method,arguments);
  }
}

void main() {
  testWidgets('one session turn hides internals and refreshes exact answer revisions', (tester) async {
    final native=TurnNative();final controller=controllerFor(native);
    await tester.pumpWidget(MaterialApp(theme:omputerTheme(Brightness.dark),home:SessionScreen(controller:controller,sessionId:'session')));
    await tester.pumpAndSettle();
    expect(find.byType(CompactTurnView),findsOneWidget);
    expect(find.text('Cevap hazır'),findsOneWidget);
    expect(find.textContaining('Private reasoning'),findsNothing);
    expect(find.textContaining('Internal progress'),findsNothing);
    expect(find.textContaining('Raw result'),findsNothing);
    expect(find.textContaining('secret-path'),findsNothing);
    final transcript=controller.transcript('session');
    transcript.upsert(ChatMessage.fromJson({...native.rows.last,'revision':2,'content':[{'type':'text','text':'Güncel cevap','textSignature':'{"v":1,"id":"answer","phase":"final_answer"}'}]}));
    await tester.pumpAndSettle();
    expect(find.text('Cevap hazır'),findsNothing);
    expect(find.text('Güncel cevap'),findsOneWidget);
    expect(transcript.messages['progress']!.value.content.first['thinking'],'Private reasoning must not render');
    transcript.reset();
    transcript.upsert(ChatMessage.fromJson({'id':'fresh','role':'assistant','sequence':1,'stopReason':'stop','content':'Yeni dal cevabı'}));
    await tester.pumpAndSettle();
    expect(find.text('Güncel cevap'),findsNothing);
    expect(find.text('Yeni dal cevabı'),findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());controller.dispose();
  });

  testWidgets('hidden tool search target opens its safe operation context without raw output', (tester) async {
    final native=TurnNative();final controller=controllerFor(native);
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    native.rows.last['content'] = [{'type':'text','text':List.filled(18, 'Uzun gerçek yanıt okunabilir kalır.').join('\n\n'),'textSignature':'{"v":1,"id":"answer","phase":"final_answer"}'}];
    await tester.pumpWidget(MaterialApp(theme:omputerTheme(Brightness.light),home:SessionScreen(controller:controller,sessionId:'session',initialMessageId:'result')));
    await tester.pumpAndSettle();
    expect(find.text('Arama sonucu konumunda okuyorsun'),findsOneWidget);
    expect(find.byType(CompactTurnView),findsOneWidget);
    expect(find.textContaining('read'),findsWidgets);
    final target = find.byKey(const ValueKey('compact-message:result'));
    final viewport = find.ancestor(of: find.byType(CompactTurnView), matching: find.byType(ListView));
    final targetBounds = tester.getRect(target);
    final viewBounds = tester.getRect(viewport);
    expect(targetBounds.top, greaterThanOrEqualTo(viewBounds.top));
    expect(targetBounds.bottom, lessThanOrEqualTo(viewBounds.bottom));
    expect(find.text('Araç · read').hitTestable(), findsOneWidget);
    expect(find.text('Son mesaja git'), findsNothing);
    expect(find.textContaining('Raw result'),findsNothing);
    expect(find.textContaining('Private reasoning'),findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());controller.dispose();
  });
}
