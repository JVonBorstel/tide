// The screen tests' browser: headless Chrome or Edge over the DevTools protocol (Node's own WebSocket; no package). Shared by
// pass-app/test-work-ui.mjs, test-status-line.mjs, test-board-rows.mjs and test-scene-gl-screen.mjs. cdpConnect(profileDir) starts the
// browser on a throwaway profile and returns { send(method, params), on(listener), close(), proc } for its first page; the caller kills proc
// when done. signIn (below) signs that browser in to the Board; boardPage (below) is the whole signed-in Board for the status-line and
// board-rows tests. { gpu: true } keeps the graphics chip (a hardware WebGL2 where the machine has one); by default the browser has only a
// software one. A cold start on a CI runner can take over 10 s, so it waits up to 30 s for the DevTools port.
import fs from 'node:fs'; import path from 'node:path'; import crypto from 'node:crypto'; import { spawn } from 'node:child_process'; import { fileURLToPath } from 'node:url';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// CHROME_PATH, else the usual places (the GitHub runners have Google Chrome; Windows has Edge)
export function chromePath() {
  const c = [process.env.CHROME_PATH, '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser',
    'C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'];
  return c.find((p) => p && fs.existsSync(p)) || null;
}
export async function cdpConnect(profileDir, { gpu = false } = {}) {
  const exe = chromePath(); if (!exe) throw new Error('no Chrome or Edge found (set CHROME_PATH)');
  const proc = spawn(exe, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profileDir}`, '--no-first-run', '--no-default-browser-check', ...(gpu ? [] : ['--disable-gpu']), '--no-sandbox', '--hide-scrollbars', 'about:blank'], { stdio: 'ignore', windowsHide: true });
  let dport = 0; for (let i = 0; i < 300 && !dport && proc.exitCode === null; i++) { try { dport = Number(fs.readFileSync(path.join(profileDir, 'DevToolsActivePort'), 'utf8').split('\n')[0]); } catch { } if (!dport) await sleep(100); }
  if (!dport) { const code = proc.exitCode; proc.kill(); throw new Error(`the browser did not open its DevTools port in 30 s${code === null ? '' : ' (it exited with ' + code + ')'}`); }
  const list = await (await fetch(`http://127.0.0.1:${dport}/json/list`)).json();
  const ws = new WebSocket(list.find((t) => t.type === 'page').webSocketDebuggerUrl);
  await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = no; });
  let id = 0; const wait = new Map(); const listeners = [];
  ws.onmessage = (m) => { const j = JSON.parse(m.data); if (j.id && wait.has(j.id)) { const w = wait.get(j.id); wait.delete(j.id); j.error ? w.no(new Error(j.error.message)) : w.ok(j.result); } else if (j.method) for (const l of listeners) l(j); };
  const send = (method, params = {}) => new Promise((ok, no) => { const i = ++id; wait.set(i, { ok, no }); ws.send(JSON.stringify({ id: i, method, params })); });
  return { send, on: (f) => listeners.push(f), close: () => ws.close(), proc };
}
// signIn(send, base, key) puts a signed session cookie for the Board at base in the browser, as /login would give (the pass key never goes
// in a URL), and returns { ev, until }: ev(expr) runs expr in the page and gives back its value; until(expr, ms) waits up to ms (default
// { wait }, 10 s) for expr to be true, trying every { step } ms (default 120).
export async function signIn(send, base, key, { wait = 10000, step = 120 } = {}) {
  const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; };
  const until = async (expr, ms = wait) => { const end = Date.now() + ms; while (Date.now() < end) { try { if (await ev(expr)) return true; } catch { } await sleep(step); } return false; };
  const exp = Math.floor(Date.now() / 1000) + 3600; const nonce = crypto.randomBytes(16).toString('hex');
  const mac = crypto.createHmac('sha256', Buffer.from(key)).update(`chef-session|${exp}|${nonce}`).digest('hex');
  await send('Network.enable'); await send('Page.enable');
  await send('Network.setCookie', { name: 'pass', value: `${exp}.${nonce}.${mac}`, url: base, httpOnly: true });
  return { ev, until };
}

// boardPage: the real Board server on a throwaway state folder (root), signed in through signIn, no service worker (every open is fresh),
// and /api/towers answered by towers() (made-up projects). Returns the page's helpers: ev(expr), until(expr, ms), phone(width, height,
// {dark, hour}), open(hash), shot(name), plus send, server, cdp, base. nodeArgs and env go to the server's node (the Work tab's store needs
// --experimental-sqlite on node 22).
export async function boardPage({ root, tmp, towers, shotsDir = '', nodeArgs = [], env = {} }) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const empty = path.join(root, 'empty'); fs.mkdirSync(empty, { recursive: true });
  const port = 21000 + Math.floor(Math.random() * 18000); const base = `http://127.0.0.1:${port}`;
  const server = spawn(process.execPath, [...nodeArgs, path.join(here, 'server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
    env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1', PASS_GITHUB: 'off',
      KITCHEN_NOTIFY_LOG: path.join(tmp, 'notify.txt'), PASS_INCOME_DIR: empty, PASS_CAREER_DIR: empty, PASS_HOSTS: '', ...env } });
  server.stderr.on('data', () => { });
  const health = () => fetch(`${base}/api/health`).then((r) => r.status === 200, () => false);
  for (let i = 0; i < 160 && !(await health()); i++) await sleep(150);
  const key = fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim();
  const cdp = await cdpConnect(path.join(tmp, 'profile')); const { send } = cdp;
  const { ev, until } = await signIn(send, base, key);
  await send('Fetch.enable', { patterns: [{ urlPattern: '*/api/towers*', requestStage: 'Request' }, { urlPattern: '*/sw.js', requestStage: 'Request' }] });
  cdp.on((m) => {
    if (m.method !== 'Fetch.requestPaused') return; const p = m.params;
    if (/\/sw\.js$/.test(p.request.url)) return void send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'BlockedByClient' }).catch(() => { });
    send('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'application/json' }], body: Buffer.from(JSON.stringify(towers())).toString('base64') }).catch(() => { });
  });
  const hourTz = (h) => { const now = new Date(); let off = h - now.getUTCHours(); if (off > 14) off -= 24; if (off < -12) off += 24; return off === 0 ? 'Etc/GMT' : `Etc/GMT${off > 0 ? '-' : '+'}${Math.abs(off)}`; };
  const phone = async (width, height = 900, { dark = true, hour = 13, motion = false } = {}) => {
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2.625, mobile: true });
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }, { name: 'prefers-reduced-motion', value: motion ? 'no-preference' : 'reduce' }] });
    await send('Emulation.setTimezoneOverride', { timezoneId: hourTz(hour) });
  };
  const open = async (hash = '#/pass', names = 6) => {
    await send('Page.navigate', { url: 'about:blank' }); await sleep(80); await send('Page.navigate', { url: `${base}/${hash}` });
    await until('document.readyState === "complete" && location.href.startsWith("http")');
    await until(`/^(Live|Paused)/.test(document.getElementById('pulse-text')?.textContent || '') && document.querySelectorAll('#city-names a').length >= ${Number(names)}`, 15000);   // live, not a stale offline copy
    await sleep(700);
  };
  const shot = async (name) => { if (!shotsDir) return; fs.mkdirSync(shotsDir, { recursive: true }); const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(shotsDir, name), Buffer.from(r.data, 'base64')); };
  return { send, ev, until, phone, open, shot, server, cdp, base, stop: () => { try { cdp.close(); } catch { } try { cdp.proc.kill(); } catch { } try { server.kill(); } catch { } } };
}
