// @ts-check
// Owns the work order (WO) lifecycle as data: the stage edges of build-way 2.1 (build > review > ci > merge-ready > jordan > merged >
// docs > closed), folded from the contract events, and the one next command the engine should run. Pure: no files, no clock, no network,
// so the same code runs inside a Temporal workflow (deterministic replay) and inside the in-process fake (core/engine/fake.mjs).
// Called by core/engine/driver.mjs, core/engine/fake.mjs, core/engine/temporal/workflows.mjs and tests/core/engine/test-wo.mjs.
//   reduce(events) -> state      fold the WO's events (core/contracts/event.schema.json) into its state
//   next(state)    -> command    what to do now: activity | ask | await | wait | close | drop | none (always with a plain-word why)
// Safety lines (each has a named test): the merge command exists only after a decision.answered "Yes" on this WO's own merge card for
// the head that card asked about; a head that moves voids that yes; after MAX_RETRIES retries the order is stuck and asks one
// "re-plan or drop?" card instead of trying again.

/** @typedef {'build'|'review'|'ci'|'merge-ready'|'jordan'|'merged'|'docs'|'closed'} Stage */
/** @typedef {{ v?: string, seq: number, at: string, actor: string, kind: string, wo: string|null, data: any, proof: string|null }} Ev */
/** @typedef {{ sec: number, reason: string }} Wait */
/**
 * @typedef {{ wo: string, stage: Stage|null, state: string, attempt: number, retries: number, repo: string|null, alias: string|null,
 *   pr: string|null, head: string|null, built: number, reviewed: string|null, cards: { merge: string|null, stuck: string|null },
 *   cardHead: string|null, mergeYes: string|null, merged: boolean, mergedSha: string|null, docsRan: boolean, dropWith: string|null,
 *   wait: Wait|null, why: string, blocked: string|null, outsideEngine: boolean, runs: Record<string, number>, lastSeq: number,
 *   edges: string[] }} WoState
 */
/**
 * @typedef {{ do: 'activity', name: string, heavy: boolean, args: Record<string, string|number|boolean|null>, attempt: number, why: string }
 *   | { do: 'ask', decision: { kind: string, ask: string, options: string[], recommended: string, why: string }, why: string }
 *   | { do: 'await', for: string, decision?: string, why: string } | { do: 'wait', sec: number, why: string }
 *   | { do: 'close', sha: string, why: string } | { do: 'drop', decision: string, why: string } | { do: 'none', why: string }} Command
 */

// The stage list mirrors core/contracts/common.schema.json $defs/stage (a test fails if they ever differ; this file cannot read files).
/** @type {Stage[]} */
export const STAGES = ['build', 'review', 'ci', 'merge-ready', 'jordan', 'merged', 'docs', 'closed'];
export const MAX_RETRIES = 2;                       // build-way 2.1: retry with a fresh crew, at most 2; then one card
export const HEAVY = new Set(['build', 'review']);  // crew steps: they spend the shared Claude plan, so the governor gates them
export const POLL_SEC = 120;                        // ci-wait's "come back later" (exit 11): look again in 2 minutes
export const MERGE_OPTIONS = ['Yes', 'Hold', 'No'];
export const STUCK_OPTIONS = ['Re-plan', 'Drop'];
const TERMINAL = new Set(['dropped', 'replaced', 'shipped']);
const ACTIVE = ['build', 'review', 'ci', 'merge-ready', 'jordan'];
const OPEN = [...ACTIVE, 'merged', 'docs'];

// Retry backoff: base * factor^(n-1) seconds, never above cap. n is the retry number (1, 2, ...).
export function backoffSec(n, { base = 60, factor = 2, cap = 3600 } = {}) {
  if (!(n >= 1)) return 0;
  return Math.min(cap, Math.round(base * Math.pow(factor, n - 1)));
}

