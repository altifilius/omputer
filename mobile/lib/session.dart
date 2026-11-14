import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';
import 'interactions.dart';
import 'session_controls.dart';
import 'session_admin.dart';
import 'session_file_context.dart';
import 'message_input.dart';
import 'projects.dart' show FilePreviewScreen;
import 'neumorphic.dart';
import 'compact_turn.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.controller, required this.sessionId, this.initialMessageId, this.initialAnswer});
  final OmputerController controller;
  final String sessionId;
  final String? initialMessageId;
  final AnswerReference? initialAnswer;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}
class _SessionScreenState extends State<SessionScreen> with WidgetsBindingObserver {
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
  final focusedUserTarget = GlobalKey();
  String? positionedUser;
  bool locating = false;
  bool targetFailed = false;
  bool focusedAnswer = false;
  int? liveWindowStart;
  bool? liveWindowHasMore;
  late String? readingEpoch, readingGeneration;
  late int readingHistory;
  Future<void> loadInitial() async {
    final c = widget.controller;
    final scope = identity, epoch = c.snapshot.journalEpoch, history = transcript.generation;
    bool valid() => mounted && identity == scope && c.snapshot.journalEpoch == epoch && transcript.generation == history;
    final target = widget.initialAnswer?.messageId ?? widget.initialMessageId;
    try {
      await c.loadMessages(widget.sessionId);
      if (!valid() || target == null) return;
      final session = c.snapshot.session(widget.sessionId);
      var reference = widget.initialAnswer ?? (session == null ? null : c.cachedAnswerReference(session, target));
      final rendered = transcript.messages[target]?.value;
      focusedAnswer = reference != null || (rendered != null && rendered.role == 'assistant' && projectCompactTurn([rendered]).answers.isNotEmpty);
      if (reference == null && focusedAnswer && session?.answerSummary != null && rendered != null) {
        reference = await findAnswerReference(session!, rendered);
        if (!valid()) return;
      }
      final targetReference = reference;
      if (!transcript.messages.containsKey(target) && targetReference != null) {
        final previousStart = transcript.before;
        final previousHasMore = transcript.hasMore;
        final page = await c.request('GET', '/v1/sessions/${Uri.encodeComponent(widget.sessionId)}/messages?before=${targetReference.sequence + 1}&limit=50');
        if (!valid()) return;
        final messages = objects(page['messages']).map(ChatMessage.fromJson).toList();
        if (!messages.any((message) => message.id == target && message.sequence == targetReference.sequence)) throw ControllerFailure('Aranan yanıtın kaynağı geçmişte bulunamadı.');
        transcript.merge(messages);
        if (previousStart != null && targetReference.sequence < previousStart) {
          liveWindowStart = previousStart;
          liveWindowHasMore = previousHasMore;
          transcript.hasMore = page['hasMore'] == true;
        }
      } else {
        while (valid() && !transcript.messages.containsKey(target) && transcript.hasMore && transcript.error == null) {
          final before = transcript.before;
          await c.loadMessages(widget.sessionId, older: true);
          if (transcript.before == before) break;
        }
      }
      if (!valid()) return;
      if (!transcript.messages.containsKey(target)) throw ControllerFailure('Aranan mesaj geçmişte bulunamadı. Son mesaja dönerek devam edebilirsin.');
      setState(() => focusedMessage = target);
    } catch (error) {
      if (valid()) setState(() { locating = false; targetFailed = true; readError = '$error'; });
    }
  }
  void targetPositioned() {
    if (!mounted || !locating) return;
    setState(() => locating = false);
    scheduleVisibility();
  }
  void positionUser(String id) {
    if (positionedUser == id) return;
    positionedUser = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = focusedUserTarget.currentContext;
      if (!mounted || focusedMessage != id || target == null) return;
      Scrollable.ensureVisible(target, alignment: .5, duration: Duration.zero);
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && focusedMessage == id) targetPositioned(); });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }
  Future<void> loadOlder() async {
    if (focusedMessage != null || liveWindowStart == null) return widget.controller.loadMessages(widget.sessionId, older: true);
    if (transcript.loading) return;
    final before = liveWindowStart!, epoch = widget.controller.snapshot.journalEpoch, scope = identity, history = transcript.generation;
    setState(() { transcript.loading = true; transcript.error = null; });
    try {
      final page = await widget.controller.request('GET', '/v1/sessions/${Uri.encodeComponent(widget.sessionId)}/messages?before=$before&limit=50');
      if (!mounted || scope != identity || epoch != widget.controller.snapshot.journalEpoch || history != transcript.generation) return;
      final messages = objects(page['messages']).map(ChatMessage.fromJson).toList();
      transcript.merge(messages);
      if (messages.isNotEmpty) liveWindowStart = messages.map((message) => message.sequence).reduce(math.min);
      liveWindowHasMore = page['hasMore'] == true;
    } catch (error) {
      if (mounted && scope == identity && epoch == widget.controller.snapshot.journalEpoch && history == transcript.generation) transcript.error = '$error';
    } finally {
      widget.controller.finishTranscriptLoad(widget.sessionId, transcript, requireReader: true);
      if (mounted) setState(() {});
    }
  }
  void returnToLatest() {
    setState(() { focusedMessage = null; targetFailed = false; locating = false; readError = null; });
    readingEpoch = widget.controller.snapshot.journalEpoch;
    readingGeneration = widget.controller.snapshot.session(widget.sessionId)?.answerSummary?.generation;
    readingHistory = transcript.generation;
    scheduleVisibility();
  }
  late Transcript transcript;
  final answerViewport = GlobalKey();
  final answerEnds = <_AnswerEndState>{};
  static int nextReader = 0;
  late final readerOwner = 'session-reader:${nextReader++}';
  bool foreground = false, currentRoute = false, visibilityScheduled = false;
  Json? readerScope;
  String? readError;
  final attemptedReads = <String>{};
  bool readPending = false;
  bool referencePending = false;
  final attemptedReferences = <String>{};

  Future<AnswerReference?> findAnswerReference(Session session, ChatMessage rendered, {bool refresh = false}) async {
    final c = widget.controller;
    final epoch = c.snapshot.journalEpoch, scope = identity, generation = session.answerSummary?.generation;
    var after = 0;
    while (mounted && epoch == c.snapshot.journalEpoch && scope == identity && c.snapshot.session(session.id)?.answerSummary?.generation == generation) {
      final page = await c.answerReferences(session, after: after, refresh: refresh);
      if (!mounted || epoch != c.snapshot.journalEpoch || scope != identity) return null;
      final match = page.where((answer) => answer.messageId == rendered.id).firstOrNull;
      if (match != null) return match;
      if (page.isEmpty || page.last.sequence >= rendered.sequence || page.last.ordinal <= after) return null;
      after = page.last.ordinal;
    }
    return null;
  }

  void answerEndChanged(_AnswerEndState anchor, bool attached) {
    if (attached) { answerEnds.add(anchor); } else { answerEnds.remove(anchor); }
    scheduleVisibility();
  }
  void scheduleVisibility() {
    if (!mounted || visibilityScheduled) return;
    visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      visibilityScheduled = false;
      if (mounted) checkAnswerVisibility();
    });
    // Scroll/lifecycle notifications need one frame even with no dirty widget.
    WidgetsBinding.instance.ensureVisualUpdate();
  }
  bool get readingVisible => foreground && currentRoute && !locating && !targetFailed && identity == attachedIdentity;
  void updateReader(Session? session, bool atLatest) {
    final c = widget.controller;
    final summary = session?.answerSummary;
    final next = atLatest && summary != null && c.snapshot.journalEpoch != null ? <String, dynamic>{
      'owner': readerOwner, 'sessionId': widget.sessionId,
      'expectedJournalEpoch': c.snapshot.journalEpoch, 'generation': summary.generation, 'atLatest': true,
    } : null;
    if (jsonEncode(next) == jsonEncode(readerScope)) return;
    final previous = readerScope;
    readerScope = next;
    if (previous != null) unawaited(c.native.invoke('answerReader', {...previous, 'atLatest': false}).then<void>((_) {}, onError: (Object _) {}));
    if (next != null) unawaited(c.native.invoke('answerReader', next).then<void>((_) {}, onError: (Object error) {
      if (mounted) setState(() => readError = 'Okuma görünürlüğü bildirilemedi: $error');
    }));
  }
  bool answerEndVisible(_AnswerEndState anchor) {
    final viewport = answerViewport.currentContext?.findRenderObject();
    final end = anchor.context.findRenderObject();
    if (viewport is! RenderBox || end is! RenderBox || !viewport.attached || !end.attached || !viewport.hasSize || !end.hasSize) return false;
    final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
    final bounds = end.localToGlobal(Offset.zero) & end.size;
    return visible.overlaps(bounds);
  }
  void checkAnswerVisibility() {
    final c = widget.controller;
    final session = c.snapshot.session(widget.sessionId);
    final summary = session?.answerSummary;
    if (readingEpoch != c.snapshot.journalEpoch || readingGeneration != summary?.generation || readingHistory != transcript.generation) {
      updateReader(null, false);
      readingEpoch = c.snapshot.journalEpoch; readingGeneration = summary?.generation; readingHistory = transcript.generation;
      attemptedReads.clear(); attemptedReferences.clear(); liveWindowStart = null; liveWindowHasMore = null;
      if (focusedMessage != null || locating) setState(() { targetFailed = true; locating = false; readError = 'Konuşmanın geçmişi değişti; seçili yanıt yeniden açılmalı. Son mesaja dönebilirsin.'; });
      scheduleVisibility();
      return;
    }
    final latest = summary?.latest;
    final visibleEnds = readingVisible ? answerEnds.where((anchor) => anchor.mounted && answerEndVisible(anchor)).toList() : <_AnswerEndState>[];
    final visibleAnswers = session != null ? visibleEnds.map((anchor) {
      final rendered = anchor.widget.message;
      final reference = c.cachedAnswerReference(session, rendered.id);
      return reference != null && reference.sourceRevision == rendered.revision && reference.sequence == rendered.sequence ? reference : null;
    }).whereType<AnswerReference>().toList() : <AnswerReference>[];
    visibleAnswers.sort((a, b) => b.ordinal.compareTo(a.ordinal));
    final answer = visibleAnswers.firstOrNull;
    final latestVisible = latest != null && visibleAnswers.any((answer) => answer.messageId == latest.messageId && answer.revision == latest.revision);
    updateReader(session, latestVisible && focusedMessage == null && scroll.hasClients && scroll.offset <= 80);
    if (session != null && summary != null) {
      final missing = visibleEnds.map((anchor) => anchor.widget.message).where((message) {
        final reference = c.cachedAnswerReference(session, message.id);
        return reference == null || reference.sourceRevision != message.revision || reference.sequence != message.sequence;
      }).toList()
        ..sort((a, b) => b.sequence.compareTo(a.sequence));
      final keys = missing.map((message) => jsonEncode([identity, c.snapshot.journalEpoch, summary.generation, message.id, message.revision])).toSet();
      attemptedReferences.retainAll(keys);
      final unresolved = missing.where((message) => !attemptedReferences.contains(jsonEncode([identity, c.snapshot.journalEpoch, summary.generation, message.id, message.revision]))).firstOrNull;
      if (!referencePending && unresolved != null) {
        referencePending = true;
        attemptedReferences.add(jsonEncode([identity, c.snapshot.journalEpoch, summary.generation, unresolved.id, unresolved.revision]));
        unawaited(findAnswerReference(session, unresolved, refresh: c.cachedAnswerReference(session, unresolved.id) != null).then<void>((_) {}, onError: (Object error) {
          if (mounted) setState(() => readError = 'Yanıtın okuma kaynağı alınamadı: $error');
        }).whenComplete(() { referencePending = false; scheduleVisibility(); }));
      }
    }
    if (answer == null || session == null || summary == null) { attemptedReads.clear(); return; }
    final key = '${identity}:${c.snapshot.journalEpoch}:${summary.generation}:${answer.messageId}:${answer.revision}';
    attemptedReads.removeWhere((value) => value != key);
    final marker = c.answerReadMarker(session.id);
    if (summary.matchesMarker(marker, c.snapshot.journalEpoch) &&
        ((marker['ordinal'] as num? ?? 0) > answer.ordinal ||
         (marker['ordinal'] == answer.ordinal && marker['messageId'] == answer.messageId && (marker['revision'] as num? ?? 0) >= answer.revision))) return;
    if (readPending || !attemptedReads.add(key)) return;
    readPending = true;
    unawaited(c.markAnswerRead(session, answer, expectedEpoch: c.snapshot.journalEpoch).then<void>((_) {
      if (mounted && readError != null) setState(() => readError = null);
    }, onError: (Object error) {
      if (mounted) setState(() => readError = 'Okuma konumu kaydedilemedi: $error');
    }).whenComplete(() { readPending = false; scheduleVisibility(); }));
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    currentRoute = ModalRoute.isCurrentOf(context) ?? false;
    if (!readingVisible) { updateReader(null, false); attemptedReads.clear(); }
    scheduleVisibility();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) { updateReader(null, false); attemptedReads.clear(); }
    scheduleVisibility();
  }
  @override
  void initState() {
    super.initState();
    transcript = widget.controller.retainTranscript(widget.sessionId);
    WidgetsBinding.instance.addObserver(this);
    foreground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    readingEpoch = widget.controller.snapshot.journalEpoch;
    readingGeneration = widget.controller.snapshot.session(widget.sessionId)?.answerSummary?.generation;
    readingHistory = transcript.generation;
    locating = widget.initialAnswer != null || widget.initialMessageId != null;
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    updateReader(null, false);
    widget.controller.draftChanges.removeListener(controllerDraftChanged);
    message.removeListener(draftChanged);
    // A deep target merges disjoint pages, but its live paging boundary is
    // route-local. Do not retain that cache after losing the boundary.
    if (liveWindowStart != null && transcript.before != null && transcript.before! < liveWindowStart!) transcript.reset();
    widget.controller.releaseTranscript(widget.sessionId);
    message.dispose(); scroll.dispose(); super.dispose();
  }
  void positionChanged() {
    final away = scroll.hasClients && scroll.offset > 80;
    if (away != showLatest && mounted) setState(() => showLatest = away);
    scheduleVisibility();
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
      case 'resume': await selectSession();
      case 'thinking' || 'effort': await action(session, 'thinking');
      case 'new': await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => NewSessionScreen(controller: widget.controller, projectId: session.projectId)));
      case 'settings' || 'login' || 'setup' || 'logout' || 'skills':
        await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => SessionAdminScreen(controller: widget.controller, sessionId: session.id, view: name)));
      case 'clipboard':
        final target = await showDialog<String>(context: context, builder: (context) => SimpleDialog(title: const Text('Neyi kopyalayacaksın?'), children: [for (final item in [('code', 'Son kod bloğu'), ('command', 'Son kabuk/eval komutu'), ('link', 'Son bağlantı')]) SimpleDialogOption(onPressed: () => Navigator.pop(context, item.$1), child: Text(item.$2))]));
        if (target != null && mounted) await executeLocalCommand('copy', target);
      case 'open_url': await executeLocalCommand('open', '');
      case 'export': await action(session, 'export');
      case 'git':
        final project = widget.controller.snapshot.project(session.projectId);
        if (project != null) await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => FilePreviewScreen(controller: widget.controller, project: project)));
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
    setState(() { sending = true; draftError = null; });
    try {
      await draftWrites;
      await widget.controller.submitDraft(current.id, submittedMode, submitted, {'message': fullText, if (objects(submitted['attachments']).isNotEmpty) 'images': objects(submitted['attachments']).map((i) => {'type': 'image', 'mimeType': i['mimeType'], 'data': i['data']}).toList(), 'runCommands': false, 'expandPromptTemplates': false});
      widget.controller.refreshInBackground();
      if (mounted && submittedMode == 'session.prompt' && ['running', 'background', 'human_wait', 'queued'].contains(current.workState)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mesaj çalışma sırasına alındı')));
      }
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
  Future<void> selectSession() async {
    final c = widget.controller;
    final selected = await showModalBottomSheet<Session>(context: context, isScrollControlled: true, showDragHandle: true, builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [
      const ListTile(title: Text('Devam edilecek oturumu seç')),
      for (final item in c.snapshot.sessions.where((item) => item.canResume || item.canRelocate || item.canSendMessages)) ListTile(title: Text(item.name.isEmpty ? 'Adsız oturum' : item.name), subtitle: Text('${c.snapshot.project(item.projectId)?.name ?? item.cwd}\n${item.statusLabel}'), onTap: () => Navigator.pop(context, item)),
    ])));
    if (!mounted || selected == null) return;
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => SessionScreen(controller: c, sessionId: selected.id)));
  }
  Future<void> relocate() async {
    final c = widget.controller;
    final source = c.snapshot.session(widget.sessionId);
    if (source == null || !source.canRelocate || sending || !c.connection.connected) return;
    final target = await showModalBottomSheet<Project>(context: context, isScrollControlled: true, showDragHandle: true, builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [
      const ListTile(title: Text('Projenin yeni konumunu seç'), subtitle: Text('Özgün konuşma dosyası değiştirilmez; geçmiş güvenli bir kopyadan sürdürülür')),
      for (final project in c.snapshot.projects) ListTile(title: Text(project.name), subtitle: Text(project.path), onTap: () => Navigator.pop(context, project)),
    ])));
    if (!mounted || target == null || !await confirm(context, 'Bu projede oturumu sürdür?', 'Oturum: ${source.name}\nÖnceki konum: ${source.cwd}\nYeni konum: ${target.path}\n\nÖzgün geçmiş korunur. Çalışma bundan sonra seçtiğin proje dosyalarına erişir.', action: 'Konumu seç ve sürdür') || !mounted) return;
    final current = c.snapshot.session(source.id);
    if (current == null || !current.canRelocate || current.journalId != source.journalId || current.sessionFile != source.sessionFile) return;
    setState(() => sending = true);
    try {
      await c.command('session.resume', sessionId: source.id, payload: {'sessionId': source.id, 'targetProjectId': target.id, 'expectedJournalId': source.journalId, 'expectedSessionFile': source.sessionFile, 'confirmed': true});
      c.refreshInBackground();
    } on CommandAccepted catch (accepted) { if (mounted) openOperations(accepted.id); }
    on CommandUncertain catch (uncertain) { if (mounted) openOperations(uncertain.id); }
    catch (failure) { if (mounted) await perform(context, () async { throw failure; }); }
    finally { if (mounted) setState(() => sending = false); }
  }
  Future<void> executeLocalCommand(String name, String args) async {
    final c = widget.controller;
    final catalog = await c.controls(widget.sessionId, 'commands');
    final command = objects(catalog['commands']).where((item) => item['name'] == name).firstOrNull;
    if (command == null) throw ControllerFailure('Komut bu oturumda bulunamadı.');
    final result = await c.executeCommand(widget.sessionId, '${command['id']}', args, catalogRevision: catalog['catalogRevision'], confirmed: true);
    if (mounted && result['id'] is String) openOperations(result['id'] as String);
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
    scheduleVisibility();
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
      if (readError != null) ErrorNotice(readError!),
      if (pending.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: NeoSurface(borderColor: Theme.of(context).colorScheme.primary.withValues(alpha: .5), child: ListTile(leading: const Icon(Icons.pending_actions_rounded), title: Text(pending.first.title, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text('${pending.length} karar bekliyor'), trailing: const Icon(Icons.arrow_forward_rounded), onTap: () => openScreen(context, InteractionScreen(controller: c, interactionId: pending.first.id))))),
      if (session?.model != null || session?.thinkingLevel != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), child: Align(alignment: Alignment.centerLeft, child: Text([session?.model?.name, session?.thinkingLevel == null ? null : 'Düşünme: ${session!.thinkingLevel}'].whereType<String>().join(' · '), style: Theme.of(context).textTheme.labelMedium))),
      if (locating) const LinearProgressIndicator(),
      if (focusedMessage != null || targetFailed) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: NeoSurface(depth: NeoDepth.inset, child: ListTile(title: Text(focusedAnswer ? 'Seçili yanıtı okuyorsun' : 'Arama sonucu konumunda okuyorsun'), subtitle: Text(focusedMessage ?? widget.initialAnswer?.messageId ?? widget.initialMessageId ?? ''), trailing: IconButton(tooltip: 'Canlı son mesaja dön', onPressed: returnToLatest, icon: const Icon(Icons.close_rounded))))),
      ]))),
      Expanded(child: LayoutBuilder(builder: (context, constraints) => Column(children: [
      Expanded(child: SizedBox.expand(key: answerViewport, child: ListenableBuilder(listenable: transcript, builder: (context, _) {
        if (transcript.ids.isEmpty && transcript.loading) return const Center(child: CircularProgressIndicator());
        if (transcript.ids.isEmpty && transcript.error != null) return SingleChildScrollView(child: ErrorNotice(transcript.error!, onRetry: () => c.loadMessages(widget.sessionId)));
        if (transcript.ids.isEmpty) return SingleChildScrollView(child: EmptyState(icon: Icons.forum_outlined, title: live ? 'Konuşma burada başlar.' : 'Henüz mesaj görüntülenemiyor.', message: live ? 'İlk istemi gönder. Canlı mesajlar ve araç sonuçları bilgisayardan geldikçe bu konuşmada görünür. Çevrimdışıysa daha önce açılmamış konuşma geçmişi alınamaz.' : 'Bu konuşma salt okunur. Çevrimdışıysa daha önce açılmamış konuşma geçmişi alınamaz.'));
        final focusedIndex = focusedMessage == null ? -1 : transcript.ids.indexOf(focusedMessage!);
        var visibleEnd = transcript.ids.length;
        if (focusedIndex >= 0) {
          visibleEnd = focusedIndex + 1;
          while (!focusedAnswer && transcript.messages[focusedMessage]?.value.role != 'user' && visibleEnd < transcript.ids.length && transcript.messages[transcript.ids[visibleEnd]]!.value.role != 'user') {
            visibleEnd++;
          }
        }
        final ids = (focusedMessage == null && liveWindowStart != null ? transcript.ids.where((id) => transcript.messages[id]!.value.sequence >= liveWindowStart!) : transcript.ids.take(visibleEnd)).toList();
        final hasMore = focusedMessage == null ? liveWindowHasMore ?? transcript.hasMore : transcript.hasMore;
        final entries = compactConversationEntries(ids, transcript.messages);
        return ListView.builder(key: PageStorageKey('transcript:${widget.sessionId}:${focusedMessage ?? 'live'}'), controller: scroll, reverse: true, padding: const EdgeInsets.only(bottom: 24), itemCount: entries.length + 1, itemBuilder: (context, index) {
          if (index == entries.length) return Column(children: [if (hasMore) TextButton.icon(onPressed: transcript.loading ? null : loadOlder, icon: transcript.loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.history_rounded), label: const Text('Önceki mesajları yükle')), if (transcript.error != null) ErrorNotice(transcript.error!, onRetry: loadOlder)]);
          final entry = entries[entries.length - index - 1];
          final notifiers = entry.messageIds.map((id) => transcript.messages[id]!).toList();
          void openFile(String path, int? line) {
            final project = c.snapshot.project(session?.projectId ?? '');
            if (project != null) openScreen(context, FilePreviewScreen(controller: c, project: project, initialPath: path, initialLine: line));
          }
          final active = index == 0 && visibleEnd == transcript.ids.length && c.connection.connected && session?.writerConnected == true && ['running', 'background', 'human_wait', 'queued'].contains(session?.workState);
          return RepaintBoundary(key: ValueKey(entry.id), child: ListenableBuilder(listenable: Listenable.merge(notifiers), builder: (context, _) {
            final messages = notifiers.map((value) => value.value).toList();
            final focusUser = entry.isUser && messages.single.id == focusedMessage;
            if (focusUser) positionUser(messages.single.id);
            return entry.isUser
              ? KeyedSubtree(key: focusUser ? focusedUserTarget : null, child: UserMessageView(message: messages.single, onOpenFile: openFile))
              : CompactTurnView(messages: messages, active: active, focusedMessageId: focusedMessage, preferAnswerFocus: focusedAnswer, onOpenFile: openFile,
                  onFocusPositioned: targetPositioned,
                  answerEndBuilder: (message) => _AnswerEnd(key: ValueKey('answer-end:${message.id}'), message: message, onChanged: answerEndChanged));
          }));
        });
      }))),
      if (showLatest && focusedMessage == null) Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => scroll.jumpTo(0), icon: const Icon(Icons.arrow_downward_rounded), label: const Text('Son mesaja git'))),
      if (session != null && !live) ConstrainedBox(constraints: BoxConstraints(maxHeight: constraints.maxHeight * .75), child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(session.activeUnbridged
          ? 'Bu oturum terminalde açık, ancak telefon bağlantısı etkin değil. Konuşmayı burada okuyabilirsin; açık oturum telefondan yeniden başlatılmaz.'
          : session.canResume
            ? 'Geçmiş oturum · yeniden açılana kadar salt okunur.'
            : session.resumeBlockedMessage ?? 'Bu oturum şu anda telefondan mesaj göndermeyi veya sürdürmeyi desteklemiyor. Konuşma salt okunur.'),
        if (session.activeUnbridged) ...[const SizedBox(height: 8), const Text('Açık oturumuna terminalden devam et veya bu projede telefondan ayrı, yeni bir oturum başlat. Yeni OMP açılışlarında telefon bağlantısı yüklenir; mevcut terminal oturumu ve konuşması korunur.')],
        if (session.canResume) ...[const SizedBox(height: 10), FilledButton.icon(key: const ValueKey('session-resume'), onPressed: !c.connection.connected || sending ? null : resume, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Oturumu sürdür'))],
        if (session.canRelocate) ...[const SizedBox(height: 12), OutlinedButton.icon(key: const ValueKey('session-relocate'), onPressed: !c.connection.connected || sending ? null : relocate, icon: const Icon(Icons.drive_file_move_rounded), label: const Text('Yeni proje konumunda sürdür'))],
        if (c.snapshot.project(session.projectId) != null) ...[const SizedBox(height: 10), OutlinedButton.icon(key: const ValueKey('session-new-project'), onPressed: !c.connection.connected || sending ? null : () => openScreen(context, NewSessionScreen(controller: c, projectId: session.projectId)), icon: const Icon(Icons.add_rounded), label: const Text('Bu projede yeni oturum'))],
      ]))),
      // This is a height cap, not a flex allocation: the transcript keeps unused space.
      if (live) ConstrainedBox(constraints: BoxConstraints(maxHeight: math.min(constraints.maxHeight, math.max(160, constraints.maxHeight * .75))), child: _composer(context, session!, availableModes)),
      ]))),
    ])));
  });

  Widget _composer(BuildContext context, Session session, List<String> modes) {
    final enabled = widget.controller.connection.connected && !sending && !draftLoading && identity == attachedIdentity;
    return NeoSurface(radius: 24, depth: NeoDepth.raised, child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: LayoutBuilder(builder: (context, constraints) => Column(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: SingleChildScrollView(key: PageStorageKey('composer:${widget.sessionId}'), primary: false, child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (draftError != null) ErrorNotice(draftError!),
      for (final operation in widget.controller.pendingBranchDrafts(widget.sessionId)) Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text('Dal istemi güvenle saklandı', style: Theme.of(context).textTheme.titleSmall), const Text('Geçerli taslağı değiştirmeden önce metni ve görselleri incele.'), Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: enabled ? () => reviewBranch(operation) : null, child: const Text('İncele')))])),
      Wrap(spacing: 8, children: [IconButton(tooltip: 'Komut paletini aç', onPressed: enabled ? palette : null, icon: const Icon(Icons.terminal_rounded)), IconButton(tooltip: 'Galeriden görsel ekle', onPressed: enabled ? () => addImages() : null, icon: const Icon(Icons.add_photo_alternate_outlined)), IconButton(tooltip: 'Kameradan görsel ekle', onPressed: enabled ? () => addImages(camera: true) : null, icon: const Icon(Icons.photo_camera_outlined)), IconButton(tooltip: 'Paylaşılan görselleri ekle', onPressed: enabled ? () => addImages(shared: true) : null, icon: const Icon(Icons.share_outlined)), IconButton(tooltip: 'Taslağı sil', onPressed: enabled && (message.text.isNotEmpty || attachments.isNotEmpty || fileContext.isNotEmpty) ? discardDraft : null, icon: const Icon(Icons.delete_outline_rounded))]),
      if (attachments.isNotEmpty) Wrap(spacing: 12, runSpacing: 12, children: [for (final image in attachments) Column(mainAxisSize: MainAxisSize.min, children: [SizedBox(width: 96, height: 96, child: boundedImage('${image['data'] ?? ''}')), IconButton(tooltip: 'Eklenen görseli kaldır', onPressed: enabled ? () => removeImage(image) : null, icon: const Icon(Icons.close_rounded))])]),
      if (attachments.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Görsel desteği seçili modele bağlıdır; desteklenmeyen modelde gönderim reddedilebilir.', style: Theme.of(context).textTheme.bodySmall)),
      Wrap(spacing: 8, children: [TextButton.icon(onPressed: enabled ? () => addFile(session) : null, icon: const Icon(Icons.attach_file_rounded), label: const Text('Dosya metni ekle')), if (message.text.startsWith('/')) TextButton(onPressed: enabled ? () async { if (await confirm(context, 'Komut değil, düz metin gönder?', 'Başındaki / işareti çalıştırılmaz. Metin aynen modele gönderilir.', action: 'Düz metin gönder')) await send(session, literal: true); } : null, child: const Text('/ metnini aynen gönder'))]),
      for (final file in fileContext) ListTile(title: Text('${file['path']}'), subtitle: Text('${'${file['text']}'.length} karakter · ${file['truncated'] == true ? 'kesilmiş' : 'tam'} metin'), trailing: IconButton(tooltip: 'Dosya bağlamını kaldır', onPressed: enabled ? () { setState(() => fileContext.remove(file)); draftChanged(); } : null, icon: const Icon(Icons.close_rounded))),
      Row(children: [Expanded(child: Semantics(label: 'Mesaj gönderme biçimi', child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: mode, isExpanded: true, itemHeight: null, items: modes.map((m) => DropdownMenuItem(value: m, child: Text(modeLabel(m)))).toList(), onChanged: enabled ? (value) => switchMode(value!) : null)))), if (session.supports('session.abort') && session.status == 'running') IconButton(tooltip: 'Çalışmayı kes', onPressed: enabled ? () => action(session, 'abort') : null, icon: const Icon(Icons.stop_circle_outlined))]),
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Align(alignment: Alignment.centerLeft, child: Text(switch (mode) { 'session.steer' => 'Devam eden çalışmayı yönlendirir; yeni bir oturum açmaz.', 'session.follow_up' => 'Geçerli turdan sonra ele alınacak takip istemi.', _ => 'AI çalışıyorsa mesaj sıraya alınır ve ilk uygun adımda işlenir; boşta ise yeni tur başlar.' }, style: Theme.of(context).textTheme.bodySmall))),
      ]))),
      const SizedBox(height: 8),
      // Only ancillary controls scroll; typing and sending stay above the IME.
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: ConstrainedBox(constraints: BoxConstraints(maxHeight: math.min(math.max(0, constraints.maxHeight - 8), math.max(MediaQuery.textScalerOf(context).scale(24) + 48, constraints.maxHeight - 56))), child: NeumorphicMessageInput(controller: message, enabled: !sending && !draftLoading))), const SizedBox(width: 8), IconButton.filled(tooltip: message.text.startsWith('/') ? 'Komut paletini aç' : modeLabel(mode), onPressed: enabled && (message.text.trim().isNotEmpty || attachments.isNotEmpty || fileContext.isNotEmpty) ? () => send(session) : null, icon: sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward_rounded), style: IconButton.styleFrom(minimumSize: const Size(52, 52)))])
    ]))));
  }
}

