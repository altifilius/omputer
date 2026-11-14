import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/interactions.dart';
import 'package:omputer/models.dart';
import 'package:omputer/ui.dart';

class InteractionNative implements NativeAdapter {
  final List<Json> commands = [];
  final Map<String, Json> drafts = {};
  final List<Json> operations = [];
  final List<String> draftCalls = [];
  final List<bool> secureCalls = [];
  Json? snapshot;
  Json? privateContext;
  final List<String> contextCalls = [];
  final List<String> openedUrls = [];
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async {
    if (method == 'openExternalUrl') { openedUrls.add('${arguments!['url']}'); return null; }
    if (method.startsWith('draft')) draftCalls.add(method);
    if (method == 'secureScreen') { secureCalls.add(arguments!['enabled'] == true); return null; }
    if (method == 'draftSave') { drafts['${arguments!['key']}'] = object(arguments['value']); return null; }
    if (method == 'draftDelete') { drafts.remove(arguments!['key']); return null; }
    if (method == 'operationSave') { operations.add(object(arguments!['operation'])); return null; }
    if (method == 'draftLoad') return drafts[arguments!['key']];
    if (method == 'operationList') return [];
    if (method == 'request' && arguments!['path'].toString().endsWith('/context')) { contextCalls.add('${arguments['path']}'); return privateContext; }
    if (method == 'request' && arguments!['path'] == '/v1/commands') {
      commands.add(object(arguments['body']));
      return {'success': true};
    }
    if (method == 'request' && arguments!['path'] == '/v1/snapshot') return snapshot ?? {'sequence': 2, 'interactions': [question('resolved')]};
    throw StateError('Unexpected $method $arguments');
  }
}
Json question(String status, {bool multi = true, bool allowCustom = true, List<String> labels = const ['Records', 'History', 'Indexes']}) => {'id': 'request', 'sessionId': 'session', 'projectId': 'project', 'method': 'ask', 'title': 'Migration choices', 'status': status, 'questions': [{'id': 'q', 'question': 'Which data should remain?', 'multi': multi, 'allowCustom': allowCustom, 'options': [for (final label in labels) {'label': label}]}]};

Future<void> openQuestion(WidgetTester tester, InteractionNative native, {bool multi = false, bool allowCustom = true, List<String> labels = const ['Records', 'History']}) async {
  final controller = OmputerController(adapter: native)
    ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
    ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending', multi: multi, allowCustom: allowCustom, labels: labels)]});
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: InteractionScreen(controller: controller, interactionId: 'request')));
  await tester.pumpAndSettle();
}

Future<void> tapChoice(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}

