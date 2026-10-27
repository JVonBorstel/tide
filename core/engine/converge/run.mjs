// @ts-check
// Owns carrying out a convergence workflow's actions (workflows.mjs) under the yes rules of build-way 3.6 and section 9:
//   - an action that needs Jordan's yes runs only with a standing yes in the event log (a standing card of that kind and topic answered
//     Yes; only for the topics section 9 allows, YES[x].standing) or a one-off card for exactly that action answered Yes; otherwise it
//     creates one card (never two for the same action) and stops;
//   - heavy and bulk actions ask the governor first (governor.mjs), and at most LIMITS.maxHeavyPerTick of them start per tick;
//   - every run writes x.converge.intent BEFORE it starts (so BOUNDS count a run that throws or dies) and x.converge.<act> after it;
//     a run that throws is a failed run (exit 1), never a stop for the rest of the workflow; a dry run calls nothing, writes nothing;
//   - an action that changes things (EFFECTFUL) interrupted after its intent is probed first (done: recorded, not rerun; not done:
//     run; unknown or no probe: one card per interruption; Jordan's Yes runs it once, his No skips it);
//   - a card action (a bound's re-plan-or-drop, the morning card) acts on Jordan's answer: Re-plan starts a new round of tries
//     (x.converge.reset), any other answer is remembered and the action is skipped.
// Called by the engine's schedules (schedule.mjs), its command line (below: dry run only) and tests/core/engine/test-converge.mjs.
//   node core/engine/converge/run.mjs <workflow> --snapshot <json> [--events <events.jsonl>] [--now <ISO time>]
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { WORKFLOWS, LIMITS } from './workflows.mjs';
import { standingYes, cardsIn, makeDecision } from '../cards.mjs';
import { decide } from '../governor.mjs';

/** @typedef {import('./workflows.mjs').Action} Action */
/**
 * @typedef {{ events: any[], dryRun?: boolean, now?: Date, usage?: () => any, run?: (a: Action) => Promise<{ exit: number, out?: string }>,
 *   ask?: (d: { kind: string, wo: string|null, ask: string, options: string[], recommended: string, why: string }) => string,
 *   record?: (e: { kind: string, wo: string|null, data: any, proof: string|null }) => void,
 *   probe?: (a: Action) => Promise<{ state: 'done'|'not-done'|'unknown', why: string }>, budget?: { heavy: number } }} Ports
 */

export const cardAsk = (/** @type {Action} */ a) => (a.act === 'card' ? String(a.args && a.args.Ask) : `${a.yes ? a.yes.topic : a.act}: ${a.target}? (${a.why})`).slice(0, 300);
const optionsOf = (a) => (a.act === 'card' ? String(a.args && a.args.Options).split(',') : ['Yes', 'Hold', 'No']);
const keyOf = (/** @type {Action} */ a) => a.key || a.target;
/** The latest card asked with exactly this text: [id, { decision, answer, ... }] or null. */
const cardFor = (events, ask) => { const m = [...cardsIn(events)].filter(([, c]) => c.decision.ask === ask); return m.length ? m[m.length - 1] : null; };

// The yes for one action: standing (cited; only for topics that allow one), a one-off card answered Yes, a card still open, a card
// declined, or none yet.
export function yesFor(/** @type {Action} */ a, events) {
  if (!a.yes) return { state: 'not-needed' };
  if (a.yes.standing !== false) {
    const st = standingYes(events, a.yes.kind, a.yes.topic);
    if (st.yes) return { state: 'standing', decision: st.decision };
  }
  const last = cardFor(events, cardAsk(a));
  if (!last) return { state: 'none' };
  const [id, c] = last;
  if (c.answer === null) return { state: 'open', decision: id };
  return { state: c.answer === 'Yes' ? 'one-off' : 'declined', decision: id };
}

// A card action: ask once; while open, wait; once answered, act on the answer.
function cardAction(a, p, would) {
  const ask = cardAsk(a); const found = cardFor(p.events, ask);
  if (!found) {
    if (p.dryRun) return would('ask', a.why);
    const opts = optionsOf(a);
    const id = /** @type {any} */ (p.ask)({ kind: String(a.args && a.args.Kind), wo: a.wo, ask, options: opts, recommended: String((a.args && a.args.Recommended) || opts[0]), why: a.why.slice(0, 2000) });
    return would('ask', `${a.why}: card ${id}`);
  }
  const [id, c] = found;
  if (c.answer === null) return would('wait', `card ${id} is still open`);
  const resetAct = a.args && a.args.ResetAct;
  if (resetAct && c.answer === 'Re-plan') {
    if (p.events.some((e) => e.kind === 'x.converge.reset' && e.data && e.data.decision === id)) return would('skip', `Jordan said Re-plan on ${id}; that round has begun`);
    if (!p.dryRun && p.record) p.record({ kind: 'x.converge.reset', wo: a.wo, data: { workflow: a.workflow, act: String(resetAct), key: keyOf(a), target: a.target, decision: id }, proof: `Re-plan on ${id}` });
    return would('reset', `Jordan said Re-plan on ${id}: a new round of ${resetAct}`);
  }
  return would('skip', `Jordan answered ${c.answer} on ${id}`);
}

