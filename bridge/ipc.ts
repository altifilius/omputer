import { createConnection, type Socket } from 'node:net';
import { randomUUID } from 'node:crypto';
import { lstat, open } from 'node:fs/promises';
import { join } from 'node:path';
import type { WireFrame } from './wire';

/** Best-effort observability; callers replay durable state and command outcomes after registration. */
export class LocalBridge {
  private socket?: Socket;
  private retry?: NodeJS.Timeout;
  private stopped = false;
  private connecting = false;
  private generation = 0;
  private delay = 250;
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
      const data = JSON.stringify(frame) + '\n';
      if (this.socket.writableLength + Buffer.byteLength(data) > 16 * 1024 * 1024) {
        this.socket.destroy(new Error('Omputer socket backpressure limit reached'));
        return false;
      }
      this.socket.write(data);
      return true;
    } catch (error) { this.failed(error); return false; }
  }
  stop(): void {
    this.stopped = true;
    clearTimeout(this.retry);
    this.socket?.destroy();
    this.socket = undefined;
    this.ready = false;
    this.rejectRequests();
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
        this.rejectRequests();
        if (wasReady) { try { this.disconnected(); } catch (error) { this.report(error); } }
        this.schedule();
      });
    } finally { this.connecting = false; }
  }
}
