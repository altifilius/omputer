import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const [base, runtime, destination] = process.argv.slice(2);
if (!base || !runtime || !destination) throw new Error('Usage: component-versions.ts <project> <runtime> <destination>');
const cargo = await readFile(join(base, 'pc/Cargo.toml'), 'utf8');
const native = cargo.match(/^version\s*=\s*"([^"]+)"/m)?.[1];
if (!native) throw new Error('Native package version missing');
const omp = JSON.parse(await readFile(join(runtime, 'packages/coding-agent/package.json'), 'utf8')).version;
const bridge = JSON.parse(await readFile(join(base, 'bridge/package.json'), 'utf8')).version;
if (typeof omp !== 'string' || typeof bridge !== 'string') throw new Error('Runtime or bridge package version missing');
await writeFile(destination, JSON.stringify({ native, omp, bridge }, null, 2) + '\n', { mode: 0o600 });
