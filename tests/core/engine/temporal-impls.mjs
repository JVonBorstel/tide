// Owns the test-double activities the Temporal worker loads in tests (worker.mjs --impls): ci-wait, merge and docs that only count
// their runs in files under the scratch state folder. ci-wait's exit codes come from <state>/ci-exits.txt, a queue (for example "11,0").
// Called by core/engine/temporal/worker.mjs when tests/core/engine/test-temporal.mjs starts it.
import fs from 'node:fs'; import path from 'node:path';
import { result } from '../../../core/engine/activity.mjs';

export function impls({ state }) {
  const count = (name) => { const f = path.join(state, `${name}.count`); const n = (fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8')) : 0) + 1; fs.writeFileSync(f, String(n)); return n; };
  // ci-exits.txt is a queue: each ci-wait run takes the first code and writes the rest back; empty or missing = 0.
  const nextExit = () => {
    const f = path.join(state, 'ci-exits.txt');
    let q = []; try { q = fs.readFileSync(f, 'utf8').trim().split(',').filter(Boolean).map(Number); } catch { /* none queued */ }
    const e = q.length ? q.shift() : 0; fs.writeFileSync(f, q.join(','));
    return e;
  };
  return {
    'ci-wait': async () => { const n = count('ci-wait'); return result(nextExit(), `example ci-wait run ${n}`); },
    merge: async () => { count('merge'); return result(0, 'example merge'); },
    docs: async () => { count('docs'); return result(0, '{"dod":{"change-note":"yes"}}'); },
  };
}
