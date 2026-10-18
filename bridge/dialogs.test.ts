import { describe, expect, test } from 'bun:test';
import type { ExtensionAskDialogQuestion, ExtensionAskDialogSubmitResult, ExtensionUIContext } from '@oh-my-pi/pi-coding-agent';
import { DialogBridge } from './dialogs';
import type { WireFrame } from './wire';

const questions: ExtensionAskDialogQuestion[] = [{ id: 'color', question: 'Renk?', options: [{ label: 'Mavi' }, { label: 'Yeşil' }] }];
const answer = { kind: 'submit', results: [{ id: 'color', selectedOptions: ['Mavi'] }] };

function fixture() {
  const frames: WireFrame[] = [];
  const local: { resolve: (value: ExtensionAskDialogSubmitResult | undefined) => void; signal?: AbortSignal }[] = [];
  const notifications: string[] = [];
  const ui = {
    askDialog: (_questions, options) => {
      const { promise, resolve } = Promise.withResolvers<ExtensionAskDialogSubmitResult | undefined>();
      local.push({ resolve, signal: options?.signal });
      options?.signal?.addEventListener('abort', () => resolve(undefined), { once: true });
      return promise;
    },
    confirm: async () => false,
    notify: (message: string) => { notifications.push(message); },
  } as ExtensionUIContext;
  let session = 'first-session';
  const bridge = new DialogBridge(() => session, frame => { frames.push(frame); return true; }, () => true, false, () => {});
  bridge.install(ui);
  return { bridge, ui, frames, local, notifications, switchSession: () => { session = 'second-session'; } };
}

