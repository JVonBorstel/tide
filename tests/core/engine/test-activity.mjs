// Owns the tests of the activity contract wrapper (core/engine/activity.mjs): contract-valid calls and results, at most one run per
// idempotency key (in memory and on disk), the station wrapper's refusals, and one real run of a test-double station through
// scripts/run-bounded.ps1 (Windows with pwsh only: run-bounded uses a Windows Job Object; elsewhere it is skipped, saying so).
// Called by tests/core/engine/test-engine.mjs.
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { makeActivity, result, once, memoryStore, fileStore, stationCommand, stationActivities, psQuote, STATIONS, OUT_CAP } from '../../../core/engine/activity.mjs';
import { check, skip, tmp } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const act = (name, args = {}, key = `WO-2101:${name}:a1:r1`) => makeActivity({ wo: 'WO-2101', name, args, idempotencyKey: key, timeoutSec: 30, maxMB: 256 });
const throws = (fn) => { try { fn(); return ''; } catch (err) { return err.message; } };

async function testContract() {
  const a = act('ci-wait', { Repo: 'example-owner/example-repo', Alias: 'J9001', Pr: null });
  check('makeActivity: a contract-valid call, null args left out', a.v === '1.0' && !('Pr' in a.args) && a.args.Alias === 'J9001');
  check('makeActivity: nested args are refused by the contract', /not valid/.test(throws(() => act('ci-wait', { Deep: { x: 1 } }))));
  check('makeActivity: a short idempotency key is refused', /not valid/.test(throws(() => act('ci-wait', {}, 'short'))));
  const big = result(0, 'x'.repeat(OUT_CAP + 50) + 'END');
  check('result: ok only for exit 0; out keeps the last 64 KB', big.ok && big.out.length === OUT_CAP && big.out.endsWith('END') && !result(11, 'later').ok);
}

