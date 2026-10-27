// @ts-check
// Owns carrying out a convergence workflow's actions (workflows.mjs) under the yes rules of build-way 3.6 and section 9:
//   - an action that needs Jordan's yes runs only with a standing yes in the event log (a standing card of that kind and topic answered
//     Yes) or a one-off card for exactly that action answered Yes; otherwise it creates one card (never two for the same action) and stops;
//   - heavy and bulk actions ask the governor first (governor.mjs); a hold is said, not dropped;
//   - every run is recorded as an x.converge.<act> event; a dry run prints what would happen and calls nothing, writes nothing;
//   - an action that changes things (EFFECTFUL) writes an x.converge.intent first; if an earlier run was interrupted after its intent,
//     the probe port looks first (done: recorded, not rerun; not done: run; unknown or no probe: one card, never a blind second run).
// Called by the engine's schedules (schedule.mjs), its command line (below: dry run only) and tests/core/engine/test-converge.mjs.
//   node core/engine/converge/run.mjs <workflow> --snapshot <json> [--events <events.jsonl>] [--now <ISO time>]
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { WORKFLOWS } from './workflows.mjs';
import { standingYes, cardsIn, makeDecision } from '../cards.mjs';
import { decide } from '../governor.mjs';

/** @typedef {import('./workflows.mjs').Action} Action */
/**
 * @typedef {{ events: any[], dryRun?: boolean, now?: Date, usage?: () => any, run?: (a: Action) => Promise<{ exit: number, out?: string }>,
 *   ask?: (d: { kind: string, wo: string|null, ask: string, options: string[], recommended: string, why: string }) => string,
 *   record?: (e: { kind: string, wo: string|null, data: any, proof: string|null }) => void,
 *   probe?: (a: Action) => Promise<{ state: 'done'|'not-done'|'unknown', why: string }> }} Ports
 */

export const cardAsk = (/** @type {Action} */ a) => (a.act === 'card' ? String(a.args && a.args.Ask) : `${a.yes ? a.yes.topic : a.act}: ${a.target}? (${a.why})`).slice(0, 300);
const optionsOf = (a) => (a.act === 'card' ? String(a.args && a.args.Options).split(',') : ['Yes', 'Hold', 'No']);

// The yes for one action: standing (cited), a one-off card answered Yes, a card still open, a card declined, or none yet.
export function yesFor(/** @type {Action} */ a, events) {
  if (!a.yes) return { state: 'not-needed' };
  const st = standingYes(events, a.yes.kind, a.yes.topic);
  if (st.yes) return { state: 'standing', decision: st.decision };
  const mine = [...cardsIn(events)].filter(([, c]) => c.decision.ask === cardAsk(a));
  const last = mine[mine.length - 1];
  if (!last) return { state: 'none' };
  const [id, c] = last;
  if (c.answer === null) return { state: 'open', decision: id };
  return { state: c.answer === 'Yes' ? 'one-off' : 'declined', decision: id };
}

/** One action under the rules. @param {Action} a @param {Ports} p */
async function one(a, p) {
  const now = p.now || new Date();
  const y = a.act === 'card' ? { state: [...cardsIn(p.events)].some(([, c]) => c.decision.ask === cardAsk(a) && c.answer === null) ? 'open' : 'none' } : yesFor(a, p.events);
  const would = (outcome, why) => ({ ...a, outcome: p.dryRun ? `would ${outcome}` : outcome, because: why });
  if (y.state === 'open') return would('wait', `card ${y.decision || ''} is still open`.replace('  ', ' '));
  if (y.state === 'declined') return would('skip', `Jordan answered no or hold on ${y.decision}`);
  if (a.act === 'card' || y.state === 'none') {
    const why = a.act === 'card' ? a.why : `needs a yes (${a.yes && a.yes.kind}: ${a.yes && a.yes.topic}) and no standing yes is in the log`;
    if (p.dryRun) return would('ask', why);
    const opts = optionsOf(a);
    const id = /** @type {any} */ (p.ask)({ kind: a.act === 'card' ? String(a.args && a.args.Kind) : /** @type {any} */ (a.yes).kind, wo: a.wo, ask: cardAsk(a), options: opts,
      recommended: String((a.args && a.args.Recommended) || opts[0]), why: a.why.slice(0, 2000) });
    return would('ask', `${why}: card ${id}`);
  }
  if (a.cls !== 'light') {
    const v = decide(a.cls, (p.usage || (() => ({ known: false, why: 'no usage reader given' })))(), { now });
    if (!v.go) return would('hold', v.why);
  }
  const because = y.state === 'standing' ? `standing yes ${y.decision}` : y.state === 'one-off' ? `Jordan said yes on ${y.decision}` : 'allowed without asking (build-way 3.6)';
  const done = (r, why) => {
    if (p.record) p.record({ kind: `x.converge.${a.act}`, wo: a.wo, data: { workflow: a.workflow, target: a.target, exit: r.exit, because: why }, proof: y.decision ? `yes ${y.decision}` : null });
    return { ...a, outcome: r.exit === 0 ? 'ran' : `failed (exit ${r.exit})`, because: why, out: String(r.out || '').slice(-500) };
  };
  if (EFFECTFUL.has(a.act) && interrupted(a, p.events)) {
    // An earlier run wrote its intent and never recorded the end: it may have taken effect. Look before running it again.
    let pr;
    try { pr = p.probe ? await p.probe(a) : { state: 'unknown', why: 'no probe for this action' }; } catch (err) { pr = { state: 'unknown', why: `the probe failed: ${/** @type {Error} */ (err).message}` }; }
    if (pr.state === 'done') return p.dryRun ? would('record', `interrupted earlier, and it had taken effect: ${pr.why}`) : done({ exit: 0, out: pr.why }, `interrupted earlier, and it had taken effect: ${pr.why}`);
    if (pr.state !== 'not-done') {
      const ask = `${a.act} ${a.target} was interrupted mid-run and whether it took effect is unknown (${pr.why}). Run it again?`.slice(0, 300);
      if (p.dryRun) return would('ask', ask);
      if ([...cardsIn(p.events)].some(([, c]) => c.decision.ask === ask && c.answer === null)) return would('wait', 'the interrupted-run card is still open');
      const id = /** @type {any} */ (p.ask)({ kind: 'question', wo: a.wo, ask, options: ['Yes', 'No'], recommended: 'No', why: 'Running it twice could do it twice; check first.' });
      return would('ask', `held, not run twice: card ${id}`);
    }
  }
  if (p.dryRun) return would('run', because);
  if (EFFECTFUL.has(a.act) && p.record) p.record({ kind: 'x.converge.intent', wo: a.wo, data: { workflow: a.workflow, act: a.act, target: a.target }, proof: null });
  return done(await /** @type {any} */ (p.run)(a), because);
}

// Actions that change things outside the engine: each writes an intent before it runs (see interrupted()).
export const EFFECTFUL = new Set(['freshen-pr', 'worktree-remove', 'pr-close', 'pickup-archive']);
// The last intent for this action's target has no x.converge.<act> after it: a crash came between the start and the record.
export function interrupted(/** @type {Action} */ a, events) {
  let open = false;
  for (const e of events) {
    if (!e.data || e.data.target !== a.target) continue;
    if (e.kind === 'x.converge.intent' && e.data.act === a.act) open = true;
    if (e.kind === `x.converge.${a.act}`) open = false;
  }
  return open;
}

/**
 * Plan a workflow on a snapshot and carry out (or, with dryRun, only describe) its actions.
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
  const actions = [];
  for (const a of plan) actions.push(await one(a, { ...p, events: p.events }));
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
