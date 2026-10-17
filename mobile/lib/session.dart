import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'interactions.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.controller, required this.sessionId});
  final OmputerController controller;
  final String sessionId;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}
class _SessionScreenState extends State<SessionScreen> {
  final message = TextEditingController();
  final scroll = ScrollController();
  String mode = 'session.prompt';
  bool sending = false;
  late Transcript transcript;
  @override
  void initState() {
    super.initState();
    transcript = widget.controller.transcript(widget.sessionId);
    widget.controller.loadMessages(widget.sessionId);
  }
  @override
  void dispose() { message.dispose(); scroll.dispose(); super.dispose(); }
  Future<void> send(Session session) async {
    final value = message.text.trim();
    if (value.isEmpty) return;
    setState(() => sending = true);
    final ok = await perform(context, () async { await widget.controller.command(mode, sessionId: session.id, payload: {'message': value}); });
    if (mounted) { setState(() => sending = false); if (ok) message.clear(); }
  }
  Future<void> action(Session session, String action) async {
    final c = widget.controller;
    switch (action) {
      case 'model':
        await chooseModel(context, c, (model) async { await c.command('session.model', sessionId: session.id, payload: {'provider': model.provider, 'modelId': model.id}); });
      case 'thinking':
        final result = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [const ListTile(title: Text('Düşünme düzeyi')), for (final level in ['off', 'minimal', 'low', 'medium', 'high', 'xhigh']) ListTile(title: Text(switch (level) { 'off' => 'Kapalı', 'minimal' => 'En az', 'low' => 'Düşük', 'medium' => 'Orta', 'high' => 'Yüksek', _ => 'Çok yüksek' }), trailing: session.thinkingLevel == level ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(context, level))])));
        if (result != null && mounted) await perform(context, () async { await c.command('session.thinking', sessionId: session.id, payload: {'level': result}); });
      case 'abort':
        if (await confirm(context, 'Bu oturumun çalışmasını kes?', 'OMP’nin bu oturumdaki aktif üretimini ve çalışma araçlarını durdurma isteği gönderilir. Ayrı / arka plan süreçlerinin veya diğer oturumların sonlandığı anlamına gelmez. Telefonun bağlantısını kesmek işi durdurmaz.', action: 'Çalışmayı kes') && mounted) await perform(context, () async { await c.command('session.abort', sessionId: session.id); }, success: 'Kesme isteği bilgisayara iletildi.');
      case 'rename':
        final name = await textDialog(context, 'Oturumu yeniden adlandır', 'Oturum adı', initial: session.name);
        if (name != null && name.trim().isNotEmpty && mounted) await perform(context, () async { await c.command('session.rename', sessionId: session.id, payload: {'name': name.trim()}); });
      case 'compact':
        final instructions = await textDialog(context, 'Konuşmayı sıkıştır', 'Ek yönerge (isteğe bağlı)', message: 'OMP bağlamı özetleyerek sıkıştırır. Bu, projenin tamamlandığı anlamına gelmez.');
        if (instructions != null && mounted) await perform(context, () async { await c.command('session.compact', sessionId: session.id, payload: {if (instructions.trim().isNotEmpty) 'instructions': instructions.trim()}); });
      case 'refresh':
        await perform(context, () async { await c.command('session.refresh', sessionId: session.id); await c.refresh(); await c.loadMessages(session.id); });
      case 'bash':
        final command = await textDialog(context, 'Bilgisayarda kabuk komutu', 'Çalıştırılacak komut', message: 'Bu, bilgisayarında gerçek bir kabuk komutu çalıştırır. OMP’ye doğal dil istemi göndermek için konuşma alanını kullan.');
        if (command != null && command.trim().isNotEmpty && mounted && await confirm(context, 'Komutu çalıştır?', command, action: 'Çalıştır') && mounted) await perform(context, () async { await c.command('session.bash', sessionId: session.id, payload: {'command': command}); });
      case 'agents':
        openScreen(context, AgentsScreen(controller: c, sessionId: session.id));
      case 'todos':
        openScreen(context, TodosScreen(controller: c, sessionId: session.id));
    }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final session = c.snapshot.session(widget.sessionId);
    final pending = c.snapshot.pending.where((i) => i.sessionId == widget.sessionId).toList();
    final live = session != null && !session.archived;
    final availableModes = ['session.prompt', 'session.steer', 'session.follow_up'].where((m) => session?.supports(m) == true).toList();
    if (availableModes.isNotEmpty && !availableModes.contains(mode)) mode = availableModes.first;
    return Scaffold(appBar: AppBar(title: Text(session?.name.isNotEmpty == true ? session!.name : 'Konuşma'), actions: [if (session != null) PopupMenuButton<String>(tooltip: 'Oturum kontrolleri', onSelected: (value) => action(session, value), itemBuilder: (context) => [
      if (session.todos.isNotEmpty) const PopupMenuItem(value: 'todos', child: Text('Yapılacaklar')),
      if (session.subagents.isNotEmpty || session.supports('agent.command')) const PopupMenuItem(value: 'agents', child: Text('Alt ajanlar')),
      for (final item in [('model', 'session.model', 'Modeli değiştir'), ('thinking', 'session.thinking', 'Düşünme düzeyi'), ('rename', 'session.rename', 'Yeniden adlandır'), ('compact', 'session.compact', 'Konuşmayı sıkıştır'), ('refresh', 'session.refresh', 'Oturum durumunu yenile'), ('bash', 'session.bash', 'Kabuk komutu çalıştır'), ('abort', 'session.abort', 'Çalışmayı kes')])
        if (session.supports(item.$2)) PopupMenuItem(value: item.$1, enabled: c.connection.connected, child: Text(item.$3)),
    ])]), body: SafeArea(top: false, child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 4, 24, 12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Hero(tag: 'checkpoint-thread', child: Icon(Icons.commit_rounded, color: Theme.of(context).colorScheme.primary)), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(c.snapshot.project(session?.projectId ?? '')?.name ?? 'Kaynak konuşma', style: Theme.of(context).textTheme.labelLarge), const SizedBox(height: 4), Text('${session?.statusLabel ?? 'Oturum bilgisi alınamadı'}${c.connection.connected ? '' : ' · Çevrimdışı'}', style: Theme.of(context).textTheme.bodySmall)]))])),
      if (session?.lastError != null) ErrorNotice(session!.lastError!),
      if (pending.isNotEmpty) Material(color: Theme.of(context).colorScheme.secondaryContainer, child: ListTile(leading: const Icon(Icons.pending_actions_rounded), title: Text(pending.first.title, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text('${pending.length} karar bekliyor'), trailing: const Icon(Icons.arrow_forward_rounded), onTap: () => openScreen(context, InteractionScreen(controller: c, interactionId: pending.first.id)))),
      if (session?.model != null || session?.thinkingLevel != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), child: Align(alignment: Alignment.centerLeft, child: Text([session?.model?.name, session?.thinkingLevel == null ? null : 'Düşünme: ${session!.thinkingLevel}'].whereType<String>().join(' · '), style: Theme.of(context).textTheme.labelMedium))),
      Expanded(child: ListenableBuilder(listenable: transcript, builder: (context, _) {
        if (transcript.ids.isEmpty && transcript.loading) return const Center(child: CircularProgressIndicator());
        if (transcript.ids.isEmpty && transcript.error != null) return SingleChildScrollView(child: ErrorNotice(transcript.error!, onRetry: () => c.loadMessages(widget.sessionId)));
        if (transcript.ids.isEmpty) return const SingleChildScrollView(child: EmptyState(icon: Icons.forum_outlined, title: 'Konuşma burada başlar.', message: 'İlk istemi gönder. Canlı mesajlar ve araç sonuçları bilgisayardan geldikçe bu konuşmada görünür. Çevrimdışıysa daha önce açılmamış konuşma geçmişi alınamaz.'));
        return ListView.builder(controller: scroll, reverse: true, padding: const EdgeInsets.only(bottom: 24), itemCount: transcript.ids.length + 1, itemBuilder: (context, index) {
          if (index == transcript.ids.length) return Column(children: [if (transcript.hasMore) TextButton.icon(onPressed: transcript.loading ? null : () => c.loadMessages(widget.sessionId, older: true), icon: transcript.loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.history_rounded), label: const Text('Önceki mesajları yükle')), if (transcript.error != null) ErrorNotice(transcript.error!)]);
          final id = transcript.ids[transcript.ids.length - index - 1];
          return RepaintBoundary(key: ValueKey(id), child: ValueListenableBuilder<ChatMessage>(valueListenable: transcript.messages[id]!, builder: (context, msg, _) => MessageView(message: msg)));
        });
      })),
      if (session?.archived == true) Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('Geçmiş oturum · yeniden açılana kadar salt okunur.'), const SizedBox(height: 10), FilledButton.icon(onPressed: !c.connection.connected || sending ? null : () async {
        setState(() => sending = true);
        await perform(context, () async { await c.command('session.resume', sessionId: session!.id, payload: {'sessionId': session.id}); await c.refresh(); }, success: 'Oturumu sürdürme isteği iletildi.');
        if (mounted) setState(() => sending = false);
      }, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Oturumu sürdür'))])),
      if (live && availableModes.isNotEmpty) _composer(context, session, availableModes),
      if (live && availableModes.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Bu çalışma zamanı telefondan istem göndermeyi desteklemiyor. Mevcut konuşma salt okunur.')),
    ])));
  });

  Widget _composer(BuildContext context, Session session, List<String> modes) {
    final enabled = widget.controller.connection.connected && !sending;
    return Material(color: Theme.of(context).colorScheme.surfaceContainerLow, child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [Expanded(child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: mode, isExpanded: true, items: modes.map((m) => DropdownMenuItem(value: m, child: Text(modeLabel(m)))).toList(), onChanged: sending ? null : (value) => setState(() => mode = value!)))), if (session.supports('session.abort') && session.status == 'running') IconButton(tooltip: 'Çalışmayı kes', onPressed: enabled ? () => action(session, 'abort') : null, icon: const Icon(Icons.stop_circle_outlined))]),
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Align(alignment: Alignment.centerLeft, child: Text(switch (mode) { 'session.steer' => 'Devam eden çalışmayı yönlendirir; yeni bir oturum açmaz.', 'session.follow_up' => 'Geçerli turdan sonra ele alınacak takip istemi.', _ => 'Bu konuşmaya yeni bir istem gönder.' }, style: Theme.of(context).textTheme.bodySmall))),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: TextField(controller: message, enabled: !sending, minLines: 1, maxLines: 6, textCapitalization: TextCapitalization.sentences, onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'OMP’ye yaz…'))), const SizedBox(width: 8), IconButton.filled(tooltip: modeLabel(mode), onPressed: enabled && message.text.trim().isNotEmpty ? () => send(session) : null, icon: sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward_rounded), style: IconButton.styleFrom(minimumSize: const Size(52, 52)))])
    ])));
  }
}

