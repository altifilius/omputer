import 'dart:async';
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

class Transcript extends ChangeNotifier {
  final Map<String, ValueNotifier<ChatMessage>> messages = {};
  List<String> ids = [];
  bool loading = false, loaded = false, hasMore = true;
  String? error;
  int generation = 0;
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
    notifyListeners();
  }

  @override
  void dispose() {
    for (final message in messages.values) { message.dispose(); }
    super.dispose();
  }
}

class OmputerController extends ChangeNotifier {
  OmputerController({NativeAdapter? adapter}) : native = adapter ?? PlatformAdapter();
  final NativeAdapter native;
  Snapshot snapshot = Snapshot.empty();
  ConnectionState connection = ConnectionState.empty();
  bool ready = false;
  String theme = 'system';
  String? error;
  Json? pendingNavigation;
  final ValueNotifier<Json?> navigation = ValueNotifier(null);
  final Map<String, Transcript> _transcripts = {};
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
      if (cached.sequence >= snapshot.sequence) snapshot = cached;
      theme = object(await _guard(() => native.invoke('preferences')))['theme'] as String? ?? 'system';
      if (connection.paired) {
        connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('connect'))));
      }
    } catch (e) { error = '$e'; }
    ready = true;
    if (!_disposed) notifyListeners();
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
          notifyListeners();
        case 'snapshot':
          if (_switchingPair) return;
          final incoming = Snapshot.fromJson(data);
          if (incoming.sequence >= snapshot.sequence) {
            snapshot = incoming;
            notifyListeners();
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
          if (sessionId.isNotEmpty) transcript(sessionId).reset();
        }
      case 'message.upsert':
        final sessionId = '${event['sessionId'] ?? data['sessionId'] ?? ''}';
        final message = object(data['message'] ?? data);
        if (sessionId.isNotEmpty && message['id'] != null) {
          transcript(sessionId).upsert(ChatMessage.fromJson({...message, 'sequence': message['sequence'] ?? event['sequence']}));
        }
      case 'device.revoked':
        if (data['currentDevice'] == true) {
          error = 'Bu cihazın erişimi kaldırıldı. Bilgisayardan yeni eşleştirme oluşturun.';
          notifyListeners();
        }
      // Native applies all other journal state to its durable snapshot and
      // publishes one authoritative snapshot. Dart never owns another cursor.
      case 'snapshot':
        if (data.containsKey('projects')) {
          final incoming = Snapshot.fromJson(data);
          if (incoming.sequence >= snapshot.sequence) { snapshot = incoming; notifyListeners(); }
        }
    }
  }

  void consumeNavigation() { pendingNavigation = null; }
  void clearError() { error = null; notifyListeners(); }
  Transcript transcript(String sessionId) => _transcripts.putIfAbsent(sessionId, Transcript.new);
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
      try { await refresh(); } catch (failure) { error = 'Eşleştirme tamamlandı; projeler bağlantı geldiğinde otomatik alınacak. $failure'; }
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
    snapshot = Snapshot.empty();
    for (final transcript in _transcripts.values) { transcript.reset(); transcript.dispose(); }
    _transcripts.clear(); pendingNavigation = null; navigation.value = null; error = null;
  }

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
    connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('connect'))));
    await refresh();
    notifyListeners();
  }
  Future<void> refresh() async {
    if (connection.connected) {
      final incoming = Snapshot.fromJson(await request('GET', '/v1/snapshot'));
      if (incoming.sequence >= snapshot.sequence) snapshot = incoming;
    } else {
      final cached = Snapshot.fromJson(object(await _guard(() => native.invoke('snapshot'))));
      if (cached.sequence >= snapshot.sequence) snapshot = cached;
    }
    notifyListeners();
  }

  Future<void> loadMessages(String sessionId, {bool older = false}) async {
    final store = transcript(sessionId);
    if (store.loading || (older && !store.hasMore)) return;
    store.loading = true;
    store.error = null;
    store.notifyListeners();
    try {
      final before = older ? store.before : null;
      final generation = store.generation;
      final result = await request('GET', '/v1/sessions/${Uri.encodeComponent(sessionId)}/messages?limit=50${before == null ? '' : '&before=$before'}');
      if (generation != store.generation || _disposed) return;
      store.merge(objects(result['messages']).map(ChatMessage.fromJson).toList());
      store.loaded = true;
      store.hasMore = result['hasMore'] == true;
    } catch (e) { if (_transcripts[sessionId] == store) store.error = '$e'; }
    finally { store.loading = false; if (!_disposed && _transcripts[sessionId] == store) store.notifyListeners(); }
  }

  Future<Json> command(String action, {String? sessionId, Json payload = const {}}) async {
    if (!connection.connected) throw ControllerFailure('Bilgisayar çevrimdışı. İşlem gönderilmedi; Ayarlar’dan yeniden bağlanın.', 'offline');
    final result = await request('POST', '/v1/commands', {'id': _uuid.v4(), if (sessionId != null) 'sessionId': sessionId, 'action': action, 'payload': payload});
    if (result['success'] == false || result['error'] != null) {
      throw ControllerFailure('${object(result['error'])['message'] ?? 'Bilgisayar komutu reddetti.'}', '${object(result['error'])['code'] ?? 'command_failed'}');
    }
    return result;
  }

  Future<void> respond(Interaction interaction, Json answer) async {
    final current = snapshot.interaction(interaction.id);
    if (current == null || !current.pendingAt(DateTime.now())) {
      throw ControllerFailure('Bu istek artık açık değil. Başka bir cihaz yanıtlamış veya süresi dolmuş olabilir.', 'stale_interaction');
    }
    await command('interaction.respond', sessionId: interaction.sessionId, payload: {'interactionId': interaction.id, ...answer});
    current.status = answer['cancelled'] == true ? 'cancelled' : 'resolved';
    notifyListeners();
    try {
      await refresh();
    } catch (e) {
      throw ControllerFailure('Yanıt bilgisayar tarafından kabul edildi; görünüm yenilenemedi. Yanıtı tekrar gönderme. Bağlantıyı yenile: $e', 'accepted_refresh_failed');
    }
  }

  Future<void> updateProject(String id, Json fields) async {
    await request('PATCH', '/v1/projects/${Uri.encodeComponent(id)}', fields);
    await refresh();
  }
  Future<List<ModelInfo>> models() async => objects((await request('GET', '/v1/models'))['models']).map(ModelInfo.fromJson).toList();
  Future<Json> file(String projectId, String path) => request('GET', '/v1/projects/${Uri.encodeComponent(projectId)}/files?path=${Uri.encodeQueryComponent(path)}');
  Future<void> revoke(String id) async { await request('POST', '/v1/devices/${Uri.encodeComponent(id)}/revoke', {}); await refresh(); }
  Future<void> setBackground(bool enabled) async {
    connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('background', {'enabled': enabled}))));
    notifyListeners();
  }
  Future<void> requestNotifications() async {
    await _guard(() => native.invoke('notifications'));
    await reloadConnection();
  }
  Future<void> reloadConnection() async {
    connection = ConnectionState.fromJson(object(await _guard(() => native.invoke('connection'))));
    notifyListeners();
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
    super.dispose();
  }
}
