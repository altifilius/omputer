import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer, type Socket } from 'node:net';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ExtensionAskDialogSubmitResult, ExtensionUIContext } from '@oh-my-pi/pi-coding-agent';
import omputer from './index';
import { LocalBridge } from './ipc';
import type { HostControls } from './controls';
import { encodeFrame, type WireFrame } from './wire';

const source = process.env.OMPUTER_OMP_SOURCE ?? join(homedir(), '.local/share/omputer-tools/omp');
const [{ ExtensionRuntime, loadExtensionFromFactory }, { ExtensionRunner }, { SessionManager }, { EventBus }] = await Promise.all([
  import(join(source, 'packages/coding-agent/src/extensibility/extensions/loader.ts')),
  import(join(source, 'packages/coding-agent/src/extensibility/extensions/runner.ts')),
  import(join(source, 'packages/coding-agent/src/session/session-manager.ts')),
  import(join(source, 'packages/coding-agent/src/utils/event-bus.ts')),
]);
const FRAME_BYTES = 1024 * 1024;
const LOGICAL_BYTES = 64 * FRAME_BYTES;
const largeText = () => 'ş🦀'.repeat(3 * FRAME_BYTES);

type Received = { frame: WireFrame; socket: Socket; physicalBytes: number };
async function socketHarness() {
  const directory = await mkdtemp(join(tmpdir(), 'omputer-bridge-transport-'));
  const frames: Received[] = [];
  const sockets = new Set<Socket>();
  const waiters = new Set<() => void>();
  const physical: { type: unknown; size: number; socket: Socket }[] = [];
  const failure = Promise.withResolvers<never>();
  void failure.promise.catch(() => {});
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    let buffer = Buffer.alloc(0);
    let pending: { id: unknown; count: number; length: number; parts: Buffer[] } | undefined;
    socket.on('data', chunk => {
      try {
        buffer = Buffer.concat([buffer, chunk]);
        let newline: number;
        while ((newline = buffer.indexOf(10)) >= 0) {
          const line = buffer.subarray(0, newline);
          buffer = buffer.subarray(newline + 1);
          expect(line.length + 1).toBeLessThanOrEqual(FRAME_BYTES);
          let frame = JSON.parse(line.toString('utf8')) as WireFrame;
          physical.push({ type: frame.type, size: line.length + 1, socket });
          if (frame.type === 'rpc_chunk') {
            const part = Buffer.from(frame.data as string, 'base64');
            expect(part.length).toBeLessThanOrEqual(256 * 1024);
            pending ??= { id: frame.chunkId, count: frame.count as number, length: frame.byteLength as number, parts: [] };
            expect(frame.chunkId).toBe(pending.id);
            expect(frame.index).toBe(pending.parts.length);
            expect(frame.count).toBe(pending.count);
            expect(frame.byteLength).toBe(pending.length);
            pending.parts.push(part);
            if (pending.parts.length < pending.count) continue;
            const bytes = Buffer.concat(pending.parts);
            expect(bytes.length).toBe(pending.length);
            expect(bytes.length).toBeLessThanOrEqual(LOGICAL_BYTES);
            frame = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
            pending = undefined;
          } else expect(pending).toBeUndefined();
          frames.push({ frame, socket, physicalBytes: line.length + 1 });
          if (frame.type === 'register') socket.write(JSON.stringify({ type: 'registered', sessionId: 'visible-session', bindingRevision: 'test-binding' }) + '\n');
          for (const waiter of [...waiters]) waiter();
        }
      } catch (error) { failure.reject(error); }
    });
  });
  await chmod(directory, 0o700);
  await writeFile(join(directory, 'bridge.token'), 'isolated-test-token', { mode: 0o600 });
  const listening = Promise.withResolvers<void>();
  server.once('error', listening.reject);
  server.listen(join(directory, 'bridge.sock'), listening.resolve);
  await listening.promise;
  await chmod(join(directory, 'bridge.sock'), 0o600);
  const received = (predicate: (entry: Received) => boolean, after = 0) => {
    const result = Promise.withResolvers<Received>();
    // Real Unix I/O uses an event-driven wait; this platform-clock timer only bounds failures.
    const deadline = setTimeout(() => result.reject(new Error(`Missing bridge frame: ${predicate}; types=${frames.slice(after).map(entry => entry.frame.type)}`)), 12_000);
    const check = () => {
      const match = frames.slice(after).find(predicate);
      if (match) result.resolve(match);
    };
    waiters.add(check); check();
    return Promise.race([result.promise, failure.promise]).finally(() => { clearTimeout(deadline); waiters.delete(check); });
  };
  return { directory, frames, sockets, physical, received, async close() {
    for (const socket of sockets) socket.destroy();
    const closed = Promise.withResolvers<void>();
    server.close(() => closed.resolve());
    await closed.promise;
    await rm(directory, { recursive: true, force: true });
  } };
}