String modeLabel(String mode) => switch (mode) { 'session.steer' => 'Yönlendir (steer)', 'session.follow_up' => 'Takibe ekle (follow-up)', _ => 'İstem gönder (prompt)' };

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Padding(padding: EdgeInsets.fromLTRB(user ? 40 : 24, 18, 24, 8), child: Material(color: user ? scheme.primaryContainer.withValues(alpha: .55) : Colors.transparent, borderRadius: BorderRadius.circular(20), child: Padding(padding: EdgeInsets.all(user ? 16 : 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(switch (message.role) { 'user' => 'Sen', 'assistant' => 'OMP', 'toolResult' => 'Araç sonucu', _ => message.role }, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary)), const SizedBox(height: 10), for (var i = 0; i < message.content.length; i++) _block(context, message.content[i], '${message.id}:$i'), if (message.timestamp != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(dateLabel(message.timestamp), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)))]))));
  }
  Widget _block(BuildContext context, Json block, String key) {
    final type = '${block['type'] ?? 'text'}';
    if (type == 'text') return Padding(padding: const EdgeInsets.only(bottom: 8), child: LocalMarkdown(data: '${block['text'] ?? ''}', styleSheet: MarkdownStyleSheet(p: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55))));
    if (type == 'thinking' || type == 'reasoning') return ExpansionTile(key: PageStorageKey(key), tilePadding: EdgeInsets.zero, title: const Text('Düşünme'), leading: const Icon(Icons.psychology_outlined), initiallyExpanded: false, children: [Padding(padding: const EdgeInsets.only(bottom: 16), child: Align(alignment: Alignment.centerLeft, child: SelectableText('${block['thinking'] ?? block['text'] ?? ''}', style: Theme.of(context).textTheme.bodyMedium)))]);
    if (type == 'image') {
      final source = object(block['source']);
      final data = block['data'] ?? source['data'];
      if (data is String) return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: embeddedImage(data));
      final url = block['url'] ?? source['url'];
      return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Görsel referansı'), if (url != null) SelectableText('$url') else const Text('Görsel baytları bu kayıtta bulunmuyor; bilgisayardaki konuşmayı incele.')]));
    }
    final title = type == 'toolCall' ? '${block['name'] ?? 'Araç çağrısı'}' : type == 'toolResult' ? '${block['toolName'] ?? block['name'] ?? 'Araç sonucu'}' : type;
    final content = block['arguments'] ?? block['content'] ?? block['result'] ?? block;
    return ExpansionTile(key: PageStorageKey(key), tilePadding: EdgeInsets.zero, leading: Icon(block['isError'] == true ? Icons.error_outline_rounded : Icons.build_outlined), title: Text(title), subtitle: type == 'toolCall' ? const Text('Çağrı parametreleri') : null, children: [Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)), child: SelectableText(content is String ? content : const JsonEncoder.withIndent('  ').convert(content), style: const TextStyle(fontFamily: 'monospace', height: 1.5)))]);
  }
}

