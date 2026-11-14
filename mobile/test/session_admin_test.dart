import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session_admin.dart';

class AdminNative implements NativeAdapter {
  final commands = <Json>[];
  final persisted = <Json>[];
  Json settings = {'settings': [
    {'key': 'retry.enabled', 'label': 'Retry enabled', 'description': 'Retry recoverable failures', 'type': 'boolean', 'value': true, 'provenance': 'session'},
  ]};
  Json providers = {'providers': [
    {'id': 'anthropic', 'name': 'Anthropic', 'authenticated': true, 'accounts': [
      {'credentialId': 'account-one', 'label': 'Work account', 'type': 'oauth'},
    ]},
  ]};
  final Json snapshot = {'sequence': 1, 'projects': [{'id': 'project', 'name': 'Project'}], 'sessions': [
    {'id': 'session', 'projectId': 'project', 'name': 'Live', 'transport': 'rpc', 'status': 'idle', 'writerConnected': true, 'journalId': 'journal', 'bindingRevision': 'binding', 'capabilities': ['session.command', 'session.control', 'session.prompt']},
  ]};
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'operationSave') { persisted.add(object(arguments!['operation'])); return null; }
    if (method == 'operationList') return [];
    if (method != 'request') throw StateError('Unexpected $method $arguments');
    final path = '${arguments!['path']}';
    if (path == '/v1/snapshot') return snapshot;
    if (path.contains('/control?')) {
      final view = Uri.parse(path).queryParameters['view'];
      if (view == 'commands') return {'catalogRevision': 'admin-r1', 'journalId': 'journal', 'bindingRevision': 'binding', 'commands': [
        for (final name in ['settings', 'login', 'logout', 'skills']) {'id': 'builtin:$name', 'name': name, 'risk': 'execute', 'available': true},
      ]};
      return view == 'settings' ? settings : providers;
    }
    if (path == '/v1/commands') { commands.add(object(arguments['body'])); return {'success': true, 'data': {}}; }
    throw StateError('Unexpected request $arguments');
  }
}

OmputerController adminController(AdminNative native) => OmputerController(adapter: native)
  ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
  ..snapshot = Snapshot.fromJson(native.snapshot)
  ..localState = {'identity': 'pc', 'sections': {}};

Future<void> closeAdmin(WidgetTester tester, OmputerController controller) async {
  await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
}

void main() {
  testWidgets('boolean setting stays typed and identity fenced after explicit confirmation', (tester) async {
    final native = AdminNative(); final controller = adminController(native);
    await tester.pumpWidget(MaterialApp(home: SessionAdminScreen(controller: controller, sessionId: 'session', view: 'settings'))); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Değiştir')); await tester.tap(find.text('Değiştir')); await tester.pumpAndSettle();
    expect(native.commands, isEmpty); expect(find.textContaining('Yeni değer: false'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula')); await tester.pumpAndSettle();
    expect(native.commands, hasLength(1)); expect(native.commands.single['action'], 'session.command');
    final payload = object(native.commands.single['payload']);
    expect(payload, containsPair('commandId', 'builtin:settings')); expect(payload, containsPair('catalogRevision', 'admin-r1'));
    expect(payload, containsPair('expectedJournalId', 'journal')); expect(payload, containsPair('expectedBindingRevision', 'binding')); expect(payload, containsPair('confirmed', true));
    final args = object(jsonDecode(payload['args'] as String));
    expect(args, {'action': 'set', 'key': 'retry.enabled', 'scope': 'session', 'value': false}); expect(args['value'], isA<bool>());
    await closeAdmin(tester, controller);
  });
  testWidgets('saved setting scope is explicit and cancelling leaves the host unchanged', (tester) async {
    final native = AdminNative(); final controller = adminController(native);
    await tester.pumpWidget(MaterialApp(home: SessionAdminScreen(controller: controller, sessionId: 'session', view: 'settings'))); await tester.pumpAndSettle();
    await tester.tap(find.text('Kalıcı bilgisayar ayarı')); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Değiştir')); await tester.tap(find.text('Değiştir')); await tester.pumpAndSettle();
    expect(find.textContaining('Kalıcı bilgisayar ayarı'), findsWidgets); await tester.tap(find.widgetWithText(TextButton, 'Vazgeç')); await tester.pumpAndSettle(); expect(native.commands, isEmpty);
    await tester.tap(find.text('Değiştir')); await tester.pumpAndSettle(); await tester.tap(find.widgetWithText(FilledButton, 'Uygula')); await tester.pumpAndSettle();
    expect(object(jsonDecode(object(native.commands.single['payload'])['args'] as String))['scope'], 'saved');
    await closeAdmin(tester, controller);
  });
  testWidgets('credential setting starts protected input without rendering or persisting an inline secret', (tester) async {
    final native = AdminNative()..settings = {'settings': [
      {'key': 'provider.apiKey', 'label': 'Provider credential', 'description': 'Protected provider key', 'type': 'string', 'credential': true, 'provenance': 'saved'},
    ]};
    final controller = adminController(native);
    await tester.pumpWidget(MaterialApp(home: SessionAdminScreen(controller: controller, sessionId: 'session', view: 'settings'))); await tester.pumpAndSettle();
    expect(find.text('Gizli değer · gösterilmez'), findsOneWidget); expect(find.byType(TextField), findsOneWidget);
    await tester.ensureVisible(find.text('Değiştir')); await tester.tap(find.text('Değiştir')); await tester.pumpAndSettle();
    expect(find.textContaining('Gizli değer ayrı korumalı girişte sorulacak'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); expect(native.commands, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula')); await tester.pumpAndSettle();
    final args = object(jsonDecode(object(native.commands.single['payload'])['args'] as String));
    expect(args, {'action': 'set', 'key': 'provider.apiKey', 'scope': 'session'}); expect(args.containsKey('value'), false);
    expect(native.persisted.every((operation) => object(object(operation['request'])['payload'])['args'] == '[korumalı yönetim argümanları]'), true);
    expect(find.byType(TextField), findsOneWidget); await closeAdmin(tester, controller);
  });
  testWidgets('account setup resolves login and logout catalog entries rather than the screen name', (tester) async {
    final native = AdminNative(); final controller = adminController(native);
    await tester.pumpWidget(MaterialApp(home: SessionAdminScreen(controller: controller, sessionId: 'session', view: 'setup'))); await tester.pumpAndSettle();
    await tester.tap(find.text('Hesap ekle')); await tester.pumpAndSettle(); expect(native.commands, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula')); await tester.pumpAndSettle();
    expect(object(native.commands.single['payload'])['commandId'], 'builtin:login');
    expect(object(jsonDecode(object(native.commands.single['payload'])['args'] as String)), {'action': 'login', 'providerId': 'anthropic'});
    final logout = find.byTooltip('Bu hesaptan çık'); await tester.ensureVisible(logout); await tester.tap(logout); await tester.pumpAndSettle();
    expect(native.commands, hasLength(1)); expect(find.textContaining('Work account'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Uygula')); await tester.pumpAndSettle();
    expect(native.commands, hasLength(2)); expect(object(native.commands.last['payload'])['commandId'], 'builtin:logout');
    expect(object(jsonDecode(object(native.commands.last['payload'])['args'] as String)), {'action': 'logout', 'providerId': 'anthropic', 'credentialId': 'account-one'});
    await closeAdmin(tester, controller);
  });
}
