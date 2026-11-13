import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/message_input.dart';
import 'package:omputer/ui.dart';

void main() {
  testWidgets('editable keeps its accessible name with a populated draft and focus', (tester) async {
    final controller = TextEditingController(text: 'Saklanan mesaj');
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: Scaffold(body: NeumorphicMessageInput(controller: controller, enabled: true))));
    final semantics = tester.ensureSemantics();
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.byType(EditableText)).label, contains('OMP’ye mesaj'));
    expect(tester.getSemantics(find.byType(EditableText)).value, 'Saklanan mesaj');
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.byType(EditableText)).label, contains('OMP’ye mesaj'));
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
    controller.dispose();
  });
}
