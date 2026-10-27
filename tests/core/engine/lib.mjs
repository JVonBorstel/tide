// Owns the engine tests' shared pieces: a check() that counts, and a synthetic event log builder whose every event is validated
// against core/contracts/event.schema.json (so the tests never feed the lifecycle a shape the contract refuses).
// All data is invented (WO-2101, example#41, example-owner/example-repo, 2030 dates), like the contract fixtures.
// Called by tests/core/engine/test-*.mjs.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
import { validate } from '../../../core/contracts/validate.mjs';
import { makeDecision } from '../../../core/engine/cards.mjs';

export const results = [];
export function check(name, pass, detail = '') { results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass }); return !!pass; }
export function skip(name, why) { results.push({ name: `${name} (skipped: ${why})`, pass: true, skipped: true }); }
export const H1 = 'aaaaaaa1'; export const H2 = 'bbbbbbb2';
export const PR = 'example#41';
export const CREATED = { goal: 'Example: the demo list says Nothing yet when empty', stream: 'DEMO', repo: 'example-owner/example-repo', alias: 'J9001' };
export const tmp = (tag) => fs.mkdtempSync(path.join(os.tmpdir(), `tide-engine-${tag}-`));

// A builder: log().created().opened(H1)... ; .events is the list; each call appends one contract-valid event.
export function log(wo = 'WO-2101') {
  const events = []; let n = 0;
  const add = (kind, data, actor = 'engine', proof = null) => {
    n++;
    const e = { v: '1.0', seq: n, at: `2030-01-07T09:${String(n % 60).padStart(2, '0')}:00Z`, actor, kind, wo, data, proof };
    const r = validate('event', e);
    if (!r.ok) throw new Error(`test event ${kind} is not valid: ${r.errors.join('; ')}`);
    events.push(e); return api;
  };
  const card = (id, kind, options) => makeDecision({ id, wo, kind, ask: `Example ${kind} card?`, options, recommended: options[0], at: '2030-01-07T09:00:00Z' });
  const api = {
    events, wo,
    created: (data = CREATED) => add('wo.created', data),
    opened: (head = H1) => add('pr.opened', { pr: PR, branch: 'wo/2101-example', base: 'main', head }),
    pushed: (head, why = 'push') => add('pr.updated', { pr: PR, head, why }, 'github'),
    verdict: (verdict, head = H1, reviewer = 'crew:verifier-1') => add('review.verdict', { verdict, reasons: `example ${verdict}`, head, reviewer, builder: 'crew:builder-1' }, reviewer),
    ci: (conclusion, head = H1) => add('ci.result', { pr: PR, head, conclusion }, 'github'),
    askMerge: (id = 'D-1') => add('decision.asked', { decision: card(id, 'merge', ['Yes', 'Hold', 'No']) }),
    askStuck: (id = 'D-2') => add('decision.asked', { decision: card(id, 'question', ['Re-plan', 'Drop']) }),
    answer: (id, answer, note = null) => add('decision.answered', { decision: id, answer, note, via: 'board' }, 'jordan'),
    merged: (sha = H1, decision = 'D-1') => add('merged', { pr: PR, sha, ...(decision ? { decision } : {}) }, 'engine', `merge of ${sha}`),
    docs: () => add('docs.done', { dod: { 'change-note': 'yes' } }),
    closed: (sha = H1) => add('closed', { sha }, 'engine', `merged at ${sha}`),
    started: (step, attempt = 1) => add('step.started', { step, attempt, idempotencyKey: `${wo}:${step}:a${attempt}:r1` }),
    done: (step, exit = 0, attempt = 1) => add('step.done', { step, attempt, exit }),
    failed: (step, exit = 1, attempt = 1) => add('step.failed', { step, attempt, exit, reason: `example ${step} failure`, retry: true }),
    timer: () => add('x.engine.timer', { sec: 60 }),
    unblock: () => add('x.engine.unblock', { reason: 'example piece landed' }),
    dropped: (decision = 'D-2') => add('dropped', { reason: 'example', decision }),
    replaced: () => add('replaced', { by: 'WO-2102', reason: 'example' }),
  };
  return api;
}

// Print the counts line every Tide suite ends with, then exit 1 on any failure.
export function finish(title) {
  for (const r of results) console.log(`${r.pass ? (r.skipped ? 'SKIP' : 'ok  ') : 'FAIL'} ${r.name}`);
  const failed = results.filter((r) => !r.pass).length; const skipped = results.filter((r) => r.skipped).length;
  console.log(`${title}: ${results.length - failed - skipped} passed, ${failed} failed, ${skipped} skipped`);
  process.exitCode = failed ? 1 : 0;
}
