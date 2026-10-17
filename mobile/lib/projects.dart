import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'session.dart';
import 'interactions.dart';

class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.controller, required this.projectId});
  final OmputerController controller;
  final String projectId;
  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}
class _ProjectScreenState extends State<ProjectScreen> {
  String query = '', filter = 'all';
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final p = c.snapshot.project(widget.projectId);
    if (p == null) return Scaffold(appBar: AppBar(title: const Text('Proje')), body: const EmptyState(icon: Icons.folder_off_outlined, title: 'Proje bulunamadı.', message: 'Bilgisayara yeniden bağlanarak kayıtları yenile.'));
    final sessions = c.snapshot.sessions.where((s) => s.projectId == p.id && s.name.toLowerCase().contains(query.toLowerCase()) && (filter == 'all' || (filter == 'archive' ? s.archived : !s.archived))).toList()..sort((a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
    final pending = c.snapshot.pending.where((i) => i.projectId == p.id).toList();
    return Scaffold(appBar: AppBar(title: Text(p.name), actions: [IconButton(tooltip: 'Yeni oturum', onPressed: c.connection.connected ? () => openScreen(context, NewSessionScreen(controller: c, projectId: p.id)) : null, icon: const Icon(Icons.add_rounded)), IconButton(tooltip: 'Proje dosyası oku', onPressed: () => openScreen(context, FilePreviewScreen(controller: c, project: p)), icon: const Icon(Icons.description_outlined))]), body: SafeArea(top: false, child: CustomScrollView(slivers: [
      SliverToBoxAdapter(child: ConnectionBanner(c)),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 0), child: SelectableText(p.path, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)))),
      if (p.activity case final activity? when activity.hasContext)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [const Icon(Icons.history_rounded), const SizedBox(width: 12), Expanded(child: Text('Son kaldığın yer', style: Theme.of(context).textTheme.titleLarge))]),
                  const SizedBox(height: 12),
                  Text('Konuşmadan ve görevlerden · ${dateLabel(activity.updatedAt)}', style: Theme.of(context).textTheme.labelMedium),
                  if (activity.goal.isNotEmpty) ...[const SizedBox(height: 16), Text(activity.goal, style: Theme.of(context).textTheme.titleMedium)],
                  if (activity.lastAssistantText.isNotEmpty) ...[const SizedBox(height: 16), Text(activity.lastAssistantText, maxLines: 8, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5))],
                  if (activity.nextStep.isNotEmpty) ...[const SizedBox(height: 16), Text('Sıradaki iş', style: Theme.of(context).textTheme.labelLarge), const SizedBox(height: 6), Text(activity.nextStep)],
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(onPressed: () => openScreen(context, SessionScreen(controller: c, sessionId: activity.sessionId), checkpoint: true), icon: const Icon(Icons.arrow_forward_rounded), label: const Text('Bu konuşmaya devam et')),
                ]),
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(child: SectionHeading('Projenin hafızası', action: IconButton(tooltip: 'Proje hafızasını düzenle', onPressed: c.connection.connected ? () => openScreen(context, CheckpointEditor(controller: c, project: p)) : null, icon: const Icon(Icons.edit_outlined)))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _memory(context, 'Hedef', p.goal, 'Henüz hedef kaydedilmedi.'),
        _memory(context, 'Durum özeti', p.summary, 'Henüz özet kaydedilmedi.'),
        _memory(context, 'Sonraki adım', p.nextStep, 'Henüz sonraki adım kaydedilmedi.'),
        Text('Kararlar', style: Theme.of(context).textTheme.titleSmall), const SizedBox(height: 8),
        if (p.decisions.isEmpty) const Text('Henüz karar kaydedilmedi.') else ...p.decisions.map((d) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.check_rounded, size: 18), const SizedBox(width: 10), Expanded(child: SelectableText(d))]))),
        const SizedBox(height: 12), Text('${p.memoryOrigin == 'agent' ? 'Ajanın kaynaklı kaydı' : 'Elle düzenlenen kayıt'} · ${dateLabel(p.memoryUpdatedAt ?? p.updatedAt)}', style: Theme.of(context).textTheme.labelMedium),
        if (p.sourceSessionId != null) Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton.icon(onPressed: () => openScreen(context, SessionScreen(controller: c, sessionId: p.sourceSessionId!), checkpoint: true), icon: const Hero(tag: 'checkpoint-thread', child: Icon(Icons.commit_rounded)), label: const Text('Kaynak oturuma git'))),
      ]))),
      if (pending.isNotEmpty) ...[const SliverToBoxAdapter(child: SectionHeading('Yanıt bekliyor')), SliverList.builder(itemCount: pending.length, itemBuilder: (context, index) => InteractionRow(controller: c, interaction: pending[index]))],
      const SliverToBoxAdapter(child: SectionHeading('Oturumlar')),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: TextField(onChanged: (s) => setState(() => query = s), decoration: const InputDecoration(hintText: 'Bu projede oturum ara', prefixIcon: Icon(Icons.search_rounded))))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Wrap(spacing: 8, children: [('all', 'Tümü'), ('live', 'Canlı'), ('archive', 'Geçmiş')].map((item) => FilterChip(label: Text(item.$2), selected: filter == item.$1, onSelected: (_) => setState(() => filter = item.$1))).toList()))),
      if (sessions.isEmpty) const SliverToBoxAdapter(child: EmptyState(icon: Icons.chat_bubble_outline_rounded, title: 'Burada oturum yok.', message: 'Filtreyi değiştir veya bu projede yeni bir oturum başlat.')),
      SliverList.builder(itemCount: sessions.length, itemBuilder: (context, index) => SessionRow(sessions[index], onTap: () => openScreen(context, SessionScreen(controller: c, sessionId: sessions[index].id)))),
      const SliverPadding(padding: EdgeInsets.only(bottom: 110)),
    ])));
  });
  Widget _memory(BuildContext context, String label, String text, String empty) => Padding(padding: const EdgeInsets.only(bottom: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)), const SizedBox(height: 8), SelectableText(text.isEmpty ? empty : text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5))]));
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
  bool busy = false;
  @override
  void dispose() { goal.dispose(); summary.dispose(); next.dispose(); decisions.dispose(); super.dispose(); }
  Future<void> save() async {
    setState(() => busy = true);
    final ok = await perform(context, () => widget.controller.updateProject(widget.project.id, {'goal': goal.text.trim(), 'summary': summary.text.trim(), 'nextStep': next.text.trim(), 'decisions': decisions.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(), 'sourceSessionId': source}));
    if (mounted) { setState(() => busy = false); if (ok) Navigator.pop(context); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Proje hafızasını düzenle')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [const Text('Bu kayıt senin düzenlediğin kalıcı proje hafızasıdır. Canlı konuşma özeti ayrıca görünür; turun bitmesi projenin tamamlandığı anlamına gelmez.'), const SizedBox(height: 24), for (final field in [(goal, 'Hedef'), (summary, 'Durum özeti'), (next, 'Sonraki adım'), (decisions, 'Kararlar · her satıra bir karar')]) ...[TextField(controller: field.$1, enabled: !busy, minLines: 2, maxLines: 8, decoration: InputDecoration(labelText: field.$2, alignLabelWithHint: true)), const SizedBox(height: 20)], DropdownButtonFormField<String>(initialValue: source, isExpanded: true, decoration: const InputDecoration(labelText: 'Kaynak oturum'), items: [const DropdownMenuItem<String>(value: null, child: Text('Kaynak belirtme')), for (final session in widget.controller.snapshot.sessions.where((s) => s.projectId == widget.project.id)) DropdownMenuItem(value: session.id, child: Text(session.name.isEmpty ? 'Adsız oturum' : session.name, maxLines: 1, overflow: TextOverflow.ellipsis))], onChanged: busy ? null : (value) => setState(() => source = value)), const SizedBox(height: 24), FilledButton(onPressed: busy ? null : save, child: Text(busy ? 'Kaydediliyor…' : 'Hafızayı kaydet'))])));
}

class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({super.key, required this.controller, required this.project});
  final OmputerController controller;
  final Project project;
  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}
