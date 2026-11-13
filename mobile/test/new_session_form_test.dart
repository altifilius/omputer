import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/models.dart';
import 'package:omputer/session.dart';
import 'package:omputer/ui.dart';
import 'controller_durability_test.dart' as fixture;

class CreationNative extends fixture.DurableNative {
  Completer<void>? startGate;
  int starts = 0;
  String? createdId;

  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'request') {
      if (arguments!['path'] == '/v1/models') {
        return {'models': [{'id': 'local-model', 'name': 'Local model', 'provider': 'local'}]};
      }
      if (arguments['path'] == '/v1/commands' && arguments['method'] == 'POST') {
        starts++;
        await startGate?.future;
        final result = object(await super.invoke(method, arguments));
        if (createdId != null) return {...result, 'data': {'sessionId': createdId}};
        return result;
      }
    }
    return super.invoke(method, arguments);
  }
}

Future<OmputerController> formController(CreationNative native) async {
  native.data = {
    'sequence': 1,
    'projects': [
      {'id': 'project', 'name': 'Omputer'},
      {'id': 'other', 'name': 'Other project'},
    ],
  };
  final controller = OmputerController(adapter: native);
  await controller.initialize();
  return controller;
}

Future<void> closeForm(WidgetTester tester, OmputerController controller, CreationNative native) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await native.stream.close();
}