// What an activity's exit code means to the engine (core/contracts activity-result + the Yard's station codes).
export function classify(exit) {
  if (exit === 0) return 'ok';
  if (exit === 11) return 'later';      // the station said "come back later" (CI running, merge freeze, red main)
  if (exit === 10 || exit === 3) return 'held'; // held for Jordan (a station's unrelated history or bad freeze file; adopt's refusal: 3)
  if (exit === 127) return 'not-built'; // the activity is not wired yet (another lane's piece); waits, burns no retry
  return 'failed';                      // includes 124 (time limit) and 125 (memory cap) from scripts/run-bounded.ps1
}

/** @returns {WoState} */
export function initial(wo) {
  return { wo, stage: null, state: 'moving', attempt: 1, retries: 0, repo: null, alias: null, pr: null, head: null, built: 0, reviewed: null,
    cards: { merge: null, stuck: null }, cardHead: null, mergeYes: null, merged: false, mergedSha: null, docsRan: false, dropWith: null,
    wait: null, why: 'not created yet', blocked: null, outsideEngine: false, runs: {}, lastSeq: 0, edges: [] };
}

const retryOrStuck = (s, why) => (s.retries < MAX_RETRIES
  ? { stage: 'build', attempt: s.attempt + 1, retries: s.retries + 1, built: 0, reviewed: null, cards: { ...s.cards, merge: null }, mergeYes: null,
    wait: { sec: backoffSec(s.retries + 1), reason: `retry ${s.retries + 1} of ${MAX_RETRIES} with a fresh crew: ${why}` }, why }
  : { state: 'stuck', why: `stuck after ${s.retries} retries: ${why}` });
const failedStep = (s, e) => `${e.data.step} failed (exit ${e.data.exit ?? 'none'}): ${e.data.reason}`;
// CREED 6 in the reducer too (the log is a file a hand can edit): a verdict counts only with a named crew reviewer and a named crew
// builder that differ. A verdict with no builder, or by its builder, moves nothing.
const CREW = /^crew:[a-z0-9][a-z0-9-]*$/;
export const fairVerdict = (e) => !!e.data && CREW.test(String(e.data.reviewer)) && CREW.test(String(e.data.builder)) && e.data.reviewer !== e.data.builder;
const verdict = (e, v) => e.data.verdict === v && fairVerdict(e);
const answer = (s, e, card, a) => e.data.decision === s.cards[card] && e.data.answer === a;

/**
 * The edges, as data. Each: id (the test name), from (stages; null = not created), on (event kind), when (guard), to (state patch).
 * The first edge whose from, on and when match is taken. stuck: true edges apply only while the order is stuck, any: true edges always,
 * the rest only while it is not stuck.
 * @type {{ id: string, from: (Stage|null)[], on: string, stuck?: boolean, any?: boolean, when?: (s: WoState, e: Ev) => boolean, to: (s: WoState, e: Ev) => Partial<WoState> }[]}
 */