/// One pixel at the end of this exact rendered source, outside Markdown caches.
class _AnswerEnd extends StatefulWidget {
  const _AnswerEnd({super.key, required this.message, required this.onChanged});
  final ChatMessage message;
  final void Function(_AnswerEndState, bool) onChanged;
  @override
  State<_AnswerEnd> createState() => _AnswerEndState();
}
class _AnswerEndState extends State<_AnswerEnd> {
  @override
  void initState() { super.initState(); widget.onChanged(this, true); }
  @override
  void didUpdateWidget(covariant _AnswerEnd oldWidget) { super.didUpdateWidget(oldWidget); widget.onChanged(this, true); }
  @override
  void dispose() { widget.onChanged(this, false); super.dispose(); }
  @override
  Widget build(BuildContext context) => const SizedBox(height: 1);
}

String modeLabel(String mode) => switch (mode) { 'session.steer' => 'Yönlendir (steer)', 'session.follow_up' => 'Takibe ekle (follow-up)', _ => 'İstem gönder (prompt)' };
String controlLabel(String name) => switch (name) { 'queue' => 'Bekleyen mesajlar', 'tree' => 'Konuşma ağacı', 'entries' => 'Günlük kayıtları', 'btw' => 'Yan soru (BTW)', 'plan' => 'Plan inceleme', 'goal' => 'Hedef', 'jobs' => 'Arka plan işleri', 'usage' => 'Bağlam ve kullanım', _ => name };
Widget boundedImage(String data) {
  if (data.length > 3 * 1024 * 1024) return const Text('Görsel boyut sınırını aşıyor. Bilgisayarda asıl kaydı aç.');
  try { return ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320, maxWidth: 640), child: Image.memory(base64Decode(data), cacheWidth: 640, cacheHeight: 640, fit: BoxFit.contain, semanticLabel: 'Konuşmaya eklenen görsel', errorBuilder: (context, error, stackTrace) => const Text('Görsel açılamadı.'))); }
  catch (_) { return const Text('Görsel verisi geçerli değil.'); }
}

