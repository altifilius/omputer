import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'models.dart';
import 'neumorphic.dart';
import 'ui.dart';

/// Entries are a presentation index, never a rewritten transcript.
class ConversationEntry {
  ConversationEntry({required this.id, required this.isUser, required List<String> messageIds})
      : messageIds = List.unmodifiable(messageIds);
  final String id;
  final bool isUser;
  final List<String> messageIds;
}

List<ConversationEntry> compactConversationEntries(
  List<String> ids,
  Map<String, ValueNotifier<ChatMessage>> messages,
) => _compactEntries(ids.map((id) => messages[id]?.value).whereType<ChatMessage>());

List<ConversationEntry> compactMessageEntries(List<ChatMessage> messages) => _compactEntries(messages);

List<ConversationEntry> _compactEntries(Iterable<ChatMessage> messages) {
  final entries = <ConversationEntry>[];
  var turn = <String>[];
  void flush() {
    if (turn.isEmpty) return;
    entries.add(ConversationEntry(id: turn.first, isUser: false, messageIds: turn));
    turn = <String>[];
  }
  for (final message in messages) {
    final id = message.id;
    if (message.role == 'user') {
      flush();
      entries.add(ConversationEntry(id: id, isUser: true, messageIds: [id]));
    } else {
      turn.add(id);
    }
  }
  flush();
  return entries;
}

enum CompactOperationState { recorded, pending, completed, error, unknown, limited, interrupted }

class CompactOperation {
  CompactOperation({required this.label, required this.state, required List<String> messageIds, this.kind = 'operation'})
      : messageIds = List.unmodifiable(messageIds);
  final String label, kind;
  final CompactOperationState state;
  final List<String> messageIds;
  String get stateLabel => switch (state) {
    CompactOperationState.recorded => 'Kaydedildi',
    CompactOperationState.pending => 'Sürüyor',
    CompactOperationState.completed => 'Tamamlandı',
    CompactOperationState.error => 'Hata',
    CompactOperationState.unknown => 'Sonuç kaydı yok',
    CompactOperationState.limited => 'Uzunluk sınırı',
    CompactOperationState.interrupted => 'Kesildi',
  };
}

/// Contains answer data only; operation payloads never enter the render model.
class CompactAnswerPart {
  const CompactAnswerPart({required this.messageId, required this.blockIndex, this.text, this.imageData, this.imageReference});
  final String messageId;
  final int blockIndex;
  final String? text, imageData, imageReference;
}

class CompactTurnProjection {
  CompactTurnProjection({required List<CompactAnswerPart> answers, required List<CompactOperation> operations})
      : answers = List.unmodifiable(answers), operations = List.unmodifiable(operations);
  final List<CompactAnswerPart> answers;
  final List<CompactOperation> operations;
  String get copyText => answers.map((part) => part.text).whereType<String>().join('\n\n');
}

String? _string(Object? value) => value is String ? value : null;
String _type(Json block) => _string(block['type']) ?? (block['text'] is String ? 'text' : 'unknown');
bool _toolCall(String type) => type == 'toolCall' || type == 'tool_use';
bool _toolResultRole(String role) => role == 'toolResult' || role == 'tool';
bool _reasoning(String type) => type == 'thinking' || type == 'reasoning' || type == 'redactedThinking' || type == 'redacted_thinking';

String? _phase(Json block) {
  final phase = block['phase'];
  if (phase == 'commentary' || phase == 'final_answer') return phase as String;
  final signature = block['textSignature'];
  if (signature is! String) return null;
  try {
    final value = jsonDecode(signature);
    if (value is Map && value['v'] == 1 && value['id'] is String &&
        (value['phase'] == 'commentary' || value['phase'] == 'final_answer')) {
      return value['phase'] as String;
    }
  } on FormatException {
    // Unknown signatures remain legacy text, not a guessed classification.
  }
  return null;
}

// Names/types are identifiers, never argument strings, commands or JSON.
final _identifierName = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_.:/-]{0,79}$');
String _safeName(Object? value, String fallback) => value is String &&
    _identifierName.hasMatch(value) ? value : fallback;

