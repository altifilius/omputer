import 'dart:async';
import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'session.dart';
import 'session_controls.dart';
import 'neumorphic.dart';

enum _CustomAnswerChoice { custom }

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, required this.controller});
  final OmputerController controller;
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}
class _InboxScreenState extends State<InboxScreen> {
  bool history = false;
  String query = '';
  final answerOrder = StableActivityOrder();
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final pendingCount = c.snapshot.pending.length;
    final incompleteAnswerTracking = c.snapshot.sessions.any((s) => s.answerSummary == null);
    final answerSessions = c.unreadAnswerSessions.where((s) => '${s.name} ${c.snapshot.project(s.projectId)?.name ?? ''} ${c.answerPreview(s) ?? ''}'.toLowerCase().contains(query.toLowerCase())).toList();
    answerOrder.apply(answerSessions, (s) => s.id, (s) => s.answerSummary?.latest?.timestamp);
    final answerIndices = {for (var index = 0; index < answerSessions.length; index++) answerSessions[index].id: index};
    final items = widget.controller.snapshot.interactions.where((i) => (history || i.pendingAt(DateTime.now())) && '${i.title} ${i.message ?? ''} ${widget.controller.snapshot.project(i.projectId)?.name ?? ''}'.toLowerCase().contains(query.toLowerCase())).toList()..sort((a, b) {
      final ap = a.pendingAt(DateTime.now()), bp = b.pendingAt(DateTime.now());
      if (ap != bp) return ap ? -1 : 1;
      return (b.createdAt ?? DateTime(1970)).compareTo(a.createdAt ?? DateTime(1970));
    });
    return RefreshIndicator(onRefresh: widget.controller.refresh, child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Text('Karar bekleyen · $pendingCount', style: Theme.of(context).textTheme.titleLarge))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: TextField(onChanged: (value) => setState(() => query = value), decoration: const InputDecoration(labelText: 'Karar, yanıt veya proje ara', prefixIcon: Icon(Icons.search_rounded))))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: NeoSurface(depth: NeoDepth.inset, radius: 16, child: SwitchListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 12), title: const Text('Yanıtlanan ve kapananları göster'), value: history, onChanged: (value) => setState(() => history = value))))),
      if (items.isEmpty) SliverToBoxAdapter(child: EmptyState(icon: Icons.mark_email_read_outlined, title: query.isNotEmpty ? 'Eşleşen karar yok.' : history ? 'Kayıtlı karar yok.' : 'Şimdilik senden bir karar beklenmiyor.', message: query.isNotEmpty ? 'Aramayı değiştir veya yanıtlanan ve kapananları da göster.' : 'OMP bir soru, seçim veya izin istediğinde burada görünür. Çevrimdışı görünüm son alınan kayıtları gösterir.')),
      SliverList.builder(itemCount: items.length, itemBuilder: (context, index) => InteractionRow(controller: widget.controller, interaction: items[index])),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 24, 16, 8), child: Text(incompleteAnswerTracking ? 'Yeni yanıtlar' : 'Yeni yanıtlar · ${answerSessions.fold<int>(0, (count, session) => count + c.unreadAnswerCount(session))}', style: Theme.of(context).textTheme.titleLarge))),
      if (incompleteAnswerTracking) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text('Yeni yanıt takibi için bilgisayar uygulamasını güncelle. Eski bağlantıda yalnız mevcut son yanıt önizlemeleri gösterilebilir.'))),
      if (answerSessions.isEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text(incompleteAnswerTracking ? 'Okunmamış yanıt bilgisi bu bilgisayarda kullanılamıyor.' : query.isEmpty ? 'Okunmamış yeni yanıt yok.' : 'Aramayla eşleşen yeni yanıt yok.'))),
      SliverList.builder(itemCount: answerSessions.length, findChildIndexCallback: (key) => key is ValueKey<String> ? answerIndices[key.value] : null, itemBuilder: (context, index) => AnswerInboxRow(key: ValueKey<String>(answerSessions[index].id), controller: c, session: answerSessions[index])),
      const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
    ]));
  });
}