Future<String?> textDialog(BuildContext context, String title, String label, {String initial = '', String? message}) async {
  final input = TextEditingController(text: initial);
  final result = await showDialog<String>(context: context, builder: (context) => AlertDialog(title: Text(title), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [if (message != null) ...[Text(message), const SizedBox(height: 16)], TextField(controller: input, minLines: 1, maxLines: 6, decoration: InputDecoration(labelText: label))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')), FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('Gönder'))]));
  // The route owns a closing animation; dispose only after it releases widgets.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  input.dispose();
  return result;
}

Future<void> chooseModel(BuildContext context, OmputerController controller, Future<void> Function(ModelInfo) selected) async {
  List<ModelInfo> models;
  try { models = await controller.models(); }
  catch (e) { if (context.mounted) await perform(context, () async { throw e; }); return; }
  if (!context.mounted) return;
  final choice = await showModalBottomSheet<ModelInfo>(context: context, isScrollControlled: true, showDragHandle: true, builder: (context) => ModelPicker(models: models));
  if (choice != null && context.mounted) await perform(context, () => selected(choice));
}

class ModelPicker extends StatefulWidget {
  const ModelPicker({super.key, required this.models});
  final List<ModelInfo> models;
  @override
  State<ModelPicker> createState() => _ModelPickerState();
}
class _ModelPickerState extends State<ModelPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final models = widget.models.where((m) => '${m.provider} ${m.name} ${m.id}'.toLowerCase().contains(query.toLowerCase())).toList();
    return SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .75, child: Column(children: [Padding(padding: const EdgeInsets.all(24), child: TextField(onChanged: (value) => setState(() => query = value), decoration: const InputDecoration(hintText: 'Model ara', prefixIcon: Icon(Icons.search_rounded)))), Expanded(child: models.isEmpty ? const SingleChildScrollView(child: EmptyState(icon: Icons.model_training_rounded, title: 'Kullanılabilir model yok.', message: 'Modeller canlı OMP çalışma zamanından gelir. Bilgisayarındaki sağlayıcı ayarlarını ve canlı oturumu kontrol et.')) : ListView.builder(itemCount: models.length, itemBuilder: (context, index) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), title: Text(models[index].name), subtitle: Text('${models[index].provider} · ${models[index].id}'), onTap: () => Navigator.pop(context, models[index]))))])));
  }
}

