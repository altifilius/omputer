import 'dart:convert';
import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'session.dart' show textDialog, boundedImage;

String controlText(Object? value) => value is String ? value : const JsonEncoder.withIndent('  ').convert(value);

/// A palette is tied to one catalog revision. A stale selection is never a prompt.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.controller, required this.sessionId, required this.onLocal, this.initialQuery = '', this.initialArgs = ''});
  final OmputerController controller;
  final String sessionId, initialQuery, initialArgs;
  final Future<void> Function(String) onLocal;
  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}
class _CommandPaletteState extends State<CommandPalette> {
  late final query = TextEditingController(text: widget.initialQuery.replaceFirst(RegExp(r'^/'), ''));
  late final args = TextEditingController(text: widget.initialArgs);
  Json? catalog, selected;
  String? error;
  bool busy = false;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    try { final result = await widget.controller.controls(widget.sessionId, 'commands'); if (mounted) setState(() { catalog = result; error = null; selected = null; }); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
  }
  @override
  void dispose() { query.dispose(); args.dispose(); super.dispose(); }
  Future<void> execute() async {
    final command = selected;
    if (command == null || busy || command['available'] != true) return;
    final risk = '${command['risk'] ?? 'execute'}';
    final needsConsent = !['read'].contains(risk) && command['localAction'] == null;
    if (needsConsent && !await confirm(context, '/${command['name']} çalıştır?', '${command['description'] ?? ''}\n\nKaynak: ${command['source']} · Risk: $risk\n${args.text}', action: 'Çalıştır')) return;
    if (!mounted) return;
    setState(() { busy = true; error = null; });
    try {
      if (command['localAction'] is String) {
        await widget.onLocal(command['localAction'] as String);
      } else {
        final result = await widget.controller.executeCommand(widget.sessionId, '${command['id']}', args.text, catalogRevision: catalog!['catalogRevision'], confirmed: needsConsent);
        if (mounted) Navigator.pop(context, result['id'] ?? true);
        return;
      }
      if (mounted) Navigator.pop(context, true);
    } on CommandAccepted catch (e) { if (mounted) Navigator.pop(context, e.id); }
    on CommandUncertain catch (e) { if (mounted) Navigator.pop(context, e.id); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final needle = query.text.toLowerCase();
    final commands = objects(catalog?['commands']).where((c) => '${c['name']} ${strings(c['aliases']).join(' ')} ${c['description']}'.toLowerCase().contains(needle)).toList();
    return Scaffold(appBar: AppBar(title: const Text('Komutlar'), actions: [IconButton(tooltip: 'Komut kataloğunu yenile', onPressed: busy ? null : load, icon: const Icon(Icons.refresh_rounded))]), body: SafeArea(top: false, child: Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: TextField(controller: query, autofocus: true, enabled: !busy, onChanged: (_) => setState(() => selected = null), decoration: const InputDecoration(labelText: 'Komut veya takma ad ara', prefixText: '/'))),
      if (error != null) ErrorNotice(error!),
      if (catalog == null && error == null) const LinearProgressIndicator(),
      Expanded(child: ListView(children: [
        for (final command in commands) ListTile(selected: selected?['id'] == command['id'], title: Text('/${command['name']}'), subtitle: Text([command['description'], 'Kaynak: ${command['source']} · Risk: ${command['risk']}', if (strings(command['aliases']).isNotEmpty) 'Takma ad: ${strings(command['aliases']).join(', ')}', if (command['available'] != true) command['unavailableReason'] ?? 'Bu oturumda kullanılamıyor', if (command['requiresIdle'] == true) 'Boşta oturum gerektirir'].join('\n')), isThreeLine: false, trailing: Icon(command['available'] == true ? Icons.chevron_right_rounded : Icons.lock_outline_rounded), onTap: busy ? null : () => setState(() { selected = command; })),
        if (catalog != null && commands.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Eşleşen komut yok. Bilinmeyen / komutları modele gönderilmez.')),
      ])),
      if (selected != null) Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (selected!['inputHint'] != null) Text('${selected!['inputHint']}'),
        if (strings(selected!['subcommands']).isNotEmpty) Text('Alt komutlar: ${strings(selected!['subcommands']).join(', ')}'),
        if (selected!['localAction'] == null) TextField(controller: args, enabled: !busy, minLines: 1, maxLines: 4, decoration: const InputDecoration(labelText: 'Komut argümanları')),
        const SizedBox(height: 12), FilledButton.icon(onPressed: selected!['available'] == true && !busy && widget.controller.connection.connected ? execute : null, icon: const Icon(Icons.play_arrow_rounded), label: Text(busy ? 'İletiliyor…' : '/${selected!['name']} çalıştır')),
      ])),
    ])));
  }
}

