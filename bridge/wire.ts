export interface WireFrame { [key: string]: unknown; type?: string; }
export interface Command { type: 'command'; id: string; action: string; payload: Record<string, unknown>; }
export function parseCommand(value: WireFrame): Command {
  if (value.type !== 'command' || typeof value.id !== 'string' || !value.id || typeof value.action !== 'string' ||
      !value.payload || typeof value.payload !== 'object' || Array.isArray(value.payload)) throw new Error('Malformed bridge command');
  return { type: 'command', id: value.id, action: value.action, payload: value.payload as Record<string, unknown> };
}
export function text(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== 'string' || !value.trim()) throw Object.assign(new Error(`${key} must be non-empty text`), { code: 'invalid_command' });
  return value;
}
