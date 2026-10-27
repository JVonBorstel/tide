// Owns the tests of the WO lifecycle (core/engine/wo.mjs): one named test per stage edge (and a check that no edge lacks one), the
// merge-only-after-Jordan's-yes rule (named cases plus 3,000 seeded random event orders), and stuck-after-2-retries -> one card.
// Called by tests/core/engine/test-engine.mjs.
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { EDGES, STAGES, MAX_RETRIES, reduce, next, classify, step, initial } from '../../../core/engine/wo.mjs';
import { check, log, H1, H2 } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const tested = new Set();
const edge = (id, pass, detail) => { tested.add(id); return check(`edge: ${id}`, pass, detail); };
const st = (l) => reduce(l.events, l.wo);
const nx = (l) => next(st(l));
const shipped = () => log().created().opened(H1).verdict('ship').ci('success');   // at merge-ready
const atJordan = () => shipped().askMerge('D-1');

function testEdges() {
  let s = st(log().created());
  edge('created > build', s.stage === 'build' && nx(log().created()).do === 'activity' && nx(log().created()).name === 'build' && nx(log().created()).heavy === true, JSON.stringify(nx(log().created())));
  s = st(log().created().opened(H1));
  edge('build > review: PR opened', s.stage === 'review' && s.head === H1 && next(s).name === 'review', `${s.stage} ${next(s).do}`);
  s = st(log().created().pushed(H2));
  edge('build > review: crew pushed', s.stage === 'review' && s.head === H2, s.stage);
  const moved = atJordan().answer('D-1', 'Yes').pushed(H2, 'freshen');
  s = st(moved);
  edge('head moved > review again', s.stage === 'review' && s.mergeYes === null && s.cards.merge === null && nx(moved).name === 'review', `${s.stage} ${nx(moved).name}`);
  s = st(log().created().opened(H1).verdict('ship'));
  const stale = st(log().created().opened(H1).verdict('ship', H2));
  edge('review > ci: ship on this head', s.stage === 'ci' && nx(log().created().opened(H1).verdict('ship')).name === 'ci-wait' && stale.stage === 'review', `${s.stage}; a SHIP for another head left it in ${stale.stage}`);
  const fix = log().created().opened(H1).verdict('fix');
  s = st(fix);
  const fix3 = st(log().created().opened(H1).verdict('fix').timer().pushed(H2).verdict('fix', H2).timer().pushed(H1).verdict('fix', H1));
  edge('review fix > build (retry) or stuck', s.stage === 'build' && s.retries === 1 && next(s).do === 'wait' && next(st(fix.timer())).name === 'build' && fix3.state === 'stuck',
    `${s.stage} r${s.retries} ${next(s).do}; third fix -> ${fix3.state}`);
  s = st(log().created().opened(H1).verdict('hold'));
  edge('review hold > stuck', s.state === 'stuck' && next(s).do === 'ask', `${s.state} ${next(s).do}`);
  s = st(shipped());
  edge('ci > merge-ready: green on this head', s.stage === 'merge-ready' && next(s).do === 'ask' && next(s).decision.kind === 'merge' && next(s).decision.options.join() === 'Yes,Hold,No', JSON.stringify(next(s)));
  s = st(log().created().opened(H1).verdict('ship').ci('failure'));
  edge('ci red > build (retry) or stuck', s.stage === 'build' && s.retries === 1, `${s.stage} r${s.retries}`);
  s = st(atJordan());
  edge('merge-ready > jordan: merge card asked', s.stage === 'jordan' && s.state === 'waiting-on-jordan' && next(s).do === 'await' && next(s).decision === 'D-1', `${s.stage} ${s.state} ${next(s).do}`);
  const yes = nx(atJordan().answer('D-1', 'Yes'));
  edge('jordan yes > merge', yes.do === 'activity' && yes.name === 'merge' && yes.args.Decision === 'D-1', JSON.stringify(yes));
  const hold = atJordan().answer('D-1', 'Hold', 'after the demo');
  edge('jordan hold > wait', nx(hold).do === 'await' && st(hold).state === 'waiting-on-jordan', nx(hold).do);
  s = st(atJordan().answer('D-1', 'No'));
  edge('jordan no > build (rework)', s.stage === 'build' && s.retries === 0 && s.attempt === 2 && next(s).name === 'build', `${s.stage} r${s.retries} a${s.attempt}`);
  s = st(atJordan().answer('D-1', 'Yes').merged(H1, 'D-1'));
  const gh = st(log().created().opened(H1).verdict('ship').merged(H1, null));
  edge('merged (by the engine or on GitHub)', s.stage === 'merged' && !s.outsideEngine && next(s).name === 'docs' && gh.stage === 'merged' && gh.outsideEngine, `${s.stage} ${s.outsideEngine}; github ${gh.stage} ${gh.outsideEngine}`);
  s = st(atJordan().answer('D-1', 'Yes').merged().docs());
  edge('merged > docs', s.stage === 'docs' && next(s).do === 'close' && next(s).sha === H1, `${s.stage} ${next(s).do}`);
  s = st(atJordan().answer('D-1', 'Yes').merged().docs().closed());
  edge('docs > closed', s.stage === 'closed' && s.state === 'shipped' && next(s).do === 'none', `${s.stage} ${s.state}`);
  const ciFail = (n) => { const l = log().created().opened(H1).verdict('ship'); for (let i = 1; i <= n; i++) l.started('ci-wait', i).failed('ci-wait', 124, i).timer(); return st(l); };
  edge('step failed > retry the step or stuck', ciFail(1).stage === 'ci' && ciFail(1).retries === 1 && ciFail(1).attempt === 2 && ciFail(MAX_RETRIES + 1).state === 'stuck',
    `after 1: ${ciFail(1).stage} r${ciFail(1).retries}; after ${MAX_RETRIES + 1}: ${ciFail(MAX_RETRIES + 1).state}`);
  s = st(log().created().opened(H1).verdict('ship').failed('ci-wait', 10));
  edge('step held > stuck', s.state === 'stuck' && s.retries === 0 && next(s).do === 'ask', `${s.state} r${s.retries}`);
  s = st(log().created().failed('build', 127));
  edge('step not built > blocked', !!s.blocked && s.retries === 0 && next(s).do === 'none' && /not built/.test(next(s).why), `${s.blocked} ${next(s).do}`);
  s = st(log().created().failed('build', 127).unblock());
  edge('unblocked (the missing piece landed)', s.blocked === null && next(s).name === 'build', String(s.blocked));
  const stuck = () => log().created().opened(H1).verdict('hold').askStuck('D-2');
  s = st(stuck());
  edge('stuck > card asked', s.cards.stuck === 'D-2' && next(s).do === 'await' && next(s).decision === 'D-2', `${s.cards.stuck} ${next(s).do}`);
  s = st(stuck().answer('D-2', 'Re-plan'));
  edge('stuck re-plan > build', s.stage === 'build' && s.state === 'moving' && s.retries === 0 && next(s).name === 'build', `${s.stage} ${s.state}`);
  s = st(stuck().answer('D-2', 'Drop'));
  const gone = st(stuck().answer('D-2', 'Drop').dropped('D-2'));
  edge('stuck drop > dropped', next(s).do === 'drop' && next(s).decision === 'D-2' && gone.state === 'dropped' && next(gone).do === 'none', `${next(s).do} then ${gone.state}`);
  s = st(log().created().opened(H1).dropped('D-2'));
  edge('dropped', s.state === 'dropped' && next(s).do === 'none' && st(log().created().opened(H1).dropped('D-2').verdict('ship')).stage === 'review', s.state);
  s = st(log().created().replaced());
  edge('replaced', s.state === 'replaced' && next(s).do === 'none', s.state);
  s = st(log().created().opened(H1).verdict('fix').timer());
  edge('timer fired', s.wait === null && next(s).name === 'build', JSON.stringify(s.wait));
  const missing = EDGES.map((e) => e.id).filter((id) => !tested.has(id));
  check('every edge in wo.mjs EDGES has a named test', missing.length === 0, `untested: ${missing.join(' | ')}`);
}

