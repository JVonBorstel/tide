// (The stage is the pixel scene on main and the City on the City home; both are measured.) The speed budget's scripted Board sessions in headless Chrome on a throttled phone profile: a busy Yard (cold open, scene, taps,
// a view change, a pinch zoom) and a calm one (idle wake-ups). Called by pass-app/speed/run.mjs; the probe is pass-app/speed/probe.js.
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PROBE = fs.readFileSync(path.join(here, 'probe.js'), 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// the phone: a 412 px wide touch screen at 3x (a large Android flagship), 4x slower CPU, the tailnet's 40 ms and 10 Mbps
export const PROFILE = { width: 412, height: 915, dpr: 3, cpu: 4, rttMs: 40, mbps: 10 };
export const profileLine = (p = PROFILE) => `${p.width}x${p.height} CSS px at ${p.dpr}x, touch, CPU ${p.cpu}x slower, ${p.rttMs} ms RTT, ${p.mbps} Mbps`;

async function openPage(browser, srv) {
  const context = await browser.newContext({ viewport: { width: PROFILE.width, height: PROFILE.height }, deviceScaleFactor: PROFILE.dpr, isMobile: true, hasTouch: true,
    serviceWorkers: 'block', reducedMotion: 'no-preference', extraHTTPHeaders: { Authorization: 'Bearer ' + srv.key } });
  const page = await context.newPage(); const cdp = await context.newCDPSession(page);
  await cdp.send('Performance.enable');
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: PROFILE.cpu });
  await cdp.send('Network.enable');
  const bps = (PROFILE.mbps * 1e6) / 8;
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: PROFILE.rttMs, downloadThroughput: bps, uploadThroughput: bps });
  await page.addInitScript(PROBE);
  return { context, page, cdp, notes: [] };
}
const setPhase = (page, p) => page.evaluate((x) => { window.__speed.phase = x; }, p);
const metric = async (cdp, name) => (await cdp.send('Performance.getMetrics')).metrics.find((m) => m.name === name)?.value ?? null;
// the Board's stage: the pixel scene slot (#scene-pass) on main, the City (#city) on the City home, which replaces that slot.
// Looked up on the page, so one scenario measures either; a page with neither is noted (a warning), never a failure.
const STAGE = { scene: { sel: '#scene-pass', canvas: '#scene-pass canvas', legend: '.px-info', crew: '#scene-pass .px-chef' },
  city: { sel: '#city', canvas: '#city canvas', legend: '#city-key', crew: null } };
