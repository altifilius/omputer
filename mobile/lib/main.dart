import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'controller.dart';
import 'ui.dart';
import 'pairing.dart';
import 'projects.dart';
import 'interactions.dart';
import 'session.dart';
import 'settings.dart';
import 'models.dart';
import 'project_files.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(OmputerApp(controller: OmputerController()));
}

class OmputerApp extends StatefulWidget {
  const OmputerApp({super.key, required this.controller});
  final OmputerController controller;
  @override
  State<OmputerApp> createState() => _OmputerAppState();
}

class _OmputerAppState extends State<OmputerApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.navigation.addListener(_navigate);
    widget.controller.initialize().then((_) => _navigate());
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.controller.ready) {
      perform(navigator.currentContext ?? context, widget.controller.reloadConnection);
    }
  }
  String? _visibleSession() {
    String? sessionId;
    void visit(Element element) {
      final screen = element.widget;
      if (screen is SessionScreen && ModalRoute.of(element)?.isCurrent == true) sessionId = screen.sessionId;
      element.visitChildren(visit);
    }
    navigator.currentContext?.visitChildElements(visit);
    return sessionId;
  }

  void _shareNotice(BuildContext context, Json data, String identity) {
    final controller = widget.controller;
    final sessionId = _visibleSession();
    showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(data['shareError'] is String ? 'Görseller alınamadı' : 'Paylaşılan görseller hazır'),
      content: SingleChildScrollView(child: Text(data['shareError'] is String
        ? '${data['shareError']}\n\nGörselleri kaynak uygulamadan yeniden paylaşabilir veya konuşmadaki galeriden ekleyebilirsin. Taslağın değiştirilmedi.'
        : 'Görseller henüz taslağa eklenmedi ve gönderilmedi. ${sessionId == null ? 'Bir konuşma seç, ardından' : 'Bu konuşmada'} “Paylaşılan görselleri ekle” düğmesini kullan. Yazdığın metin korunur.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Kapat')),
        if (data['sharedImages'] == true) FilledButton(onPressed: () {
          Navigator.pop(dialogContext);
          if ('${controller.localState['identity'] ?? ''}' != identity) return;
          if (sessionId == null) _chooseSharedSession(context, identity);
        }, child: Text(sessionId == null ? 'Konuşma seç' : 'Konuşmaya dön')),
      ],
    ));
  }

  void _chooseSharedSession(BuildContext context, String identity) {
    final controller = widget.controller;
    showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Görseller için konuşma seç'),
      content: SizedBox(width: double.maxFinite, child: ListView(shrinkWrap: true, children: [
        if (controller.snapshot.sessions.isEmpty) const Text('Henüz konuşma yok. Projelerden bir oturum aç; ardından paylaşılan görselleri ekle.'),
        for (final session in controller.snapshot.sessions) ListTile(
          title: Text(session.name), subtitle: Text(controller.snapshot.project(session.projectId)?.name ?? session.projectId),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            Navigator.pop(dialogContext);
            if ('${controller.localState['identity'] ?? ''}' != identity) return;
            openScreen(context, SessionScreen(controller: controller, sessionId: session.id));
          },
        ),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Vazgeç'))],
    ));
  }
  void _navigate() {
    final data = widget.controller.pendingNavigation;
    if (data == null || !widget.controller.ready) return;
    widget.controller.consumeNavigation();
    final identity = '${widget.controller.localState['identity'] ?? ''}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || navigator.currentContext == null || '${widget.controller.localState['identity'] ?? ''}' != identity) return;
      final controller = widget.controller;
      final ctx = navigator.currentContext!;
      if (data['sharedImages'] == true || data['shareError'] is String) {
        _shareNotice(ctx, data, identity);
        return;
      }
      if (data['bundle'] is! String && data['interactionId'] is! String && data['sessionId'] is! String) return;
      navigator.currentState!.popUntil((route) => route.isFirst);
      if (data['bundle'] is String) {
        openScreen(ctx, PairingScreen(controller: controller, initialBundle: data['bundle'] as String));
      } else if (data['interactionId'] is String) {
        openScreen(ctx, InteractionScreen(controller: controller, interactionId: data['interactionId'] as String));
      } else if (data['sessionId'] is String) {
        openScreen(ctx, SessionScreen(controller: controller, sessionId: data['sessionId'] as String));
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.navigation.removeListener(_navigate);
    widget.controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) => MaterialApp(
    title: 'Omputer', navigatorKey: navigator, debugShowCheckedModeBanner: false,
    theme: omputerTheme(Brightness.light), darkTheme: omputerTheme(Brightness.dark),
    themeMode: switch (widget.controller.theme) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system },
    locale: const Locale('tr'), supportedLocales: const [Locale('tr'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: Theme.of(context).colorScheme.surface,
          systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: !widget.controller.ready ? const Scaffold(body: Center(child: CircularProgressIndicator())) : widget.controller.connection.paired ? HomeScreen(controller: widget.controller) : PairingScreen(controller: widget.controller),
  ));
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final OmputerController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  int destination = 0;
  String query = '', filter = 'all';
  final search = TextEditingController();
  final _projectOrder = StableActivityOrder();
  @override
  void dispose() { search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final destinations = [const NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: 'Projeler'), NavigationDestination(icon: Badge(isLabelVisible: c.snapshot.pending.isNotEmpty, label: Text('${c.snapshot.pending.length}'), child: const Icon(Icons.inbox_outlined)), selectedIcon: const Icon(Icons.inbox_rounded), label: 'Gelen kutusu'), const NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Ayarlar')];
    final content = switch (destination) {
      1 => InboxScreen(controller: c),
      2 => SettingsScreen(controller: c),
      _ => _projects(context),
    };
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Scaffold(
      appBar: AppBar(title: Text(['Omputer', 'Gelen kutusu', 'Ayarlar'][destination]), actions: [if (destination != 2) IconButton(tooltip: 'Görünümü yenile', onPressed: () => perform(context, c.refresh), icon: const Icon(Icons.refresh_rounded))]),
      body: SafeArea(top: false, child: wide ? Row(children: [NavigationRail(selectedIndex: destination, onDestinationSelected: (i) => setState(() => destination = i), labelType: NavigationRailLabelType.all, destinations: const [NavigationRailDestination(icon: Icon(Icons.folder_outlined), label: Text('Projeler')), NavigationRailDestination(icon: Icon(Icons.inbox_outlined), label: Text('Gelen kutusu')), NavigationRailDestination(icon: Icon(Icons.tune_rounded), label: Text('Ayarlar'))]), const VerticalDivider(width: 1), Expanded(child: content)]) : content),
      bottomNavigationBar: wide ? null : NavigationBar(selectedIndex: destination, onDestinationSelected: (i) => setState(() => destination = i), destinations: destinations),
      floatingActionButton: destination == 0 && c.snapshot.projects.isNotEmpty ? FloatingActionButton.extended(onPressed: c.connection.connected ? () => openScreen(context, NewSessionScreen(controller: c)) : null, icon: const Icon(Icons.add_rounded), label: const Text('Yeni oturum')) : null,
    );
  });

  Widget _projects(BuildContext context) {
    final c = widget.controller;
    final needle = query.trim().toLowerCase();
    final ordered = c.snapshot.projects.toList();
    _projectOrder.apply(ordered, (p) => p.id, (p) => p.updatedAt);
    final pins = object(object(c.localState['sections'])['pins']);
    final projects = ordered.where((p) {
      final sessions = c.snapshot.sessions.where((s) => s.projectId == p.id);
      final matches = '${p.name} ${p.goal} ${p.summary} ${p.nextStep} ${p.path}'.toLowerCase().contains(needle);
      return matches && (filter != 'waiting' || c.snapshot.pending.any((i) => i.projectId == p.id)) && (filter != 'live' || sessions.any((s) => !s.archived)) && (filter != 'pinned' || pins['project:${p.id}'] == true);
    }).toList();
    final matchingSessions = needle.isEmpty ? <Session>[] : c.snapshot.sessions.where((s) => '${s.name} ${s.cwd}'.toLowerCase().contains(needle)).toList();
    return RefreshIndicator(onRefresh: c.refresh, child: CustomScrollView(key: const PageStorageKey('project-overview'), physics: const AlwaysScrollableScrollPhysics(), slivers: [
      SliverToBoxAdapter(child: ConnectionBanner(c)),
      if (c.error != null) SliverToBoxAdapter(child: ErrorNotice(c.error!, onRetry: () => perform(context, () async { c.clearError(); await c.reconnect(); }))),
      if (c.snapshot.pending.isNotEmpty) SliverToBoxAdapter(child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24), leading: const Icon(Icons.pending_actions_rounded), title: Text('${c.snapshot.pending.length} karar seni bekliyor'), subtitle: Text(c.snapshot.pending.first.title, maxLines: 1, overflow: TextOverflow.ellipsis), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => setState(() => destination = 1))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 0), child: Text('Kaldığın yerden.', style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.7)))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 8), child: TextField(controller: search, onChanged: (s) => setState(() => query = s), onSubmitted: (s) { if (s.trim().isNotEmpty) openScreen(context, SessionSearchScreen(controller: c, initialQuery: s)); }, decoration: InputDecoration(labelText: 'Proje veya oturum ara', prefixIcon: const Icon(Icons.search_rounded), suffixIcon: query.isEmpty ? null : IconButton(tooltip: 'Aramayı temizle', onPressed: () { search.clear(); setState(() => query = ''); }, icon: const Icon(Icons.close_rounded)))))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Wrap(spacing: 8, children: [('all', 'Tümü'), ('waiting', 'Karar bekleyen'), ('live', 'Canlı oturumu olan'), ('pinned', 'Sabitlenen')].map((item) => FilterChip(label: Text(item.$2), selected: filter == item.$1, onSelected: (_) => setState(() => filter = item.$1))).toList()))),
      if (needle.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeading('Eşleşen oturumlar')),
        SliverList.builder(itemCount: matchingSessions.length, itemBuilder: (context, index) => LocalSessionRow(controller: c, session: matchingSessions[index], key: ValueKey('search:${matchingSessions[index].id}'))),
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: OutlinedButton.icon(onPressed: c.connection.connected ? () => openScreen(context, SessionSearchScreen(controller: c, initialQuery: query)) : null, icon: const Icon(Icons.manage_search_rounded), label: const Text('Konuşma içeriğinde ara')))),
      ],
      if (projects.isEmpty && matchingSessions.isEmpty) SliverToBoxAdapter(child: EmptyState(icon: Icons.folder_open_rounded, title: c.snapshot.projects.isEmpty ? 'Projelerin bilgisayardan gelir.' : 'Eşleşen proje yok.', message: c.snapshot.projects.isEmpty ? 'Bilgisayarındaki kayıtlı OMP projeleri ve oturumları otomatik bulunur. İlk çalışmandan sonra burada görünür.' : 'Başka bir arama dene veya filtreyi değiştir.')),
      SliverList.builder(itemCount: projects.length, itemBuilder: (context, index) => ProjectOverviewRow(controller: c, project: projects[index], key: ValueKey(projects[index].id))),
      const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
    ]));
  }
}