class NewSessionScreen extends StatefulWidget {
  const NewSessionScreen({super.key, required this.controller, this.projectId});
  final OmputerController controller;
  final String? projectId;
  @override
  State<NewSessionScreen> createState() => _NewSessionScreenState();
}
class _NewSessionScreenState extends State<NewSessionScreen> {
  late String? projectId = widget.projectId;
  final name = TextEditingController(), prompt = TextEditingController();
  ModelInfo? model;
  bool busy = false;
  @override
  void dispose() { name.dispose(); prompt.dispose(); super.dispose(); }
  Future<void> start() async {
    if (projectId == null) return;
    setState(() => busy = true);
    try {
      final result = await widget.controller.command('session.start', payload: {'projectId': projectId, if (name.text.trim().isNotEmpty) 'name': name.text.trim(), if (prompt.text.trim().isNotEmpty) 'prompt': prompt.text.trim(), if (model != null) 'model': {'provider': model!.provider, 'id': model!.id}});
      await widget.controller.refresh();
      final data = object(result['data']);
      final id = data['sessionId'] ?? data['id'] ?? object(data['session'])['id'];
      if (mounted) {
        if (id is String) Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => SessionScreen(controller: widget.controller, sessionId: id)));
        else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Oturum başlatıldı. Projendeki güncel oturum listesinden açabilirsin.'))); Navigator.pop(context); }
      }
    } catch (e) { if (mounted) await perform(context, () async { throw e; }); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Yeni oturum')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [Text('Bir sonraki adımı başlat.', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 12), const Text('Yalnızca bilgisayarda kayıtlı proje köklerinde yeni bir OMP oturumu açılır. Çalışma bilgisayarında yürür.'), const SizedBox(height: 24), DropdownButtonFormField<String>(initialValue: projectId, isExpanded: true, decoration: const InputDecoration(labelText: 'Proje'), items: widget.controller.snapshot.projects.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis))).toList(), onChanged: busy ? null : (value) => setState(() => projectId = value)), const SizedBox(height: 20), TextField(controller: name, enabled: !busy, decoration: const InputDecoration(labelText: 'Oturum adı (isteğe bağlı)')), const SizedBox(height: 20), TextField(controller: prompt, enabled: !busy, minLines: 4, maxLines: 12, decoration: const InputDecoration(labelText: 'İlk istem (isteğe bağlı)', alignLabelWithHint: true)), const SizedBox(height: 20), ListTile(contentPadding: EdgeInsets.zero, title: const Text('Model'), subtitle: Text(model == null ? 'Bilgisayardaki OMP varsayılanı' : '${model!.provider} · ${model!.name}'), trailing: const Icon(Icons.expand_more_rounded), onTap: busy ? null : () => chooseModel(context, widget.controller, (choice) async { setState(() => model = choice); })), if (model != null) TextButton(onPressed: busy ? null : () => setState(() => model = null), child: const Text('Varsayılan modeli kullan')), const SizedBox(height: 24), FilledButton.icon(onPressed: busy || projectId == null || !widget.controller.connection.connected ? null : start, icon: const Icon(Icons.play_arrow_rounded), label: Text(busy ? 'Başlatılıyor…' : 'Oturumu başlat'))])));
}

