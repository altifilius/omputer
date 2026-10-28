import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'session.dart';
import 'interactions.dart';
import 'project_files.dart';
import 'memory_history.dart';

class ProjectOverviewRow extends StatefulWidget {
  const ProjectOverviewRow({super.key, required this.controller, required this.project});
  final OmputerController controller;
  final Project project;
  @override
  State<ProjectOverviewRow> createState() => _ProjectOverviewRowState();
}

class _ProjectOverviewRowState extends State<ProjectOverviewRow> {
  bool expanded = false;
  final order = StableActivityOrder();
  @override
  Widget build(BuildContext context) {
    final c = widget.controller, p = widget.project;
    final goal = p.goal.isNotEmpty ? p.goal : p.activity?.goal ?? '';
    final next = p.nextStep.isNotEmpty ? p.nextStep : p.activity?.nextStep ?? '';
    final sessions = c.snapshot.sessions.where((s) => s.projectId == p.id).toList();
    order.apply(sessions, (s) => s.id, (s) => s.updatedAt);
    final liveSessions = sessions.where((s) => !s.archived || s.activeUnbridged).toList();
    final recentArchive = liveSessions.isEmpty ? sessions.firstOrNull : null;
    final pinned = object(object(c.localState['sections'])['pins'])['project:${p.id}'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 16, 16, 8), child: Row(children: [
        Expanded(child: InkWell(onTap: () => openScreen(context, ProjectScreen(controller: c, projectId: p.id)), child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(p.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600))))),
        IconButton(tooltip: pinned ? 'Proje sabitlemesini kaldır' : 'Projeyi sabitle', onPressed: () => perform(context, () => c.updateLocalState('pins', 'project:${p.id}', !pinned)), icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (goal.isNotEmpty) Text(goal, key: ValueKey('overview-goal:${p.id}'), maxLines: expanded ? null : 2, overflow: expanded ? null : TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge),
        if (next.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sıradaki: $next', maxLines: expanded ? null : 2, overflow: expanded ? null : TextOverflow.ellipsis)),
        if (expanded && p.summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: LocalMarkdown(data: p.summary)),
        if (expanded && p.activity?.lastAssistantText.isNotEmpty == true) Padding(padding: const EdgeInsets.only(top: 12), child: LocalMarkdown(data: p.activity!.lastAssistantText)),
        Text('${sessions.length} oturum · ${dateLabel(p.activity?.updatedAt ?? p.updatedAt)}', style: Theme.of(context).textTheme.labelMedium),
        Wrap(spacing: 8, children: [
          if (recentArchive != null) TextButton.icon(key: ValueKey('recent:${p.id}'), onPressed: () => openScreen(context, SessionScreen(controller: c, sessionId: recentArchive.id)), icon: const Icon(Icons.history_rounded), label: const Text('Son konuşma')),
          TextButton.icon(onPressed: () => openScreen(context, ProjectScreen(controller: c, projectId: p.id)), icon: const Icon(Icons.arrow_forward_rounded), label: const Text('Projeyi aç')),
          TextButton(onPressed: () => setState(() => expanded = !expanded), child: Text(expanded ? 'Özeti daralt' : 'Özeti genişlet')),
        ]),
      ])),
      for (final session in liveSessions) LocalSessionRow(key: ValueKey(session.id), controller: c, session: session),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: Divider()),
    ]);
  }
}

class LocalSessionRow extends StatelessWidget {
  const LocalSessionRow({super.key, required this.controller, required this.session});
  final OmputerController controller;
  final Session session;
  @override
  Widget build(BuildContext context) {
    final sections = object(controller.localState['sections']);
    final pinned = object(sections['pins'])['session:${session.id}'] == true;
    final marker = object(object(sections['read'])['session:${session.id}']);
    final transcript = controller.loadedTranscript(session.id);
    final last = transcript == null || transcript.ids.isEmpty ? null : transcript.messages[transcript.ids.last]?.value;
    final unread = last != null && (marker['messageId'] != last.id || marker['revision'] != last.revision);
    var reference = session.id;
    for (var length = 8; length < session.id.length; length++) {
      final suffix = session.id.substring(session.id.length - length);
      if (!controller.snapshot.sessions.any((other) => other.id != session.id && other.id.endsWith(suffix))) {
        reference = '…$suffix';
        break;
      }
    }
    return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: Icon(pinned ? Icons.push_pin_rounded : session.archived && !session.activeUnbridged ? Icons.history_rounded : Icons.chat_bubble_outline_rounded), title: Text(session.name.isEmpty ? 'Adsız oturum' : session.name, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${session.statusLabel}${unread ? ' · Okunmadı' : marker.isNotEmpty ? ' · Okundu' : ''}\n${dateLabel(session.updatedAt)}'),
      Text('Oturum $reference', style: Theme.of(context).textTheme.bodySmall),
    ]), onTap: () => openScreen(context, SessionScreen(controller: controller, sessionId: session.id)), trailing: IconButton(tooltip: pinned ? 'Oturum sabitlemesini kaldır' : 'Oturumu sabitle', icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined), onPressed: () => perform(context, () => controller.updateLocalState('pins', 'session:${session.id}', !pinned))));
  }
}

