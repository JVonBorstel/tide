// Screen tests of the scene's WebGL2 renderer (pass-app/public/gl.js, SCENE.md "Renderer", decision D-4) in a real browser: with the flag
// the Live tab's pixel stage draws with WebGL2 where the browser has a hardware one, and the picture is the same as Canvas2D's; where it
// has only a software WebGL2 or none, the stage falls back to Canvas2D and still draws; the frame work stays inside the speed budget.
// Each check is named after an acceptance line. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
//   node pass-app/test-scene-gl-screen.mjs [--shots <folder>] [--label before|after] [--speed <runs>] [--app <pass-app folder>]
// --label before takes only the plain screenshots (no flag) and stops, so it can run against main's pass-app (--app). --speed repeats the
// frame-work runs (CPU 4x slower, the speed budget's phone profile) and writes speed-<label>.json beside the shots.
// It drives the real Board server (a throwaway state folder from pass-app/speed/fixture.mjs, made-up work orders only) in headless Chrome or
// Edge over the DevTools protocol: one browser with the graphics chip ({ gpu: true }) and one without (only a software WebGL2, which gl.js
// refuses). The CI runners have no graphics chip: there the WebGL2 checks say so in their names and only the fallback is checked.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import http from 'node:http';
import zlib from 'node:zlib'; import { spawn } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { makeYard } from './speed/fixture.mjs';
import { cdpConnect, signIn } from './test-browser-kit.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const argOf = (n) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : ''; };
const shotsDir = argOf('shots') ? path.resolve(argOf('shots')) : ''; const label = argOf('label') || 'after';
const app = argOf('app') ? path.resolve(argOf('app')) : here; const speedRuns = Number(argOf('speed')) || 1;
const out = [];
const check = (name, pass, detail = '') => out.push({ name: detail && !pass ? `${name} (${String(detail).slice(0, 400)})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'scene-gl-test-'));
const root = makeYard(tmp, 'busy');
const empty = path.join(root, 'empty');

// ---- a PNG screenshot as RGBA pixels (8-bit RGB or RGBA, the five row filters): Node's own zlib, no package ----
function png(buf) {
  let p = 8, w = 0, h = 0, type = 6; const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p), kind = buf.toString('latin1', p + 4, p + 8), d = buf.subarray(p + 8, p + 8 + len);
    if (kind === 'IHDR') { w = d.readUInt32BE(0); h = d.readUInt32BE(4); type = d[9]; } else if (kind === 'IDAT') idat.push(d);
    p += 12 + len;
  }
  const bpp = type === 6 ? 4 : 3, raw = zlib.inflateSync(Buffer.concat(idat)), stride = w * bpp, px = new Uint8Array(w * h * 4);
  let prev = new Uint8Array(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], row = Uint8Array.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? row[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
      row[i] = (row[i] + [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][f]) & 255;
    }
    for (let x = 0; x < w; x++) { px.set(row.subarray(x * bpp, x * bpp + 3), (y * w + x) * 4); px[(y * w + x) * 4 + 3] = bpp === 4 ? row[x * bpp + 3] : 255; }
    prev = row;
  }
  return { w, h, px };
}
const colours = (img) => { const s = new Set(); for (let i = 0; i < img.px.length; i += 4) s.add((img.px[i] << 16) | (img.px[i + 1] << 8) | img.px[i + 2]); return s.size; };
// the stage's art pixels as the screen shows them: the colour at the centre of each art pixel's block (the compositor scales a WebGL2 layer
// and a 2D layer up from different corners, so at a fractional edge one row of device pixels can land on the neighbouring art pixel)
const artGrid = (img, cw, ch) => { const px = new Uint8Array(cw * ch * 4); for (let j = 0; j < ch; j++) for (let i = 0; i < cw; i++) { const x = Math.floor(((i + 0.5) * img.w) / cw), y = Math.floor(((j + 0.5) * img.h) / ch); px.set(img.px.subarray((y * img.w + x) * 4, (y * img.w + x) * 4 + 4), (j * cw + i) * 4); } return { w: cw, h: ch, px }; };
const differ = (a, b) => { if (a.w !== b.w || a.h !== b.h) return Infinity; let n = 0; for (let i = 0; i < a.px.length; i += 4) if (a.px[i] !== b.px[i] || a.px[i + 1] !== b.px[i + 1] || a.px[i + 2] !== b.px[i + 2]) n++; return n; };

// ---- the real Board server (this pass-app, or --app for main's) ----
const port = 21000 + Math.floor(Math.random() * 18000); const base = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, [path.join(app, 'server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
  env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1', PASS_GITHUB: 'off',
    KITCHEN_NOTIFY_LOG: path.join(tmp, 'notify.txt'), PASS_INCOME_DIR: empty, PASS_CAREER_DIR: empty, PASS_HOSTS: '' } });
let serverErr = ''; server.stderr.on('data', (d) => { serverErr = (serverErr + d).slice(-4000); });
const health = () => new Promise((ok) => { const r = http.get(`${base}/api/health`, (res) => { res.resume(); ok(res.statusCode === 200); }); r.on('error', () => ok(false)); });
const browsers = [];

// one headless browser on the Board: { gpu } keeps the graphics chip; { noGl } takes WebGL2 away from every canvas before the Board loads;
// { frozen } stops the page's clocks (Date.now, performance.now and the frame time), so two opens draw the same animation step and the
// same moments (the crews' work cycle and the lights step with the clock even in a still frame)
async function board({ gpu = false, noGl = false, frozen = false } = {}) {
  const key = fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim();
  const cdp = await cdpConnect(path.join(tmp, 'profile-' + browsers.length), { gpu }); browsers.push(cdp.proc); const { send } = cdp;
  const { ev, until } = await signIn(send, base, key);
  await send('Fetch.enable', { patterns: [{ urlPattern: '*/sw.js', requestStage: 'Request' }] });   // no service worker: every open is fresh
  cdp.on((m) => { if (m.method === 'Fetch.requestPaused') send('Fetch.failRequest', { requestId: m.params.requestId, errorReason: 'BlockedByClient' }).catch(() => { }); });
  if (noGl) await send('Page.addScriptToEvaluateOnNewDocument', { source: `{ const g = HTMLCanvasElement.prototype.getContext; HTMLCanvasElement.prototype.getContext = function (k, o) { return k === 'webgl2' ? null : g.call(this, k, o); }; }` });
  if (frozen) await send('Page.addScriptToEvaluateOnNewDocument', { source: `{ const T = ${Date.now()}; Date.now = () => T; performance.now = () => 100000; const r = window.requestAnimationFrame.bind(window); window.requestAnimationFrame = (f) => r(() => f(100000)); }` });
  const hourTz = (h) => { const now = new Date(); let off = h - now.getUTCHours(); if (off > 14) off -= 24; if (off < -12) off += 24; return off === 0 ? 'Etc/GMT' : `Etc/GMT${off > 0 ? '-' : '+'}${Math.abs(off)}`; };
  const phone = async ({ dark = true, still = true, cpu = 1 } = {}) => {
    await send('Emulation.setDeviceMetricsOverride', { width: 412, height: 900, deviceScaleFactor: 2.625, mobile: true });
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }, { name: 'prefers-reduced-motion', value: still ? 'reduce' : 'no-preference' }] });
    await send('Emulation.setTimezoneOverride', { timezoneId: hourTz(13) });
    await send('Emulation.setCPUThrottlingRate', { rate: cpu });
  };
  // the Live tab, where the pixel stage is; q: the address's query (?gl, ?hud)
  const open = async (q = '') => {
    await send('Page.navigate', { url: 'about:blank' }); await sleep(80); await send('Page.navigate', { url: `${base}/${q}#/cooks` });
    await until('document.readyState === "complete" && location.href.startsWith("http")');
    const ok = await until(`(() => { const c = document.querySelector('#scene-live .px-canvas'); return !!c && c.getBoundingClientRect().height > 50; })()`, 15000);
    await sleep(900); return ok;
  };
  // which renderer draws, as Settings > About says it
  const renderer = async () => {
    await ev(`document.getElementById('menu-btn').click()`); await until(`/Scene renderer/.test(document.getElementById('menu-body').textContent)`, 4000);
    const r = await ev(`(() => { const d = [...document.querySelectorAll('#menu-body dt')].find((t) => t.textContent === 'Scene renderer'); return { says: d?.nextElementSibling?.textContent || '', sw: document.getElementById('gl-switch')?.checked ?? null }; })()`);
    await ev(`document.querySelector('#menu-sheet [data-close]').click()`); await sleep(300); return r;
  };
  const canvasShot = async () => {
    // the canvas alone: the links, words and chips over it (page elements, not the renderer's) are hidden for the shot
    const r = await ev(`(() => { const c = document.querySelector('#scene-live .px-canvas'), b = c.getBoundingClientRect(); for (const e of document.querySelectorAll('#scene-live .px-stage > :not(canvas)')) e.style.visibility = 'hidden'; return { x: b.left + scrollX, y: b.top + scrollY, w: b.width, h: b.height, cw: c.width, ch: c.height }; })()`);
    const s = await send('Page.captureScreenshot', { format: 'png', clip: { x: r.x, y: r.y, width: r.w, height: r.h, scale: 1 } });
    await ev(`for (const e of document.querySelectorAll('#scene-live .px-stage > :not(canvas)')) e.style.visibility = '';`);
    return artGrid(png(Buffer.from(s.data, 'base64')), r.cw, r.ch);
  };
  // the canvas once it has settled: two shots 400 ms apart alike (the live state can still be arriving on a busy machine)
  const stillShot = async () => { let a = await canvasShot(); for (let i = 0; i < 12; i++) { await sleep(400); const b = await canvasShot(); if (!differ(a, b)) return b; a = b; } return a; };
  const shot = async (name) => { if (!shotsDir) return; fs.mkdirSync(shotsDir, { recursive: true }); const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(shotsDir, name), Buffer.from(r.data, 'base64')); };
  // the frame meter's own numbers (frame-meter.js, ?hud): "Run 5 s" draws every frame for 5 s; the stage's work per frame (tick + draw)
  const frameWork = async (q) => {
    await phone({ still: false, cpu: 4 }); await open(q);
    await until(`!!document.querySelector('.px-meter button')`, 5000); await ev(`document.querySelector('.px-meter button').click()`); await sleep(5600);
    const line = await ev(`document.querySelector('.px-meter div')?.textContent || ''`); await phone();
    const m = /work p50 ([\d.]+) · p95 ([\d.]+) · max ([\d.]+) ms/.exec(line);
    return m ? { p50: +m[1], p95: +m[2], max: +m[3], line } : { line };
  };
  return { send, ev, until, phone, open, renderer, canvasShot, stillShot, shot, frameWork, close: () => cdp.close() };
}
const median = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.floor(s.length / 2)] : null; };

