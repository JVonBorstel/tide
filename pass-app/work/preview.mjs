// @ts-check
// Owns the per-PR preview launcher (lane L5, WO-UPG-L5-3; build-way 2.2 "Previews"): it serves one PR worktree's Board (its
// pass-app/server.mjs) on a local port with fixture data only, so a Board card can link to "see it running" before Jordan taps Yes.
// Called by its command line (below), by the Work API in a later slice (the link on a card), and by pass-app/test-work-preview.mjs.
//   node pass-app/work/preview.mjs start --worktree <PR checkout> [--fixture <folder>] [--port <n>] [--ttl-min 120] [--user <tailnet login>]
//   Prints one JSON line { ok, id, url, port, expires, scratch, serve } and stays up until the preview ends (Ctrl+C ends it too).
// Rules kept here:
//   - fixture data only: the server runs on a new scratch state folder (a copy of the fixture, or the built-in synthetic one) and with a
//     minimal environment whose LOCALAPPDATA, APPDATA, USERPROFILE, HOME and TEMP point inside that scratch folder, so the live state
//     folder (%LOCALAPPDATA%\brain-kitchen) cannot be found, let alone read. A worktree or fixture inside the live folder is refused;
//   - the port is freed after 2 h (ttl): the process tree is ended and the scratch folder removed; at most 3 previews run at once;
//   - it never changes Tailscale: reaching the port from the phone needs `tailscale serve`, which is Jordan's setting. The answer names the
//     exact command (serve) so a card can ask for it.
// The PR's code runs as this Windows user. Run previews only for PRs of this repo (the crews' own branches), never for a stranger's fork.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const TTL_MS = 2 * 3600 * 1000;
export const MAX_PREVIEWS = 3;
export const PORTS = [7900, 7999];

/** @type {Map<string, { id: string, port: number, url: string, scratch: string, proc: import('node:child_process').ChildProcess, expires: number, timer: NodeJS.Timeout, worktree: string }>} */
const running = new Map();

/** The live state folder(s) a preview must never touch. @param {string[]} [extra] */
export function liveStateDirs(extra = []) {
  const base = process.env.LOCALAPPDATA ? [path.join(process.env.LOCALAPPDATA, 'brain-kitchen')] : [];
  if (process.env.BRAIN_KITCHEN) base.push(process.env.BRAIN_KITCHEN);
  return [...base, ...extra].map((p) => path.resolve(p).toLowerCase());
}
/** @param {string} p @param {string[]} dirs */
const inside = (p, dirs) => { const r = path.resolve(p).toLowerCase(); return dirs.some((d) => r === d || r.startsWith(d + path.sep)); };

/** A synthetic Board state: three work orders and a few Yard events (no real names). @param {string} dir */
export function writeFixture(dir) {
  const iso = (m) => new Date(Date.now() - m * 60000).toISOString();
  fs.mkdirSync(path.join(dir, 'jobs'), { recursive: true });
  const job = (id, status, name) => ({ id, name, status, cursor: 0, attempt: 0, created: iso(90), costUsd: 0, steps: [{ script: 'agent-step.ps1', args: { Role: 'do' } }], history: [{ at: iso(5), step: 0, outcome: status === 'done' ? 'done' : 'start' }] });
  for (const j of [job('J1', 'running', 'improve: example sunrise colour'), job('J2', 'waiting-approval', 'improve: example empty state'), job('J3', 'done', 'improve: example tidy')]) fs.writeFileSync(path.join(dir, 'jobs', `${j.id}.json`), JSON.stringify(j));
  fs.writeFileSync(path.join(dir, 'events.jsonl'), ['J1', 'J2', 'J3'].map((j, i) => JSON.stringify({ ts: iso(30 - i), type: 'job.done', job: j })).join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'supervisor.json'), JSON.stringify({ lastTick: iso(1) }));
  fs.writeFileSync(path.join(dir, 'FIXTURE.txt'), 'synthetic preview data (pass-app/work/preview.mjs)\n');
}

