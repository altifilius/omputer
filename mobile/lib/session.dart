import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'interactions.dart';
import 'session_controls.dart';
import 'session_file_context.dart';
import 'projects.dart' show FilePreviewScreen;

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.controller, required this.sessionId, this.initialMessageId});
  final OmputerController controller;
  final String sessionId;
  final String? initialMessageId;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}
class _SessionScreenState extends State<SessionScreen> {
  final message = TextEditingController();
  final scroll = ScrollController();
  String mode = 'session.prompt';
  bool sending = false;
  final List<Json> attachments = [];
  final List<Json> fileContext = [];
  Future<void> addFile(Session session) async {
    final selected = await Navigator.push<Json>(context, MaterialPageRoute(builder: (_) => SessionFileContextScreen(controller: widget.controller, projectId: session.projectId)));
    if (!mounted || selected == null) return;
    if (fileContext.fold<int>(0, (n, f) => n + '${f['text']}'.length) + '${selected['text']}'.length > 32000) { setState(() => draftError = 'Toplam dosya bağlamı 32.000 karakter sınırını aşıyor.'); return; }
    setState(() { fileContext.removeWhere((f) => f['path'] == selected['path']); fileContext.add(selected); });
    draftChanged();
  }
  String? draftError;
  bool draftLoading = true, showLatest = false;
  Future<void> draftWrites = Future.value();
  String get draftKey => 'session:${widget.sessionId}:$mode';
  String get identity => widget.controller.localState['identity']?.toString() ?? '';
  late String attachedIdentity;
  bool restoringDraft = false;
  bool paletteOpen = false, slashScheduled = false, hadSlash = false;
  String? savedComposer;
  Json get composer => {'text': message.text, 'attachments': List<Json>.from(attachments), 'files': List<Json>.from(fileContext)};
  void applyDraft(Json? draft) {
    restoringDraft = true;
    message.text = '${draft?['text'] ?? ''}';
    attachments..clear()..addAll(objects(draft?['attachments']));
    fileContext..clear()..addAll(objects(draft?['files']));
    hadSlash = message.text.startsWith('/');
    savedComposer = jsonEncode(composer);
    restoringDraft = false;
  }
  void controllerDraftChanged() {
    final change = widget.controller.draftChanges.value;
    if (!mounted || draftLoading || change == null || change.key != draftKey || change.identity != attachedIdentity || identity != attachedIdentity) return;
    if (!OmputerController.sameDraft(composer, OmputerController.composerDraft(change.before))) return;
    if (OmputerController.sameDraft(composer, OmputerController.composerDraft(change.after))) return;
    setState(() { applyDraft(change.after); draftError = null; });
  }
  String? focusedMessage;
  bool locating = false;
  Future<void> loadInitial() async {
    await widget.controller.loadMessages(widget.sessionId);
    final target = widget.initialMessageId;
    if (target == null || !mounted) return;
    setState(() => locating = true);
    var pages = 0;
    while (mounted && !transcript.messages.containsKey(target) && transcript.hasMore && transcript.error == null && pages < 20) {
      await widget.controller.loadMessages(widget.sessionId, older: true);
      pages++;
    }
    if (mounted) setState(() { locating = false; focusedMessage = transcript.messages.containsKey(target) ? target : null; if (focusedMessage == null) draftError = 'Aranan mesaj yüklenen geçmişte bulunamadı. Önceki mesajları yükleyerek devam edebilirsin.'; });
  }
  late Transcript transcript;
  @override
  void initState() {
    super.initState();
    transcript = widget.controller.retainTranscript(widget.sessionId);
    attachedIdentity = identity;
    final storedMode = object(widget.controller.localState['sections'])['lastMode'];
    final remembered = object(storedMode)['session:${widget.sessionId}'];
    if (remembered is String && widget.controller.snapshot.session(widget.sessionId)?.supports(remembered) == true) mode = remembered;
    message.addListener(draftChanged);
    widget.controller.draftChanges.addListener(controllerDraftChanged);
    scroll.addListener(positionChanged);
    restoreDraft();
    loadInitial();
  }
  @override
  void dispose() { widget.controller.draftChanges.removeListener(controllerDraftChanged); message.removeListener(draftChanged); widget.controller.releaseTranscript(widget.sessionId); message.dispose(); scroll.dispose(); super.dispose(); }
  void positionChanged() {
    final away = scroll.hasClients && scroll.offset > 80;
    if (away != showLatest && mounted) setState(() => showLatest = away);
  }
  void draftChanged() {
    if (restoringDraft || draftLoading || identity != attachedIdentity) return;
    final slash = message.text.startsWith('/');
    if (slash && !hadSlash && !paletteOpen && !slashScheduled && widget.controller.connection.connected) {
      slashScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        slashScheduled = false;
        if (mounted && !restoringDraft && !draftLoading && message.text.startsWith('/') && !paletteOpen) palette();
      });
    }
    hadSlash = slash;
    final key = draftKey;
    final value = composer;
    final encoded = jsonEncode(value);
    if (encoded == savedComposer) { if (mounted) setState(() {}); return; }
    savedComposer = encoded;
    draftWrites = widget.controller.saveDraft(key, value).catchError((Object e) { if (mounted) setState(() => draftError = 'Taslak kaydedilemedi: $e'); throw e; });
    // Keep an error observer when editing without immediately awaiting a send.
    draftWrites.catchError((Object _) {});
    if (mounted) setState(() {});
  }
  Future<void> restoreDraft() async {
    final key = draftKey;
    try {
      final draft = await widget.controller.loadDraft(key);
      if (!mounted || key != draftKey || attachedIdentity != identity) return;
      applyDraft(draft);
      setState(() { draftLoading = false; draftError = null; });
    } catch (e) { if (mounted) setState(() { draftLoading = false; draftError = 'Taslak açılamadı: $e'; }); }
  }
  Future<void> switchMode(String next) async {
    await draftWrites;
    if (!mounted) return;
    setState(() { restoringDraft = true; mode = next; draftLoading = true; message.clear(); attachments.clear(); fileContext.clear(); restoringDraft = false; });
    await widget.controller.updateLocalState('lastMode', 'session:${widget.sessionId}', next);
    await restoreDraft();
  }
  Future<void> discardDraft() async {
    if (!await confirm(context, 'Taslağı sil?', 'Kaydedilmiş metin ve görsel ekleri kaldırılır.', action: 'Sil')) return;
    try {
      await draftWrites;
      await widget.controller.deleteDraft(draftKey);
    } catch (e) { if (mounted) setState(() => draftError = 'Taslak silinemedi: $e'); }
  }
  Future<void> addImages({bool camera = false, bool shared = false}) async {
    var picked = <Json>[];
    var retained = false;
    try {
      picked = shared ? await widget.controller.consumeSharedImages() : await widget.controller.pickImages(camera: camera);
      if (!mounted || attachedIdentity != identity) return;
      final merged = [...attachments, ...picked.where((i) => !attachments.any((a) => a['id'] == i['id']))];
      await widget.controller.prepareImages(merged);
      if (!mounted || attachedIdentity != identity) return;
      setState(() { attachments..clear()..addAll(merged); });
      retained = true;
      draftChanged();
      await draftWrites;
    } catch (e) { if (mounted) setState(() => draftError = '$e'); }
    finally {
      if (!retained && picked.isNotEmpty && attachedIdentity == identity) {
        try { await widget.controller.releaseAttachments(picked); }
        catch (e) { if (mounted) setState(() => draftError = 'Görseller kaldırılamadı: $e'); }
      }
    }
  }
  Future<void> removeImage(Json image) async {
    setState(() => attachments.remove(image));
    draftChanged();
    try { await draftWrites; }
    catch (e) { if (mounted) setState(() => draftError = 'Görsel değişikliği kaydedilemedi: $e'); }
  }
  Future<void> reviewBranch(Json operation) async {
    try {
      await draftWrites;
      if (!mounted) return;
      if (await reviewBranchDraft(context, widget.controller, operation) && mounted && mode != 'session.prompt') await switchMode('session.prompt');
    } catch (e) { if (mounted) setState(() => draftError = '$e'); }
  }
  void openOperations([String? id]) => openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: id));
  Future<void> palette() async {
    if (paletteOpen) return;
    paletteOpen = true;
    final text = message.text;
    final split = text.indexOf(RegExp(r'\s'));
    try {
      final result = await Navigator.push<Object?>(context, MaterialPageRoute(builder: (_) => CommandPalette(controller: widget.controller, sessionId: widget.sessionId, initialQuery: text.startsWith('/') ? (split < 0 ? text : text.substring(0, split)) : '', initialArgs: text.startsWith('/') && split >= 0 ? text.substring(split + 1) : '', onLocal: localControl)));
      if (mounted && result is String) openOperations(result);
    } finally { paletteOpen = false; }
  }
  Future<void> localControl(String name) async {
    final session = widget.controller.snapshot.session(widget.sessionId);
    if (session == null) return;
    switch (name) {
      case 'model' || 'models': await action(session, 'model');
      case 'resume': await resume();
      case 'thinking' || 'effort': await action(session, 'thinking');
      case 'new': await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => NewSessionScreen(controller: widget.controller, projectId: session.projectId)));
      case 'tree' || 'entries' || 'queue' || 'btw' || 'plan' || 'goal' || 'agents' || 'jobs' || 'usage':
        await draftWrites;
        final result = await Navigator.push<Object?>(context, MaterialPageRoute(builder: (_) => SessionControlScreen(controller: widget.controller, sessionId: session.id, view: name, title: controlLabel(name))));
        if (mounted && result == true && mode != 'session.prompt') await switchMode('session.prompt');
      default: throw ControllerFailure('Yerel komut desteklenmiyor: $name');
    }
  }
  Future<void> send(Session session, {bool literal = false}) async {
    final value = message.text.trim();
    final current = widget.controller.snapshot.session(widget.sessionId);
    if ((value.isEmpty && attachments.isEmpty && fileContext.isEmpty) || sending || draftLoading || current == null || !current.canSendMessages || !current.supports(mode) || attachedIdentity != identity) return;
    if (value.startsWith('/') && !literal) { await palette(); return; }
    final submittedMode = mode;
    final submitted = composer;
    final fullText = [value, ...objects(submitted['files']).map((file) => '\n--- Seçilen proje dosyası: ${file['path']} (${file['truncated'] == true ? 'kesilmiş' : 'tam'} metin) ---\n${file['text']}\n--- Dosya sonu ---')].join('\n');
    setState(() => sending = true);
    try {
      await draftWrites;
      await widget.controller.submitDraft(current.id, submittedMode, submitted, {'message': fullText, if (objects(submitted['attachments']).isNotEmpty) 'images': objects(submitted['attachments']).map((i) => {'type': 'image', 'mimeType': i['mimeType'], 'data': i['data']}).toList(), 'runCommands': false, 'expandPromptTemplates': false});
    } on CommandAccepted catch (e) { if (mounted) openOperations(e.id); }
    on CommandUncertain catch (e) { if (mounted) openOperations(e.id); }
    catch (e) { if (mounted) setState(() => draftError = '$e'); }
    finally { if (mounted) setState(() => sending = false); }
  }
  Future<void> resume() async {
    final c = widget.controller;
    final session = c.snapshot.session(widget.sessionId);
    if (session == null || !session.canResume || !c.connection.connected || sending) return;
    setState(() => sending = true);
    try { await c.command('session.resume', sessionId: session.id, payload: {'sessionId': session.id}); c.refreshInBackground(); }
    on CommandAccepted catch (e) { if (mounted) openOperations(e.id); }
    on CommandUncertain catch (e) { if (mounted) openOperations(e.id); }
    catch (e) { if (mounted) await perform(context, () async { throw e; }); }
    if (mounted) setState(() => sending = false);
  }
  Future<void> action(Session session, String action) async {
    final c = widget.controller;
    switch (action) {
      case 'palette': await palette();
      case 'export':
        await perform(context, () async { final exported = await c.exportSession(session.id); if (mounted && await confirm(context, 'Konuşmayı paylaş?', 'Metin yerel Android paylaşım seçicisine aktarılır. Paylaşmadan önce özel içerikleri kontrol et.', action: 'Paylaş')) await c.shareExport(exported); });
      case 'operations': openOperations();
      case 'queue' || 'tree' || 'btw' || 'plan' || 'goal' || 'jobs' || 'usage': await localControl(action);
      case 'model':
        if (sending) return;
        setState(() => sending = true);
        try {
          await chooseModel(context, c, (model) async { if (mounted) setState(() => sending = false); await submitAction(() => c.command('session.model', sessionId: session.id, payload: {'provider': model.provider, 'modelId': model.id})); }, sessionId: session.id);
        } finally { if (mounted) setState(() => sending = false); }
      case 'thinking':
        Json effort;
        try { effort = await c.effort(session.id); } catch (e) { if (mounted) await perform(context, () async { throw e; }); return; }
        if (!mounted) return;
        final levels = strings(effort['levels']);
        final result = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [const ListTile(title: Text('Düşünme düzeyi')), if (levels.isEmpty) const ListTile(title: Text('Bu model düşünme düzeyi seçimini desteklemiyor.')), for (final level in levels) ListTile(title: Text(level), trailing: effort['level'] == level ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(context, level))])));
        if (result != null && mounted) await submitAction(() => c.command('session.thinking', sessionId: session.id, payload: {'level': result}));
      case 'abort':
        if (await confirm(context, 'Bu oturumun çalışmasını kes?', 'OMP’nin bu oturumdaki aktif üretimini ve çalışma araçlarını durdurma isteği gönderilir. Ayrı / arka plan süreçlerinin veya diğer oturumların sonlandığı anlamına gelmez. Telefonun bağlantısını kesmek işi durdurmaz.', action: 'Çalışmayı kes') && mounted) await submitAction(() => c.command('session.abort', sessionId: session.id), success: 'Kesme isteği bilgisayara iletildi.');
      case 'rename':
        final name = await textDialog(context, 'Oturumu yeniden adlandır', 'Oturum adı', initial: session.name);
        if (name != null && name.trim().isNotEmpty && mounted) await submitAction(() => c.command('session.rename', sessionId: session.id, payload: {'name': name.trim()}));
      case 'compact':
        final instructions = await textDialog(context, 'Konuşmayı sıkıştır', 'Ek yönerge (isteğe bağlı)', message: 'OMP bağlamı özetleyerek sıkıştırır. Bu, projenin tamamlandığı anlamına gelmez.');
        if (instructions != null && mounted) await submitAction(() => c.command('session.compact', sessionId: session.id, payload: {if (instructions.trim().isNotEmpty) 'instructions': instructions.trim()}));
      case 'refresh':
        await submitAction(() => c.command('session.refresh', sessionId: session.id));
        if (mounted) await c.loadMessages(session.id);
      case 'bash':
        final command = await textDialog(context, 'Bilgisayarda kabuk komutu', 'Çalıştırılacak komut', message: 'Bu, bilgisayarında gerçek bir kabuk komutu çalıştırır. OMP’ye doğal dil istemi göndermek için konuşma alanını kullan.');
        if (command != null && command.trim().isNotEmpty && mounted && await confirm(context, 'Komutu çalıştır?', command, action: 'Çalıştır') && mounted) await submitAction(() => c.command('session.bash', sessionId: session.id, payload: {'command': command}));
      case 'agents':
        openScreen(context, AgentsScreen(controller: c, sessionId: session.id));
      case 'todos':
        openScreen(context, TodosScreen(controller: c, sessionId: session.id));
    }
  }
  Future<void> submitAction(Future<Json> Function() operation, {String? success}) async {
    if (sending) return;
    setState(() => sending = true);
    try { final result = await operation(); widget.controller.refreshInBackground(); if (result['id'] is String && mounted) openOperations(result['id'] as String); if (success != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success))); }
    on CommandAccepted catch (e) { if (mounted) openOperations(e.id); }
    on CommandUncertain catch (e) { if (mounted) openOperations(e.id); }
    catch (e) { if (mounted) await perform(context, () async { throw e; }); }
    if (mounted) setState(() => sending = false);
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final session = c.snapshot.session(widget.sessionId);
    if (identity != attachedIdentity) {
      attachedIdentity = identity;
      restoringDraft = true; message.clear(); attachments.clear(); fileContext.clear(); restoringDraft = false;
      draftLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) restoreDraft(); });
    }
    final pending = c.snapshot.pending.where((i) => i.sessionId == widget.sessionId).toList();
    final live = session?.canSendMessages == true;
    final availableModes = ['session.prompt', 'session.steer', 'session.follow_up'].where((m) => session?.supports(m) == true).toList();
    if (availableModes.isNotEmpty && !availableModes.contains(mode) && !draftLoading) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) switchMode(availableModes.first); });
    return Scaffold(appBar: AppBar(title: Text(session?.name.isNotEmpty == true ? session!.name : 'Konuşma'), actions: [if (session != null) PopupMenuButton<String>(tooltip: 'Oturum kontrolleri', onSelected: (value) => action(session, value), itemBuilder: (context) => [
      const PopupMenuItem(value: 'palette', child: Text('/ Komutlar')),
      const PopupMenuItem(value: 'operations', child: Text('İşlem geçmişi')),
      const PopupMenuItem(value: 'export', child: Text('Konuşmayı dışa aktar')),
      for (final view in ['queue', 'tree', 'btw', 'plan', 'goal', 'jobs', 'usage']) PopupMenuItem(value: view, child: Text(controlLabel(view))),
      if (session.todos.isNotEmpty) const PopupMenuItem(value: 'todos', child: Text('Yapılacaklar')),
      if (session.subagents.isNotEmpty || session.supports('agent.command')) const PopupMenuItem(value: 'agents', child: Text('Alt ajanlar')),
      for (final item in [('model', 'session.model', 'Modeli değiştir'), ('thinking', 'session.thinking', 'Düşünme düzeyi'), ('rename', 'session.rename', 'Yeniden adlandır'), ('compact', 'session.compact', 'Konuşmayı sıkıştır'), ('refresh', 'session.refresh', 'Oturum durumunu yenile'), ('bash', 'session.bash', 'Kabuk komutu çalıştır'), ('abort', 'session.abort', 'Çalışmayı kes')])
        if (!session.archived && !session.activeUnbridged && session.supports(item.$2)) PopupMenuItem(value: item.$1, enabled: c.connection.connected && !sending, child: Text(item.$3)),
    ])]), body: SafeArea(top: false, child: Column(children: [
      ConstrainedBox(constraints: BoxConstraints(maxHeight: math.max(0, (MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom - MediaQuery.paddingOf(context).vertical - kToolbarHeight) * .3)), child: SingleChildScrollView(primary: false, child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 4, 24, 12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Hero(tag: 'checkpoint-thread', child: Icon(Icons.commit_rounded, color: Theme.of(context).colorScheme.primary)), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(c.snapshot.project(session?.projectId ?? '')?.name ?? 'Kaynak konuşma', style: Theme.of(context).textTheme.labelLarge), const SizedBox(height: 4), Text('${session?.statusLabel ?? 'Oturum bilgisi alınamadı'}${c.connection.connected ? '' : ' · Çevrimdışı'}', style: Theme.of(context).textTheme.bodySmall)]))])),
      if (session?.lastError != null) ErrorNotice(session!.lastError!),
      if (session?.turnError != null) ErrorNotice('Tur hatası: ${session!.turnError}. Bağlantı açıksa oturumu yönlendirmeye devam edebilirsin.'),
      if (pending.isNotEmpty) Material(color: Theme.of(context).colorScheme.secondaryContainer, child: ListTile(leading: const Icon(Icons.pending_actions_rounded), title: Text(pending.first.title, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text('${pending.length} karar bekliyor'), trailing: const Icon(Icons.arrow_forward_rounded), onTap: () => openScreen(context, InteractionScreen(controller: c, interactionId: pending.first.id)))),
      if (session?.model != null || session?.thinkingLevel != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), child: Align(alignment: Alignment.centerLeft, child: Text([session?.model?.name, session?.thinkingLevel == null ? null : 'Düşünme: ${session!.thinkingLevel}'].whereType<String>().join(' · '), style: Theme.of(context).textTheme.labelMedium))),
      if (locating) const LinearProgressIndicator(),
      if (focusedMessage != null) Material(color: Theme.of(context).colorScheme.secondaryContainer, child: ListTile(title: const Text('Arama sonucu konumunda okuyorsun'), subtitle: Text(focusedMessage!), trailing: IconButton(tooltip: 'Canlı son mesaja dön', onPressed: () => setState(() => focusedMessage = null), icon: const Icon(Icons.close_rounded)))),
      ]))),
      Expanded(child: LayoutBuilder(builder: (context, constraints) => Column(children: [
      Expanded(child: ListenableBuilder(listenable: transcript, builder: (context, _) {
        if (transcript.ids.isEmpty && transcript.loading) return const Center(child: CircularProgressIndicator());
        if (transcript.ids.isEmpty && transcript.error != null) return SingleChildScrollView(child: ErrorNotice(transcript.error!, onRetry: () => c.loadMessages(widget.sessionId)));
        if (transcript.ids.isEmpty) return SingleChildScrollView(child: EmptyState(icon: Icons.forum_outlined, title: live ? 'Konuşma burada başlar.' : 'Henüz mesaj görüntülenemiyor.', message: live ? 'İlk istemi gönder. Canlı mesajlar ve araç sonuçları bilgisayardan geldikçe bu konuşmada görünür. Çevrimdışıysa daha önce açılmamış konuşma geçmişi alınamaz.' : 'Bu konuşma salt okunur. Çevrimdışıysa daha önce açılmamış konuşma geçmişi alınamaz.'));
        final ids = focusedMessage == null ? transcript.ids : transcript.ids.take(transcript.ids.indexOf(focusedMessage!) + 1).toList();
        return ListView.builder(key: PageStorageKey('transcript:${widget.sessionId}:${focusedMessage ?? 'live'}'), controller: scroll, reverse: true, padding: const EdgeInsets.only(bottom: 24), itemCount: ids.length + 1, itemBuilder: (context, index) {
          if (index == ids.length) return Column(children: [if (transcript.hasMore) TextButton.icon(onPressed: transcript.loading ? null : () => c.loadMessages(widget.sessionId, older: true), icon: transcript.loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.history_rounded), label: const Text('Önceki mesajları yükle')), if (transcript.error != null) ErrorNotice(transcript.error!, onRetry: () => c.loadMessages(widget.sessionId, older: true))]);
          final id = ids[ids.length - index - 1];
          return RepaintBoundary(key: ValueKey(id), child: ValueListenableBuilder<ChatMessage>(valueListenable: transcript.messages[id]!, builder: (context, msg, _) => MessageView(message: msg, onOpenFile: (path, line) { final project = c.snapshot.project(session?.projectId ?? ''); if (project != null) openScreen(context, FilePreviewScreen(controller: c, project: project, initialPath: path, initialLine: line)); })));
        });
      })),
      if (showLatest) Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () { scroll.jumpTo(0); final id = transcript.ids.lastOrNull; if (id != null) widget.controller.updateLocalState('read', 'session:${widget.sessionId}', {'messageId': id, 'revision': transcript.messages[id]!.value.revision}); }, icon: const Icon(Icons.arrow_downward_rounded), label: const Text('Son mesaja git'))),
      if (session != null && !live) ConstrainedBox(constraints: BoxConstraints(maxHeight: constraints.maxHeight * .75), child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(session.activeUnbridged
          ? 'Bu oturum terminalde açık, ancak telefon bağlantısı etkin değil. Konuşmayı burada okuyabilirsin; açık oturum telefondan yeniden başlatılmaz.'
          : session.canResume
            ? 'Geçmiş oturum · yeniden açılana kadar salt okunur.'
            : 'Bu oturum şu anda telefondan mesaj göndermeyi veya sürdürmeyi desteklemiyor. Konuşma salt okunur.'),
        if (session.activeUnbridged) ...[const SizedBox(height: 8), const Text('Açık oturumuna terminalden devam et veya bu projede telefondan ayrı, yeni bir oturum başlat. Yeni OMP açılışlarında telefon bağlantısı yüklenir; mevcut terminal oturumu ve konuşması korunur.')],
        if (session.canResume) ...[const SizedBox(height: 10), FilledButton.icon(key: const ValueKey('session-resume'), onPressed: !c.connection.connected || sending ? null : resume, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Oturumu sürdür'))],
        if (c.snapshot.project(session.projectId) != null) ...[const SizedBox(height: 10), OutlinedButton.icon(key: const ValueKey('session-new-project'), onPressed: !c.connection.connected || sending ? null : () => openScreen(context, NewSessionScreen(controller: c, projectId: session.projectId)), icon: const Icon(Icons.add_rounded), label: const Text('Bu projede yeni oturum'))],
      ]))),
      // This is a height cap, not a flex allocation: the transcript keeps unused space.
      if (live) ConstrainedBox(constraints: BoxConstraints(maxHeight: math.min(constraints.maxHeight, math.max(160, constraints.maxHeight * .75))), child: _composer(context, session!, availableModes)),
      ]))),
    ])));
  });

  Widget _composer(BuildContext context, Session session, List<String> modes) {
    final enabled = widget.controller.connection.connected && !sending && !draftLoading && identity == attachedIdentity;
    return Material(color: Theme.of(context).colorScheme.surfaceContainerLow, child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: LayoutBuilder(builder: (context, constraints) => Column(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: SingleChildScrollView(key: PageStorageKey('composer:${widget.sessionId}'), primary: false, child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (draftError != null) ErrorNotice(draftError!),
      for (final operation in widget.controller.pendingBranchDrafts(widget.sessionId)) Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text('Dal istemi güvenle saklandı', style: Theme.of(context).textTheme.titleSmall), const Text('Geçerli taslağı değiştirmeden önce metni ve görselleri incele.'), Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: enabled ? () => reviewBranch(operation) : null, child: const Text('İncele')))])),
      Wrap(spacing: 8, children: [IconButton(tooltip: 'Komut paletini aç', onPressed: enabled ? palette : null, icon: const Icon(Icons.terminal_rounded)), IconButton(tooltip: 'Galeriden görsel ekle', onPressed: enabled ? () => addImages() : null, icon: const Icon(Icons.add_photo_alternate_outlined)), IconButton(tooltip: 'Kameradan görsel ekle', onPressed: enabled ? () => addImages(camera: true) : null, icon: const Icon(Icons.photo_camera_outlined)), IconButton(tooltip: 'Paylaşılan görselleri ekle', onPressed: enabled ? () => addImages(shared: true) : null, icon: const Icon(Icons.share_outlined)), IconButton(tooltip: 'Taslağı sil', onPressed: enabled && (message.text.isNotEmpty || attachments.isNotEmpty || fileContext.isNotEmpty) ? discardDraft : null, icon: const Icon(Icons.delete_outline_rounded))]),
      if (attachments.isNotEmpty) Wrap(spacing: 12, runSpacing: 12, children: [for (final image in attachments) Column(mainAxisSize: MainAxisSize.min, children: [SizedBox(width: 96, height: 96, child: boundedImage('${image['data'] ?? ''}')), IconButton(tooltip: 'Eklenen görseli kaldır', onPressed: enabled ? () => removeImage(image) : null, icon: const Icon(Icons.close_rounded))])]),
      if (attachments.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Görsel desteği seçili modele bağlıdır; desteklenmeyen modelde gönderim reddedilebilir.', style: Theme.of(context).textTheme.bodySmall)),
      Wrap(spacing: 8, children: [TextButton.icon(onPressed: enabled ? () => addFile(session) : null, icon: const Icon(Icons.attach_file_rounded), label: const Text('Dosya metni ekle')), if (message.text.startsWith('/')) TextButton(onPressed: enabled ? () async { if (await confirm(context, 'Komut değil, düz metin gönder?', 'Başındaki / işareti çalıştırılmaz. Metin aynen modele gönderilir.', action: 'Düz metin gönder')) await send(session, literal: true); } : null, child: const Text('/ metnini aynen gönder'))]),
      for (final file in fileContext) ListTile(title: Text('${file['path']}'), subtitle: Text('${'${file['text']}'.length} karakter · ${file['truncated'] == true ? 'kesilmiş' : 'tam'} metin'), trailing: IconButton(tooltip: 'Dosya bağlamını kaldır', onPressed: enabled ? () { setState(() => fileContext.remove(file)); draftChanged(); } : null, icon: const Icon(Icons.close_rounded))),
      Row(children: [Expanded(child: Semantics(label: 'Mesaj gönderme biçimi', child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: mode, isExpanded: true, itemHeight: null, items: modes.map((m) => DropdownMenuItem(value: m, child: Text(modeLabel(m)))).toList(), onChanged: enabled ? (value) => switchMode(value!) : null)))), if (session.supports('session.abort') && session.status == 'running') IconButton(tooltip: 'Çalışmayı kes', onPressed: enabled ? () => action(session, 'abort') : null, icon: const Icon(Icons.stop_circle_outlined))]),
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Align(alignment: Alignment.centerLeft, child: Text(switch (mode) { 'session.steer' => 'Devam eden çalışmayı yönlendirir; yeni bir oturum açmaz.', 'session.follow_up' => 'Geçerli turdan sonra ele alınacak takip istemi.', _ => 'Bu konuşmaya yeni bir istem gönder.' }, style: Theme.of(context).textTheme.bodySmall))),
      ]))),
      const SizedBox(height: 8),
      // Only ancillary controls scroll; typing and sending stay above the IME.
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: ConstrainedBox(constraints: BoxConstraints(maxHeight: math.min(math.max(0, constraints.maxHeight - 8), math.max(MediaQuery.textScalerOf(context).scale(24) + 48, constraints.maxHeight - 56))), child: TextField(controller: message, enabled: !sending && !draftLoading, minLines: 1, maxLines: 6, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'OMP’ye mesaj', hintText: 'OMP’ye yaz… / ile komut aç', alignLabelWithHint: true)))), const SizedBox(width: 8), IconButton.filled(tooltip: message.text.startsWith('/') ? 'Komut paletini aç' : modeLabel(mode), onPressed: enabled && (message.text.trim().isNotEmpty || attachments.isNotEmpty || fileContext.isNotEmpty) ? () => send(session) : null, icon: sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward_rounded), style: IconButton.styleFrom(minimumSize: const Size(52, 52)))])
    ]))));
  }
}