class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.controller, required this.projectId});
  final OmputerController controller;
  final String projectId;
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}
class _ProjectScreenState extends State<ProjectScreen> {
  String query = '', filter = 'all';
  final _sessionOrder = StableActivityOrder();
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final p = c.snapshot.project(widget.projectId);
    if (p == null) return Scaffold(appBar: AppBar(title: const Text('Proje')), body: const EmptyState(icon: Icons.folder_off_outlined, title: 'Proje bulunamadı.', message: 'Bilgisayara yeniden bağlanarak kayıtları yenile.'));
    final ordered = c.snapshot.sessions.where((s) => s.projectId == p.id).toList();
    _sessionOrder.apply(ordered, (s) => s.id, (s) => s.updatedAt);
    final pins = object(object(c.localState['sections'])['pins']);
    final sessions = ordered.where((s) => s.name.toLowerCase().contains(query.toLowerCase()) && (filter == 'all' || (filter == 'pinned' ? pins['session:${s.id}'] == true : filter == 'archive' ? s.archived && !s.activeUnbridged : !s.archived || s.activeUnbridged))).toList();
    final pending = c.snapshot.pending.where((i) => i.projectId == p.id).toList();
    return Scaffold(appBar: AppBar(title: Text(p.name), actions: [IconButton(tooltip: 'Yeni oturum', onPressed: c.connection.connected ? () => openScreen(context, NewSessionScreen(controller: c, projectId: p.id)) : null, icon: const Icon(Icons.add_rounded)), IconButton(tooltip: 'Proje dosyalarını incele', onPressed: () => openScreen(context, ProjectFilesScreen(controller: c, project: p)), icon: const Icon(Icons.folder_copy_outlined))]), body: SafeArea(top: false, child: CustomScrollView(key: PageStorageKey('project:${p.id}'), slivers: [
      SliverToBoxAdapter(child: ConnectionBanner(c)),
      if (pending.isNotEmpty) ...[const SliverToBoxAdapter(child: SectionHeading('Yanıt bekliyor')), SliverList.builder(itemCount: pending.length, itemBuilder: (context, index) => InteractionRow(controller: c, interaction: pending[index]))],
      const SliverToBoxAdapter(child: SectionHeading('Oturumlar')),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: TextField(onChanged: (s) => setState(() => query = s), onSubmitted: (s) { if (s.trim().isNotEmpty) openScreen(context, SessionSearchScreen(controller: c, projectId: p.id, initialQuery: s)); }, decoration: InputDecoration(labelText: 'Bu projede oturum ara', prefixIcon: const Icon(Icons.search_rounded), suffixIcon: IconButton(tooltip: 'Konuşma içeriğinde ara', onPressed: () => openScreen(context, SessionSearchScreen(controller: c, projectId: p.id, initialQuery: query)), icon: const Icon(Icons.manage_search_rounded)))))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Wrap(spacing: 8, children: [('all', 'Tümü'), ('live', 'Canlı'), ('archive', 'Geçmiş'), ('pinned', 'Sabitlenen')].map((item) => FilterChip(label: Text(item.$2), selected: filter == item.$1, onSelected: (_) => setState(() => filter = item.$1))).toList()))),
      if (sessions.isEmpty) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: Text('Bu filtrede oturum yok.'))),
      SliverList.builder(itemCount: sessions.length, itemBuilder: (context, index) => LocalSessionRow(controller: c, session: sessions[index], key: ValueKey(sessions[index].id))),
      if (p.activity case final activity? when activity.hasContext) SliverToBoxAdapter(child: ExpansionTile(key: PageStorageKey('activity:${p.id}'), tilePadding: const EdgeInsets.symmetric(horizontal: 24), childrenPadding: const EdgeInsets.all(24), title: const Text('Son kaldığın yer'), subtitle: Text('Konuşmadan ve görevlerden · ${dateLabel(activity.updatedAt)}'), children: [
        if (activity.goal.isNotEmpty) SelectableText(activity.goal),
        if (activity.lastAssistantText.isNotEmpty) LocalMarkdown(data: activity.lastAssistantText, onOpenFile: (path, line) => openScreen(context, FilePreviewScreen(controller: c, project: p, initialPath: path, initialLine: line))),
        if (activity.nextStep.isNotEmpty) SelectableText('Sıradaki iş: ${activity.nextStep}'),
        FilledButton.tonalIcon(onPressed: () => openScreen(context, SessionScreen(controller: c, sessionId: activity.sessionId), checkpoint: true), icon: const Icon(Icons.arrow_forward_rounded), label: const Text('Konuşmayı görüntüle')),
      ])),
      SliverToBoxAdapter(child: ExpansionTile(key: PageStorageKey('memory:${p.id}'), tilePadding: const EdgeInsets.symmetric(horizontal: 24), childrenPadding: const EdgeInsets.symmetric(horizontal: 24), title: const Text('Projenin hafızası'), subtitle: Text('Sürüm ${p.memoryRevision} · ${dateLabel(p.memoryUpdatedAt ?? p.updatedAt)}'), children: [
        _memory(context, 'Hedef', p.goal, 'Henüz hedef kaydedilmedi.'),
        _memory(context, 'Durum özeti', p.summary, 'Henüz özet kaydedilmedi.'),
        _memory(context, 'Sonraki adım', p.nextStep, 'Henüz sonraki adım kaydedilmedi.'),
        ...p.decisions.map((d) => Padding(padding: const EdgeInsets.only(bottom: 12), child: LocalMarkdown(data: d))),
        Text(p.memoryOrigin == 'agent' ? 'Ajanın kaynaklı kaydı' : 'Elle düzenlenen kayıt'),
        Wrap(spacing: 8, children: [
          TextButton.icon(onPressed: c.connection.connected ? () => openScreen(context, CheckpointEditor(controller: c, project: p)) : null, icon: const Icon(Icons.edit_outlined), label: const Text('Hafızayı düzenle')),
          TextButton.icon(onPressed: () => openScreen(context, MemoryHistoryScreen(controller: c, project: p)), icon: const Icon(Icons.history_rounded), label: const Text('Sürüm geçmişi')),
          if (p.sourceSessionId != null) TextButton.icon(onPressed: () => openScreen(context, SessionScreen(controller: c, sessionId: p.sourceSessionId!), checkpoint: true), icon: const Icon(Icons.commit_rounded), label: const Text('Kaynak oturuma git')),
        ]),
      ])),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText(p.path, style: Theme.of(context).textTheme.bodySmall))),
      const SliverPadding(padding: EdgeInsets.only(bottom: 110)),
    ])));
  });
  Widget _memory(BuildContext context, String label, String text, String empty) => Padding(padding: const EdgeInsets.only(bottom: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)), const SizedBox(height: 8), if (text.isEmpty) Text(empty) else LocalMarkdown(data: text)]));
}

