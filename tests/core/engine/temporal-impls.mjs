// Owns the test-double activities the Temporal worker loads in tests (worker.mjs --impls): ci-wait, merge and docs that only count
// their runs in files under the scratch state folder. ci-wait's exit codes come from <state>/ci-exits.txt (for example "11,0").
// Called by core/engine/temporal/worker.mjs when tests/core/engine/test-temporal.mjs starts it.
import fs from 'node:fs'; import path from 'node:path';
import { result } from '../../../core/engine/activity.mjs';

export function impls({ state }) {
  const count = (name) => { const f = path.join(state, `${name}.count`); const n = (fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8')) : 0) + 1; fs.writeFileSync(f, String(n)); return n; };
  const exits = () => { try { return fs.readFileSync(path.join(state, 'ci-exits.txt'), 'utf8').trim().split(',').map(Number); } catch { return [0]; } };
  return {
    'ci-wait': async () => { const n = count('ci-wait'); const e = exits(); return result(e[Math.min(n, e.length) - 1], `example ci-wait run ${n}`); },
    merge: async () => { count('merge'); return result(0, 'example merge'); },
    docs: async () => { count('docs'); return result(0, '{"dod":{"change-note":"yes"}}'); },
  };
}