class AnswerInboxRow extends StatefulWidget {
  const AnswerInboxRow({super.key, required this.controller, required this.session});
  final OmputerController controller;
  final Session session;
  @override
  State<AnswerInboxRow> createState() => _AnswerInboxRowState();
}
class _AnswerInboxRowState extends State<AnswerInboxRow> {
  bool opening = false;
  Future<void> openAnswer() async {
    if (opening) return;
    final c = widget.controller, session = widget.session;
    final identity = c.localState['identity'], epoch = c.snapshot.journalEpoch;
    final route = ModalRoute.of(context);
    setState(() => opening = true);
    await perform(context, () async {
      final answer = await c.firstUnreadAnswer(session);
      if (mounted && (route?.isCurrent ?? true) && identity == c.localState['identity'] &&
          epoch == c.snapshot.journalEpoch && session.answerSummary?.generation == c.snapshot.session(session.id)?.answerSummary?.generation && answer != null) {
        openScreen(context, SessionScreen(controller: c, sessionId: session.id, initialMessageId: answer.messageId, initialAnswer: answer));
      }
    });
    if (mounted) setState(() => opening = false);
  }
  Future<void> markRead() async {
    final session = widget.session;
    final latest = session.answerSummary?.latest;
    if (latest == null || opening) return;
    setState(() => opening = true);
    await perform(context, () => widget.controller.markAnswerRead(session, latest));
    if (mounted) setState(() => opening = false);
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.controller, s = widget.session;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: NeoSurface(child: ListTile(
      contentPadding: const EdgeInsets.all(16),
      leading: Icon(Icons.mark_chat_unread_outlined, color: Theme.of(context).colorScheme.primary),
      title: Text(s.name.isEmpty ? 'Adsız oturum' : s.name),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${c.snapshot.project(s.projectId)?.name ?? 'Proje'} · ${dateLabel(s.answerSummary?.latest?.timestamp)}'),
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(c.answerPreview(s) ?? '', maxLines: 2, overflow: TextOverflow.ellipsis)),
        Text('${c.unreadAnswerCount(s)} yeni yanıt', style: Theme.of(context).textTheme.labelLarge),
      ]),
      trailing: opening ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : IconButton(key: ValueKey('answer-read:${s.id}'), tooltip: 'Okundu işaretle', onPressed: markRead, icon: const Icon(Icons.done_all_rounded)),
      onTap: opening ? null : openAnswer,
    )));
  }
}

