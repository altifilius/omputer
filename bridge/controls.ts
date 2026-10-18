import type { ExtensionAPI, ExtensionContext, AgentSession } from '@oh-my-pi/pi-coding-agent';
import type { Command, WireFrame } from './wire';

export interface HostControls {
  catalog(): Promise<Record<string, unknown>>;
  query(view: string, args: Record<string, unknown>): Promise<Record<string, unknown>>;
  execute(action: string, payload: Record<string, unknown>, operationId: string, emit: (event: WireFrame) => void): Promise<Record<string, unknown>>;
}
interface ControlsExport { version: number; create(pi: ExtensionAPI, ctx: ExtensionContext, session: AgentSession): HostControls; }
export function createControls(pi: ExtensionAPI, ctx: ExtensionContext, session?: AgentSession): HostControls | undefined {
  // The private runtime optionally adds this session-local factory to the public exports.
  const exports = pi.pi as unknown as { OmputerControls?: ControlsExport };
  const factory = exports.OmputerControls;
  return factory?.version === 1 && session ? factory.create(pi, ctx, session) : undefined;
}
export function controlsError(code: string, message: string): Error { return Object.assign(new Error(message), { code }); }
export async function runControl(adapter: HostControls | undefined, command: Command,
  identity: { journalId: string; bindingRevision?: string }, emit: (event: WireFrame) => void): Promise<Record<string, unknown>> {
  if (!adapter) throw controlsError('unsupported', 'This runtime does not export OmputerControls; update the private OMP runtime');
  if (command.action === 'session.controls') {
    const view = command.payload.view;
    if (typeof view !== 'string') throw controlsError('invalid_command', 'Control view is required');
    const args = command.payload.arguments;
    if (!args || typeof args !== 'object' || Array.isArray(args)) throw controlsError('invalid_command', 'Control arguments must be an object');
    const data = view === 'commands' ? await adapter.catalog() : await adapter.query(view, args as Record<string, unknown>);
    return { ...data, ...identity };
  }
  if (command.payload.expectedJournalId !== identity.journalId ||
      command.payload.expectedBindingRevision !== identity.bindingRevision || !identity.bindingRevision) {
    throw controlsError('stale_identity', 'Session identity changed; refresh controls before executing');
  }
  if (!command.operationId) throw controlsError('invalid_command', 'Durable operation identity is required');
  return adapter.execute(command.action, command.payload, command.operationId, event => {
    if (event.type !== 'operation_output' || event.operationId !== command.operationId || typeof event.kind !== 'string' || typeof event.text !== 'string') {
      throw controlsError('invalid_output', 'Host emitted invalid or uncorrelated operation output');
    }
    emit(event);
  });
}
