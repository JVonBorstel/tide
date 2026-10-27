// Owns the tests of the Temporal binding (core/engine/temporal/*). Two parts:
//   always: the parts that need no Temporal (activities over a memory log, the worker's argument and address checks, the refusal
//           with the install card's reason when Temporal is missing);
//   with Temporal installed (Jordan's taps, core/engine/temporal/INSTALL.md): the runner's acceptance lines on a real dev server in a
//           scratch folder: kill the worker mid-wait and restart it (the tech-scan spike), a timer that fires after a restart (about
//           2 minutes: ci-wait's poll), and a signal that wakes a waiting order. Without Temporal each one is SKIPPED, saying why.
// UNVERIFIED until the install: the Temporal part has never run on this PC (no temporal CLI, no @temporalio packages on 2026-10-26).
// Called by tests/core/engine/test-engine.mjs. Every process it starts is killed in finally.
import fs from 'node:fs'; import net from 'node:net'; import path from 'node:path'; import { spawn, spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { temporalStatus, openEngine, ADAPTER_METHODS } from '../../../core/engine/engine.mjs';
import { createActivities } from '../../../core/engine/temporal/activities.mjs';
import { parseArgs } from '../../../core/engine/temporal/worker.mjs';
import { memorySink } from '../../../core/engine/events.mjs';
import { memoryStore } from '../../../core/engine/activity.mjs';
import { check, skip, tmp, CREATED, H1, PR } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const workerJs = path.join(repo, 'core/engine/temporal/worker.mjs');
const ACCEPTANCE = ['temporal: kill the worker mid-wait, restart it, the order resumes (spike)', 'temporal: a timer fires after a worker restart', 'temporal: a signal wakes a waiting order'];

async function testWithout() {
  const sink = memorySink(); const acts = createActivities({ sink, store: memoryStore(), impls: {}, usage: () => ({ known: true, used: 0.1, why: 'x' }), clock: () => new Date('2030-01-07T09:00:00Z') });
  sink.append({ at: '2030-01-07T09:00:00Z', actor: 'engine', kind: 'wo.created', wo: 'WO-2101', data: CREATED, proof: null });
  const r = await acts.runCommand('WO-2101', { do: 'ask', why: 'x', decision: { kind: 'merge', ask: 'Merge example#41?', options: ['Yes', 'Hold', 'No'], recommended: 'Yes', why: 'x' } });
  const t = await acts.addTimer('WO-2101', 60, 'example');
  check('temporal activities: runCommand and addTimer write the same contract events as the fake engine (no Temporal needed)',
    r.events[0].kind === 'decision.asked' && r.events[0].data.decision.id === 'D-1' && t.kind === 'x.engine.timer' && (await acts.loadEvents('WO-2101')).length === 3);
  check('temporal worker: refuses an address that is not this PC', /not this PC/.test(parseArgs(['--state', 'x', '--address', '203.0.113.5:7233']).error || ''));
  check('temporal worker: needs --state, accepts a loopback address', /--state/.test(parseArgs([]).error || '') && !parseArgs(['--state', 'x', '--address', 'localhost:7233']).error);
  const st = await temporalStatus();
  if (!st.ok) {
    const wd = tmp('worker');
    const w = spawnSync(process.execPath, [workerJs, '--state', wd], { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(wd, { recursive: true, force: true });
    check('temporal worker: without the packages it exits 3 and names INSTALL.md', w.status === 3 && /INSTALL\.md/.test(w.stdout), `exit ${w.status}: ${w.stdout.trim().slice(0, 200)}`);
    let msg = ''; try { await openEngine({ kind: 'temporal', state: 'x' }); } catch (err) { msg = err.message; }
    check('openEngine temporal: refuses with what is missing and the install card', /not available/.test(msg) && /INSTALL\.md/.test(msg), msg.slice(0, 200));
  }
  return st;
}

const freePort = () => new Promise((resolve) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); }); });
const until = async (fn, ms, step = 500) => { const end = Date.now() + ms; for (;;) { const v = await fn(); if (v || Date.now() > end) return v; await new Promise((r) => setTimeout(r, step)); } };
const count = (dir, n) => { const f = path.join(dir, `${n}.count`); return fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8')) : 0; };

async function testWith() {
  const dir = tmp('temporal'); const procs = [];
  const port = await freePort(); const address = `127.0.0.1:${port}`; const queue = `tide-test-${process.pid}`;
  const startWorker = () => { const p = spawn(process.execPath, [workerJs, '--state', dir, '--address', address, '--queue', queue, '--impls', path.join(repo, 'tests/core/engine/temporal-impls.mjs')], { stdio: 'ignore' }); procs.push(p); return p; };
  let eng;
  try {
    procs.push(spawn('temporal', ['server', 'start-dev', '--headless', '--port', String(port), '--db-filename', path.join(dir, 'temporal.db'), '--log-level', 'error'], { stdio: 'ignore' }));
    await until(() => new Promise((r) => { const c = net.connect(port, '127.0.0.1', () => { c.end(); r(true); }); c.on('error', () => r(false)); }), 30000);
    let worker = startWorker();
    eng = await openEngine({ kind: 'temporal', state: dir, address, queue });
    check(`adapter: the Temporal engine has every adapter method (${ADAPTER_METHODS.join(', ')})`, ADAPTER_METHODS.every((m) => typeof eng[m] === 'function'));
    const toJordan = async (wo) => {
      await eng.start(wo, CREATED);
      await eng.signal(wo, { kind: 'pr.opened', actor: 'github', data: { pr: PR, branch: 'wo/2101-example', base: 'main', head: H1 } });
      await eng.signal(wo, { kind: 'review.verdict', actor: 'crew:verifier-1', data: { verdict: 'ship', reasons: 'x', head: H1, reviewer: 'crew:verifier-1', builder: 'crew:builder-1' } });
      return until(async () => (await eng.query(wo)).stage === 'jordan', 60000);
    };
    const reached = await toJordan('WO-2101');
    worker.kill('SIGKILL'); worker = startWorker();
    const card = (await eng.query('WO-2101')).cards.merge;
    await eng.signal('WO-2101', { kind: 'decision.answered', actor: 'jordan', data: { decision: card, answer: 'Yes', via: 'board' } });
    const done = await until(async () => (await eng.query('WO-2101')).state === 'shipped', 60000);
    check(ACCEPTANCE[0], reached && done && count(dir, 'merge') === 1, `reached jordan ${reached}, shipped ${done}, merges ${count(dir, 'merge')}`);
    check(ACCEPTANCE[2], done, 'the Yes signal did not move the order to shipped within 60 s');
    fs.writeFileSync(path.join(dir, 'ci-exits.txt'), '11,0'); const before = count(dir, 'ci-wait');
    const p2 = toJordan('WO-2102');
    await until(() => count(dir, 'ci-wait') > before, 60000);
    worker.kill('SIGKILL'); worker = startWorker();
    const timed = await until(async () => (await eng.query('WO-2102')).stage === 'jordan', 240000, 2000);
    await p2;
    check(ACCEPTANCE[1], timed && count(dir, 'ci-wait') - before === 2, `stage jordan ${timed}; ci-wait runs ${count(dir, 'ci-wait') - before}`);
  } finally {
    if (eng) await eng.close().catch(() => {});
    for (const p of procs) p.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
  }
}

export async function run() {
  const st = await testWithout();
  if (!st.ok) { for (const name of ACCEPTANCE) skip(name, st.why); return; }
  await testWith();
}
