// Owns running every engine suite (core/engine) and printing one counts line: "Engine tests: N passed, M failed, K skipped".
// Called by tests/Test-Engine.ps1 (the Yard's tests Step, verify-all) and by hand: node tests/core/engine/test-engine.mjs [suite ...]
// Suites: wo (lifecycle edges, merge gate, stuck card), activity (contract, once, stations), runner (the fake engine: kill test, timer
// after restart, signal wakes, backoff caps), governor, converge (dry runs, the yes rules both ways, schedules), temporal (skips,
// saying why, until Jordan's install taps).
import { finish, check } from './lib.mjs';

const SUITES = ['wo', 'activity', 'runner', 'governor', 'converge', 'temporal'];
const pick = process.argv.slice(2).length ? process.argv.slice(2) : SUITES;
for (const name of pick) {
  if (!SUITES.includes(name)) { check(`suite ${name} exists`, false, `known: ${SUITES.join(', ')}`); continue; }
  try { await (await import(`./test-${name}.mjs`)).run(); } catch (err) { check(`suite ${name} ran to the end`, false, err.stack.split('\n').slice(0, 3).join(' / ')); }
}
finish('Engine tests');
