// Chef speed on a copy of the kitchen state: state build time, first-load bytes as a phone asks, live-stream bytes while jobs change.
// Called by scripts/bench/bench.ps1 with: <server.mjs> <port> <kitchen copy root>. Starts its own throwaway server (its own test key,
// no phone alerts, no kitchen kicks) and stops it after. Prints one JSON line.
import fs from 'node:fs'; import path from 'node:path'; import http from 'node:http'; import { spawn } from 'node:child_process';
const [serverPath, port, root] = process.argv.slice(2);
for (const d of [root + '-career', root + '-income']) fs.mkdirSync(d, { recursive: true });
const env = { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: port, PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1',
  KITCHEN_NOTIFY_LOG: root + '-notify.txt', KITCHEN_NO_DIAGNOSE: '1', KITCHEN_OLLAMA_URL: 'off', KITCHEN_AGY_EXE: 'off',
  PASS_CAREER_DIR: root + '-career', PASS_INCOME_DIR: root + '-income' };
const srv = spawn('node', [serverPath], { env, stdio: 'ignore' });
const base = `http://127.0.0.1:${port}`;
const get = (p, headers) => new Promise((ok, no) => http.get(base + p, { headers }, (res) => { let n = 0; res.on('data', (d) => { n += d.length; }); res.on('end', () => ok({ code: res.statusCode, n })); }).on('error', no));
const median = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
const out = {};
try {
  let up = false;
  for (let i = 0; i < 60 && !up; i++) { try { await get('/manifest.webmanifest', {}); up = true; } catch { await new Promise((r) => setTimeout(r, 250)); } }
  if (!up) throw new Error('throwaway Chef server did not start');
  const H = { Authorization: 'Bearer ' + fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim() };
  const t = [];
  for (let i = 0; i < 11; i++) { const s = performance.now(); await get('/api/state', H); t.push(performance.now() - s); }
  out.stateColdMs = +t[0].toFixed(1); out.stateWarmMs = +median(t.slice(1)).toFixed(1);
  const files = ['/', '/app.js', '/app.css', '/scene.js', '/sprites.js', '/icon.svg', '/manifest.webmanifest'];
  let first = 0; for (const f of files) first += (await get(f, { ...H, 'Accept-Encoding': 'br' })).n;
  await new Promise((r) => setTimeout(r, 2000));   // the best compression is made in the background; a repeat load gets it
  let repeat = 0; for (const f of files) repeat += (await get(f, { ...H, 'Accept-Encoding': 'br' })).n;
  out.firstLoadBytes = first; out.repeatLoadBytes = repeat;
  // live stream: wire bytes over 12 s while one job file changes every 2 s
  const jobs = fs.readdirSync(path.join(root, 'jobs')).filter((f) => /^J\d+\.json$/.test(f));
  out.jobs = jobs.length;
  if (jobs.length) {
    const jf = path.join(root, 'jobs', jobs[0]); const orig = fs.readFileSync(jf, 'utf8');
    out.stream12sBytes = await new Promise((resolve) => {
      let n = 0; let k = 0;
      const req = http.get(base + '/api/stream', { headers: { ...H, 'Accept-Encoding': 'br' } }, (res) => res.on('data', (d) => { n += d.length; }));
      const tick = setInterval(() => { const j = JSON.parse(orig.replace(/^﻿/, '')); j.attempt = 1000 + (++k); fs.writeFileSync(jf, JSON.stringify(j)); }, 2000);
      setTimeout(() => { clearInterval(tick); fs.writeFileSync(jf, orig); req.destroy(); resolve(n); }, 12500);
    });
  }
} catch (e) { out.error = e.message; } finally { srv.kill(); }
console.log(JSON.stringify(out));
