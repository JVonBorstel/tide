#!/usr/bin/env node
// @ts-check
// The ledger command (core/ledger/README.md):
//   node core/ledger/cli.mjs build --state <dir> --db <file> [--out <dir>] [--repo name=path]... [--github owner/name,...|--no-github]
//                                  [--plans <dir>] [--work <dir>] [--flags <flags.json>] [--now <iso>] [--json]
//   node core/ledger/cli.mjs show <id> --db <file> [--json]          one row with its events (WO-312 or J312)
//   node core/ledger/cli.mjs queue --db <file> [--json]              Jordan's cards and the orders waiting on him, oldest first
//   node core/ledger/cli.mjs streams --db <file> [--json]            the streams, their WIP and the attention flags
//   node core/ledger/cli.mjs parity --db <file> --old <ledger.json> [--json]   every old ledger item: same, explained or unexplained
//   node core/ledger/cli.mjs flags --db <file> [--json]              feature flag values (flag.set events over flags.json defaults)
//   node core/ledger/cli.mjs backup --db <file> --to <file>          the nightly copy (VACUUM INTO)
// Exit: 0 fine, 1 the store or a source could not be read, 2 a usage error or a refused write, 3 parity found unexplained items.
// node:sqlite needs --experimental-sqlite on Node 22 and nothing on Node 24: this file checks, and starts itself again with the flag only
// when the module is missing. Everything else lives in commands.mjs.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// node:sqlite exists from Node 22.5: below that, say so in plain words (node itself would only say "bad option")
const [maj, min] = process.versions.node.split('.').map(Number);
if (maj < 22 || (maj === 22 && min < 5)) { process.stdout.write(`ERROR (unavailable): the ledger needs Node 22.5 or later for node:sqlite; this is Node ${process.versions.node}\n`); process.exit(1); }
let ok = true;
try { await import('node:sqlite'); } catch { ok = false; }
if (!ok && !process.env.LEDGER_SQLITE_RESPAWNED) {
  const r = spawnSync(process.execPath, ['--experimental-sqlite', '--disable-warning=ExperimentalWarning', fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: 'inherit', env: { ...process.env, LEDGER_SQLITE_RESPAWNED: '1' }, windowsHide: true });
  process.exit(r.status ?? 1);
}
const { main } = await import('./commands.mjs');
process.exitCode = await main(process.argv.slice(2));
