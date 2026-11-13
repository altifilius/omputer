import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/controller.dart';
import 'package:omputer/main.dart';
import 'package:omputer/models.dart';
import 'package:omputer/neumorphic.dart';
import 'package:omputer/projects.dart';
import 'package:omputer/project_carousel.dart';
import 'package:omputer/project_cards.dart';
import 'package:omputer/day_night_switch.dart';
import 'package:omputer/ui.dart';
import 'package:omputer/joined_tabs.dart';
import 'package:omputer/session.dart';
import 'package:omputer/settings.dart';

class AppearanceNative implements NativeAdapter {
  String theme='system';bool fail=false;
  final calls=<String>[];
  final data=<String,dynamic>{'projects':[
    {'id':'one','name':'Birinci proje','goal':'Gerçek hedef'},
    {'id':'two','name':'İkinci proje','goal':'İkinci gerçek hedef'},
  ],'sessions':[
    {'id':'a','projectId':'one','name':'Açık A','status':'running','transport':'rpc','writerConnected':true,'workState':'running'},
    {'id':'b','projectId':'two','name':'Açık B','status':'idle','transport':'rpc','writerConnected':true,'workState':'background'},
    {'id':'old','projectId':'one','name':'Kapalı kayıt','status':'closed','transport':'archive'},
  ]};
  @override Stream<Object?> get events=>const Stream.empty();
  @override Future<Object?> invoke(String method,[Json? args])async{
    calls.add(method);
    switch(method){
      case 'connection':case 'connect':return {'paired':true,'connected':true,'serverName':'Omputer'};
      case 'snapshot':return data;
      case 'preferences':return {'theme':theme};
      case 'localState':return {'identity':'test','sections':{}};
      case 'operationList':case 'sharedImages':return [];
      case 'draftLoad':return null;
      case 'theme':if(fail)throw PlatformException(code:'storage',message:'Kayıt yazılamadı');theme=args!['mode'];return null;
      default:throw StateError('Unexpected $method');
    }
  }
}
OmputerController homeController(AppearanceNative native)=>OmputerController(adapter:native)
  ..snapshot=Snapshot.fromJson(native.data)..connection=ConnectionState.fromJson({'paired':true,'connected':true,'serverName':'Omputer'});
Widget home(OmputerController c,{double scale=1})=>ListenableBuilder(listenable:c,builder:(context,_)=>MaterialApp(theme:omputerTheme(c.theme=='light'?Brightness.light:Brightness.dark),home:MediaQuery(data:MediaQueryData(textScaler:TextScaler.linear(scale),disableAnimations:true),child:HomeScreen(controller:c))));