export const EDGES = [
  { id: 'created > build', from: [null], on: 'wo.created', to: (s, e) => ({ stage: 'build', repo: e.data.repo ?? null, alias: e.data.alias ?? null, why: 'created' }) },
  { id: 'build > review: PR opened', from: ['build'], on: 'pr.opened', to: (s, e) => ({ stage: 'review', pr: e.data.pr, head: e.data.head, why: 'PR opened' }) },
  { id: 'build > review: crew pushed', from: ['build'], on: 'pr.updated', when: (s, e) => e.data.why !== 'closed' && e.data.head !== s.head,
    to: (s, e) => ({ stage: 'review', head: e.data.head, why: 'the crew pushed a new head' }) },
  { id: 'head moved > review again', from: ['review', 'ci', 'merge-ready', 'jordan'], on: 'pr.updated', when: (s, e) => e.data.why !== 'closed' && e.data.head !== s.head,
    to: (s, e) => ({ stage: 'review', head: e.data.head, reviewed: null, cards: { ...s.cards, merge: null }, cardHead: null, mergeYes: null, why: `head moved (${e.data.why}): re-review; any yes was for the old head` }) },
  { id: 'review > ci: ship on this head', from: ['review'], on: 'review.verdict',
    when: (s, e) => verdict(e, 'ship') && e.data.head === s.head, to: () => ({ stage: 'ci', why: 'review SHIP' }) },
  { id: 'review fix > build (retry) or stuck', from: ['review'], on: 'review.verdict', when: (s, e) => verdict(e, 'fix') && e.data.head === s.head,
    to: (s, e) => retryOrStuck(s, `review said fix: ${e.data.reasons}`) },
  { id: 'review hold > stuck', from: ['review'], on: 'review.verdict', when: (s, e) => verdict(e, 'hold') && e.data.head === s.head,
    to: (s, e) => ({ state: 'stuck', why: `review held it: ${e.data.reasons}` }) },
  { id: 'ci > merge-ready: green on this head', from: ['ci'], on: 'ci.result', when: (s, e) => e.data.conclusion === 'success' && e.data.head === s.head,
    to: () => ({ stage: 'merge-ready', why: 'CI green' }) },
  { id: 'ci red > build (retry) or stuck', from: ['ci'], on: 'ci.result', when: (s, e) => ['failure', 'cancelled', 'timed-out'].includes(e.data.conclusion) && e.data.head === s.head,
    to: (s, e) => retryOrStuck(s, `CI ${e.data.conclusion}`) },
  { id: 'merge-ready > jordan: merge card asked', from: ['merge-ready'], on: 'decision.asked', when: (s, e) => e.data.decision.kind === 'merge' && e.data.decision.wo === s.wo,
    to: (s, e) => ({ stage: 'jordan', state: 'waiting-on-jordan', cards: { ...s.cards, merge: e.data.decision.id }, cardHead: s.head, why: `waiting for Jordan's tap on ${e.data.decision.id}` }) },
  { id: 'jordan yes > merge', from: ['jordan'], on: 'decision.answered', when: (s, e) => answer(s, e, 'merge', 'Yes') && s.cardHead === s.head,
    to: (s, e) => ({ state: 'moving', mergeYes: e.data.decision, why: `Jordan said yes on ${e.data.decision}` }) },
  { id: 'jordan hold > wait', from: ['jordan'], on: 'decision.answered', when: (s, e) => answer(s, e, 'merge', 'Hold'),
    to: (s, e) => ({ state: 'waiting-on-jordan', why: `Jordan said hold on ${e.data.decision}${e.data.note ? `: ${e.data.note}` : ''}` }) },
  { id: 'jordan no > build (rework)', from: ['jordan'], on: 'decision.answered', when: (s, e) => answer(s, e, 'merge', 'No'),
    to: (s, e) => ({ stage: 'build', state: 'moving', attempt: s.attempt + 1, built: 0, reviewed: null, cards: { ...s.cards, merge: null }, cardHead: null, mergeYes: null,
      why: `Jordan said no on ${e.data.decision}: rework${e.data.note ? ` (${e.data.note})` : ''}` }) },
  { id: 'merged (by the engine or on GitHub)', from: ACTIVE, on: 'merged', to: (s, e) => ({ stage: 'merged', state: 'moving', merged: true, mergedSha: e.data.sha,
    outsideEngine: !(s.mergeYes && e.data.decision === s.mergeYes), why: s.mergeYes && e.data.decision === s.mergeYes ? 'merged after Jordan\'s yes' : 'merged outside the engine (a tap on GitHub)' }) },
  { id: 'merged > docs', from: ['merged'], on: 'docs.done', to: () => ({ stage: 'docs', why: 'docs station done' }) },
  { id: 'docs > closed', from: ['docs'], on: 'closed', to: () => ({ stage: 'closed', state: 'shipped', why: 'closed with proof on main' }) },
  { id: 'step failed > retry the step or stuck', from: OPEN, on: 'step.failed', when: (s, e) => !['held', 'not-built'].includes(classify(e.data.exit)),
    to: (s, e) => (s.retries < MAX_RETRIES
      ? { attempt: s.attempt + 1, retries: s.retries + 1, wait: { sec: backoffSec(s.retries + 1), reason: `retry ${s.retries + 1} of ${MAX_RETRIES}: ${failedStep(s, e)}` }, why: failedStep(s, e) }
      : { state: 'stuck', why: `stuck after ${s.retries} retries: ${failedStep(s, e)}` }) },
  { id: 'step held > stuck', from: OPEN, on: 'step.failed', when: (s, e) => classify(e.data.exit) === 'held', to: (s, e) => ({ state: 'stuck', why: `held: ${failedStep(s, e)}` }) },
  { id: 'step not built > blocked', from: OPEN, on: 'step.failed', when: (s, e) => classify(e.data.exit) === 'not-built',
    to: (s, e) => ({ blocked: `${e.data.step} is not built yet: ${e.data.reason}`, why: `waiting for a missing piece: ${e.data.reason}` }) },
  { id: 'stuck > card asked', from: OPEN, on: 'decision.asked', stuck: true, when: (s, e) => e.data.decision.kind === 'question' && e.data.decision.wo === s.wo,
    to: (s, e) => ({ cards: { ...s.cards, stuck: e.data.decision.id }, why: `waiting for Jordan: re-plan or drop (${e.data.decision.id})` }) },
  { id: 'stuck re-plan > build', from: OPEN, on: 'decision.answered', stuck: true, when: (s, e) => answer(s, e, 'stuck', 'Re-plan'),
    to: (s, e) => ({ stage: 'build', state: 'moving', attempt: s.attempt + 1, retries: 0, built: 0, reviewed: null, blocked: null, cards: { merge: null, stuck: null }, mergeYes: null, why: `re-plan (${e.data.decision})` }) },
  { id: 'stuck drop > dropped', from: OPEN, on: 'decision.answered', stuck: true, when: (s, e) => answer(s, e, 'stuck', 'Drop'),
    to: (s, e) => ({ dropWith: e.data.decision, why: `Jordan said drop (${e.data.decision})` }) },
  { id: 'dropped', from: [null, ...OPEN], on: 'dropped', any: true, to: (s, e) => ({ state: 'dropped', why: `dropped: ${e.data.reason}` }) },
  { id: 'replaced', from: [null, ...OPEN], on: 'replaced', any: true, to: (s, e) => ({ state: 'replaced', why: `replaced by ${e.data.by}: ${e.data.reason}` }) },
  { id: 'timer fired', from: [null, ...OPEN], on: 'x.engine.timer', any: true, to: () => ({ wait: null }) },
  { id: 'unblocked (the missing piece landed)', from: OPEN, on: 'x.engine.unblock', any: true, when: (s) => !!s.blocked,
    to: (s, e) => ({ blocked: null, why: `unblocked: ${(e.data && e.data.reason) || 'the missing piece landed'}` }) },
];