class OperationsScreen extends StatefulWidget {
  const OperationsScreen({super.key, required this.controller, required this.sessionId, this.operationId});
  final OmputerController controller;
  final String sessionId;
  final String? operationId;
  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}
class _OperationsScreenState extends State<OperationsScreen> {
  String? error;
  bool hasMore = false, loading = false;
  int? cursor;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load({bool older = false}) async {
    if (loading) return;
    setState(() => loading = true);
    try {
      if (widget.sessionId.isNotEmpty) {
        final page = await widget.controller.loadOperations(widget.sessionId, before: older ? cursor : null);
        if (mounted) setState(() { hasMore = page['hasMore'] == true; cursor = (page['nextCursor'] as num?)?.toInt(); });
      }
      if (widget.operationId != null) await widget.controller.operation(widget.operationId!);
      await widget.controller.reconcileOperations();
      if (mounted) setState(() => error = null);
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => loading = false); }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final items = widget.sessionId.isEmpty ? widget.controller.operations.where((op) => widget.operationId == null || op['id'] == widget.operationId).toList() : widget.controller.operationsFor(widget.sessionId);
    return Scaffold(appBar: AppBar(title: const Text('İşlem geçmişi'), actions: [IconButton(tooltip: 'İşlem durumlarını yenile', onPressed: load, icon: const Icon(Icons.refresh_rounded))]), body: SafeArea(top: false, child: ListView(children: [
      if (error != null) ErrorNotice(error!, onRetry: load),
      const Padding(padding: EdgeInsets.all(24), child: Text('Her işlem kendi kimliğiyle izlenir. Kabul edildi durumu tamamlandı anlamına gelmez. Bağlantısı belirsiz işlemler otomatik yeniden çalıştırılmaz.')),
      if (items.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Bu oturumda kayıtlı işlem yok.')),
      for (final item in items) OperationOutput(key: ValueKey(item['id']), controller: widget.controller, operation: item, initiallyExpanded: widget.operationId == item['id']),
      if (hasMore) TextButton(onPressed: loading ? null : () => load(older: true), child: const Text('Önceki işlemleri yükle')),
      if (loading) const LinearProgressIndicator(),
    ])));
  });
}
class OperationOutput extends StatefulWidget {
  const OperationOutput({super.key, required this.controller, required this.operation, this.initiallyExpanded = false});
  final OmputerController controller;
  final Json operation;
  final bool initiallyExpanded;
  @override
  State<OperationOutput> createState() => _OperationOutputState();
}
class _OperationOutputState extends State<OperationOutput> {
  final List<Json> output = [];
  bool busy = false, hasMore = true;
  int after = 0;
  String? error;
  @override
  void initState() { super.initState(); if (widget.initiallyExpanded) load(); }
  Future<void> load() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.controller.operation('${widget.operation['id']}');
      final page = await widget.controller.operationOutput('${widget.operation['id']}', after: after);
      final rows = objects(page['items']);
      if (mounted) setState(() { output.addAll(rows); if (rows.isNotEmpty) after = (rows.last['sequence'] as num).toInt(); hasMore = page['hasMore'] == true; error = null; });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final op = widget.operation;
    final result = object(op['result']);
    return ExpansionTile(key: PageStorageKey('operation:${op['id']}'), initiallyExpanded: widget.initiallyExpanded, onExpansionChanged: (open) { if (open && output.isEmpty) load(); }, title: Text('${op['action']} · ${op['status']}'), subtitle: Text('${op['id']}\n${op['updatedAt'] ?? op['createdAt'] ?? ''}'), children: [
      if (result.isNotEmpty) Padding(padding: const EdgeInsets.all(16), child: SelectableText(controlText(result), key: PageStorageKey('operation:${op['id']}:result'))),
      for (final row in output) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Align(alignment: Alignment.centerLeft, child: SelectableText('${row['kind']}: ${row['text']}', key: PageStorageKey('operation:${op['id']}:output:${row['sequence']}'), style: const TextStyle(fontFamily: 'monospace')))),
      if (error != null) ErrorNotice(error!),
      Wrap(spacing: 8, children: [TextButton.icon(onPressed: busy ? null : load, icon: const Icon(Icons.refresh_rounded), label: Text(busy ? 'Alınıyor…' : hasMore ? 'Sonraki çıktıyı yükle' : 'Yeni çıktı ve durumu al')), TextButton.icon(onPressed: () => copyText(context, [controlText(result), ...output.map((r) => '${r['kind']}: ${r['text']}')].join('\n')), icon: const Icon(Icons.copy_rounded), label: const Text('Çıktıyı kopyala'))]),
    ]);
  }
}