void main(){
  setUp(()=>TestWidgetsFlutterBinding.instance.platformDispatcher.accessibilityFeaturesTestValue=FakeAccessibilityFeatures(disableAnimations:true));
  tearDown(()=>TestWidgetsFlutterBinding.instance.platformDispatcher.clearAccessibilityFeaturesTestValue());
  testWidgets('Home shows selected-project sessions with rail-only navigation', (tester)async{
    tester.view.physicalSize=const Size(393,1000);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final c=homeController(AppearanceNative());await tester.pumpWidget(home(c));await tester.pumpAndSettle();
    List<String> sessions()=>tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((row)=>row.session.id).toList();
    expect(find.textContaining('Canlı oturumlar'),findsNothing);
    expect(sessions(),['a','old']);expect(find.text('Kapalı kayıt'),findsOneWidget);
    expect(find.text('Açık B'),findsNothing);
    final rail=find.byKey(const ValueKey('project-carousel-rail'));
    var bounds=tester.getRect(rail);
    await tester.tapAt(Offset(bounds.center.dx,bounds.bottom-16));await tester.pumpAndSettle();
    expect(sessions(),['b']);expect(find.text('Kapalı kayıt'),findsNothing);
    expect(find.text('İkinci proje · Oturumlar (1)'),findsOneWidget);
    expect(tester.widget<ProjectCarousel>(find.byType(ProjectCarousel)).selectedProjectId,'two');
    bounds=tester.getRect(rail);
    await tester.tapAt(Offset(bounds.center.dx,bounds.top+16));await tester.pumpAndSettle();
    expect(sessions(),['a','old']);expect(find.text('Açık B'),findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();
  });
  for(final scale in [1.0,2.0]){
    testWidgets('joined phone filters and centered header stay usable at text scale $scale', (tester)async{
      tester.view.physicalSize=const Size(360,1000);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
      final c=homeController(AppearanceNative());await tester.pumpWidget(home(c,scale:scale));await tester.pumpAndSettle();
      final tabs=find.byKey(const ValueKey('home-filter-tabs'));
      final searchBounds=tester.getRect(find.byType(TextField).first);
      final bottomBounds=tester.getRect(find.byKey(const ValueKey('home-bottom-tabs')));
      final filterBounds=tester.getRect(tabs);
      for(final bounds in [searchBounds,bottomBounds,filterBounds]){
        expect(bounds.left,inInclusiveRange(0,8));expect(bounds.right,inInclusiveRange(352,360));
      }
      final front=find.byWidgetPredicate((w)=>w is ProjectOverviewCard&&w.selected);
      final cardBounds=tester.getRect(front);
      final railBounds=tester.getRect(find.byKey(const ValueKey('project-carousel-rail')));
      expect(cardBounds.left,greaterThanOrEqualTo(8));expect(cardBounds.right,lessThanOrEqualTo(railBounds.left));
      expect(tester.widget<NeoJoinedTabs>(tabs).tabs.map((tab)=>tab.label),['Tümü','Canlı','Sabitlenen']);
      expect(find.text('Karar bekleyen'),findsNothing);
      final switchBounds=tester.getRect(find.byType(DayNightSwitch));
      final titleBounds=tester.getRect(find.byKey(const ValueKey('home-centered-title')));
      final settingsBounds=tester.getRect(find.byTooltip('Ayarlar'));
      expect(switchBounds.right,lessThanOrEqualTo(titleBounds.left));
      expect(settingsBounds.left,greaterThanOrEqualTo(titleBounds.right));
      expect(titleBounds.center.dx,closeTo(180,1));
      final all=tester.getRect(find.descendant(of:tabs,matching:find.byKey(const ValueKey('joined-tab:all'))));
      final live=tester.getRect(find.descendant(of:tabs,matching:find.byKey(const ValueKey('joined-tab:live'))));
      final pinned=tester.getRect(find.descendant(of:tabs,matching:find.byKey(const ValueKey('joined-tab:pinned'))));
      expect(all.width,closeTo(live.width,.1));expect(live.width,closeTo(pinned.width,.1));
      expect(all.height,greaterThanOrEqualTo(48));expect(all.top,live.top);expect(live.top,pinned.top);
      await tester.tap(find.descendant(of:tabs,matching:find.text('Canlı')));await tester.pumpAndSettle();
      final panel=tester.widget<DecoratedBox>(find.byKey(const ValueKey('home-filter-panel')));
      expect((panel.decoration as BoxDecoration).color,tester.widget<NeoJoinedTabs>(tabs).panelColor);
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox.shrink());c.dispose();
    });
  }
  testWidgets('normal phone keeps project controls and sessions within one screen', (tester)async{
    tester.view.physicalSize=const Size(393,852);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final c=homeController(AppearanceNative());
    await tester.pumpWidget(home(c));await tester.pumpAndSettle();
    final bottom=tester.getRect(find.byKey(const ValueKey('home-bottom-tabs')));
    final deck=tester.getRect(find.byType(ProjectCarousel));
    final heading=tester.getRect(find.byKey(const ValueKey('home-session-heading')));
    final sessions=tester.getRect(find.byKey(const ValueKey('home-project-sessions:one')));
    expect(deck.height,lessThanOrEqualTo(248));expect(deck.bottom,lessThanOrEqualTo(heading.top));
    expect(sessions.height,greaterThanOrEqualTo(96));expect(sessions.bottom,lessThanOrEqualTo(bottom.top));
    expect(tester.widget<NeoJoinedTabs>(find.byKey(const ValueKey('home-bottom-tabs'))).panelAbove,isTrue);
    expect(find.textContaining('Projeler ·'),findsNothing);
    expect(find.byKey(const ValueKey('project-view-selector')),findsNothing);
    expect(find.byTooltip('Liste'),findsNothing);expect(find.byTooltip('Kartlar'),findsNothing);
    expect(find.byTooltip('Önceki proje'),findsNothing);expect(find.byTooltip('Sonraki proje'),findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();
  });

  testWidgets('selected-project session panel reconciles removal without showing another project history', (tester)async{
    tester.view.physicalSize=const Size(393,1000);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final native=AppearanceNative();final c=homeController(native);
    await tester.pumpWidget(home(c));await tester.pumpAndSettle();
    final rail=tester.getRect(find.byKey(const ValueKey('project-carousel-rail')));
    await tester.tapAt(Offset(rail.center.dx,rail.bottom-16));await tester.pumpAndSettle();
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((r)=>r.session.id),['b']);
    c.snapshot=Snapshot.fromJson({'projects':[native.data['projects'][0]],'sessions':native.data['sessions']});
    c.notifyListeners();await tester.pumpAndSettle();
    expect(tester.widget<ProjectCarousel>(find.byType(ProjectCarousel)).selectedProjectId,'one');
    expect(tester.widgetList<LocalSessionRow>(find.byType(LocalSessionRow)).map((r)=>r.session.id),['a','old']);
    expect(find.text('Açık B'),findsNothing);expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();
  });

  for(final scale in [1.0,2.0]){
    testWidgets('compact Home retains sessions and native controls at scale $scale',(tester)async{
      tester.view.physicalSize=const Size(320,640);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
      final c=homeController(AppearanceNative());
      await tester.pumpWidget(home(c,scale:scale));await tester.pumpAndSettle();
      expect(tester.takeException(),isNull);
      expect(find.byKey(const ValueKey('home-session-heading')),findsOneWidget);
      final outer=find.byType(SingleChildScrollView).evaluate().where((e)=>
        find.descendant(of:find.byWidget(e.widget),matching:find.byKey(const ValueKey('home-session-heading'))).evaluate().isNotEmpty).toList();
      expect(outer,hasLength(1));
      await tester.ensureVisible(find.byKey(const ValueKey('home-project-sessions:one')));await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('home-project-sessions:one'))).height,greaterThan(48));
      final sessionScroll=find.descendant(of:find.byKey(const ValueKey('home-project-sessions:one')),matching:find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('old')),120,scrollable:sessionScroll);
      expect(find.text('Kapalı kayıt'),findsOneWidget);expect(find.text('Açık B'),findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());c.dispose();
    });
  }


  testWidgets('decisions live only in inbox and new-session action preserves selected destination', (tester)async{
    tester.view.physicalSize=const Size(393,1600);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final native=AppearanceNative();native.data['interactions']=[{'id':'pending','projectId':'one','sessionId':'a','title':'Gerçek bekleyen karar','method':'input'}];
    final c=homeController(native);await tester.pumpWidget(home(c));await tester.pumpAndSettle();
    final bottom=find.byKey(const ValueKey('home-bottom-tabs'));
    expect(find.text('Karar bekleyen · 1'),findsNothing);
    expect(tester.widget<NeoJoinedTabs>(bottom).tabs.last.count,1);
    await tester.tap(find.descendant(of:bottom,matching:find.text('Gelen kutusu')));await tester.pumpAndSettle();
    expect(find.text('Karar bekleyen · 1'),findsOneWidget);expect(find.text('Gerçek bekleyen karar'),findsOneWidget);
    await tester.tap(find.descendant(of:bottom,matching:find.text('Yeni oturum')));await tester.pumpAndSettle();
    expect(find.byType(NewSessionScreen),findsOneWidget);expect(c.operations,isEmpty);
    await tester.binding.handlePopRoute();await tester.pumpAndSettle();
    expect(tester.widget<NeoJoinedTabs>(bottom).selectedId,'inbox');
    await tester.tap(find.byTooltip('Ayarlar'));await tester.pumpAndSettle();expect(find.byType(SettingsScreen),findsOneWidget);
    await tester.binding.handlePopRoute();await tester.pumpAndSettle();expect(tester.widget<NeoJoinedTabs>(bottom).selectedId,'inbox');
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();
  });
  testWidgets('header theme action persists and tracks actual full app brightness',(tester)async{
    final native=AppearanceNative();final c=homeController(native);
    await tester.pumpWidget(home(c));await tester.pumpAndSettle();
    await tester.tap(find.byType(DayNightSwitch));await tester.pumpAndSettle();
    expect(c.theme,'light');expect(native.theme,'light');expect(tester.widget<DayNightSwitch>(find.byType(DayNightSwitch)).dark,isFalse);
    native.fail=true;await tester.tap(find.byType(DayNightSwitch));await tester.pumpAndSettle();
    expect(c.theme,'light');expect(find.textContaining('Kayıt yazılamadı'),findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();
  });
  testWidgets('session working tint follows real state rather than selection or process presence',(tester)async{
    final c=homeController(AppearanceNative());
    Future<Color?> surface(Json session,{bool connected=true})async{
      c.connection=ConnectionState.fromJson({'connected':connected});
      final value=Session.fromJson({'id':'one','projectId':'one','name':'Oturum','transport':'rpc',...session});
      await tester.pumpWidget(MaterialApp(theme:omputerTheme(Brightness.dark),home:Scaffold(body:LocalSessionRow(controller:c,session:value,showProject:true))));await tester.pump();
      return tester.widget<NeoSurface>(find.descendant(of: find.byType(LocalSessionRow), matching: find.byType(NeoSurface)).first).color;
    }
    expect(await surface({'status':'running','writerConnected':true,'workState':'running'}),isNotNull);
    expect(await surface({'status':'idle','writerConnected':true,'workState':'background'}),isNotNull);
    expect(await surface({'status':'waiting','writerConnected':true,'workState':'human_wait'}),isNull);
    expect(await surface({'status':'idle','writerConnected':false,'workState':'running'}),isNull);
    expect(await surface({'status':'running','writerConnected':true,'workState':'running'},connected:false),isNull);
    await tester.pumpWidget(const SizedBox.shrink());c.dispose();
  });
}