class InteractionRow extends StatelessWidget {
  const InteractionRow({super.key, required this.controller, required this.interaction});
  final OmputerController controller;
  final Interaction interaction;
  @override
  Widget build(BuildContext context) {
    final pending = interaction.pendingAt(DateTime.now());
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: NeoSurface(child: ListTile(contentPadding: const EdgeInsets.all(16), leading: Icon(interaction.method == 'approval' ? Icons.shield_outlined : Icons.question_answer_outlined, color: pending ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant), title: Text(interaction.title), subtitle: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${controller.snapshot.project(interaction.projectId)?.name ?? 'Proje'} · ${interaction.statusLabel}\n${dateLabel(interaction.createdAt)}')), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => openScreen(context, InteractionScreen(controller: controller, interactionId: interaction.id)))));
  }
}

class InteractionScreen extends StatefulWidget {
  const InteractionScreen({super.key, required this.controller, required this.interactionId});
  final OmputerController controller;
  final String interactionId;
  @override
  State<InteractionScreen> createState() => _InteractionScreenState();
}
class _InteractionScreenState extends State<InteractionScreen> with WidgetsBindingObserver {
  final input = TextEditingController();
  List<QuestionAnswer> answers = [];
  String? selected;
  String? initializedId;
  bool busy = false, refreshing = false;
  String? error;
  Timer? clock;
  bool draftLoading = true, restoring = false;
  Json? restored, acceptedResponse;
  Future<void> draftWrites = Future.value();
  String get draftKey => 'decision:${widget.interactionId}';
  String? draftError;
  String? identity;
  int draftGeneration = 0;
  bool draftRequested = false, secureReady = false, secureRequested = false, secretInput = false;
  Json? privateContext;
  bool contextLoading = false, contextAttempted = false, foreground = true, privatePrompt = false;
  int contextGeneration = 0;
  bool get protected => secret || privatePrompt || widget.controller.snapshot.interaction(widget.interactionId)?.sensitiveContext == true;
  Future<void> loadPrivateContext(Interaction interaction) async {
    if (contextLoading || contextAttempted || !secureReady || !foreground || ModalRoute.isCurrentOf(context) == false || !interaction.pendingAt(DateTime.now()) || busy) return;
    setState(() { contextAttempted = true; contextLoading = true; });
    final generation = ++contextGeneration;
    final owner = identity;
    try {
      final value = await widget.controller.request('GET', '/v1/interactions/${Uri.encodeComponent(interaction.id)}/context');
      if (!mounted || owner != identity || generation != contextGeneration || !foreground || ModalRoute.isCurrentOf(context) == false) return;
      final latest = widget.controller.snapshot.interaction(interaction.id);
      if (value['interactionId'] != interaction.id || value['sessionId'] != interaction.sessionId || latest?.pendingAt(DateTime.now()) != true) throw StateError('Private context identity changed');
      setState(() { privateContext = {'title': value['title'], 'message': value['message']}; contextLoading = false; });
    } catch (_) {
      if (mounted && generation == contextGeneration) setState(() { contextLoading = false; error = 'Korumalı giriş bağlamı açılamadı. Bağlantıyı kontrol edip ekranı yeniden aç.'; });
    }
  }
  bool get secret => secretInput || widget.controller.snapshot.interaction(widget.interactionId)?.secret == true;
  String get secureOwner => 'interaction:${identityHashCode(this)}';
  Future<void> protectSecret() async {
    if (secureRequested) return;
    secureRequested = true;
    try {
      await widget.controller.native.invoke('secureScreen', {'owner': secureOwner, 'enabled': true});
      if (mounted) setState(() => secureReady = true);
    } catch (_) { if (mounted) setState(() => error = 'Gizli giriş ekranı korunamadı. Uygulamayı yeniden aç.'); }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (protected && !foreground) {
      input.clear(); contextGeneration++;
      setState(() { privateContext = null; contextLoading = false; contextAttempted = false; });
    } else if (protected && mounted) { setState(() {}); }
  }
  Future<void> restoreDraft() async {
    final interaction = widget.controller.snapshot.interaction(widget.interactionId);
    if (interaction == null) return;
    draftRequested = true;
    if (interaction.secret || interaction.sensitiveContext) { secretInput = interaction.secret; setState(() => draftLoading = false); unawaited(protectSecret()); return; }
    try {
      final owner = identity;
      final value = await widget.controller.loadDraft(draftKey);
      if (!mounted || owner != identity) return;
      setState(() { restored = value; initializedId = null; draftLoading = false; draftGeneration++; });
    } catch (e) { if (mounted) setState(() { draftLoading = false; draftError = 'Yanıt taslağı açılamadı: $e'; }); }
  }
  void saveDraft() {
    final owner = identity;
    if (protected || restoring || draftLoading || owner != widget.controller.localState['identity']?.toString()) return;
    final value = <String, dynamic>{'text': input.text, 'selected': selected, 'questions': [for (final answer in answers) {'id': answer.id, 'options': answer.options, 'selected': answer.selected.toList(), 'customSelected': answer.customSelected, 'customInput': answer.customInput, 'note': answer.note}]};
    draftWrites = widget.controller.saveDraft(draftKey, value).catchError((Object e) { if (mounted && owner == widget.controller.localState['identity']?.toString()) setState(() => draftError = 'Yanıt taslağı kaydedilemedi: $e'); });
  }
  void changed(VoidCallback change) { setState(change); saveDraft(); }
  Future<void> discard() async {
    if (!await confirm(context, 'Yanıt taslağını sil?', 'Bu karar kapatılmaz; yalnızca telefondaki yanıt taslağı silinir.', action: 'Sil')) return;
    await draftWrites;
    await widget.controller.deleteDraft(draftKey);
    if (mounted) setState(() { restored = null; initializedId = null; draftError = null; draftGeneration++; });
  }
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    identity = widget.controller.localState['identity']?.toString();
    restoreDraft();
    input.addListener(saveDraft);
    clock = Timer.periodic(const Duration(seconds: 15), (_) { if (mounted) setState(() {}); });
    if (widget.controller.snapshot.interaction(widget.interactionId) == null) {
      refreshing = true;
      widget.controller.refresh().catchError((Object e) { if (mounted) setState(() => error = '$e'); }).whenComplete(() { if (mounted) setState(() => refreshing = false); });
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    privateContext = null; contextGeneration++;
    input.removeListener(saveDraft); input.clear(); input.dispose(); clock?.cancel();
    if (secureRequested) unawaited(widget.controller.native.invoke('secureScreen', {'owner': secureOwner, 'enabled': false}).catchError((Object _) => null));
    super.dispose();
  }
  Future<void> send(Interaction interaction, Json response) async {
    if (busy || !mounted) return;
    setState(() { busy = true; error = null; });
    if (protected) { input.clear(); privateContext = null; contextGeneration++; contextLoading = false; }
    try {
      await draftWrites;
      await widget.controller.respond(interaction, response);
      acceptedResponse = protected ? null : response;
      if (!protected) await widget.controller.deleteDraft(draftKey);
    }
    on CommandAccepted catch (e) { if (mounted) { setState(() => error = 'Yanıt işlemi kabul edildi; henüz tamamlanmadı. ${e.id}'); openScreen(context, OperationsScreen(controller: widget.controller, sessionId: interaction.sessionId, operationId: e.id)); } }
    on CommandUncertain catch (e) { if (mounted) { setState(() => error = 'Yanıtın durumu belirsiz. Yeniden göndermeden işlem durumunu incele. ${e.id}'); openScreen(context, OperationsScreen(controller: widget.controller, sessionId: interaction.sessionId, operationId: e.id)); } }
    catch (e) { if (mounted) setState(() => error = protected ? 'Korumalı yanıt gönderilemedi. Yeniden göndermeden işlem durumunu kontrol et.' : '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final currentIdentity = c.localState['identity']?.toString();
    if (identity != currentIdentity) {
      identity = currentIdentity; restored = null; acceptedResponse = null; initializedId = null; draftLoading = true; draftRequested = false;
      privateContext = null; contextGeneration++; contextLoading = false; contextAttempted = false;
      input.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) restoreDraft(); });
    }
    final interaction = c.snapshot.interaction(widget.interactionId);
    if (interaction == null) {
      privateContext = null; contextGeneration++; contextLoading = false;
      if (secret) input.clear();
      return Scaffold(appBar: AppBar(title: const Text('Karar')), body: refreshing ? const Center(child: CircularProgressIndicator()) : EmptyState(icon: Icons.event_busy_outlined, title: 'Bu istek artık görünmüyor.', message: error ?? 'Bağlantıyı yenile. İstek başka bir cihazdan yanıtlanmış, iptal edilmiş veya kayıt dışına çıkmış olabilir.', action: OutlinedButton(onPressed: () => perform(context, c.refresh), child: const Text('Yenile'))));
    }
    if (interaction.secret) secretInput = true;
    if (interaction.sensitiveContext) privatePrompt = true;
    if (!draftRequested) {
      draftRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) restoreDraft(); });
    }
    if (protected && !secureRequested) unawaited(protectSecret());
    if (initializedId != interaction.id) {
      initializedId = interaction.id;
      restoring = true;
      input.text = interaction.secret ? '' : '${restored?['text'] ?? interaction.prefill ?? ''}';
      selected = strings(interaction.options.map((o) => o['label']).toList()).contains(restored?['selected']) ? (restored?['selected'] as String?) : null;
      answers = interaction.questions.map(QuestionAnswer.new).toList();
      for (final answer in answers) {
        final saved = objects(restored?['questions']).where((q) => q['id'] == answer.id && strings(q['options']).join('\u0000') == answer.options.join('\u0000')).firstOrNull;
        if (saved == null) continue;
        for (final label in strings(saved['selected'])) { answer.select(label, true); }
        answer.selectCustom(saved['customSelected'] == true);
        answer.customInput = '${saved['customInput'] ?? ''}';
        answer.note = '${saved['note'] ?? ''}';
      }
      restoring = false;
    }
    final pending = interaction.pendingAt(DateTime.now());
    final visible = foreground && ModalRoute.isCurrentOf(context) != false;
    if (protected && (!pending || !visible)) {
      input.clear();
      if (privateContext != null || contextLoading) { privateContext = null; contextGeneration++; contextLoading = false; contextAttempted = false; }
    }
    if (interaction.sensitiveContext && pending && visible && secureReady && !busy && !contextAttempted && c.connection.connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(loadPrivateContext(interaction)); });
    }
    final enabled = pending && c.connection.connected && !busy && !draftLoading && (!protected || secureReady && visible) && (!interaction.sensitiveContext || privateContext != null);
    final linkMatch = RegExp(r'''https?://[^\s<>"'\)\]]+''').firstMatch('${privateContext?['message'] ?? ''}');
    final loginUrl = linkMatch == null ? null : Uri.tryParse(linkMatch.group(0)!);
    return Scaffold(appBar: AppBar(title: const Text('Bekleyen karar'), actions: [IconButton(tooltip: 'Kaynak konuşmayı aç', onPressed: () => openScreen(context, SessionScreen(controller: c, sessionId: interaction.sessionId)), icon: const Icon(Icons.chat_bubble_outline_rounded))]), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.fromLTRB(24, 12, 24, 40), children: [
      Text(c.snapshot.project(interaction.projectId)?.name ?? 'Proje', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)), const SizedBox(height: 16),
      Text('${privateContext?['title'] ?? interaction.title}', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 12),
      Text('${interaction.statusLabel} · ${dateLabel(interaction.createdAt)}', style: Theme.of(context).textTheme.labelLarge),
      if (interaction.expiresAt != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Son yanıt zamanı: ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(interaction.expiresAt!.toLocal()), alwaysUse24HourFormat: true)} · ${interaction.expiresAt!.toLocal().day}.${interaction.expiresAt!.toLocal().month}')),
      if (privateContext?['message']?.toString().isNotEmpty == true) ...[const SizedBox(height: 24), Text('${privateContext!['message']}')]
      else if (interaction.message?.isNotEmpty == true) ...[const SizedBox(height: 24), LocalMarkdown(data: interaction.message!)],
      if (loginUrl != null && loginUrl.host.isNotEmpty && loginUrl.userInfo.isEmpty) TextButton.icon(onPressed: enabled ? () async {
        final url = loginUrl.toString();
        if (!await confirm(context, 'Giriş bağlantısını aç?', 'Bu adres varsayılan tarayıcıda açılacak:\n$url', action: 'Tarayıcıda aç') || !mounted) return;
        if (!c.connection.connected || c.snapshot.interaction(interaction.id)?.pendingAt(DateTime.now()) != true) return;
        try { await c.openExternalUrl(url); }
        catch (_) { if (mounted) setState(() => error = 'Giriş bağlantısı açılamadı. Varsayılan tarayıcıyı kontrol et.'); }
      } : null, icon: const Icon(Icons.open_in_new_rounded), label: const Text('Giriş bağlantısını aç')),
      if (!pending) ...[const SizedBox(height: 24), const NeoSurface(depth: NeoDepth.inset, padding: EdgeInsets.all(20), child: Text('Bu istek kapandı. Yeniden yanıt gönderilemez; masaüstü ve telefon yanıtlarından ilk geçerli olan kabul edilir.'))],
      if (!pending && !protected && (interaction.response ?? acceptedResponse) != null) ...[const SizedBox(height: 16), NeoSurface(depth: NeoDepth.inset, padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text('Kabul edilen yanıt', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 12), SelectableText(controlText(interaction.response ?? acceptedResponse))]))],
      if (!pending && c.snapshot.pending.where((i) => i.id != interaction.id).isNotEmpty) TextButton.icon(onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute<void>(builder: (_) => InteractionScreen(controller: c, interactionId: c.snapshot.pending.first.id))), icon: const Icon(Icons.arrow_forward_rounded), label: const Text('Sonraki bekleyen karara geç')),
      if (draftLoading || contextLoading) const LinearProgressIndicator(),
      if (draftError != null) ErrorNotice(draftError!),
      if (!c.connection.connected && pending) const Padding(padding: EdgeInsets.only(top: 20), child: NeoSurface(depth: NeoDepth.inset, padding: EdgeInsets.all(20), child: Text('Çevrimdışısın. Yanıt sıraya alınmaz; bağlandığında güncel isteği kontrol edip gönder.'))),
      const SizedBox(height: 24),
      if (interaction.method == 'ask') ...[
        for (var index = 0; index < answers.length; index++) _question(context, answers[index], enabled, interaction.supportsNotes),
        FilledButton.icon(onPressed: enabled && answers.isNotEmpty && answers.every((a) => a.valid) ? () => send(interaction, {'answer': {'kind': 'submit', 'results': answers.map((a) => a.toJson(includeNote: interaction.supportsNotes)).toList()}}) : null, icon: const Icon(Icons.send_rounded), label: Text(busy ? 'Gönderiliyor…' : 'Yanıtları gönder')),
      ] else if (interaction.method == 'select') ...[
        RadioGroup<String>(groupValue: selected, onChanged: (value) { if (enabled) changed(() => selected = value); }, child: Column(children: [for (final option in interaction.options) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: NeoSurface(child: RadioListTile<String>(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), value: '${option['label'] ?? ''}', enabled: enabled, title: Text('${option['label'] ?? ''}'), subtitle: option['description'] == null ? null : Text('${option['description']}'))))])),
        const SizedBox(height: 20), FilledButton(onPressed: enabled && selected != null ? () => send(interaction, {'value': selected}) : null, child: const Text('Seçimi gönder')),
      ] else if (interaction.method == 'confirm' || interaction.method == 'approval') ...[
        if (interaction.method == 'approval') ...[const NeoSurface(depth: NeoDepth.inset, padding: EdgeInsets.all(20), child: Text('Bu izin bilgisayarında bir işlem çalıştırabilir. Yukarıdaki komut / araç bağlamını inceleyerek karar ver.')), const SizedBox(height: 20)],
        FilledButton.icon(onPressed: enabled ? () => send(interaction, {'confirmed': true}) : null, icon: const Icon(Icons.check_rounded), label: Text(interaction.method == 'approval' ? 'İzin ver' : 'Onayla')), const SizedBox(height: 12), OutlinedButton(onPressed: enabled ? () => send(interaction, {'confirmed': false}) : null, child: Text(interaction.method == 'approval' ? 'İzni reddet' : 'Hayır')),
      ] else ...[
        TextField(controller: input, enabled: enabled, obscureText: interaction.secret, enableSuggestions: !interaction.secret, autocorrect: !interaction.secret, autofillHints: interaction.secret ? const <String>[] : null, enableIMEPersonalizedLearning: !interaction.secret, enableInteractiveSelection: !interaction.secret, keyboardType: interaction.secret ? TextInputType.visiblePassword : TextInputType.multiline, minLines: interaction.secret ? 1 : interaction.method == 'editor' ? 10 : 2, maxLines: interaction.secret ? 1 : interaction.method == 'editor' ? 24 : 8, style: interaction.method == 'editor' ? const TextStyle(fontFamily: 'monospace', height: 1.5) : null, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: interaction.secret ? 'Gizli yanıtın' : interaction.method == 'editor' ? 'Düzenlenen içerik' : 'Yanıtın', alignLabelWithHint: true)), const SizedBox(height: 20), FilledButton(onPressed: enabled ? () => send(interaction, {'value': input.text}) : null, child: Text(busy ? 'Gönderiliyor…' : 'Yanıtı gönder')),
      ],
      if (pending) Padding(padding: const EdgeInsets.only(top: 12), child: TextButton(onPressed: enabled ? () async { if (await confirm(context, 'İsteği iptal et?', 'Bu istek OMP’ye iptal olarak döner.', action: 'İptal et') && mounted) { await send(interaction, {'cancelled': true}); } } : null, child: const Text('İsteği iptal et'))),
      if (pending && !protected) TextButton.icon(onPressed: enabled ? discard : null, icon: const Icon(Icons.delete_outline_rounded), label: const Text('Yanıt taslağını sil')),
      if (error != null) ErrorNotice(error!),
    ])));
  });

  Widget _question(BuildContext context, QuestionAnswer answer, bool enabled, bool supportsNotes) {
    final choices = Column(children: [for (var i = 0; i < answer.options.length; i++) Builder(builder: (context) {
      final label = answer.options[i];
      final raw = (answer.question['options'] as List)[i];
      final option = raw is Map ? object(raw) : <String, dynamic>{};
      final detail = [option['description'], option['preview']].whereType<String>().where((s) => s.isNotEmpty).join('\n');
      final recommended = answer.question['recommended'] == i;
      return answer.multi ? CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, title: Text('$label${recommended ? ' · önerilen' : ''}'), subtitle: detail.isEmpty ? null : Text(detail), value: answer.selected.contains(label), onChanged: enabled ? (value) => changed(() => answer.select(label, value == true)) : null) : RadioListTile<Object>(contentPadding: EdgeInsets.zero, title: Text('$label${recommended ? ' · önerilen' : ''}'), subtitle: detail.isEmpty ? null : Text(detail), value: label, enabled: enabled);
    }), if (answer.allowCustom)
      answer.multi ? CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, title: const Text('Özel yanıt'), value: answer.customSelected, onChanged: enabled ? (value) => changed(() => answer.selectCustom(value == true)) : null) : RadioListTile<Object>(contentPadding: EdgeInsets.zero, title: const Text('Özel yanıt'), value: _CustomAnswerChoice.custom, enabled: enabled),
    ]);
    return Padding(padding: const EdgeInsets.only(bottom: 24), child: NeoSurface(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text(answer.title, style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 12), if (answer.multi) const Text('Birden çok seçenek seçebilirsin.'),
      if (answer.multi) choices else RadioGroup<Object>(groupValue: answer.customSelected ? _CustomAnswerChoice.custom : answer.selected.firstOrNull, onChanged: (value) {
        if (!enabled) return;
        if (value == _CustomAnswerChoice.custom) {
          changed(() => answer.selectCustom(true));
        } else if (value is String) {
          changed(() => answer.select(value, true));
        }
      }, child: choices),
      if (answer.allowCustom) ...[const SizedBox(height: 12), TextFormField(key: ValueKey('custom:${answer.id}:$draftGeneration'), initialValue: answer.customInput, enabled: enabled && answer.customSelected, minLines: 1, maxLines: 5, onChanged: (value) => changed(() => answer.customInput = value), decoration: const InputDecoration(labelText: 'Özel yanıtın'))],
      if (supportsNotes) ...[const SizedBox(height: 12), TextFormField(key: ValueKey('note:${answer.id}:$draftGeneration'), initialValue: answer.note, enabled: enabled, minLines: 1, maxLines: 5, onChanged: (value) => changed(() => answer.note = value), decoration: const InputDecoration(labelText: 'Bağlam notu (isteğe bağlı)'))],
    ])));
  }
}
