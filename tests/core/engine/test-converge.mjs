// Owns the tests of the convergence workflows (core/engine/converge/*): each workflow is dry-run-able (nothing called, nothing written);
// actions that need a yes only create cards unless a standing-yes event exists (tested both ways, per action kind); no duplicate cards;
// one-off yes, no and withdrawn standing yes; the governor gate; the schedules; the morning card's 3-tap limit; the dry-run command line.
// Called by tests/core/engine/test-engine.mjs. Synthetic snapshots only.
import fs from 'node:fs'; import path from 'node:path';
import { WORKFLOWS, YES, LIMITS } from '../../../core/engine/converge/workflows.mjs';
import { runWorkflow, askVia, main, HOUSE_WO } from '../../../core/engine/converge/run.mjs';
import { SCHEDULES, due } from '../../../core/engine/converge/schedule.mjs';
import { memorySink } from '../../../core/engine/events.mjs';
import { makeDecision } from '../../../core/engine/cards.mjs';
import { check, tmp, H1, H2 } from './lib.mjs';

const NOW = new Date('2030-01-08T09:00:00Z');
const LOW = () => ({ known: true, used: 0.1, why: '10 %' }); const HIGH = () => ({ known: true, used: 0.8, why: '80 %' });
const pr = (o = {}) => ({ pr: 'example#41', wo: 'WO-2101', branch: 'wo/2101-example', head: H1, behind: 0, mergeable: 'yes', reviewedHead: H1, ...o });
// One snapshot per workflow that gives at least one action.
const SNAP = {
  'freshen-pr': { prs: [pr({ behind: 3 })] },
  're-review': { prs: [pr({ head: H2 })] },
  retry: { rows: [{ wo: 'WO-2101', state: 'moving', lastEventAt: '2030-01-06T09:00:00Z', retries: 0 }] },
  recook: { prs: [pr({ mergeable: 'conflicting' })] },
  'pickup-archive': { pickup: [{ line: 2, date: '2030-01-05T09:00:00Z' }, { line: 3, date: '2030-01-08T08:00:00Z' }] },
  'worktree-tidy': { worktrees: [{ path: 'wt/example-1', branch: 'wo/2101-example', merged: true, clean: true, idleH: 30 }] },
  'close-superseded': { prs: [pr({ pr: 'private-example#7', private: true, portedTo: 'example#41', portMerged: true })] },
  contradictions: {},
  'morning-card': { since: '2030-01-07T09:00:00Z' },
};
const spies = () => {
  const calls = { run: [], ask: [], record: [] };
  return { calls, run: async (a) => { calls.run.push(a); return { exit: 0, out: 'example ok' }; }, ask: (d) => { calls.ask.push(d); return `D-${90 + calls.ask.length}`; }, record: (e) => { calls.record.push(e); } };
};
// A standing yes in the log: a standing card of that kind whose ask holds the topic, answered by Jordan.
function standing(sink, y, answer = 'Yes') {
  const id = sink.nextDecisionId();
  sink.append({ at: '2030-01-07T08:00:00Z', actor: 'engine', kind: 'decision.asked', wo: HOUSE_WO, data: { decision: makeDecision({ id, wo: HOUSE_WO, kind: y.kind, ask: `Standing: ${y.topic}?`, options: ['Yes', 'No'], recommended: 'Yes', at: '2030-01-07T08:00:00Z', standing: true }) }, proof: null });
  sink.append({ at: `2030-01-07T08:0${sink.all().length % 10}:00Z`, actor: 'jordan', kind: 'decision.answered', wo: HOUSE_WO, data: { decision: id, answer, via: 'board' }, proof: null });
  return id;
}

async function testDryRun() {
  for (const name of Object.keys(WORKFLOWS)) {
    const s = spies();
    const r = await runWorkflow(name, SNAP[name], { events: [], dryRun: true, now: NOW, usage: LOW, run: s.run, ask: s.ask, record: s.record });
    check(`dry run: ${name} plans its actions and calls nothing, writes nothing`, r.ok && r.actions.length > 0 && r.actions.every((x) => x.outcome.startsWith('would ')) && !s.calls.run.length && !s.calls.ask.length && !s.calls.record.length,
      r.error || r.actions.map((x) => x.outcome).join(', '));
  }
  check('every workflow has a dry-run test snapshot', Object.keys(WORKFLOWS).every((n) => n in SNAP));
  const miss = await runWorkflow('freshen-pr', {}, { events: [], dryRun: true, now: NOW });
  check('a missing snapshot input is refused by name (unknown is not empty)', !miss.ok && /needs prs/.test(miss.error), miss.error);
  check('a real run without run and ask ports is refused', !(await runWorkflow('contradictions', {}, { events: [], now: NOW })).ok);
}