describe('DialogBridge ownership and first answer', () => {
  test('one ask advertises one interaction and phone answer resolves the desktop promise once', async () => {
    const f = fixture();
    try {
      const promise = f.ui.askDialog!(questions);
      await Promise.resolve();
      expect(f.frames.filter(frame => frame.type === 'interaction')).toHaveLength(1);
      expect(f.local).toHaveLength(1);
      const request = f.frames[0].request as WireFrame;
      const payload = { interactionId: request.id, answer };
      expect(f.bridge.respond(payload)).toEqual({ interactionId: request.id, status: 'resolved' });
      expect(await promise).toMatchObject({ kind: 'submit', results: [{ id: 'color', selectedOptions: ['Mavi'] }] });
      expect(f.local[0].signal?.aborted).toBe(true);
      expect(() => f.bridge.respond(payload)).toThrow('Question is no longer pending');
      expect(f.frames.filter(frame => frame.type === 'interaction_end')).toHaveLength(1);
    } finally { f.bridge.close(); }
  });

  test('two identical concurrent invocations retain distinct first-answer fences', async () => {
    const f = fixture();
    try {
      const first = f.ui.askDialog!(questions);
      const second = f.ui.askDialog!(questions);
      await Promise.resolve();
      const requests = f.frames.filter(frame => frame.type === 'interaction').map(frame => frame.request as WireFrame);
      expect(requests).toHaveLength(2);
      expect(requests[0].id).not.toBe(requests[1].id);
      f.bridge.respond({ interactionId: requests[0].id, answer });
      await first;
      expect(f.bridge.waiting).toBe(true);
      f.bridge.respond({ interactionId: requests[1].id, answer });
      await second;
      expect(f.bridge.waiting).toBe(false);
    } finally { f.bridge.close(); }
  });

  test('desktop answer wins and reconnect replays only the original pending identity and deadline', async () => {
    const f = fixture();
    try {
      const promise = f.ui.askDialog!(questions, { timeout: 60_000 });
      await Promise.resolve();
      const request = f.frames[0].request as WireFrame;
      f.bridge.reconnect();
      expect(f.frames[1]).toEqual(f.frames[0]);
      expect((f.frames[1].request as WireFrame).expiresAt).toBe(request.expiresAt);
      const result: ExtensionAskDialogSubmitResult = { kind: 'submit', results: [{ id: 'color', question: 'Renk?', options: ['Mavi', 'Yeşil'], multi: false, selectedOptions: ['Mavi'] }] };
      f.local[0].resolve(result);
      expect(await promise).toBe(result);
      expect(() => f.bridge.respond({ interactionId: request.id, answer })).toThrow('Question is no longer pending');
      const count = f.frames.length;
      f.bridge.reconnect();
      expect(f.frames).toHaveLength(count);
    } finally { f.bridge.close(); }
  });

  test('close restores descriptors, cancels with the original session and confirm default, and can reinstall', async () => {
    const f = fixture();
    f.bridge.close();
    const originalAsk = Object.getOwnPropertyDescriptor(f.ui, 'askDialog');
    const originalNotify = Object.getOwnPropertyDescriptor(f.ui, 'notify');
    f.bridge.install(f.ui);
    const promise = f.ui.confirm('Devam?', 'Onayla');
    f.switchSession();
    f.bridge.close();
    expect(await promise).toBe(false);
    expect(f.frames.at(-1)).toMatchObject({ type: 'interaction_end', sessionId: 'first-session', status: 'cancelled' });
    expect(Object.getOwnPropertyDescriptor(f.ui, 'askDialog')).toEqual(originalAsk);
    expect(Object.getOwnPropertyDescriptor(f.ui, 'notify')).toEqual(originalNotify);
    f.bridge.install(f.ui);
    try {
      f.ui.notify('Bildirim');
      expect(f.notifications).toEqual(['Bildirim']);
      expect(f.frames.filter(frame => frame.type === 'event')).toHaveLength(1);
      const next = f.ui.askDialog!(questions);
      const request = f.frames.at(-1)!.request as WireFrame;
      f.bridge.respond({ interactionId: request.id, answer });
      await next;
    } finally { f.bridge.close(); }
  });

  test('retained methods and a later foreign wrapper cannot reactivate a closed installation', async () => {
    const f = fixture();
    const retainedAsk = f.ui.askDialog!;
    const retainedNotify = f.ui.notify;
    const foreignNotify: ExtensionUIContext['notify'] = (message, level) => retainedNotify(message, level);
    f.ui.notify = foreignNotify;
    f.bridge.close();
    expect(f.ui.notify).toBe(foreignNotify);
    f.bridge.install(f.ui);
    try {
      retainedNotify('Eski');
      f.ui.notify('Yeni');
      expect(f.notifications).toEqual(['Eski', 'Yeni']);
      expect(f.frames.filter(frame => frame.type === 'event')).toHaveLength(1);
      const localOnly = retainedAsk(questions);
      expect(f.frames.filter(frame => frame.type === 'interaction')).toHaveLength(0);
      f.local.at(-1)!.resolve(undefined);
      await localOnly;
    } finally { f.bridge.close(); }
  });

  test('phone notes stay separate from a single selected answer and empty multi-select is valid', async () => {
    const f = fixture();
    try {
      const promise = f.ui.askDialog!(questions);
      const request = f.frames.at(-1)!.request as WireFrame;
      f.bridge.respond({ interactionId: request.id, answer: { kind: 'submit', results: [{ id: 'color', selectedOptions: ['Mavi'], note: 'Bağlam kaybolmasın' }] } });
      expect(await promise).toMatchObject({ results: [{ selectedOptions: ['Mavi'], note: 'Bağlam kaybolmasın' }] });
      const multi = f.ui.askDialog!([{ ...questions[0], multi: true }]);
      const multiRequest = f.frames.at(-1)!.request as WireFrame;
      f.bridge.respond({ interactionId: multiRequest.id, answer: { kind: 'submit', results: [{ id: 'color', selectedOptions: [] }] } });
      expect(await multi).toMatchObject({ results: [{ multi: true, selectedOptions: [] }] });
    } finally { f.bridge.close(); }
  });

  test('ask timeout returns OMP recommended answers instead of turning expiry into user cancellation', async () => {
    const f = fixture();
    let timeouts = 0;
    try {
      const promise = f.ui.askDialog!([{ ...questions[0], recommended: 1 }], { timeout: 10, onTimeout: () => { timeouts++; } });
      await Promise.resolve();
      const request = f.frames.at(-1)!.request as WireFrame;
      expect(await promise).toMatchObject({ kind: 'submit', results: [{ selectedOptions: ['Yeşil'], timedOut: true }] });
      expect(timeouts).toBe(1);
      expect(f.local[0].signal?.aborted).toBe(true);
      expect(f.frames.filter(frame => frame.type === 'interaction_end')).toEqual([
        { type: 'interaction_end', sessionId: 'first-session', id: request.id, status: 'expired' },
      ]);
      expect(() => f.bridge.respond({ interactionId: request.id, answer })).toThrow('Question is no longer pending');
    } finally { f.bridge.close(); }
  });
});