// Bookkeeping that is not a stage edge: how often each step ran, what finished, and the ci-wait poll.
function note(s, e) {
  const d = e.data || {};
  if (e.kind === 'step.started') return { runs: { ...s.runs, [d.step]: (s.runs[d.step] || 0) + 1 } };
  if (e.kind !== 'step.done') return {};
  if (classify(d.exit) === 'later') return { wait: { sec: POLL_SEC, reason: `${d.step} said come back later` } };
  if (d.exit !== 0) return {};
  if (d.step === 'build') return { built: s.attempt };
  if (d.step === 'review') return { reviewed: s.head };
  if (d.step === 'docs') return { docsRan: true };
  return {};
}

/** @param {WoState} s @param {Ev} e @returns {WoState} */
export function step(s, e) {
  if (e.wo !== s.wo) return s;
  let out = { ...s, ...note(s, e), lastSeq: e.seq };
  if (TERMINAL.has(s.state) && e.kind !== 'x.engine.timer') return out;
  const isStuck = s.state === 'stuck';
  const edge = EDGES.find((x) => x.on === e.kind && x.from.includes(s.stage) && (x.any || !!x.stuck === isStuck) && (!x.when || x.when(s, e)));
  if (!edge) return out;
  const patch = edge.to(out, e);
  // A missing piece blocks one step; once the order moves to another stage (the result came from elsewhere), that block is gone.
  const moved = patch.stage && patch.stage !== out.stage ? { blocked: null } : {};
  out = { ...out, ...moved, ...patch, edges: [...s.edges, edge.id] };
  return out;
}

