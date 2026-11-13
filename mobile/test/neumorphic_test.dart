import 'package:flutter/material.dart';
import 'dart:ui' show SemanticsAction, SemanticsFlag, CheckedState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
    testWidgets('${brightness.name} primary action keeps text and icon contrast through surface states', (tester) async {
      var enabled = true;
      var submits = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(brightness), home: Scaffold(
        body: StatefulBuilder(builder: (context, update) {
          rebuild = update;
          return Center(child: FilledButton.icon(
            onPressed: enabled ? () => submits++ : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Oturumu başlat'),
          ));
        }),
      )));
      final button = find.widgetWithText(FilledButton, 'Oturumu başlat');
      final label = find.text('Oturumu başlat');
      final icon = find.byIcon(Icons.play_arrow_rounded);
      final scheme = Theme.of(tester.element(button)).colorScheme;
      Color labelColor() => tester.widget<RichText>(find.descendant(
        of: label, matching: find.byType(RichText))).text.style!.color!;
      Color iconColor() => IconTheme.of(tester.element(icon)).color!;
      expect(labelColor(), scheme.onPrimary);
      expect(iconColor(), scheme.onPrimary);
      final contrast = (scheme.primary.computeLuminance() > scheme.onPrimary.computeLuminance())
          ? (scheme.primary.computeLuminance() + .05) / (scheme.onPrimary.computeLuminance() + .05)
          : (scheme.onPrimary.computeLuminance() + .05) / (scheme.primary.computeLuminance() + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      final press = await tester.startGesture(tester.getCenter(button));
      await tester.pump(const Duration(milliseconds: 220));
      expect(labelColor(), scheme.onPrimary);
      expect(iconColor(), scheme.onPrimary);
      await press.up();
      await tester.pumpAndSettle();
      expect(submits, 1);
      rebuild(() => enabled = false);
      await tester.pumpAndSettle();
      expect(labelColor(), scheme.onSurfaceVariant);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${brightness.name} native choices keep touch, keyboard, semantics and disabled state', (tester) async {
      final semantics = tester.ensureSemantics();
      final focus = FocusNode();
      var enabled = true, background = false, notifications = false;
      var source = 'current';
      var changes = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(brightness), home: Scaffold(body: StatefulBuilder(builder: (context, update) {
        rebuild = update;
        return Column(children: [
          SwitchListTile(focusNode: focus, title: const Text('Arka plan bağlantısı'), value: background, onChanged: enabled ? (value) => update(() { background = value; changes++; }) : null),
          CheckboxListTile(title: const Text('Karar bildirimleri'), value: notifications, onChanged: enabled ? (value) => update(() { notifications = value!; changes++; }) : null),
          RadioGroup<String>(groupValue: source, onChanged: (value) => update(() { source = value!; changes++; }), child: Column(children: [
            RadioListTile<String>(title: const Text('Güncel oturum'), value: 'current', enabled: enabled),
            RadioListTile<String>(title: const Text('Kayıtlı oturum'), value: 'saved', enabled: enabled),
          ])),
        ]);
      }))));
      final toggle = find.widgetWithText(SwitchListTile, 'Arka plan bağlantısı');
      final checkbox = find.widgetWithText(CheckboxListTile, 'Karar bildirimleri');
      final saved = find.widgetWithText(RadioListTile<String>, 'Kayıtlı oturum');
      for (final control in [toggle, checkbox, saved]) {
        expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
      }
      expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isToggled.toBoolOrNull(), isFalse);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isToggled.toBoolOrNull(), isTrue);
      tester.semantics.tap(find.semantics.byLabel('Karar bildirimleri'));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(checkbox).getSemanticsData().flagsCollection.isChecked, CheckedState.isTrue);
      await tester.tap(find.text('Kayıtlı oturum'));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(saved).getSemanticsData().flagsCollection.isChecked, CheckedState.isTrue);
      expect(changes, 3);
      rebuild(() => enabled = false);
      await tester.pumpAndSettle();
      for (final control in [toggle, checkbox, saved]) {
        final data = tester.getSemantics(control).getSemanticsData();
        expect(data.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
        expect(data.hasAction(SemanticsAction.tap), isFalse);
      }
      await tester.tap(find.text('Arka plan bağlantısı'));
      await tester.tap(find.text('Karar bildirimleri'));
      await tester.tap(find.text('Güncel oturum'));
      await tester.pumpAndSettle();
      expect(changes, 3);
      expect(background, isTrue);
      expect(notifications, isTrue);
      expect(source, 'saved');
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose(); semantics.dispose();
    });

    testWidgets('${brightness.name} slider exposes adjustable value and stops when disabled', (tester) async {
      final semantics = tester.ensureSemantics();
      var value = 40.0;
      var enabled = true;
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(brightness), home: Scaffold(body: StatefulBuilder(builder: (context, update) {
        rebuild = update;
        return Slider(value: value, min: 0, max: 100, divisions: 10, semanticFormatterCallback: (value) => '${value.round()} birim', onChanged: enabled ? (next) => update(() => value = next) : null);
      }))));
      expect(tester.getSize(find.byType(Slider)).height, greaterThanOrEqualTo(48));
      final slider = find.semantics.byFlag(SemanticsFlag.isSlider);
      expect(slider, findsOneWidget);
      expect(slider.evaluate().single.value, '40 birim');
      tester.semantics.increase(find.semantics.byAction(SemanticsAction.increase));
      await tester.pumpAndSettle();
      expect(slider.evaluate().single.value, '50 birim');
      tester.semantics.decrease(find.semantics.byAction(SemanticsAction.decrease));
      await tester.pumpAndSettle();
      expect(value, 40);
      rebuild(() => enabled = false);
      await tester.pumpAndSettle();
      expect(slider, findsOneWidget);
      expect(slider.evaluate().single.value, '40 birim');
      final disabled = slider.evaluate().single.getSemanticsData();
      expect(disabled.hasAction(SemanticsAction.increase), isFalse);
      expect(disabled.hasAction(SemanticsAction.decrease), isFalse);
      await tester.tapAt(tester.getTopRight(find.byType(Slider)) - const Offset(24, -24));
      await tester.pumpAndSettle();
      expect(value, 40);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    });

    testWidgets('${brightness.name} raised menu retains disabled action and keyboard dismissal', (tester) async {
      final selections = <String>[];
      await tester.pumpWidget(MaterialApp(theme: omputerTheme(brightness), home: Scaffold(body: PopupMenuButton<String>(
        tooltip: 'Oturum kontrolleri', onSelected: selections.add,
        itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Yeniden adlandır')), PopupMenuItem(value: 'stop', enabled: false, child: Text('Çalışmayı kes'))],
      ))));
      await tester.tap(find.byTooltip('Oturum kontrolleri'));
      await tester.pumpAndSettle();
      final rename = find.widgetWithText(PopupMenuItem<String>, 'Yeniden adlandır');
      final disabled = find.widgetWithText(PopupMenuItem<String>, 'Çalışmayı kes');
      expect(tester.getSize(rename).height, greaterThanOrEqualTo(48));
      await tester.tap(disabled);
      await tester.pumpAndSettle();
      expect(selections, isEmpty);
      expect(rename, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(rename, findsNothing);
      await tester.tap(find.byTooltip('Oturum kontrolleri'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yeniden adlandır'));
      await tester.pumpAndSettle();
      expect(selections, ['rename']);
    });
  }
}
