// Owns a small stand-in for @temporalio/workflow, so core/engine/temporal/workflows.mjs can be run and raced in a plain Node process
// without Temporal: signals, conditions with timeouts, activities as plain functions. It is NOT Temporal (no history, no replay);
// it only lets a test put a signal at an exact point, such as while loadEvents is in flight.
// Loaded with: node --import ./tests/core/engine/workflow-double.mjs <script>. In the main thread it registers itself as a module hook
// that answers "@temporalio/workflow" with this file. Called by tests/core/engine/workflow-sim.mjs (from test-temporal.mjs).
import { register } from 'node:module'; import { isMainThread } from 'node:worker_threads';

if (isMainThread) register(import.meta.url);

// Module hook (runs in the hooks thread): the bare name resolves to this file.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === '@temporalio/workflow') return { url: import.meta.url, shortCircuit: true };
  return nextResolve(specifier, context);
}

export const sim = { activities: /** @type {Record<string, Function>} */ ({}), handlers: /** @type {Record<string, Function>} */ ({}), timeScale: 0.001 };
const waiters = new Set();
const poke = () => { for (const w of [...waiters]) if (w.fn()) { waiters.delete(w); clearTimeout(w.t); w.res(true); } };

export const proxyActivities = () => new Proxy({}, { get: (_, name) => async (...args) => { const r = await sim.activities[String(name)](...args); poke(); return r; } });
export const defineSignal = (name) => name;
export const defineQuery = (name) => name;
export function setHandler(name, fn) { sim.handlers[name] = fn; }
export function condition(fn, ms) {
  if (fn()) return Promise.resolve(true);
  return new Promise((res) => {
    const w = { fn, res, t: /** @type {any} */ (null) };
    waiters.add(w);
    if (ms !== undefined) w.t = setTimeout(() => { waiters.delete(w); res(false); }, Math.max(0, ms * sim.timeScale));
  });
}
export const workflowInfo = () => ({ historyLength: 1 });
export async function continueAsNew() { throw new Error('continueAsNew is not simulated'); }
/** Deliver a signal now, the way Temporal would between two awaits. */
export function signal(name, ...args) { sim.handlers[name](...args); poke(); }
