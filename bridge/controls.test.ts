import { expect, test } from 'bun:test';
import { runControl, type HostControls } from './controls';
import { parseCommand, type Command, type WireFrame } from './wire';

const identity = { journalId: 'journal', bindingRevision: 'binding' };
function command(payload: Record<string, unknown> = {}): Command {
  return { type: 'command', id: 'transport-request', operationId: 'durable-operation', action: 'session.control',
    payload: { expectedJournalId: identity.journalId, expectedBindingRevision: identity.bindingRevision, ...payload } };
}
function adapter(execute: HostControls['execute']): HostControls {
  return { catalog: async () => ({ catalogRevision: 'catalog', commands: [] }), query: async () => ({ value: 1 }), execute };
}

test('stale bridge generation rejects before executing a real host effect boundary', async () => {
  let calls = 0;
  const host = adapter(async () => { calls++; return { changed: true }; });
  await expect(runControl(host, command({ expectedBindingRevision: 'old-binding' }), identity, () => {})).rejects.toMatchObject({ code: 'stale_identity' });
  expect(calls).toBe(0);
  expect(await runControl(host, command(), identity, () => {})).toEqual({ changed: true });
  expect(calls).toBe(1);
});

test('operation output remains explicitly correlated across delayed host completion', async () => {
  const admitted = Promise.withResolvers<void>();
  const complete = Promise.withResolvers<Record<string, unknown>>();
  const events: WireFrame[] = [];
  const host = adapter(async (_action, _payload, operationId, emit) => {
    emit({ type: 'operation_output', operationId, kind: 'command', text: 'started' });
    admitted.resolve();
    const result = await complete.promise;
    emit({ type: 'operation_output', operationId, kind: 'command', text: 'finished' });
    return result;
  });
  const result = runControl(host, command(), identity, event => events.push(event));
  await admitted.promise;
  expect(events.map(event => event.operationId)).toEqual(['durable-operation']);
  complete.resolve({ actualResult: true });
  expect(await result).toEqual({ actualResult: true });
  expect(events.map(event => event.operationId)).toEqual(['durable-operation', 'durable-operation']);
});

test('uncorrelated host output and host failures are not reported as success', async () => {
  const host = adapter(async (_action, _payload, _operationId, emit) => {
    emit({ type: 'operation_output', operationId: 'other-operation', kind: 'command', text: 'wrong' });
    return { changed: true };
  });
  await expect(runControl(host, command(), identity, () => {})).rejects.toMatchObject({ code: 'invalid_output' });
  const rejected = adapter(async () => { throw Object.assign(new Error('Actual host rejection'), { code: 'stale_entry' }); });
  await expect(runControl(rejected, command(), identity, () => {})).rejects.toMatchObject({ code: 'stale_entry' });
});

test('catalog uses actual adapter availability and current binding without executing commands', async () => {
  let calls = 0;
  const host = adapter(async () => { calls++; return {}; });
  const query = { ...command(), action: 'session.controls', payload: { view: 'commands', arguments: {} } };
  expect(await runControl(host, query, identity, () => {})).toEqual({ catalogRevision: 'catalog', commands: [], ...identity });
  expect(calls).toBe(0);
  await expect(runControl(undefined, query, identity, () => {})).rejects.toMatchObject({ code: 'unsupported' });
  expect(() => parseCommand({ ...command(), operationId: 123 })).toThrow('Malformed operation identity');
});
