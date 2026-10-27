// @ts-check
// Owns the Temporal side of the engine adapter (core/engine/engine.mjs): start a WO's workflow, wake it with a signal after an event
// is written to the log, and ask it for its state. The log (events.mjs fileSink) stays the record: the client writes an outside
// event (Jordan's decision.answered, a GitHub push) there first and only then signals, so a lost signal loses no fact; the next wake
// reads it. Needs Jordan's install taps (INSTALL.md); core/engine/engine.mjs openEngine() checks before loading this file.
// Called by core/engine/engine.mjs and tests/core/engine/test-temporal.mjs.
import path from 'node:path';
import { load } from './load.mjs';
import { fileSink } from '../events.mjs';
import { reduce } from '../wo.mjs';
import { DEFAULTS } from './worker.mjs';

export const workflowId = (wo) => `wo-${wo}`;

/**
 * @param {{ state: string, address?: string, namespace?: string, queue?: string, clock?: () => Date }} o
 * @returns {Promise<import('../engine.mjs').EngineAdapter>}
 */
export async function createTemporalEngine(o) {
  if (!o || !o.state) throw new Error('createTemporalEngine needs { state } (the folder that holds engine\\events.jsonl)');
  const c = await load('client');
  const address = o.address || DEFAULTS.address; const namespace = o.namespace || DEFAULTS.namespace; const taskQueue = o.queue || DEFAULTS.queue;
  const connection = await c.Connection.connect({ address });
  const client = new c.Client({ connection, namespace });
  const sink = fileSink(path.join(o.state, 'engine', 'events.jsonl'));
  const clock = o.clock || (() => new Date());
  const wake = (wo) => client.workflow.signalWithStart('woLifecycle', { taskQueue, workflowId: workflowId(wo), args: [{ wo }], signal: 'event', signalArgs: [{ at: clock().toISOString() }] });
  return {
    kind: 'temporal',
    async start(wo, created) {
      if (!sink.forWo(wo).some((e) => e.kind === 'wo.created')) sink.append({ at: clock().toISOString(), actor: 'engine', kind: 'wo.created', wo, data: created, proof: null });
      await wake(wo);
      return { status: 'started', why: `workflow ${workflowId(wo)} on ${taskQueue}` };
    },
    async signal(wo, event) {
      const ev = event.seq ? event : sink.append({ at: clock().toISOString(), proof: null, ...event, wo });
      await wake(wo);
      return { status: 'signalled', why: `${ev.kind} #${ev.seq} written, ${workflowId(wo)} woken` };
    },
    async query(wo) {
      try { return await client.workflow.getHandle(workflowId(wo)).query('state'); } catch { return reduce(sink.forWo(wo), wo); }
    },
    async close() { await connection.close(); },
  };
}
