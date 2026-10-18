import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session.dart';
import 'package:omputer/ui.dart';

Json sessionData(String status, List<String> capabilities, {String transport = 'archive'}) => {
  'id': 'session', 'projectId': 'project', 'name': 'Existing conversation',
  'status': status, 'transport': transport, 'capabilities': capabilities,
};

Json snapshotData(Json session) => {
  'sequence': 1,
  'projects': [
    {'id': 'project', 'name': 'Original project', 'path': '/work/project', 'activity': {'sessionId': 'session', 'goal': 'Continue the real work'}},
    {'id': 'other-project', 'name': 'Other project', 'path': '/work/other'},
  ],
  'sessions': [session],
};

class SessionAccessNative implements NativeAdapter {
  SessionAccessNative(this.data);
  final Json data;
  final List<Json> commands = [];
  final drafts = <String, Json>{};
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (['operationSave', 'removeAttachment'].contains(method)) return null;
    if (method == 'draftSave') { drafts['${arguments!['key']}'] = object(arguments['value']); return null; }
    if (method == 'draftDelete') { drafts.remove(arguments!['key']); return null; }
    if (method == 'draftLoad') return drafts[arguments!['key']];
    if (method == 'draftList') return drafts;
    if (method == 'localStateSet') return {'identity': 'test', 'sections': {}};
    if (['operationList', 'sharedImages', 'pickImages'].contains(method)) return [];
    if (method != 'request') throw StateError('Unexpected $method');
    final path = arguments!['path'] as String;
    if (path.contains('/messages')) return {'messages': [{'id': 'message', 'role': 'assistant', 'sequence': 1, 'content': 'Preserved terminal transcript'}], 'hasMore': false};
    if (path == '/v1/snapshot') return data;
    if (path == '/v1/commands') {
      commands.add(object(arguments['body']));
      return {'success': true};
    }
    throw StateError('Unexpected request $arguments');
  }
}

OmputerController controllerFor(SessionAccessNative native) => OmputerController(adapter: native)
  ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
  ..snapshot = Snapshot.fromJson(native.data);

Future<void> disposeScreen(WidgetTester tester, OmputerController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  for (final capabilities in <List<String>>[[], ['session.resume', 'session.prompt']]) {
    testWidgets('active-unbridged stays read-only even with capabilities $capabilities', (tester) async {
      final native = SessionAccessNative(snapshotData(sessionData('active-unbridged', capabilities)));
      final controller = controllerFor(native);
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: SessionScreen(controller: controller, sessionId: 'session')));
      await tester.pumpAndSettle();

      expect(find.byType(MessageView), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('session-resume')), findsNothing);
      final alternative = find.byKey(const ValueKey('session-new-project'));
      await tester.ensureVisible(alternative);
      await tester.tap(alternative);
      await tester.pumpAndSettle();

      final nextScreen = tester.widget<NewSessionScreen>(find.byType(NewSessionScreen));
      expect(nextScreen.projectId, 'project');
      expect(native.commands, isEmpty);
      await disposeScreen(tester, controller);
    });
  }

  testWidgets('archive without resume capability never offers resume', (tester) async {
    final native = SessionAccessNative(snapshotData(sessionData('inactive', [])));
    final controller = controllerFor(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-resume')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(native.commands, isEmpty);
    await disposeScreen(tester, controller);
  });

  testWidgets('inactive archive with resume capability sends one resume for the existing session', (tester) async {
    final native = SessionAccessNative(snapshotData(sessionData('inactive', ['session.resume'])));
    final controller = controllerFor(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session')));
    await tester.pumpAndSettle();
    final resume = find.byKey(const ValueKey('session-resume'));
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(native.commands.single['action'], 'session.resume');
    expect(native.commands.single['sessionId'], 'session');
    expect(object(native.commands.single['payload'])['sessionId'], 'session');
    await disposeScreen(tester, controller);
  });

  testWidgets('resume callback rechecks ownership after capability changes', (tester) async {
    final native = SessionAccessNative(snapshotData(sessionData('inactive', ['session.resume'])));
    final controller = controllerFor(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session')));
    await tester.pumpAndSettle();
    final oldButton = tester.widget<FilledButton>(find.byKey(const ValueKey('session-resume')));
    controller.snapshot = Snapshot.fromJson(snapshotData(sessionData('active-unbridged', [])));
    oldButton.onPressed!();
    await tester.pumpAndSettle();
    expect(native.commands, isEmpty);
    await disposeScreen(tester, controller);
  });

  testWidgets('live message-capable RPC retains composer and sends to the same session', (tester) async {
    final native = SessionAccessNative(snapshotData(sessionData('idle', ['session.prompt'], transport: 'rpc')));
    final controller = controllerFor(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-resume')), findsNothing);
    await tester.enterText(find.byType(TextField), 'Continue in this live session');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(native.commands.single['action'], 'session.prompt');
    expect(native.commands.single['sessionId'], 'session');
    expect(object(native.commands.single['payload'])['message'], 'Continue in this live session');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await disposeScreen(tester, controller);
  });
  for (final status in ['closed', 'failed', 'disconnected']) {
    testWidgets('$status runtime is read-only despite stale message capability and can resume with explicit capability', (tester) async {
      final native = SessionAccessNative(snapshotData(sessionData(status, ['session.prompt', 'session.resume'], transport: 'rpc')));
      final controller = controllerFor(native);
      await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('session-resume')), findsOneWidget);
      await disposeScreen(tester, controller);
    });
  }

  testWidgets('stale composer callback cannot send after runtime ownership is lost', (tester) async {
    final native = SessionAccessNative(snapshotData(sessionData('idle', ['session.prompt'], transport: 'rpc')));
    final controller = controllerFor(native);
    await tester.pumpWidget(MaterialApp(home: SessionScreen(controller: controller, sessionId: 'session')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();
    final button = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded));
    controller.snapshot = Snapshot.fromJson(snapshotData(sessionData('disconnected', ['session.prompt'], transport: 'rpc')));
    button.onPressed!();
    await tester.pumpAndSettle();
    expect(native.commands, isEmpty);
    await disposeScreen(tester, controller);
  });

}
