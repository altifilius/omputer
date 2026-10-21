import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

abstract interface class NativeAdapter {
  Future<Object?> invoke(String method, [Json? arguments]);
  Stream<Object?> get events;
}

class PlatformAdapter implements NativeAdapter {
  static const _methods = MethodChannel('omputer/connection');
  static const _events = EventChannel('omputer/events');
  @override
  Future<Object?> invoke(String method, [Json? arguments]) => _methods.invokeMethod<Object?>(method, arguments);
  @override
  Stream<Object?> get events => _events.receiveBroadcastStream();
}

class ControllerFailure implements Exception {
  ControllerFailure(this.message, [this.code = 'unknown']);
  final String message, code;
  @override
  String toString() => message;
}

class CommandAccepted extends ControllerFailure {
  CommandAccepted(this.operation) : super('İşlem bilgisayarda sürüyor. Sonucunu işlemlerden izle; yeniden gönderme.', 'command_accepted');
  final Json operation;
  String get id => '${operation['id']}';
}

class CommandUncertain extends ControllerFailure {
  CommandUncertain(this.operation, Object cause) : super('İşlemin sonucu henüz bilinmiyor. Aynı işlemi yeniden gönderme; kimliğiyle sorgulanacak. $cause', 'command_unknown');
  final Json operation;
  String get id => '${operation['id']}';
}

class DraftChange {
  DraftChange(this.key, this.identity, this.before, this.after);
  final String key, identity;
  final Json? before, after;
}

class Transcript extends ChangeNotifier {
  final Map<String, ValueNotifier<ChatMessage>> messages = {};
  List<String> ids = [];
  bool loading = false, loaded = false, hasMore = true;
  String? error;
  int generation = 0;
  bool refreshAfterLoad = false;
  int? get before => ids.isEmpty ? null : messages[ids.first]!.value.sequence;

  void upsert(ChatMessage message) {
    final existing = messages[message.id];
    if (existing != null) {
      if (message.revision >= existing.value.revision) existing.value = message;
      return;
    }
    messages[message.id] = ValueNotifier(message);
    ids.add(message.id);
    ids.sort((a, b) => messages[a]!.value.sequence.compareTo(messages[b]!.value.sequence));
    notifyListeners();
  }

  void merge(List<ChatMessage> page) {
    for (final message in page) {
      final existing = messages[message.id];
      if (existing == null) {
        messages[message.id] = ValueNotifier(message);
      } else if (message.revision >= existing.value.revision) {
        existing.value = message;
      }
    }
    ids = messages.keys.toList()..sort((a, b) => messages[a]!.value.sequence.compareTo(messages[b]!.value.sequence));
    notifyListeners();
  }

  void reset() {
    generation++;
    for (final message in messages.values) { message.dispose(); }
    messages.clear();
    ids = [];
    hasMore = true;
    loaded = false;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final message in messages.values) { message.dispose(); }
    super.dispose();
  }
}

class OmputerController extends ChangeNotifier {
  OmputerController({NativeAdapter? adapter, this.maxInactiveTranscripts = 8}) : native = adapter ?? PlatformAdapter();
  final NativeAdapter native;
  Snapshot snapshot = Snapshot.empty();
  ConnectionState connection = ConnectionState.empty();
  bool ready = false;
  String theme = 'system';
  String? appVersion, buildNumber;
  int? protocol;
  String? error;
  Json? pendingNavigation;
  final ValueNotifier<Json?> navigation = ValueNotifier(null);
  final Map<String, Transcript> _transcripts = {};
  final int maxInactiveTranscripts;
  final Map<String, int> _readers = {};
  final Map<String, int> _transcriptAccess = {};
  int _accessClock = 0;
  Json localState = {'sections': <String, dynamic>{}};
  final Map<String, Json> _operations = {};
  final Map<String, Future<void>> _operationWrites = {};
  Future<void> _draftWrites = Future.value();
  final ValueNotifier<DraftChange?> draftChanges = ValueNotifier(null);
  Future<void>? _reconciliation;
  final Map<String, Json> _catalogs = {};
  List<Json> get operations => _operations.values.toList()..sort((a, b) => '${b['createdAt'] ?? ''}'.compareTo('${a['createdAt'] ?? ''}'));
  List<Json> operationsFor(String sessionId) => operations.where((entry) => entry['sessionId'] == sessionId).toList();
  StreamSubscription<Object?>? _subscription;
  final _uuid = const Uuid();
  bool _disposed = false;
  List<Json> computers = [];
  bool scanning = false;
  String? discoveryError;
  Json? pairing;
  String pairingStatus = 'idle';
  int _pairRevision = 0, _identityRevision = 0;
  bool _switchingPair = false;
  final Map<String, String> _acceptedResponses = {};
  final Map<String, Json> _acceptedAnswers = {};
  final Map<String, DateTime?> _acceptedAt = {};
  final Set<String> _responding = {};

  void _acceptSnapshot(Snapshot incoming) {
    if (incoming.sequence < snapshot.sequence) return;
    for (final interaction in incoming.interactions) {
      final accepted = _acceptedResponses[interaction.id];
      if (accepted == null) continue;
      if (interaction.status == 'pending') {
        interaction.status = accepted;
      }
      interaction.response ??= _acceptedAnswers[interaction.id];
      interaction.respondedAt ??= _acceptedAt[interaction.id];
    }
    snapshot = incoming;
    _catalogs.removeWhere((id, catalog) {
      final session = incoming.session(id);
      return session == null || catalog['journalId'] != session.journalId || catalog['bindingRevision'] != session.bindingRevision;
    });
  }

  void refreshInBackground() {
    final identity = _identityRevision;
    unawaited(refresh().catchError((Object failure) {
      if (_disposed || identity != _identityRevision) return;
      error = 'İşlem kabul edildi; güncel görünüm alınamadı. Yeniden göndermeden bağlantıyı yenile. $failure';
      notifyListeners();
    }));
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try { return await operation(); }
    on ControllerFailure { rethrow; }
    on PlatformException catch (e) {
      throw ControllerFailure(e.message ?? 'Android işlemi başarısız. Bağlantıyı kontrol edip yeniden deneyin.', e.code);
    }
    on MissingPluginException {
      throw ControllerFailure('Android bağlantı katmanı kullanılamıyor. Uygulamayı Android üzerinde yeniden başlatın.', 'native_unavailable');
    }
    catch (e) { throw ControllerFailure('İşlem tamamlanamadı: $e'); }
  }

