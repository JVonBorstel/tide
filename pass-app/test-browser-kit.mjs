// The screen tests' browser: headless Chrome or Edge over the DevTools protocol (Node's own WebSocket; no package). Shared by
// pass-app/test-work-ui.mjs, test-status-line.mjs and test-scene-gl-screen.mjs. cdpConnect(profileDir) starts the browser on a throwaway
// profile and returns { send(method, params), on(listener), close(), proc } for its first page; the caller kills proc when done.
// { gpu: true } keeps the graphics chip (a hardware WebGL2 where the machine has one); by default the browser has only a software one.
// A cold start on a CI runner can take over 10 s, so it waits up to 30 s for the DevTools port.
import fs from 'node:fs'; import path from 'node:path'; import { spawn } from 'node:child_process';

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