class CheckpointEditor extends StatefulWidget {
  const CheckpointEditor({super.key, required this.controller, required this.project});
  final OmputerController controller;
  final Project project;
  @override
  State<CheckpointEditor> createState() => _CheckpointEditorState();
}
class _CheckpointEditorState extends State<CheckpointEditor> {
  late final goal = TextEditingController(text: widget.project.goal);
  late final summary = TextEditingController(text: widget.project.summary);
  late final next = TextEditingController(text: widget.project.nextStep);
  late final decisions = TextEditingController(text: widget.project.decisions.join('\n'));
  late String? source = widget.project.sourceSessionId;
  bool busy = false, saved = false;
  String? conflict;
  late int revision = widget.project.memoryRevision;
  Json? latestMemory;
  int? latestRevision;
  bool get dirty => !saved && (goal.text != widget.project.goal || summary.text != widget.project.summary || next.text != widget.project.nextStep || decisions.text != widget.project.decisions.join('\n') || source != widget.project.sourceSessionId);
  @override
  void dispose() { goal.dispose(); summary.dispose(); next.dispose(); decisions.dispose(); super.dispose(); }
  Future<void> save() async {
    if (busy || conflict != null || !widget.controller.connection.connected) return;
    setState(() => busy = true);
    try {
      await widget.controller.updateProject(widget.project.id, {'expectedMemoryRevision': revision, 'goal': goal.text.trim(), 'summary': summary.text.trim(), 'nextStep': next.text.trim(), 'decisions': decisions.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(), 'sourceSessionId': source});
      if (!mounted) return;
      setState(() { busy = false; saved = true; });
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Navigator.pop(context); });
    } catch (e) {
      if (!mounted) return;
      setState(() { busy = false; if (e is ControllerFailure && e.code == 'memory_conflict') conflict = 'Hafıza başka bir yerde değişti. Taslağın korunuyor. Güncel sürümü getirip alanları açıkça birleştirmeden kaydedemezsin; eski sürümün üzerine yazılmadı.'; });
      if (conflict == null) await perform(context, () async => throw e);
    }
  }
  Future<void> loadConflict() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final page = await widget.controller.memoryHistory(widget.project.id, limit: 1);
      final entry = objects(page['entries']).firstOrNull;
      if (entry == null) throw ControllerFailure('Güncel hafıza sürümü alınamadı. Bağlantıyı yenileyip tekrar dene.');
      if (mounted) setState(() { latestMemory = object(entry['memory']); latestRevision = (entry['revision'] as num?)?.toInt(); });
    } catch (e) { if (mounted) await perform(context, () async => throw e); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> mergeConflict() async {
    final latest = latestMemory;
    final targetRevision = latestRevision;
    if (latest == null || targetRevision == null) return;
    final draft = <String, dynamic>{'goal': goal.text, 'summary': summary.text, 'nextStep': next.text, 'decisions': decisions.text.split('\n'), 'sourceSessionId': source};
    final chosen = <String>{};
    final accepted = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) => AlertDialog(
      title: Text('Sürüm $targetRevision ile birleştir'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Varsayılan olarak bilgisayardaki güncel alanlar korunur. Yalnızca kendi taslağından almak istediğin alanları seç. Kaydetmeden önce sonuç metnini düzenleyebilirsin.'),
        for (final field in [('goal', 'Hedef'), ('summary', 'Özet'), ('nextStep', 'Sonraki adım'), ('decisions', 'Kararlar'), ('sourceSessionId', 'Kaynak oturum')]) ...[
          CheckboxListTile(contentPadding: EdgeInsets.zero, title: Text('${field.$2}: taslağımı kullan'), value: chosen.contains(field.$1), onChanged: (value) => update(() { if (value == true) { chosen.add(field.$1); } else { chosen.remove(field.$1); } })),
          SelectableText('Güncel: ${latest[field.$1] ?? '—'}\nTaslağım: ${draft[field.$1] ?? '—'}'),
        ],
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Seçilen alanlarla düzenle'))],
    )));
    if (accepted != true || !mounted) return;
    Object? value(String key) => chosen.contains(key) ? draft[key] : latest[key];
    setState(() { goal.text = '${value('goal') ?? ''}'; summary.text = '${value('summary') ?? ''}'; next.text = '${value('nextStep') ?? ''}'; decisions.text = strings(value('decisions')).join('\n'); source = value('sourceSessionId')?.toString(); revision = targetRevision; conflict = null; latestMemory = null; latestRevision = null; });
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) => PopScope<void>(
    canPop: !busy && !dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || busy) return;
      if (await confirm(context, 'Değişiklikleri bırak?', 'Kaydedilmemiş proje hafızası değişiklikleri silinecek. Bilgisayardaki kayıt değişmez.', action: 'Değişiklikleri bırak') && context.mounted) { setState(() => saved = true); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Navigator.pop(context); }); }
    },
    child: Scaffold(appBar: AppBar(title: const Text('Proje hafızasını düzenle')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
      ConnectionBanner(widget.controller),
      Text('Kalıcı proje hafızası · düzenlenen sürüm $revision. Canlı konuşma özeti ayrıdır; turun bitmesi projenin tamamlandığı anlamına gelmez.'),
      if (conflict != null) ...[ErrorNotice(conflict!), TextButton(onPressed: busy ? null : loadConflict, child: const Text('Güncel sürümü getir')), if (latestMemory != null) ...[Text('Güncel sürüm: $latestRevision'), LocalMarkdown(data: '${latestMemory!['summary'] ?? ''}'), TextButton(onPressed: busy ? null : mergeConflict, child: const Text('Alanları karşılaştır ve birleştir'))], TextButton(onPressed: () => openScreen(context, MemoryHistoryScreen(controller: widget.controller, project: widget.project)), child: const Text('Sürüm geçmişini incele')), TextButton(onPressed: () => copyText(context, 'Hedef\n${goal.text}\n\nÖzet\n${summary.text}\n\nSonraki adım\n${next.text}\n\nKararlar\n${decisions.text}'), child: const Text('Taslağımı kopyala'))],
      const SizedBox(height: 24),
      for (final field in [(goal, 'Hedef'), (summary, 'Durum özeti'), (next, 'Sonraki adım'), (decisions, 'Kararlar · her satıra bir karar')]) ...[
        TextField(controller: field.$1, enabled: !busy, onChanged: (_) => setState(() {}), minLines: 2, maxLines: 8, decoration: InputDecoration(labelText: field.$2, alignLabelWithHint: true)), const SizedBox(height: 20),
      ],
      DropdownButtonFormField<String>(key: ValueKey('source:$revision:$source'), initialValue: source, isExpanded: true, decoration: const InputDecoration(labelText: 'Kaynak oturum'), items: [
        const DropdownMenuItem<String>(value: null, child: Text('Kaynak belirtme')),
        if (source != null && !widget.controller.snapshot.sessions.any((s) => s.projectId == widget.project.id && s.id == source)) DropdownMenuItem(value: source, child: const Text('Kayıtlı kaynak · oturum listede değil')),
        for (final session in widget.controller.snapshot.sessions.where((s) => s.projectId == widget.project.id)) DropdownMenuItem(value: session.id, child: Text(session.name.isEmpty ? 'Adsız oturum' : session.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ], onChanged: busy ? null : (value) => setState(() => source = value)),
      const SizedBox(height: 24),
      FilledButton(onPressed: busy || conflict != null || !widget.controller.connection.connected ? null : save, child: Text(busy ? 'Kaydediliyor…' : 'Hafızayı kaydet')),
    ]))),
  ));
}