CompactTurnProjection projectCompactTurn(List<ChatMessage> messages, {bool active = false}) {
  final answers = <CompactAnswerPart>[];
  final operations = <CompactOperation>[];
  final results = <String, List<ChatMessage>>{};
  var previousWasReasoning = false;
  for (final message in messages) {
    if (_toolResultRole(message.role) && message.toolCallId != null) {
      results.putIfAbsent(message.toolCallId!, () => []).add(message);
    }
  }
  void add(String label, CompactOperationState state, List<String> ids, {String kind = 'operation'}) {
    // Only adjacent reasoning is coalesced; tool/answer boundaries stay ordered.
    if (kind == 'reasoning' && previousWasReasoning && operations.isNotEmpty) {
      final previous = operations.removeLast();
      operations.add(CompactOperation(label: label, state: state, messageIds: {...previous.messageIds, ...ids}.toList(), kind: kind));
    } else {
      operations.add(CompactOperation(label: label, state: state, messageIds: ids, kind: kind));
    }
    previousWasReasoning = kind == 'reasoning';
  }
  // Match before emitting so results arriving in a different order do not move calls.
  final calls = <String>{};
  for (final message in messages) {
    if (message.role != 'assistant') continue;
    for (final block in message.content) {
      if (_toolCall(_type(block))) {
        final id = _string(block['id']) ?? _string(block['toolCallId']);
        if (id != null) calls.add(id);
      }
    }
  }
  for (final message in messages) {
    if (_toolResultRole(message.role)) {
      if (message.toolCallId != null && calls.contains(message.toolCallId)) {
        previousWasReasoning = false;
        continue;
      }
      add('Araç · ${_safeName(message.toolName, 'Araç sonucu')}',
          message.isError ? CompactOperationState.error : CompactOperationState.completed, [message.id], kind: 'tool');
      continue;
    }
    if (message.role != 'assistant' && message.role != 'user') {
      add('Kayıt · ${_safeName(message.role, 'Diğer')}',
          message.isError ? CompactOperationState.error : CompactOperationState.recorded, [message.id]);
      continue;
    }
    final progress = message.role == 'assistant' &&
        (message.stopReason == 'toolUse' || message.content.any((block) => _toolCall(_type(block))));
    for (var index = 0; index < message.content.length; index++) {
      final block = message.content[index];
      final type = _type(block);
      final phase = _phase(block);
      if (_reasoning(type)) {
        add('Düşünme', CompactOperationState.recorded, [message.id], kind: 'reasoning');
        continue;
      }
      if (_toolCall(type)) {
        final callId = _string(block['id']) ?? _string(block['toolCallId']);
        final matches = callId == null ? <ChatMessage>[] : results[callId] ?? <ChatMessage>[];
        add('Araç · ${_safeName(block['name'], 'Araç çağrısı')}',
            matches.isEmpty ? (active ? CompactOperationState.pending : CompactOperationState.unknown)
                : matches.any((result) => result.isError) ? CompactOperationState.error : CompactOperationState.completed,
            [message.id, ...matches.map((result) => result.id)], kind: 'tool');
      } else if (type == 'text' || type == 'image') {
        if (message.role == 'assistant' && (phase == 'commentary' || (phase != 'final_answer' && progress))) {
          add('Çalışma güncellendi', CompactOperationState.recorded, [message.id], kind: 'commentary');
        } else if (type == 'text') {
          final text = _string(block['text']);
          if (text != null && text.trim().isNotEmpty) answers.add(CompactAnswerPart(messageId: message.id, blockIndex: index, text: text));
          previousWasReasoning = false;
        } else {
          final source = block['source'] is Map ? block['source'] as Map : const {};
          answers.add(CompactAnswerPart(messageId: message.id, blockIndex: index,
              imageData: _string(block['data']) ?? _string(source['data']),
              imageReference: _string(block['url']) ?? _string(source['url'])));
          previousWasReasoning = false;
        }
      } else {
        add('İçerik · ${_safeName(type, 'Diğer')}', block['isError'] == true ? CompactOperationState.error : CompactOperationState.recorded, [message.id]);
      }
    }
    final stop = message.stopReason;
    if (message.isError || stop == 'error') {
      add('Yanıt hatası', CompactOperationState.error, [message.id]);
    } else if (stop == 'aborted') {
      add('Yanıt kesildi', CompactOperationState.interrupted, [message.id]);
    } else if (stop == 'length') {
      add('Yanıt sınıra ulaştı', CompactOperationState.limited, [message.id]);
    } else if (message.content.isEmpty) {
      add('Mesaj kaydı', CompactOperationState.recorded, [message.id]);
    }
  }
  return CompactTurnProjection(answers: answers, operations: operations);
}

