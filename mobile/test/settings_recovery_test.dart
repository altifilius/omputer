import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/settings.dart';
import 'package:omputer/ui.dart';

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
    if (method == 'theme') return null;
    if (method == 'background') { background = args!['enabled'] == true; return {...state, 'background': background}; }
    throw StateError('Unexpected $method');
  }
}

void main() {
  testWidgets('notification denial leaves background off and the user can retry after granting permission', (tester) async {
    final native = PermissionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true});
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: Scaffold(body: SettingsScreen(controller: controller))));
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
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: SettingsScreen(controller: controller))));
    final preference = find.widgetWithText(CheckboxListTile, 'Scoped project');
    await tester.scrollUntilVisible(preference, 250, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(preference), alignment: .5);
    await tester.pumpAndSettle();
    expect(preference.hitTestable(), findsOneWidget);
    await tester.tap(preference);
    await tester.pumpAndSettle();
    expect(object(object(controller.localState['sections'])['notificationPreferences'])['project:p'], isFalse);
    expect(native.calls.where((call) => call == 'localStateSet'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
  testWidgets('appearance menu retains exact choices and persists the selected theme', (tester) async {
    final native = PermissionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true});
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: Scaffold(body: SettingsScreen(controller: controller))));
    final theme = find.byType(DropdownButtonFormField<String>);
    await tester.scrollUntilVisible(theme, 250, scrollable: find.byType(Scrollable).first);
    await tester.tap(theme);
    await tester.pumpAndSettle();
    expect(find.text('Sistemle aynı'), findsWidgets);
    expect(find.text('Açık · sis grisi'), findsOneWidget);
    expect(find.text('Koyu · grafit'), findsOneWidget);
    await tester.tap(find.text('Koyu · grafit'));
    await tester.pumpAndSettle();
    expect(controller.theme, 'dark');
    expect(native.calls.where((call) => call == 'theme'), hasLength(1));
    expect(find.text('Koyu · grafit'), findsOneWidget);
    expect(find.text('Yazı boyutu ve Animasyonları kaldır tercihi Android erişilebilirlik ayarlarından izlenir.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
}