/** Is this port free on 127.0.0.1? @param {number} port */
export function portFree(port) {
  return new Promise((ok) => { const s = net.createServer(); s.once('error', () => ok(false)); s.listen(port, '127.0.0.1', () => s.close(() => ok(true))); });
}
async function pickPort(/** @type {number|undefined} */ want) {
  if (want) return (await portFree(want)) ? want : 0;
  for (let p = PORTS[0]; p <= PORTS[1]; p++) if (![...running.values()].some((r) => r.port === p) && await portFree(p)) return p;
  return 0;
}

/**
 * The minimal environment a preview server gets: no path or variable that leads to the live state folder or to Jordan's accounts.
 * @param {string} scratch @param {number} port
 */
export function previewEnv(scratch, port) {
  const keep = ['PATH', 'Path', 'PATHEXT', 'SystemRoot', 'SYSTEMROOT', 'ComSpec', 'windir', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'OS'];
  /** @type {Record<string, string>} */ const env = {};
  for (const k of keep) if (process.env[k] !== undefined) env[k] = String(process.env[k]);
  const home = path.join(scratch, 'home'); const tmp = path.join(scratch, 'tmp'); const empty = path.join(scratch, 'empty');
  for (const d of [home, tmp, empty]) fs.mkdirSync(d, { recursive: true });
  return { ...env, BRAIN_KITCHEN: path.join(scratch, 'state'), LOCALAPPDATA: home, APPDATA: home, USERPROFILE: home, HOME: home, TEMP: tmp, TMP: tmp,
    PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', PASS_HOSTS: '', PASS_NO_KICK: '1', BRAIN_NTFY_TOPIC: '', KITCHEN_NOTIFY_LOG: path.join(tmp, 'notify.txt'),
    PASS_INCOME_DIR: empty, PASS_CAREER_DIR: empty, TIDE_DB: path.join(scratch, 'state', 'tide.db'), PASS_PREVIEW: '1' };
}

/**
 * End a process and its children (taskkill /T on Windows; the process group elsewhere) and wait until it has exited (at most 5 s).
 * @param {import('node:child_process').ChildProcess} proc
 */
async function killTree(proc) {
  if (proc.exitCode !== null || proc.signalCode !== null) return;
  const gone = new Promise((ok) => proc.once('exit', ok));
  if (process.platform === 'win32' && proc.pid) { try { execFileSync('taskkill', ['/pid', String(proc.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }); } catch { } }
  else { try { if (proc.pid) process.kill(-proc.pid, 'SIGKILL'); } catch { try { proc.kill('SIGKILL'); } catch { } } }
  await Promise.race([gone, new Promise((ok) => setTimeout(ok, 5000))]);
}

/**
 * Start a preview.
 * @param {{ worktree: string, fixture?: string, port?: number, ttlMs?: number, users?: string[], live?: string[], nodeArgs?: string[] }} o
 * @returns {Promise<{ ok: true, id: string, url: string, port: number, expires: string, scratch: string, serve: string } | { ok: false, error: string }>}
 */
export async function startPreview(o) {
  const live = liveStateDirs(o.live);
  const wt = path.resolve(String(o.worktree || ''));
  const server = path.join(wt, 'pass-app', 'server.mjs');
  if (!o.worktree || !fs.existsSync(server)) return { ok: false, error: `no pass-app/server.mjs in ${wt}` };
  if (inside(wt, live)) return { ok: false, error: 'the worktree is inside the live state folder: refused' };
  if (o.fixture && (inside(o.fixture, live) || live.some((d) => inside(d, [path.resolve(o.fixture).toLowerCase()])))) return { ok: false, error: 'the fixture is (or holds) the live state folder: refused; previews use fixture data only' };
  if (o.fixture && !fs.existsSync(path.join(o.fixture, 'FIXTURE.txt'))) return { ok: false, error: 'a fixture folder must say what it is (FIXTURE.txt); only synthetic data goes in a preview' };
  if (running.size >= MAX_PREVIEWS) return { ok: false, error: `${MAX_PREVIEWS} previews are running; stop one first` };
  const port = await pickPort(o.port);
  if (!port) return { ok: false, error: o.port ? `port ${o.port} is taken` : `no free port in ${PORTS[0]}-${PORTS[1]}` };
  const id = `pv-${port}-${crypto.randomBytes(3).toString('hex')}`;
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), `tide-preview-${port}-`));
  const state = path.join(scratch, 'state');
  if (o.fixture) fs.cpSync(o.fixture, state, { recursive: true }); else writeFixture(state);
  if (o.users?.length) fs.writeFileSync(path.join(state, 'pass-users.txt'), o.users.join('\n') + '\n');
  const env = previewEnv(scratch, port);
  const log = fs.openSync(path.join(scratch, 'server.log'), 'a');
  const proc = spawn(process.execPath, [...(o.nodeArgs || []), server], { cwd: wt, env, stdio: ['ignore', log, log], windowsHide: true, detached: process.platform !== 'win32' });   // its own process group, so the whole tree ends
  fs.closeSync(log);
  const ttl = Math.max(1000, o.ttlMs ?? TTL_MS);
  const rec = { id, port, url: `http://127.0.0.1:${port}/`, scratch, proc, expires: Date.now() + ttl, worktree: wt, timer: setTimeout(() => { stopPreview(id); }, ttl) };
  rec.timer.unref?.();
  running.set(id, rec);
  proc.once('exit', () => { if (running.has(id)) stopPreview(id); });
  for (let i = 0; i < 100 && !(await answers(port)); i++) await new Promise((r) => setTimeout(r, 150));
  if (!(await answers(port))) { await stopPreview(id); return { ok: false, error: 'the preview server did not start (see its server.log before it is removed)' }; }
  return { ok: true, id, url: rec.url, port, expires: new Date(rec.expires).toISOString(), scratch, serve: `tailscale serve --bg --https=${port} http://127.0.0.1:${port}` };
}
/** Does the Board answer /api/health on this port? @param {number} port */
async function answers(port) { try { const r = await fetch(`http://127.0.0.1:${port}/api/health`, { signal: AbortSignal.timeout(1000) }); return r.status === 200; } catch { return false; } }

