import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/interactions.dart';
import 'package:omputer/models.dart';
import 'package:omputer/ui.dart';

class InteractionNative implements NativeAdapter {
  final List<Json> commands = [];
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'request' && arguments!['path'] == '/v1/commands') {
      commands.add(object(arguments['body']));
      return {'success': true};
    }
    if (method == 'request' && arguments!['path'] == '/v1/snapshot') return {'sequence': 2, 'interactions': [question('resolved')]};
    throw StateError('Unexpected $method $arguments');
  }
}
Json question(String status) => {'id': 'request', 'sessionId': 'session', 'projectId': 'project', 'method': 'ask', 'title': 'Migration choices', 'status': status, 'questions': [{'id': 'q', 'question': 'Which data should remain?', 'multi': true, 'options': [{'label': 'Records'}, {'label': 'History'}, {'label': 'Indexes'}]}]};

void main() {
  testWidgets('multi-answer UI sends selected labels, not indexes', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending')]});
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: InteractionScreen(controller: controller, interactionId: 'request')));
    await tester.tap(find.text('Records'));
    await tester.pump();
    await tester.tap(find.text('History'));
    await tester.pump();
    await tester.tap(find.text('Records'));
    await tester.pump();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Yanıtları gönder'), 180, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yanıtları gönder'));
    await tester.pumpAndSettle();
    final answer = object(object(native.commands.single['payload'])['answer']);
    expect(answer['kind'], 'submit');
    expect(objects(answer['results']).single['selectedOptions'], ['History']);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('desktop answer disables an already-open mobile decision', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending')]});
    await tester.pumpWidget(MaterialApp(home: InteractionScreen(controller: controller, interactionId: 'request')));
    await tester.tap(find.text('History'));
    await tester.pump();
    controller.snapshot = Snapshot.fromJson({'sequence': 2, 'interactions': [question('resolved')]});
    controller.notifyListeners();
    await tester.pump();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Yanıtları gönder'), 180, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Yanıtları gönder'));
    expect(button.onPressed, isNull);
    expect(native.commands, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