async function controlHarness(history: WireFrame[]) {
  const ipc = await socketHarness();
  const previous = process.env.OMPUTER_STATE_DIR;
  const previousManaged = process.env.OMPUTER_RPC_MANAGED;
  process.env.OMPUTER_STATE_DIR = ipc.directory;
  delete process.env.OMPUTER_RPC_MANAGED;
  const manager = SessionManager.inMemory(ipc.directory);
  let leaf = 'original-leaf';
  let executions = 0;
  let transcriptReads = 0;
  let forward: ((event: WireFrame) => void) | undefined;
  const host: HostControls = {
    catalog: async () => ({ catalogRevision: 'catalog', commands: [{ id: 'builtin:context', available: true }] }),
    query: async () => ({ alive: true }),
    execute: async (_action, payload) => {
      executions++;
      if (payload.control || payload.commandId === 'extension:branch') leaf = `next-${executions}`;
      return { consumed: true };
    },
  };
  const live = {
    sessionManager: manager, sessionId: 'provider', isStreaming: false, isCompacting: false, queuedMessageCount: 0,
    hasPendingAsyncWork: () => false, getQueuedMessages: () => ({ steering: [], followUp: [], liveSteered: 0 }),
    getTodoPhases: () => [], subscribe: (listener: (event: WireFrame) => void) => { forward = listener; return () => { forward = undefined; }; }, enableOmputerMessageIds: () => {},
    getOmputerMessages: () => { transcriptReads++; return history; },
  };
  const registry = { get: () => ({ session: live }), list: () => [], onChange: () => () => {} };
  const runtime = new ExtensionRuntime();
  const extension = await loadExtensionFromFactory(api => omputer(Object.assign(Object.create(api), {
    pi: { ...api.pi, AgentRegistry: { global: () => registry }, OmputerControls: { version: 1, create: () => host } },
  })), ipc.directory, new EventBus(), runtime, 'omputer-control-transport-regression');
  const originalLeaf = manager.getLeafId.bind(manager);
  manager.getLeafId = () => leaf;
  const runner = new ExtensionRunner([extension], runtime, ipc.directory, manager, { getAvailable: () => [] } as never);
  const local: { signal?: AbortSignal }[] = [];
  const ui: ExtensionUIContext = Object.create(runner.getUIContext());
  ui.askDialog = (_questions, options) => {
    const result = Promise.withResolvers<ExtensionAskDialogSubmitResult | undefined>();
    local.push({ signal: options?.signal });
    options?.signal?.addEventListener('abort', () => result.resolve(undefined), { once: true });
    return result.promise;
  };
  runner.initialize({
    sendMessage: () => {}, sendUserMessage: () => {}, appendEntry: () => {}, setLabel: () => {},
    getActiveTools: () => [], getAllTools: () => [], setActiveTools: async () => {}, getCommands: () => [],
    setModel: async () => false, getThinkingLevel: () => undefined, setThinkingLevel: () => {},
    getSessionName: () => undefined, setSessionName: async () => {},
  }, {
    getModel: () => undefined, isIdle: () => true, abort: () => {}, hasPendingMessages: () => false,
    shutdown: () => {}, getContextUsage: () => undefined, compact: async () => {}, getSystemPrompt: () => [],
  }, undefined, ui, 'tui');
  await runner.emit({ type: 'session_start' });
  const ready = await ipc.received(entry => entry.frame.type === 'state');
  const command = (payload: WireFrame, action = 'session.command') => ({
    type: 'command', id: randomUUID(), operationId: randomUUID(), action,
    payload: { expectedJournalId: manager.getSessionId(), expectedBindingRevision: 'test-binding', ...payload },
  });
  return { ...ipc, ready, command, host, runner, manager, ui, local, forward: (event: WireFrame) => forward?.(event), executions: () => executions, transcriptReads: () => transcriptReads,
    async close() {
      manager.getLeafId = originalLeaf;
      await runner.emit({ type: 'session_shutdown' }); runner.clearManagedTimers();
      if (previous === undefined) delete process.env.OMPUTER_STATE_DIR; else process.env.OMPUTER_STATE_DIR = previous;
      if (previousManaged === undefined) delete process.env.OMPUTER_RPC_MANAGED; else process.env.OMPUTER_RPC_MANAGED = previousManaged;
      await ipc.close();
    },
  };
}