class TodosScreen extends StatelessWidget {
  const TodosScreen({super.key, required this.controller, required this.sessionId});
  final OmputerController controller;
  final String sessionId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) {
    final phases = controller.snapshot.session(sessionId)?.todos ?? [];
    final todos = <Json>[];
    for (final phase in phases) {
      if (phase['tasks'] is List) {
        for (final task in objects(phase['tasks'])) { todos.add({...task, if (phase['name'] != null) 'phase': phase['name']}); }
      } else { todos.add(phase); }
    }
    return Scaffold(appBar: AppBar(title: const Text('Yapılacaklar')), body: SafeArea(top: false, child: todos.isEmpty ? const SingleChildScrollView(child: EmptyState(icon: Icons.checklist_rounded, title: 'Kayıtlı görev yok.', message: 'OMP’nin paylaştığı görev listesi burada görünür. Görevler bu görünümde salt okunurdur.')) : ListView.builder(itemCount: todos.length, itemBuilder: (context, index) {
      final todo = todos[index];
      final done = todo['status'] == 'completed' || todo['completed'] == true;
      return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: Icon(done ? Icons.check_circle_outline_rounded : todo['status'] == 'in_progress' ? Icons.pending_outlined : Icons.radio_button_unchecked_rounded), title: Text('${todo['text'] ?? todo['content'] ?? todo['title'] ?? todo['description'] ?? ''}'), subtitle: Text([todo['phase'], todo['status']].whereType<String>().join(' · ')));
    })));
  });
}