Future<bool> reviewBranchDraft(BuildContext context, OmputerController controller, Json operation) async {
  final key = '${object(operation['branchRestore'])['key']}';
  final expected = await controller.loadDraft(key);
  final recovered = await controller.loadDraft('${operation['branchDraftKey']}');
  if (!context.mounted) return false;
  if (recovered == null) throw ControllerFailure('Dal taslağı açılamadı. İşlem sonucunu kontrol et.', 'missing_draft');
  final accepted = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
    title: const Text('Dal istemini geri yükle'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Geri yüklenecek istem'), SelectableText('${recovered['text']}'),
      Text('${objects(recovered['attachments']).length} görsel'),
      for (final image in objects(recovered['attachments'])) Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(height: 96, child: boundedImage('${image['data']}'))),
      if (OmputerController.hasDraft(expected)) ...[const SizedBox(height: 16), const Text('Geçerli gönderilmemiş taslağın değiştirilecek:'), SelectableText('${expected?['text'] ?? ''}'), Text('${objects(expected?['attachments']).length} görsel · ${objects(expected?['files']).length} dosya')],
      const SizedBox(height: 12), const Text('İptal edersen her iki taslak da korunur. İstem kendiliğinden gönderilmez.'),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('İkisini de koru')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('İstemi geri yükle'))],
  ));
  if (accepted != true) return false;
  await controller.restoreBranchDraft('${operation['id']}', expected: expected);
  return true;
}

