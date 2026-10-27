// Owns the tests of the in-process engine (core/engine/fake.mjs + driver.mjs + events.mjs) against the runner's acceptance lines:
// a crash mid-step resumes exactly once (real kill tests on a child process), a timer fires after a restart, a signal wakes a waiting
// order, backoff caps; plus the governor gate on heavy steps, the event log's crash safety and the adapter shape.
// Called by tests/core/engine/test-engine.mjs. Child processes: tests/core/engine/fake-child.mjs, each killed or finished within 20 s.
import fs from 'node:fs'; import path from 'node:path'; import { spawn, spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { createFakeEngine } from '../../../core/engine/fake.mjs';
import { fileSink, memorySink } from '../../../core/engine/events.mjs';
import { backoffSec, MAX_RETRIES } from '../../../core/engine/wo.mjs';
import { result } from '../../../core/engine/activity.mjs';
import { ADAPTER_METHODS } from '../../../core/engine/engine.mjs';
import { check, tmp, CREATED, H1, PR } from './lib.mjs';

const child = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fake-child.mjs');
const WO = 'WO-2101';
const events = (dir) => fileSink(path.join(dir, 'events.jsonl')).all();
const kinds = (dir, kind, step) => events(dir).filter((e) => e.kind === kind && (!step || e.data.step === step)).length;
const count = (dir, name) => { const f = path.join(dir, `${name}.count`); return fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8')) : 0; };
const runChild = (dir, mode, env = {}) => {
  const r = spawnSync(process.execPath, [child, dir, WO, mode], { encoding: 'utf8', timeout: 20000, env: { ...process.env, ...env } });
  try { return JSON.parse(r.stdout.trim().split('\n').pop()); } catch { return { status: 'child failed', why: `${r.status} ${r.stderr.slice(-300)}` }; }
};
// Start the child with CRASH set, wait for its marker (it is now inside the step), kill it hard, and say whether it was killed.
async function killMidStep(dir, crash, env = {}, mode = 'start') {
  const p = spawn(process.execPath, [child, dir, WO, mode], { env: { ...process.env, ...env, CRASH: crash }, stdio: 'ignore' });
  const marker = path.join(dir, `${crash}.marker`);
  for (let i = 0; i < 400 && !fs.existsSync(marker); i++) await new Promise((r) => setTimeout(r, 50));
  const reached = fs.existsSync(marker);
  p.kill('SIGKILL');
  await new Promise((r) => (p.exitCode !== null || p.signalCode !== null ? r() : p.once('exit', r)));
  return reached;
}

async function testKill() {
  for (const crash of ['after-store', 'during']) {
    const dir = tmp(`kill-${crash}`);
    try {
      const reached = await killMidStep(dir, crash);
      // Proof the kill landed mid-step: the step was started and nothing recorded its end before the restart.
      const mid = kinds(dir, 'step.started', 'ci-wait') === 1 && kinds(dir, 'step.done', 'ci-wait') === 0;
      check(`kill test (${crash}): the kill landed mid-step (started, not finished, in the log)`, reached && mid, `marker ${reached}; done ${kinds(dir, 'step.done', 'ci-wait')}`);
      const after = runChild(dir, 'drive');
      const effects = count(dir, 'ci-wait');
      const once = kinds(dir, 'step.started', 'ci-wait') === 1 && kinds(dir, 'step.done', 'ci-wait') === 1 && kinds(dir, 'ci.result') === 1;
      const want = crash === 'after-store' ? 1 : 2; // killed after the result was stored: replayed, not rerun; killed during: the unfinished run is redone
      check(`kill test (${crash}): a crash mid-step resumes and is recorded exactly once (one step.started, one step.done, one ci.result; ${want} run(s) of this read-only step)`,
        reached && once && effects === want && after.stage === 'jordan', `marker ${reached}; started ${kinds(dir, 'step.started', 'ci-wait')} done ${kinds(dir, 'step.done', 'ci-wait')} ci ${kinds(dir, 'ci.result')}; runs ${effects}; ${JSON.stringify(after)}`);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }
}

// A crash during a merge (a step that changes things): the restart probes the outside world and never merges twice.
async function testKillMerge() {
  const cases = [
    ['merge-after-effect', {}, 'done', 1, 'shipped'],     // merged, then killed before the result was stored: probe says done, no second merge
    ['merge-before-effect', {}, 'not-done', 1, 'shipped'], // killed before the merge happened: probe says not done, it runs once
    ['merge-after-effect', { PROBE: 'none' }, 'held', 1, 'stuck'], // no way to check: held for Jordan with a card, never merged twice
  ];
  for (const [crash, env, want, merges, state] of cases) {
    const dir = tmp(`kill-${crash}`);
    try {
      runChild(dir, 'start', env);
      const reached = await killMidStep(dir, crash, env, 'signal-yes');
      const after = runChild(dir, 'drive', env);
      const asked = events(dir).filter((e) => e.kind === 'decision.asked').map((e) => e.data.decision.kind);
      check(`kill during merge (${crash}${env.PROBE ? ', no probe' : ''}): the restart ${want === 'held' ? 'holds it with a re-plan-or-drop card' : `probes (${want})`} and the merge happens ${merges} time(s) in all`,
        reached && count(dir, 'merge') === merges && kinds(dir, 'merged') === (state === 'shipped' ? 1 : 0) && after.state === state && (state !== 'stuck' || asked.includes('question')),
        `marker ${reached}; merges ${count(dir, 'merge')}; merged events ${kinds(dir, 'merged')}; ${JSON.stringify(after)}; cards ${asked.join()}`);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }
}

async function testTimer() {
  const dir = tmp('timer');
  try {
    const first = runChild(dir, 'start', { CI_EXITS: '11,0', CLOCK: '2030-01-07T09:00:00Z' });
    const early = runChild(dir, 'drive', { CI_EXITS: '11,0', CLOCK: '2030-01-07T09:01:00Z' });
    const late = runChild(dir, 'drive', { CI_EXITS: '11,0', CLOCK: '2030-01-07T09:02:01Z' });
    check('timer: a timer set before a restart fires after it (new process, clock past due), and the step runs again',
      first.status === 'timer' && early.status === 'timer' && late.stage === 'jordan' && kinds(dir, 'x.engine.timer') === 1 && count(dir, 'ci-wait') === 2,
      `${JSON.stringify(first)} | ${early.status} | ${JSON.stringify(late)}; timers ${kinds(dir, 'x.engine.timer')}; runs ${count(dir, 'ci-wait')}`);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

async function testSignal() {
  const dir = tmp('signal');
  try {
    const waiting = runChild(dir, 'start');
    const woke = runChild(dir, 'signal-yes');
    const merges = events(dir).filter((e) => e.kind === 'merged');
    check('signal: Jordan\'s Yes (a signal from another process) wakes the waiting order, which merges once, runs docs and closes',
      waiting.status === 'waiting' && waiting.stage === 'jordan' && woke.status === 'done' && woke.state === 'shipped' && count(dir, 'merge') === 1 && merges.length === 1 && merges[0].data.decision === 'D-1',
      `${JSON.stringify(waiting)} -> ${JSON.stringify(woke)}; merges ${count(dir, 'merge')}`);
    const dropped = events(dir).filter((e) => e.kind === 'decision.asked').map((e) => e.data.decision.id);
    check('signal: decision ids are handed out by the log, one per card (D-1)', dropped.join() === 'D-1', dropped.join());
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

async function testBackoff() {
  const seq = Array.from({ length: 12 }, (_, i) => backoffSec(i + 1));
  check('backoff caps: 60, 120, 240 ... never above 3600 s, never shrinking', seq[0] === 60 && seq[1] === 120 && seq[2] === 240 && Math.max(...seq) === 3600 && seq.every((x, i) => i === 0 || x >= seq[i - 1]), seq.join());
  check('backoff caps: a custom cap holds (base 30, cap 100)', backoffSec(5, { base: 30, cap: 100 }) === 100 && backoffSec(0) === 0);
  let clock = new Date('2030-01-07T09:00:00Z'); let n = 0;
  const eng = createFakeEngine({ clock: () => clock, usage: () => ({ known: true, used: 0.1, why: 'x' }), impls: { 'ci-wait': async () => { n++; return result(n === 1 ? 124 : 0, 'example'); } } });
  await eng.start(WO, CREATED);
  await eng.signal(WO, { kind: 'pr.opened', actor: 'github', data: { pr: PR, branch: 'wo/2101-example', base: 'main', head: H1 } });
  const r = await eng.signal(WO, { kind: 'review.verdict', actor: 'crew:verifier-1', data: { verdict: 'ship', reasons: 'x', head: H1, reviewer: 'crew:verifier-1', builder: 'crew:builder-1' } });
  check(`backoff caps: a failed step (exit 124) waits backoffSec(1) = ${backoffSec(1)} s before retry 1 of ${MAX_RETRIES}`, r.status === 'timer' && Date.parse(r.due || '') - clock.getTime() === backoffSec(1) * 1000, JSON.stringify({ status: r.status, due: r.due }));
  clock = new Date(clock.getTime() + 61000);
  const after = await eng.drive(WO);
  check('backoff caps: after the backoff the step runs again and the order moves on', after.state.stage === 'jordan' && n === 2, `${after.state.stage} runs ${n}`);
}

async function testGovernorGate() {
  const at = (used) => createFakeEngine({ usage: () => (used === null ? { known: false, why: 'no file' } : { known: true, used, why: `${used * 100} %` }), clock: () => new Date('2030-01-07T09:00:00Z') });
  const high = at(0.8); const hr = await high.start(WO, CREATED);
  check('governor gate: above 70 % a heavy step (build) is held, not started, and the hold is an event with the reason',
    hr.status === 'held' && hr.state.runs.build === undefined && /70 %/.test(hr.why), JSON.stringify({ s: hr.status, why: hr.why }));
  const unknown = at(null); const ur = await unknown.start(WO, CREATED);
  check('governor gate: unknown usage holds the heavy step too', ur.status === 'held' && /unknown/.test(ur.why), ur.why);
  const low = at(0.2); const lr = await low.start(WO, CREATED);
  check('governor gate: under 70 % the heavy step starts (and, with no crew runner yet, waits for lane L3 instead of failing)',
    lr.state.runs.build === 1 && lr.state.retries === 0 && /L3/.test(lr.why), JSON.stringify({ s: lr.status, why: lr.why }));
}

async function testLogAndShape() {
  const dir = tmp('log');
  try {
    const file = path.join(dir, 'events.jsonl'); const sink = fileSink(file);
    sink.append({ at: '2030-01-07T09:00:00Z', actor: 'engine', kind: 'wo.created', wo: WO, data: CREATED, proof: null });
    fs.appendFileSync(file, '{"v":"1.0","seq":2,"half');
    const e = sink.append({ at: '2030-01-07T09:01:00Z', actor: 'engine', kind: 'x.engine.timer', wo: WO, data: { sec: 1 }, proof: null });
    check('event log: a half-written last line (a crash mid-append) is cut off; the next append follows the last whole line', e.seq === 2 && sink.all().length === 2, `seq ${e.seq}, lines ${sink.all().length}`);
    let msg = ''; try { sink.append({ at: 'x', actor: 'engine', kind: 'wo.created', wo: WO, data: {}, proof: null }); } catch (err) { msg = err.message; }
    check('event log: an event the contract refuses is never written', /not valid/.test(msg) && sink.all().length === 2, msg.slice(0, 120));
    check('event log: no lock file left behind', !fs.existsSync(`${file}.lock`));
    // A brand-new state folder (the first real Temporal run hit ENOENT here): the lock's folder is made before the lock is taken.
    const fresh = fileSink(path.join(dir, 'new-state', 'engine', 'events.jsonl'));
    const firstId = fresh.nextDecisionId(); const firstEv = fresh.append({ at: '2030-01-07T09:00:00Z', actor: 'engine', kind: 'wo.created', wo: WO, data: CREATED, proof: null });
    check('event log: a first decision id and a first append into a folder that does not exist yet both work (no ENOENT)', firstId === 'D-1' && firstEv.seq === 1 && fresh.all().length === 1);
    const timer = (n, at = '2030-01-07T09:03:00Z') => ({ at, actor: 'engine', kind: 'x.engine.timer', wo: WO, data: { sec: n }, proof: null });
    let batchErr = ''; try { sink.appendAll([timer(1), { ...timer(2), at: 'bad' }]); } catch (err) { batchErr = err.message; }
    const two = sink.appendAll([timer(3), timer(4)]);
    check('event log: appendAll writes all or none (one bad event writes nothing), with seq in order', /not valid/.test(batchErr) && two.map((x) => x.seq).join() === '3,4' && sink.all().length === 4,
      `${batchErr.slice(0, 60)}; ${sink.all().length} lines`);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  const eng = createFakeEngine({ sink: memorySink() });
  check(`adapter: the fake engine has every adapter method (${ADAPTER_METHODS.join(', ')})`, ADAPTER_METHODS.every((m) => typeof eng[m] === 'function'));
  const loop = createFakeEngine({ maxSteps: 1, usage: () => ({ known: true, used: 0.1, why: 'x' }), impls: { build: async () => result(0, 'built') } });
  const r = await loop.start(WO, CREATED);
  check('drive never loops forever: past maxSteps it stops and says why', r.status === 'stopped' && /maxSteps|more than 1 steps/.test(r.why), r.why);
}

export async function run() { await testKill(); await testKillMerge(); await testTimer(); await testSignal(); await testBackoff(); await testGovernorGate(); await testLogAndShape(); }