class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key, required this.controller, required this.sessionId});
  final OmputerController controller;
  final String sessionId;
  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}
class _AgentsScreenState extends State<AgentsScreen> {
  final Set<String> busy = {};
  Future<void> command(Json agent, String command) async {
    final id = '${agent['id'] ?? agent['agentId'] ?? agent['name'] ?? ''}';
    String? message;
    if (command == 'chat') {
      message = await textDialog(context, 'Alt ajana mesaj gönder', 'Mesaj');
      if (message == null || message.trim().isEmpty) return;
    }
    if (command == 'kill' && !await confirm(context, 'Alt ajanı durdur?', '$id adlı ajana durdurma komutu gönderilecek. Diğer ajanların sonlandığı anlamına gelmez.', action: 'Durdur')) return;
    if (!mounted) return;
    setState(() => busy.add(id));
    await perform(context, () async { await widget.controller.command('agent.command', sessionId: widget.sessionId, payload: {'agentId': id, 'command': command, if (message != null) 'message': message}); await widget.controller.refresh(); }, success: 'Alt ajan komutu iletildi.');
    if (mounted) setState(() => busy.remove(id));
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final session = widget.controller.snapshot.session(widget.sessionId);
    final agents = session?.subagents ?? [];
    return Scaffold(appBar: AppBar(title: const Text('Alt ajanlar')), body: SafeArea(top: false, child: agents.isEmpty ? const SingleChildScrollView(child: EmptyState(icon: Icons.account_tree_outlined, title: 'Etkin alt ajan görünmüyor.', message: 'Bu oturum alt ajan durumunu paylaştığında gerçek görevleri ve durumları burada görünür.')) : ListView.builder(itemCount: agents.length, itemBuilder: (context, index) {
      final agent = agents[index];
      final id = '${agent['id'] ?? agent['agentId'] ?? agent['name'] ?? ''}';
      final enabled = widget.controller.connection.connected && !busy.contains(id) && session?.supports('agent.command') == true;
      return Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${agent['name'] ?? id}', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 8), Text('${agent['status'] ?? 'Durum belirtilmedi'}'), if (agent['task'] != null || agent['description'] != null) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText('${agent['task'] ?? agent['description']}')), if (agent['result'] != null) ExpansionTile(title: const Text('Sonuç'), tilePadding: EdgeInsets.zero, children: [SelectableText('${agent['result']}')]), const SizedBox(height: 12), Wrap(spacing: 8, children: [if (session?.supports('agent.chat') == true) OutlinedButton.icon(onPressed: enabled ? () => command(agent, 'chat') : null, icon: const Icon(Icons.chat_outlined), label: const Text('Mesaj')), if (session?.supports('agent.revive') == true) TextButton(onPressed: enabled ? () => command(agent, 'revive') : null, child: const Text('Yeniden etkinleştir')), if (session?.supports('agent.kill') == true) TextButton(onPressed: enabled ? () => command(agent, 'kill') : null, child: const Text('Durdur'))]), const SizedBox(height: 20), const Divider()]));
    })));
  });
}
