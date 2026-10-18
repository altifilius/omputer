import 'package:flutter_test/flutter_test.dart';
import 'package:omputer/models.dart';

void main() {
  test('multi permits explicit zero choices while single requires one', () {
    final multi = QuestionAnswer({'id': 'q', 'multi': true, 'options': ['A']});
    expect(multi.valid, isTrue);
    expect(multi.toJson()['selectedOptions'], isEmpty);
    multi.selectCustom(true);
    expect(multi.valid, isFalse);
    multi.customInput = 'Specific answer';
    expect(multi.valid, isTrue);
    multi.selectCustom(false);
    expect(multi.valid, isTrue);
    final single = QuestionAnswer({'id': 'q', 'options': ['A']});
    expect(single.valid, isFalse);
    single.select('A', true);
    expect(single.valid, isTrue);
    single.select('A', false);
    expect(single.valid, isFalse);
  });

  test('failed live turn retains writer ownership and prompt controls', () {
    final session = Session.fromJson({
      'id': 'visible', 'transport': 'bridge', 'status': 'failed',
      'writerConnected': true, 'turnError': {'message': 'Provider rejected request'},
      'journalId': 'journal', 'providerSessionId': 'provider', 'bindingRevision': 'generation',
      'capabilities': ['session.prompt', 'session.control'],
    });
    expect(session.archived, isFalse);
    expect(session.canResume, isFalse);
    expect(session.canSendMessages, isTrue);
    expect(session.workState, 'turn_error');
    expect(session.isSettled, isFalse);
    expect(session.turnError, 'Provider rejected request');
    expect(session.journalId, 'journal');
    expect(session.providerSessionId, 'provider');
    expect(session.bindingRevision, 'generation');
    expect(session.lastError, isNull);
  });

  test('explicit writer disconnect outranks idle transport metadata', () {
    final session = Session.fromJson({'id': 's', 'transport': 'bridge', 'status': 'idle', 'writerConnected': false, 'workState': 'settled', 'capabilities': ['session.prompt']});
    expect(session.canSendMessages, isFalse);
    expect(session.workState, 'disconnected');
    expect(session.isSettled, isFalse);
  });

  test('idle agent turn with queued or background work is not settled', () {
    final queued = Session.fromJson({'id': 's', 'transport': 'bridge', 'status': 'idle', 'writerConnected': true, 'queuedMessages': [{'id': 'q', 'text': 'Next'}]});
    expect(queued.workState, 'queued');
    expect(queued.isSettled, isFalse);
    final background = Session.fromJson({'id': 's', 'transport': 'bridge', 'status': 'idle', 'writerConnected': true, 'asyncJobs': [{'id': 'job', 'status': 'running'}], 'todos': [{'id': 'todo', 'status': 'pending'}], 'contextUsage': {'tokens': 3500, 'percent': 12.5}});
    expect(background.hasPendingAsyncWork, isTrue);
    expect(background.workState, 'background');
    expect(background.isSettled, isFalse);
    expect(background.todos.single['status'], 'pending');
    expect(background.contextUsage['percent'], 12.5);
    final settled = Session.fromJson({'id': 's', 'transport': 'bridge', 'status': 'idle', 'writerConnected': true, 'todos': [{'status': 'pending'}]});
    expect(settled.isSettled, isTrue, reason: 'Unfinished project todos do not imply a running agent turn');
  });

  test('archive identity never aliases provider session id to journal id', () {
    final session = Session.fromJson({'id': 's', 'providerSessionId': 'provider', 'runtimeSessionId': 'ambiguous-legacy', 'status': 'inactive', 'capabilities': ['session.resume']});
    expect(session.journalId, isNull);
    expect(session.providerSessionId, 'provider');
    expect(session.archived, isTrue);
    expect(session.canResume, isTrue);
    expect(session.canSendMessages, isFalse);
  });

  test('tool error, accounting and stop metadata survive message accumulation', () {
    final message = ChatMessage.fromJson({'id': 'm', 'role': 'toolResult', 'toolCallId': 'call', 'toolName': 'bash', 'isError': true, 'usage': {'input': 19, 'output': 7}, 'stopReason': 'error', 'content': 'Permission denied', 'sequence': 8, 'revision': 10});
    expect(message.toolCallId, 'call');
    expect(message.toolName, 'bash');
    expect(message.isError, isTrue);
    expect(message.usage, {'input': 19, 'output': 7});
    expect(message.stopReason, 'error');
    expect(message.content.single['text'], 'Permission denied');
    expect(message.revision, 10);
  });

  test('legacy project memory revision migrates to zero', () {
    expect(Project.fromJson({'id': 'project'}).memoryRevision, 0);
    expect(Project.fromJson({'id': 'project', 'memoryRevision': 7}).memoryRevision, 7);
  });
}