// Acceptance: merge happens only after a decision.answered Yes event for that WO and that card (and that head).
function testMergeGate() {
  const noYes = [atJordan(), atJordan().answer('D-1', 'Hold'), atJordan().answer('D-9', 'Yes'), shipped(), atJordan().answer('D-1', 'Yes').pushed(H2)];
  check('merge gate: no merge command without Jordan\'s Yes on the merge card (none, Hold, Yes on another card, card not asked, head moved)',
    noYes.every((l) => nx(l).name !== 'merge'), noYes.map((l) => nx(l).do + ':' + (nx(l).name || '')).join(', '));
  const other = atJordan(); other.events.push({ ...log('WO-2199').answer('D-1', 'Yes').events[0], seq: 99 });
  check('merge gate: a Yes written for another WO does not merge this one', nx(other).name !== 'merge', nx(other).do);
  check('merge gate: the merge command carries the card it was answered on', nx(atJordan().answer('D-1', 'Yes')).args.Decision === 'D-1');
  // 3,000 seeded random orders of plausible events: every time next() says merge, the log holds a Yes on this WO's merge card,
  // answered after that card was asked, with no head change since the card.
  let seed = 20301; const rnd = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
  let merges = 0; const bad = [];
  for (let run = 0; run < 3000; run++) {
    const l = log().created(); const heads = [H1, H2]; let cardN = 0;
    for (let i = 0; i < 18; i++) {
      // Half the time the event a real order would see next (so merges are reached), half the time any event at all (so the gate is attacked).
      const h = rnd(4) ? (st(l).head || heads[rnd(2)]) : heads[rnd(2)]; const k = rnd(2) ? ({ build: 0, review: 2, ci: 3, 'merge-ready': 4, jordan: 5 }[st(l).stage] ?? rnd(9)) : rnd(9);
      if (k === 0) l.opened(h); else if (k === 1) l.pushed(h); else if (k === 2) l.verdict(['ship', 'ship', 'fix', 'hold'][rnd(4)], h); else if (k === 3) l.ci(['success', 'success', 'failure'][rnd(3)], h);
      else if (k === 4) l.askMerge(`D-${++cardN}`); else if (k === 5) l.answer(`D-${1 + rnd(Math.max(1, cardN))}`, ['Yes', 'Yes', 'Hold', 'No'][rnd(4)]); else if (k === 6) l.timer();
      else if (k === 7) l.failed('ci-wait', [1, 10, 124][rnd(3)], 1); else l.askStuck(`D-${++cardN}`);
      const cmd = nx(l);
      if (cmd.name !== 'merge') continue;
      merges++;
      const card = cmd.args.Decision; const ev = l.events;
      const asked = ev.findIndex((e) => e.kind === 'decision.asked' && e.data.decision.id === card && e.data.decision.kind === 'merge');
      const yes = ev.findIndex((e, j) => j > asked && e.kind === 'decision.answered' && e.data.decision === card && e.data.answer === 'Yes' && e.actor === 'jordan' && e.wo === l.wo);
      const moved = ev.some((e, j) => j > asked && e.kind === 'pr.updated' && e.data.head !== st({ events: ev.slice(0, asked + 1), wo: l.wo }).head);
      if (asked < 0 || yes < 0 || moved) bad.push(`run ${run}: ${ev.map((e) => e.kind).join(' ')}`);
    }
  }
  check(`merge gate: 3,000 random event orders never merge without that Yes (${merges} merges reached)`, merges > 0 && bad.length === 0, bad.slice(0, 2).join(' || ') || `merges ${merges}`);
}