Future<void> revealFormControl(WidgetTester tester, Finder target, {double delta = 160, bool progressing = false}) async {
  Future<void> settle() async {
    if (progressing) { await tester.pump(const Duration(milliseconds: 100)); }
    else { await tester.pumpAndSettle(); }
  }
  await tester.scrollUntilVisible(target, delta, scrollable: find.byType(Scrollable).first);
  await settle();
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await settle();
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('new session at ${scale * 100}% keeps grouped inputs, next focus and actions reachable with IME', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); tester.view.resetPadding(); tester.view.resetViewInsets(); });
      final semantics = tester.ensureSemantics();
      final native = CreationNative();
      final controller = await formController(native);
      await tester.pumpWidget(MaterialApp(
        theme: omputerTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: NewSessionScreen(controller: controller, projectId: 'project'),
      ));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('new-session-name'));
      final prompt = find.byKey(const ValueKey('new-session-prompt'));
      final project = find.byType(DropdownButtonFormField<String>);
      final model = find.widgetWithText(ListTile, 'Model');
      final start = find.widgetWithText(FilledButton, 'Oturumu başlat');
      final clear = find.widgetWithText(TextButton, 'Taslağı sil');
      expect(find.byType(ConnectionBanner), findsNothing);
      expect(find.text('Oluşturulan oturumu aç'), findsNothing);
      expect(find.text('Bir sonraki adımı başlat.'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Oturum adı')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('İlk istem')), findsOneWidget);
      expect(tester.getRect(project).left, 24);
      expect(tester.getRect(name).left, tester.getRect(project).left);
      expect(tester.getRect(prompt).left, tester.getRect(name).left);
      expect(tester.getRect(name).top - tester.getRect(project).bottom, 16);
      expect(tester.getRect(prompt).top - tester.getRect(name).bottom, 16);
      expect(tester.getRect(model).top - tester.getRect(prompt).bottom, 16);
      await tester.ensureVisible(name);
      await tester.enterText(name, 'Phone continuity');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.descendant(of: prompt, matching: find.byType(EditableText))).focusNode.hasFocus, isTrue);
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, 'Inspect the current project\nKeep the next step local');
      await tester.pumpAndSettle();
      final editable = find.descendant(of: prompt, matching: find.byType(EditableText));
      expect(editable.hitTestable(), findsOneWidget);
      expect(tester.getRect(editable).bottom, lessThanOrEqualTo(400));
      await revealFormControl(tester, start);
      expect(start.hitTestable(), findsOneWidget);
      expect(tester.getRect(start).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(start).bottom, lessThanOrEqualTo(400));
      await revealFormControl(tester, clear);
      expect(clear.hitTestable(), findsOneWidget);
      expect(tester.getRect(clear).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(clear).bottom, lessThanOrEqualTo(400));
      expect(native.starts, 0, reason: 'Next and multiline editing must never submit the creation form.');
      expect((await controller.loadDraft('new:project'))!['name'], 'Phone continuity');
      expect((await controller.loadDraft('new:project'))!['prompt'], contains('\nKeep the next step local'));
      expect(tester.takeException(), isNull);
      await closeForm(tester, controller, native);
      semantics.dispose();
    });
  }

  testWidgets('new session loading and failed restoration keep typed edits and explain the error', (tester) async {
    final native = CreationNative();
    final controller = await formController(native);
    final draftRead = Completer<Object?>();
    native.draftPage = draftRead;
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: NewSessionScreen(controller: controller, projectId: 'project')));
    await tester.pump();
    final name = find.byKey(const ValueKey('new-session-name'));
    final start = find.widgetWithText(FilledButton, 'Oturumu başlat');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await revealFormControl(tester, start, progressing: true);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await revealFormControl(tester, name, delta: -160, progressing: true);
    await tester.enterText(name, 'Edit during restore');
    native.draftPage = null;
    draftRead.completeError(StateError('Draft storage unavailable'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('Taslak açılamadı:'), findsOneWidget);
    expect(tester.widget<TextField>(name).controller!.text, 'Edit during restore');
    await revealFormControl(tester, start);
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
    expect((await controller.loadDraft('new:project'))!['name'], 'Edit during restore');
    expect(native.starts, 0);
    await closeForm(tester, controller, native);
  });

  testWidgets('new session switches project drafts and model, then confirms draft removal', (tester) async {
    final native = CreationNative();
    final controller = await formController(native);
    await controller.saveDraft('new:other', {'name': 'Other saved name', 'prompt': 'Other saved prompt'});
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: NewSessionScreen(controller: controller, projectId: 'project')));
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('new-session-name'));
    final prompt = find.byKey(const ValueKey('new-session-prompt'));
    await tester.enterText(name, 'First project draft');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other project').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(name).controller!.text, 'Other saved name');
    expect(tester.widget<TextField>(prompt).controller!.text, 'Other saved prompt');
    expect((await controller.loadDraft('new:project'))!['name'], 'First project draft');
    await tester.ensureVisible(find.widgetWithText(ListTile, 'Model'));
    await tester.tap(find.widgetWithText(ListTile, 'Model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local model'));
    await tester.pumpAndSettle();
    expect(find.text('local · Local model'), findsOneWidget);
    expect(object((await controller.loadDraft('new:other'))!['model'])['id'], 'local-model');
    await tester.ensureVisible(find.text('Varsayılan modeli kullan'));
    await tester.tap(find.text('Varsayılan modeli kullan'));
    await tester.pumpAndSettle();
    expect((await controller.loadDraft('new:other'))!['model'], isNull);
    final clear = find.widgetWithText(TextButton, 'Taslağı sil');
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(prompt).controller!.text, 'Other saved prompt');
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sil'));
    await tester.pumpAndSettle();
    expect(await controller.loadDraft('new:other'), isNull);
    expect(tester.widget<TextField>(name).controller!.text, isEmpty);
    expect(tester.widget<TextField>(prompt).controller!.text, isEmpty);
    expect((await controller.loadDraft('new:project'))!['name'], 'First project draft');
    expect(native.starts, 0);
    await closeForm(tester, controller, native);
  });

  testWidgets('new session offline recovery preserves draft without showing a named connection banner', (tester) async {
    final native = CreationNative();
    final controller = await formController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: NewSessionScreen(controller: controller, projectId: 'project')));
    await tester.pumpAndSettle();
    final prompt = find.byKey(const ValueKey('new-session-prompt'));
    await tester.enterText(prompt, 'Continue after reconnect');
    tester.testTextInput.hide();
    controller.connection = ConnectionState.fromJson({'paired': true, 'connected': false, 'serverName': 'Named workstation'});
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionBanner), findsNothing);
    expect(find.text('Named workstation'), findsNothing);
    final start = find.widgetWithText(FilledButton, 'Oturumu başlat');
    await revealFormControl(tester, start);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Model')).enabled, isFalse);
    await revealFormControl(tester, find.text('Yeniden bağlan'), delta: -160);
    await tester.tap(find.text('Yeniden bağlan'));
    await tester.pumpAndSettle();
    expect(native.calls, contains('connect'));
    expect(find.text('Yeniden bağlan'), findsNothing);
    await revealFormControl(tester, start);
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
    expect(tester.widget<TextField>(prompt).controller!.text, 'Continue after reconnect');
    expect(native.starts, 0);
    await closeForm(tester, controller, native);
  });

  testWidgets('new session busy controls prevent duplicate start and successful start replaces the form', (tester) async {
    final native = CreationNative()..createdId = 'created-session'..startGate = Completer<void>();
    final controller = await formController(native);
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: NewSessionScreen(controller: controller, projectId: 'project')));
    await tester.pumpAndSettle();
    final prompt = find.byKey(const ValueKey('new-session-prompt'));
    await tester.enterText(prompt, 'One initial prompt');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final start = find.widgetWithText(FilledButton, 'Oturumu başlat');
    await revealFormControl(tester, start);
    await tester.tap(start);
    await tester.pump();
    await revealFormControl(tester, find.widgetWithText(FilledButton, 'Başlatılıyor…'), progressing: true);
    expect(native.starts, 1);
    await tester.tap(find.widgetWithText(FilledButton, 'Başlatılıyor…'));
    await tester.pump();
    expect(native.starts, 1);
    expect(tester.widget<TextField>(prompt).enabled, isFalse);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('new-session-name'))).enabled, isFalse);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Başlatılıyor…')).onPressed, isNull);
    await revealFormControl(tester, find.widgetWithText(TextButton, 'Taslağı sil'), progressing: true);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Taslağı sil')).onPressed, isNull);
    await revealFormControl(tester, find.widgetWithText(ListTile, 'Model'), delta: -160, progressing: true);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Model')).enabled, isFalse);
    native.startGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(NewSessionScreen), findsNothing);
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).sessionId, 'created-session');
    expect(native.starts, 1);
    expect(await controller.loadDraft('new:project'), isNull);
    await closeForm(tester, controller, native);
  });
}
