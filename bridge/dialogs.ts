import { randomUUID } from 'node:crypto';
import type { ExtensionAskDialogQuestion as Question, ExtensionAskDialogSubmitResult as AskResult,
  ExtensionUIDialogOptions as DialogOptions, ExtensionUIContext } from '@oh-my-pi/pi-coding-agent';
import type { WireFrame } from './wire';

type UiMethod = (...args: unknown[]) => unknown;
interface Request extends WireFrame { id: string; sessionId: string; method: string; title: string;
  createdAt: string; status: string; options?: { label: string; description?: string }[]; questions?: Question[]; }
interface PendingDialog { id: string; request: Request; accept: (payload: WireFrame) => unknown;
  finish: (value: unknown, status: string) => void; cancel: () => void; }
function invalid(message: string): never { throw Object.assign(new Error(message), { code: 'invalid_answer' }); }

export function validateAsk(questions: Question[], answer: unknown): AskResult {
  if (!answer || typeof answer !== 'object' || !('kind' in answer) || answer.kind !== 'submit' ||
      !('results' in answer) || !Array.isArray(answer.results) || answer.results.length !== questions.length) {
    return invalid('Answer must contain one submitted result per question');
  }
  const answers: unknown[] = answer.results;
  return { kind: 'submit', results: questions.map((question, index) => {
    const value = answers[index];
    if (!value || typeof value !== 'object' || !('id' in value) || value.id !== question.id ||
        !('selectedOptions' in value) || !Array.isArray(value.selectedOptions)) return invalid('Question identity mismatch');
    const labels = question.options.map(option => option.label);
    const selected: string[] = [];
    for (const label of value.selectedOptions) {
      if (typeof label !== 'string' || !labels.includes(label) || selected.includes(label)) return invalid('Selected option is not a unique offered answer');
      selected.push(label);
    }
    const custom = 'customInput' in value ? value.customInput : undefined;
    const note = 'note' in value ? value.note : undefined;
    if (custom !== undefined && typeof custom !== 'string') return invalid('Custom answer must be text');
    if (note !== undefined && typeof note !== 'string') return invalid('Note must be text');
    const customInput = typeof custom === 'string' ? custom.trim() || undefined : undefined;
    if (!question.multi && (selected.length > 1 || (selected.length > 0 && customInput))) return invalid('Question is single-select');
    if (!question.multi && !selected.length && !customInput) return invalid('Choose an option or enter a custom answer');
    return { id: question.id, question: question.question, options: labels, multi: question.multi ?? false,
      selectedOptions: selected, customInput, ...(typeof note === 'string' ? { note } : {}) };
  }) };
}

/** Reflection bypasses createHandlerUIContext's get trap and captures its real target method. */
function underlyingMethod(ui: ExtensionUIContext, key: string): UiMethod | undefined {
  let target: object | null = ui;
  while (target) {
    const descriptor = Object.getOwnPropertyDescriptor(target, key);
    if (descriptor) {
      const value: unknown = descriptor.get ? descriptor.get.call(ui) : descriptor.value;
      return typeof value === 'function' ? value.bind(ui) as UiMethod : undefined;
    }
    target = Object.getPrototypeOf(target);
  }
  return undefined;
}

