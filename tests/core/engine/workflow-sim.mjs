// Owns one race on the Temporal workflow (core/engine/temporal/workflows.mjs) under the stand-in (workflow-double.mjs): Jordan's Yes
// is written and its signal delivered WHILE the workflow's loadEvents is in flight, after the log was read without it. A workflow that
// counts that wake must still merge; one that loses it waits forever. Prints one JSON line: {done, state, merges}.
//   node --import ./tests/core/engine/workflow-double.mjs tests/core/engine/workflow-sim.mjs
import { sim, signal } from './workflow-double.mjs';
import { woLifecycle } from '../../../core/engine/temporal/workflows.mjs';
import { createActivities } from '../../../core/engine/temporal/activities.mjs';
import { memorySink } from '../../../core/engine/events.mjs';
import { memoryStore, result } from '../../../core/engine/activity.mjs';
import { CREATED, H1, PR } from './lib.mjs';

const wo = 'WO-2101'; const at = '2030-01-07T09:00:00Z';
const sink = memorySink(); let merges = 0;
const add = (kind, data, actor = 'engine') => sink.append({ at, actor, kind, wo, data, proof: null });
add('wo.created', CREATED); add('pr.opened', { pr: PR, branch: 'wo/2101-example', base: 'main', head: H1 }, 'github');
add('review.verdict', { verdict: 'ship', reasons: 'x', head: H1, reviewer: 'crew:verifier-1', builder: 'crew:builder-1' }, 'crew:verifier-1');
add('ci.result', { pr: PR, head: H1, conclusion: 'success' }, 'github');
const impls = { merge: async () => { merges++; return result(0, 'example merge'); }, docs: async () => result(0, '{"dod":{}}') };
const acts = createActivities({ sink, store: memoryStore(), impls, usage: () => ({ known: true, used: 0.1, weekly: 0.1, why: 'x' }), clock: () => new Date(at) });
let raced = false;
sim.activities = {
  ...acts,
  // The race: once the merge card is asked, the next read of the log returns what it saw BEFORE Jordan's tap, and the tap (event, then
  // signal) lands while that read is still in flight.
  loadEvents: async (w) => {
    const seenNow = sink.forWo(w);
    if (!raced && seenNow.some((e) => e.kind === 'decision.asked')) {
      raced = true;
      const card = seenNow.find((e) => e.kind === 'decision.asked').data.decision.id;
      add('decision.answered', { decision: card, answer: 'Yes', via: 'board' }, 'jordan');
      signal('event');
    }
    return seenNow;
  },
};
const timeout = new Promise((r) => setTimeout(() => r(null), 3000));
const s = await Promise.race([woLifecycle({ wo }), timeout]);
console.log(JSON.stringify({ done: !!s, raced, state: s ? s.state : 'still waiting after 3 s (a lost wake-up)', merges }));
process.exit(0);