String modeLabel(String mode) => switch (mode) { 'session.steer' => 'Yönlendir (steer)', 'session.follow_up' => 'Takibe ekle (follow-up)', _ => 'İstem gönder (prompt)' };
String controlLabel(String name) => switch (name) { 'queue' => 'Bekleyen mesajlar', 'tree' => 'Konuşma ağacı', 'entries' => 'Günlük kayıtları', 'btw' => 'Yan soru (BTW)', 'plan' => 'Plan inceleme', 'goal' => 'Hedef', 'jobs' => 'Arka plan işleri', 'usage' => 'Bağlam ve kullanım', _ => name };
Widget boundedImage(String data) {
  if (data.length > 3 * 1024 * 1024) return const Text('Görsel boyut sınırını aşıyor. Bilgisayarda asıl kaydı aç.');
  try { return ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320, maxWidth: 640), child: Image.memory(base64Decode(data), cacheWidth: 640, cacheHeight: 640, fit: BoxFit.contain, semanticLabel: 'Konuşmaya eklenen görsel', errorBuilder: (context, error, stackTrace) => const Text('Görsel açılamadı.'))); }
  catch (_) { return const Text('Görsel verisi geçerli değil.'); }
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message, this.onOpenFile});
  final ChatMessage message;
  final void Function(String, int?)? onOpenFile;
  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Padding(padding: EdgeInsets.fromLTRB(user ? 40 : 24, 18, 24, 8), child: Material(color: user ? scheme.primaryContainer.withValues(alpha: .55) : Colors.transparent, borderRadius: BorderRadius.circular(20), child: Padding(padding: EdgeInsets.all(user ? 16 : 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Expanded(child: Text(switch (message.role) { 'user' => 'Sen', 'assistant' => 'OMP', 'toolResult' => 'Araç sonucu', _ => message.role }, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary))), IconButton(tooltip: 'Mesajı kopyala', onPressed: () => copyText(context, message.content.map((b) => b['text'] ?? b['thinking'] ?? controlText(b)).join('\n')), icon: const Icon(Icons.copy_rounded)), IconButton(tooltip: 'Mesaj bağlantısını kopyala', onPressed: () => copyText(context, 'omputer://message/${Uri.encodeComponent(message.id)}'), icon: const Icon(Icons.link_rounded))]), const SizedBox(height: 10), for (var i = 0; i < message.content.length; i++) _block(context, message.content[i], '${message.id}:$i'), if (message.timestamp != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(dateLabel(message.timestamp), style: Theme.of(context).textTheme.labelSmall))]))));
  }
  Widget _block(BuildContext context, Json block, String key) {
    final type = '${block['type'] ?? 'text'}';
    if (type == 'text') return Padding(padding: const EdgeInsets.only(bottom: 8), child: LocalMarkdown(data: '${block['text'] ?? ''}', onOpenFile: onOpenFile, styleSheet: MarkdownStyleSheet(p: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55))));
    if (type == 'thinking' || type == 'reasoning') return ExpansionTile(key: PageStorageKey(key), tilePadding: EdgeInsets.zero, title: const Text('Düşünme'), leading: const Icon(Icons.psychology_outlined), initiallyExpanded: false, children: [Padding(padding: const EdgeInsets.only(bottom: 16), child: Align(alignment: Alignment.centerLeft, child: SelectableText('${block['thinking'] ?? block['text'] ?? ''}', key: PageStorageKey('$key:thinking'), style: Theme.of(context).textTheme.bodyMedium)))]);
    if (type == 'image') {
      final source = object(block['source']);
      final data = block['data'] ?? source['data'];
      if (data is String) return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: boundedImage(data));
      final url = block['url'] ?? source['url'];
      return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Görsel referansı'), if (url != null) SelectableText('$url') else const Text('Görsel baytları bu kayıtta bulunmuyor; bilgisayardaki konuşmayı incele.')]));
    }
    final title = type == 'toolCall' ? '${block['name'] ?? 'Araç çağrısı'}' : type == 'toolResult' ? '${block['toolName'] ?? block['name'] ?? 'Araç sonucu'}' : type;
    final content = block['arguments'] ?? block['content'] ?? block['result'] ?? block;
    return ExpansionTile(key: PageStorageKey(key), tilePadding: EdgeInsets.zero, leading: Icon(block['isError'] == true ? Icons.error_outline_rounded : Icons.build_outlined), title: Text(title), subtitle: type == 'toolCall' ? const Text('Çağrı parametreleri') : null, children: [Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)), child: SelectableText(content is String ? content : const JsonEncoder.withIndent('  ').convert(content), key: PageStorageKey('$key:tool-content'), style: const TextStyle(fontFamily: 'monospace', height: 1.5))), Wrap(spacing: 8, children: [TextButton.icon(onPressed: () => copyText(context, content is String ? content : controlText(content)), icon: const Icon(Icons.copy_rounded), label: const Text('Araç sonucunu kopyala')), TextButton.icon(onPressed: () => copyText(context, 'omputer://tool/${Uri.encodeComponent('${block['id'] ?? block['toolCallId'] ?? key}')}'), icon: const Icon(Icons.link_rounded), label: const Text('Araç bağlantısını kopyala'))])]);
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