function testStuckCard() {
  const s = st(log().created().opened(H1).verdict('ship').ci('failure').timer().pushed(H2).verdict('ship', H2).ci('failure', H2).timer().pushed(H1).verdict('ship', H1).ci('failure', H1));
  const c = next(s);
  check(`stuck: after ${MAX_RETRIES} retries the third failure is stuck, and asks one re-plan-or-drop card`, s.state === 'stuck' && s.retries === MAX_RETRIES && c.do === 'ask'
    && c.decision.kind === 'question' && c.decision.options.join() === 'Re-plan,Drop' && c.decision.ask.length <= 300, `${s.state} r${s.retries} ${JSON.stringify(c)}`);
  const asked = st(log().created().opened(H1).verdict('hold').askStuck('D-2').verdict('ship'));
  check('stuck: while stuck, progress events do not move the order (only the card does)', asked.state === 'stuck' && asked.stage === 'review', `${asked.state} ${asked.stage}`);
}

// The log is a file a hand can edit: a verdict that skipped the sink's contract check must still not move the order.
function testFairVerdict() {
  const l = log().created().opened(H1);
  const raw = (data) => ({ v: '1.0', seq: 99, at: '2030-01-07T10:00:00Z', actor: 'crew:verifier-1', kind: 'review.verdict', wo: l.wo, data: { verdict: 'ship', reasons: 'x', head: H1, ...data }, proof: null });
  const cases = { 'no builder': raw({ reviewer: 'crew:verifier-1' }), 'reviewer is the builder': raw({ reviewer: 'crew:a', builder: 'crew:a' }), 'empty builder': raw({ reviewer: 'crew:verifier-1', builder: '' }),
    'no reviewer': raw({ builder: 'crew:builder-1' }), 'not a crew': raw({ reviewer: 'jordan', builder: 'crew:builder-1' }) };
  const moved = Object.entries(cases).filter(([, e]) => reduce([...l.events, e], l.wo).stage !== 'review').map(([k]) => k);
  check('reviewer is never the builder: a SHIP with no builder, no reviewer, the same crew or a non-crew moves nothing (5 tampered lines)', moved.length === 0, moved.join(', '));
  check('reviewer is never the builder: a fix verdict with no builder does not use a retry either', reduce([...l.events, { ...cases['no builder'], data: { ...cases['no builder'].data, verdict: 'fix' } }], l.wo).retries === 0);
}

