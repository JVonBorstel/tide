// @ts-check
// Owns carrying out one lifecycle command (core/engine/wo.mjs next()) for one work order: run an activity at most once, ask a card,
// close, or drop, and append the contract events that record it. Engine-neutral: the in-process fake (fake.mjs) calls it directly and
// the Temporal worker calls it inside one activity (temporal/activities.mjs), so both engines write the same events for the same step.
// Waiting (timers, Jordan's tap) is not here: that is the engine's job (a timer table in the fake, sleep/condition in Temporal).
// Called by core/engine/fake.mjs, core/engine/temporal/activities.mjs and tests/core/engine/*.
import { reduce, classify, MAX_RETRIES } from './wo.mjs';
import { makeActivity, once, result } from './activity.mjs';
import { makeDecision } from './cards.mjs';
import { decide } from './governor.mjs';

/** @typedef {import('./wo.mjs').Command} Command */ /** @typedef {import('./wo.mjs').WoState} WoState */
/** @typedef {import('./events.mjs').Sink} Sink */ /** @typedef {import('./events.mjs').Event} Event */
/**
 * @typedef {{ sink: Sink, store: import('./activity.mjs').Store, impls: Record<string, import('./activity.mjs').Impl>,
 *   usage: () => import('./governor.mjs').Usage, clock?: () => Date, hour?: () => number, hooks?: { afterStore?: (r: any) => void },
 *   limits?: Record<string, { timeoutSec: number, maxMB: number }> }} Ports
 */

// Which lane builds an activity this engine does not have yet; the step waits (exit 127) and says so instead of failing.
const OWNER = { build: 'lane L3 (crews)', review: 'lane L3 (verifier crews)', docs: 'lane L4 (docs station)' };
const lastLine = (t) => (String(t || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean).pop() || '').slice(0, 1990);

// A step.started with no step.done or step.failed after it is a step a crash interrupted: resume it with the same idempotency key.
function pendingStart(events, step, attempt) {
  let open = null;
  for (const e of events) {
    if (e.data && e.data.step !== step) continue;
    if (e.kind === 'step.started' && e.data.attempt === attempt) open = e;
    if ((e.kind === 'step.done' || e.kind === 'step.failed') && open && e.data.attempt === attempt) open = null;
  }
  return open;
}

// The docs station may print one JSON line {"dod": {...}} as its last word; anything else is an empty checklist (nothing claimed).
function dodOf(out) {
  try { const j = JSON.parse(lastLine(out)); if (j && typeof j.dod === 'object') return j.dod; } catch { /* not a JSON line */ }
  return {};
}

/** The contract events one activity result means. Pure. @param {WoState} s @param {any} cmd @param {any} r */
export function resultEvents(s, cmd, r, sec = 0) {
  const base = { step: cmd.name, attempt: cmd.attempt };
  const c = classify(r.exit);
  const ev = (kind, data, proof = r.proof ?? null) => ({ kind, data, proof });
  if (cmd.name === 'ci-wait' && (c === 'ok' || r.exit === 1)) {
    return [ev('step.done', { ...base, exit: r.exit, sec }), ev('ci.result', { ...(s.pr ? { pr: s.pr } : {}), head: s.head, conclusion: c === 'ok' ? 'success' : 'failure' })];
  }
  if (c === 'ok' || c === 'later') {
    const out = [ev('step.done', { ...base, exit: r.exit, sec })];
    if (c === 'ok' && cmd.name === 'merge') out.push(ev('merged', { pr: s.pr, sha: s.head, decision: cmd.args.Decision }, r.proof || `merge activity exit 0 (${cmd.args.Decision})`));
    if (c === 'ok' && cmd.name === 'docs') out.push(ev('docs.done', { dod: dodOf(r.out) }));
    return out;
  }
  const retry = c === 'failed' && s.retries < MAX_RETRIES;
  return [ev('step.failed', { ...base, exit: r.exit, reason: lastLine(r.out) || `exit ${r.exit}`, retry })];
}

/**
 * Carry out one command. Returns { events } (appended), or { hold } when the governor says not now (with retrySec).
 * @param {Command} cmd @param {Ports} p
 */
export async function execute(wo, cmd, p) {
  const clock = p.clock || (() => new Date());
  const at = () => clock().toISOString();
  const add = (e) => p.sink.append({ at: at(), actor: 'engine', wo, proof: null, ...e });
  const events = p.sink.forWo(wo);
  const s = reduce(events, wo);
  if (cmd.do === 'ask') {
    const decision = makeDecision({ ...cmd.decision, id: p.sink.nextDecisionId(), wo, at: at() });
    return { events: [add({ kind: 'decision.asked', data: { decision } })] };
  }
  if (cmd.do === 'close') return { events: [add({ kind: 'closed', data: { sha: cmd.sha }, proof: `merged at ${cmd.sha}` })] };
  if (cmd.do === 'drop') return { events: [add({ kind: 'dropped', data: { reason: s.why.slice(0, 2000), decision: cmd.decision } })] };
  if (cmd.do !== 'activity') return { events: [] };
  const pending = pendingStart(events, cmd.name, cmd.attempt);
  if (!pending && cmd.heavy) {
    const v = decide('heavy', p.usage(), { now: clock(), hour: p.hour ? p.hour() : clock().getHours() });
    if (!v.go) return { hold: v, events: [add({ kind: 'x.engine.governor', data: { step: cmd.name, verdict: v.verdict, why: v.why, retrySec: v.retrySec } })] };
  }
  const key = pending ? pending.data.idempotencyKey : `${wo}:${cmd.name}:a${cmd.attempt}:r${(s.runs[cmd.name] || 0) + 1}`;
  const lim = (p.limits && p.limits[cmd.name]) || {};
  const a = makeActivity({ wo, name: cmd.name, args: cmd.args, idempotencyKey: key, ...lim });
  const started = pending ? [] : [add({ kind: 'step.started', data: { step: cmd.name, attempt: cmd.attempt, idempotencyKey: key } })];
  const impl = p.impls[cmd.name] || (async () => result(127, `no activity named ${cmd.name} in this engine yet (${OWNER[cmd.name] || 'not assigned'})`));
  const t0 = clock().getTime();
  const { result: r, replayed } = await once(a, impl, p.store, p.hooks);
  const sec = Math.max(0, (clock().getTime() - t0) / 1000);
  return { replayed, result: r, events: [...started, ...resultEvents(s, cmd, r, sec).map(add)] };
}
