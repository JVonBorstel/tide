// Owns the child process of the engine kill tests: one in-process engine (core/engine/fake.mjs) on a scratch folder, driven once, with
// test-double activities whose behaviour comes from the environment. The parent (test-runner.mjs) kills it mid-step and starts it again.
//   node tests/core/engine/fake-child.mjs <folder> <WO> <start|drive|signal-yes>
// Env: CLOCK (ISO time the engine sees), CI_EXITS (ci-wait exit codes, one per run, e.g. "11,0"), CRASH (during | after-store: write
// <folder>/<CRASH>.marker, then hang until killed). Prints one JSON line: the drive result's status and why.
import fs from 'node:fs'; import path from 'node:path';
import { createFakeEngine } from '../../../core/engine/fake.mjs';
import { result } from '../../../core/engine/activity.mjs';
import { CREATED, H1, PR } from './lib.mjs';

const [dir, wo, mode] = process.argv.slice(2);
const hang = (what) => { fs.writeFileSync(path.join(dir, `${what}.marker`), String(process.pid)); setInterval(() => {}, 1000); return new Promise(() => {}); };
const count = (name) => { const f = path.join(dir, `${name}.count`); const n = (fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8')) : 0) + 1; fs.writeFileSync(f, String(n)); return n; };
const exits = String(process.env.CI_EXITS || '0').split(',').map(Number);
const impls = {
  'ci-wait': async () => {
    const n = count('ci-wait');
    if (process.env.CRASH === 'during') await hang('during');
    return result(exits[Math.min(n, exits.length) - 1], `example ci-wait run ${n}`);
  },
  merge: async () => { count('merge'); return result(0, 'example merge'); },
  docs: async () => { count('docs'); return result(0, '{"dod":{"change-note":"yes"}}'); },
};
// after-store blocks the thread itself (the hook is synchronous), so nothing after the stored result can run before the kill.
const block = () => { fs.writeFileSync(path.join(dir, 'after-store.marker'), String(process.pid)); for (;;) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000); };
const hooks = process.env.CRASH === 'after-store' ? { afterStore: (r) => { if (/ci-wait/.test(r.out)) block(); } } : {};
const clock = () => new Date(process.env.CLOCK || '2030-01-07T09:00:00Z');
const eng = createFakeEngine({ dir, impls, hooks, clock, usage: () => ({ known: true, used: 0.1, why: 'example 10 %' }) });
const at = clock().toISOString();
let r;
if (mode === 'start') {
  await eng.start(wo, CREATED);
  await eng.signal(wo, { kind: 'pr.opened', actor: 'github', data: { pr: PR, branch: 'wo/2101-example', base: 'main', head: H1 }, at });
  r = await eng.signal(wo, { kind: 'review.verdict', actor: 'crew:verifier-1', data: { verdict: 'ship', reasons: 'example', head: H1, reviewer: 'crew:verifier-1', builder: 'crew:builder-1' }, at });
} else if (mode === 'signal-yes') {
  const card = (await eng.query(wo)).cards.merge;
  r = await eng.signal(wo, { kind: 'decision.answered', actor: 'jordan', data: { decision: card, answer: 'Yes', via: 'board' }, at });
} else r = await eng.drive(wo);
console.log(JSON.stringify({ status: r.status, why: r.why, stage: r.state.stage, state: r.state.state }));