  Future<void> initialize() async {
    _subscription = native.events.listen(_event, onError: (Object e) {
      error = 'Yerel bağlantı olayları alınamıyor: $e. Ayarlar’dan yeniden bağlanın.';
      if (!_disposed) notifyListeners();
    });
    try {
      connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('connection'))));
      final cached = Snapshot.fromJson(object(await _guard(() => native.invoke('snapshot'))));
      _acceptSnapshot(cached);
      final preferences = object(await _guard(() => native.invoke('preferences')));
      theme = preferences['theme'] as String? ?? 'system';
      appVersion = preferences['appVersion']?.toString();
      buildNumber = preferences['buildNumber']?.toString();
      protocol = (preferences['protocol'] as num?)?.toInt();
      if (connection.paired) {
        await _loadLocalState();
        await _restoreOperations();
        connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('connect'))));
      }
    } catch (e) { error = '$e'; }
    ready = true;
    if (!_disposed) notifyListeners();
    if (!_disposed && connection.connected) _reconcileInBackground();
  }

  void _event(Object? raw) {
    if (_disposed) return;
    try {
      final envelope = object(raw);
      final data = object(envelope['data']);
      switch (envelope['type']) {
        case 'discovery':
          computers = objects(data['computers']);
          scanning = data['scanning'] == true;
          discoveryError = data['error'] as String?;
          notifyListeners();
        case 'connection':
          if (_switchingPair) return;
          connection = ConnectionState.fromJson(data);
          if (connection.connected) _reconcileInBackground();
          notifyListeners();
        case 'snapshot':
          if (_switchingPair) return;
          final incoming = Snapshot.fromJson(data);
          if (incoming.sequence >= snapshot.sequence) {
            _acceptSnapshot(incoming);
            notifyListeners();
          }
        case 'history_reset':
          if (_switchingPair) return;
          for (final entry in _transcripts.entries.toList()) {
            entry.value.reset();
            if (entry.value.loading) entry.value.refreshAfterLoad = true;
            else unawaited(loadMessages(entry.key));
          }
        case 'navigate':
          pendingNavigation = data;
          navigation.value = data;
        case 'event':
          if (_switchingPair) return;
          _journal(data);
      }
    } catch (e) {
      error = 'Bilgisayardan gelen veri okunamadı: $e. Bağlantıyı yenileyin.';
      notifyListeners();
    }
  }

  void _journal(Json event) {
    final data = object(event['data']);
    switch (event['type']) {
      case 'session.event':
        if (data['type'] == 'transcript_reset') {
          final sessionId = '${event['sessionId'] ?? ''}';
          if (sessionId.isNotEmpty) _transcripts[sessionId]?.reset();
        }
      case 'message.upsert':
        final sessionId = '${event['sessionId'] ?? data['sessionId'] ?? ''}';
        final message = object(data['message'] ?? data);
        if (sessionId.isNotEmpty && message['id'] != null) {
          _transcripts[sessionId]?.upsert(ChatMessage.fromJson({...message, 'sequence': message['sequence'] ?? event['sequence']}));
        }
      case 'device.revoked':
        if (data['currentDevice'] == true) {
          error = 'Bu cihazın erişimi kaldırıldı. Bilgisayardan yeni eşleştirme oluşturun.';
          notifyListeners();
        }
      // Operation changes trigger UUID queries, never another submission.
      case 'operation.updated':
        final operationId = '${data['id'] ?? data['operationId'] ?? ''}';
        if (operationId.isNotEmpty) _reconcileInBackground();
      // Native publishes one authoritative snapshot; Dart owns no second cursor.
      case 'snapshot':
        if (data.containsKey('projects')) {
          final incoming = Snapshot.fromJson(data);
          if (incoming.sequence >= snapshot.sequence) { _acceptSnapshot(incoming); notifyListeners(); }
        }
    }
  }

  void consumeNavigation() { pendingNavigation = null; }
  void clearError() { error = null; notifyListeners(); }
  Transcript? loadedTranscript(String sessionId) => _transcripts[sessionId];
  Transcript transcript(String sessionId) {
    final store = _transcripts.putIfAbsent(sessionId, Transcript.new);
    _transcriptAccess[sessionId] = ++_accessClock;
    _evictTranscripts(protect: sessionId);
    return store;
  }
  Transcript retainTranscript(String sessionId) {
    _readers[sessionId] = (_readers[sessionId] ?? 0) + 1;
    return transcript(sessionId);
  }
  void releaseTranscript(String sessionId) {
    final count = _readers[sessionId] ?? 0;
    if (count <= 1) { _readers.remove(sessionId); } else { _readers[sessionId] = count - 1; }
    _evictTranscripts();
  }
  void _evictTranscripts({String? protect}) {
    if (_disposed) return;
    final inactive = _transcripts.keys.where((id) => id != protect && (_readers[id] ?? 0) == 0 && !_transcripts[id]!.hasListeners && !_transcripts[id]!.loading).toList()
      ..sort((a, b) => (_transcriptAccess[a] ?? 0).compareTo(_transcriptAccess[b] ?? 0));
    final allowed = maxInactiveTranscripts < 0 ? 0 : maxInactiveTranscripts;
    while (inactive.length > allowed) {
      final id = inactive.removeAt(0);
      _transcripts.remove(id)!.dispose();
      _transcriptAccess.remove(id);
    }
  }
  Future<Json> request(String method, String path, [Json? body]) => _guard(() async {
    final identity = _identityRevision;
    final result = await native.invoke('request', {'method': method, 'path': path, if (body != null) 'body': body});
    if (identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; eski yanıt kullanılmadı.', 'connection_changed');
    return object(result);
  });

  Future<void> discover(bool enabled) async {
    final state = object(await _guard(() => native.invoke('discover', {'enabled': enabled})));
    scanning = state['scanning'] == true;
    discoveryError = state['error'] as String?;
    notifyListeners();
  }
  Future<void> requestPair(String computerId, String name, {bool background = false}) async {
    final revision = ++_pairRevision;
    pairing = null; pairingStatus = 'requesting'; notifyListeners();
    try {
      final result = object(await _guard(() => native.invoke('pairRequest', {'computerId': computerId, 'name': name.trim().isEmpty ? 'Omputer Android' : name.trim(), 'background': background})));
      if (revision != _pairRevision || _disposed) return;
      pairing = result; pairingStatus = 'pending'; notifyListeners();
    } catch (_) {
      if (revision == _pairRevision) { pairingStatus = 'idle'; notifyListeners(); }
      rethrow;
    }
  }
  Future<String> pollPair() async {
    final revision = _pairRevision;
    _switchingPair = true;
    late final Json result;
    try { result = object(await _guard(() => native.invoke('pairPoll'))); }
    finally { _switchingPair = false; }
    if (revision != _pairRevision || _disposed) return 'cancelled';
    pairingStatus = '${result['status']}';
    if (pairingStatus == 'approved') {
      _clearIdentity();
      connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('connection'))));
      notifyListeners();
      try {
        await refresh();
        await _loadLocalState();
        await _restoreOperations();
        if (connection.connected) await reconcileOperations();
      } catch (failure) { error = 'Eşleştirme tamamlandı; projeler ve yerel kayıtlar bağlantı geldiğinde alınacak. $failure'; }
    }
    notifyListeners();
    return pairingStatus;
  }
  Future<void> cancelPair() async {
    _pairRevision++; pairing = null; pairingStatus = 'idle';
    await _guard(() => native.invoke('pairCancel'));
    if (!_disposed) notifyListeners();
  }
  void _clearIdentity() {
    _identityRevision++;
    _acceptedResponses.clear();
    _acceptedAnswers.clear(); _acceptedAt.clear();
    _responding.clear();
    _operations.clear(); _operationWrites.clear(); _catalogs.clear();
    _draftWrites = Future.value();
    draftChanges.value = null;
    _reconciliation = null;
    localState = {'sections': <String, dynamic>{}};
    snapshot = Snapshot.empty();
    for (final entry in _transcripts.entries.toList()) {
      entry.value.reset();
      if ((_readers[entry.key] ?? 0) == 0 && !entry.value.hasListeners && !entry.value.loading) {
        _transcripts.remove(entry.key)!.dispose();
        _transcriptAccess.remove(entry.key);
      }
    }
    pendingNavigation = null; navigation.value = null; error = null;
  }

  Future<Json> previewBundle(String bundle) => _guard(() async => object(await native.invoke('previewBundle', {'bundle': bundle.trim()})));

  Future<void> pair(String bundle, String name) async {
    _switchingPair = true;
    try {
      await _guard(() => native.invoke('pair', {'bundle': bundle.trim(), 'name': name.trim().isEmpty ? 'Omputer Android' : name.trim()}));
      _clearIdentity();
    } finally { _switchingPair = false; }
    notifyListeners();
    await reconnect();
  }
  Future<void> reconnect() async {
    final identity = _identityRevision;
    final state = await _guard(() => native.invoke('connect', {'force': true}));
    if (_disposed || identity != _identityRevision) return;
    connection = ConnectionState.fromJson(object(state));
    notifyListeners();
    await refresh();
    await _loadLocalState();
    await _restoreOperations();
    await reconcileOperations();
    _reloadTranscripts();
  }
  Future<void> refresh() async {
    final identity = _identityRevision;
    final incoming = connection.connected
        ? Snapshot.fromJson(await request('GET', '/v1/snapshot'))
        : Snapshot.fromJson(object(await _guard(() => native.invoke('snapshot'))));
    if (_disposed || identity != _identityRevision) return;
    _acceptSnapshot(incoming);
    notifyListeners();
  }

  void _reloadTranscripts() {
    for (final entry in _transcripts.entries.toList()) {
      final store = entry.value;
      store.generation++;
      if (store.loading) store.refreshAfterLoad = true;
      else unawaited(loadMessages(entry.key));
    }
  }

  Future<void> loadMessages(String sessionId, {bool older = false}) async {
    final store = transcript(sessionId);
    if (store.loading || (older && !store.hasMore)) return;
    store.loading = true;
    store.error = null;
    store.notifyListeners();
    final generation = store.generation;
    final hadHistory = store.loaded;
    try {
      final before = older ? store.before : null;
      final result = await request('GET', '/v1/sessions/${Uri.encodeComponent(sessionId)}/messages?limit=50${before == null ? '' : '&before=$before'}');
      if (generation != store.generation || _disposed) return;
      store.merge(objects(result['messages']).map(ChatMessage.fromJson).toList());
      store.loaded = true;
      if (older || !hadHistory) store.hasMore = result['hasMore'] == true;
    } catch (e) { if (generation == store.generation && !_disposed && _transcripts[sessionId] == store) store.error = '$e'; }
    finally {
      store.loading = false;
      if (!_disposed && _transcripts[sessionId] == store) {
        store.notifyListeners();
        if (store.refreshAfterLoad) {
          store.refreshAfterLoad = false;
          unawaited(loadMessages(sessionId));
        }
      }
      _evictTranscripts(protect: sessionId);
    }
  }

  bool _finalOperation(Json value) => value['status'] == 'succeeded' || value['status'] == 'failed';

  Json _mergeOperation(Json incoming) {
    final current = _operations['${incoming['id']}'];
    if (current == null) return {...incoming};
    if (_finalOperation(current)) return {...incoming, ...current};
    if (_finalOperation(incoming)) return {...current, ...incoming};
    final oldTime = instant(current['updatedAt']);
    final newTime = instant(incoming['updatedAt']);
    if (oldTime != null && newTime != null && newTime.isBefore(oldTime)) return {...incoming, ...current};
    return {...current, ...incoming};
  }

  Future<void> _saveOperation(Json incoming, {bool applyBranch = false}) async {
    final id = '${incoming['id']}';
    final identity = _identityRevision;
    final previous = _operationWrites[id];
    final write = () async {
      if (previous != null) { try { await previous; } catch (_) { /* A subsequent durable state remains independently writable. */ } }
      if (_disposed || identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; eski işlem kaydı kullanılmadı.', 'connection_changed');
      final merged = _mergeOperation(incoming);
      await _guard(() => native.invoke('operationSave', {'operation': merged}));
      if (_disposed || identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; eski işlem kaydı kullanılmadı.', 'connection_changed');
      _operations[id] = merged;
      _applyOperationDecision(merged);
      try { await _applyOperationDraft(merged, applyBranch: applyBranch); }
      catch (failure) {
        error = 'İşlem sonuçlandı; taslak güncellenemedi. İşlem geçmişinden sonucu yeniden sorgula. $failure';
        notifyListeners();
        rethrow;
      }
      notifyListeners();
    }();
    _operationWrites[id] = write;
    try { await write; } finally { if (identical(_operationWrites[id], write)) _operationWrites.remove(id); }
  }

  void _applyOperationDecision(Json operation) {
    if (operation['status'] != 'succeeded' || operation['action'] != 'interaction.respond') return;
    final payload = object(object(operation['request'])['payload']);
    final interactionId = payload['interactionId'] as String?;
    if (interactionId == null) return;
    final status = payload['cancelled'] == true ? 'cancelled' : 'resolved';
    _acceptedResponses[interactionId] = status;
    final response = {...payload}..remove('interactionId');
    _acceptedAnswers[interactionId] = response;
    _acceptedAt[interactionId] = instant(operation['updatedAt']);
    final current = snapshot.interaction(interactionId);
    if (current?.status == 'pending') {
      current!.status = status;
      current.response = response;
      current.respondedAt = _acceptedAt[interactionId];
    }
  }

  static bool sameDraft(Object? a, Object? b) {
    if (a is Map && b is Map) return a.length == b.length && a.keys.every((key) => b.containsKey(key) && sameDraft(a[key], b[key]));
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) { if (!sameDraft(a[i], b[i])) return false; }
      return true;
    }
    return a == b;
  }

  static Json composerDraft(Json? draft) => {'text': draft?['text'] ?? '', 'attachments': objects(draft?['attachments']), 'files': objects(draft?['files'])};
  static bool hasDraft(Json? draft) => '${draft?['text'] ?? ''}'.isNotEmpty || objects(draft?['attachments']).isNotEmpty || objects(draft?['files']).isNotEmpty;
  Json _copy(Json value) => object(jsonDecode(jsonEncode(value)));

  Future<T> _withDrafts<T>(Future<T> Function() work) {
    final identity = _identityRevision;
    final next = _draftWrites.catchError((Object _) {}).then((_) {
      if (_disposed || identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; eski taslak kullanılmadı.', 'connection_changed');
      return work();
    });
    _draftWrites = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<Json?> _readDraft(String key) async {
    final value = await _localCall('draftLoad', {'key': key});
    return value == null ? null : object(value);
  }

  Future<void> _releaseUnusedAttachments(List<Json> images) async {
    final ids = images.map((image) => image['id']).whereType<String>().where((id) => RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(id)).toSet();
    if (ids.isEmpty) return;
    final drafts = object(await _localCall('draftList'));
    for (final value in drafts.values) {
      for (final image in objects(object(value)['attachments'])) { ids.remove(image['id']); }
    }
    for (final id in ids) { await _localCall('removeAttachment', {'id': id}); }
  }

  void _draftChanged(String key, Json? before, Json? after) {
    draftChanges.value = DraftChange(key, '${localState['identity'] ?? ''}', before, after);
  }

  Future<void> _writeDraft(String key, Json? value) async {
    final before = await _readDraft(key);
    if (value == null) { await _localCall('draftDelete', {'key': key}); }
    else { await _localCall('draftSave', {'key': key, 'value': value}); }
    _draftChanged(key, before, value);
    final retained = objects(value?['attachments']).map((image) => image['id']).toSet();
    await _releaseUnusedAttachments(objects(before?['attachments']).where((image) => !retained.contains(image['id'])).toList());
  }

  Future<void> _markDraftEffect(Json operation, String effect, {String? branchKey}) async {
    final updated = {...operation, 'draftEffect': effect, if (branchKey != null) 'branchDraftKey': branchKey};
    await _localCall('operationSave', {'operation': updated});
    _operations['${operation['id']}'] = updated;
  }

  Future<void> _applyOperationDraft(Json operation, {bool applyBranch = false}) async {
    if (operation['status'] != 'succeeded' || operation['draftEffect'] != null) return;
    if (operation['identity'] != null && operation['identity'] != localState['identity']) return;
    final identity = _identityRevision;
    final submission = object(operation['draftSubmission']);
    final branch = object(operation['branchRestore']);
    if (submission.isEmpty && branch.isEmpty) return;
    await _withDrafts(() async {
      if (submission.isNotEmpty) {
        final key = submission['key'] as String;
        final submitted = object(submission['value']);
        final current = await _readDraft(key);
        if (sameDraft(current, submitted)) { await _writeDraft(key, null); }
        else { await _releaseUnusedAttachments(objects(submitted['attachments'])); }
        await _markDraftEffect(operation, current == null || sameDraft(current, submitted) ? 'cleared' : 'retained');
        return;
      }
      final body = object(object(operation['result'])['data']);
      if (body['cancelled'] == true) { await _markDraftEffect(operation, 'cancelled'); return; }
      if (body['selectedText'] is! String || body['journalId'] is! String || body['bindingRevision'] is! String || (body['selectedImages'] != null && (body['selectedImages'] is! List || (body['selectedImages'] as List).any((image) => image is! Map)))) throw ControllerFailure('Dal tamamlandı fakat geri yüklenecek istem verisi alınamadı. İşlem sonucunu yeniden sorgula.', 'branch_result');
      final session = snapshot.session('${operation['sessionId']}');
      final payload = object(object(operation['request'])['payload']);
      final original = session?.journalId == payload['expectedJournalId'] && session?.bindingRevision == payload['expectedBindingRevision'];
      final returned = session?.journalId == body['journalId'] && session?.bindingRevision == body['bindingRevision'];
      if (session == null || (!original && !returned)) { await _markDraftEffect(operation, 'stale'); return; }
      final key = branch['key'] as String;
      final branchKey = 'session:${operation['sessionId']}:branch:${operation['id']}';
      var recovered = await _readDraft(branchKey);
      if (recovered == null) {
        final images = await prepareImages(objects(body['selectedImages']));
        if (_disposed || identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; eski dal taslağı geri yüklenmedi.', 'connection_changed');
        final latest = snapshot.session('${operation['sessionId']}');
        final stillOriginal = latest?.journalId == payload['expectedJournalId'] && latest?.bindingRevision == payload['expectedBindingRevision'];
        final stillReturned = latest?.journalId == body['journalId'] && latest?.bindingRevision == body['bindingRevision'];
        if (latest == null || (!stillOriginal && !stillReturned)) { await _markDraftEffect(operation, 'stale'); return; }
        recovered = {'text': body['selectedText'], 'attachments': images, 'files': <Json>[], '_revision': _uuid.v4(), '_branchOperation': operation['id']};
        await _writeDraft(branchKey, recovered);
      }
      final current = await _readDraft(key);
      if (current?['_branchOperation'] == operation['id']) { await _markDraftEffect(operation, 'restored'); await _writeDraft(branchKey, null); return; }
      if (applyBranch && !hasDraft(current) && sameDraft(current?['_revision'], branch['expectedRevision'])) {
        await _writeDraft(key, recovered);
        await _markDraftEffect(operation, 'restored');
        await _writeDraft(branchKey, null);
      } else { await _markDraftEffect(operation, 'review', branchKey: branchKey); }
    });
  }

  List<Json> pendingBranchDrafts(String sessionId) => operationsFor(sessionId).where((entry) => entry['draftEffect'] == 'review').toList();

  Future<void> restoreBranchDraft(String id, {required Json? expected}) async {
    await _withDrafts(() async {
      final operation = _operations[id];
      if (operation == null || operation['draftEffect'] != 'review') throw ControllerFailure('Dal taslağı artık beklemiyor.', 'stale_draft');
      final session = snapshot.session('${operation['sessionId']}');
      final body = object(object(operation['result'])['data']);
      final payload = object(object(operation['request'])['payload']);
      final original = session?.journalId == payload['expectedJournalId'] && session?.bindingRevision == payload['expectedBindingRevision'];
      final returned = session?.journalId == body['journalId'] && session?.bindingRevision == body['bindingRevision'];
      if (session == null || (!original && !returned)) throw ControllerFailure('Oturum dal geri yüklemesinden sonra değişti. Eski istem otomatik geri yüklenmedi.', 'stale_draft');
      final key = '${object(operation['branchRestore'])['key']}';
      final recovered = await _readDraft('${operation['branchDraftKey']}');
      if (recovered == null) throw ControllerFailure('Dal taslağı depolamadan açılamadı. İşlem sonucunu kontrol et.', 'missing_draft');
      if (!sameDraft(await _readDraft(key), expected)) throw ControllerFailure('İnceleme sırasında taslak değişti; yeni taslağı silmemek için geri yüklenmedi.', 'draft_changed');
      await _writeDraft(key, recovered);
      await _markDraftEffect(operation, 'restored');
      await _writeDraft('${operation['branchDraftKey']}', null);
    });
    notifyListeners();
  }

  Future<List<Json>> prepareImages(List<Json> images) async {
    if (images.length > 8) throw ControllerFailure('En çok 8 görsel geri yüklenebilir.', 'image_limit');
    var total = 0;
    final prepared = <Json>[];
    for (final image in images) {
      final data = image['data'];
      final mime = image['mimeType'];
      if (data is! String || data.isEmpty || data.length > 1398104 || !['image/jpeg', 'image/png', 'image/webp', 'image/gif'].contains(mime)) throw ControllerFailure('Dal görseli desteklenen tür veya boyutta değil; bilgisayardaki kaydı incele.', 'invalid_image');
      try {
        final bytes = base64Decode(data);
        total += bytes.length;
        if (bytes.isEmpty || bytes.length > 1024 * 1024 || total > 2 * 1024 * 1024) throw ControllerFailure('Görsel başına 1 MiB, toplam 2 MiB sınırı aşıldı.', 'image_limit');
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        try {
          final descriptor = await ui.ImageDescriptor.encoded(buffer);
          try {
            if (descriptor.width < 1 || descriptor.height < 1 || descriptor.width > 16384 || descriptor.height > 16384 || descriptor.width * descriptor.height > 25000000) throw ControllerFailure('Görsel boyutları desteklenmiyor.', 'image_limit');
            prepared.add({'type': 'image', 'mimeType': mime, 'data': data, 'bytes': bytes.length, 'width': descriptor.width, 'height': descriptor.height});
          } finally { descriptor.dispose(); }
        } finally { buffer.dispose(); }
      } on ControllerFailure { rethrow; }
      catch (_) { throw ControllerFailure('Dal görselinin verisi okunamadı.', 'invalid_image'); }
    }
    return prepared;
  }

  Future<void> _restoreOperations() async {
    final identity = _identityRevision;
    final records = objects(await _guard(() => native.invoke('operationList')));
    if (_disposed || identity != _identityRevision) return;
    for (final record in records) {
      if (record['id'] is! String || record['action'] is! String) continue;
      if (record['identity'] != null && localState['identity'] != null && record['identity'] != localState['identity']) continue;
      final merged = _mergeOperation(record);
      _operations['${record['id']}'] = merged;
      _applyOperationDecision(merged);
      try { await _applyOperationDraft(merged); }
      catch (failure) { error = 'İşlem sonuçlandı; taslak güncellenemedi. İşlem geçmişinden sonucu yeniden sorgula. $failure'; }
    }
    notifyListeners();
  }

  Future<Json> operation(String id) async {
    final result = await request('GET', '/v1/commands/${Uri.encodeComponent(id)}');
    if (result['id'] != id) throw ControllerFailure('İşlem kimliği uyuşmuyor.', 'operation_identity');
    await _saveOperation(result);
    return _operations[id]!;
  }

  Future<Json> operationOutput(String id, {int after = 0, int limit = 100}) => request('GET', _query('/v1/commands/${Uri.encodeComponent(id)}/output', {'after': after, 'limit': limit}));

  Future<Json> loadOperations(String sessionId, {int? before, int limit = 50}) async {
    final result = await request('GET', _query('/v1/sessions/${Uri.encodeComponent(sessionId)}/operations', {'before': before, 'limit': limit}));
    for (final record in objects(result['operations'])) {
      if (record['id'] is String) await _saveOperation({...record, 'sessionId': record['sessionId'] ?? sessionId});
    }
    return result;
  }

  Future<void> reconcileOperations() {
    if (_reconciliation != null) return _reconciliation!;
    final identity = _identityRevision;
    final work = () async {
      if (!connection.connected) return;
      ControllerFailure? failure;
      for (final record in operations.where((entry) => !_finalOperation(entry))) {
        if (_disposed || identity != _identityRevision) return;
        try { await operation('${record['id']}'); }
        on ControllerFailure catch (e) {
          // A request may have been lost before the server persisted it. Keep
          // the original UUID unknown; a 404 never authorizes destructive replay.
          if (e.code != 'not_found' && e.code != 'operation_not_found') failure ??= e;
        }
      }
      if (failure != null) throw failure;
    }();
    _reconciliation = work;
    return work.whenComplete(() { if (identical(_reconciliation, work)) _reconciliation = null; });
  }

  void _reconcileInBackground() {
    final identity = _identityRevision;
    unawaited(reconcileOperations().catchError((Object failure) {
      if (!_disposed && identity == _identityRevision) { error = 'İşlem sonuçları alınamadı; yeniden gönderilmedi. $failure'; notifyListeners(); }
    }));
  }

  String _query(String path, Map<String, Object?> values) {
    final query = Uri(queryParameters: {
      for (final entry in values.entries) if (entry.value != null) entry.key: entry.value is Map || entry.value is List ? jsonEncode(entry.value) : '${entry.value}',
    }).query;
    return '$path?$query';
  }

  Session _controlSession(String sessionId, {String? action}) {
    final session = snapshot.session(sessionId);
    if (session == null || !session.writerConnected || session.activeUnbridged) throw ControllerFailure('Bu oturumun canlı denetim bağlantısı yok.', 'session_unavailable');
    if (action != null && !session.supports(action)) throw ControllerFailure('Bu işlem oturum tarafından desteklenmiyor.', 'unsupported');
    return session;
  }

  Json _expectedIdentity(Session session) {
    if (session.journalId == null || session.bindingRevision == null) throw ControllerFailure('Oturum kimliği henüz doğrulanamadı. Görünümü yenile.', 'session_identity');
    return {'expectedJournalId': session.journalId, 'expectedBindingRevision': session.bindingRevision};
  }

  Future<Json> controls(String sessionId, String view, {Json arguments = const {}}) async {
    final session = _controlSession(sessionId);
    final result = await request('GET', _query('/v1/sessions/${Uri.encodeComponent(sessionId)}/control', {...arguments, 'view': view}));
    final current = snapshot.session(sessionId);
    if (current == null || current.journalId != session.journalId || current.bindingRevision != session.bindingRevision) throw ControllerFailure('Oturum sorgu sırasında değişti. Görünümü yenile.', 'session_changed');
    if (view == 'commands') {
      if (result['catalogRevision'] is! String) throw ControllerFailure('Komut katalog sürümü geçersiz.', 'invalid_catalog');
      if (result['journalId'] != session.journalId || result['bindingRevision'] != session.bindingRevision) throw ControllerFailure('Komut kataloğu eski oturuma ait.', 'stale_catalog');
      _catalogs[sessionId] = result;
    }
    return result;
  }

  Future<Json> control(String sessionId, String control, {Json arguments = const {}, bool confirmed = false}) async {
    final session = _controlSession(sessionId, action: 'session.control');
    final identity = _identityRevision;
    final key = 'session:$sessionId:session.prompt';
    final expected = control == 'branch' ? await loadDraft(key) : null;
    if (identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; dal işlemi gönderilmedi.', 'connection_changed');
    return command('session.control', sessionId: sessionId, payload: {'control': control, 'arguments': arguments, ..._expectedIdentity(session), 'confirmed': confirmed}, branchRestore: control == 'branch' ? {'key': key, 'expectedRevision': expected?['_revision']} : null);
  }

  Future<Json> executeCommand(String sessionId, String commandId, String args, {Object? catalogRevision, bool confirmed = false}) async {
    final session = _controlSession(sessionId, action: 'session.command');
    final catalog = _catalogs[sessionId] ?? await controls(sessionId, 'commands');
    final current = snapshot.session(sessionId);
    if (current == null || current.journalId != session.journalId || current.bindingRevision != session.bindingRevision || catalog['journalId'] != current.journalId || catalog['bindingRevision'] != current.bindingRevision) throw ControllerFailure('Oturum değişti. Komut listesini yenile.', 'stale_catalog');
    if (catalogRevision != null && catalogRevision != catalog['catalogRevision']) throw ControllerFailure('Komut listesi değişti. Yenileyip yeniden seç.', 'stale_catalog');
    final entry = objects(catalog['commands']).where((entry) => entry['id'] == commandId).firstOrNull;
    if (entry == null || entry['available'] != true) throw ControllerFailure('${entry?['unavailableReason'] ?? 'Bu komut kullanılamıyor.'}', 'unsupported_command');
    if (entry['requiresIdle'] == true && ['running', 'human_wait', 'queued', 'background'].contains(session.workState)) throw ControllerFailure('Bu komut için oturumun boşta olması gerekir.', 'session_busy');
    if (['execute', 'destructive', 'provider'].contains(entry['risk']) && !confirmed) throw ControllerFailure('Bu komut açık onay gerektirir.', 'confirmation_required');
    return command('session.command', sessionId: sessionId, payload: {'commandId': commandId, 'args': args, 'catalogRevision': catalog['catalogRevision'], ..._expectedIdentity(session), 'confirmed': confirmed});
  }

  Future<Json> effort(String sessionId) => controls(sessionId, 'effort');
  Future<Json> usage(String sessionId) => controls(sessionId, 'usage');

  Future<Object?> _localCall(String method, [Json? arguments]) => _guard(() async {
    final identity = _identityRevision;
    if (_switchingPair) throw ControllerFailure('Eşleştirme değişiyor; kayıt yapılmadı.', 'connection_changed');
    final value = await native.invoke(method, arguments);
    if (_disposed || identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; eski yerel yanıt kullanılmadı.', 'connection_changed');
    return value;
  });
  Future<void> _loadLocalState() async {
    final state = object(await _localCall('localState'));
    localState = state;
    notifyListeners();
  }
  Future<Json?> loadDraft(String key) => _withDrafts(() => _readDraft(key));
  Future<void> saveDraft(String key, Json value) {
    final saved = {..._copy(value), '_revision': _uuid.v4()};
    return _withDrafts(() => _writeDraft(key, saved));
  }
  Future<void> deleteDraft(String key) => _withDrafts(() => _writeDraft(key, null));
  Future<void> releaseAttachments(List<Json> images) => _withDrafts(() => _releaseUnusedAttachments(images));

  bool hasPendingSubmission(String sessionId, String mode, Json value) => operationsFor(sessionId).any((operation) => !_finalOperation(operation) && operation['action'] == mode && operation['draftSubmission'] is Map && sameDraft(composerDraft(object(object(operation['draftSubmission'])['value'])), composerDraft(value)));

  Future<Json> submitDraft(String sessionId, String mode, Json value, Json payload) async {
    final identity = _identityRevision;
    final session = snapshot.session(sessionId);
    if (!connection.connected || session == null || !session.canSendMessages || !session.supports(mode)) throw ControllerFailure('Bu oturuma şu anda mesaj gönderilemiyor.', 'session_unavailable');
    if (hasPendingSubmission(sessionId, mode, value)) throw ControllerFailure('Bu taslağın gönderimi henüz sonuçlanmadı. Aynı mesajı yeniden gönderme; işlem geçmişinden sonucunu sorgula.', 'submission_pending');
    final key = 'session:$sessionId:$mode';
    final submitted = {..._copy(composerDraft(value)), '_revision': _uuid.v4()};
    await _withDrafts(() => _writeDraft(key, submitted));
    if (identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; taslak gönderilmedi.', 'connection_changed');
    final current = snapshot.session(sessionId);
    if (current == null || !current.canSendMessages || !current.supports(mode) || current.journalId != session.journalId || current.bindingRevision != session.bindingRevision) throw ControllerFailure('Taslak hazırlanırken oturum değişti; mesaj gönderilmedi.', 'session_changed');
    return command(mode, sessionId: sessionId, payload: payload, draftSubmission: {'key': key, 'value': submitted});
  }
  Future<void> updateLocalState(String section, String key, Object? value) async {
    localState = object(await _localCall('localStateSet', {'section': section, 'key': key, 'value': value}));
    notifyListeners();
  }
  Future<List<Json>> pickImages({bool camera = false}) async => objects(await _localCall('pickImages', {'camera': camera}));
  Future<List<Json>> consumeSharedImages() async => objects(await _localCall('sharedImages'));

  Future<Json> projectTree(String projectId, {String path = '', String query = '', Object? cursor, int limit = 100}) => request('GET', _query('/v1/projects/${Uri.encodeComponent(projectId)}/tree', {'path': path, 'query': query, 'cursor': cursor, 'limit': limit}));
  Future<Json> projectChanges(String projectId) => request('GET', '/v1/projects/${Uri.encodeComponent(projectId)}/changes');
  Future<Json> projectDiff(String projectId, String path) => request('GET', _query('/v1/projects/${Uri.encodeComponent(projectId)}/diff', {'path': path}));
  Future<Json> memoryHistory(String projectId, {int? before, int limit = 30}) => request('GET', _query('/v1/projects/${Uri.encodeComponent(projectId)}/memory/history', {'before': before, 'limit': limit}));
  Future<Json> search(String query, {String? projectId, String? sessionId, Object? cursor, int limit = 50}) => request('GET', _query('/v1/search', {'query': query, 'projectId': projectId, 'sessionId': sessionId, 'cursor': cursor, 'limit': limit}));
  Future<Json> exportSession(String sessionId, {String format = 'markdown'}) => request('GET', _query('/v1/sessions/${Uri.encodeComponent(sessionId)}/export', {'format': format}));
  Future<void> shareExport(Json exported) async { await _localCall('shareExport', {'filename': exported['filename'], 'mimeType': exported['mimeType'], 'text': exported['text']}); }

  Future<Json> command(String action, {String? sessionId, Json payload = const {}, Json? draftSubmission, Json? branchRestore}) async {
    if (!connection.connected) throw ControllerFailure('Bilgisayar çevrimdışı. İşlem gönderilmedi; Ayarlar’dan yeniden bağlanın.', 'offline');
    final identity = _identityRevision;
    final id = _uuid.v4();
    final requestBody = object(jsonDecode(jsonEncode({'id': id, if (sessionId != null) 'sessionId': sessionId, 'action': action, 'payload': payload})));
    final now = DateTime.now().toUtc().toIso8601String();
    await _saveOperation({'id': id, 'action': action, if (sessionId != null) 'sessionId': sessionId, 'request': requestBody, 'status': 'unknown', 'createdAt': now, 'updatedAt': now, if (localState['identity'] != null) 'identity': localState['identity'], if (draftSubmission != null) 'draftSubmission': draftSubmission, if (branchRestore != null) 'branchRestore': branchRestore});
    if (identity != _identityRevision || _switchingPair) throw ControllerFailure('Bilgisayar değişti; işlem gönderilmedi.', 'connection_changed');
    late final Json result;
    try {
      result = await request('POST', '/v1/commands', requestBody);
    } catch (failure) {
      if (identity != _identityRevision || _switchingPair) rethrow;
      final uncertain = {..._operations[id]!, 'status': 'unknown', 'lastError': '$failure', 'updatedAt': DateTime.now().toUtc().toIso8601String()};
      try { await _saveOperation(uncertain); }
      catch (storageFailure) {
        if (identity != _identityRevision || _switchingPair) rethrow;
        _operations[id] = _mergeOperation(uncertain);
        notifyListeners();
        throw CommandUncertain(_operations[id]!, '$failure; Yerel sonuç kaydı da yazılamadı: $storageFailure');
      }
      throw CommandUncertain(_operations[id]!, failure);
    }
    final status = result['status'] == 'unknown' ? 'unknown' :
        result['status'] == 'running' ? 'running' :
        result['success'] == false || result['accepted'] == false || result['error'] != null || result['status'] == 'failed' ? 'failed' :
        result['accepted'] == true ? 'running' : result['success'] != true ? 'unknown' : 'succeeded';
    final completed = {..._operations[id]!, 'status': status, 'result': result, 'updatedAt': DateTime.now().toUtc().toIso8601String()};
    try { await _saveOperation(completed, applyBranch: status == 'succeeded'); }
    catch (failure) {
      if (identity != _identityRevision || _switchingPair) rethrow;
      _operations[id] = _mergeOperation(completed);
      _applyOperationDecision(_operations[id]!);
      notifyListeners();
      throw CommandUncertain(_operations[id]!, 'Yanıt alındı fakat yerel kalıcı kayda yazılamadı: $failure');
    }
    if (status == 'running') throw CommandAccepted(_operations[id]!);
    if (status == 'unknown') throw CommandUncertain(_operations[id]!, 'Bilgisayar henüz kesin sonuç bildirmedi.');
    if (status == 'failed') throw ControllerFailure('${object(result['error'])['message'] ?? 'Bilgisayar komutu reddetti.'}', '${object(result['error'])['code'] ?? 'command_failed'}');
    return result;
  }

  Future<void> respond(Interaction interaction, Json answer) async {
    final current = snapshot.interaction(interaction.id);
    final unresolvedResponse = operations.any((entry) => !_finalOperation(entry) && entry['action'] == 'interaction.respond' && object(object(entry['request'])['payload'])['interactionId'] == interaction.id);
    if (current == null || !current.pendingAt(DateTime.now()) || _responding.contains(interaction.id) || unresolvedResponse) {
      throw ControllerFailure('Bu istek artık açık değil veya yanıtı gönderiliyor. Başka bir cihaz yanıtlamış veya süresi dolmuş olabilir.', 'stale_interaction');
    }
    final identity = _identityRevision;
    _responding.add(current.id);
    try {
      await command('interaction.respond', sessionId: current.sessionId, payload: {...answer, 'interactionId': current.id});
      if (_disposed || identity != _identityRevision) return;
      final latest = snapshot.interaction(current.id);
      final status = answer['cancelled'] == true ? 'cancelled' : 'resolved';
      _acceptedResponses[current.id] = status;
      if (latest?.status == 'pending') latest!.status = status;
      notifyListeners();
      refreshInBackground();
    } finally { _responding.remove(current.id); }
  }

  Future<void> updateProject(String id, Json fields) async {
    final memoryFields = ['goal', 'summary', 'nextStep', 'decisions'];
    final result = await request('PATCH', '/v1/projects/${Uri.encodeComponent(id)}', {
      ...fields,
      if (memoryFields.any(fields.containsKey) && !fields.containsKey('expectedMemoryRevision')) 'expectedMemoryRevision': snapshot.project(id)?.memoryRevision ?? 0,
    });
    final index = snapshot.projects.indexWhere((project) => project.id == id);
    if (index >= 0 && result['id'] == id) {
      snapshot.projects[index] = Project.fromJson(result);
      notifyListeners();
    }
    refreshInBackground();
  }
  Future<List<ModelInfo>> models({String? sessionId}) async => objects((sessionId == null ? await request('GET', '/v1/models') : await controls(sessionId, 'models'))['models']).map(ModelInfo.fromJson).toList();
  Future<Json> file(String projectId, String path) => request('GET', '/v1/projects/${Uri.encodeComponent(projectId)}/files?path=${Uri.encodeQueryComponent(path)}');
  Future<void> revoke(String id) async { await request('POST', '/v1/devices/${Uri.encodeComponent(id)}/revoke', {}); refreshInBackground(); }
  Future<void> setBackground(bool enabled) async {
    connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('background', {'enabled': enabled}))));
    notifyListeners();
  }
  Future<void> requestNotifications() async {
    await _guard(() => native.invoke('notifications'));
    await reloadConnection();
  }
  Future<void> reloadConnection() async {
    final identity = _identityRevision;
    final state = await _guard(() => native.invoke('connection'));
    if (_disposed || identity != _identityRevision) return;
    connection = ConnectionState.fromJson(object(state));
    notifyListeners();
    // Native events are not replayed while Flutter is paused. Rehydrate its
    // durable snapshot and every already-open history when Android resumes.
    final cached = await _guard(() => native.invoke('snapshot'));
    if (_disposed || identity != _identityRevision) return;
    _acceptSnapshot(Snapshot.fromJson(object(cached)));
    notifyListeners();
    if (connection.paired) { await _loadLocalState(); await _restoreOperations(); }
    if (connection.connected) await reconcileOperations();
    _reloadTranscripts();
  }
  Future<void> batterySettings() => _guard(() async { await native.invoke('batterySettings'); });
  Future<void> setTheme(String mode) async {
    await _guard(() => native.invoke('theme', {'mode': mode}));
    theme = mode;
    notifyListeners();
  }
  Future<void> forget() async {
    await _guard(() => native.invoke('forget'));
    connection = ConnectionState.empty();
    _clearIdentity();
    notifyListeners();
  }
  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _pairRevision++;
    for (final store in _transcripts.values) { store.dispose(); }
    navigation.dispose();
    draftChanges.dispose();
    super.dispose();
  }
}