class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({super.key, required this.controller, required this.project, this.initialPath = '', this.initialLine});
  final OmputerController controller;
  final Project project;
  final String initialPath;
  final int? initialLine;
  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}
class _FilePreviewScreenState extends State<FilePreviewScreen> {
  late final path = TextEditingController(text: widget.initialPath);
  Json? result;
  String? error, loadedPath;
  bool busy = false;
  @override
  void initState() { super.initState(); if (widget.initialPath.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) load(); }); }
  @override
  void dispose() { path.dispose(); super.dispose(); }
  Future<void> load() async {
    if (path.text.trim().isEmpty || busy || !widget.controller.connection.connected) return;
    final requestedPath = path.text.trim();
    FocusScope.of(context).unfocus();
    setState(() { busy = true; error = null; result = null; loadedPath = null; });
    try { final value = await widget.controller.file(widget.project.id, requestedPath); if (mounted) setState(() { result = value; loadedPath = requestedPath; }); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) => Scaffold(
    appBar: AppBar(title: const Text('Dosya önizlemesi'), actions: [if (result != null) IconButton(tooltip: 'Dosya içeriğini kopyala', onPressed: () => copyText(context, '${result!['text'] ?? ''}'), icon: const Icon(Icons.copy_rounded))]),
    body: SafeArea(top: false, child: ListView(children: [
      Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ConnectionBanner(widget.controller), Text(widget.project.name, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8), const Text('Salt okunur · proje köküne göre dosya yolu. Bilgisayar yol sınırını ve boyutunu doğrular.'), const SizedBox(height: 16), TextField(controller: path, enabled: !busy, onSubmitted: (_) => load(), autocorrect: false, decoration: InputDecoration(labelText: 'Proje içindeki dosya yolu', hintText: 'Örneğin src/main.rs', suffixIcon: IconButton(tooltip: 'Dosyayı aç', onPressed: busy || !widget.controller.connection.connected ? null : load, icon: const Icon(Icons.arrow_forward_rounded))))])),
      if (busy) const LinearProgressIndicator(),
      if (error != null) ErrorNotice(error!, onRetry: load),
      if (result?['truncated'] == true) const Padding(padding: EdgeInsets.all(24), child: Text('Dosya boyut sınırında kesildi. Tam dosyayı bilgisayarda incele.')),
      if (result == null && !busy && error == null) const EmptyState(icon: Icons.description_outlined, title: 'Bir dosyaya göz at.', message: 'Dosya yolunu yazarak içeriğini oku. Bu ekrandan hiçbir dosya değiştirilemez.'),
      if (result != null) Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SelectableText(loadedPath!, style: Theme.of(context).textTheme.labelLarge), if (widget.initialLine != null) Text('Bağlantının hedef satırı: ${widget.initialLine}'), const SizedBox(height: 16), if (result?['binary'] == true) const Text('İkili dosya; metin önizlemesi yok.') else CopyableCode(text: '${result!['text'] ?? ''}', initialLine: widget.initialLine)])),
    ])),
  ));
}
