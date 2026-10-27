// @ts-check
// Owns the Temporal workflow for one work order: the same lifecycle as the in-process fake (core/engine/wo.mjs next()), with Temporal
// keeping the durability: its history replays this function after a worker restart, sleep() is a durable timer, and the "event" signal
// (sent after the Board or /decide has written Jordan's decision.answered to the log) wakes an order that waits on him.
// Workflow code must be deterministic: no files, no clock, no network here. Everything that touches the world is an activity
// (activities.mjs): loadEvents reads the WO's events, runCommand carries out one command (driver.mjs), addTimer records a fired timer.
// Bundled by the worker (worker.mjs, workflowsPath) from core/engine/temporal/node_modules (package-lock.json, @temporalio 1.24.0).
// Checked on 2026-10-26 with Temporal CLI 1.9.1 on Node 22.12 and 24.22: the bundler takes this .mjs file and ../wo.mjs as written
// (tests/core/engine/test-temporal.mjs: kill the worker mid-wait, a timer after a restart, a signal that wakes, back-to-back signals).
import { proxyActivities, defineSignal, defineQuery, setHandler, condition, continueAsNew, workflowInfo } from '@temporalio/workflow';
import { reduce, next } from '../wo.mjs';

// Retries here cover a worker or activity crash; the lifecycle's own retries (a fresh crew, at most 2) are in wo.mjs.
const { loadEvents, runCommand, addTimer } = /** @type {any} */ (proxyActivities({
  startToCloseTimeout: '3 hours',
  retry: { initialInterval: '30 seconds', backoffCoefficient: 2, maximumInterval: '1 hour', maximumAttempts: 5 },
}));

export const eventSignal = defineSignal('event');
export const stateQuery = defineQuery('state');
export const HISTORY_LIMIT = 4000; // continue as new before Temporal's history grows large; the event log keeps the whole story

/** One work order, start to closed (or dropped, replaced, or stuck waiting on a card). @param {{ wo: string }} input */
export async function woLifecycle({ wo }) {
  let wakes = 0;
  let s = reduce([], wo);
  setHandler(eventSignal, () => { wakes++; });
  setHandler(stateQuery, () => s);
  // seen is taken BEFORE every read of the log. The client writes an event, then signals. A signal that lands while loadEvents is in
  // flight (its event maybe not in what was read) still counts as new, so the next wait returns at once and the log is read again.
  // Taking seen after the read would swallow that wake and wait for a signal that has already come (a lost wake-up).
  let seen = wakes;
  s = reduce(await loadEvents(wo), wo);
  let waitUntil = 0;
  for (;;) {
    if (workflowInfo().historyLength > HISTORY_LIMIT) await continueAsNew({ wo });
    const cmd = next(s);
    if (cmd.do === 'none') return s;
    if (cmd.do === 'await') {
      await condition(() => wakes > seen);
    } else if (cmd.do === 'wait') {
      if (!waitUntil) waitUntil = Date.now() + cmd.sec * 1000;   // Date.now() is replay-safe inside a workflow
      const woke = await condition(() => wakes > seen, Math.max(1, waitUntil - Date.now()));
      if (!woke) { await addTimer(wo, cmd.sec, cmd.why); waitUntil = 0; }
    } else {
      const r = await runCommand(wo, cmd);
      if (r.hold) await condition(() => wakes > seen, r.hold.retrySec * 1000);
    }
    seen = wakes;
    s = reduce(await loadEvents(wo), wo);
  }
}