function testShape() {
  const schema = JSON.parse(fs.readFileSync(path.join(repo, 'core/contracts/common.schema.json'), 'utf8'));
  check('STAGES in wo.mjs equals the contract stage enum (common.schema.json)', JSON.stringify(STAGES) === JSON.stringify(schema.$defs.stage.enum), STAGES.join());
  check('classify: 0 ok, 11 later, 10 and 3 (a refusal) held, 127 not-built, 1/124/125 failed', [0, 11, 10, 3, 127, 1, 124, 125].map(classify).join() === 'ok,later,held,held,not-built,failed,failed,failed');
  const s0 = initial('WO-2101');
  check('step ignores another WO\'s event', step(s0, { ...log('WO-2199').created().events[0] }) === s0);
  check('wo.mjs is pure: no import of node: modules or files (it runs inside a Temporal workflow)', !/from 'node:|require\(/.test(fs.readFileSync(path.join(repo, 'core/engine/wo.mjs'), 'utf8')));
  const all = [log().created(), log().created().opened(H1), shipped(), atJordan(), atJordan().answer('D-1', 'Yes').merged().docs().closed()];
  check('every command says why', all.every((l) => typeof nx(l).why === 'string' && nx(l).why.length > 0));
}

export function run() { testEdges(); testMergeGate(); testStuckCard(); testFairVerdict(); testShape(); }