async function testOnce() {
  let runs = 0; const impl = async () => { runs++; return result(0, 'done', 'example proof'); };
  const store = memoryStore(); const a = act('docs');
  const r1 = await once(a, impl, store); const r2 = await once(a, impl, store);
  check('once: the second call with the same key replays the stored result and does not run the step again', runs === 1 && !r1.replayed && r2.replayed && r2.result.out === 'done', `runs ${runs}`);
  await once(act('docs', {}, 'WO-2101:docs:a1:r2'), impl, store);
  check('once: a new key runs the step again', runs === 2, `runs ${runs}`);
  const boom = await once(act('docs', {}, 'WO-2101:docs:a1:r3'), async () => { throw new Error('example crash'); }, store);
  check('once: a step that throws becomes exit 1 with the reason (never an unhandled crash)', boom.result.exit === 1 && /example crash/.test(boom.result.out));
  const dir = tmp('store');
  try {
    let n = 0; const count = async () => { n++; return result(0, 'on disk'); };
    await once(a, count, fileStore(dir));
    const again = await once(a, count, fileStore(dir));
    check('once + fileStore: a new process (new store on the same folder) replays, not reruns', n === 1 && again.replayed, `runs ${n}`);
    check('fileStore: no temp files left behind', fs.readdirSync(dir).every((f) => f.endsWith('.json')), fs.readdirSync(dir).join());
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

async function testStationRefusals() {
  const calls = []; const run = async (exe, argv, o) => { calls.push({ argv, env: o.env }); return { exit: 0, out: 'example ok' }; };
  const yes = (d, wo) => d === 'D-1' && wo === 'WO-2101';
  const shadow = stationActivities({ mode: 'shadow', run, answered: yes });
  const live = stationActivities({ mode: 'new', run, answered: yes, kitchen: 'scratch-state' });
  check('stations: every station in STATIONS has an activity', Object.keys(STATIONS).every((n) => typeof shadow[n] === 'function'));
  check('stations: in shadow, a station that changes things (merge) is not run (exit 127, says why)', (await shadow.merge(act('merge', { Alias: 'J9001', Decision: 'D-1' }))).exit === 127 && calls.length === 0);
  check('stations: without the WO\'s Yard alias, nothing runs (exit 127)', (await shadow['ci-wait'](act('ci-wait', {}))).exit === 127 && calls.length === 0);
  check('stations: merge without a decision id is refused (exit 2)', (await live.merge(act('merge', { Alias: 'J9001' }))).exit === 2 && calls.length === 0);
  check('stations: merge with a decision that is not Jordan\'s Yes on this WO is refused (exit 2)', (await live.merge(act('merge', { Alias: 'J9001', Decision: 'D-7' }))).exit === 2 && calls.length === 0);
  const m = await live.merge(act('merge', { Alias: 'J9001', Decision: 'D-1', Repo: 'example-checkout' }));
  const c = calls[0] || { argv: [], env: {} };
  check('stations: merge after a Yes runs through run-bounded with KITCHEN_JOB, KITCHEN_APPROVED and the scratch BRAIN_KITCHEN',
    m.ok && /-TimeoutSeconds 30 -MaxMB 256/.test(c.argv.join(' ')) && c.argv.join(' ').includes(path.join('scripts', 'run-bounded.ps1')) && c.env.KITCHEN_JOB === 'J9001' && c.env.KITCHEN_APPROVED === '1' && c.env.BRAIN_KITCHEN === 'scratch-state', JSON.stringify(c.argv));
  await live['ci-wait'](act('ci-wait', { Alias: 'J9001', Repo: 'example-checkout' }, 'WO-2101:ci-wait:a1:r9'));
  check('stations: a read-only station never gets KITCHEN_APPROVED', calls[1] && calls[1].env.KITCHEN_APPROVED !== '1');
  const cmd = stationCommand(act('ci-wait', { Repo: 'r', Alias: 'J9001', Head: 'abc' }), { root: repo, repoPath: (x) => `checkout-of-${x}` });
  check('stationCommand: passes only the station\'s own parameters, quoted, after -ScriptArgs',
    cmd[cmd.length - 1].endsWith("-ScriptArgs @('-Repo','checkout-of-r'); exit $LASTEXITCODE") && !cmd.join(' ').includes('abc'), cmd.join(' '));
  check('psQuote: a value cannot end the quoted string (straight and curly quotes doubled; $ and backtick stay literal)',
    psQuote("a'b’c") === "'a''b’’c'" && psQuote('$x `y') === "'$x `y'", psQuote("a'b’c"));
}

// One real run: a test-double station in a scratch root, through the real scripts/run-bounded.ps1.
async function testRealStation() {
  const pw = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8', timeout: 30000 });
  if (process.platform !== 'win32' || pw.status !== 0) { skip('stations: a real station run through run-bounded.ps1', process.platform !== 'win32' ? 'run-bounded uses a Windows Job Object' : 'pwsh not found'); return; }
  const root = tmp('root');
  try {
    fs.mkdirSync(path.join(root, 'scripts')); fs.mkdirSync(path.join(root, 'kitchen', 'stations'), { recursive: true });
    fs.copyFileSync(path.join(repo, 'scripts', 'run-bounded.ps1'), path.join(root, 'scripts', 'run-bounded.ps1'));
    fs.writeFileSync(path.join(root, 'kitchen', 'stations', 'ci-wait.ps1'), "param([string]$Repo = '')\nWrite-Output \"ci-wait double: repo=$Repo job=$env:KITCHEN_JOB\"\nexit 11\n");
    const r = await stationActivities({ mode: 'shadow', root })['ci-wait'](act('ci-wait', { Alias: 'J9001', Repo: 'example-checkout' }));
    check('stations: a real run through run-bounded passes -Repo and KITCHEN_JOB and keeps the station\'s exit (11)', r.exit === 11 && /repo=example-checkout job=J9001/.test(r.out), `exit ${r.exit}: ${r.out.trim().slice(-200)}`);
    fs.writeFileSync(path.join(root, 'kitchen', 'stations', 'ci-wait.ps1'), "param([string]$Repo = '')\nStart-Sleep -Seconds 60\n");
    const slow = await stationActivities({ mode: 'shadow', root })['ci-wait'](makeActivity({ wo: 'WO-2101', name: 'ci-wait', args: { Alias: 'J9001' }, idempotencyKey: 'WO-2101:ci-wait:slow', timeoutSec: 3, maxMB: 256 }));
    check('stations: run-bounded\'s time limit comes back as exit 124', slow.exit === 124, `exit ${slow.exit}: ${slow.out.trim().slice(-200)}`);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

export async function run() { await testContract(); await testOnce(); await testStationRefusals(); await testRealStation(); }
