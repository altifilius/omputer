import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/main.dart';
import 'package:omputer/models.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/project_carousel.dart';

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
  setUp(() => TestWidgetsFlutterBinding.instance.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true));
  tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.clearAccessibilityFeaturesTestValue());
  testWidgets('open session list retains row positions while incoming activity and payload order change', (tester) async {
    tester.view.physicalSize = const Size(393, 2400);
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

  testWidgets('project cards retain selection and next identity while streaming payload order changes', (tester) async {
    tester.view.physicalSize = const Size(393, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Json project(String id, int minute) => {'id': id, 'name': 'Project $id', 'updatedAt': '2026-10-18T12:${minute.toString().padLeft(2, '0')}:00Z'};
    final controller = OmputerController(adapter: OrderNative())
      ..snapshot = Snapshot.fromJson({'projects': [project('a', 3), project('b', 2), project('c', 1)]});
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: controller)));
    await tester.pump();
    final rail=find.byKey(const ValueKey('project-carousel-rail'));
    var bounds=tester.getRect(rail);
    await tester.tapAt(bounds.center);await tester.pumpAndSettle();
    expect(tester.widget<ProjectCarousel>(find.byType(ProjectCarousel)).selectedProjectId, 'b');
    controller.snapshot = Snapshot.fromJson({'projects': [project('c', 5), project('b', 4), project('a', 3)]});
    controller.notifyListeners();
    await tester.pump();
    expect(tester.widget<ProjectCarousel>(find.byType(ProjectCarousel)).selectedProjectId, 'b');
    bounds=tester.getRect(rail);
    await tester.tapAt(Offset(bounds.center.dx,bounds.bottom-16));await tester.pumpAndSettle();
    expect(tester.widget<ProjectCarousel>(find.byType(ProjectCarousel)).selectedProjectId, 'c');
    expect(find.byKey(const ValueKey('project-carousel-next')),findsNothing);
    await tester.pump(const Duration(seconds:30));
    expect(tester.widget<ProjectCarousel>(find.byType(ProjectCarousel)).selectedProjectId,'c');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
