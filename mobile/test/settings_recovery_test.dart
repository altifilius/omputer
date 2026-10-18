import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/settings.dart';

class PermissionNative implements NativeAdapter {
  bool allowed = false, background = false;
  final calls = <String>[];
  final sections = <String, dynamic>{};
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    calls.add(method);
    if (method == 'localStateSet') { final section = sections.putIfAbsent('${args!['section']}', () => <String, dynamic>{}) as Json; section['${args['key']}'] = args['value']; return {'identity': 'test', 'sections': sections}; }
    final state = {'paired': true, 'connected': true, 'notifications': allowed, 'background': background};
    if (method == 'connection') return state;
    if (method == 'snapshot') return {'sequence': 1};
    if (method == 'localState') return {'identity': 'test', 'sections': sections};
    if (method == 'operationList') return <Json>[];
    if (method == 'preferences') return {'theme': 'system'};
    if (method == 'notifications') return allowed;
    if (method == 'background') { background = args!['enabled'] == true; return {...state, 'background': background}; }
    throw StateError('Unexpected $method');
  }
}

void main() {
  testWidgets('notification denial leaves background off and the user can retry after granting permission', (tester) async {
    final native = PermissionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(controller: controller))));
    final toggle = find.byType(SwitchListTile);
    await tester.scrollUntilVisible(toggle, 250, scrollable: find.byType(Scrollable).first);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(native.calls.where((method) => method == 'background'), isEmpty);
    expect(controller.connection.background, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    native.allowed = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(native.calls.where((method) => method == 'background'), hasLength(1));
    expect(controller.connection.background, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('project notification preference stays scoped to paired local state', (tester) async {
    final native = PermissionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'projects': [{'id': 'p', 'name': 'Scoped project'}]});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(controller: controller))));
    await tester.scrollUntilVisible(find.text('Scoped project'), 250, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Scoped project'));
    await tester.pumpAndSettle();
    expect(object(object(controller.localState['sections'])['notificationPreferences'])['project:p'], isFalse);
    expect(native.calls.where((call) => call == 'localStateSet'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
}
