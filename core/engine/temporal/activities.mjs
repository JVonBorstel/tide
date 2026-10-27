// @ts-check
// Owns the Temporal activities of the WO workflow (workflows.mjs). They are thin: each one is a call into the same engine-neutral code
// the in-process fake uses (driver.mjs over events.mjs, activity.mjs and governor.mjs), so both engines write the same events.
// No Temporal import here: plain async functions the worker registers (worker.mjs) and the tests can call directly.
// Called by core/engine/temporal/worker.mjs and tests/core/engine/test-temporal.mjs.
import { execute } from '../driver.mjs';

/**
 * @param {{ sink: import('../events.mjs').Sink, store: import('../activity.mjs').Store, impls: Record<string, any>,
 *   usage: () => any, clock?: () => Date }} ports
 */
export function createActivities(ports) {
  const clock = ports.clock || (() => new Date());
  return {
    /** Every event of one order, oldest first: the workflow folds them with wo.mjs reduce(). */
    async loadEvents(/** @type {string} */ wo) { return ports.sink.forWo(wo); },
    /** Carry out one lifecycle command (activity, ask, close, drop); returns the events written and any governor hold. */
    async runCommand(/** @type {string} */ wo, /** @type {any} */ cmd) {
      const r = await execute(wo, cmd, { ...ports, clock });
      return { events: r.events, hold: r.hold || null, replayed: !!r.replayed };
    },
    /** A durable timer fired (retry backoff, a ci-wait poll): record it so the lifecycle moves on. */
    async addTimer(/** @type {string} */ wo, /** @type {number} */ sec, /** @type {string} */ why) {
      return ports.sink.append({ at: clock().toISOString(), actor: 'engine', kind: 'x.engine.timer', wo, data: { sec, why }, proof: null });
    },
  };
}
