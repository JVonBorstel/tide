// Owns running the ledger's suites (core/ledger) and printing one counts line: the event store, the importers, the view and its queries,
// the export, the CLI and parity (ledger-core.mjs), the old items, share.mjs and redaction (ledger-share.mjs); shared pieces in lib.mjs.
// Called by tests/Test-CoreLedger.ps1 (the Yard's tests Step, verify-all) and by hand: node tests/core/ledger/test-ledger.mjs
// node:sqlite needs --experimental-sqlite on Node 22: this file starts itself again with the flag only when the module is missing.
// All data is synthetic and made at run time in a temp folder (WO-2001, example-owner/example-repo, dates in 2030); nothing is read from
// the live state folder.
import fs from 'node:fs'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';

let hasSqlite = true; try { await import('node:sqlite'); } catch { hasSqlite = false; }
if (!hasSqlite && !process.env.LEDGER_SQLITE_RESPAWNED) {
  const r = spawnSync(process.execPath, ['--experimental-sqlite', '--disable-warning=ExperimentalWarning', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit', env: { ...process.env, LEDGER_SQLITE_RESPAWNED: '1' } });
  process.exit(r.status ?? 1);
}
const { results, check, tmp } = await import('./lib.mjs');   // (after the restart above: lib.mjs makes the temp folder)
const C = await import('./ledger-core.mjs'); const S = await import('./ledger-share.mjs');

try {
  await S.testSecrets();
  await S.testRedactionHardening();
  await S.testShare37();
  await S.testShare();
  await S.testLegacy();
  await S.testReview31();
  await C.testStore(); await C.testYard(); await C.testGithub(); await C.testLocal(); C.testView(); C.testExport();
  const db = await C.testCli(); await C.testParity(db);
} catch (e) { check(`the suite ran to the end (${String(e?.stack || e).split('\n').slice(0, 3).join(' | ')})`, false); }
finally { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { } }
for (const r of results) if (!r.pass) console.log(`FAIL: ${r.name}`);
const failed = results.filter((r) => !r.pass).length;
console.log(`Ledger tests: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