/// Host-backed controls use the same identity-fenced controller as the palette.
class SessionControlScreen extends StatefulWidget {
  const SessionControlScreen({super.key, required this.controller, required this.sessionId, required this.view, required this.title, this.arguments = const {}});
  final OmputerController controller;
  final String sessionId, view, title;
  final Json arguments;
  @override
  State<SessionControlScreen> createState() => _SessionControlScreenState();
}
class _SessionControlScreenState extends State<SessionControlScreen> {
  Json? data;
  String? error;
  bool busy = false;
  bool loading = false, hasMore = false;
  int nextOffset = 0, nextByte = 0;
  String? pageIdentity;
  final pageRows = <Json>[];
  final pageIds = <String>{};
  String get identity {
    final session = widget.controller.snapshot.session(widget.sessionId);
    return '${widget.controller.localState['identity']}|${session?.journalId}|${session?.bindingRevision}';
  }
  final input = TextEditingController();
  @override
  void initState() { super.initState(); load(); }
  @override
  void dispose() { input.dispose(); super.dispose(); }
  Future<void> load({bool more = false}) async {
    if (loading) return;
    if (more && pageIdentity != identity) {
      setState(() => error = 'Oturum değişti. Yeni kimliğin kayıtlarını almak için görünümü yenile.');
      return;
    }
    final requestedIdentity = identity;
    final cursor = widget.view == 'entries' ? nextOffset : nextByte;
    setState(() => loading = true);
    try {
      final result = await widget.controller.controls(widget.sessionId, widget.view, arguments: {
        ...widget.arguments,
        if (widget.view == 'entries') ...{'limit': 200, 'offset': more ? nextOffset : 0},
        if (widget.view == 'agentMessages') 'fromByte': more ? nextByte : 0,
      });
      if (!mounted || requestedIdentity != identity) return;
      final paged = widget.view == 'entries' || widget.view == 'agentMessages';
      final replace = !more || result['reset'] == true || pageIdentity != requestedIdentity;
      final entries = objects(result['entries']);
      final incoming = widget.view == 'entries' ? entries : objects(result['messages']);
      final messageEntries = entries.where((entry) => entry['message'] is Map).toList();
      final records = widget.view == 'agentMessages' && messageEntries.isNotEmpty
        ? messageEntries.map((entry) => <String, dynamic>{...object(entry['message']), 'id': entry['id'] ?? object(entry['message'])['id'], 'timestamp': entry['timestamp']}).toList()
        : incoming;
      setState(() {
        if (paged) {
          if (replace) { pageRows.clear(); pageIds.clear(); }
          for (var i = 0; i < records.length; i++) {
            final row = records[i];
            final id = row['id']?.toString() ?? '${replace ? 0 : cursor}:$i';
            if (pageIds.add(id)) pageRows.add({...row, '_pageKey': id});
          }
          nextOffset = (result['nextOffset'] as num?)?.toInt() ?? 0;
          nextByte = (result['nextByte'] as num?)?.toInt() ?? 0;
          final next = widget.view == 'entries' ? nextOffset : nextByte;
          hasMore = result['hasMore'] == true && next > (replace ? 0 : cursor);
        }
        data = result; pageIdentity = requestedIdentity; error = null;
      });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => loading = false); }
  }
  Future<void> run(String control, Json arguments, {bool consent = false}) async {
    if (busy || pageIdentity != identity || !widget.controller.connection.connected) return;
    if (consent && !await confirm(context, 'İşlemi onayla', '$control\n${controlText(arguments)}\n\nKimlik veya çalışan iş değişebilir. Etkin çalışma izinsiz kesilmez.', action: 'Onayla')) return;
    if (!mounted || pageIdentity != identity) return;
    setState(() { busy = true; error = null; });
    try {
      final result = await widget.controller.control(widget.sessionId, control, arguments: arguments, confirmed: true);
      final body = object(result['data']);
      if (!mounted) return;
      if (control == 'branch' && body['cancelled'] != true) {
        final operation = widget.controller.operationsFor(widget.sessionId).where((entry) => entry['id'] == result['id']).firstOrNull;
        if (operation?['draftEffect'] == 'review') await reviewBranchDraft(context, widget.controller, operation!);
        if (!mounted) return;
        widget.controller.refreshInBackground();
        if (operation?['draftEffect'] != 'stale') { Navigator.pop(context, true); return; }
      }
      input.clear();
      await load();
      widget.controller.refreshInBackground();
    } on CommandAccepted catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: e.id)); }
    on CommandUncertain catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: e.id)); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  bool get enabled => !busy && !loading && widget.controller.connection.connected && data != null && pageIdentity == identity;
  Widget button(String label, String control, Json arguments, {bool consent = false, IconData icon = Icons.play_arrow_rounded}) => OutlinedButton.icon(onPressed: enabled ? () => run(control, arguments, consent: consent) : null, icon: Icon(icon), label: Text(label));
  Widget detail(Object? value, {String? storageId}) => Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(controlText(value), key: storageId == null ? null : PageStorageKey('detail:$storageId')));
  List<Json> rows(String key) => objects(data?[key]);
  Widget _queue() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (strings(data?['steering']).isEmpty && strings(data?['followUp']).isEmpty) const Text('Sırada bekleyen mesaj yok.'),
    for (final queue in ['steering', 'followUp']) ...[
      Text(queue == 'steering' ? 'Yönlendirme sırası' : 'Takip sırası', style: Theme.of(context).textTheme.titleMedium),
      for (final message in strings(data?[queue])) Padding(padding: const EdgeInsets.only(bottom: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [detail(message), Wrap(spacing: 8, children: [
        button('Öne al', 'queue.promote', {'message': message}),
        OutlinedButton.icon(onPressed: enabled ? () async { final value = await textDialog(context, 'Sıradaki mesajı düzenle', 'Mesaj', initial: message); if (value != null && value.trim().isNotEmpty) await run('queue.edit', {'message': message, 'queue': queue, 'text': value}); } : null, icon: const Icon(Icons.edit_outlined), label: const Text('Düzenle')),
        button('Kaldır', 'queue.remove', {'message': message, 'queue': queue}, consent: true, icon: Icons.delete_outline_rounded),
      ])])),
    ],
  ]);
  Iterable<Json> treeEntries(List<Json> nodes) sync* {
    for (final node in nodes) { yield object(node['entry']); yield* treeEntries(objects(node['children'])); }
  }
  Widget _tree() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text('Dal değiştirmek gerçek günlük ve yaprak kimliğini değiştirir. Kaynak günlük ve görünen konuşma korunur. Seçilen istem, görselleriyle birlikte bu konuşmanın istem taslağına alınır; var olan taslak değiştirilmeden önce incelenir. Geçerli yaprak: ${data?['leafId'] ?? 'yok'}'),
    for (final row in widget.view == 'entries' ? pageRows : treeEntries(rows('tree'))) ExpansionTile(key: PageStorageKey('entry:${row['id']}'), title: Text('${row['type'] ?? 'Kayıt'} · ${row['id']}'), subtitle: Text('${row['timestamp'] ?? ''}'), children: [
      detail(row, storageId: 'entry:${row['id']}'),
      Wrap(spacing: 8, children: [button('Bu kayda git', 'tree.navigate', {'entryId': row['id']}, consent: true), button('Buradan dal aç', 'branch', {'entryId': row['id']}, consent: true), button('Ayrı konuşmaya çatalla', 'fork', {'entryId': row['id']}, consent: true)]),
    ]),
    if (widget.view == 'tree') TextButton.icon(onPressed: () => openScreen(context, SessionControlScreen(controller: widget.controller, sessionId: widget.sessionId, view: 'entries', title: 'Günlük kayıtları')), icon: const Icon(Icons.history_rounded), label: const Text('Tüm kayıtları aç')),
    if (widget.view == 'entries' && hasMore) TextButton.icon(onPressed: loading ? null : () => load(more: true), icon: const Icon(Icons.history_rounded), label: const Text('Sonraki kayıtları yükle')),
  ]);
  Widget _btw() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('BTW ana konuşmayı yönlendirmeyen ayrı yan soru panelidir.'),
    for (final record in rows('records')) Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${record['question'] ?? ''}', style: Theme.of(context).textTheme.titleMedium), Text('${record['status']}'), LocalMarkdown(data: '${record['answer'] ?? ''}'), button('Yan soruyu iptal et', 'btw.cancel', {'recordId': record['id']}, consent: true)]),
    TextField(controller: input, onChanged: (_) => setState(() {}), minLines: 2, maxLines: 8, enabled: enabled, decoration: const InputDecoration(labelText: 'Yan soru')),
    OutlinedButton.icon(onPressed: enabled && input.text.trim().isNotEmpty ? () => run('btw.ask', {'question': input.text}) : null, icon: const Icon(Icons.send_rounded), label: const Text('Yan soruyu sor')),
  ]);
  Widget _plan() {
    final review = object(data?['review']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      detail(data?['state']),
      if (review.isNotEmpty) ...[Text('${review['title'] ?? 'Plan'}', style: Theme.of(context).textTheme.titleLarge), SelectableText('${review['planFilePath'] ?? ''}'), LocalMarkdown(data: '${review['planContent'] ?? ''}'), Text('İncelenen sürüm: ${review['revision']}')],
      const Text('Onay yalnızca burada incelenen plan sürümü içindir. Değişmiş plan yeniden incelenmelidir.'),
      Wrap(spacing: 8, children: [button('Plan moduna gir', 'plan.enter', const {}), button('Planı incelemeye al', 'plan.review', const {}), OutlinedButton.icon(onPressed: enabled && review['revision'] is String ? () => run('plan.approve', {'revision': review['revision']}, consent: true) : null, icon: const Icon(Icons.check_rounded), label: const Text('Planı onayla ve uygula')), button('Planı iptal et', 'plan.cancel', const {}, consent: true)]),
    ]);
  }
  Widget _goal() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [detail(data), TextField(controller: input, onChanged: (_) => setState(() {}), minLines: 2, maxLines: 8, enabled: enabled, decoration: const InputDecoration(labelText: 'Hedef')), Wrap(spacing: 8, children: [OutlinedButton(onPressed: enabled && input.text.trim().isNotEmpty ? () => run('goal.create', {'objective': input.text}) : null, child: const Text('Hedef oluştur')), button('Hedefi sürdür', 'goal.resume', const {}), button('Hedefi duraklat', 'goal.pause', const {}), button('Hedefi bırak', 'goal.drop', const {}, consent: true)])]);
  Widget _jobs() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text('Teslim durumu: ${controlText(object(data?['snapshot'])['delivery'])}'),
    for (final group in ['running', 'recent']) ...[Text(group == 'running' ? 'Çalışan işler' : 'Son işler', style: Theme.of(context).textTheme.titleMedium), for (final row in objects(object(data?['snapshot'])[group])) Column(crossAxisAlignment: CrossAxisAlignment.start, children: [detail(row), if (group == 'running') button('İşi iptal et', 'jobs.cancel', {'id': row['id']}, consent: true)])],
  ]);
  Widget _agents() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final row in rows('agents')) Column(crossAxisAlignment: CrossAxisAlignment.start, children: [detail(row), TextButton.icon(onPressed: () => openScreen(context, SessionControlScreen(controller: widget.controller, sessionId: widget.sessionId, view: 'agentMessages', title: 'Ajan mesaj geçmişi', arguments: {'agentId': row['id'] ?? row['agentId']})), icon: const Icon(Icons.forum_outlined), label: const Text('Mesaj geçmişini aç'))])]);
  Widget _agentMessage(Json row) {
    final message = row['message'] is Map ? object(row['message']) : row;
    final content = message['content'];
    final blocks = content is String ? <Json>[{'type': 'text', 'text': content}] : objects(content);
    return Padding(key: ValueKey('agent-message:${row['_pageKey']}'), padding: const EdgeInsets.symmetric(vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${message['role'] ?? 'Kayıt'} · ${row['id'] ?? row['_pageKey']}', style: Theme.of(context).textTheme.titleSmall),
      Text('Ajan: ${widget.arguments['agentId']} · ${row['timestamp'] ?? message['timestamp'] ?? ''}'),
      for (final block in blocks) switch (block['type']) {
        'text' => LocalMarkdown(data: '${block['text'] ?? ''}'),
        'thinking' || 'reasoning' => ExpansionTile(title: const Text('Düşünme'), children: [SelectableText('${block['thinking'] ?? block['text'] ?? ''}')]),
        'image' => const Text('Görsel kaydı · Asıl görseli bilgisayardaki ajan günlüğünde incele.'),
        _ => ExpansionTile(title: Text('${block['name'] ?? block['toolName'] ?? block['type'] ?? 'Kayıt'}'), children: [CopyableCode(text: controlText(block['arguments'] ?? block['result'] ?? block['content'] ?? block))]),
      },
    ]));
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(widget.title), actions: [IconButton(tooltip: 'Görünümü yenile', onPressed: busy || loading ? null : load, icon: const Icon(Icons.refresh_rounded))]), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
    ConnectionBanner(widget.controller), if (error != null) ErrorNotice(error!, onRetry: load), if (data == null && error == null) const LinearProgressIndicator(),
    if (data != null && widget.view == 'agentMessages') ...[
      SelectableText('Kaynak: ${data?['sessionFile'] ?? ''}'),
      if (pageRows.isEmpty) const Text('Bu ajan günlüğünde mesaj yok.'),
      for (final row in pageRows) _agentMessage(row),
      if (hasMore) TextButton.icon(onPressed: loading ? null : () => load(more: true), icon: const Icon(Icons.forum_outlined), label: const Text('Sonraki ajan mesajlarını yükle')),
    ] else if (data != null) switch (widget.view) { 'queue' => _queue(), 'tree' || 'entries' => _tree(), 'btw' => _btw(), 'plan' => _plan(), 'goal' => _goal(), 'jobs' => _jobs(), 'agents' => _agents(), _ => detail(data) },
    if (busy || loading) const LinearProgressIndicator(),
  ])));
}