// After a crash between an effectful action's intent and its record: probe; else one card per interruption, and honour its answer.
// Returns null (go ahead and run, with the given reason) or a finished outcome.
async function afterInterruption(a, p, y, open, would) {
  let pr;
  try { pr = p.probe ? await p.probe(a) : { state: 'unknown', why: 'no probe for this action' }; } catch (err) { pr = { state: 'unknown', why: `the probe failed: ${/** @type {Error} */ (err).message}` }; }
  if (pr.state === 'not-done') return { go: 'interrupted earlier, and the probe says it never took effect' };
  if (pr.state === 'done') {
    const why = `interrupted earlier, and it had taken effect: ${pr.why}`;
    return { result: p.dryRun ? would('record', why) : finish(a, p, y, { exit: 0, out: pr.why }, why) };
  }
  const ask = `${a.act} ${a.target} was interrupted mid-run (#${open.seq}) and whether it took effect is unknown (${pr.why}). Run it again?`.slice(0, 300);
  const found = cardFor(p.events, ask);
  if (found && found[1].answer === null) return { result: would('wait', `the interrupted-run card ${found[0]} is still open`) };
  if (found && found[1].answer !== 'Yes') return { result: would('skip', `Jordan answered ${found[1].answer} on ${found[0]}: not run again`) };
  if (found) return { go: `Jordan said run it again on ${found[0]}` };
  if (p.dryRun) return { result: would('ask', ask) };
  const id = /** @type {any} */ (p.ask)({ kind: 'question', wo: a.wo, ask, options: ['Yes', 'No'], recommended: 'No', why: 'Running it twice could do it twice; check first.' });
  return { result: would('ask', `held, not run twice: card ${id}`) };
}

/** One action under the rules. @param {Action} a @param {Ports & { budget: { heavy: number } }} p */
async function one(a, p) {
  const now = p.now || new Date();
  const would = (outcome, why) => ({ ...a, outcome: p.dryRun ? `would ${outcome}` : outcome, because: why });
  if (a.act === 'card') return cardAction(a, p, would);
  const y = yesFor(a, p.events);
  if (y.state === 'open') return would('wait', `card ${y.decision} is still open`);
  if (y.state === 'declined') return would('skip', `Jordan answered no or hold on ${y.decision}`);
  if (y.state === 'none') {
    const why = `needs a yes (${a.yes && a.yes.kind}: ${a.yes && a.yes.topic})${a.yes && a.yes.standing === false ? ', one-off: a standing yes does not cover it' : ' and no standing yes is in the log'}`;
    if (p.dryRun) return would('ask', why);
    const id = /** @type {any} */ (p.ask)({ kind: /** @type {any} */ (a.yes).kind, wo: a.wo, ask: cardAsk(a), options: ['Yes', 'Hold', 'No'], recommended: 'Yes', why: a.why.slice(0, 2000) });
    return would('ask', `${why}: card ${id}`);
  }
  let because = y.state === 'standing' ? `standing yes ${y.decision}` : y.state === 'one-off' ? `Jordan said yes on ${y.decision}` : 'allowed without asking (build-way 3.6)';
  const open = EFFECTFUL.has(a.act) ? interrupted(a, p.events) : null;
  if (open) {
    const r = await afterInterruption(a, p, y, open, would);
    if (r.result) return r.result;
    because = r.go;
  }
  if (a.cls !== 'light') {
    if (p.budget.heavy <= 0) return would('hold', `at most ${LIMITS.maxHeavyPerTick} heavy or bulk starts per tick; this one waits for the next tick`);
    const v = decide(a.cls, (p.usage || (() => ({ known: false, why: 'no usage reader given' })))(), { now });
    if (!v.go) return would('hold', v.why);
  }
  if (p.dryRun) return would('run', because);
  if (a.cls !== 'light') p.budget.heavy--;
  // The attempt is recorded BEFORE the run: a run that throws, or a process that dies, still counts against BOUNDS.
  if (p.record) p.record({ kind: 'x.converge.intent', wo: a.wo, data: { workflow: a.workflow, act: a.act, key: keyOf(a), target: a.target }, proof: null });
  let r;
  try { r = await /** @type {any} */ (p.run)(a); } catch (err) { r = { exit: 1, out: `the run threw: ${/** @type {Error} */ (err).message}` }; }
  return finish(a, p, y, r, because);
}

