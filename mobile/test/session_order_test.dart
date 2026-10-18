import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/main.dart';
import 'package:omputer/models.dart';
import 'package:omputer/projects.dart';

class OrderNative implements NativeAdapter {
  @override
  Stream<Object?> get events => const Stream.empty();
  @override
  Future<Object?> invoke(String method, [Json? arguments]) async => throw StateError('Unexpected $method');
}

Json session(String id, int minute) => {
  'id': id, 'name': 'Oturum $id', 'projectId': 'p', 'transport': 'bridge', 'status': 'running',
  'updatedAt': '2026-10-18T12:${minute.toString().padLeft(2, '0')}:00Z',
};

void main() {
  testWidgets('open session list retains row positions while incoming activity and payload order change', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = OmputerController(adapter: OrderNative())
      ..snapshot = Snapshot.fromJson({'projects': [{'id': 'p', 'name': 'Project'}], 'sessions': [session('a', 3), session('b', 2), session('c', 1)]});
    await tester.pumpWidget(MaterialApp(home: ProjectScreen(controller: controller, projectId: 'p')));
    await tester.pump();
    List<String> order() => tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row) => row.session.id).toList();
    expect(order(), ['a', 'b', 'c']);
    controller.snapshot = Snapshot.fromJson({'projects': [{'id': 'p', 'name': 'Project'}], 'sessions': [session('c', 5), session('b', 4), session('a', 3)]});
    controller.notifyListeners();
    await tester.pump();
    expect(order(), ['a', 'b', 'c']);
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).last.session.updatedAt, DateTime.parse('2026-10-18T12:05:00Z'));
    await tester.enterText(find.byType(TextField), 'Oturum c');
    await tester.pump();
    expect(order(), ['c']);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(order(), ['a', 'b', 'c']);
    controller.snapshot = Snapshot.fromJson({'projects': [{'id': 'p', 'name': 'Project'}], 'sessions': [session('d', 6), session('c', 5), session('a', 3)]});
    controller.notifyListeners();
    await tester.pump();
    expect(order(), ['d', 'a', 'c']);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('open project list does not promote streaming projects on each activity update', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Json project(String id, int minute) => {'id': id, 'name': 'Project $id', 'updatedAt': '2026-10-18T12:${minute.toString().padLeft(2, '0')}:00Z'};
    final controller = OmputerController(adapter: OrderNative())
      ..snapshot = Snapshot.fromJson({'projects': [project('a', 3), project('b', 2), project('c', 1)]});
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller)));
    await tester.pump();
    expect(tester.getTopLeft(find.text('Project a')).dy, lessThan(tester.getTopLeft(find.text('Project b')).dy));
    expect(tester.getTopLeft(find.text('Project b')).dy, lessThan(tester.getTopLeft(find.text('Project c')).dy));
    controller.snapshot = Snapshot.fromJson({'projects': [project('c', 5), project('b', 4), project('a', 3)]});
    controller.notifyListeners();
    await tester.pump();
    expect(tester.getTopLeft(find.text('Project a')).dy, lessThan(tester.getTopLeft(find.text('Project b')).dy));
    expect(tester.getTopLeft(find.text('Project b')).dy, lessThan(tester.getTopLeft(find.text('Project c')).dy));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