test('command-triggered branch cancels old dialogs and installs one fresh binding', async () => {
  const harness = await controlHarness([]);
  try {
    const questions = [{ id: 'color', question: 'Renk?', options: [{ label: 'Mavi' }] }];
    const answer = { kind: 'submit', results: [{ id: 'color', selectedOptions: ['Mavi'] }] };
    const old = harness.ui.askDialog!(questions);
    const request = await harness.received(entry => entry.frame.type === 'interaction');
    const oldId = (request.frame.request as WireFrame).id;
    const execute = harness.host.execute;
    harness.host.execute = async (...args) => {
      const result = await execute(...args);
      await harness.manager.newSession();
      await harness.runner.emit({ type: 'session_branch', reason: 'branch' });
      return result;
    };
    const command = harness.command({ control: 'branch', arguments: {} }, 'session.control');
    harness.ready.socket.write(JSON.stringify(command) + '\n');
    const response = await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === command.id);
    expect(response.frame.success).toBe(true);
    expect(harness.local[0].signal?.aborted).toBe(true);
    expect(await old).toBeUndefined();
    expect(harness.frames.filter(entry => entry.frame.type === 'interaction_end' && entry.frame.id === oldId).map(entry => entry.frame)).toEqual([
      { type: 'interaction_end', sessionId: request.frame.sessionId, id: oldId, status: 'cancelled' },
    ]);
    const stale = harness.command({ interactionId: oldId, answer }, 'interaction.respond');
    harness.ready.socket.write(JSON.stringify(stale) + '\n');
    expect((await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === stale.id)).frame).toMatchObject({
      success: false, error: { code: 'stale_interaction' },
    });
    const offset = harness.frames.length;
    const next = harness.ui.askDialog!(questions);
    const fresh = await harness.received(entry => entry.frame.type === 'interaction', offset);
    const newId = (fresh.frame.request as WireFrame).id;
    expect(newId).not.toBe(oldId);
    const submit = harness.command({ interactionId: newId, answer }, 'interaction.respond');
    harness.ready.socket.write(JSON.stringify(submit) + '\n');
    expect((await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === submit.id)).frame.success).toBe(true);
    expect(await next).toMatchObject({ kind: 'submit', results: [{ selectedOptions: ['Mavi'] }] });
    expect(harness.frames.slice(offset).filter(entry => entry.frame.type === 'interaction')).toHaveLength(1);
    expect(harness.local).toHaveLength(2);
  } finally { await harness.close(); }
}, 20_000);

test('session switch does not inherit the previous journal turn error', async () => {
  const harness = await controlHarness([]);
  try {
    harness.forward({ type: 'message_end', message: { role: 'assistant', stopReason: 'error', errorMessage: 'Old journal failure' } });
    await harness.received(entry => entry.frame.type === 'state' && (entry.frame.session as WireFrame).turnError === 'Old journal failure');
    await harness.manager.newSession();
    const offset = harness.frames.length;
    await harness.runner.emit({ type: 'session_switch', reason: 'new' });
    const registration = await harness.received(entry => entry.frame.type === 'register', offset);
    const current = await harness.received(entry => entry.socket === registration.socket && entry.frame.type === 'state', offset);
    expect(current.frame.session).toMatchObject({ journalId: harness.manager.getSessionId(), turnError: null, workState: 'settled' });
  } finally { await harness.close(); }
}, 20_000);