/** End a preview: its process tree, its timer and its scratch folder; resolves when the port is free and the folder gone. @param {string} id */
export async function stopPreview(id) {
  const r = running.get(id); if (!r) return false;
  running.delete(id); clearTimeout(r.timer); await killTree(r.proc);
  for (let n = 0; n < 20; n++) {   // a dying process can hold its files a moment (Windows) or still be writing one (elsewhere)
    try { fs.rmSync(r.scratch, { recursive: true, force: true }); if (!fs.existsSync(r.scratch)) break; } catch { }
    await new Promise((ok) => setTimeout(ok, 250));
  }
  return true;
}
/** @returns {Array<{ id: string, url: string, port: number, expires: string, worktree: string }>} */
export const listPreviews = () => [...running.values()].map((r) => ({ id: r.id, url: r.url, port: r.port, expires: new Date(r.expires).toISOString(), worktree: r.worktree }));
export const stopAll = () => Promise.all([...running.keys()].map((id) => stopPreview(id)));

/** @param {string[]} argv */
async function main(argv) {
  const [cmd, ...rest] = argv; /** @type {Record<string, string>} */ const a = {}; /** @type {string[]} */ const users = [];
  for (let i = 0; i < rest.length; i += 2) { if (rest[i] === '--user') users.push(rest[i + 1]); else a[rest[i].replace(/^--/, '')] = rest[i + 1]; }
  if (cmd !== 'start' || !a.worktree) { console.log('usage: node pass-app/work/preview.mjs start --worktree <PR checkout> [--fixture <folder>] [--port <n>] [--ttl-min 120] [--user <tailnet login>]'); return 2; }
  const r = await startPreview({ worktree: a.worktree, fixture: a.fixture, port: a.port ? Number(a.port) : undefined, ttlMs: a['ttl-min'] ? Number(a['ttl-min']) * 60000 : undefined, users });
  console.log(JSON.stringify(r));
  if (!r.ok) return 1;
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => { stopAll().then(() => process.exit(0)); });
  await new Promise((done) => { const t = setInterval(() => { if (!running.size) { clearInterval(t); done(null); } }, 1000); });
  console.log(JSON.stringify({ ok: true, ended: r.id }));
  return 0;
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main(process.argv.slice(2)).then((c) => { process.exitCode = c; });
