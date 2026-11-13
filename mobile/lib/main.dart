import 'dart:math' as math;
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
import 'project_carousel.dart';
import 'neumorphic.dart';
import 'day_night_switch.dart';
import 'joined_tabs.dart';

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
  String? selectedProjectId;
  bool savingTheme = false;
  int _pauseSignal = 0;
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final _projectOrder = StableActivityOrder();
  final _sessionOrder = StableActivityOrder();

  @override
  void initState() { super.initState(); searchFocus.addListener(searchFocusChanged); }
  void searchFocusChanged() { if (mounted) setState(() {}); }
  void _pauseCards() { if (mounted) setState(() => _pauseSignal++); }
  @override
  void dispose() { searchFocus.removeListener(searchFocusChanged); searchFocus.dispose(); search.dispose(); super.dispose(); }

  Future<void> changeTheme(bool dark) async {
    if (savingTheme) return;
    setState(() => savingTheme = true);
    await perform(context, () => widget.controller.setTheme(dark ? 'dark' : 'light'));
    if (mounted) setState(() => savingTheme = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final connected = c.connection.connected;
    final panelColor = NeoPalette.of(context).raised;
    final content = destination == 1 ? InboxScreen(controller: c) : _projects(context);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: (MediaQuery.textScalerOf(context).scale(28) + MediaQuery.textScalerOf(context).scale(16) + 12).clamp(64, double.infinity),
        automaticallyImplyLeading: false, centerTitle: true, titleSpacing: 4, leadingWidth: 88,
        leading: Padding(padding: const EdgeInsets.only(left: 8), child: DayNightSwitch(dark: Theme.of(context).brightness == Brightness.dark, onChanged: savingTheme ? null : changeTheme)),
        title: Column(key: const ValueKey('home-centered-title'), crossAxisAlignment: CrossAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          const Text('Omputer', maxLines: 1, overflow: TextOverflow.ellipsis),
          Semantics(liveRegion: true, child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [Icon(connected ? Icons.link_rounded : Icons.link_off_rounded, size: 14, color: connected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error), const SizedBox(width: 4), Flexible(child: Text(connected ? 'Bağlı' : 'Çevrimdışı', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall))])),
        ]),
        actions: [SizedBox(width: 88, child: Align(alignment: Alignment.center, child: IconButton(tooltip: 'Ayarlar', onPressed: () => openScreen(context, Scaffold(appBar: AppBar(title: const Text('Ayarlar')), body: SafeArea(top: false, child: SettingsScreen(controller: c)))), icon: const Icon(Icons.tune_rounded))))],
      ),
      body: SafeArea(top: false, child: content),
      bottomNavigationBar: SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 0), child: NeoJoinedTabs(
        key: const ValueKey('home-bottom-tabs'), panelColor: panelColor, panelAbove: true, selectedId: destination == 1 ? 'inbox' : 'projects',
        tabs: [const JoinedTab(id: 'projects', label: 'Projeler', icon: Icons.folder_outlined), JoinedTab(id: 'new-session', label: 'Yeni oturum', icon: Icons.add_rounded, action: true, enabled: connected && c.snapshot.projects.isNotEmpty), JoinedTab(id: 'inbox', label: 'Gelen kutusu', icon: Icons.inbox_outlined, count: c.snapshot.pending.length)],
        onSelected: (id) {
          if (id == 'new-session') {
            if (c.connection.connected && c.snapshot.projects.isNotEmpty) openScreen(context, NewSessionScreen(controller: c, projectId: selectedProjectId));
          } else {
            searchFocus.unfocus();
            setState(() => destination = id == 'inbox' ? 1 : 0);
          }
        },
      ))),
    );
  });

  Color _filterPanelColor(BuildContext context) {
    final palette = NeoPalette.of(context);
    final alpha = filter == 'pinned' ? .045 : filter == 'live' ? .025 : 0.0;
    return Color.alphaBlend(Theme.of(context).colorScheme.primary.withValues(alpha: alpha), palette.raised);
  }

  Widget _filters(Color panelColor) => Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: NeoJoinedTabs(
    key: const ValueKey('home-filter-tabs'), panelColor: panelColor, selectedId: filter,
    tabs: const [JoinedTab(id: 'all', label: 'Tümü'), JoinedTab(id: 'live', label: 'Canlı'), JoinedTab(id: 'pinned', label: 'Sabitlenen')],
    onSelected: (id) => setState(() => filter = id),
  ));

  Widget _projects(BuildContext context) {
    final c = widget.controller;
    final needle = query.trim().toLowerCase();
    final ordered = c.snapshot.projects.toList();
    _projectOrder.apply(ordered, (p) => p.id, (p) => p.updatedAt);
    final pins = object(object(c.localState['sections'])['pins']);
    bool matchesFilter(String projectId) =>
      (filter != 'live' || c.snapshot.sessions.any((s) => s.projectId == projectId && (!s.archived || s.activeUnbridged))) &&
      (filter != 'pinned' || pins['project:$projectId'] == true);
    final eligible = ordered.where((p) => matchesFilter(p.id)).toList();
    final projects = eligible.where((p) => '${p.name} ${p.goal} ${p.summary} ${p.nextStep} ${p.path}'.toLowerCase().contains(needle) || c.snapshot.sessions.any((s) => s.projectId == p.id && '${s.name} ${s.cwd}'.toLowerCase().contains(needle))).toList();
    final selected = projects.where((p) => p.id == selectedProjectId).firstOrNull ?? projects.firstOrNull;
    selectedProjectId = selected?.id;
    final orderedSessions = c.snapshot.sessions.toList();
    _sessionOrder.apply(orderedSessions, (s) => s.id, (s) => s.updatedAt);
    final sessions = orderedSessions.where((s) => s.projectId == selected?.id).toList(growable: false);
    void openProject(Project project) {
      setState(() => selectedProjectId = project.id);
      openScreen(context, ProjectScreen(controller: c, projectId: project.id));
    }
    final panelColor = _filterPanelColor(context);
    final scaler = MediaQuery.textScalerOf(context);
    final searchHeight = math.max(52.0, scaler.scale(20) + 24);
    return LayoutBuilder(builder: (context, constraints) {
      final minimumHeight = (scaler.scale(16) > 24 ? 712.0 : 496.0) +
          (!c.connection.connected || c.error != null ? 48 : 0);
      final needsScroll = constraints.maxHeight < minimumHeight;
      final pageHeight = math.max(minimumHeight, constraints.maxHeight);
      final deckHeight = pageHeight < 620 ? 216.0 : 248.0;
      final page = SizedBox(height: pageHeight, child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8), child: SizedBox(
          height: searchHeight,
          child: TextField(controller: search, focusNode: searchFocus,
            onChanged: (s) => setState(() => query = s),
            onSubmitted: (s) { if (s.trim().isNotEmpty) openScreen(context, SessionSearchScreen(controller: c, initialQuery: s)); },
            decoration: InputDecoration(labelText: 'Proje veya oturum ara',
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty ? null : IconButton(tooltip: 'Aramayı temizle',
                onPressed: () { search.clear(); setState(() => query = ''); },
                icon: const Icon(Icons.close_rounded))),
          ),
        )),
        _filters(panelColor),
        Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: DecoratedBox(
          key: const ValueKey('home-filter-panel'),
          decoration: BoxDecoration(color: panelColor,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20))),
          child: Column(children: [
            if (!c.connection.connected || c.error != null) Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Expanded(child: Text(c.error ?? 'Kaydedilmiş görünüm · bağlantı bekleniyor',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: c.error == null ? null : Theme.of(context).colorScheme.error))),
                IconButton(tooltip: 'Yeniden dene', onPressed: () => perform(context, () async {
                  c.clearError(); await c.reconnect();
                }), icon: const Icon(Icons.refresh_rounded)),
              ]),
            ),
            if (projects.isEmpty) Expanded(child: RefreshIndicator(onRefresh: c.refresh,
              child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
                SliverFillRemaining(hasScrollBody: false, child: Center(child: SingleChildScrollView(child: EmptyState(
                  icon: Icons.folder_open_rounded,
                  title: c.snapshot.projects.isEmpty ? 'Projelerin bilgisayardan gelir' : 'Eşleşen proje yok',
                  message: c.snapshot.projects.isEmpty ? 'Bilgisayarındaki kayıtlı projeler ve oturumlar burada görünür.' : 'Başka bir arama dene veya filtreyi değiştir.',
                )))),
              ]),
            )) else ...[
              Padding(padding: const EdgeInsets.only(top: 8), child: ProjectCarousel(
                controller: c, projects: projects, selectedProjectId: selected!.id,
                height: deckHeight, pauseSignal: _pauseSignal,
                autoAdvance: query.isEmpty && !searchFocus.hasFocus,
                onSelected: (id) => setState(() => selectedProjectId = id),
              )),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
                Expanded(child: Text('${selected.name} · Oturumlar (${sessions.length})',
                  key: const ValueKey('home-session-heading'), maxLines: 2,
                  overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall)),
                IconButton(tooltip: 'Seçili projeyi aç', onPressed: () => openProject(selected),
                  icon: const Icon(Icons.open_in_new_rounded)),
              ])),
              Expanded(child: Listener(onPointerDown: (_) => _pauseCards(), child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: NeoSurface(depth: NeoDepth.inset, radius: 16,
                  child: ClipRRect(borderRadius: BorderRadius.circular(16), child: RefreshIndicator(
                    onRefresh: c.refresh,
                    child: CustomScrollView(key: ValueKey('home-project-sessions:${selected.id}'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (sessions.isEmpty) const SliverFillRemaining(hasScrollBody: false,
                          child: Center(child: Padding(padding: EdgeInsets.all(16),
                            child: Text('Bu projede oturum yok', textAlign: TextAlign.center)))),
                        SliverList.builder(itemCount: sessions.length, itemBuilder: (context, index) =>
                          LocalSessionRow(controller: c, session: sessions[index], compact: true,
                            key: ValueKey(sessions[index].id))),
                      ],
                    ),
                  )),
                ),
              ))),
            ],
          ]),
        ))),
      ]));
      return needsScroll ? SingleChildScrollView(child: page) : page;
    });
  }
}