/// Source identity remains inspectable without retaining a hidden raw message UI.
class CompactSourceAnchor extends StatelessWidget {
  const CompactSourceAnchor({super.key, required this.messageIds, required this.child, this.focusedMessageId});
  final List<String> messageIds;
  final String? focusedMessageId;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    var result = child;
    for (final id in messageIds.reversed) {
      result = Semantics(key: ValueKey('compact-message:$id'), identifier: 'message:$id', container: true,
          explicitChildNodes: true, focused: id == focusedMessageId ? true : null, child: result);
    }
    return result;
  }
}

class CompactTurnView extends StatefulWidget {
  const CompactTurnView({super.key, required this.messages, this.active = false, this.focusedMessageId, this.preferAnswerFocus = false, this.onOpenFile, this.answerEndBuilder, this.onFocusPositioned});
  final List<ChatMessage> messages;
  final bool active;
  final String? focusedMessageId;
  final bool preferAnswerFocus;
  final void Function(String, int?)? onOpenFile;
  /// An anchor after the source's last rendered answer block, not its heading.
  final Widget Function(ChatMessage)? answerEndBuilder;
  final VoidCallback? onFocusPositioned;
  @override
  State<CompactTurnView> createState() => _CompactTurnViewState();
}

class _CompactTurnViewState extends State<CompactTurnView> {
  bool expanded = false;
  final focusedTarget = GlobalKey();
  String? positionedFocus;
  @override
  void didUpdateWidget(covariant CompactTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.active && !widget.active) || oldWidget.messages.firstOrNull?.id != widget.messages.firstOrNull?.id) expanded = false;
    if (oldWidget.preferAnswerFocus != widget.preferAnswerFocus) positionedFocus = null;
  }

  @override
  Widget build(BuildContext context) {
    final projection = projectCompactTurn(widget.messages, active: widget.active);
    final answerText = projection.copyText;
    final answerSources = projection.answers.map((part) => part.messageId).toSet().toList();
    final user = widget.messages.firstOrNull?.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final focused = widget.focusedMessageId;
    final focusedOperation = projection.operations.indexWhere((step) => step.messageIds.contains(focused));
    final focusedAnswer = projection.answers.indexWhere((part) => part.messageId == focused);
    final focusOperation = focusedOperation >= 0 && !(widget.preferAnswerFocus && focusedAnswer >= 0);
    if (focused == null) positionedFocus = null;
    if (focused != null && positionedFocus != focused && (focusedOperation >= 0 || focusedAnswer >= 0)) {
      positionedFocus = focused;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = focusedTarget.currentContext;
        if (mounted && widget.focusedMessageId == focused && target != null) {
          Scrollable.ensureVisible(target, alignment: .5, duration: Duration.zero);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && widget.focusedMessageId == focused) widget.onFocusPositioned?.call();
          });
        }
      });
    }
    final showAll = expanded || focusOperation;
    final operations = projection.operations;
    final firstVisible = showAll ? 0 : widget.active ? (operations.length - 3).clamp(0, operations.length).toInt() : operations.length;
    final problems = <String>[];
    for (final state in [CompactOperationState.error, CompactOperationState.unknown, CompactOperationState.limited, CompactOperationState.interrupted]) {
      final count = operations.where((step) => step.state == state).length;
      if (count > 0) {
        final label = operations.firstWhere((step) => step.state == state).stateLabel;
        problems.add('$count ${label.toLowerCase()}');
      }
    }
    return Padding(padding: EdgeInsets.fromLTRB(user ? 40 : 24, 16, 24, 8), child: NeoSurface(
      depth: user ? NeoDepth.raised : NeoDepth.flat, padding: EdgeInsets.all(user ? 16 : 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (operations.isNotEmpty) ...[
          NeoSurface(depth: NeoDepth.inset, radius: 16, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(expanded: showAll, child: InkWell(borderRadius: BorderRadius.circular(16),
              onTap: focusOperation ? null : () => setState(() => expanded = !expanded),
              child: Padding(padding: const EdgeInsets.fromLTRB(12, 4, 8, 4), child: Row(children: [
                Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('İşlem akışı · ${operations.length}', style: textTheme.labelLarge),
                  if (problems.isNotEmpty) Text(problems.join(' · '), style: textTheme.bodySmall?.copyWith(color: scheme.error)),
                ]))),
                SizedBox(width: 48, height: 48, child: Icon(showAll ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20)),
              ])))),
            if (firstVisible > 0 && firstVisible < operations.length)
              Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Text('$firstVisible önceki işlem', style: textTheme.bodySmall)),
            for (var index = firstVisible; index < operations.length; index++)
              _operation(context, operations[index], index + 1, focusKey: focusOperation && index == focusedOperation ? focusedTarget : null),
          ])),
          const SizedBox(height: 16),
        ],
        if (projection.answers.isNotEmpty) ...[
          Row(children: [Expanded(child: Text(user ? 'Sen' : 'OMP', style: textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant))),
            if (answerText.isNotEmpty) IconButton(tooltip: user ? 'Mesajı kopyala' : 'Yanıtı kopyala',
                onPressed: () => copyText(context, answerText), icon: const Icon(Icons.copy_rounded, size: 20)),
            PopupMenuButton<String>(tooltip: 'Yanıt kaynağının bağlantısını kopyala',
              icon: const Icon(Icons.link_rounded, size: 20),
              onSelected: (id) => copyText(context, 'omputer://message/${Uri.encodeComponent(id)}'),
              itemBuilder: (context) => [
                for (var index = 0; index < answerSources.length; index++)
                  PopupMenuItem(value: answerSources[index], child: Text('Yanıt kaynağı ${index + 1}')),
              ]),
          ]),
          for (var index = 0; index < projection.answers.length; index++)
            CompactSourceAnchor(key: !focusOperation && index == focusedAnswer ? focusedTarget : ValueKey('compact-answer:${projection.answers[index].messageId}:${projection.answers[index].blockIndex}'),
              messageIds: [projection.answers[index].messageId], focusedMessageId: focused,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(padding: const EdgeInsets.only(bottom: 8), child: projection.answers[index].text != null
                    ? _markdown(context, projection.answers[index].text!) : _image(projection.answers[index].imageData, projection.answers[index].imageReference)),
                if (widget.answerEndBuilder != null && !projection.answers.skip(index + 1).any((part) => part.messageId == projection.answers[index].messageId))
                  widget.answerEndBuilder!(widget.messages.firstWhere((message) => message.id == projection.answers[index].messageId)),
              ])),
        ] else if (widget.active && !user)
          Text('Yanıt hazırlanıyor', style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ])));
  }

  Widget _operation(BuildContext context, CompactOperation step, int number, {Key? focusKey}) {
    final focused = step.messageIds.contains(widget.focusedMessageId);
    final scheme = Theme.of(context).colorScheme;
    final attention = step.state == CompactOperationState.error || step.state == CompactOperationState.interrupted;
    return CompactSourceAnchor(key: focusKey, messageIds: step.messageIds, focusedMessageId: widget.focusedMessageId,
      child: Semantics(label: focused ? 'Seçili mesaj, işlem $number' : null,
        child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 32, child: Text('$number.', style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(step.label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: focused ? scheme.primary : scheme.onSurface)),
            Text(step.stateLabel, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: attention ? scheme.error : scheme.onSurfaceVariant)),
          ])),
        ]))));
  }

  Widget _markdown(BuildContext context, String text) => LocalMarkdown(
    data: text,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(p: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5)),
    onOpenFile: widget.onOpenFile,
  );

  Widget _image(String? data, String? reference) {
    if (data == null) return Text(reference == null ? 'Görsel baytları bu kayıtta bulunmuyor' : 'Görsel referansı: $reference');
    if (data.length > 3 * 1024 * 1024) return const Text('Görsel boyut sınırını aşıyor');
    try {
      return ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320, maxWidth: 640),
          child: Image.memory(base64Decode(data), cacheWidth: 640, fit: BoxFit.contain,
              semanticLabel: 'Konuşmaya eklenen görsel', errorBuilder: (context, error, stackTrace) => const Text('Görsel açılamadı')));
    } on FormatException {
      return const Text('Görsel verisi geçerli değil');
    }
  }
}