class UserMessageView extends StatelessWidget {
  const UserMessageView({super.key, required this.message, this.onOpenFile});
  final ChatMessage message;
  final void Function(String, int?)? onOpenFile;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(40, 16, 24, 8),
    child: NeoSurface(radius: 20, padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Sen', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary))),
        IconButton(tooltip: 'Mesajı kopyala', onPressed: () => copyText(context, message.content.where((block) => block['type'] == 'text').map((block) => block['text'] ?? '').join('\n')), icon: const Icon(Icons.copy_rounded)),
        IconButton(tooltip: 'Mesaj bağlantısını kopyala', onPressed: () => copyText(context, 'omputer://message/${Uri.encodeComponent(message.id)}'), icon: const Icon(Icons.link_rounded)),
      ]),
      const SizedBox(height: 12),
      for (final block in message.content)
        if (block['type'] == 'text') Padding(padding: const EdgeInsets.only(bottom: 8), child: LocalMarkdown(data: '${block['text'] ?? ''}', onOpenFile: onOpenFile))
        else if (block['type'] == 'image') _image(block),
      if (message.timestamp != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(dateLabel(message.timestamp), style: Theme.of(context).textTheme.labelSmall)),
    ])),
  );
  Widget _image(Json block) {
    final source = object(block['source']);
    final data = block['data'] ?? source['data'];
    if (data is String) return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: boundedImage(data));
    final url = block['url'] ?? source['url'];
    return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Görsel referansı'), if (url != null) SelectableText('$url') else const Text('Görsel baytları bu kayıtta bulunmuyor; bilgisayardaki konuşmayı incele.')]));
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
  bool busy = false, restoring = false, draftLoading = true;
  int editRevision = 0, restoreRevision = 0;
  String? draftError;
  String? savedDraft;
  Future<void> writes = Future.value();
  String get draftKey => 'new:${projectId ?? 'unselected'}';
  String get identity => '${widget.controller.localState['identity'] ?? ''}';
  late String attachedIdentity;
  Json get draft => {'name': name.text, 'prompt': prompt.text, if (model != null) 'model': {'id': model!.id, 'name': model!.name, 'provider': model!.provider}};

  void applyDraft(Json? value) {
    restoring = true;
    name.text = '${value?['name'] ?? ''}'; prompt.text = '${value?['prompt'] ?? ''}';
    model = value?['model'] is Map ? ModelInfo.fromJson(object(value?['model'])) : null;
    restoring = false;
    savedDraft = jsonEncode(draft);
  }

  void controllerDraftChanged() {
    final change = widget.controller.draftChanges.value;
    if (!mounted || draftLoading || change == null || change.key != draftKey || change.identity != attachedIdentity || identity != attachedIdentity) return;
    if (!OmputerController.sameDraft(draft, OmputerController.newSessionDraft(change.before))) return;
    if (OmputerController.sameDraft(draft, OmputerController.newSessionDraft(change.after))) return;
    editRevision++;
    setState(() { applyDraft(change.after); draftError = null; });
  }

  @override
  void initState() {
    super.initState();
    attachedIdentity = identity;
    savedDraft = jsonEncode(draft);
    name.addListener(save); prompt.addListener(save);
    widget.controller.draftChanges.addListener(controllerDraftChanged);
    restore();
  }

  Future<void> restore() async {
    final key = draftKey, scope = attachedIdentity;
    final revision = editRevision, ticket = ++restoreRevision;
    try {
      final value = await widget.controller.loadDraft(key);
      if (!mounted || key != draftKey || scope != identity || ticket != restoreRevision) return;
      setState(() {
        if (editRevision == revision) applyDraft(value);
        draftLoading = false; draftError = null;
      });
    } catch (e) {
      if (mounted && key == draftKey && scope == identity && ticket == restoreRevision) setState(() { draftLoading = false; draftError = 'Taslak açılamadı: $e'; });
    }
  }

  void save() {
    if (restoring || identity != attachedIdentity) return;
    final encoded = jsonEncode(draft);
    if (encoded == savedDraft) return;
    savedDraft = encoded;
    editRevision++;
    final key = draftKey, scope = attachedIdentity;
    final value = draft;
    writes = writes.catchError((Object _) {}).then((_) {
      if (scope != identity) throw ControllerFailure('Bilgisayar değişti; eski taslak kaydedilmedi.', 'connection_changed');
      return widget.controller.saveDraft(key, value);
    }).catchError((Object e) { if (mounted) setState(() => draftError = 'Taslak kaydedilemedi: $e'); throw e; });
    writes.catchError((Object _) {});
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.draftChanges.removeListener(controllerDraftChanged);
    name.removeListener(save); prompt.removeListener(save); name.dispose(); prompt.dispose();
    super.dispose();
  }

  Future<void> start() async {
    final target = projectId;
    if (target == null || busy || draftLoading || attachedIdentity != identity || !widget.controller.connection.connected || widget.controller.hasPendingNewSession(target, draft)) return;
    final submitted = draft;
    setState(() => busy = true);
    try {
      await writes;
      final result = await widget.controller.startSession(target, submitted);
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
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    if (identity != attachedIdentity) {
      attachedIdentity = identity; editRevision++; applyDraft(null); draftLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) restore(); });
    }
    final pending = projectId != null && widget.controller.hasPendingNewSession(projectId!, draft);
    final operation = projectId == null ? null : widget.controller.newSessionOperation(projectId!);
    return Scaffold(
      appBar: AppBar(title: const Text('Yeni oturum')),
      body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(8), children: [
        if (draftLoading || busy) ...[
          Semantics(label: draftLoading ? 'Taslak açılıyor' : 'Oturum başlatılıyor', child: const LinearProgressIndicator()),
          const SizedBox(height: 16),
        ],
        if (draftError != null) ErrorNotice(draftError!),
        if (!widget.controller.connection.connected) ...[
          NeoSurface(depth: NeoDepth.inset, radius: 16, padding: const EdgeInsets.all(16), child: Semantics(liveRegion: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Çevrimdışı. Taslağını düzenleyebilirsin; oturum başlatmak için yeniden bağlan.'),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: () => perform(context, widget.controller.reconnect), icon: const Icon(Icons.refresh_rounded), label: const Text('Yeniden bağlan')),
          ]))),
          const SizedBox(height: 16),
        ],
        if (pending) ...[
          NeoSurface(depth: NeoDepth.inset, radius: 16, padding: const EdgeInsets.all(16), child: Semantics(liveRegion: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Yeni oturum isteğinin sonucu bekleniyor. Aynı istek yeniden gönderilmez.'),
            if (operation != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(onPressed: () => openScreen(context, OperationsScreen(controller: widget.controller, sessionId: '', operationId: '${operation['id']}')), icon: const Icon(Icons.receipt_long_outlined), label: const Text('İşlem sonucunu kontrol et')),
            ],
          ]))),
          const SizedBox(height: 16),
        ],
        NeoSurface(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(initialValue: projectId, isExpanded: true, decoration: const InputDecoration(labelText: 'Proje'), items: widget.controller.snapshot.projects.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis))).toList(), onChanged: busy || draftLoading ? null : (value) async {
            try {
              await writes;
              if (!mounted) return;
              setState(() { projectId = value; editRevision++; draftLoading = true; applyDraft(null); });
              await restore();
            } catch (e) { if (mounted) setState(() => draftError = '$e'); }
          }),
          const SizedBox(height: 16),
          TextField(key: const ValueKey('new-session-name'), controller: name, enabled: !busy, textInputAction: TextInputAction.next, scrollPadding: const EdgeInsets.all(16), decoration: const InputDecoration(labelText: 'Oturum adı (isteğe bağlı)')),
          const SizedBox(height: 16),
          TextField(key: const ValueKey('new-session-prompt'), controller: prompt, enabled: !busy, minLines: 4, maxLines: 12, keyboardType: TextInputType.multiline, textInputAction: TextInputAction.newline, scrollPadding: const EdgeInsets.all(16), decoration: const InputDecoration(labelText: 'İlk istem (isteğe bağlı)', alignLabelWithHint: true)),
          const SizedBox(height: 16),
          NeoSurface(depth: NeoDepth.inset, radius: 16, child: ListTile(contentPadding: const EdgeInsets.all(16), enabled: !busy && widget.controller.connection.connected, title: const Text('Model'), subtitle: Text(model == null ? 'Bilgisayardaki OMP varsayılanı' : '${model!.provider} · ${model!.name}'), trailing: const Icon(Icons.expand_more_rounded), onTap: busy || !widget.controller.connection.connected ? null : () => chooseModel(context, widget.controller, (choice) async { if (mounted) setState(() => model = choice); save(); }))),
          if (model != null) ...[
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: busy ? null : () { setState(() => model = null); save(); }, child: const Text('Varsayılan modeli kullan'))),
          ],
        ])),
        const SizedBox(height: 16),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Yalnızca bilgisayarda kayıtlı proje köklerinde yeni bir OMP oturumu açılır. Çalışma bilgisayarında yürür.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: busy || draftLoading || pending || projectId == null || !widget.controller.connection.connected ? null : start, icon: const Icon(Icons.play_arrow_rounded), label: Text(busy ? 'Başlatılıyor…' : 'Oturumu başlat')),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: busy || draftLoading ? null : () async {
          if (!await confirm(context, 'Yeni oturum taslağını sil?', 'Oturum oluşturulmaz; yalnızca kaydedilen taslak silinir.', action: 'Sil')) return;
          try { await writes; await widget.controller.deleteDraft(draftKey); if (mounted) setState(() { editRevision++; applyDraft(null); }); }
          catch (e) { if (mounted) setState(() => draftError = 'Taslak silinemedi: $e'); }
        }, icon: const Icon(Icons.delete_outline_rounded), label: const Text('Taslağı sil'))),
        const SizedBox(height: 8),
      ])),
    );
  });
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
        return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: NeoSurface(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ListTile(contentPadding: EdgeInsets.zero, title: Text(text), subtitle: Text([todo['phase'], todo['status']].whereType<String>().join(' · '))), Wrap(spacing: 8, runSpacing: 8, children: [for (final action in [('start', 'Başlat'), ('done', 'Tamamla'), ('drop', 'Bırak'), ('rm', 'Sil')]) TextButton(onPressed: enabled && text.isNotEmpty ? () => run(action.$1, text) : null, child: Text(action.$2))])])));
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
      return Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 12), child: NeoSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${agent['name'] ?? id}', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 8), Text('${agent['status'] ?? 'Durum belirtilmedi'}'), if (agent['task'] != null || agent['description'] != null) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText('${agent['task'] ?? agent['description']}')), if (agent['result'] != null) ExpansionTile(title: const Text('Sonuç'), tilePadding: EdgeInsets.zero, children: [SelectableText('${agent['result']}')]), TextButton.icon(onPressed: () => openScreen(context, SessionControlScreen(controller: widget.controller, sessionId: widget.sessionId, view: 'agentMessages', title: 'Ajan mesaj geçmişi', arguments: {'agentId': id})), icon: const Icon(Icons.history_rounded), label: const Text('Mesaj geçmişi')), if (agent['metrics'] != null) SelectableText(controlText(agent['metrics'])), const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: [if (session?.supports('agent.chat') == true) OutlinedButton.icon(onPressed: enabled ? () => command(agent, 'chat') : null, icon: const Icon(Icons.chat_outlined), label: const Text('Mesaj')), if (session?.supports('agent.revive') == true) TextButton(onPressed: enabled ? () => command(agent, 'revive') : null, child: const Text('Yeniden etkinleştir')), if (session?.supports('agent.kill') == true) TextButton(onPressed: enabled ? () => command(agent, 'kill') : null, child: const Text('Durdur'))])])));
    })));
  });
}