// Each yes-needing action, both ways: no standing yes -> one card, nothing run; standing yes -> it runs, no card.
async function testYesBothWays() {
  const cases = [['freshen-pr', YES.freshen, 'freshen-pr'], ['worktree-tidy', YES.worktree, 'worktree-remove'], ['close-superseded', YES.closePr, 'pr-close'],
    ['recook', YES.freshen, 'freshen-pr']];
  for (const [wf, y, act] of cases) {
    const s1 = spies();
    const without = await runWorkflow(wf, SNAP[wf], { events: [], now: NOW, usage: LOW, ...s1 });
    const asked = s1.calls.ask.filter((d) => d.kind === y.kind && d.ask.includes(y.topic));
    check(`yes rule (${wf} ${act}): with no standing yes it only creates a card`, without.ok && asked.length === 1 && !s1.calls.run.some((a) => a.act === act) && asked[0].options.join() === 'Yes,Hold,No',
      without.actions.map((x) => `${x.act}:${x.outcome}`).join(', '));
    const sink = memorySink(); const id = standing(sink, y);
    const s2 = spies();
    const withYes = await runWorkflow(wf, SNAP[wf], { events: sink.all(), now: NOW, usage: LOW, ...s2 });
    check(`yes rule (${wf} ${act}): with a standing-yes event it runs, cites the card, and asks nothing`, s2.calls.run.some((a) => a.act === act) && !s2.calls.ask.some((d) => d.ask.includes(y.topic))
      && s2.calls.record.some((e) => e.proof === `yes ${id}`), withYes.actions.map((x) => `${x.act}:${x.outcome}:${x.because}`).join(', '));
  }
}

async function testCardsLifecycle() {
  const sink = memorySink(); const ask = askVia(sink, () => NOW);
  const s = spies();
  await runWorkflow('worktree-tidy', SNAP['worktree-tidy'], { events: sink.all(), now: NOW, run: s.run, ask, record: s.record });
  const again = await runWorkflow('worktree-tidy', SNAP['worktree-tidy'], { events: sink.all(), now: NOW, run: s.run, ask, record: s.record });
  const cards = sink.all().filter((e) => e.kind === 'decision.asked');
  check('cards: a second run while the card is open makes no second card (it waits)', cards.length === 1 && /wait/.test(again.actions[0].outcome), `${cards.length} cards; ${again.actions[0].outcome}`);
  const id = cards[0].data.decision.id;
  sink.append({ at: '2030-01-08T09:05:00Z', actor: 'jordan', kind: 'decision.answered', wo: HOUSE_WO, data: { decision: id, answer: 'Yes', via: 'board' }, proof: null });
  const yes = await runWorkflow('worktree-tidy', SNAP['worktree-tidy'], { events: sink.all(), now: NOW, run: s.run, ask, record: s.record });
  check('cards: a one-off Yes on that exact card runs that action', yes.actions[0].outcome === 'ran' && /Jordan said yes/.test(yes.actions[0].because), yes.actions[0].outcome);
  const sink2 = memorySink(); const ask2 = askVia(sink2, () => NOW);
  await runWorkflow('close-superseded', SNAP['close-superseded'], { events: [], now: NOW, run: s.run, ask: ask2 });
  const c2 = sink2.all()[0].data.decision.id;
  sink2.append({ at: '2030-01-08T09:05:00Z', actor: 'jordan', kind: 'decision.answered', wo: HOUSE_WO, data: { decision: c2, answer: 'No', via: 'board' }, proof: null });
  const no = await runWorkflow('close-superseded', SNAP['close-superseded'], { events: sink2.all(), now: NOW, run: async () => { throw new Error('must not run'); }, ask: ask2 });
  check('cards: a No on that card skips the action (no run, no new card)', no.actions[0].outcome === 'skip' && sink2.all().filter((e) => e.kind === 'decision.asked').length === 1, no.actions[0].outcome);
  const sink3 = memorySink(); standing(sink3, YES.worktree, 'Yes'); standing(sink3, YES.worktree, 'No');
  const s3 = spies();
  const withdrawn = await runWorkflow('worktree-tidy', SNAP['worktree-tidy'], { events: sink3.all(), now: NOW, ...s3 });
  check('cards: a standing yes withdrawn by a later standing No asks again', s3.calls.ask.length === 1 && !s3.calls.run.length, withdrawn.actions[0].because);
  const other = memorySink(); standing(other, { kind: 'close', topic: 'something else entirely' });
  const s4 = spies();
  await runWorkflow('worktree-tidy', SNAP['worktree-tidy'], { events: other.all(), now: NOW, ...s4 });
  check('cards: a standing yes on another topic does not cover this action', s4.calls.ask.length === 1 && !s4.calls.run.length);
}

