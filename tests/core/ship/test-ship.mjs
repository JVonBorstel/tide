// Owns the run of the ship path's suite (core/ship, scripts/check-*.mjs): every tests/core/ship/test-*.mjs, one named line per check.
// Called by tests/Test-Ship.ps1 (the Yard's tests Step, verify-all), the ci.yml "Ship" step, and by hand: node tests/core/ship/test-ship.mjs
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath, pathToFileURL } from 'node:url';
import { checker, cleanup } from './lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const only = process.argv[2] || '';
const files = fs.readdirSync(here).filter((f) => /^test-.+\.mjs$/.test(f) && f !== 'test-ship.mjs' && f.includes(only)).sort();
/** @type {{ name: string, pass: boolean }[]} */
const results = [];
const check = checker(results);
try {
  for (const f of files) {
    const mod = await import(pathToFileURL(path.join(here, f)).href);
    try { await mod.run(check); } catch (e) { check(`${f}: ran to the end`, false, /** @type {Error} */ (e).stack || String(e)); }
  }
} finally { cleanup(); }
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}: ${r.name}`);
const failed = results.filter((r) => !r.pass).length;
console.log(`Ship tests: ${results.length - failed} passed, ${failed} failed (${files.length} files)`);
process.exitCode = failed || !results.length ? 1 : 0;
