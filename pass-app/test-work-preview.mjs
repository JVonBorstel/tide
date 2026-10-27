// Owns the tests of the per-PR preview launcher (pass-app/work/preview.mjs, lane L5, WO-UPG-L5-3). Each test is named after an acceptance
// line of the L5 brief (work breakdown "previews": fixture data only, a test proves the state folder is not read; the port is freed after
// 2 h) or a rule of preview.mjs. Called by tests/Test-Work.ps1 (CI's Core step) and by hand: node pass-app/test-work-preview.mjs
// It starts this checkout's own Board as the "PR worktree", against a decoy live state folder under TEMP (never the real one).
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url)); const repo = path.resolve(here, '..');
const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'work-preview-test-'));
// the decoy "live" state folder: where the Board would look if anything leaked (LOCALAPPDATA\brain-kitchen), with a canary order
const decoyApp = path.join(tmp, 'decoy-appdata'); const decoy = path.join(decoyApp, 'brain-kitchen');
fs.mkdirSync(path.join(decoy, 'jobs'), { recursive: true });
fs.writeFileSync(path.join(decoy, 'jobs', 'J999.json'), JSON.stringify({ id: 'J999', name: 'improve: CANARY-LIVE-ORDER', status: 'running', steps: [], history: [] }));
const decoyBefore = fs.readdirSync(decoy).sort().join();
process.env.LOCALAPPDATA = decoyApp; delete process.env.BRAIN_KITCHEN;
const { startPreview, stopPreview, listPreviews, portFree, stopAll, writeFixture, liveStateDirs } = await import('./work/preview.mjs');

async function state(p) {
  const key = fs.readFileSync(path.join(p.scratch, 'state', 'pass-key.txt'), 'utf8').trim();
  const r = await fetch(`${p.url}api/state`, { headers: { Authorization: `Bearer ${key}` } });
  return { code: r.status, text: await r.text() };
}

try {
  check('the decoy live folder is what the launcher guards', liveStateDirs().includes(path.resolve(decoy).toLowerCase()));

  // ---- fixture data only ----
  const p = await startPreview({ worktree: repo, ttlMs: 60000 });
  check('a preview starts this worktree\'s Board on a local port', p.ok === true && /^http:\/\/127\.0\.0\.1:\d+\/$/.test(p.url), JSON.stringify(p));
  const s = p.ok ? await state(p) : { code: 0, text: '' };
  check('fixture data only: the preview shows the synthetic orders', s.code === 200 && s.text.includes('example sunrise colour') && s.text.includes('example empty state'), `${s.code} ${s.text.slice(0, 120)}`);
  check('fixture data only: the state folder is not read (the canary order in the live folder never shows)', s.code === 200 && !s.text.includes('CANARY-LIVE-ORDER'));
  check('fixture data only: the live folder is not written either (no pass key, no log, nothing new)', fs.readdirSync(decoy).sort().join() === decoyBefore, fs.readdirSync(decoy).join());
  check('the preview has its own pass key in its scratch folder, not the live one', p.ok && fs.existsSync(path.join(p.scratch, 'state', 'pass-key.txt')) && !fs.existsSync(path.join(decoy, 'pass-key.txt')));
  check('it never changes Tailscale: the answer only names the serve command for a card', p.ok && p.serve === `tailscale serve --bg --https=${p.port} http://127.0.0.1:${p.port}`);
  const noKey = p.ok ? await fetch(`${p.url}api/state`) : { status: 0 };
  check('the preview keeps the Board\'s auth: no key, 401', noKey.status === 401, String(noKey.status));
  check('the preview is listed while it runs', listPreviews().some((x) => x.id === p.id && x.port === p.port));
  check('stopping a preview frees its port and removes its scratch folder', p.ok && await stopPreview(p.id) && await portFree(p.port) && !fs.existsSync(p.scratch), p.scratch);

  // ---- refusals ----
  const inLive = path.join(decoy, 'wt'); fs.mkdirSync(path.join(inLive, 'pass-app'), { recursive: true }); fs.writeFileSync(path.join(inLive, 'pass-app', 'server.mjs'), '');
  const r1 = await startPreview({ worktree: inLive });
  check('a worktree inside the live state folder is refused', r1.ok === false && /live state folder/.test(r1.error), JSON.stringify(r1));
  fs.rmSync(inLive, { recursive: true, force: true });
  const r2 = await startPreview({ worktree: repo, fixture: decoy });
  check('the live state folder as the fixture is refused', r2.ok === false && /fixture data only/.test(r2.error), JSON.stringify(r2));
  const r2b = await startPreview({ worktree: repo, fixture: decoyApp });
  check('a fixture folder that holds the live state folder is refused', r2b.ok === false && /fixture data only/.test(r2b.error), JSON.stringify(r2b));
  const plain = path.join(tmp, 'plain'); fs.mkdirSync(plain);
  const r3 = await startPreview({ worktree: repo, fixture: plain });
  check('a fixture that does not say it is synthetic (no FIXTURE.txt) is refused', r3.ok === false && /FIXTURE\.txt/.test(r3.error), JSON.stringify(r3));
  const r4 = await startPreview({ worktree: tmp });
  check('a folder with no pass-app/server.mjs is refused', r4.ok === false && /no pass-app\/server\.mjs/.test(r4.error), JSON.stringify(r4));
  check('nothing was started by the refusals', listPreviews().length === 0);

  // ---- a given fixture is copied, not used in place ----
  const fx = path.join(tmp, 'fixture'); writeFixture(fx); const fxBefore = fs.readdirSync(fx).sort().join();
  // ---- the port is freed after the time limit (2 h; here 2.5 s) ----
  const q = await startPreview({ worktree: repo, fixture: fx, ttlMs: 2500 });
  const qs = q.ok ? await state(q) : { code: 0, text: '' };
  check('a given fixture is served from a copy (the fixture folder is unchanged)', q.ok && qs.code === 200 && qs.text.includes('example tidy') && fs.readdirSync(fx).sort().join() === fxBefore, `${qs.code}`);
  check('the preview names when it ends', q.ok && Math.abs(Date.parse(q.expires) - Date.now() - 2500) < 15000);
  await sleep(5000);
  check('the port is freed after the time limit: the process is gone and the port is free', q.ok && await portFree(q.port), String(q.port));
  check('the port is freed after the time limit: the scratch folder is removed and the preview unlisted', q.ok && !fs.existsSync(q.scratch) && listPreviews().length === 0, q.scratch);
} catch (e) { check('the preview tests ran to the end without a crash', false, e.stack || e.message); }
finally { await stopAll(); try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { } }

const failed = results.filter((r) => !r.pass);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}: ${r.name}`);
console.log(`Work tests: ${results.length - failed.length} passed, ${failed.length} failed (previews, ${Math.round((Date.now() - t0) / 1000)} s)`);
process.exit(failed.length ? 1 : 0);