Future<void> chooseModel(BuildContext context, OmputerController controller, Future<void> Function(ModelInfo) selected, {String? sessionId}) async {
  List<ModelInfo> models;
  try { models = await controller.models(sessionId: sessionId); }
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
    return SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: SizedBox(height: MediaQuery.sizeOf(context).height * .65, child: Column(children: [Padding(padding: const EdgeInsets.all(24), child: TextField(onChanged: (value) => setState(() => query = value), decoration: const InputDecoration(labelText: 'Model ara', prefixIcon: Icon(Icons.search_rounded)))), Expanded(child: models.isEmpty ? const SingleChildScrollView(child: EmptyState(icon: Icons.model_training_rounded, title: 'Kullanılabilir model yok.', message: 'Modeller canlı OMP çalışma zamanından gelir. Bilgisayarındaki sağlayıcı ayarlarını ve canlı oturumu kontrol et.')) : ListView.builder(itemCount: models.length, itemBuilder: (context, index) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), title: Text(models[index].name), subtitle: Text('${models[index].provider} · ${models[index].id}'), onTap: () => Navigator.pop(context, models[index]))))]))));
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
  bool restoring = false;
  String? draftError;
  Future<void> writes = Future.value();
  String get draftKey => 'new:${projectId ?? 'unselected'}';
  @override
  void initState() { super.initState(); restore(); name.addListener(save); prompt.addListener(save); }
  Future<void> restore() async {
    try {
      final key = draftKey;
      final value = await widget.controller.loadDraft(key);
      if (!mounted || key != draftKey) return;
      restoring = true;
      name.text = '${value?['name'] ?? ''}'; prompt.text = '${value?['prompt'] ?? ''}';
      model = value?['model'] is Map ? ModelInfo.fromJson(object(value?['model'])) : null;
      restoring = false;
      setState(() {});
    } catch (e) { if (mounted) setState(() => draftError = 'Taslak açılamadı: $e'); }
  }
  void save() {
    if (restoring) return;
    final key = draftKey;
    final value = <String, dynamic>{'name': name.text, 'prompt': prompt.text, if (model != null) 'model': {'id': model!.id, 'name': model!.name, 'provider': model!.provider}};
    writes = writes.catchError((Object _) {}).then((_) => widget.controller.saveDraft(key, value)).catchError((Object e) { if (mounted) setState(() => draftError = 'Taslak kaydedilemedi: $e'); });
  }
  @override
  void dispose() { name.removeListener(save); prompt.removeListener(save); name.dispose(); prompt.dispose(); super.dispose(); }
  Future<void> start() async {
    if (projectId == null || busy || !widget.controller.connection.connected) return;
    setState(() => busy = true);
    try {
      await writes;
      final result = await widget.controller.command('session.start', payload: {'projectId': projectId, if (name.text.trim().isNotEmpty) 'name': name.text.trim(), if (prompt.text.trim().isNotEmpty) 'prompt': prompt.text.trim(), if (model != null) 'model': {'provider': model!.provider, 'id': model!.id}});
      await widget.controller.deleteDraft(draftKey);
      widget.controller.refreshInBackground();
      final data = object(result['data']);
      final id = data['sessionId'] ?? data['id'] ?? object(data['session'])['id'];
      if (mounted) {
        if (id is String) Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => SessionScreen(controller: widget.controller, sessionId: id)));
        else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Oturum başlatıldı. Projendeki güncel oturum listesinden açabilirsin.'))); Navigator.pop(context); }
      }
    } on CommandAccepted catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: '', operationId: e.id)); }
    on CommandUncertain catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: '', operationId: e.id)); }
    catch (e) { if (mounted) await perform(context, () async { throw e; }); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) => Scaffold(
    appBar: AppBar(title: const Text('Yeni oturum')),
    body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
      ConnectionBanner(widget.controller),
      if (draftError != null) ErrorNotice(draftError!),
      Text('Bir sonraki adımı başlat.', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      const Text('Yalnızca bilgisayarda kayıtlı proje köklerinde yeni bir OMP oturumu açılır. Çalışma bilgisayarında yürür.'),
      const SizedBox(height: 24),
      DropdownButtonFormField<String>(initialValue: projectId, isExpanded: true, decoration: const InputDecoration(labelText: 'Proje'), items: widget.controller.snapshot.projects.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis))).toList(), onChanged: busy ? null : (value) async { await writes; if (mounted) setState(() => projectId = value); await restore(); }),
      const SizedBox(height: 20),
      TextField(controller: name, enabled: !busy, decoration: const InputDecoration(labelText: 'Oturum adı (isteğe bağlı)')),
      const SizedBox(height: 20),
      TextField(controller: prompt, enabled: !busy, minLines: 4, maxLines: 12, decoration: const InputDecoration(labelText: 'İlk istem (isteğe bağlı)', alignLabelWithHint: true)),
      const SizedBox(height: 20),
      ListTile(contentPadding: EdgeInsets.zero, title: const Text('Model'), subtitle: Text(model == null ? 'Bilgisayardaki OMP varsayılanı' : '${model!.provider} · ${model!.name}'), trailing: const Icon(Icons.expand_more_rounded), onTap: busy || !widget.controller.connection.connected ? null : () => chooseModel(context, widget.controller, (choice) async { if (mounted) setState(() => model = choice); save(); })),
      if (model != null) TextButton(onPressed: busy ? null : () { setState(() => model = null); save(); }, child: const Text('Varsayılan modeli kullan')),
      TextButton.icon(onPressed: busy ? null : () async { if (!await confirm(context, 'Yeni oturum taslağını sil?', 'Oturum oluşturulmaz; yalnızca kaydedilen taslak silinir.', action: 'Sil')) return; await writes; await widget.controller.deleteDraft(draftKey); if (mounted) setState(() { restoring = true; name.clear(); prompt.clear(); model = null; restoring = false; }); }, icon: const Icon(Icons.delete_outline_rounded), label: const Text('Taslağı sil')),
      const SizedBox(height: 24),
      FilledButton.icon(onPressed: busy || projectId == null || !widget.controller.connection.connected ? null : start, icon: const Icon(Icons.play_arrow_rounded), label: Text(busy ? 'Başlatılıyor…' : 'Oturumu başlat')),
    ])),
  ));
}

