typedef Json = Map<String, dynamic>;

Json object(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Json> objects(Object? value) => value is List ? value.map(object).toList() : <Json>[];
List<String> strings(Object? value) => value is List ? value.map((e) => '$e').toList() : <String>[];
DateTime? instant(Object? value) => value == null ? null : DateTime.tryParse('$value');

class Project {
  Project.fromJson(Json j)
      : id = j['id'] as String,
        name = j['name'] as String? ?? '',
        path = j['path'] as String? ?? '',
        goal = j['goal'] as String? ?? '',
        summary = j['summary'] as String? ?? '',
        nextStep = j['nextStep'] as String? ?? '',
        decisions = strings(j['decisions']),
        updatedAt = instant(j['updatedAt']),
        memoryUpdatedAt = instant(j['memoryUpdatedAt']),
        sourceSessionId = j['sourceSessionId'] as String?,
        memoryOrigin = j['memoryOrigin'] as String? ?? 'manual',
        activity = j['activity'] is Map ? ProjectActivity.fromJson(object(j['activity'])) : null,
        sessionCount = (j['sessionCount'] as num?)?.toInt() ?? 0,
        memoryRevision = (j['memoryRevision'] as num?)?.toInt() ?? 0,
        pendingCount = (j['pendingCount'] as num?)?.toInt() ?? 0;
  final String id, name, path, goal, summary, nextStep;
  final List<String> decisions;
  final DateTime? updatedAt, memoryUpdatedAt;
  final String? sourceSessionId;
  final String memoryOrigin;
  final ProjectActivity? activity;
  final int sessionCount, pendingCount, memoryRevision;
}

class ProjectActivity {
  ProjectActivity.fromJson(Json value)
      : sessionId = value['sessionId'] as String? ?? '',
        updatedAt = instant(value['updatedAt']),
        goal = value['goal'] as String? ?? '',
        lastAssistantText = value['lastAssistantText'] as String? ?? '',
        nextStep = value['nextStep'] as String? ?? '',
        todos = objects(value['todos']),
        pendingCount = (value['pendingCount'] as num?)?.toInt() ?? 0;
  final String sessionId, goal, lastAssistantText, nextStep;
  final DateTime? updatedAt;
  final List<Json> todos;
  final int pendingCount;
  bool get hasContext => goal.isNotEmpty || lastAssistantText.isNotEmpty || nextStep.isNotEmpty || pendingCount > 0;
}

class ModelInfo {
  ModelInfo.fromJson(Json j)
      : provider = j['provider'] as String? ?? '',
        id = j['id'] as String? ?? '',
        name = j['name'] as String? ?? j['id'] as String? ?? '';
  final String provider, id, name;
  String get key => '$provider/$id';
}

class Session {
  Session.fromJson(Json j)
      : id = j['id'] as String,
        projectId = j['projectId'] as String? ?? '',
        name = j['name'] as String? ?? '',
        cwd = j['cwd'] as String? ?? '',
        transport = j['transport'] as String? ?? 'archive',
        status = j['status'] as String? ?? 'disconnected',
        model = j['model'] is Map ? ModelInfo.fromJson(object(j['model'])) : null,
        thinkingLevel = j['thinkingLevel'] as String?,
        updatedAt = instant(j['updatedAt']),
        sessionFile = j['sessionFile'] as String?,
        journalId = j['journalId'] as String?,
        providerSessionId = j['providerSessionId'] as String?,
        bindingRevision = j['bindingRevision'] as String?,
        writerConnected = j['writerConnected'] is bool ? j['writerConnected'] == true :
            j['transport'] != null && j['transport'] != 'archive' && ['running', 'waiting', 'idle'].contains(j['status']),
        turnError = j['turnError'] == null ? null : (j['turnError'] is Map ? '${object(j['turnError'])['message'] ?? j['turnError']}' : '${j['turnError']}'),
        reportedWorkState = j['workState'] as String?,
        pendingAsyncWork = j['hasPendingAsyncWork'] == true,
        queuedMessages = objects(j['queuedMessages'] ?? j['queue']),
        contextUsage = object(j['contextUsage']),
        todos = objects(j['todos']),
        subagents = objects(j['subagents']),
        asyncJobs = objects(j['asyncJobs'] ?? j['jobs']),
        capabilities = strings(j['capabilities']),
        lastAssistantText = j['lastAssistantText'] as String?,
        lastError = j['lastError'] as String?;
  final String id, projectId, name, cwd, transport, status;
  final ModelInfo? model;
  final String? thinkingLevel, sessionFile, lastAssistantText, lastError;
  final String? journalId, providerSessionId, bindingRevision, turnError, reportedWorkState;
  final bool writerConnected, pendingAsyncWork;
  final DateTime? updatedAt;
  final List<Json> todos, subagents, asyncJobs, queuedMessages;
  final Json contextUsage;
  final List<String> capabilities;
  bool get archived => !writerConnected && (transport == 'archive' || ['closed', 'disconnected', 'failed', 'inactive'].contains(status));
  bool get activeUnbridged => status == 'active-unbridged';
  bool get canResume => archived && !activeUnbridged && supports('session.resume');
  bool get canSendMessages => writerConnected && !activeUnbridged && ['session.prompt', 'session.steer', 'session.follow_up'].any(supports);
  bool get hasPendingAsyncWork => pendingAsyncWork || [...asyncJobs, ...subagents].any((job) => ['running', 'pending', 'queued', 'waiting', 'starting'].contains(job['status']));
  String get workState {
    if (!writerConnected) return 'disconnected';
    if (reportedWorkState != null) return reportedWorkState!;
    if (status == 'waiting') return 'human_wait';
    if (status == 'running') return 'running';
    if (queuedMessages.isNotEmpty) return 'queued';
    if (hasPendingAsyncWork) return 'background';
    if (turnError != null || status == 'failed') return 'turn_error';
    return 'settled';
  }
  bool get isSettled => workState == 'settled' && !hasPendingAsyncWork && queuedMessages.isEmpty;
  bool supports(String action) => capabilities.contains(action) || capabilities.contains(action.replaceFirst('session.', ''));
  String get statusLabel => activeUnbridged ? 'Terminalde açık · telefonda salt okunur' : switch (workState) {
        'running' => 'Çalışıyor',
        'human_wait' => 'Yanıt bekliyor',
        'queued' => 'Sırada mesaj var',
        'background' => 'Arka plan işi sürüyor',
        'turn_error' => 'Son tur başarısız · oturum açık',
        'settled' => 'Tur tamamlandı',
        _ => switch (status) {
          'closed' => 'Kapalı',
          'inactive' => 'Geçmiş oturum',
          'failed' => 'Hata · bağlantı kapalı',
          _ => 'Oturum bağlantısı kesik',
        },
      };
}

class Interaction {
  Interaction.fromJson(Json j)
      : id = j['id'] as String,
        sessionId = j['sessionId'] as String? ?? '',
        projectId = j['projectId'] as String? ?? '',
        method = j['method'] as String? ?? 'input',
        title = j['title'] as String? ?? '',
        message = j['message'] as String?,
        options = objects(j['options']),
        questions = objects(j['questions']),
        prefill = j['prefill'] as String?,
        createdAt = instant(j['createdAt']),
        supportsNotes = j['supportsNotes'] != false,
        expiresAt = instant(j['expiresAt']),
        response = j['response'] is Map ? object(j['response']) : null,
        respondedAt = instant(j['respondedAt'] ?? j['resolvedAt']),
        status = j['status'] as String? ?? 'pending';
  final String id, sessionId, projectId, method, title;
  String status;
  final String? message, prefill;
  final List<Json> options, questions;
  final bool supportsNotes;
  final DateTime? createdAt, expiresAt;
  Json? response;
  DateTime? respondedAt;
  bool pendingAt(DateTime now) => status == 'pending' && (expiresAt == null || expiresAt!.isAfter(now));
  String get statusLabel => switch (status) {
        'pending' => expiresAt != null && !expiresAt!.isAfter(DateTime.now()) ? 'Süresi doldu' : 'Yanıt bekliyor',
        'resolved' => 'Yanıtlandı',
        'cancelled' => 'İptal edildi',
        'expired' => 'Süresi doldu',
        _ => status,
      };
}

class Device {
  Device.fromJson(Json j)
      : id = j['id'] as String,
        name = j['name'] as String? ?? 'Android cihazı',
        createdAt = instant(j['createdAt']),
        lastSeenAt = instant(j['lastSeenAt']),
        revokedAt = instant(j['revokedAt']);
  final String id, name;
  final DateTime? createdAt, lastSeenAt, revokedAt;
}

class Snapshot {
  Snapshot.fromJson(Json j)
      : sequence = (j['sequence'] as num?)?.toInt() ?? 0,
        serverName = j['serverName'] as String? ?? '',
        projects = objects(j['projects']).map(Project.fromJson).toList(),
        sessions = objects(j['sessions']).map(Session.fromJson).toList(),
        interactions = objects(j['interactions']).map(Interaction.fromJson).toList(),
        devices = objects(j['devices']).map(Device.fromJson).toList();
  Snapshot.empty() : sequence = 0, serverName = '', projects = [], sessions = [], interactions = [], devices = [];
  final int sequence;
  final String serverName;
  final List<Project> projects;
  final List<Session> sessions;
  final List<Interaction> interactions;
  final List<Device> devices;
  List<Interaction> get pending => interactions.where((i) => i.pendingAt(DateTime.now())).toList();
  Project? project(String id) => projects.where((p) => p.id == id).firstOrNull;
  Session? session(String id) => sessions.where((s) => s.id == id).firstOrNull;
  Interaction? interaction(String id) => interactions.where((i) => i.id == id).firstOrNull;
}

class ConnectionState {
  ConnectionState.fromJson(Json j)
      : paired = j['paired'] == true,
        connected = j['connected'] == true,
        background = j['background'] == true,
        backgroundRunning = j['backgroundRunning'] == true,
        notifications = j['notifications'] == true,
        batteryExempt = j['batteryExempt'] == true,
        serverName = j['serverName'] as String? ?? '',
        url = j['url'] as String? ?? '',
        identity = j['identity'] as String?,
        lastSyncAt = instant(j['lastSyncAt']),
        cacheFresh = j['cacheFresh'] == true,
        components = object(j['components']),
        lastError = j['lastError'] as String?;
  ConnectionState.empty() : paired = false, connected = false, background = false, backgroundRunning = false, notifications = false, batteryExempt = false, serverName = '', url = '', lastError = null, identity = null, lastSyncAt = null, cacheFresh = false, components = const {};
  final bool paired, connected, background, backgroundRunning, notifications, batteryExempt;
  final String serverName, url;
  final String? lastError;
  final String? identity;
  final DateTime? lastSyncAt;
  final bool cacheFresh;
  final Json components;
}

class ChatMessage {
  ChatMessage.fromJson(Json j)
      : id = j['id'] as String,
        role = j['role'] as String? ?? 'assistant',
        content = j['content'] is String ? [<String, dynamic>{'type': 'text', 'text': j['content']}] : objects(j['content']),
        timestamp = instant(j['timestamp']),
        sequence = (j['sequence'] as num?)?.toInt() ?? 0,
        toolCallId = j['toolCallId'] as String?,
        toolName = j['toolName'] as String?,
        isError = j['isError'] == true,
        usage = object(j['usage']),
        stopReason = j['stopReason'] as String?,
        revision = (j['revision'] as num?)?.toInt() ?? (j['sequence'] as num?)?.toInt() ?? 0;
  final String id, role;
  final List<Json> content;
  final DateTime? timestamp;
  final int sequence, revision;
  final String? toolCallId, toolName, stopReason;
  final bool isError;
  final Json usage;
}

/// Preserves the host's question schema, but keeps selection state local until
/// an acknowledged response. Labels, not option indexes, are sent over v1.
class QuestionAnswer {
  QuestionAnswer(this.question)
      : id = '${question['id'] ?? ''}',
        title = '${question['question'] ?? question['title'] ?? ''}',
        multi = question['multi'] == true,
        options = (question['options'] as List? ?? []).map((e) => e is Map ? '${e['label'] ?? e['value'] ?? ''}' : '$e').toList();
  final Json question;
  final String id, title;
  final bool multi;
  final List<String> options;
  final Set<String> _selected = {};
  Iterable<String> get selected => _selected;
  bool _customSelected = false;
  bool get customSelected => _customSelected;
  String customInput = '', note = '';
  bool get allowCustom => question['allowCustom'] != false;
  bool get valid => (!customSelected || customInput.trim().isNotEmpty) &&
      (multi || _selected.length <= 1) && (multi || _selected.isNotEmpty || customSelected);
  void select(String label, bool enabled) {
    if (!options.contains(label)) return;
    if (!multi) {
      _selected.clear();
      if (enabled) _customSelected = false;
    }
    if (enabled) { _selected.add(label); } else { _selected.remove(label); }
  }
  void selectCustom(bool enabled) {
    if (!allowCustom) return;
    _customSelected = enabled;
    if (enabled && !multi) _selected.clear();
  }
  Json toJson({bool includeNote = true}) => {
        'id': id,
        'question': title,
        'options': options,
        'multi': multi,
        'selectedOptions': options.where(_selected.contains).toList(),
        if (customSelected && customInput.trim().isNotEmpty) 'customInput': customInput.trim(),
        if (includeNote && note.trim().isNotEmpty) 'note': note.trim(),
      };
}