async function testPlans() {
  const s = spies();
  const rr = await runWorkflow('re-review', SNAP['re-review'], { events: [], now: NOW, usage: LOW, ...s });
  check('re-review: a moved head is reviewed again without asking (heavy, under the threshold)', rr.actions[0].outcome === 'ran' && !s.calls.ask.length && s.calls.run[0].act === 'review');
  const held = await runWorkflow('re-review', SNAP['re-review'], { events: [], now: NOW, usage: HIGH, ...spies() });
  check('governor: a heavy action above the threshold is held with the reason', held.actions[0].outcome === 'hold' && /70 %/.test(held.actions[0].because), held.actions[0].because);
  const retries = [1, 2].map(() => ({ v: '1.0', seq: 1, at: '2030-01-07T00:00:00Z', actor: 'engine', kind: 'x.converge.retry', wo: 'WO-2101', data: {}, proof: null }));
  const r1 = WORKFLOWS.retry.plan({ ...SNAP.retry, events: [] }, NOW); const r3 = WORKFLOWS.retry.plan({ ...SNAP.retry, events: retries }, NOW);
  check(`retry: a row stale ${LIMITS.staleH} h gets a fresh crew; after ${LIMITS.maxConvergeRetries} it becomes one re-plan-or-drop card`, r1[0].act === 'retry' && r3[0].act === 'card' && /Re-plan or drop/.test(String(r3[0].args && r3[0].args.Ask)));
  const fresh = WORKFLOWS.retry.plan({ rows: [{ ...SNAP.retry.rows[0], lastEventAt: '2030-01-08T08:00:00Z' }], events: [] }, NOW);
  check('retry: a row with a recent event is left alone', fresh.length === 0);
  const rc = WORKFLOWS.recook.plan(SNAP.recook, NOW);
  check('recook: a conflicting PR gets the conflict fix and a re-cook from its BRIEF in parallel, then a verifier pick (re-cook is bulk)', rc.map((x) => x.act).join() === 'freshen-pr,recook,pick' && rc[1].cls === 'bulk');
  const picked = WORKFLOWS.recook.plan({ ...SNAP.recook, picks: { 'example#41': 'recook' } }, NOW);
  check('recook: when the re-cook wins, closing the old PR needs a yes', picked.length === 1 && picked[0].act === 'pr-close' && picked[0].yes === YES.closeSuperseded);
  const pa = WORKFLOWS['pickup-archive'].plan(SNAP['pickup-archive'], NOW);
  check(`pickup archive: only entries older than ${LIMITS.pickupKeepH} h move (moved, never deleted), no yes needed`, pa.length === 1 && pa[0].args.Lines === '2' && !pa[0].yes);
  check('worktree tidy: a dirty or not-merged or recently used worktree is never planned', WORKFLOWS['worktree-tidy'].plan({ worktrees: [{ path: 'a', branch: 'b', merged: true, clean: false, idleH: 99 }, { path: 'c', branch: 'd', merged: false, clean: true, idleH: 99 }, { path: 'e', branch: 'f', merged: true, clean: true, idleH: 2 }] }, NOW).length === 0);
}