test('real bridge benign slash command and catalog omit oversized conversation without disconnecting', async () => {
  const harness = await controlHarness([{ role: 'user', content: largeText(), _entryId: 'huge-history' }]);
  try {
    const catalog = harness.command({ view: 'commands', arguments: {} }, 'session.controls');
    harness.ready.socket.write(JSON.stringify(catalog) + '\n');
    const listing = await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === catalog.id);
    expect(listing.frame.success).toBe(true);
    const command = harness.command({ commandId: 'builtin:context', args: '', catalogRevision: 'catalog' });
    harness.ready.socket.write(JSON.stringify(command) + '\n');
    const response = await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === command.id);
    expect(response.frame).toMatchObject({ success: true, data: { consumed: true } });
    expect((response.frame.data as WireFrame)._omputerMessages).toBeUndefined();
    expect(harness.transcriptReads()).toBe(0);
    expect(harness.executions()).toBe(1);
    const barrier = harness.command({ view: 'state', arguments: {} }, 'session.controls');
    harness.ready.socket.write(JSON.stringify(barrier) + '\n');
    await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === barrier.id);
    expect(harness.frames.filter(entry => entry.frame.type === 'register')).toHaveLength(1);
  } finally { await harness.close(); }
}, 20_000);

test.each(['branch', 'fork', 'tree.navigate', 'extension-command'])('real bridge %s preserves large UTF8 history and cached reconnect completion without reexecution', async control => {
  const history = [{ role: 'user', content: largeText(), _entryId: 'full-utf8-history' }];
  const harness = await controlHarness(history);
  try {
    const command = control === 'extension-command'
      ? harness.command({ commandId: 'extension:branch', args: '' })
      : harness.command({ control, arguments: { entryId: 'entry' } }, 'session.control');
    harness.ready.socket.write(JSON.stringify(command) + '\n');
    const response = await harness.received(entry => entry.frame.type === 'response' && entry.frame.id === command.id);
    expect(response.frame).toMatchObject({ success: true, data: { _omputerState: { leafId: 'next-1' } } });
    expect((response.frame.data as WireFrame)._omputerMessages).toEqual(history);
    expect(harness.physical.some(frame => frame.type === 'rpc_chunk')).toBe(true);
    expect(harness.executions()).toBe(1);
    const offset = harness.frames.length;
    harness.ready.socket.destroy();
    const registration = await harness.received(entry => entry.frame.type === 'register', offset);
    const replay = await harness.received(entry => entry.socket === registration.socket && entry.frame.type === 'response' && entry.frame.id === command.id, offset);
    expect(replay.frame).toEqual(response.frame);
    const duplicateOffset = harness.frames.length;
    registration.socket.write(JSON.stringify(command) + '\n');
    const duplicate = await harness.received(entry => entry.socket === registration.socket && entry.frame.type === 'response' && entry.frame.id === command.id, duplicateOffset);
    expect(duplicate.frame).toEqual(response.frame);
    expect(harness.executions()).toBe(1);
    const barrier = harness.command({ view: 'state', arguments: {} }, 'session.controls');
    registration.socket.write(JSON.stringify(barrier) + '\n');
    await harness.received(entry => entry.frame.id === barrier.id && entry.frame.type === 'response');
    expect(harness.frames.filter(entry => entry.frame.type === 'register')).toHaveLength(2);
  } finally { await harness.close(); }
}, 30_000);

