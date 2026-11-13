export interface WireFrame { [key: string]: unknown; type?: string; }
export interface Command { type: 'command'; id: string; action: string; payload: Record<string, unknown>; operationId?: string; }
export const FRAME_BYTES = 1024 * 1024;
export const LOGICAL_BYTES = 64 * FRAME_BYTES;
export const CHUNK_BYTES = 256 * 1024;
/** Immutable logical JSON bytes, shared by bounded socket queues and exact outcome replay. */
export interface EncodedFrame { readonly bytes: Buffer; }
export function encodeFrame(frame: WireFrame): EncodedFrame {
  const json = JSON.stringify(frame);
  if (Buffer.byteLength(json) > LOGICAL_BYTES) throw Object.assign(new Error('Omputer logical response exceeds 64 MiB; the host effect may have completed. Refresh state before issuing another command.'), { code: 'frame_too_large' });
  return { bytes: Buffer.from(json) };
}
export function parseCommand(value: WireFrame): Command {
  if (value.type !== 'command' || typeof value.id !== 'string' || !value.id || typeof value.action !== 'string' ||
      !value.payload || typeof value.payload !== 'object' || Array.isArray(value.payload)) throw new Error('Malformed bridge command');
  if (value.operationId !== undefined && (typeof value.operationId !== 'string' || !value.operationId)) throw new Error('Malformed operation identity');
  return { type: 'command', id: value.id, action: value.action, payload: value.payload as Record<string, unknown>, operationId: value.operationId as string | undefined };
}
export function text(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== 'string' || !value.trim()) throw Object.assign(new Error(`${key} must be non-empty text`), { code: 'invalid_command' });
  return value;
}