const warn = (S, msg) => { S.notes.push(msg); console.log('::warning title=Speed scenario::' + msg); };
const stageKind = (page) => page.evaluate(() => (document.getElementById('scene-pass') ? 'scene' : document.getElementById('city') ? 'city' : null)).catch(() => null);
// opens the Board and waits for its first useful paint, then (up to 20 s) for the pixel stage (scene or City canvas) to appear.
// Nothing here is fatal: a stage or paint that never comes is a warning and the metric it feeds is left unmeasured.
async function load(S, srv) {
  await S.page.goto('http://127.0.0.1:' + srv.port + '/#/pass', { waitUntil: 'load', timeout: 60000 });
  S.kind = await stageKind(S.page);
  if (!S.kind) warn(S, 'the Board has neither #scene-pass nor #city; first useful paint, scene frames and zoom are not measured');
  try { await S.page.waitForFunction(() => window.__speed.fup !== null, null, { timeout: S.kind ? 30000 : 3000 }); }
  catch { if (S.kind) warn(S, 'no first useful paint within 30 s (waited for the headline and the ' + STAGE[S.kind].sel + ' stage); carried on'); }
  if (!S.kind) return 'none';
  try { await S.page.waitForSelector(STAGE[S.kind].canvas, { timeout: 20000 }); return S.kind === 'city' ? 'city' : 'pixel'; }
  catch { warn(S, S.kind === 'city' ? 'the City canvas did not appear; measured the page without it' : 'the pixel stage did not load; measured the still card'); return S.kind === 'city' ? 'city-none' : 'still'; }
}
// a tap that may find nothing to tap (a fixture or a view without that control): noted, never fatal
async function tap(S, sel, label) {
  try { await S.page.locator(sel).first().tap({ timeout: 5000, force: true }); return true; } catch { S.notes.push('could not tap ' + label); return false; }
}
// a two-finger pinch over the stage (the scene, or the City) through Chrome's own gesture synthesis; it gives up after 20 s on a slow runner
async function pinch(S, scale) {
  const box = S.kind ? await S.page.locator(STAGE[S.kind].sel).boundingBox().catch(() => null) : null;
  if (!box) { S.notes.push('no stage to pinch'); return; }
  const go = S.cdp.send('Input.synthesizePinchGesture', { x: Math.round(box.x + box.width / 2), y: Math.round(box.y + box.height / 2), scaleFactor: scale, relativeSpeed: 400, gestureSourceType: 'touch' });
  const r = await Promise.race([go.then(() => 'ok', () => 'failed'), sleep(20000).then(() => 'timeout')]);
  if (r !== 'ok') S.notes.push('pinch zoom ' + r);
}
async function interactions(S) {
  await setPhase(S.page, 'tap');
  const st = S.kind && STAGE[S.kind];
  if (st && await tap(S, st.legend, S.kind === 'city' ? 'the City legend chip' : 'the scene legend chip')) { await sleep(900); await S.page.keyboard.press('Escape'); await sleep(600); }
  if (st?.crew && await tap(S, st.crew, 'a crew member')) { await sleep(3600); await S.page.keyboard.press('Escape'); await sleep(800); }
  if (await tap(S, 'nav.bar a[data-view="cooks"]', 'the Live tab')) await sleep(1500);
  if (await tap(S, 'nav.bar a[data-view="pass"]', 'the Board tab')) await sleep(1500);
  // a view change (today a View Transition; the drone-camera flight replaces it and is measured here)
  await setPhase(S.page, 'flight');
  if (await tap(S, 'nav.bar a[data-view="world"]', 'the World tab')) await sleep(2000);
  if (await tap(S, 'nav.bar a[data-view="pass"]', 'the Board tab')) await sleep(2000);
}
// the busy Yard: cold open, 8 s of the scene at work, taps, a view change, a pinch in and out; then the heap after a collection
export async function busyRun(browser, srv) {
  const S = await openPage(browser, srv);
  try {
    const stage = await load(S, srv);
    await setPhase(S.page, 'busy'); await sleep(8000);
    await interactions(S);
    await setPhase(S.page, 'zoom'); await pinch(S, 2); await sleep(500); await pinch(S, 0.5); await sleep(500);
    await setPhase(S.page, 'end');
    await S.cdp.send('HeapProfiler.collectGarbage');
    const heap = await S.cdp.send('Runtime.getHeapUsage');
    const nodes = await metric(S.cdp, 'Nodes');
    const speed = await S.page.evaluate(() => ({ ...window.__speed, canvases: document.querySelectorAll('canvas').length }));
    return { speed, stage, kind: S.kind || null, heapMB: heap.usedSize / 1048576, nodes, canvases: speed.canvases, notes: S.notes };
  } finally { await S.context.close(); }
}
// the calm Yard (nothing building, nothing waiting): after it settles, how often the page wakes for a frame and how much it scripts
export async function calmRun(browser, srv, seconds = 10) {
  const S = await openPage(browser, srv);
  try {
    await load(S, srv); await sleep(3000);
    await setPhase(S.page, 'idle');
    const r0 = await S.page.evaluate(() => window.__speed.rafs), s0 = await metric(S.cdp, 'ScriptDuration');
    await sleep(seconds * 1000);
    const r1 = await S.page.evaluate(() => window.__speed.rafs), s1 = await metric(S.cdp, 'ScriptDuration');
    return { rafPerSec: (r1 - r0) / seconds, scriptPct: s0 === null || s1 === null ? null : ((s1 - s0) / seconds) * 100, notes: S.notes };
  } finally { await S.context.close(); }
}