/** @param {Ev[]} events @param {string} [wo] @returns {WoState} */
export function reduce(events, wo) {
  const id = wo || (events.find((e) => e.kind === 'wo.created') || events[0] || { wo: '' }).wo || '';
  return [...events].sort((a, b) => a.seq - b.seq).reduce(step, initial(id));
}

const args = (s, extra = {}) => ({ Wo: s.wo, Pr: s.pr, Head: s.head, Repo: s.repo, Alias: s.alias, Attempt: s.attempt, ...extra });
const act = (s, name, why, extra) => /** @type {Command} */ ({ do: 'activity', name, heavy: HEAVY.has(name), args: args(s, extra), attempt: s.attempt, why });

/** What the engine does next for this order. Exactly one command; every one says why. @param {WoState} s @returns {Command} */
export function next(s) {
  if (s.stage === null) return { do: 'none', why: 'no wo.created event yet' };
  if (TERMINAL.has(s.state)) return { do: 'none', why: `finished: ${s.state}` };
  if (s.dropWith) return { do: 'drop', decision: s.dropWith, why: s.why };
  if (s.wait) return { do: 'wait', sec: s.wait.sec, why: s.wait.reason };
  if (s.state === 'stuck') {
    if (s.cards.stuck) return { do: 'await', for: 'decision', decision: s.cards.stuck, why: s.why };
    return { do: 'ask', why: s.why, decision: { kind: 'question', ask: `${s.wo}: ${s.why}`.slice(0, 280) + ' Re-plan or drop?', options: STUCK_OPTIONS, recommended: 'Re-plan', why: 'A fresh plan from the brief is cheaper than a third retry of the same one.' } };
  }
  if (s.blocked) return { do: 'none', why: s.blocked };
  switch (s.stage) {
    case 'build': return s.built === s.attempt ? { do: 'await', for: 'pr', why: 'built; waiting for the crew\'s push (pr.opened or pr.updated)' } : act(s, 'build', `build attempt ${s.attempt}`);
    case 'review': return s.reviewed === s.head ? { do: 'await', for: 'review.verdict', why: `reviewed ${s.head}; waiting for the verifier's verdict` } : act(s, 'review', `review head ${s.head}`);
    case 'ci': return act(s, 'ci-wait', `wait for CI on ${s.head}`);
    case 'merge-ready': return { do: 'ask', why: 'review SHIP and CI green', decision: { kind: 'merge', ask: `Merge ${s.pr} (${s.wo}) at ${String(s.head).slice(0, 7)}?`, options: MERGE_OPTIONS, recommended: 'Yes', why: 'The review said SHIP and CI is green on this head.' } };
    case 'jordan':
      if (s.mergeYes && s.mergeYes === s.cards.merge && s.cardHead === s.head) return act(s, 'merge', `merge after Jordan's yes on ${s.mergeYes}`, { Decision: s.mergeYes });
      return { do: 'await', for: 'decision', decision: s.cards.merge || undefined, why: s.why };
    case 'merged': return s.docsRan ? { do: 'await', for: 'docs.done', why: 'docs ran; waiting for docs.done' } : act(s, 'docs', 'after the merge: MAP, change note, glossary, names');
    case 'docs': return { do: 'close', sha: String(s.mergedSha), why: 'docs done: close with the merge sha as proof' };
    default: return { do: 'none', why: `nothing to do in ${s.stage}` };
  }
}
