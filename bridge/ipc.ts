import { createConnection, type Socket } from 'node:net';
import { randomUUID } from 'node:crypto';
import { lstat, open } from 'node:fs/promises';
import { join } from 'node:path';
import { CHUNK_BYTES, FRAME_BYTES, LOGICAL_BYTES, encodeFrame, type EncodedFrame, type WireFrame } from './wire';

/** Best-effort observability; callers replay durable state and command outcomes after registration. */
export class LocalBridge {
  private socket?: Socket;
  private retry?: NodeJS.Timeout;
  private stopped = false;
  private connecting = false;
  private generation = 0;
  private delay = 250;
  private queue: { frame: EncodedFrame; complete?: (sent: boolean) => void }[] = [];
  private queuedBytes = 0;
  private writing = false;
  private capacity?: () => void;
  private reliableWaiting = false;
  ready = false;
  private requests = new Map<string, { resolve: (frame: WireFrame) => void; reject: (error: Error) => void }>();
  async request(frame: WireFrame, signal?: AbortSignal): Promise<WireFrame> {
    if (!this.ready) throw new Error('Omputer bridge disconnected; checkpoint was not submitted');
    if (signal?.aborted) throw new Error('Omputer checkpoint cancelled before submission');
    const id = randomUUID();
    const { promise, resolve, reject } = Promise.withResolvers<WireFrame>();
    const abort = () => reject(new Error('Omputer checkpoint acknowledgement cancelled; checkpoint persistence is unconfirmed'));
    const timer = setTimeout(() => reject(new Error('Omputer checkpoint acknowledgement timed out; checkpoint persistence is unconfirmed')), 15_000);
    timer.unref?.();
    this.requests.set(id, { resolve, reject });
    signal?.addEventListener('abort', abort, { once: true });
    try {
      if (!this.send({ ...frame, id })) throw new Error('Omputer bridge unavailable; checkpoint submission was not acknowledged');
      const response = await promise;
      if (response.success !== true) {
        const error = response.error as { message?: unknown; code?: unknown } | undefined;
        throw Object.assign(new Error(typeof error?.message === 'string' ? error.message : 'Omputer checkpoint rejected'),
          { code: typeof error?.code === 'string' ? error.code : 'checkpoint_rejected' });
      }
      return response;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      this.requests.delete(id);
    }
  }
  private rejectRequests(): void {
    for (const request of this.requests.values()) request.reject(new Error('Omputer bridge disconnected; checkpoint persistence is unconfirmed'));
    this.requests.clear();
  }
  constructor(readonly stateDir: string, private registration: () => WireFrame,
    private receive: (frame: WireFrame) => void, private connected: () => void,
    private disconnected: () => void, private report: (error: unknown) => void) {}