export class DialogBridge {
  private pending = new Map<string, PendingDialog>();
  private restore: (() => void)[] = [];
  private installation?: { active: boolean };
  constructor(private sessionId: () => string, private send: (frame: WireFrame) => boolean,
    private isReady: () => boolean, private managed: boolean, private changed: () => void) {}
  get waiting() { return this.pending.size > 0; }
  install(ui: ExtensionUIContext) {
    if (this.installation) return;
    const installation = this.installation = { active: true };
    for (const method of ['select', 'confirm', 'input', 'editor', 'askDialog']) {
      const original = underlyingMethod(ui, method);
      if (!original && method !== 'askDialog') continue;
      const descriptor = Object.getOwnPropertyDescriptor(ui, method);
      const wrapper = (...args: unknown[]) => installation.active ? this.dialog(method, args, original) :
        original ? original(...args) : Promise.resolve(method === 'confirm' ? false : undefined);
      Object.defineProperty(ui, method, { value: wrapper, writable: true, configurable: true, enumerable: true });
      this.restore.push(() => {
        if (Object.getOwnPropertyDescriptor(ui, method)?.value !== wrapper) return;
        if (descriptor) Object.defineProperty(ui, method, descriptor); else Reflect.deleteProperty(ui, method);
      });
    }
    const notify = underlyingMethod(ui, 'notify');
    if (notify) {
      const descriptor = Object.getOwnPropertyDescriptor(ui, 'notify');
      const wrapper = (message: string, level?: string) => {
        if (installation.active) {
          try { this.send({ type: 'event', sessionId: this.sessionId(), event: { type: 'notification', message, level } }); } catch {}
        }
        return notify(message, level);
      };
      Object.defineProperty(ui, 'notify', { value: wrapper, writable: true, configurable: true, enumerable: true });
      this.restore.push(() => {
        if (Object.getOwnPropertyDescriptor(ui, 'notify')?.value !== wrapper) return;
        if (descriptor) Object.defineProperty(ui, 'notify', descriptor); else Reflect.deleteProperty(ui, 'notify');
      });
    }
  }
  respond(payload: WireFrame) {
    const pending = typeof payload.interactionId === 'string' ? this.pending.get(payload.interactionId) : undefined;
    if (!pending) throw Object.assign(new Error('Question is no longer pending'), { code: 'stale_interaction' });
    const value = pending.accept(payload);
    pending.finish(value, payload.cancelled ? 'cancelled' : 'resolved');
    return { interactionId: pending.id, status: payload.cancelled ? 'cancelled' : 'resolved' };
  }
  reconnect() {
    for (const pending of this.pending.values()) {
      // The host is still waiting: replay the same first-answer fence and absolute deadline.
      this.send({ type: 'interaction', sessionId: pending.request.sessionId, request: pending.request });
    }
  }
  close() {
    if (this.installation) this.installation.active = false;
    this.installation = undefined;
    for (const pending of [...this.pending.values()]) pending.cancel();
    for (const restore of this.restore.splice(0).reverse()) restore();
  }
  private dialog(method: string, args: unknown[], original?: UiMethod): Promise<unknown> {
    // Arguments originate in OMP's typed in-process UI contract, never from IPC.
    const opts = (args[method === 'askDialog' ? 1 : 2] ?? {}) as DialogOptions;
    const defaultValue = method === 'confirm' ? false : undefined;
    if (opts.signal?.aborted) return Promise.resolve(defaultValue);
    if (!this.managed && !this.isReady()) return original ? Promise.resolve(original(...args)) : Promise.resolve(defaultValue);
    const options = method === 'select' ? args[1] as (string | { label: string; description?: string })[] : undefined;
    const approval = options?.length === 2 && options[0] === 'Approve' && options[1] === 'Deny';
    const request: Request = { id: randomUUID(), sessionId: this.sessionId(), method: approval ? 'approval' : method === 'askDialog' ? 'ask' : method,
      title: method === 'askDialog' ? 'OMP sorusu' : args[0] as string, createdAt: new Date().toISOString(), status: 'pending' };
    if (options) request.options = options.map(option => typeof option === 'string' ? { label: option } : option);
    if (method === 'confirm' || method === 'input') request.message = args[1];
    if (method === 'editor') request.prefill = args[1];
    if (method === 'askDialog') request.questions = args[0] as Question[];
    if (typeof opts.timeout === 'number' && opts.timeout > 0) request.expiresAt = new Date(Date.now() + opts.timeout).toISOString();
    const localAbort = new AbortController();
    const signal = opts.signal ? AbortSignal.any([opts.signal, localAbort.signal]) : localAbort.signal;
    const { promise, resolve, reject } = Promise.withResolvers<unknown>();
    let settled = false;
    let timer: NodeJS.Timeout | undefined;
    const onAbort = () => finish(defaultValue, 'cancelled');
    const finish = (value: unknown, status: string, error?: unknown) => {
      if (settled) return;
      settled = true;
      this.pending.delete(pending.id); clearTimeout(timer);
      opts.signal?.removeEventListener('abort', onAbort);
      localAbort.abort();
      this.send({ type: 'interaction_end', sessionId: request.sessionId, id: pending.id, status });
      this.changed();
      if (error) reject(error); else resolve(value);
    };
    const pending: PendingDialog = { id: request.id, request, finish, cancel: onAbort, accept: payload => {
      if (payload.cancelled === true) return defaultValue;
      if (approval || method === 'confirm') {
        if (typeof payload.confirmed !== 'boolean') return invalid('Confirmation must be a boolean');
        return approval ? payload.confirmed ? 'Approve' : 'Deny' : payload.confirmed;
      }
      if (request.questions) return validateAsk(request.questions, payload.answer);
      if (typeof payload.value !== 'string') return invalid('Answer must be text');
      if (method === 'select' && !request.options?.some(option => option.label === payload.value)) return invalid('Option was not offered');
      return payload.value;
    } };
    this.pending.set(pending.id, pending);
    opts.signal?.addEventListener('abort', onAbort, { once: true });
    this.send({ type: 'interaction', sessionId: this.sessionId(), request });
    this.changed();
    if (typeof opts.timeout === 'number' && opts.timeout > 0) {
      timer = setTimeout(() => {
        try { opts.onTimeout?.(); } catch {}
        const value = request.questions ? { kind: 'submit', results: request.questions.map(question => {
          const labels = question.options.map(option => option.label);
          const index = Math.min(Math.max(question.recommended ?? 0, 0), Math.max(labels.length - 1, 0));
          return { id: question.id, question: question.question, options: labels, multi: question.multi ?? false,
            selectedOptions: labels[index] === undefined ? [] : [labels[index]], timedOut: true };
        }) } : defaultValue;
        finish(value, 'expired');
      }, opts.timeout);
      timer.unref?.();
    }
    if (!this.managed && original) {
      const localArgs = [...args];
      localArgs[method === 'askDialog' ? 1 : 2] = { ...opts, timeout: undefined, onTimeout: undefined, signal };
      Promise.resolve().then(() => settled ? undefined : original(...localArgs)).then(
        value => finish(value, value === undefined ? 'cancelled' : 'resolved'),
        error => finish(defaultValue, 'cancelled', error),
      );
    }
    return promise;
  }
}