try {
  for (let i = 0; i < 160 && !(await health()); i++) await sleep(150);
  const target = JSON.parse(fs.readFileSync(path.join(here, 'speed', 'budget.json'), 'utf8')).metrics.frameP95Ms.target;

  // ---------- before (main, no flag): the Live tab's scene at 412 px, dark and light ----------
  if (label === 'before') {
    const B = await board({ gpu: true }); await B.phone(); await B.open(); await B.shot('scene-412-dark-before.png');
    await B.phone({ dark: false }); await B.open(); await B.shot('scene-412-light-before.png');
    const speed = []; for (let i = 0; i < speedRuns; i++) speed.push(await B.frameWork('?hud'));
    if (shotsDir) fs.writeFileSync(path.join(shotsDir, 'speed-before.json'), JSON.stringify({ canvas2d: speed }, null, 1));
    B.close(); throw null;
  }

  // ---------- with the graphics chip: WebGL2 draws the same scene as Canvas2D ----------
  const F = await board({ gpu: true, frozen: true }); await F.phone();
  const hw = await F.ev(`(() => { const c = document.createElement('canvas'); return !!c.getContext('webgl2', { failIfMajorPerformanceCaveat: true }); })()`);
  let same = null; const tries = [];
  for (let i = 0; i < 3 && !same; i++) {   // the wall clock's minute hand can move between the two opens: try again then
    const okGl = await F.open('?gl'); const gl = await F.stillShot(); const okC2 = await F.open('?gl=0'); const c2 = await F.stillShot();
    const d = differ(gl, c2); tries.push(d); if (okGl && okC2 && d === 0) same = { w: gl.w, h: gl.h, colours: colours(gl) };
  }
  F.close(); const G = await board({ gpu: true }); await G.phone();
  await G.open('?gl'); const rG = await G.renderer();
  if (hw) {
    check(`GlScreen_WebGL2Draws: with ?gl and a hardware WebGL2 the Live tab's stage draws with WebGL2 (Settings > About: "${rG.says}")`, rG.says === 'WebGL2', JSON.stringify(rG));
    check(`GlScreen_SameScene: renders the same scene as Canvas2D on a fixture (the busy fixture Yard, 412 px, the frame clock held still, ${same ? same.w + 'x' + same.h + ' art pixels, each compared, ' + same.colours + ' colours' : 'no match'}; pixels that differ per try: ${tries.join(', ')})`,
      !!same && same.colours >= 8, JSON.stringify(tries));
  } else {
    check('GlScreen_WebGL2Draws: not checked here (this machine has no hardware WebGL2; the stage falls back, checked below)', rG.says.startsWith('Canvas2D'), JSON.stringify(rG));
    check(`GlScreen_SameScene: not checked here (no hardware WebGL2); the fallback is the Canvas2D picture (pixels that differ per try: ${tries.join(', ')})`, tries.includes(0), JSON.stringify(tries));
  }
  await G.shot('scene-412-dark-webgl2.png');
  await G.ev(`document.getElementById('menu-btn').click()`); await G.until(`/Scene renderer/.test(document.getElementById('menu-body').textContent)`, 4000);
  await G.ev(`document.querySelector('#menu-body dt:nth-of-type(1)') && [...document.querySelectorAll('#menu-body dt')].find((t) => t.textContent === 'Scene renderer').scrollIntoView({ block: 'center' })`); await sleep(400);
  await G.shot('settings-412-dark-webgl2.png'); await G.ev(`document.querySelector('#menu-sheet [data-close]').click()`); await sleep(300);
  await G.phone({ dark: false }); await G.open('?gl'); await G.shot('scene-412-light-webgl2.png'); await G.phone();
  // on by default (no ?gl, nothing kept); ?gl=0 turns it off for the visit; the Settings switch turns it off on this phone, and ?gl turns that phone on for the visit
  await G.open(); const dflt = await G.renderer(); await G.open('?gl=0'); const offVisit = await G.renderer();
  await G.open(); await G.ev(`document.getElementById('menu-btn').click()`); await G.until(`!!document.getElementById('gl-switch')`, 4000);
  await G.ev(`document.getElementById('gl-switch').click()`); await sleep(1200); await G.ev(`document.querySelector('#menu-sheet [data-close]').click()`); await sleep(300);
  await G.open(); const keptOff = await G.renderer(); await G.open('?gl'); const onVisit = await G.renderer();
  const drawsGl = (r) => (hw ? r.says === 'WebGL2' : r.says.startsWith('Canvas2D'));
  check(`GlScreen_DefaultOn: with nothing kept the stage draws with ${hw ? 'WebGL2' : 'the fallback'} and the switch is on ("${dflt.says}"); ?gl=0 turns it off for the visit ("${offVisit.says}"); the switch turned off keeps Canvas2D on this phone ("${keptOff.says}"), and ?gl turns it on for the visit ("${onVisit.says}")`,
    dflt.sw === true && drawsGl(dflt) && offVisit.says.startsWith('Canvas2D') && keptOff.sw === false && keptOff.says.startsWith('Canvas2D') && drawsGl(onVisit), JSON.stringify({ dflt, offVisit, keptOff, onVisit }));
  // the frame budget in the browser: the frame meter's work p95 (tick + draw + the WebGL2 flush) at CPU 4x slower, each renderer
  const sp = { webgl2: [], canvas2d: [] };
  for (let i = 0; i < speedRuns; i++) { sp.webgl2.push(await G.frameWork('?gl&hud')); sp.canvas2d.push(await G.frameWork('?gl=0&hud')); }
  const p95G = median(sp.webgl2.map((r) => r.p95).filter((v) => v != null)), p95C = median(sp.canvas2d.map((r) => r.p95).filter((v) => v != null));
  check(`GlScreen_FrameBudget: frame time inside the speed budget in the browser (CPU 4x slower, ${speedRuns} run(s) of 5 s: ${hw ? 'WebGL2' : 'the fallback'} p95 ${p95G} ms, Canvas2D p95 ${p95C} ms; budget ${target} ms)`,
    p95G != null && p95G <= target && p95C != null, JSON.stringify(sp));
  G.close();

  // ---------- no WebGL2 at all, and only a software one: the stage falls back to Canvas2D and still draws ----------
  const N = await board({ gpu: true, noGl: true }); await N.phone();
  const okN = await N.open('?gl'); const rN = await N.renderer(); const imgN = await N.canvasShot();
  check(`GlScreen_FallbackNoWebGL2: falls back when WebGL2 is missing (getContext('webgl2') gives null): the stage draws with Canvas2D (${colours(imgN)} colours) and Settings > About says why ("${rN.says}")`,
    okN && /^Canvas2D \(WebGL2 off: no WebGL2/.test(rN.says) && colours(imgN) >= 8, JSON.stringify(rN));
  await N.shot('scene-412-dark-fallback.png');
  await N.phone({ dark: false }); await N.open('?gl'); await N.shot('scene-412-light-fallback.png'); N.close();
  const S = await board(); await S.phone();
  let okS = false, rS = null, imgS = null; const triesS = [];
  for (let i = 0; i < 3 && triesS.at(-1) !== 0; i++) {   // the live scene moves between the two opens: try again then
    okS = await S.open('?gl'); rS = await S.renderer(); imgS = await S.canvasShot(); await S.open('?gl=0'); triesS.push(differ(imgS, await S.canvasShot()));
  }
  check(`GlScreen_FallbackSoftware: a software-only WebGL2 (no graphics chip) is refused: the stage draws with Canvas2D, the same picture as with WebGL2 turned off (pixels that differ per try: ${triesS.join(', ')}), and Settings > About says why ("${rS.says}")`,
    okS && /^Canvas2D \(WebGL2 off: no WebGL2/.test(rS.says) && colours(imgS) >= 8 && triesS.includes(0), JSON.stringify(rS));
  await S.open('?gl'); await S.ev(`document.getElementById('menu-btn').click()`); await S.until(`!!document.getElementById('gl-switch')`, 4000);
  await S.ev(`[...document.querySelectorAll('#menu-body dt')].find((t) => t.textContent === 'Scene renderer').scrollIntoView({ block: 'center' })`); await sleep(400);
  await S.shot('settings-412-dark-fallback.png'); S.close();
  if (shotsDir) fs.writeFileSync(path.join(shotsDir, `speed-${label}.json`), JSON.stringify({ hardwareWebGL2: hw, ...sp }, null, 1));
} catch (e) { if (e !== null) check('the WebGL2 screen tests ran to the end without a crash', false, (e?.stack || e?.message || String(e)) + ' ' + serverErr.slice(-300)); }
finally {
  for (const b of browsers) try { b.kill(); } catch { }
  try { server.kill(); } catch { }
  await sleep(500); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}
console.log(JSON.stringify(out));
process.exit(0);