function finish(a, p, y, r, because) {
  if (p.record) p.record({ kind: `x.converge.${a.act}`, wo: a.wo, data: { workflow: a.workflow, key: keyOf(a), target: a.target, exit: r.exit, because }, proof: y.decision ? `yes ${y.decision}` : null });
  return { ...a, outcome: r.exit === 0 ? 'ran' : `failed (exit ${r.exit})`, because, out: String(r.out || '').slice(-500) };
}

// Actions that change things outside the engine: after a crash between their intent and their record, a probe looks before any rerun.
export const EFFECTFUL = new Set(['freshen-pr', 'worktree-remove', 'pr-close', 'pickup-archive']);
// The last intent for this action's key with no x.converge.<act> after it (a crash came between the start and the record), or null.
export function interrupted(/** @type {Action} */ a, events) {
  let open = null; const key = keyOf(a);
  for (const e of events) {
    if (!e.data || (e.data.key ?? e.data.target) !== key) continue;
    if (e.kind === 'x.converge.intent' && e.data.act === a.act) open = e;
    if (e.kind === `x.converge.${a.act}`) open = null;
  }
  return open;
}

/**
 * Plan a workflow on a snapshot and carry out (or, with dryRun, only describe) its actions. Each action is tried on its own: one that
 * fails or throws never stops the rest.
 * @param {string} name @param {Record<string, any>} snapshot @param {Ports} p
 */
export async function runWorkflow(name, snapshot, p) {
  const wf = WORKFLOWS[name];
  if (!wf) return { ok: false, error: `no workflow named ${name}; known: ${Object.keys(WORKFLOWS).join(', ')}`, actions: [] };
  const input = { events: p.events, ...snapshot };
  const missing = wf.needs.filter((k) => input[k] === undefined || input[k] === null);
  if (missing.length) return { ok: false, error: `${name} needs ${missing.join(', ')} in its snapshot; unknown is not empty, so nothing is planned`, actions: [] };
  if (!p.dryRun && (!p.run || !p.ask)) return { ok: false, error: 'a real run needs both run and ask ports (or use dryRun)', actions: [] };
  const plan = wf.plan(input, p.now || new Date());
  // One budget of heavy and bulk starts per tick; a caller running several workflows in one tick passes the same p.budget to each.
  const budget = p.budget || { heavy: LIMITS.maxHeavyPerTick };
  const actions = [];
  for (const a of plan) actions.push(await one(a, { ...p, budget }));
  return { ok: true, workflow: name, dryRun: !!p.dryRun, actions };
}

// Cards about no single order (a worktree, the morning card, a standing yes) are filed under this work order: the event contract
// needs a wo on decision.asked and decision.answered, while the decision contract allows none (a card for L0 asks to align them).
export const HOUSE_WO = 'WO-HOUSEKEEPING';

/** A card-asking port over an event sink (events.mjs): one decision.asked per card, ids from the log. */
export function askVia(sink, now = () => new Date()) {
  return (d) => {
    const wo = d.wo || HOUSE_WO;
    const decision = makeDecision({ ...d, wo, id: sink.nextDecisionId(), at: now().toISOString() });
    sink.append({ at: now().toISOString(), actor: 'engine', kind: 'decision.asked', wo, data: { decision }, proof: null });
    return decision.id;
  };
}

// The command line: dry run only (the engine runs workflows for real on its schedule, with the switch on).
export async function main(argv, say = console.log) {
  const [name, ...rest] = argv; const o = {};
  for (let i = 0; i < rest.length; i += 2) o[String(rest[i]).replace(/^--/, '')] = rest[i + 1];
  if (!name || !o.snapshot) { say('usage: node core/engine/converge/run.mjs <workflow> --snapshot <json> [--events <events.jsonl>] [--now <ISO>] (dry run only)'); return 2; }
  let snapshot; let events = [];
  try {
    snapshot = JSON.parse(fs.readFileSync(o.snapshot, 'utf8'));
    if (o.events) events = fs.readFileSync(o.events, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
  } catch (err) { say(`converge: an input does not read: ${/** @type {Error} */ (err).message}`); return 2; }
  const now = o.now ? new Date(o.now) : new Date();
  const r = await runWorkflow(name, snapshot, { events, dryRun: true, now, usage: () => ({ known: false, why: 'dry run from the command line reads no usage' }) });
  if (!r.ok) { say(`converge: ${r.error}`); return 2; }
  for (const x of r.actions) say(`${x.outcome}: ${x.act} ${x.target} (${x.why}; ${x.because})`);
  say(`converge ${name}: ${r.actions.length} action(s), dry run, nothing done`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).then((c) => { process.exitCode = c; });