function testMorning() {
  const sink = memorySink();
  sink.append({ at: '2030-01-08T01:00:00Z', actor: 'engine', kind: 'merged', wo: 'WO-2101', data: { pr: 'example#41', sha: H1 }, proof: 'example merge' });
  sink.append({ at: '2030-01-06T01:00:00Z', actor: 'engine', kind: 'merged', wo: 'WO-2100', data: { pr: 'example#40', sha: H2 }, proof: 'example merge' });
  for (const [id, at] of [['D-3', '2030-01-07T10:00:00Z'], ['D-4', '2030-01-06T10:00:00Z']]) sink.append({ at, actor: 'engine', kind: 'decision.asked', wo: 'WO-2101', data: { decision: makeDecision({ id, wo: 'WO-2101', kind: 'merge', ask: `Example ${id}?`, options: ['Yes', 'Hold', 'No'], recommended: 'Yes', at }) }, proof: null });
  const [card] = WORKFLOWS['morning-card'].plan({ events: sink.all(), since: '2030-01-07T09:00:00Z' }, NOW);
  const opts = String(card.args.Options).split(',');
  check('morning card: one card, at most 3 taps; it counts what landed since the last morning and what waits, and recommends the oldest open card',
    opts.length <= 3 && /1 landed \(example#41\)/.test(String(card.args.Ask)) && /2 wait on you/.test(String(card.args.Ask)) && opts[0] === 'Answer D-4' && String(card.args.Ask).length <= 300, String(card.args.Ask));
  const [empty] = WORKFLOWS['morning-card'].plan({ events: [], since: '2030-01-07T09:00:00Z' }, NOW);
  check('morning card: with nothing waiting it says so in 2 taps', /Nothing waits/.test(String(empty.args.Ask)) && String(empty.args.Options).split(',').length === 2);
}

async function testScheduleAndCli() {
  check('schedules: every schedule names a workflow that exists, and every workflow has a schedule', SCHEDULES.every((s) => s.workflow in WORKFLOWS) && Object.keys(WORKFLOWS).every((w) => SCHEDULES.some((s) => s.workflow === w)));
  const two = SCHEDULES.find((s) => s.workflow === 'freshen-pr'); const night = SCHEDULES.find((s) => s.workflow === 'contradictions');
  const at = (h, m = 0) => { const d = new Date(2030, 0, 8, h, m); return d; };
  check('schedules: every 2 h is due after 2 h, not after 1 h; never run = due', due(two, at(7).toISOString(), at(9)) && !due(two, at(8).toISOString(), at(9)) && due(two, null, at(9)));
  check('schedules: nightly 02:00 is due once after 02:00 and not again that day', due(night, at(1).toISOString(), at(2, 5)) && !due(night, at(2, 6).toISOString(), at(3)) && !due(night, new Date(2030, 0, 7, 3).toISOString(), at(1)));
  const dir = tmp('converge');
  try {
    const snap = path.join(dir, 'snap.json'); fs.writeFileSync(snap, JSON.stringify(SNAP['worktree-tidy']));
    const lines = []; const code = await main(['worktree-tidy', '--snapshot', snap, '--now', NOW.toISOString()], (l) => lines.push(l));
    check('cli: the command line is a dry run: it prints "would ask" and writes nothing', code === 0 && /would ask/.test(lines[0]) && /nothing done/.test(lines[lines.length - 1]) && fs.readdirSync(dir).length === 1, lines.join(' | '));
    check('cli: an unknown workflow or missing snapshot is exit 2', (await main(['nope', '--snapshot', snap], () => {})) === 2 && (await main(['retry'], () => {})) === 2);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

export async function run() { await runInterrupted(); await testDryRun(); await testYesBothWays(); await testCardsLifecycle(); await testPlans(); testMorning(); await testScheduleAndCli(); }

// A crash between an effectful action's intent and its record: look before running it again (the #33 review fix, here too).
export async function runInterrupted() {
  const snap = SNAP['worktree-tidy']; const target = snap.worktrees[0].path;
  const crashed = () => {
    const sink = memorySink(); standing(sink, YES.worktree);
    sink.append({ at: '2030-01-08T08:00:00Z', actor: 'engine', kind: 'x.converge.intent', wo: HOUSE_WO, data: { workflow: 'worktree-tidy', act: 'worktree-remove', target }, proof: null });
    return sink;
  };
  const cases = [['done', 0, 'ran', 0], ['not-done', 1, 'ran', 0], ['unknown', 0, 'ask', 1], [null, 0, 'ask', 1]];
  for (const [state, runs, outcome, cards] of cases) {
    const s = spies(); const sink = crashed();
    const r = await runWorkflow('worktree-tidy', snap, { events: sink.all(), now: NOW, ...s, ...(state ? { probe: async () => ({ state, why: `example ${state}` }) } : {}) });
    check(`interrupted action (${state || 'no probe'}): ${runs ? 'runs it again' : outcome === 'ask' ? 'asks one card, never a blind rerun' : 'records it as done, not run again'}`,
      s.calls.run.length === runs && r.actions[0].outcome === outcome && s.calls.ask.length === cards, `${r.actions[0].outcome}: ${r.actions[0].because}; runs ${s.calls.run.length}; cards ${s.calls.ask.length}`);
  }
  const s = spies(); const sink = memorySink(); standing(sink, YES.worktree);
  await runWorkflow('worktree-tidy', snap, { events: sink.all(), now: NOW, ...s });
  check('effectful action: the intent is recorded before the run, then the action\'s own record', s.calls.record.map((e) => e.kind).join() === 'x.converge.intent,x.converge.worktree-remove', s.calls.record.map((e) => e.kind).join());
}