Future<void> revealSubmit(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Yanıtları gönder'), 180, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

Json submittedResult(InteractionNative native) => objects(object(object(native.commands.single['payload'])['answer'])['results']).single;

void main() {
  restoredDecisionDraftTests();
  testWidgets('private confirm context stays transient and clears on cover and resolution', (tester) async {
    const url = 'https://provider.invalid/authorize?state=private-state';
    final native = InteractionNative()..privateContext = {'interactionId': 'private', 'sessionId': 'session', 'title': 'Private authorization', 'message': url};
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [{'id': 'private', 'sessionId': 'session', 'status': 'pending', 'method': 'confirm', 'sensitiveContext': true, 'title': '[redacted]', 'message': '[redacted]'}]});
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: InteractionScreen(controller: controller, interactionId: 'private')));
    await tester.pumpAndSettle();
    expect(native.secureCalls, [true]);
    expect(native.contextCalls, ['/v1/interactions/private/context']);
    expect(find.text('Private authorization'), findsOneWidget);
    expect(native.draftCalls, isEmpty);
    expect(native.openedUrls, isEmpty);
    await tester.ensureVisible(find.text('Giriş bağlantısını aç'));
    await tester.tap(find.text('Giriş bağlantısını aç')); await tester.pumpAndSettle();
    expect(native.openedUrls, isEmpty);
    await tester.tap(find.text('Tarayıcıda aç')); await tester.pumpAndSettle();
    expect(native.openedUrls, [url]);
    final contextReadsBeforeCover = native.contextCalls.length;
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Other')))));
    await tester.pumpAndSettle();
    expect(find.text('Private authorization', skipOffstage: false), findsNothing);
    nav.currentState!.pop(); await tester.pumpAndSettle();
    expect(native.contextCalls, hasLength(contextReadsBeforeCover + 1));
    controller.snapshot.interaction('private')!.status = 'resolved'; controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Private authorization'), findsNothing);
    expect(native.operations.toString(), isNot(contains(url)));
    expect(native.drafts.toString(), isNot(contains(url)));
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
  testWidgets('secret input is protected single-line and never restores saves or reveals its answer', (tester) async {
    const value = 'private-test-secret';
    final pending = <String, dynamic>{'id': 'secret', 'sessionId': 'session', 'method': 'input', 'title': 'API key', 'status': 'pending', 'secret': true, 'prefill': 'unsafe-prefill'};
    final native = InteractionNative()
      ..drafts['decision:secret'] = {'text': 'unsafe-draft'}
      ..snapshot = {'sequence': 2, 'interactions': [{...pending, 'status': 'resolved', 'response': {'value': value}}]};
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [pending]});
    await tester.pumpWidget(MaterialApp(home: InteractionScreen(controller: controller, interactionId: 'secret')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.maxLines, 1);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(field.autofillHints, isEmpty);
    expect(field.controller!.text, isEmpty);
    expect(native.secureCalls, [true]);
    await tester.enterText(find.byType(TextField), value);
    tester.testTextInput.hide();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Yanıtı gönder'));
    await tester.tap(find.widgetWithText(FilledButton, 'Yanıtı gönder'));
    await tester.pumpAndSettle();
    expect(object(native.commands.single['payload'])['value'], value);
    expect(native.operations.toString(), isNot(contains(value)));
    expect(native.draftCalls, isEmpty);
    expect(field.controller!.text, isEmpty);
    expect(find.text('Kabul edilen yanıt'), findsNothing);
    expect(find.text(value), findsNothing);
    expect(controller.snapshot.interaction('secret')!.response.toString(), isNot(contains(value)));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(native.secureCalls, [true, false]);
    controller.dispose();
  });

  testWidgets('secret input clears when its route is covered and when resolved elsewhere', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [{'id': 'secret', 'method': 'input', 'status': 'pending', 'secret': true}]});
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: InteractionScreen(controller: controller, interactionId: 'secret')));
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(find.byType(TextField)).controller!;
    await tester.enterText(find.byType(TextField), 'transient');
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Other route')))));
    await tester.pumpAndSettle();
    expect(input.text, isEmpty);
    nav.currentState!.pop(); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'transient-again');
    controller.snapshot.interaction('secret')!.status = 'resolved';
    controller.notifyListeners(); await tester.pumpAndSettle();
    expect(input.text, isEmpty);
    expect(native.draftCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
  testWidgets('Inbox history remains a named toggle and filters closed decisions without changing them', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'projects': [{'id': 'project', 'name': 'Yerel proje'}], 'interactions': [
        {...question('pending'), 'id': 'pending', 'title': 'Bekleyen seçim'},
        {...question('resolved'), 'id': 'resolved', 'title': 'Yanıtlanmış seçim'},
      ]});
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.dark), home: Scaffold(body: InboxScreen(controller: controller))));
    final toggle = find.widgetWithText(SwitchListTile, 'Yanıtlanan ve kapananları göster');
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
    expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isToggled.toBoolOrNull(), isFalse);
    expect(find.text('Karar bekleyen · 1'), findsOneWidget);
    expect(find.text('Bekleyen seçim'), findsOneWidget);
    expect(find.text('Yanıtlanmış seçim'), findsNothing);
    tester.semantics.tap(find.semantics.byLabel('Yanıtlanan ve kapananları göster'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(toggle).getSemanticsData().flagsCollection.isToggled.toBoolOrNull(), isTrue);
    expect(find.text('Yanıtlanmış seçim'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Yanıtlanmış');
    await tester.pumpAndSettle();
    expect(find.text('Bekleyen seçim'), findsNothing);
    expect(find.text('Yanıtlanmış seçim'), findsOneWidget);
    await tester.tap(find.text('Yanıtlanan ve kapananları göster'));
    await tester.pumpAndSettle();
    expect(find.text('Yanıtlanmış seçim'), findsNothing);
    expect(find.text('Eşleşen karar yok.'), findsOneWidget);
    expect(controller.snapshot.interaction('resolved')!.status, 'resolved');
    expect(native.commands, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose(); controller.dispose();
  });
  testWidgets('multi-answer UI sends selected labels, not indexes', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending')]});
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: InteractionScreen(controller: controller, interactionId: 'request')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Records'));
    await tester.pump();
    await tester.tap(find.text('History'));
    await tester.pump();
    await tester.tap(find.text('Records'));
    await tester.pump();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Yanıtları gönder'), 180, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yanıtları gönder'));
    await tester.pumpAndSettle();
    final answer = object(object(native.commands.single['payload'])['answer']);
    expect(answer['kind'], 'submit');
    expect(objects(answer['results']).single['selectedOptions'], ['History']);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('desktop answer disables an already-open mobile decision', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending')]});
    await tester.pumpWidget(MaterialApp(home: InteractionScreen(controller: controller, interactionId: 'request')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pump();
    controller.snapshot = Snapshot.fromJson({'sequence': 2, 'interactions': [question('resolved')]});
    controller.notifyListeners();
    await tester.pump();
    await tester.scrollUntilVisible(find.widgetWithText(FilledButton, 'Yanıtları gönder'), 180, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Yanıtları gönder'));
    expect(button.onPressed, isNull);
    expect(native.commands, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final switchBack in [false, true]) {
    testWidgets('single offered to custom${switchBack ? ' and back' : ''} submits only the active answer', (tester) async {
      final native = InteractionNative();
      await openQuestion(tester, native);
      final customField = find.byType(TextFormField).first;
      expect(tester.widget<TextFormField>(customField).enabled, isFalse);
      await tapChoice(tester, find.text('Records'));
      await tapChoice(tester, find.widgetWithText(RadioListTile<Object>, 'Özel yanıt'));
      expect(tester.widget<TextFormField>(customField).enabled, isTrue);
      await tester.ensureVisible(customField);
      await tester.enterText(customField, ' Keep only exports ');
      await tester.pump();
      if (switchBack) {
        await tapChoice(tester, find.text('History'));
        expect(tester.widget<TextFormField>(customField).enabled, isFalse);
      }
      final noteField = find.byType(TextFormField).last;
      await tester.ensureVisible(noteField);
      await tester.enterText(noteField, ' Context only ');
      await revealSubmit(tester);
      await tester.tap(find.text('Yanıtları gönder'));
      await tester.pumpAndSettle();
      final result = submittedResult(native);
      expect(result['selectedOptions'], switchBack ? ['History'] : isEmpty);
      if (switchBack) {
        expect(result.containsKey('customInput'), isFalse);
      } else {
        expect(result['customInput'], 'Keep only exports');
      }
      expect(result['note'], 'Context only');
    });
  }

  testWidgets('selected custom answer requires nonblank text before submit', (tester) async {
    final native = InteractionNative();
    await openQuestion(tester, native);
    await tapChoice(tester, find.text('Records'));
    await tapChoice(tester, find.widgetWithText(RadioListTile<Object>, 'Özel yanıt'));
    await revealSubmit(tester);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Yanıtları gönder')).onPressed, isNull);
    final customField = find.byType(TextFormField).first;
    await tester.ensureVisible(customField);
    await tester.enterText(customField, '  \n\t ');
    await tester.pump();
    await revealSubmit(tester);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Yanıtları gönder')).onPressed, isNull);
    expect(native.commands, isEmpty);
  });

  testWidgets('allowCustom false exposes only offered choices and the context note', (tester) async {
    final native = InteractionNative();
    await openQuestion(tester, native, allowCustom: false);
    expect(find.byType(RadioListTile<Object>), findsNWidgets(2));
    expect(find.text('Özel yanıt'), findsNothing);
    expect(find.byType(TextFormField), findsOneWidget);
    await tapChoice(tester, find.text('Records'));
    final noteField = find.byType(TextFormField);
    await tester.ensureVisible(noteField);
    await tester.enterText(noteField, 'Keep this context');
    await revealSubmit(tester);
    await tester.tap(find.text('Yanıtları gönder'));
    await tester.pumpAndSettle();
    final result = submittedResult(native);
    expect(result['selectedOptions'], ['Records']);
    expect(result.containsKey('customInput'), isFalse);
    expect(result['note'], 'Keep this context');
  });

  for (final includeCustom in [false, true]) {
    testWidgets('multi custom checkbox ${includeCustom ? 'restores' : 'excludes'} its draft without changing labels', (tester) async {
      final native = InteractionNative();
      await openQuestion(tester, native, multi: true);
      await tapChoice(tester, find.text('Records'));
      final customChoice = find.widgetWithText(CheckboxListTile, 'Özel yanıt');
      await tapChoice(tester, customChoice);
      await revealSubmit(tester);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Yanıtları gönder')).onPressed, isNull);
      final customField = find.byType(TextFormField).first;
      await tester.ensureVisible(customField);
      await tester.enterText(customField, ' More data ');
      await tester.pump();
      await tapChoice(tester, customChoice);
      expect(tester.widget<TextFormField>(customField).enabled, isFalse);
      if (includeCustom) {
        await tapChoice(tester, customChoice);
        expect(tester.widget<TextFormField>(customField).enabled, isTrue);
      }
      await revealSubmit(tester);
      await tester.tap(find.text('Yanıtları gönder'));
      await tester.pumpAndSettle();
      final result = submittedResult(native);
      expect(result['selectedOptions'], ['Records']);
      if (includeCustom) {
        expect(result['customInput'], 'More data');
      } else {
        expect(result.containsKey('customInput'), isFalse);
      }
    });
  }

  testWidgets('a genuine offered label named Özel yanıt remains separate from custom mode', (tester) async {
    final native = InteractionNative();
    await openQuestion(tester, native, labels: ['Özel yanıt', 'History']);
    final sameNamedChoices = find.widgetWithText(RadioListTile<Object>, 'Özel yanıt');
    expect(sameNamedChoices, findsNWidgets(2));
    final customField = find.byType(TextFormField).first;
    await tapChoice(tester, sameNamedChoices.first);
    expect(tester.widget<TextFormField>(customField).enabled, isFalse);
    await tapChoice(tester, sameNamedChoices.last);
    expect(tester.widget<TextFormField>(customField).enabled, isTrue);
    await tester.ensureVisible(customField);
    await tester.enterText(customField, 'A different answer');
    await tester.pump();
    await tapChoice(tester, sameNamedChoices.first);
    expect(tester.widget<TextFormField>(customField).enabled, isFalse);
    await revealSubmit(tester);
    await tester.tap(find.text('Yanıtları gönder'));
    await tester.pumpAndSettle();
    final result = submittedResult(native);
    expect(result['selectedOptions'], ['Özel yanıt']);
    expect(result.containsKey('customInput'), isFalse);
  });

  testWidgets('desktop resolution disables active custom input and its choice', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending', multi: false)]});
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: omputerTheme(Brightness.light), home: InteractionScreen(controller: controller, interactionId: 'request')));
    await tester.pumpAndSettle();
    final customChoice = find.widgetWithText(RadioListTile<Object>, 'Özel yanıt');
    await tapChoice(tester, customChoice);
    final customField = find.byType(TextFormField).first;
    await tester.ensureVisible(customField);
    await tester.enterText(customField, 'Phone draft');
    await tester.pump();
    controller.snapshot = Snapshot.fromJson({'sequence': 2, 'interactions': [question('resolved', multi: false)]});
    controller.notifyListeners();
    await tester.pump();
    expect(tester.widget<RadioListTile<Object>>(customChoice).enabled, isFalse);
    expect(tester.widget<TextFormField>(customField).enabled, isFalse);
    await revealSubmit(tester);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Yanıtları gönder')).onPressed, isNull);
    expect(native.commands, isEmpty);
  });
  testWidgets('native ask without notes support submits choices without offering a discarded note', (tester) async {
    final native = InteractionNative();
    final controller = OmputerController(adapter: native)
      ..connection = ConnectionState.fromJson({'paired': true, 'connected': true})
      ..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [{...question('pending', allowCustom: false), 'supportsNotes': false}]});
    await tester.pumpWidget(MaterialApp(home: InteractionScreen(controller: controller, interactionId: 'request')));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    await tapChoice(tester, find.text('Records'));
    await revealSubmit(tester);
    await tester.tap(find.text('Yanıtları gönder'));
    await tester.pumpAndSettle();
    expect(submittedResult(native).containsKey('note'), isFalse);
    expect(submittedResult(native)['selectedOptions'], ['Records']);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

void restoredDecisionDraftTests() {
  testWidgets('decision draft restores selections custom answer and note after remount', (tester) async {
    final native = InteractionNative()..drafts['decision:request'] = {'text': '', 'questions': [{'id': 'q', 'options': ['Records', 'History', 'Indexes'], 'selected': ['History'], 'customSelected': true, 'customInput': 'Preserved custom', 'note': 'Preserved context'}]};
    final controller = OmputerController(adapter: native)..connection = ConnectionState.fromJson({'paired': true, 'connected': true})..snapshot = Snapshot.fromJson({'sequence': 1, 'interactions': [question('pending')]});
    await tester.pumpWidget(MaterialApp(home: InteractionScreen(controller: controller, interactionId: 'request'))); await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'History')).value, true);
    expect(find.text('Preserved custom'), findsOneWidget); expect(find.text('Preserved context'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); controller.dispose();
  });
}
