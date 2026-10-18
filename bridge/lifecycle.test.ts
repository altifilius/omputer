import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer, type Socket } from 'node:net';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ExtensionAskDialogSubmitResult, ExtensionUIContext } from '@oh-my-pi/pi-coding-agent';
import omputer from './index';
import type { WireFrame } from './wire';

// Use the opt-in supported OMP source, including its real handler-scoped UI proxy.
const source = process.env.OMPUTER_OMP_SOURCE ?? join(homedir(), '.local/share/omputer-tools/omp');
const [{ ExtensionRuntime, loadExtensionFromFactory }, { ExtensionRunner }, { SessionManager }, { EventBus }, { registerLogSink }] = await Promise.all([
  import(join(source, 'packages/coding-agent/src/extensibility/extensions/loader.ts')),
  import(join(source, 'packages/coding-agent/src/extensibility/extensions/runner.ts')),
  import(join(source, 'packages/coding-agent/src/session/session-manager.ts')),
  import(join(source, 'packages/coding-agent/src/utils/event-bus.ts')),
  import(join(source, 'packages/utils/src/logger.ts')),
]);

test('actual OMP session switch and branch leave exactly one answerable DialogBridge', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'omputer-dialog-lifecycle-'));
  const previousStateDir = process.env.OMPUTER_STATE_DIR;
  const previousManaged = process.env.OMPUTER_RPC_MANAGED;
  process.env.OMPUTER_STATE_DIR = directory;
  delete process.env.OMPUTER_RPC_MANAGED;
  const frames: { frame: WireFrame; socket: Socket }[] = [];
  const sockets = new Set<Socket>();
  const waiters = new Set<() => void>();
  const failure = Promise.withResolvers<never>();
  void failure.promise.catch(() => {});
  const removeLogSink = registerLogSink(event => {
    if (event.message === 'Omputer local bridge unavailable') {
      failure.reject(new Error(`Bridge setup failed: ${JSON.stringify(event.context)}`));
    }
  });
  const received = (predicate: (entry: { frame: WireFrame; socket: Socket }) => boolean, after = 0) => {
    const result = Promise.withResolvers<{ frame: WireFrame; socket: Socket }>();
    // This is a failure deadline for real Unix IPC, never a synchronization sleep.
    const deadline = AbortSignal.timeout(3000);
    const expired = () => result.reject(new Error(`Missing frame ${predicate.toString()}; observed ${JSON.stringify(frames.map(entry => entry.frame))}`));
    deadline.addEventListener('abort', expired, { once: true });
    const check = () => {
      const match = frames.slice(after).find(predicate);
      if (match) { waiters.delete(check); result.resolve(match); }
    };
    waiters.add(check);
    check();
    return Promise.race([result.promise, failure.promise]).finally(() => {
      deadline.removeEventListener('abort', expired);
      waiters.delete(check);
    });
  };
  const server = createServer(socket => {
    sockets.add(socket);
    socket.setEncoding('utf8');
    socket.on('close', () => sockets.delete(socket));
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const frame = JSON.parse(buffer.slice(0, newline)) as WireFrame;
        buffer = buffer.slice(newline + 1);
        frames.push({ frame, socket });
        if (frame.type === 'register') socket.write(JSON.stringify({ type: 'registered', sessionId: (frame.session as WireFrame).id }) + '\n');
        for (const waiter of [...waiters]) waiter();
      }
    });
  });
  let runner: InstanceType<typeof ExtensionRunner> | undefined;
  try {
    await chmod(directory, 0o700);
    await writeFile(join(directory, 'bridge.token'), 'isolated-test-token', { mode: 0o600 });
    const listening = Promise.withResolvers<void>();
    server.once('error', listening.reject);
    server.listen(join(directory, 'bridge.sock'), listening.resolve);
    await listening.promise;
    await chmod(join(directory, 'bridge.sock'), 0o600);
    const runtime = new ExtensionRuntime();
    const extension = await loadExtensionFromFactory(omputer, directory, new EventBus(), runtime, 'omputer-lifecycle-regression');
    const manager = SessionManager.inMemory(directory);
    // No provider/model is involved: the real runner only queries this facade for state.
    const models = { getAvailable: () => [] };
    runner = new ExtensionRunner([extension], runtime, directory, manager, models as never);
    const errors: unknown[] = [];
    runner.onError(error => {
      errors.push(error);
      failure.reject(new Error(`OMP handler failed: ${JSON.stringify(error)}`));
    });
    const local: { resolve: (value: ExtensionAskDialogSubmitResult | undefined) => void; signal?: AbortSignal }[] = [];
    const notifications: string[] = [];
    const base = runner.getUIContext();
    const ui: ExtensionUIContext = Object.create(base);
    ui.askDialog = (_questions, options) => {
      const result = Promise.withResolvers<ExtensionAskDialogSubmitResult | undefined>();
      local.push({ resolve: result.resolve, signal: options?.signal });
      options?.signal?.addEventListener('abort', () => result.resolve(undefined), { once: true });
      return result.promise;
    };
    ui.notify = message => { notifications.push(message); };
    const originalAsk = Object.getOwnPropertyDescriptor(ui, 'askDialog');
    const originalNotify = Object.getOwnPropertyDescriptor(ui, 'notify');
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
    await received(entry => entry.frame.type === 'state');
    const questions = [{ id: 'color', question: 'Renk?', options: [{ label: 'Mavi' }] }];
    const answer = { kind: 'submit', results: [{ id: 'color', selectedOptions: ['Mavi'] }] };
    for (const event of [{ type: 'session_switch', reason: 'new' }, { type: 'session_branch', reason: 'branch' }] as const) {
      const oldSession = manager.getSessionId();
      const localStart = local.length;
      const cancelledOffset = frames.length;
      const cancelled = ui.askDialog(questions);
      await Promise.resolve();
      const previousSignal = local.at(-1)?.signal;
      const cancelledFrame = await received(entry => entry.frame.type === 'interaction', cancelledOffset);
      await manager.newSession();
      const offset = frames.length;
      await runner.emit(event as never);
      expect(await cancelled).toBeUndefined();
      expect(previousSignal?.aborted).toBe(true);
      const ended = await received(entry => entry.frame.type === 'interaction_end' && entry.frame.id === (cancelledFrame.frame.request as WireFrame).id, cancelledOffset);
      expect(ended.frame.sessionId).toBe(oldSession);
      const registration = await received(entry => entry.frame.type === 'register' &&
        (entry.frame.session as WireFrame).id === manager.getSessionId(), offset);
      // Cancelling the old dialog can emit state before that old socket is stopped.
      const current = await received(entry => entry.socket === registration.socket && entry.frame.type === 'state' &&
        (entry.frame.session as WireFrame).id === manager.getSessionId(), offset);
      expect(manager.getSessionId()).not.toBe(oldSession);
      const singleStart = frames.length;
      const single = ui.askDialog(questions);
      const singleFrame = await received(entry => entry.frame.type === 'interaction', singleStart);
      ui.notify('Single barrier');
      await received(entry => entry.frame.type === 'event' && (entry.frame.event as WireFrame).message === 'Single barrier', singleStart);
      expect(frames.slice(singleStart).filter(entry => entry.frame.type === 'interaction')).toHaveLength(1);
      const singleId = (singleFrame.frame.request as WireFrame).id;
      const singleCommandId = randomUUID();
      current.socket.write(JSON.stringify({ type: 'command', id: singleCommandId, action: 'interaction.respond', payload: { interactionId: singleId, answer } }) + '\n');
      const singleResponse = await received(entry => entry.frame.type === 'response' && entry.frame.id === singleCommandId, singleStart);
      expect(singleResponse.frame).toMatchObject({ success: true, data: { interactionId: singleId, status: 'resolved' } });
      expect(await single).toMatchObject({ kind: 'submit', results: [{ selectedOptions: ['Mavi'] }] });
      const start = frames.length;
      const first = ui.askDialog(questions);
      const second = ui.askDialog(questions);
      const firstFrame = await received(entry => entry.frame.type === 'interaction', start);
      const secondFrame = await received(entry => entry.frame.type === 'interaction' && (entry.frame.request as WireFrame).id !== (firstFrame.frame.request as WireFrame).id, start);
      // Barrier: desktop invocation is a microtask, and all interaction writes precede this notification.
      ui.notify('Barrier');
      await received(entry => entry.frame.type === 'event' && (entry.frame.event as WireFrame).type === 'notification', start);
      const requests = frames.slice(start).filter(entry => entry.frame.type === 'interaction');
      expect(requests).toHaveLength(2);
      expect(local).toHaveLength(localStart + 4);
      const firstId = (firstFrame.frame.request as WireFrame).id;
      const secondId = (secondFrame.frame.request as WireFrame).id;
      expect(firstId).not.toBe(secondId);
      for (const interactionId of [firstId, secondId]) {
        const commandId = randomUUID();
        current.socket.write(JSON.stringify({ type: 'command', id: commandId, action: 'interaction.respond', payload: { interactionId, answer } }) + '\n');
        const response = await received(entry => entry.frame.type === 'response' && entry.frame.id === commandId, start);
        expect(response.frame).toMatchObject({ success: true, data: { interactionId, status: 'resolved' } });
      }
      expect(await first).toMatchObject({ kind: 'submit', results: [{ selectedOptions: ['Mavi'] }] });
      expect(await second).toMatchObject({ kind: 'submit', results: [{ selectedOptions: ['Mavi'] }] });
    }
    await runner.emit({ type: 'session_shutdown' });
    expect(Object.getOwnPropertyDescriptor(ui, 'askDialog')).toEqual(originalAsk);
    expect(Object.getOwnPropertyDescriptor(ui, 'notify')).toEqual(originalNotify);
    expect(notifications).toEqual(['Single barrier', 'Barrier', 'Single barrier', 'Barrier']);
    expect(errors).toEqual([]);
  } finally {
    removeLogSink();
    if (runner) { await runner.emit({ type: 'session_shutdown' }); runner.clearManagedTimers(); }
    for (const socket of sockets) socket.destroy();
    const closed = Promise.withResolvers<void>();
    server.close(() => closed.resolve());
    await closed.promise;
    if (previousStateDir === undefined) delete process.env.OMPUTER_STATE_DIR; else process.env.OMPUTER_STATE_DIR = previousStateDir;
    if (previousManaged === undefined) delete process.env.OMPUTER_RPC_MANAGED; else process.env.OMPUTER_RPC_MANAGED = previousManaged;
    await rm(directory, { recursive: true, force: true });
  }
}, 15_000);