test('real bridge oversized single outcome is correlated and cacheable without reconnect poison', async () => {
  const harness = await controlHarness([{ role: 'user', content: 'x'.repeat(LOGICAL_BYTES + 1), _entryId: 'too-large' }]);
  try {
    const command = harness.command({ control: 'branch', arguments: {} }, 'session.control');
    harness.ready.socket.write(JSON.stringify(command) + '\n');
    const response = await harness.received(entry => entry.frame.id === command.id && entry.frame.type === 'response');
    expect(response.frame).toMatchObject({ success: false, error: { code: 'outcome_unknown' } });
    expect((response.frame.error as WireFrame).message).toContain('64 MiB');
    const offset = harness.frames.length;
    harness.ready.socket.write(JSON.stringify(command) + '\n');
    expect((await harness.received(entry => entry.frame.id === command.id && entry.frame.type === 'response', offset)).frame).toEqual(response.frame);
    expect(harness.executions()).toBe(1);
    expect(harness.frames.filter(entry => entry.frame.type === 'register')).toHaveLength(1);
  } finally { await harness.close(); }
}, 20_000);

test('LocalBridge bounds queued bytes without disconnect and stops a blocked chunk writer', async () => {
  const harness = await socketHarness();
  const connected = Promise.withResolvers<void>();
  const errors: unknown[] = [];
  const bridge = new LocalBridge(harness.directory, () => ({ session: { id: 'queue-session' } }), () => {}, connected.resolve, () => {}, error => errors.push(error));
  try {
    bridge.start(); await connected.promise;
    const registration = await harness.received(entry => entry.frame.type === 'register');
    registration.socket.pause();
    const frame = { type: 'event', data: largeText() };
    expect(bridge.send(frame)).toBe(true);
    expect(bridge.send(frame)).toBe(true);
    expect(bridge.send(frame)).toBe(true);
    expect(bridge.send(frame)).toBe(false);
    expect(bridge.ready).toBe(true);
    const waiting = bridge.sendEncoded(encodeFrame(frame));
    bridge.stop();
    expect(bridge.ready).toBe(false);
    expect(await waiting).toBe(false);
    expect(bridge.send(frame)).toBe(false);
    const restarted = Promise.withResolvers<void>();
    const replay = new LocalBridge(harness.directory, () => ({ session: { id: 'question-session' } }), () => {}, restarted.resolve, () => {}, error => errors.push(error));
    try {
      const offset = harness.frames.length;
      replay.start(); await restarted.promise;
      const socket = (await harness.received(entry => entry.frame.type === 'register' && entry.frame.session != null, offset)).socket;
      socket.pause();
      expect(replay.send(frame)).toBe(true);
      expect(replay.send(frame)).toBe(true);
      expect(replay.send(frame)).toBe(true);
      expect(replay.send({ type: 'interaction', request: { id: 'pending', method: 'input', title: 'Question' } })).toBe(true);
      expect(replay.send(frame)).toBe(false);
      // Fill the remaining physical queue with bounded non-droppable lifecycle frames.
      let queued = true;
      for (let index = 0; index < 1100 && queued; index++) queued = replay.send({ type: 'interaction_end', id: `question-${index}`, status: 'resolved' });
      expect(queued).toBe(false);
      const registration = await harness.received(entry => entry.frame.type === 'register', harness.frames.length);
      expect(registration.socket).not.toBe(socket);
    } finally { replay.stop(); }
  } finally { bridge.stop(); await harness.close(); }
}, 20_000);

test('real bridge interrupted history write replays the same complete outcome after reconnect', async () => {
  const history = [{ role: 'user', content: largeText(), _entryId: 'interrupted-history' }];
  const harness = await controlHarness(history);
  try {
    const command = harness.command({ control: 'branch', arguments: { entryId: 'entry' } }, 'session.control');
    const interrupted = Promise.withResolvers<void>();
    harness.ready.socket.once('data', () => { harness.ready.socket.destroy(); interrupted.resolve(); });
    const offset = harness.frames.length;
    harness.ready.socket.write(JSON.stringify(command) + '\n');
    await interrupted.promise;
    const registration = await harness.received(entry => entry.frame.type === 'register', offset);
    const response = await harness.received(entry => entry.socket === registration.socket && entry.frame.type === 'response' && entry.frame.id === command.id, offset);
    expect(response.frame.success).toBe(true);
    expect((response.frame.data as WireFrame)._omputerMessages).toEqual(history);
    expect(harness.executions()).toBe(1);
    expect(harness.frames.filter(entry => entry.frame.type === 'register')).toHaveLength(2);
  } finally { await harness.close(); }
}, 20_000);