  start(): void { void this.connect().catch(error => this.failed(error)); }
  send(frame: WireFrame): boolean {
    if (!this.ready || !this.socket || this.socket.destroyed) return false;
    try {
      const sent = this.enqueue(encodeFrame(frame));
      if (!sent && (frame.type === 'interaction' || frame.type === 'interaction_end')) this.socket.destroy(new Error('Omputer interaction queue overflow; reconnecting for authoritative replay'));
      return sent;
    }
    catch (error) { this.report(error); return false; }
  }
  /** The extension serializes durable replay; at most one logical frame waits outside the queue. */
  async sendEncoded(frame: EncodedFrame): Promise<boolean> {
    if (this.reliableWaiting || frame.bytes.length > LOGICAL_BYTES) return false;
    this.reliableWaiting = true;
    const socket = this.socket;
    try {
      while (this.ready && socket === this.socket && socket && !socket.destroyed) {
        if (this.queuedBytes + frame.bytes.length <= LOGICAL_BYTES + FRAME_BYTES && this.queue.length < 1024) {
          const completed = Promise.withResolvers<boolean>();
          if (!this.enqueue(frame, completed.resolve)) return false;
          return await completed.promise;
        }
        const available = Promise.withResolvers<void>();
        this.capacity = available.resolve;
        await available.promise;
      }
      return false;
    } finally { this.reliableWaiting = false; }
  }
  private enqueue(frame: EncodedFrame, complete?: (sent: boolean) => void): boolean {
    if (!this.ready || !this.socket || this.socket.destroyed || frame.bytes.length > LOGICAL_BYTES ||
        this.queuedBytes + frame.bytes.length > LOGICAL_BYTES + FRAME_BYTES || this.queue.length >= 1024) return false;
    this.queue.push({ frame, complete });
    this.queuedBytes += frame.bytes.length;
    if (!this.writing) void this.writeQueue(this.socket);
    return true;
  }
  private async writeQueue(socket: Socket): Promise<void> {
    this.writing = true;
    try {
      while (socket === this.socket && !socket.destroyed && this.queue.length) {
        const item = this.queue[0];
        const bytes = item.frame.bytes;
        if (bytes.length + 1 <= FRAME_BYTES) await this.write(socket, Buffer.concat([bytes, Buffer.from('\n')]));
        else {
          const chunkId = randomUUID();
          const count = Math.ceil(bytes.length / CHUNK_BYTES);
          for (let index = 0; index < count; index++) {
            const data = bytes.subarray(index * CHUNK_BYTES, (index + 1) * CHUNK_BYTES).toString('base64');
            await this.write(socket, JSON.stringify({ type: 'rpc_chunk', chunkId, index, count, byteLength: bytes.length, data }) + '\n');
          }
        }
        if (socket !== this.socket) return;
        this.queue.shift();
        this.queuedBytes -= bytes.length;
        item.complete?.(true);
        this.capacity?.(); this.capacity = undefined;
      }
    } catch (error) {
      if (socket === this.socket && !this.stopped) { this.report(error); socket.destroy(); }
    } finally {
      if (socket === this.socket) this.writing = false;
    }
  }
  private async write(socket: Socket, bytes: string | Buffer): Promise<void> {
    if (socket !== this.socket || socket.destroyed) throw new Error('Omputer bridge closed during write');
    const completed = Promise.withResolvers<void>();
    let flushed = false;
    let drained = false;
    const finish = () => { if (flushed && drained) completed.resolve(); };
    const drain = () => { drained = true; finish(); };
    const close = () => completed.reject(new Error('Omputer bridge closed during write'));
    const error = (failure: Error) => completed.reject(failure);
    socket.once('drain', drain); socket.once('close', close); socket.once('error', error);
    try {
      drained = socket.write(bytes, failure => {
        if (failure) completed.reject(failure);
        else { flushed = true; finish(); }
      });
      await completed.promise;
    } finally {
      socket.off('drain', drain); socket.off('close', close); socket.off('error', error);
    }
  }
  private clearQueue(): void {
    for (const item of this.queue) item.complete?.(false);
    this.queue = []; this.queuedBytes = 0; this.writing = false;
    this.capacity?.(); this.capacity = undefined;
  }
  stop(): void {
    this.stopped = true;
    clearTimeout(this.retry);
    this.socket?.destroy();
    this.socket = undefined;
    this.ready = false;
    this.rejectRequests();
    this.clearQueue();
  }
  private failed(error: unknown): void {
    this.report(error);
    this.socket?.destroy();
    this.schedule();
  }
  private schedule(): void {
    if (this.stopped || this.retry) return;
    this.retry = setTimeout(() => { this.retry = undefined; this.start(); }, this.delay);
    this.retry.unref?.();
    this.delay = Math.min(this.delay * 2, 15_000);
  }
  private async connect(): Promise<void> {
    if (this.stopped || this.connecting || this.socket) return;
    this.connecting = true;
    try {
      const socketPath = join(this.stateDir, 'bridge.sock');
      const tokenPath = join(this.stateDir, 'bridge.token');
      const [directory, socketInfo, tokenInfo] = await Promise.all([lstat(this.stateDir), lstat(socketPath), lstat(tokenPath)]);
      const uid = process.getuid?.();
      if (!directory.isDirectory() || (directory.mode & 0o077) !== 0 || (uid !== undefined && directory.uid !== uid)) throw new Error('Omputer state directory must be owner-only (0700)');
      if (!socketInfo.isSocket() || (socketInfo.mode & 0o077) !== 0 || (uid !== undefined && socketInfo.uid !== uid)) throw new Error('Omputer bridge socket must be owner-only (0600)');
      if (!tokenInfo.isFile() || (tokenInfo.mode & 0o077) !== 0 || (uid !== undefined && tokenInfo.uid !== uid)) throw new Error('Omputer bridge token must be an owner-only regular file (0600)');
      const tokenFile = await open(tokenPath, 'r');
      let token: string;
      try {
        const actual = await tokenFile.stat();
        if (actual.ino !== tokenInfo.ino || actual.dev !== tokenInfo.dev) throw new Error('Bridge token changed while opening');
        token = (await tokenFile.readFile('utf8')).trim();
      } finally { await tokenFile.close(); }
      if (!token || token.length > 4096) throw new Error('Invalid Omputer bridge token');
      if (this.stopped) return;
      const generation = ++this.generation;
      const socket = createConnection(socketPath);
      this.socket = socket;
      socket.setEncoding('utf8');
      let buffer = '';
      const deadline = setTimeout(() => socket.destroy(new Error('Omputer registration timed out')), 5000);
      deadline.unref?.();
      socket.on('connect', () => {
        try { socket.write(JSON.stringify({ ...this.registration(), type: 'register', token }) + '\n'); }
        catch (error) { this.failed(error); }
      });
      socket.on('data', data => {
        try {
          buffer += data;
          if (Buffer.byteLength(buffer) > 8 * 1024 * 1024) throw new Error('Bridge input frame exceeds limit');
          let newline: number;
          while ((newline = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, newline);
            buffer = buffer.slice(newline + 1);
            if (!line.trim()) continue;
            const parsed: unknown = JSON.parse(line);
            if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Invalid bridge frame');
            const frame = parsed as WireFrame;
            if (frame.type === 'registered' && !this.ready) {
              clearTimeout(deadline); this.ready = true; this.delay = 250; this.receive(frame); this.connected();
            } else if (this.ready) {
              const request = frame.type === 'response' && typeof frame.id === 'string' ? this.requests.get(frame.id) : undefined;
              if (request) request.resolve(frame);
              else if (frame.type !== 'response') this.receive(frame);
            }
          }
        } catch (error) { this.failed(error); }
      });
      socket.on('error', error => this.report(error));
      socket.on('close', () => {
        clearTimeout(deadline);
        if (generation !== this.generation) return;
        const wasReady = this.ready;
        this.socket = undefined; this.ready = false;
        this.clearQueue();
        this.rejectRequests();
        if (wasReady) { try { this.disconnected(); } catch (error) { this.report(error); } }
        this.schedule();
      });
    } finally { this.connecting = false; }
  }
}
