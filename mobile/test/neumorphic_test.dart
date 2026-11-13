import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/neumorphic.dart';
import 'package:omputer/ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} native controls retain names, focus, disabled and submit behavior', (tester) async {
      final text = TextEditingController();
      var submits = 0;
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(brightness), home: Scaffold(body: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        TextField(controller: text, decoration: const InputDecoration(labelText: 'Proje hedefi')),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => submits++, child: const Text('Kaydet')),
        const SizedBox(height: 24),
        const OutlinedButton(onPressed: null, child: Text('Şu an kullanılamıyor')),
      ])))));
      final semantics = tester.ensureSemantics();
      await tester.enterText(find.byType(TextField), 'Kayıtlı hedefi koru');
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasFocus, isTrue);
      expect(tester.getSemantics(find.byType(EditableText)).value, 'Kayıtlı hedefi koru');
      final save = find.widgetWithText(FilledButton, 'Kaydet');
      final gesture = await tester.startGesture(tester.getCenter(save));
      await tester.pump();
      expect(submits, 0);
      expect(find.descendant(of: save, matching: find.byWidgetPredicate((widget) => widget is NeoSurface && widget.depth == NeoDepth.inset)), findsOneWidget);
      await gesture.up(); await tester.pumpAndSettle();
      expect(submits, 1);
      expect(text.text, 'Kayıtlı hedefi koru');
      final disabled = find.widgetWithText(OutlinedButton, 'Şu an kullanılamıyor');
      expect(tester.widget<OutlinedButton>(disabled).onPressed, isNull);
      expect(tester.getSemantics(disabled).getSemanticsData().flagsCollection.isEnabled.toBoolOrNull(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose(); text.dispose();
    });
  }
}