class TodosScreen extends StatefulWidget {
  const TodosScreen({super.key, required this.controller, required this.sessionId});
  final OmputerController controller;
  final String sessionId;
  @override
  State<TodosScreen> createState() => _TodosScreenState();
}
class _TodosScreenState extends State<TodosScreen> {
  bool busy = false;
  String? error;
  Future<void> run(String control, String args) async {
    if (busy) return;
    if (['drop', 'rm'].contains(control) && !await confirm(context, 'Görevi kaldır?', args, action: 'Kaldır')) return;
    if (!mounted) return;
    setState(() { busy = true; error = null; });
    try { await widget.controller.control(widget.sessionId, 'todo.$control', arguments: {'args': args}, confirmed: true); widget.controller.refreshInBackground(); }
    on CommandAccepted catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: e.id)); }
    on CommandUncertain catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: e.id)); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final phases = widget.controller.snapshot.session(widget.sessionId)?.todos ?? [];
    final todos = <Json>[];
    for (final phase in phases) { if (phase['tasks'] is List) { for (final task in objects(phase['tasks'])) { todos.add({...task, if (phase['name'] != null) 'phase': phase['name']}); } } else { todos.add(phase); } }
    final enabled = !busy && widget.controller.connection.connected;
    return Scaffold(appBar: AppBar(title: const Text('Yapılacaklar')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
      if (error != null) ErrorNotice(error!), if (busy) const LinearProgressIndicator(),
      OutlinedButton.icon(onPressed: enabled ? () async { final text = await textDialog(context, 'Görev ekle', 'Görev', message: 'İsteğe bağlı aşama biçimi: [aşama] görev'); if (text != null && text.trim().isNotEmpty) await run('append', text); } : null, icon: const Icon(Icons.add_rounded), label: const Text('Görev ekle')),
      if (todos.isEmpty) const Text('Kayıtlı görev yok.'),
      for (final todo in todos) Builder(builder: (context) {
        final text = '${todo['text'] ?? todo['content'] ?? todo['title'] ?? todo['description'] ?? ''}';
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ListTile(contentPadding: EdgeInsets.zero, title: Text(text), subtitle: Text([todo['phase'], todo['status']].whereType<String>().join(' · '))), Wrap(spacing: 8, children: [for (final action in [('start', 'Başlat'), ('done', 'Tamamla'), ('drop', 'Bırak'), ('rm', 'Sil')]) TextButton(onPressed: enabled && text.isNotEmpty ? () => run(action.$1, text) : null, child: Text(action.$2))]), const Divider()]);
      }),
    ])));
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
    try { await widget.controller.command('agent.command', sessionId: widget.sessionId, payload: {'agentId': id, 'command': command, if (message != null) 'message': message}); widget.controller.refreshInBackground(); }
    on CommandAccepted catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: e.id)); }
    on CommandUncertain catch (e) { if (mounted) openScreen(context, OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: e.id)); }
    catch (e) { if (mounted) await perform(context, () async { throw e; }); }
    if (mounted) setState(() => busy.remove(id));
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final session = widget.controller.snapshot.session(widget.sessionId);
    final agents = session?.subagents ?? [];
    return Scaffold(appBar: AppBar(title: const Text('Alt ajanlar')), body: SafeArea(top: false, child: agents.isEmpty ? const SingleChildScrollView(child: EmptyState(icon: Icons.account_tree_outlined, title: 'Etkin alt ajan görünmüyor.', message: 'Bu oturum alt ajan durumunu paylaştığında gerçek görevleri ve durumları burada görünür.')) : ListView.builder(itemCount: agents.length, itemBuilder: (context, index) {
      final agent = agents[index];
      final id = '${agent['id'] ?? agent['agentId'] ?? agent['name'] ?? ''}';
      final enabled = widget.controller.connection.connected && !busy.contains(id) && session?.archived == false && session?.activeUnbridged == false && session?.supports('agent.command') == true;
      return Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${agent['name'] ?? id}', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 8), Text('${agent['status'] ?? 'Durum belirtilmedi'}'), if (agent['task'] != null || agent['description'] != null) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText('${agent['task'] ?? agent['description']}')), if (agent['result'] != null) ExpansionTile(title: const Text('Sonuç'), tilePadding: EdgeInsets.zero, children: [SelectableText('${agent['result']}')]), TextButton.icon(onPressed: () => openScreen(context, SessionControlScreen(controller: widget.controller, sessionId: widget.sessionId, view: 'agentMessages', title: 'Ajan mesaj geçmişi', arguments: {'agentId': id})), icon: const Icon(Icons.history_rounded), label: const Text('Mesaj geçmişi')), if (agent['metrics'] != null) SelectableText(controlText(agent['metrics'])), const SizedBox(height: 12), Wrap(spacing: 8, children: [if (session?.supports('agent.chat') == true) OutlinedButton.icon(onPressed: enabled ? () => command(agent, 'chat') : null, icon: const Icon(Icons.chat_outlined), label: const Text('Mesaj')), if (session?.supports('agent.revive') == true) TextButton(onPressed: enabled ? () => command(agent, 'revive') : null, child: const Text('Yeniden etkinleştir')), if (session?.supports('agent.kill') == true) TextButton(onPressed: enabled ? () => command(agent, 'kill') : null, child: const Text('Durdur'))]), const SizedBox(height: 20), const Divider()]));
    })));
  });
}
