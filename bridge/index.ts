import { realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import type { ExtensionAPI, ExtensionContext, AgentSession, AgentRef } from '@oh-my-pi/pi-coding-agent';
import { LocalBridge } from './ipc';
import { DialogBridge } from './dialogs';
import { parseCommand, text, type Command, type WireFrame } from './wire';

interface Lifecycle {
  ensureLive(id: string): Promise<AgentSession>;
  release(id: string, expected: AgentRef, options: { tombstone: boolean }): Promise<boolean>;
}
interface LifecycleExport { global(): Lifecycle; }
interface Outcome { fingerprint: string; response?: WireFrame; running: Promise<WireFrame>; }

/** Explicit opt-in only. Factories are session-local, even when OMP reuses this module for children. */
export default function omputer(pi: ExtensionAPI) {
  let ctx: ExtensionContext | undefined;
  let live: AgentSession | undefined;
  let bridge: LocalBridge | undefined;
  let dialogs: DialogBridge | undefined;
  let stopped = false;
  let unsubscribe: (() => void) | undefined;
  let unregistry: (() => void) | undefined;
  let timer: NodeJS.Timeout | undefined;
  let lastState = '';
  const managed = process.env.OMPUTER_RPC_MANAGED === '1';
  const managedSessionId = process.env.OMPUTER_SESSION_ID;
  const stateDir = process.env.OMPUTER_STATE_DIR ?? join(process.env.XDG_DATA_HOME ?? join(homedir(), '.local/share'), 'omputer');
  const outcomes = new Map<string, Outcome>();
  const messageIds = new Map<string, string>();
  const registry = pi.pi.AgentRegistry.global();
  const runtimeExports = pi.pi as unknown as { AgentLifecycleManager?: LifecycleExport };
  const lifecycle = runtimeExports.AgentLifecycleManager?.global();
  let warnedAt = 0;
  const report = (error: unknown) => {
    // Reconnection failures are contained and rate-limited; never notify through the wrapped UI.
    if (Date.now() - warnedAt < 60_000) return;
    warnedAt = Date.now();
    try { pi.logger.warn('Omputer local bridge unavailable', { error: error instanceof Error ? error.message : String(error) }); } catch {}
  };
  const id = () => managed && managedSessionId ? managedSessionId : ctx?.sessionManager.getSessionId() ?? '';
  const capabilities = () => [
    ...(managed ? [] : [...(live ? ['session.prompt', 'session.steer', 'session.follow_up', 'session.bash'] : []),
      'session.abort', 'session.model', 'session.thinking', 'session.compact', 'session.rename', 'session.refresh']),
    'interaction.respond', 'ui.select', 'ui.confirm', 'ui.input', 'ui.editor', 'ui.ask', 'ui.approval',
    ...(bridge?.ready ? ['project.checkpoint'] : []),
    ...(live ? ['agent.command', 'agent.chat', ...(lifecycle ? ['agent.kill', 'agent.revive'] : [])] : []),
  ];
  const ownedAgents = () => {
    if (!ctx) return [];
    const rootId = ctx.agent.id;
    const refs = registry.list();
    const reachable = new Set<string>([rootId]);
    let added = true;
    while (added) {
      added = false;
      for (const ref of refs) if (ref.kind === 'sub' && ref.parentId && reachable.has(ref.parentId) && !reachable.has(ref.id)) {
        reachable.add(ref.id); added = true;
      }
    }
    return refs.filter(ref => ref.kind === 'sub' && reachable.has(ref.id));
  };
  const state = () => {
    if (!ctx) throw new Error('Session not initialized');
    let cwd = ctx.sessionManager.getCwd();
    try { cwd = realpathSync(cwd); } catch {}
    const model = ctx.models.current();
    const hasPendingAsyncWork = live?.hasPendingAsyncWork() ?? undefined;
    const isSettled = live ? !live.isStreaming && !live.isCompacting && !ctx.hasPendingMessages() && !hasPendingAsyncWork && !dialogs?.waiting : undefined;
    return { id: id(), cwd, name: pi.getSessionName() ?? '', sessionFile: ctx.sessionManager.getSessionFile(),
      model: model ? { provider: model.provider, id: model.id, name: model.name } : undefined,
      thinkingLevel: pi.getThinkingLevel(), status: stopped ? 'closed' : dialogs?.waiting ? 'waiting' :
        live?.isStreaming || live?.isCompacting || !ctx.isIdle() ? 'running' : hasPendingAsyncWork || ctx.hasPendingMessages() ? 'waiting' : 'idle',
      isStreaming: live?.isStreaming, isCompacting: live?.isCompacting, hasPendingAsyncWork, isSettled,
      todos: live?.getTodoPhases() ?? [], subagents: ownedAgents().map(ref => ({ id: ref.id, name: ref.displayName,
        status: ref.status, parentId: ref.parentId, task: ref.activity ?? '', sessionFile: ref.sessionFile,
        model: ref.history?.resolvedModel, metrics: ref.history?.metrics })),
      capabilities: capabilities(), updatedAt: new Date().toISOString(),
      asyncJobs: ctx.getAsyncJobSnapshot() };
  };
  const sendState = (force = false) => {
    if (ctx && !live) {
      live = registry.get(ctx.agent.id)?.session ?? undefined;
      if (live && !unsubscribe) unsubscribe = live.subscribe(event => forward(event as unknown as WireFrame));
    }
    if (!bridge?.ready || !ctx) return;
    try {
      const current = state();
      // updatedAt is emission time, not a reason to emit unchanged snapshots every tick.
      const key = JSON.stringify({ ...current, updatedAt: undefined });
      if (force || key !== lastState) { lastState = key; bridge.send({ type: 'state', session: current }); }
    } catch (error) { report(error); }
  };
  const messageId = (message: { role?: string; timestamp?: number; toolCallId?: string }, fallback?: string) => {
    const key = `${message.role ?? ''}:${message.timestamp ?? ''}:${message.toolCallId ?? ''}`;
    let value = messageIds.get(key);
    if (!value) { value = fallback ?? `omputer-${randomUUID()}`; messageIds.set(key, value); }
    return value;
  };
  const replayMessages = () => {
    if (!ctx || managed) return;
    for (const entry of ctx.sessionManager.getBranch()) if (entry.type === 'message') {
      bridge?.send({ type: 'event', sessionId: id(), event: { type: 'message_end',
        messageId: messageId(entry.message, entry.id), message: entry.message } });
    }
  };
  const forward = (event: WireFrame) => {
    try {
      if (managed && event.type !== 'notification' && event.type !== 'omputer_command_error') return; // Native RPC owns transcript/control.
      let outgoing = event;
      if (event.message && typeof event.message === 'object') {
        const message = event.message as { role?: string; timestamp?: number; toolCallId?: string };
        outgoing = { ...event, messageId: messageId(message) };
      }
      bridge?.send({ type: 'event', sessionId: id(), event: outgoing });
      sendState();
    } catch (error) { report(error); }
  };
  const admit = async (session: AgentSession, message: string, images?: Parameters<AgentSession['prompt']>[1], asAgent = false) => {
    const admitted = Promise.withResolvers<void>();
    let accepted = false;
    const turn = session.prompt(message, { ...images, streamingBehavior: 'steer', onPromptAdmitted: () => {
      accepted = true; admitted.resolve();
    } });
    void turn.then(() => admitted.resolve(), error => {
      if (!accepted) admitted.reject(error);
      else forward({ type: 'omputer_command_error', error: error instanceof Error ? error.message : String(error), subagent: asAgent });
    });
    await admitted.promise;
    return { accepted: true };
  };
  const execute = async (command: Command): Promise<unknown> => {
    if (!ctx || !dialogs) throw new Error('Session not initialized');
    const payload = command.payload;
    if (command.action === 'interaction.respond') return dialogs.respond(payload);
    if (command.action === 'session.models') return { models: ctx.models.list().map(model => ({ provider: model.provider, id: model.id, name: model.name })) };
    if (command.action === 'agent.command') {
      const agentId = text(payload, 'agentId');
      const ref = ownedAgents().find(agent => agent.id === agentId);
      if (!ref) throw Object.assign(new Error('Agent does not belong to this session'), { code: 'unknown_agent' });
      const action = text(payload, 'command');
      if (action === 'kill') {
        if (!lifecycle) throw Object.assign(new Error('Runtime lifecycle export is required; use bridge/bootstrap.sh'), { code: 'unsupported' });
        const [released, aborted] = await Promise.allSettled([
          lifecycle.release(ref.id, ref, { tombstone: true }), ref.session?.abort({ reason: 'User interrupted' }),
        ]);
        if (released.status === 'rejected') throw released.reason;
        if (aborted.status === 'rejected') throw aborted.reason;
        return { killed: released.value };
      }
      if (action === 'revive') {
        if (!lifecycle) throw Object.assign(new Error('Runtime lifecycle export is required; use bridge/bootstrap.sh'), { code: 'unsupported' });
        await lifecycle.ensureLive(ref.id);
        return { revived: true };
      }
      if (action === 'chat') {
        const session = lifecycle ? await lifecycle.ensureLive(ref.id) : ref.session;
        if (!session) throw Object.assign(new Error('Parked agent needs the opt-in Omputer runtime'), { code: 'unsupported' });
        return admit(session, text(payload, 'message'), undefined, true);
      }
      throw Object.assign(new Error('Unknown subagent command'), { code: 'unsupported' });
    }
    if (managed) throw Object.assign(new Error('Managed session commands belong to its native RPC controller'), { code: 'unsupported' });
    switch (command.action) {
      case 'session.prompt': {
        if (!live) throw new Error('Live session handle unavailable');
        if (payload.images !== undefined && !Array.isArray(payload.images)) throw new Error('images must be an array');
        // Provider image blocks remain validated by OMP's canonical preprocessing path.
        const images = payload.images as NonNullable<Parameters<AgentSession['prompt']>[1]>['images'];
        return admit(live, text(payload, 'message'), { images });
      }
      case 'session.steer':
      case 'session.follow_up': {
        if (!live) throw new Error('Live session handle unavailable');
        if (payload.images !== undefined && !Array.isArray(payload.images)) throw new Error('images must be an array');
        const images = payload.images as NonNullable<Parameters<AgentSession['prompt']>[1]>['images'];
        if (command.action === 'session.steer') await live.steer(text(payload, 'message'), images);
        else await live.followUp(text(payload, 'message'), images);
        return { accepted: true };
      }
      case 'session.abort': await ctx.abort(); return { aborted: true };
      case 'session.model': {
        const provider = text(payload, 'provider'); const modelId = text(payload, 'modelId');
        const model = ctx.models.list().find(candidate => candidate.provider === provider && candidate.id === modelId);
        if (!model || !(await pi.setModel(model))) throw new Error('Model not available or not authenticated');
        return { provider: model.provider, id: model.id, name: model.name };
      }
      case 'session.thinking': {
        const level = text(payload, 'level');
        if (!['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'auto'].includes(level)) throw new Error('Invalid thinking level');
        pi.setThinkingLevel(level as Parameters<ExtensionAPI['setThinkingLevel']>[0]);
        return { level: pi.getThinkingLevel() };
      }
      case 'session.compact': await ctx.compact(typeof payload.instructions === 'string' ? payload.instructions : undefined); return { compacted: true };
      case 'session.rename': await pi.setSessionName(text(payload, 'name')); return { name: pi.getSessionName() };
      case 'session.refresh': sendState(true); replayMessages(); return { session: state(), models: ctx.models.list().map(model => ({ provider: model.provider, id: model.id, name: model.name })) };
      case 'session.bash': {
        if (!live) throw new Error('Live session handle unavailable');
        return live.executeBash(text(payload, 'command'), chunk => forward({ type: 'bash_output', chunk }), { useUserShell: true });
      }
      default: throw Object.assign(new Error(`Unsupported action: ${command.action}`), { code: 'unsupported' });
    }
  };
  const receive = (frame: WireFrame) => {
    let command: Command;
    try { command = parseCommand(frame); } catch (error) { report(error); return; }
    const fingerprint = createHash('sha256').update(JSON.stringify([command.action, command.payload])).digest('hex');
    const existing = outcomes.get(command.id);
    if (existing) {
      if (existing.fingerprint !== fingerprint) {
        bridge?.send({ type: 'response', id: command.id, success: false, error: { code: 'command_conflict', message: 'Command ID was reused with a different payload' } });
      } else if (existing.response) bridge?.send(existing.response);
      // In-flight duplicate shares the original operation and its eventual single outcome.
      return;
    }
    const running = Promise.resolve().then(() => execute(command)).then(data => ({ type: 'response', id: command.id, success: true, data }),
      (error: unknown) => ({ type: 'response', id: command.id, success: false, error: {
        code: error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : 'host_error',
        message: error instanceof Error ? error.message : String(error),
      } }));
    const outcome: Outcome = { fingerprint, running };
    outcomes.set(command.id, outcome);
    void running.then(response => { outcome.response = response; bridge?.send(response); sendState(true); }).catch(report);
  };
  const initialize = async (_event: unknown, context: ExtensionContext): Promise<void> => {
    if (context.agent.kind !== 'main') return;
    ctx = context;
    live = registry.get(context.agent.id)?.session ?? undefined;
    // Pairing exposes resume/history even before a model turn; materialize its real journal.
    if (live) {
      await live.sessionManager.ensureOnDisk();
      await live.sessionManager.flush();
    }
    if (!bridge) {
      dialogs = new DialogBridge(id, frame => bridge?.send(frame) ?? false, () => bridge?.ready ?? false, managed, () => sendState());
      dialogs.install(context.ui);
      bridge = new LocalBridge(stateDir, () => ({ managed, managedSessionId,
        session: { ...state(), runtimeSessionId: ctx?.sessionManager.getSessionId() } }), receive,
        () => { sendState(true); replayMessages(); dialogs?.reconnect();
          for (const outcome of outcomes.values()) if (outcome.response) bridge?.send(outcome.response); },
        () => { lastState = ''; }, report);
      if (live) unsubscribe = live.subscribe(event => forward(event as unknown as WireFrame));
      unregistry = registry.onChange(() => sendState());
      timer = context.setInterval(() => sendState(), 1000);
      bridge.start();
    } else {
      dialogs?.close();
      dialogs?.install(context.ui);
      bridge.stop();
      // Session switches change canonical identity; reconnecting creates a fresh registration.
      bridge = undefined;
      unsubscribe?.(); unregistry?.();
      if (timer) context.clearTimer(timer);
      await initialize(_event, context);
    }
  };
  const z = pi.zod;
  pi.registerTool({
    name: 'omputer_checkpoint', label: 'Save project checkpoint', approval: 'write', loadMode: 'essential',
    description: 'Persist evidence-backed durable project context to the local Omputer daemon. Use at a normal stopping point or handoff, not to claim unverified completion. All fields are required; empty text/decisions are allowed when no evidence exists. Success requires the daemon persistence acknowledgement.',
    parameters: z.object({
      goal: z.string().describe('Current user-requested project goal, without invented scope'),
      summary: z.string().describe('Observed work and outcomes; distinguish verified results from uncertainty'),
      nextStep: z.string().describe('Concrete remaining action, or empty when no remaining action is known'),
      decisions: z.array(z.string()).describe('Evidence-backed durable decisions; empty if none'),
    }),
    async execute(_toolCallId, data, signal, _onUpdate, context) {
      if (context.agent.kind !== 'main' || !ctx || context.sessionManager.getSessionId() !== ctx.sessionManager.getSessionId()) {
        throw new Error('Checkpoint is available only to the registered main session');
      }
      if (!bridge?.ready) throw new Error('Omputer bridge disconnected; checkpoint was not submitted');
      const response = await bridge.request({ type: 'checkpoint', sessionId: id(), data }, signal);
      return { content: [{ type: 'text', text: 'Project checkpoint persisted by the local Omputer daemon.' }], details: { acknowledged: true, data: response.data } };
    },
  });
  pi.on('before_agent_start', (event, context) => {
    if (context.agent.kind !== 'main') return;
    return { systemPrompt: [...event.systemPrompt,
      'At a normal stopping point when finishing work or handing off, use omputer_checkpoint to save concise evidence-backed goal, observed progress, next step, and durable decisions. Never invent a summary or claim unverified completion. Do not interrupt ongoing work or make extra model calls for checkpointing. A disconnected or unacknowledged checkpoint is not confirmed saved.'] };
  });
  // Registry attachment can lag session_start. Preserve live messages until the session handle appears.
  pi.on('message_start', (event, context) => { if (!live && context.agent.kind === 'main') forward(event as unknown as WireFrame); });
  pi.on('message_update', (event, context) => { if (!live && context.agent.kind === 'main') forward(event as unknown as WireFrame); });
  pi.on('message_end', (event, context) => { if (!live && context.agent.kind === 'main') forward(event as unknown as WireFrame); });
  pi.on('session_start', initialize);
  pi.on('session_switch', initialize);
  pi.on('session_branch', initialize);
  pi.on('session_shutdown', () => {
    stopped = true;
    dialogs?.close(); sendState(true);
    unsubscribe?.(); unregistry?.(); bridge?.stop();
    if (timer && ctx) ctx.clearTimer(timer);
  });
}