class _FilePreviewScreenState extends State<FilePreviewScreen> {
  final path = TextEditingController();
  Json? result;
  String? error;
  bool busy = false;
  @override
  void dispose() { path.dispose(); super.dispose(); }
  Future<void> load() async {
    if (path.text.trim().isEmpty) return;
    setState(() { busy = true; error = null; });
    try { final value = await widget.controller.file(widget.project.id, path.text.trim()); if (mounted) setState(() => result = value); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Dosya önizlemesi'), actions: [if (result != null) IconButton(tooltip: 'Dosya içeriğini kopyala', onPressed: () => copyText(context, '${result!['text'] ?? ''}'), icon: const Icon(Icons.copy_rounded))]), body: SafeArea(top: false, child: Column(children: [Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.project.name, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8), const Text('Salt okunur · proje köküne göre dosya yolu. Bilgisayar yol sınırını ve boyutunu doğrular.'), const SizedBox(height: 16), TextField(controller: path, onSubmitted: (_) => load(), autocorrect: false, decoration: InputDecoration(labelText: 'Örneğin src/main.rs', suffixIcon: IconButton(tooltip: 'Dosyayı aç', onPressed: busy ? null : load, icon: const Icon(Icons.arrow_forward_rounded))))])), if (busy) const LinearProgressIndicator(), if (error != null) ErrorNotice(error!, onRetry: load), if (result?['truncated'] == true) const Padding(padding: EdgeInsets.all(16), child: Text('Dosya boyut sınırında kesildi. Tam dosyayı bilgisayarda incele.')), Expanded(child: result == null ? const SingleChildScrollView(child: EmptyState(icon: Icons.description_outlined, title: 'Bir dosyaya göz at.', message: 'Dosya yolunu yazarak içeriğini oku. Bu ekrandan hiçbir dosya değiştirilemez.')) : SingleChildScrollView(padding: const EdgeInsets.all(24), child: SelectableText('${result!['text'] ?? ''}', style: const TextStyle(fontFamily: 'monospace', height: 1.5))))])));
}
