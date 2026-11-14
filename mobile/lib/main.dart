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
  int navigationRevision = 0;
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
    final revision = ++navigationRevision;
    final identity = '${widget.controller.localState['identity'] ?? ''}';
    final epoch = widget.controller.snapshot.journalEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || revision != navigationRevision || navigator.currentContext == null || '${widget.controller.localState['identity'] ?? ''}' != identity || widget.controller.snapshot.journalEpoch != epoch) return;
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
        final sessionId = data['sessionId'] as String;
        if (data['answer'] == true) {
          await perform(ctx, () async {
            final session = controller.snapshot.session(sessionId);
            if (session == null) throw ControllerFailure('Bildirimin kaynak oturumu bulunamadı. Gelen kutusunu yenile.', 'session_unavailable');
            Route<dynamic>? route;
            navigator.currentState!.popUntil((candidate) { route = candidate; return true; });
            final answer = await controller.firstUnreadAnswer(session);
            if (!mounted || !ctx.mounted || revision != navigationRevision || route?.isCurrent != true ||
                '${controller.localState['identity'] ?? ''}' != identity || controller.snapshot.journalEpoch != epoch ||
                controller.snapshot.session(sessionId)?.answerSummary?.generation != session.answerSummary?.generation) return;
            final target = answer ?? session.answerSummary?.latest;
            openScreen(ctx, SessionScreen(controller: controller, sessionId: sessionId, initialMessageId: target?.messageId, initialAnswer: target));
          });
        } else {
          openScreen(ctx, SessionScreen(controller: controller, sessionId: sessionId));
        }
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
    theme: omputerTheme(Brightness.light, colorTheme: widget.controller.colorTheme),
    darkTheme: omputerTheme(Brightness.dark, colorTheme: widget.controller.colorTheme),
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
class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int destination = 0;
  String query = '', filter = 'all';
  String? selectedProjectId;
  bool savingTheme = false;
  int _pauseSignal = 0;
  final _heldPointers = <int>{};
  final _heldKeys = <LogicalKeyboardKey>{};
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final _projectOrder = StableActivityOrder();
  final _sessionOrder = StableActivityOrder();

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); searchFocus.addListener(searchFocusChanged); }
  void searchFocusChanged() { if (mounted) setState(() {}); }
  void _pauseCards() { if (mounted) setState(() => _pauseSignal++); }
  void _pointerDown(PointerDownEvent event) => setState(() {
    _heldPointers.add(event.pointer);
    _pauseSignal++;
  });
  void _pointerUp(PointerEvent event) => setState(() => _heldPointers.remove(event.pointer));
  KeyEventResult _keyInput(FocusNode node, KeyEvent event) {
    setState(() {
      if (event is KeyUpEvent) {
        _heldKeys.remove(event.logicalKey);
      } else {
        _heldKeys.add(event.logicalKey);
        _pauseSignal++;
      }
    });
    return KeyEventResult.ignored;
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) setState(() {
      _heldPointers.clear();
      _heldKeys.clear();
      _pauseSignal++;
    });
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); searchFocus.removeListener(searchFocusChanged); searchFocus.dispose(); search.dispose(); super.dispose(); }

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
    final panelColor = destination == 1 ? NeoPalette.of(context).raised : _filterPanelColor(context);
    final content = destination == 1 ? InboxScreen(controller: c) : _projects(context);
    final scaffold = Scaffold(
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
      body: SafeArea(key: const ValueKey('home-body'), top: false, bottom: false, child: Stack(
        fit: StackFit.expand,
        children: [
          if (destination == 1) Positioned.fill(left: 8, right: 8, child: ColoredBox(color: panelColor)),
          content,
        ],
      )),
      bottomNavigationBar: SafeArea(top: false, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: NeoJoinedTabs(
        key: const ValueKey('home-bottom-tabs'), panelColor: panelColor, panelAbove: true, selectedId: destination == 1 ? 'inbox' : 'projects',
        tabs: [const JoinedTab(id: 'projects', label: 'Projeler', icon: Icons.folder_outlined), JoinedTab(id: 'new-session', label: 'Yeni oturum', icon: Icons.add_rounded, action: true, enabled: connected && c.snapshot.projects.isNotEmpty), JoinedTab(id: 'inbox', label: 'Gelen kutusu', icon: Icons.inbox_outlined, count: c.snapshot.pending.length + c.unreadAnswerSessions.length)],
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
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _keyInput,
      child: Listener(onPointerDown: _pointerDown, onPointerUp: _pointerUp,
        onPointerCancel: _pointerUp, onPointerSignal: (_) => _pauseCards(), child: scaffold));
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
    final live = filter == 'live';
    final workingSessions = c.connection.connected
        ? c.snapshot.sessions.where((s) => s.isWorking).toList(growable: false)
        : const <Session>[];
    final workingProjects = workingSessions.map((s) => s.projectId).toSet();
    final eligible = ordered.where((p) => (!live || workingProjects.contains(p.id)) &&
        (filter != 'pinned' || pins['project:${p.id}'] == true)).toList();
    bool projectMatches(Project p) => '${p.name} ${p.goal} ${p.summary} ${p.nextStep} ${p.path}'.toLowerCase().contains(needle);
    bool sessionMatches(Session s) => '${s.name} ${s.cwd}'.toLowerCase().contains(needle);
    final projects = eligible.where((p) => projectMatches(p) ||
        (live ? workingSessions : c.snapshot.sessions).any((s) => s.projectId == p.id && sessionMatches(s))).toList();
    final selected = projects.where((p) => p.id == selectedProjectId).firstOrNull ?? projects.firstOrNull;
    selectedProjectId = selected?.id;
    final orderedSessions = c.snapshot.sessions.toList();
    _sessionOrder.apply(orderedSessions, (s) => s.id, (s) => s.updatedAt);
    bool includeSession(Session session) {
      if (!live) return session.projectId == selected?.id;
      final project = c.snapshot.project(session.projectId);
      return c.connection.connected && session.isWorking &&
          (sessionMatches(session) || (project != null && projectMatches(project)));
    }
    final sessions = orderedSessions.where(includeSession).toList(growable: false);
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
          decoration: BoxDecoration(color: panelColor),
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
            if (projects.isEmpty && (!live || sessions.isEmpty)) Expanded(child: RefreshIndicator(onRefresh: c.refresh,
              child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
                SliverFillRemaining(hasScrollBody: false, child: Center(child: SingleChildScrollView(child: EmptyState(
                  icon: live ? Icons.task_alt_rounded : Icons.folder_open_rounded,
                  title: live ? c.connection.connected ? 'Çalışan oturum yok' : 'Canlı durum için bağlantı gerekiyor'
                      : c.snapshot.projects.isEmpty ? 'Projelerin bilgisayardan gelir' : 'Eşleşen proje yok',
                  message: live ? c.connection.connected ? 'Yeni bir iş başladığında burada görünür. Geçmiş oturumlar Tümü sekmesinde kalır.'
                      : 'Kaydedilmiş oturumlar Tümü sekmesinde; güncel çalışma durumunu bağlantı kurulunca görebilirsin.'
                      : c.snapshot.projects.isEmpty ? 'Bilgisayarındaki kayıtlı projeler ve oturumlar burada görünür.' : 'Başka bir arama dene veya filtreyi değiştir.',
                )))),
              ]),
            )) else ...[
              if (selected != null) Padding(padding: const EdgeInsets.only(top: 8), child: ProjectCarousel(
                controller: c, projects: projects, selectedProjectId: selected.id,
                height: deckHeight, pauseSignal: _pauseSignal,
                autoAdvance: query.isEmpty && !searchFocus.hasFocus && MediaQuery.viewInsetsOf(context).bottom == 0 &&
                    _heldPointers.isEmpty && _heldKeys.isEmpty,
                onSelected: (id) => setState(() => selectedProjectId = id),
              )),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
                Expanded(child: Text(live ? 'Çalışan oturumlar (${sessions.length})' : '${selected!.name} · Oturumlar (${sessions.length})',
                  key: const ValueKey('home-session-heading'), maxLines: 2,
                  overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall)),
                if (!live) IconButton(tooltip: 'Seçili projeyi aç', onPressed: () => openProject(selected!),
                  icon: const Icon(Icons.open_in_new_rounded)),
              ])),
              Expanded(child: NotificationListener<UserScrollNotification>(
                onNotification: (notification) { _pauseCards(); return false; }, child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: NeoSurface(depth: NeoDepth.inset, radius: 16,
                  child: ClipRRect(borderRadius: BorderRadius.circular(16), child: RefreshIndicator(
                    onRefresh: c.refresh,
                    child: CustomScrollView(key: live ? const ValueKey('home-live-sessions') : ValueKey('home-project-sessions:${selected!.id}'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (sessions.isEmpty) SliverFillRemaining(hasScrollBody: false,
                          child: Center(child: Padding(padding: const EdgeInsets.all(16),
                            child: Text(live ? 'Çalışan oturum yok' : 'Bu projede oturum yok', textAlign: TextAlign.center)))),
                        SliverList.builder(itemCount: sessions.length, itemBuilder: (context, index) =>
                          LocalSessionRow(controller: c, session: sessions[index], compact: true, showProject: live,
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
