// @ts-check
// Owns starting the Temporal worker for Tide work orders: it runs workflows.mjs and the activities (activities.mjs) against the
// engine's own folder (<state>\engine: events.jsonl, activities\). Needs Jordan's two install taps (INSTALL.md); without them it exits 3
// naming what is missing. Registering it as a task at logon is a separate card (build-way 10.3), never done here.
//   node core/engine/temporal/worker.mjs --state <folder> [--address 127.0.0.1:7233] [--namespace default] [--queue tide-engine]
//        [--mode shadow|new] [--impls <module exporting impls(options)>]
// --address must be this PC (127.0.0.1, localhost or ::1): the dev server is "not for production" (relaxed checks), so it is never
// reached over a network from here. --impls swaps the station activities for test doubles (tests/core/engine/temporal-impls.mjs).
// Exit: 0 stopped cleanly, 2 bad arguments, 3 Temporal not installed or not reachable.
import path from 'node:path'; import { fileURLToPath, pathToFileURL } from 'node:url';
import { load } from './load.mjs';
import { createActivities } from './activities.mjs';
import { fileSink } from '../events.mjs';
import { fileStore, stationActivities } from '../activity.mjs';
import { readUsage } from '../governor.mjs';
import { cardsIn } from '../cards.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULTS = { address: '127.0.0.1:7233', namespace: 'default', queue: 'tide-engine', mode: 'shadow' };
const LOOPBACK = /^(127\.0\.0\.1|localhost|\[::1\]|::1):[0-9]{2,5}$/;

export function parseArgs(argv) {
  const o = { ...DEFAULTS, state: '', impls: '' };
  for (let i = 0; i < argv.length; i += 2) {
    const k = String(argv[i]).replace(/^--/, ''); const v = argv[i + 1];
    if (!(k in o) || v === undefined) return { error: `unknown or empty option ${argv[i]}` };
    o[k] = v;
  }
  if (!o.state) return { error: '--state <folder> is required (a scratch folder in tests; never the live state folder while the switch is old)' };
  if (!LOOPBACK.test(o.address)) return { error: `--address ${o.address} is not this PC; only 127.0.0.1, localhost or ::1` };
  if (!['shadow', 'new'].includes(o.mode)) return { error: `--mode ${o.mode}: shadow or new` };
  return { o };
}

// A merge needs Jordan's Yes on that card for that WO in the log: the station wrapper asks this before it sets KITCHEN_APPROVED.
const answeredYes = (sink) => (decision, wo) => {
  const c = cardsIn(sink.forWo(wo)).get(decision);
  return !!c && c.answer === 'Yes' && c.decision.wo === wo;
};

export async function main(argv) {
  const a = parseArgs(argv);
  if (a.error) { console.log(`worker: ${a.error}`); return 2; }
  const o = /** @type {any} */ (a.o);
  let w;
  try { w = await load('worker'); } catch (err) { console.log(`worker: ${/** @type {Error} */ (err).message}`); return 3; }
  const dir = path.join(o.state, 'engine');
  const sink = fileSink(path.join(dir, 'events.jsonl'));
  const base = stationActivities({ mode: o.mode, kitchen: o.state, answered: answeredYes(sink) });
  const impls = o.impls ? { ...base, ...(await import(pathToFileURL(path.resolve(o.impls)).href)).impls({ state: o.state }) } : base;
  const activities = createActivities({ sink, store: fileStore(path.join(dir, 'activities')), impls, usage: () => readUsage(path.join(o.state, 'plan-usage.json')) });
  let connection;
  try { connection = await w.NativeConnection.connect({ address: o.address }); } catch (err) {
    console.log(`worker: cannot reach Temporal at ${o.address} (is \`temporal server start-dev\` running?): ${/** @type {Error} */ (err).message}`); return 3;
  }
  const worker = await w.Worker.create({ connection, namespace: o.namespace, taskQueue: o.queue, workflowsPath: path.join(here, 'workflows.mjs'), activities });
  console.log(`worker: running on ${o.address} queue ${o.queue} (mode ${o.mode}, state ${dir})`);
  await worker.run();
  await connection.close();
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).then((c) => { process.exitCode = c; });
