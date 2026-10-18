import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/pairing.dart';
import 'package:omputer/ui.dart';
import 'discovery_test.dart' show DiscoveryNative;

class BundleNative extends DiscoveryNative {
  bool paired = false;
  @override
  Future<Object?> invoke(String method, [Json? args]) async {
    if (method == 'previewBundle') {
      calls.add((method, args));
      return {'serverId': 'second-pc', 'serverName': 'Second PC', 'url': 'https://192.168.1.9:9999', 'fingerprint': 'AA:BB:CC:DD', 'existingPair': paired};
    }
    if (method == 'pair') { calls.add((method, args)); paired = true; return {}; }
    if (method == 'connect' || method == 'connection') {
      calls.add((method, args));
      return {'paired': paired, 'connected': paired, 'notifications': false};
    }
    return super.invoke(method, args);
  }
}

void main() {
  testWidgets('selecting a discovered PC shows its verification code without authorizing early', (tester) async {
    final native = DiscoveryNative();
    final controller = OmputerController(adapter: native);
    await controller.initialize();
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: PairingScreen(controller: controller)));
    await tester.pump();
    native.stream.add({'type': 'discovery', 'data': {'scanning': true, 'computers': [{'id': 'pc-a', 'name': 'Work computer', 'fingerprint': 'pin'}]}});
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Work computer'), 180, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work computer'));
    await tester.pump();
    await tester.pump();
    expect(find.text('123456'), findsOneWidget);
    expect(controller.connection.paired, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await native.stream.close();
  });
  for (final approve in [false, true]) {
    testWidgets('external bundle requires trust confirmation before ${approve ? 'replacing' : 'preserving'} paired data', (tester) async {
      final native = BundleNative()..paired = true;
      final controller = OmputerController(adapter: native);
      await controller.initialize();
      controller.snapshot = Snapshot.fromJson({'sequence': 99, 'projects': [{'id': 'saved', 'summary': 'Private cached project'}]});
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: PairingScreen(controller: controller, initialBundle: 'external-bundle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('AA:BB:CC:DD'), findsOneWidget);
      expect(native.calls.any((call) => ['pair', 'pairCancel', 'notifications', 'background'].contains(call.$1)), isFalse);
      expect(controller.snapshot.project('saved'), isNotNull);
      await tester.tap(find.widgetWithText(approve ? FilledButton : TextButton, approve ? 'Değiştir ve eşleştir' : 'Vazgeç'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(native.calls.where((call) => call.$1 == 'pair'), hasLength(approve ? 1 : 0));
      if (approve) {
        expect(controller.snapshot.project('saved'), isNull);
      } else {
        expect(controller.snapshot.project('saved')!.summary, 'Private cached project');
        expect(native.calls.any((call) => ['pairCancel', 'notifications', 'background'].contains(call.$1)), isFalse);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await native.stream.close();
    });
  }
}
