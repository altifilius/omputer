import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/pairing.dart';
import 'package:omputer/ui.dart';
import 'discovery_test.dart' show DiscoveryNative;

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
}
