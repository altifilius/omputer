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
  void _navigate() {
    final data = widget.controller.pendingNavigation;
    if (data == null || !widget.controller.ready) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || navigator.currentContext == null) return;
      final controller = widget.controller;
      controller.consumeNavigation();
      navigator.currentState!.popUntil((route) => route.isFirst);
      final ctx = navigator.currentContext!;
      if (data['bundle'] is String) {
        openScreen(ctx, PairingScreen(controller: controller, initialBundle: data['bundle'] as String));
      } else if (data['interactionId'] is String) {
        openScreen(ctx, InteractionScreen(controller: controller, interactionId: data['interactionId'] as String));
      } else if (data['sessionId'] is String) {
        openScreen(ctx, SessionScreen(controller: controller, sessionId: data['sessionId'] as String));
      }
    });
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
    final projects = c.snapshot.projects.where((p) {
      final sessions = c.snapshot.sessions.where((s) => s.projectId == p.id);
      final matches = '${p.name} ${p.goal} ${p.summary} ${p.nextStep} ${p.path} ${sessions.map((s) => s.name).join(' ')}'.toLowerCase().contains(needle);
      return matches && (filter != 'waiting' || c.snapshot.pending.any((i) => i.projectId == p.id)) && (filter != 'live' || sessions.any((s) => !s.archived));
    }).toList()..sort((a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
    return RefreshIndicator(onRefresh: c.refresh, child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
      SliverToBoxAdapter(child: ConnectionBanner(c)),
      if (c.error != null) SliverToBoxAdapter(child: ErrorNotice(c.error!, onRetry: () => perform(context, () async { c.clearError(); await c.reconnect(); }))),
      if (c.snapshot.pending.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 20), child: Material(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(20), child: InkWell(borderRadius: BorderRadius.circular(20), onTap: () => setState(() => destination = 1), child: Padding(padding: const EdgeInsets.all(20), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.pending_actions_rounded), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${c.snapshot.pending.length} karar seni bekliyor', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 6), Text(c.snapshot.pending.first.title, maxLines: 2, overflow: TextOverflow.ellipsis)])), const Icon(Icons.arrow_forward_rounded)])))))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 0), child: Text('Kaldığın yerden.', style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.7)))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 8), child: TextField(controller: search, onChanged: (s) => setState(() => query = s), decoration: InputDecoration(hintText: 'Proje veya oturum ara', prefixIcon: const Icon(Icons.search_rounded), suffixIcon: query.isEmpty ? null : IconButton(tooltip: 'Aramayı temizle', onPressed: () { search.clear(); setState(() => query = ''); }, icon: const Icon(Icons.close_rounded)))))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Wrap(spacing: 8, children: [('all', 'Tümü'), ('waiting', 'Karar bekleyen'), ('live', 'Canlı oturumu olan')].map((item) => FilterChip(label: Text(item.$2), selected: filter == item.$1, onSelected: (_) => setState(() => filter = item.$1))).toList()))),
      if (projects.isEmpty) SliverToBoxAdapter(child: EmptyState(icon: Icons.folder_open_rounded, title: c.snapshot.projects.isEmpty ? 'Projelerin bilgisayardan gelir.' : 'Eşleşen proje yok.', message: c.snapshot.projects.isEmpty ? 'Omputer bilgisayarındaki kayıtlı OMP projelerini ve oturumlarını otomatik bulur. Henüz kayıt yoksa ilk OMP çalışmandan sonra burada görünür. Bilgisayar uygulamasından keşif durumunu inceleyebilirsin.' : 'Başka bir arama dene veya filtreyi değiştir. Kayıtlı veriler çevrimdışıyken de okunabilir.')),
      SliverList.builder(itemCount: projects.length, itemBuilder: (context, index) {
        final p = projects[index];
        final activity = p.activity;
        final goal = p.goal.isNotEmpty ? p.goal : activity?.goal ?? '';
        final next = p.nextStep.isNotEmpty ? p.nextStep : activity?.nextStep ?? '';
        final latest = activity?.lastAssistantText ?? '';
        return Column(children: [InkWell(onTap: () => openScreen(context, ProjectScreen(controller: c, projectId: p.id)), child: Padding(padding: const EdgeInsets.fromLTRB(24, 22, 24, 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Text(p.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600))), const SizedBox(width: 12), const Icon(Icons.arrow_forward_rounded, size: 20)]), if (goal.isNotEmpty) ...[const SizedBox(height: 10), Text(goal, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge)], if (latest.isNotEmpty) ...[const SizedBox(height: 14), Text(latest, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))], const SizedBox(height: 14), Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.commit_rounded, size: 20, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 10), Expanded(child: Text(next.isEmpty ? activity?.pendingCount != null && activity!.pendingCount > 0 ? '${activity.pendingCount} karar yanıtını bekliyor' : 'Son konuşmayı açıp kaldığın yerden devam et' : next, maxLines: 2, overflow: TextOverflow.ellipsis))]), const SizedBox(height: 12), Text('${p.sessionCount} oturum · ${dateLabel(activity?.updatedAt ?? p.updatedAt)}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))]))), const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: Divider())]);
      }),
      const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
    ]));
  }
}
