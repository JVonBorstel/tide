// Chef: Jordan's private app for watching and running the kitchen from his phone.
// Live feeds (Server-Sent Events) of jobs, events and the cooks' output; job detail with every step, run, cost and the sous chef's reasons;
// sign-off with the exact approval text; new orders with a preview of the sous chef's decision; the cooks; an audit trail; a view-only
// screen peek. No dependencies. Data never leaves the machine except to Jordan's own devices.
// Security: listens on 127.0.0.1 only; the phone comes in over Tailscale HTTPS (tailscale serve). Every request needs either a
// Tailscale login listed in pass-users.txt or the pass key (Bearer, or a signed session cookie from /login). Actions go through kitchen-api.ps1 on the chef channel,
// so the kitchen's own rules apply. Request bodies are capped, every handler is guarded (one bad request can't stop the server).
//   node pass-app/server.mjs            (env PASS_PORT=7878, BRAIN_KITCHEN=<root>; phone access: tailscale serve --bg 7878)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';
import { monitorEventLoopDelay } from 'node:perf_hooks';
import { makeTowers } from './towers.mjs';

const VERSION = '2.10.0';
const here = path.dirname(fileURLToPath(import.meta.url));
// Seamless updates. BUILD is a hash of the app files; it is re-checked every 2 s, so a change to public/ goes live with no restart:
// the next state on the stream carries the new build, and the phone swaps itself over the next time it is idle. SERVER is a hash
// of this file as it was when the process started, so pass-app/update.ps1 can tell whether a restart is needed at all.
const SERVER = crypto.createHash('sha256').update(fs.readFileSync(fileURLToPath(import.meta.url))).digest('hex').slice(0, 12);
const root = path.resolve(process.env.BRAIN_KITCHEN || path.join(process.env.LOCALAPPDATA || '', 'brain-kitchen'));
const kitchenDir = path.resolve(here, '..', 'kitchen');
const recipesDir = process.env.KITCHEN_RECIPES ? path.resolve(process.env.KITCHEN_RECIPES) : path.join(kitchenDir, 'recipes');
const api = path.join(kitchenDir, 'kitchen-api.ps1');
const sousPs = path.join(kitchenDir, 'sous-chef.ps1');
const kitchenPs = path.join(kitchenDir, 'kitchen.ps1');
const atsPs = path.join(kitchenDir, 'ats.ps1');
const port = Number(process.env.PASS_PORT || 7878);
const pwsh = process.env.PASS_PWSH || 'pwsh';
const runDir = path.join(root, 'run');
fs.mkdirSync(root, { recursive: true });

// ---- the pass key: 32 random bytes, created once, readable only by Jordan's account ----
const keyPath = path.join(root, 'pass-key.txt');
if (!fs.existsSync(keyPath)) fs.writeFileSync(keyPath, crypto.randomBytes(32).toString('hex'), { mode: 0o600 });
// The key is re-read whenever pass-key.txt changes (one stat per check), so replacing or deleting the file cuts a lost phone off at
// once, without a restart. A missing, unreadable or malformed key file accepts no key at all (fail closed); on a change every open
// live stream is dropped so a cut-off device can't keep watching (the others reconnect with their new cookie in a second).
const key = { sig: '', text: '', buf: Buffer.alloc(0) };
function passKey() {
  let sig = ''; try { const st = fs.statSync(keyPath); sig = `${st.size}:${st.mtimeMs}:${st.ino}`; } catch {}
  if (sig !== key.sig) {
    let t = ''; try { t = fs.readFileSync(keyPath, 'utf8').trim(); } catch {}
    if (!/^[0-9a-f]{64}$/.test(t)) t = '';
    const rotated = key.sig !== '' && t !== key.text;
    Object.assign(key, { sig, text: t, buf: Buffer.from(t) });
    if (rotated) for (const c of [...clients]) dropClient(c);   // never on the first read (clients is declared further down)
  }
  return key.text;
}
passKey();
function keyOk(k) { const cur = passKey(); const b = Buffer.from(String(k || '')); return cur.length === 64 && b.length === key.buf.length && crypto.timingSafeEqual(b, key.buf); }
// Tailscale identity: `tailscale serve` (HTTPS on the tailnet) proxies to 127.0.0.1 and adds Tailscale-User-Login for the signed-in
// person. The server listens only on 127.0.0.1, so that header can only come from Tailscale (or a local process, which could read
// the key file anyway). Allowed logins are listed one per line in pass-users.txt.
const usersPath = path.join(root, 'pass-users.txt');
function allowedUsers() { try { return fs.readFileSync(usersPath, 'utf8').split(/\r?\n/).map((s) => s.trim().toLowerCase()).filter(Boolean); } catch { return []; } }
function tailscaleUser(req) {
  const login = String(req.headers['tailscale-user-login'] || '').trim().toLowerCase();
  const local = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress);
  // only a request that came through `tailscale serve` carries the tailnet name as its Host (serve keeps it); a web page on this PC
  // (DNS rebinding) or a local process talking to 127.0.0.1 can't make a browser send that Host, so its header is never trusted
  return local && login && hostKind(req) === 'tailnet' && allowedUsers().includes(login) ? login : null;
}
// ---- which Host/Origin Chef answers (DNS-rebinding guard) ----
// Only the names Chef is really served on: 127.0.0.1 / localhost / [::1] with its port, this machine's tailnet name (read from
// `tailscale status --json`, refreshed every 10 min, never printed or pushed) and PASS_HOSTS (comma list, extra tailnet names).
// Anything else gets 421 before auth: a rebinding page's requests carry its own hostname, which a browser can't fake.
const tailnetHosts = new Set(String(process.env.PASS_HOSTS || '').split(',').map((s) => s.trim().toLowerCase().replace(/\.$/, '')).filter(Boolean));
const directHosts = new Set();   // the raw Tailscale IP when PASS_TAILSCALE_DIRECT=1 (old mode)
function readTailnetName() {
  if (process.env.PASS_NO_TAILSCALE === '1') return;
  for (const exe of ['tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe']) {
    execFile(exe, ['status', '--json'], { timeout: 8000, windowsHide: true, maxBuffer: 8 << 20 }, (err, out) => {
      if (err) return; try { const n = String(JSON.parse(String(out)).Self?.DNSName || '').toLowerCase().replace(/\.$/, ''); if (/^[a-z0-9.-]{3,253}$/.test(n)) tailnetHosts.add(n); } catch {}
    });
  }
}
readTailnetName(); setInterval(readTailnetName, 600000).unref();
function hostKind(req) {
  const h = String(req.headers.host || '').toLowerCase(); const m = /^(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::(\d{1,5}))?$/.exec(h); if (!m) return null;
  const [, name, p] = m;
  if (['127.0.0.1', 'localhost', '[::1]'].includes(name)) return p === String(port) ? 'local' : null;
  if (directHosts.has(name)) return p === String(port) ? 'direct' : null;
  if (tailnetHosts.has(name)) return 'tailnet';   // any serve port (443 or --https=N): a rebinding page can't carry this name
  return null;
}
// a POST that names its Origin must come from a page Chef itself served (CSRF defence in depth; browsers can't forge Origin)
function originOk(req) {
  const o = req.headers.origin; if (o == null) return true;
  let u; try { u = new URL(String(o)); } catch { return false; }
  const name = u.hostname.toLowerCase(), p = u.port;
  if (u.protocol === 'https:' && tailnetHosts.has(name)) return true;
  if (u.protocol === 'http:' && (['127.0.0.1', 'localhost', '[::1]'].includes(name) || directHosts.has(name)) && p === String(port)) return true;
  return false;
}
function authed(req) {
  if (tailscaleUser(req)) return true;
  const h = req.headers.authorization || '';
  if (h.startsWith('Bearer ') && keyOk(h.slice(7))) return true;
  const m = /(?:^|;\s*)pass=(\d{10}\.[0-9a-f]{32}\.[0-9a-f]{64})(?:;|$)/.exec(req.headers.cookie || '');
  return !!m && sessionOk(m[1]);
}
// ---- sign-in sessions (security audit 2026-10-22) ----
// The cookie carries a session, never the pass key: "<expiry>.<nonce>.<hmac>", signed with the current key. It lasts
// PASS_SESSION_DAYS (default 30); replacing pass-key.txt signs every device out at once (the signature no longer matches).
const SESSION_SEC = Math.round((Number(process.env.PASS_SESSION_DAYS) || 30) * 86400);
const sessionMac = (exp, nonce) => crypto.createHmac('sha256', key.buf).update(`chef-session|${exp}|${nonce}`).digest('hex');
function newSession() { passKey(); const exp = Math.floor(Date.now() / 1000) + SESSION_SEC; const nonce = crypto.randomBytes(16).toString('hex'); return `${exp}.${nonce}.${sessionMac(exp, nonce)}`; }
function sessionOk(tok) {
  const [exp, nonce, mac] = String(tok).split('.'); if (passKey().length !== 64 || !(Number(exp) * 1000 > Date.now())) return false;
  const a = Buffer.from(mac || ''), b = Buffer.from(sessionMac(exp, nonce)); return a.length === b.length && crypto.timingSafeEqual(a, b);
}
// Sign-in attempts: after LOGIN_MAX wrong keys in 15 minutes every sign-in is refused (429) until the window passes. Everything
// reaches Chef from 127.0.0.1 (tailscale serve), so the count is global; a Tailscale login on pass-users.txt is never affected.
const LOGIN_MAX = 10, LOGIN_WINDOW_MS = 15 * 60000; let loginFails = [];
const loginLocked = () => (loginFails = loginFails.filter((t) => Date.now() - t < LOGIN_WINDOW_MS)).length >= LOGIN_MAX;
const loginForm = (msg) => `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>The Board sign-in</title>
<form method="post" action="/login"><p>${msg}</p><label>Pass key <input name="key" type="password" autocomplete="current-password" required></label> <button>Sign in</button></form>`;

// ---- reading kitchen state straight from disk (read-only, fast) ----
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '')); } catch { return null; } };
// Unchanged inputs are not read again: a file's size and write time are its signature, and work derived from files is redone only
// when a signature changes (the live loop runs every second; at 10x the orders a full re-read each second would not keep up).
const sigOf = (p) => { try { const st = fs.statSync(p); return `${st.size}:${st.mtimeMs}`; } catch { return '-'; } };
const memoCache = new Map();
function memo(name, sig, fn) { const hit = memoCache.get(name); if (hit && hit.sig === sig) return hit.val; const val = fn(); memoCache.set(name, { sig, val }); return val; }
function tailLines(p, n, maxBytes = 65536) {
  try {
    const st = fs.statSync(p); const len = Math.min(st.size, maxBytes); const fd = fs.openSync(p, 'r');
    const buf = Buffer.alloc(len); fs.readSync(fd, buf, 0, len, st.size - len); fs.closeSync(fd);
    return buf.toString('utf8').replace(/^\uFEFF/, '').split(/\r?\n/).filter(Boolean).slice(-n);
  } catch { return []; }
}
// the cook's tool-by-tool activity (last 25 lines); private orders keep only ts, kind, tool and status (whitelist, never target or out)
function readActivity(p, priv, n = 25, maxBytes = 65536) {
  const cap = (x) => typeof x === 'string' ? x.slice(0, 200) : x;
  const out = [];
  for (const l of tailLines(p, n, maxBytes)) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    if (!o || typeof o !== 'object' || Array.isArray(o)) continue;
    if (priv) out.push({ ts: cap(o.ts), kind: cap(o.kind), tool: cap(o.tool), status: cap(o.status) });
    else out.push(Object.fromEntries(Object.entries(o).filter(([, x]) => typeof x !== 'object').map(([k, x]) => [k, cap(x)])));
  }
  return out;
}
const jobId = (v) => /^J\d{1,6}$/.test(String(v || '')) ? String(v) : null;
const approvalId = (v) => /^A\d{1,8}$/.test(String(v || '')) ? String(v) : null;   // scripts/approvals.ps1 ids ("added A12")
const runId = (v) => /^J\d{1,6}-s\d{1,3}-a\d{1,3}$/.test(String(v || '')) ? String(v) : null;
const stationOf = (s) => path.basename(s?.script || '').replace(/\.ps1$/i, '').replace(/^agent-step$/, 'agent');
function stepSummary(s) {
  const a = s?.args || {};
  if (a.Order) return String(a.Order).slice(0, 240);
  if (a.Prompt) return String(a.Prompt).slice(0, 240);
  return Object.entries(a).filter(([, v]) => typeof v !== 'object').map(([k, v]) => `${k}: ${v}`).join(', ').slice(0, 240);
}
// Job files are parsed only when they change (one stat each per call); a file that is mid-write and does not parse is not kept, so
// the next call reads it again. Callers only read the job objects, never change them (they are shared between calls).
// The live loop (watched: true) goes further: Windows tells Chef which job file changed, so a change costs one stat and one parse of
// that file, and a quiet second costs nothing. Every 60 s a sweep stats every job file off the main thread (fs.promises) and queues
// any whose size or time moved, as if Windows had named it (a watch event dropped in a burst is caught there; at 2,840 jobs a
// blocking scan froze the loop ~200 ms). A blocking full scan runs only at the start, after a watch error or a nameless event, and on
// every call when the folder can't be watched (as before).
// `work` counts the reads (shown in /api/health as numbers only) so tests can prove a one-file edit reads one file.
const jobCache = new Map();   // file name -> { sig, job }
const jobsWatch = { on: false, full: true, names: new Set(), at: 0, keys: [], list: [], sweeping: false };
const work = { parsed: 0, statted: 0, fullScans: 0, indexBytes: 0, refScans: 0, gateMeasures: 0 };
const JOB_FILE = /^J\d+\.json$/, FULL_SCAN_MS = 60000;
const byNum = (a, b) => parseInt(a.slice(1)) - parseInt(b.slice(1));
function watchJobs() {
  if (jobsWatch.on) return;
  try {
    fs.watch(path.join(root, 'jobs'), (ev, name) => { const f = name ? String(name) : ''; if (JOB_FILE.test(f)) jobsWatch.names.add(f); else if (!f) jobsWatch.full = true; })
      .on('error', () => { jobsWatch.on = false; jobsWatch.full = true; });
    jobsWatch.on = true;
  } catch { }
}
// one job file: 'same', 'changed' (read again, or gone), or 'retry' (mid-write: not kept, read again on the next call)
function readJobFile(f) {
  const p = path.join(root, 'jobs', f); work.statted++; const sig = sigOf(p); const hit = jobCache.get(f);
  if (sig === '-') { if (!hit) return 'same'; jobCache.delete(f); return 'changed'; }
  if (hit && hit.sig === sig) return 'same';
  work.parsed++; const job = readJson(p);
  if (!job) { jobCache.delete(f); return 'retry'; }
  jobCache.set(f, { sig, job }); return 'changed';
}
function listFromCache() {
  if (jobsWatch.keys.length !== jobCache.size || jobsWatch.keys.some((f) => !jobCache.has(f))) jobsWatch.keys = [...jobCache.keys()].sort(byNum);
  jobsWatch.list = jobsWatch.keys.map((f) => jobCache.get(f).job); return jobsWatch.list;
}
async function sweepJobs() {
  if (jobsWatch.sweeping) return; jobsWatch.sweeping = true; jobsWatch.at = Date.now();
  try {
    const dir = path.join(root, 'jobs'); const files = (await fs.promises.readdir(dir)).filter((f) => JOB_FILE.test(f)); const seen = new Set(files);
    for (let i = 0; i < files.length; i += 32) {
      await Promise.all(files.slice(i, i + 32).map(async (f) => {
        let sig = '-'; try { const st = await fs.promises.stat(path.join(dir, f)); sig = `${st.size}:${st.mtimeMs}`; } catch {}
        work.statted++; if (jobCache.get(f)?.sig !== sig) jobsWatch.names.add(f);
      }));
    }
    for (const f of jobCache.keys()) if (!seen.has(f)) jobsWatch.names.add(f);
    work.fullScans++;
  } catch { jobsWatch.full = true; } finally { jobsWatch.sweeping = false; }
}
function loadJobs({ watched = false } = {}) {
  if (watched) {
    watchJobs();
    if (jobsWatch.on && !jobsWatch.full) {
      if (Date.now() - jobsWatch.at >= FULL_SCAN_MS) sweepJobs();   // in the background; what it finds is read on a later call
      if (!jobsWatch.names.size) return jobsWatch.list;
      const names = [...jobsWatch.names]; jobsWatch.names.clear(); let moved = false;
      for (const f of names) { const r = readJobFile(f); if (r === 'retry') jobsWatch.names.add(f); if (r !== 'same') moved = true; }
      return moved ? listFromCache() : jobsWatch.list;
    }
  }
  jobsWatch.full = false; jobsWatch.names.clear(); work.fullScans++;   // cleared before the scan: a change during it marks the file again
  let files; try { files = fs.readdirSync(path.join(root, 'jobs')).filter((f) => JOB_FILE.test(f)); } catch { jobsWatch.full = true; return []; }
  const seen = new Set(files);
  for (const f of files) if (readJobFile(f) === 'retry') jobsWatch.names.add(f);
  for (const f of jobCache.keys()) if (!seen.has(f)) jobCache.delete(f);
  jobsWatch.at = Date.now();
  return listFromCache();
}
// the run folder's file names, listed again only when the folder changes (a file added or removed changes its write time)
const runFiles = () => memo('runFiles', sigOf(runDir), () => { try { return fs.readdirSync(runDir); } catch { return []; } });
// cook.ps1 stores the private flag as the string 'yes'/'true'; a step can also be marked Private on its own
const isJobPrivate = (j) => { const on = (x) => x === true || ['yes', 'true'].includes(String(x ?? '').toLowerCase()); return on(j?.vars?.private) || (j?.steps || []).some((s) => on(s.args?.Private)); };
// Stuck-loop alarm: the step the order is on now failed (or was sent back) twice or more since that step last finished. Counted
// from the job's own history (kitchen.ps1 Fail-Step writes one entry per failure), so it costs nothing extra and survives a requeue.
// A private order gives the station and the count only, never the failure's words.
const FAIL_OUTCOMES = new Set(['fail', 'crash', 'timeout', 'memcap', 'logflood', 'hung', 'taster', 'rework']);
const STUCK_AT = 2;
function stuckOf(j) {
  if (!j || ['done', 'closed'].includes(j.status) || !Array.isArray(j.history)) return null;
  const at = Number(j.cursor); let times = 0, lastKind = '', lastDetail = '', same = true, first = null;
  for (let i = j.history.length - 1; i >= 0; i--) {
    const h = j.history[i]; if (!h || Number(h.step) !== at) continue;
    if (h.outcome === 'done') break;
    if (!FAIL_OUTCOMES.has(h.outcome)) continue;
    const d = String(h.detail || '').slice(0, 200);
    if (!times) { lastKind = h.outcome; lastDetail = d; first = d; } else if (d !== first) same = false;
    times++;
  }
  if (times < STUCK_AT) return null;
  const priv = isJobPrivate(j);
  return { step: at + 1, station: stationOf(j.steps?.[at]), times, kind: lastKind, detail: priv ? '' : lastDetail, same: priv ? null : same };
}
// why the order stopped, for its Retry button: the last history entry when it is a failure ("fail: exit 1: ..."); kind only when private
function retryWhyOf(j) {
  const h = (j?.history || []).at(-1); if (!h || !FAIL_OUTCOMES.has(h.outcome)) return '';
  return isJobPrivate(j) || !h.detail ? h.outcome : `${h.outcome}: ${String(h.detail).slice(0, 200)}`;
}
function jobView(j) {
  const s = j.steps?.[Math.min(j.cursor, (j.steps?.length || 1) - 1)] || {};
  const hist = j.history || []; const last = hist.length ? hist[hist.length - 1] : null;
  const v = { id: j.id, name: j.name, status: j.status, step: Math.min(j.cursor + 1, j.steps?.length || 1), steps: j.steps?.length || 1,
    attempt: j.attempt || 0, cost: j.costUsd || 0, last: last ? `${last.outcome}${last.detail ? ': ' + last.detail : ''}` : '',
    worker: path.basename(s.script || ''), station: stationOf(s), role: s.args?.Role || '', supplier: s.args?.Supplier || '',
    approval: j.approval && !j.approval.granted ? { id: j.approval.id, text: j.approval.text, kind: j.approval.kind || 'gate' } : null,
    created: j.created || null, updated: last?.at || j.created || null, parent: j.parent || '', depth: j.depth || 0, notBefore: j.notBefore || null,
    recipe: j.recipe || null, label: labelOf(j), stuck: stuckOf(j), retryWhy: retryWhyOf(j), tower: towers.towerOf(j),
    // TD-EH-08: a pending order waiting out its back-off before a retry ('wait' = it waited on CI, the network or GitHub; 'code' = the rest)
    retry: j.status === 'pending' && j.retryWait && j.notBefore ? { cls: j.retryWait.class === 'wait' ? 'wait' : 'code' } : null };   // the order's words (vars) stay out of the live stream; the job sheet shows them on request
  if (v.approval) {   // what the gate is: a merge of a code change (with its size and whether it touches a protected file) or another step
    v.approval.gate = mergeGate(j) ? 'merge' : 'step';
    if (v.approval.gate === 'merge' && !isJobPrivate(j)) { v.change = changeSummary(j); const cl = ciLookError(j.id); if (cl) v.approval.ciLook = cl; }
  }
  if (j.status === 'running' && j.run) {
    v.since = j.run.startedAt; v.limit = s.timeoutSec;
    const pick = readJson(j.run.base + '.sous.json');   // the sous chef's decision for this step
    if (pick) { v.cook = [pick.supplier, pick.model].filter(Boolean).join(' ') || pick.action; v.why = pick.why || ''; }
    // a private order (vars.private 'yes'/'true', any Private step, or the sous chef's call) never puts its log on the live stream:
    // the log holds the cook's whole answer (the tailored resume, the cover note) until the next tick marks the job done
    let earlier = false; try { earlier = runFiles().some((f) => f.startsWith(j.id + '-s') && f.endsWith('.sous.json') && readJson(path.join(runDir, f))?.private === true); } catch {}   // an earlier step's private call covers the whole order
    const priv = isJobPrivate(j) || earlier || !!pick?.private; if (priv) v.private = true; else if (pick) v.private = false;
    v.tail = priv ? [] : tailLines(j.run.base + '.log', 6);
    v.activity = readActivity(j.run.base + '.activity.jsonl', priv);
    v.plan = (j.steps || []).map((x) => ({ station: stationOf(x), role: String(x.args?.Role || '').slice(0, 24) }));   // the Live call's tree (order -> steps -> cook): step kinds only, never their words
  }
  return v;
}
// TD-EH-15: a merge gate whose last CI look failed (gh down or signed out, a crash, the time limit) shows why: ci-wait (or the caller that
// ran it) saved {state 'error', error, at} in results\<job>.ci.json. Only an error look is shown; a good look says nothing here.
function ciLookError(id) {
  const c = readJson(path.join(root, 'results', id + '.ci.json'));
  return c && c.state === 'error' ? { error: String(c.error || 'no reason was given').slice(0, 200), at: String(c.at || '') } : null;
}
const ciSigOf = (j) => (mergeGate(j) ? sigOf(path.join(root, 'results', j.id + '.ci.json')) : '');
// A job's view (and its JSON, which the live stream compares) is made again only when its file was read again (a new job object)
// or its gate was measured again; a running job is made every time (its log tail and activity grow without a job-file change).
const viewCache = new Map();   // job id -> { job, ver, view, json }
function viewOf(j) {
  const ver = gateCache.get(j.id)?.ver ?? 0; const ci = ciSigOf(j); const hit = viewCache.get(j.id);   // (ci: a new CI look is a new view)
  if (hit && hit.job === j && hit.ver === ver && hit.ci === ci && j.status !== 'running') return hit;
  const view = jobView(j); const e = { job: j, ver, ci, view, json: JSON.stringify(view) }; viewCache.set(j.id, e); return e;
}
// A merge gate: the step waiting for Jordan's yes is the merge station and its ask is the kitchen's merge wording (kitchen.ps1
// Request-Approval: "<name>: start step N of M (merge)"). Anything else (a recipe step with approve:true) is never batched.
function mergeGate(j) {
  const s = j?.steps?.[j.cursor]; if (!s || !j.approval || j.approval.granted) return false;
  return stationOf(s) === 'merge' && /: start step \d+ of \d+ \(merge\)$/.test(String(j.approval.text || ''));
}
// The protected-file list is automerge.ps1's own (one source of truth: the files whose change must always be Jordan's own look),
// plus kitchen.json autoMerge.protect. If it can't be read, every change counts as protected (fail closed).
let protectCache = { sig: '', res: null };
function protectPatterns() {
  const files = [path.join(kitchenDir, 'automerge.ps1'), path.join(kitchenDir, 'kitchen.json'), path.join(root, 'kitchen.json')];
  const sig = files.map((f) => { try { const st = fs.statSync(f); return `${st.size}:${st.mtimeMs}`; } catch { return '-'; } }).join('|');
  if (sig === protectCache.sig) return protectCache.res;
  let res = null;
  try {
    const src = fs.readFileSync(files[0], 'utf8'); const block = /protect\s*=\s*@\(([\s\S]*?)\)\s*\}/.exec(src)?.[1] || '';
    const pats = [...block.replace(/#.*$/gm, '').matchAll(/'((?:[^']|'')*)'/g)].map((m) => m[1].replace(/''/g, "'"));
    for (const f of files.slice(1)) { const extra = readJson(f)?.autoMerge?.protect; if (Array.isArray(extra)) pats.push(...extra.map(String)); }
    if (pats.length >= 5) res = pats.map((p) => new RegExp(p, 'i'));   // PowerShell -match is case-insensitive
  } catch { res = null; }
  protectCache = { sig, res }; return res;
}
// ---- child processes off the main thread ----
// On Windows, starting a process (CreateProcess) runs on the thread that asks for it: at 10 merge gates the "async" git calls froze the
// loop for 110 ms median / 812 ms max every ~16 s (projects/tide/arch-10-22/chef.md). git and the kitchen's scripts are started from one
// long-lived worker thread instead, so the 1 s loop, every phone's stream and /api/health keep flowing while they run. If the worker
// can't start (or stops), the same call runs on this thread, as before. Answers come back as { err, out } like execFile's callback.
const RUNNER_SRC = `const { parentPort } = require('node:worker_threads'); const { execFile } = require('node:child_process');
parentPort.on('message', ({ id, file, args, opts }) => execFile(file, args, opts, (err, out) => parentPort.postMessage({ id, out: String(out ?? ''), err: err ? { message: String(err.message || err), code: err.code ?? null } : null })));`;
let runner = null; let runSeq = 0; const runWait = new Map();
function startRunner() {
  try {
    const w = new Worker(RUNNER_SRC, { eval: true }); w.unref();
    w.on('message', (m) => { const done = runWait.get(m.id); if (done) { runWait.delete(m.id); done(m); } });
    const gone = () => { if (runner !== w) return; runner = null; for (const [id, done] of runWait) done({ id, out: '', err: { message: 'the process runner stopped' } }); runWait.clear(); };
    w.on('error', (e) => { console.error('runner:', e?.message); gone(); }); w.on('exit', gone);
    runner = w;
  } catch (e) { console.error('runner:', e?.message); runner = null; }
}
function run(file, args, opts) {
  return new Promise((resolve) => {
    if (!runner) startRunner();
    if (!runner) return execFile(file, args, opts, (err, out) => resolve({ err, out: String(out ?? '') }));
    const id = ++runSeq; runWait.set(id, (m) => resolve({ err: m.err ? Object.assign(new Error(m.err.message), { code: m.err.code }) : null, out: m.out }));
    runner.postMessage({ id, file, args, opts });
  });
}
// the change a merge gate would land: file count, +/- lines and the protected files it touches, measured by git from main's merge
// base to the order's branch (never the worktree's DIFF.patch, which AI code can rewrite; automerge measures the same way).
// No branch, a git error or no protect list all count as needing Jordan's own look.
const repoOfJob = (j) => { const m = (j?.steps || []).find((s) => /merge\.ps1$/.test(String(s.script || '')) && s.args?.Repo); return m ? String(m.args.Repo) : path.resolve(kitchenDir, '..'); };
function repoOf(id) { return repoOfJob(readJson(path.join(root, 'jobs', id + '.json'))); }
// the City (GET /api/towers, towersV, githubAt, jobView.tower): towers.mjs reads the Yard's records, git and GitHub (gh, read-only), off this thread through run()
const towers = makeTowers({ root, repoHome: path.resolve(kitchenDir, '..'), run, jobs: () => loadJobs({ watched: true }), isPrivate: isJobPrivate, github: { log: (l) => console.log(l) } });
const unknownChange = () => ({ files: 0, add: 0, del: 0, protected: [], unknown: true });
const gitOpts = { encoding: 'utf8', timeout: 10000, windowsHide: true, maxBuffer: 16 << 20 };
const gitRun = (repo, a) => run('git', ['-C', repo, '-c', 'core.quotepath=off', ...a], gitOpts).then(({ err, out }) => { if (err) throw err; return out; });
function changeFrom(numstat, diff) {
  const files = [], recs = numstat.split('\0').filter(Boolean); let add = 0, del = 0, bin = false;
  for (const r of recs) { const m = /^(\d+|-)\t(\d+|-)\t([\s\S]+)$/.exec(r.replace(/^\n/, '')); if (!m) continue; files.push(m[3]); if (m[1] === '-') bin = true; else { add += +m[1]; del += +m[2]; } }
  const pats = protectPatterns();
  const prot = pats ? files.filter((f) => pats.some((re) => re.test(f))) : files.slice();
  return { files: files.length, add, del, protected: prot.slice(0, 20), unknown: !files.length || !pats || bin, sha: diff ? crypto.createHash('sha256').update(diff).digest('hex') : '' };
}
// measured now (three git calls, one after the other, off this thread); a git error is an unknown change (fail closed)
async function gateDiff(repo, id) {
  const br = 'kitchen/' + id; const mb = (await gitRun(repo, ['merge-base', 'main', br])).trim();
  return { numstat: await gitRun(repo, ['diff', '--numstat', '-z', '--no-renames', mb, br]), diff: await gitRun(repo, ['diff', '--no-renames', mb, br]) };
}
async function measureChange(repo, id) { const g = await gateDiff(repo, id); return changeFrom(g.numstat, g.diff); }
// The live state shows each gate's last measured change. A refresher asks git once per repo every 10 s which commit main and every
// kitchen/<id> branch point at (one `for-each-ref`), and measures a gate again only when its pair of commits (or the protect list)
// moved, one gate at a time. So no git runs inside the 1 s loop, and nothing at all runs while no branch moves. A gate not measured
// yet shows as unknown (it needs Jordan's own look) and asks for a refresh at once.
const gateCache = new Map();   // job id -> { key, res, ver }
const gates = { busy: false, again: false, soon: false, ver: 0 };
const GATE_EVERY_MS = Number(process.env.PASS_GATE_REFRESH_MS) || 10000;
async function refreshGates() {
  if (gates.busy) { gates.again = true; return; }
  gates.busy = true;
  try {
    const list = loadJobs({ watched: true }).filter((j) => mergeGate(j) && !isJobPrivate(j));
    const ids = new Set(list.map((j) => j.id)); for (const id of gateCache.keys()) if (!ids.has(id)) gateCache.delete(id);
    const byRepo = new Map(); for (const j of list) { const r = repoOfJob(j); if (!byRepo.has(r)) byRepo.set(r, []); byRepo.get(r).push(j); }
    protectPatterns(); const prot = protectCache.sig;
    for (const [repo, js] of byRepo) {
      let refs = null; work.refScans++;
      try { refs = new Map((await gitRun(repo, ['for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/main', 'refs/heads/kitchen/'])).split(/\r?\n/).map((l) => l.trim().split(' ')).filter((x) => x.length === 2)); } catch { refs = null; }
      for (const j of js) {
        const key = refs ? `${refs.get('refs/heads/main') || '-'}:${refs.get('refs/heads/kitchen/' + j.id) || '-'}:${prot}` : 'refs-unreadable:' + prot;
        if (gateCache.get(j.id)?.key === key) continue;
        work.gateMeasures++; const res = await measureChange(repo, j.id).catch(() => unknownChange());
        gateCache.set(j.id, { key, res, ver: ++gates.ver });
      }
    }
  } catch (e) { console.error('gates:', e?.message); } finally {
    gates.busy = false; if (gates.again) { gates.again = false; setImmediate(refreshGates); }
  }
}
setInterval(refreshGates, GATE_EVERY_MS).unref();
function changeSummary(j) {
  const hit = gateCache.get(j.id);
  if (!hit && !gates.soon) { gates.soon = true; setImmediate(() => { gates.soon = false; refreshGates(); }); }
  return hit ? hit.res : unknownChange();
}
// Inspection gate: sha256 of the exact diff a merge gate would land (git, never the worktree's DIFF.patch), measured fresh on every call
// (never the refresher's copy, so there is no stale window), awaited before the answer. Jordan's yes carries the sha he looked at;
// a change since then is refused. null = unreadable, '' = empty diff.
async function diffSha(id) {
  try {
    const repo = repoOf(id); const br = 'kitchen/' + id;
    const d = await gitRun(repo, ['diff', '--no-renames', (await gitRun(repo, ['merge-base', 'main', br])).trim(), br]);
    return d ? crypto.createHash('sha256').update(d).digest('hex') : '';   // '' = a genuinely empty diff (git ran fine)
  } catch { return null; }   // null = git failed: unreadable
}
// why a yes on this job is refused for its diff sha ('' = fine): only a merge gate with a readable diff needs one. The yes paths
// (approve, approve-all) await this fresh check before the kitchen is asked to grant anything.
async function shaRefusal(j, sha) {
  try { return await shaRefusalOf(j, sha); } catch { return `${j?.id}: the change can't be checked right now, so this yes is refused; try again`; }   // fail closed, never a 500
}
async function shaRefusalOf(j, sha) {
  if (!mergeGate(j)) return '';
  const cur = await diffSha(j.id);
  if (cur === null) return `${j.id}: the change can't be read right now, so this yes is refused; try again`;   // fail closed
  if (cur === '') return '';   // empty diff: nothing to look at
  if (!/^[0-9a-f]{64}$/.test(String(sha || ''))) return 'reload the Board: this yes does not say which change it covers';
  return sha === cur ? '' : `${j.id} changed since you looked; look again`;
}
// a gate Approve all may sign off: a merge gate whose change, measured now (never the cached one), is known and touches nothing
// protected (Jordan's 2026-10-18 audit: a guardrail change never merges under a list of friendly titles)
async function batchable(j) {
  if (!mergeGate(j) || j.approval.kind === 'hold' || isJobPrivate(j)) return false;
  const c = await measureChange(repoOfJob(j), j.id).catch(() => unknownChange()); return !c.unknown && !c.protected.length;
}
// Replay: every run of a job with start/end, cook, tokens, outcome and its activity lines (private orders: ts, kind, tool, status only)
function jobTimeline(id) {
  const j = readJson(path.join(root, 'jobs', id + '.json')); if (!j) return null;
  let files = []; try { files = fs.readdirSync(runDir).filter((f) => f.startsWith(id + '-s')); } catch {}
  const jobPriv = isJobPrivate(j);
  const runs = {};
  for (const f of files) {
    const m = /^(J\d+)-s(\d+)-a(\d+)\.(log|exit|cost\.json|sous\.json|activity\.jsonl)$/.exec(f); if (!m || m[1] !== id) continue;
    const key = `${m[1]}-s${m[2]}-a${m[3]}`; const r = runs[key] ||= { run: key, step: +m[2], attempt: +m[3], start: null, end: null, cook: '', tokens: 0, outcome: 'running', private: jobPriv, activity: [] };
    const p = path.join(runDir, f);
    try {
      const st = fs.statSync(p);
      if (m[4] === 'log') { r.start = (st.birthtime && st.birthtime.getTime() > 0 ? st.birthtime : st.mtime).toISOString(); r.logEnd = st.mtime.toISOString(); }
      else if (m[4] === 'exit') { r.exit = Number(String(fs.readFileSync(p, 'utf8')).trim()); r.end = st.mtime.toISOString(); }
      else if (m[4] === 'cost.json') {
        const c = readJson(p);
        if (c) { r.cook = r.cook || [c.supplier, c.model].filter(Boolean).join(' '); r.tokens = (Number(c.inputTokens) || 0) + (Number(c.outputTokens) || 0) + (Number(c.cacheReadTokens) || 0) + (Number(c.cacheWriteTokens) || 0); }
      } else if (m[4] === 'sous.json') {
        const d = readJson(p);
        if (d) { if (d.private) r.private = true; r.cook = [d.supplier, d.model].filter(Boolean).join(' ') || d.action || r.cook; }
      }
    } catch {}
  }
  const list = Object.values(runs).sort((a, b) => a.step - b.step || a.attempt - b.attempt);
  for (const r of list) {
    r.outcome = r.exit === undefined ? 'running' : r.exit === 0 ? 'done' : r.exit === 10 ? 'hold' : r.exit === 11 ? 'wait' : 'fail';
    if (r.exit === undefined && j.status !== 'running') r.outcome = 'fail';
    if (r.end === null && r.outcome === 'fail') r.end = r.logEnd || null;
    if (!r.start && j.run?.base && path.basename(j.run.base) === r.run) r.start = j.run.startedAt || null;
    if (!r.cook) { const s = j.steps?.[r.step]; r.cook = s?.args?.Supplier || stationOf(s) || 'hand'; }
    r.activity = readActivity(path.join(runDir, r.run + '.activity.jsonl'), r.private, 400, 1 << 20);
    delete r.exit; delete r.logEnd;
  }
  return { id, name: j.name, status: j.status, created: j.created || null, private: jobPriv || list.some((r) => r.private), runs: list };
}
// Spend and tokens come from the cost lines the event index keeps (eventIndex reads events.jsonl once, then only the bytes appended
// since: an append costs its own bytes, never a re-read of the last 5,000 lines). Counted again only when the log, the minute (the
// cooks' windows slide), the day or a cook's window length changes.
function spentFromEvents() {
  const ix = eventIndex(); const today = new Date().toDateString();
  return memo('spent', ix.sig + '|' + today, () => Math.round(ix.cost.reduce((s, c) => s + (new Date(c.t).toDateString() === today ? c.usd : 0), 0) * 10000) / 10000);
}
function tokensFromEvents(cooks = {}) {
  const ix = eventIndex();
  const sig = [ix.sig, Math.floor(Date.now() / 60000), ...Object.entries(cooks).map(([n, c]) => n + ':' + c?.windowHours)].join('|');
  return memo('tokens', sig, () => tokensFromRows(ix.cost, cooks));
}
function tokensFromRows(rows, cooks = {}) {
  const today = new Date().toDateString(); const now = Date.now();
  let todayTotal = 0; const perCook = {}; const perWindow = {};
  for (const name of Object.keys(cooks)) { perCook[name] = 0; perWindow[name] = 0; }
  for (const c of rows) {
    if (!c.tok) continue;
    if (new Date(c.t).toDateString() === today) { todayTotal += c.tok; if (c.sup) perCook[c.sup] = (perCook[c.sup] || 0) + c.tok; }
    if (c.sup && now - c.t <= Number(cooks[c.sup]?.windowHours || 24) * 3600 * 1000) perWindow[c.sup] = (perWindow[c.sup] || 0) + c.tok;
  }
  return { today: todayTotal, perCook, perWindow };
}
// a small file read again only when it changes (size and write time); callers never change what they get back
const fileJson = (p) => memo('json:' + p, sigOf(p), () => readJson(p));
const lastJsonLine = (p) => memo('last:' + p, sigOf(p), () => { try { return JSON.parse(tailLines(p, 1).pop() || 'null'); } catch { return null; } });
// Everything the board shows, in two parts: the top fields and one { id, view, json } per job (the live stream sends only what moved).
function stateParts() {
  const jobs = loadJobs({ watched: true }).map(viewOf);
  if (viewCache.size > jobs.length) { const ids = new Set(jobs.map((x) => x.view.id)); for (const id of viewCache.keys()) if (!ids.has(id)) viewCache.delete(id); }
  const meta = fileJson(path.join(root, 'supervisor.json')) || {};
  const board = fileJson(path.join(root, 'suppliers-board.json')) || {};
  const tickAge = meta.lastTick ? Math.round((Date.now() - new Date(meta.lastTick).getTime()) / 1000) : null;
  const cooks = Object.fromEntries(Object.entries(board.suppliers || {}).map(([n, c]) => [n, { ...c }]));   // a copy: the cached board stays as read
  const tokenStats = tokensFromEvents(cooks);
  for (const [name, c] of Object.entries(cooks)) {
    c.tokensToday = tokenStats.perCook[name] || 0;
    c.tokensWindow = tokenStats.perWindow[name] || 0;
  }
  // paused: Jordan stopped the kitchen on purpose (kitchen.ps1 pause), so a quiet supervisor is not an alarm; stalled: no tick for 10+ min otherwise
  const paused = fs.existsSync(path.join(root, 'PAUSED')); const stalled = !paused && tickAge !== null && tickAge > STALL_SEC;
  const ip = path.join(root, 'ideas.json'), ap = path.join(root, 'alerts.jsonl');
  const top = { at: new Date().toISOString(), version: VERSION, build: build.id, tickAge, lastTick: meta.lastTick || null, breaker: !!meta.breakerTripped, breakerUntil: meta.breakerTripped ? meta.breakerOpenUntil || null : null, paused, stalled,
    live: fs.existsSync(path.join(root, 'LIVE')), spent: spentFromEvents(), tokensToday: tokenStats.today,
    tokens: { today: tokenStats.today, perCook: tokenStats.perCook, perWindow: tokenStats.perWindow },
    budget: Number(board.dailyBudgetUsd || process.env.PASS_BUDGET || 20),
    cooks, judge: board.judge || null, cooksAt: board.at || null,
    scoreboard: lastJsonLine(path.join(root, 'scoreboard.jsonl')),
    due: memo('due', sigOf(trackerPath) + '|' + today(), () => dueItems().length), push: pushOn(),
    ideas: memo('ideas', sigOf(ip), () => (readJson(ip)?.items || []).filter((x) => x.status === 'new').length), leads: memo('leads', sigOf(leadsPath), clientsNew),
    freeze: memo('freeze', sigOf(path.join(root, 'freeze.json')) + '|' + Math.floor(Date.now() / 60000), freezeView),
    towersV: towers.v(),   // the City: /api/towers changed (a merge, a git count, a GitHub read that found something); the phone fetches it again
    githubAt: towers.githubAt(),   // the City's "GitHub read N min ago" sign: the last good GitHub read (every 5 min), null before one
    mainStatus: mainStatusView(),   // TD-EH-03a: each Tower's main, green or red (the Board's main-is-red banner, public/main-status.js)
    undoUnpushed: undoUnpushedView(), automergePause: automergePauseView(),   // TD-EH-10/11: banners in public/undo-pause.js
    lead: leadView(), lobe: lobeView(), lobeOwner: lobeOwnerView(), lobeGlass: lobeGlass(), alerts: memo('alerts', sigOf(ap), () => tailLines(ap, 8).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)) };
  top.alertsUnsent = memo('alertsUnsent', sigOf(ap), () => alertsUnsent(ap));   // TD-EH-04: the Board's "Phone alerts are off" banner
  return { top, jobs };
}
// TD-EH-04 "Sent or not": how many alerts at the end of alerts.jsonl did not reach the phone, and since when. Each line's `sent` is
// written by kitchen.ps1 Alert (off, failed, limited = not sent). The count stops at the newest line that was sent, is still held, or
// predates the record (no `sent`), so it never claims more than the record shows. Counts and a time only: no alert text leaves here.
function alertsUnsent(ap) {
  let lines = []; try { lines = fs.readFileSync(ap, 'utf8').trimStart().split(/\r?\n/); } catch { return { n: 0, since: null }; }
  let n = 0, since = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].trim()) continue;
    let a = null; try { a = JSON.parse(lines[i]); } catch { continue; }   // a torn line is skipped, not counted
    if (!a || !['off', 'failed', 'limited'].includes(a.sent)) break;
    n++; if (typeof a.ts === 'string') since = a.ts;
  }
  return { n, since };
}
function state() { const p = stateParts(); return { ...p.top, jobs: p.jobs.map((x) => x.view) }; }
// ---- TD-EH-03a main status: each Tower's main as verify last found it (kitchen/main-status.ps1 writes <kitchen>\main-status\<sha12>.json
// on every verdict). Read-only. A few small files: listed and stat'ed each call, parsed again only when one changed. A file that cannot be
// read is shown as such (state 'unreadable'), never dropped: a red main must not vanish behind a torn file.
function mainStatusView() {
  const dir = path.join(root, 'main-status'); let files = [];
  try { files = fs.readdirSync(dir).filter((f) => /^[0-9a-f]{12}\.json$/.test(f)).sort(); } catch { return []; }
  return memo('main-status', files.map((f) => f + '=' + sigOf(path.join(dir, f))).join('|'), () => files.map((f) => {
    const r = readJson(path.join(dir, f));
    if (!r || !['green', 'red'].includes(r.state)) return { tower: f.slice(0, 12), state: 'unreadable', suites: [], why: 'its main-status file cannot be read', since: null, at: null, sha: '', job: '' };
    return { tower: String(r.tower || '').slice(0, 80), state: r.state, suites: (Array.isArray(r.suites) ? r.suites : []).map(String).slice(0, 12), why: String(r.why || '').slice(0, 400),
      since: typeof r.since === 'string' ? r.since : null, at: typeof r.at === 'string' ? r.at : null, sha: String(r.sha || '').slice(0, 40), job: String(r.job || '').slice(0, 12) };
  }));
}
// ---- TD-EH-10 undo not pushed: <kitchen>\undo-unpushed\<job>.json, written by kitchen/undo-merge.ps1 when an undo had to go up to GitHub
// and did not; removed by kitchen/undo-push-check.ps1 once GitHub has it. Read-only here. A file that cannot be read is shown as such.
function undoUnpushedView() {
  const dir = path.join(root, 'undo-unpushed'); let files = [];
  try { files = fs.readdirSync(dir).filter((f) => /^J\d+\.json$/.test(f)).sort(); } catch { return []; }
  return memo('undo-unpushed', files.map((f) => f + '=' + sigOf(path.join(dir, f))).join('|'), () => files.map((f) => {
    const r = readJson(path.join(dir, f)); const job = f.slice(0, -5);
    if (!r || typeof r !== 'object') return { job, state: 'unreadable' };
    return { job, state: 'unpushed', tower: String(r.tower || '').slice(0, 80), slug: String(r.slug || '').slice(0, 140), why: String(r.why || '').slice(0, 200), at: typeof r.at === 'string' ? r.at : null, sha: String(r.sha || '').slice(0, 40) };
  }));
}
// the check: the Board's "Check now" button, and every 15 minutes while a record exists (a fetch of GitHub's main by URL; nothing is pushed)
const undoCheck = { busy: null };
function undoPushCheck() {
  if (undoCheck.busy) return undoCheck.busy;
  undoCheck.busy = ps(path.join(kitchenDir, 'undo-push-check.ps1'), ['-Json'], 120000).then(({ err, out }) => {
    try { const r = JSON.parse(String(out).trim().split(/\r?\n/).pop()); return r.ok ? { ok: true, data: { cleared: r.cleared || [], left: r.left || [] } } : { ok: false, error: 'the check gave no answer' }; } catch { return { ok: false, error: err ? String(err.message) : 'the check gave no answer' }; }
  }).finally(() => { undoCheck.busy = null; });
  return undoCheck.busy;
}
setInterval(() => { if (undoUnpushedView().length) undoPushCheck().catch(() => {}); }, Number(process.env.PASS_UNDO_CHECK_MS) || 900000).unref();
// ---- TD-EH-11 auto-merge paused: <kitchen>\automerge-paused.json, written by kitchen/stations/verify.ps1 when a check on main passed only
// on a retry. Shown while it lasts: null once its end time is past (or there is none).
function automergePauseView() {
  const p = path.join(root, 'automerge-paused.json');
  return memo('automerge-paused', sigOf(p) + '|' + Math.floor(Date.now() / 60000), () => {
    const v = readJson(p); if (!v || typeof v.until !== 'string' || !(new Date(v.until).getTime() > Date.now())) return null;
    return { until: v.until, since: typeof v.since === 'string' ? v.since : null, flaky: Number(v.flaky) || 0, suites: (Array.isArray(v.suites) ? v.suites : []).map(String).slice(0, 20) };
  });
}
// Merge freeze windows per repo (kitchen.repo.json "freeze"), as the supervisor last wrote them to freeze.json (kitchen/freeze-lib.ps1,
// every 2 minutes): read-only. Windows already over are dropped here; active-or-ahead is decided by the app against its own clock.
function freezeView() {
  const v = readJson(path.join(root, 'freeze.json')); if (!v) return null;
  const now = Date.now(); const ok = (w) => w && typeof w.from === 'string' && typeof w.to === 'string' && new Date(w.to).getTime() > now;
  const repos = (Array.isArray(v.repos) ? v.repos : []).map((r) => ({ name: String(r?.name || ''), windows: (Array.isArray(r?.windows) ? r.windows : []).filter(ok).map((w) => ({ from: w.from, to: w.to, why: String(w.why || ''), fromText: String(w.fromText || ''), toText: String(w.toText || '') })) })).filter((r) => r.windows.length);
  const errors = (Array.isArray(v.errors) ? v.errors : []).map((e) => ({ name: String(e?.name || ''), error: String(e?.error || '') }));
  return { at: v.at || null, repos, errors };
}
// Everything about one job: each step, every run of it (outcome, cost receipt, the sous chef's decision), history and the approval.
async function jobDetail(id) {
  const j = readJson(path.join(root, 'jobs', id + '.json')); if (!j) return null;
  let files = []; try { files = fs.readdirSync(runDir).filter((f) => f.startsWith(id + '-s')); } catch {}
  const runs = {};
  for (const f of files) {
    const m = /^(J\d+)-s(\d+)-a(\d+)\.(log|exit|cost\.json|sous\.json|wait|dish\.md)$/.exec(f); if (!m || m[1] !== id) continue;
    const key = `${m[1]}-s${m[2]}-a${m[3]}`; const r = runs[key] ||= { run: key, step: +m[2], attempt: +m[3] };
    const p = path.join(runDir, f);
    if (m[4] === 'exit') r.exit = Number(String(fs.readFileSync(p, 'utf8')).trim());
    else if (m[4] === 'cost.json') { const c = readJson(p); if (c) r.cost = { supplier: c.supplier, model: c.model, usd: c.usd, turns: c.turns, tried: c.tried, kind: c.kind, error: c.subtype }; }
    else if (m[4] === 'sous.json') { const d = readJson(p); if (d) r.sous = { action: d.action, supplier: d.supplier, model: d.model, tier: d.tier, kind: d.kind, private: d.private, why: d.why, reasons: d.reasons, skipped: d.skipped, ms: d.ms }; }
    else if (m[4] === 'dish.md') { try { const st = fs.statSync(p); r.dishAt = st.mtime.toISOString(); r.dishBytes = st.size; } catch {} }
    else if (m[4] === 'log') { try { const st = fs.statSync(p); r.logBytes = st.size; r.at = st.mtime.toISOString(); } catch {} }
  }
  const byStep = {}; for (const r of Object.values(runs)) (byStep[r.step] ||= []).push(r);
  const steps = (j.steps || []).map((s, i) => ({
    index: i, station: stationOf(s), role: s.args?.Role || '', supplier: s.args?.Supplier || '', summary: stepSummary(s),
    prompt: s.args?.Prompt ? String(s.args.Prompt).slice(0, 4000) : '', approve: !!s.approve, replay: s.replay, timeoutSec: s.timeoutSec,
    retries: s.retries, mustMatch: s.mustMatch || '', mustNotMatch: s.mustNotMatch || '',
    state: i < j.cursor ? 'done' : i === j.cursor ? (['done'].includes(j.status) ? 'done' : j.status) : 'waiting',
    runs: (byStep[i] || []).sort((a, b) => a.attempt - b.attempt) }));
  // the dish: the newest answer any AI step of this job produced (the last one is what the order was for), first 60 KB
  const withDish = Object.values(runs).filter((r) => r.dishAt).sort((a, b) => a.step - b.step || String(a.dishAt).localeCompare(String(b.dishAt))).pop();   // newest by time (a retry can reuse an attempt number)
  let dish = null;
  if (withDish) {
    try {
      const p = path.join(runDir, withDish.run + '.dish.md'); const buf = fs.readFileSync(p);
      dish = { run: withDish.run, step: withDish.step, at: withDish.dishAt, text: buf.subarray(0, 60000).toString('utf8').replace(/^﻿/, ''), cut: buf.length > 60000, by: withDish.cost ? [withDish.cost.supplier, withDish.cost.model].filter(Boolean).join(' ') : '' };
    } catch {}
  }
  // fix what breaks: a set-aside job links to its diagnosis; a diagnosis that ends in "FIX GOAL: ..." offers that goal to Improve
  const diagnosis = (readJson(path.join(root, 'diagnosed.json')) || {})[id]?.by || null;
  // a code change (Improve): the diff and the test results the cooks left in the job's worktree, so Jordan can read it before his yes
  let change = null;
  try {
    const kd = path.join(root, 'worktrees', id, '.kitchen'); const dp = path.join(kd, 'DIFF.patch');
    if (fs.existsSync(dp)) {
      const buf = fs.readFileSync(dp); const diff = buf.subarray(0, 150000).toString('utf8').replace(/^﻿/, '');
      const files = [...diff.matchAll(/^diff --git a\/(\S+)/gm)].map((m) => m[1]);
      const add = (diff.match(/^\+(?!\+\+)/gm) || []).length, del = (diff.match(/^-(?!--)/gm) || []).length;
      let tests = ''; try { tests = fs.readFileSync(path.join(kd, 'TESTS.txt'), 'utf8').replace(/^﻿/, '').slice(0, 8000); } catch {}
      change = isJobPrivate(j) ? { files, add, del, diff: '', cut: false, tests, private: true } : { files, add, del, diff, cut: buf.length > 150000, tests };   // private: names only
    }
  } catch {}
  const fg = dish && /^diagnose:/.test(j.name || '') ? /^\s*FIX GOAL:\s*(.{8,600}?)\s*$/m.exec(dish.text) : null;
  // did it merge on its own (automerged.jsonl), and was that undone since
  let autoMerged = false, undone = false;
  for (const l of tailLines(path.join(root, 'automerged.jsonl'), 1000)) { try { const o = JSON.parse(l); if (o.job !== id) continue; if (o.undone) { undone = true; autoMerged = false; } else { autoMerged = true; undone = false; } } catch {} }
  // its pull request on GitHub (the pr station's record; the kitchen's copy outlives the worktree): only a number and a github.com PR link
  let pr = null;
  for (const p of [path.join(root, 'results', id + '.pr.json'), path.join(root, 'worktrees', id, '.kitchen', 'PR.json')]) {
    const r = readJson(p); if (!r) continue;
    if (!r.skipped && Number.isInteger(r.number) && r.number > 0 && typeof r.url === 'string' && /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+$/.test(r.url) && r.url.endsWith('/pull/' + r.number)) pr = { number: r.number, url: r.url };
    break;
  }
  return { ...jobView(j), autoMerged, undone, costUsd: j.costUsd || 0, history: (j.history || []).slice(-60), approvalFull: j.approval || null, steps, waits: j.waits || 0, dish,
    change, diffSha: mergeGate(j) ? await diffSha(id) : null, pr, diagnosis: jobId(diagnosis), fixGoal: fg ? fg[1].replace(/\*+/g, '').trim() : null,
    proof: j.status === 'done' ? await proofOf(j, steps, { autoMerged, undone }) : null };
}
// ---- Proof Card (Tide ideas-chef SHORTLIST item 4): the receipt a plated order shows, read only from the kitchen's own records ----
// tests: one "tests: PASS|FAIL|- <suite> ..." line per suite in the tests station's newest run log, and results/<id>.tests.json
// (final line, flaky suites, the commit tested); taster: the check step's last "VERDICT: SHIP|REWORK" line (taster-gate.ps1 reads
// it the same way) and the cook that ran it; landed: results/<id>.merge.json (before/after/via) and the sha256 of git's diff between
// those two commits (off this thread); cost and minutes from the job. A field with no record is null: the app says "unknown".
const newestRun = (id, step, ext) => runFiles().filter((f) => f.startsWith(`${id}-s${step}-a`) && f.endsWith(ext))
  .map((f) => { try { return { f, t: fs.statSync(path.join(runDir, f)).mtimeMs }; } catch { return null; } }).filter(Boolean).sort((a, b) => a.t - b.t).pop()?.f || '';
async function proofOf(j, steps, merged) {
  const id = j.id; const readLog = (f) => { try { return f ? fs.readFileSync(path.join(runDir, f), 'utf8') : null; } catch { return null; } };
  // tests: the last tests step in the recipe
  let tests = null; const ti = steps.filter((s) => s.station === 'tests').map((s) => s.index).pop();
  if (ti !== undefined) {
    const log = readLog(newestRun(id, ti, '.log')); const rec = readJson(path.join(root, 'results', id + '.tests.json'));
    let pass = 0, fail = 0, skip = 0, last = '';
    for (const l of String(log || '').split(/\r?\n/)) {
      const m = /^tests: (PASS|FAIL|-)\s+\S+\s/.exec(l); if (m) { if (m[1] === 'PASS') pass++; else if (m[1] === 'FAIL') fail++; else skip++; }
      const f = /^tests: (ALL PASS|FAILED: .*|PARTIAL PASS: .*)$/.exec(l.trim()); if (f) last = f[1];
    }
    const seen = pass + fail + skip > 0;
    tests = seen || rec ? { pass: seen ? pass : null, fail: seen ? fail : null, notRun: seen ? skip : null, final: String(rec?.final || last || '').slice(0, 200) || null,
      flaky: Array.isArray(rec?.flaky) ? rec.flaky.map(String).slice(0, 20) : null, commit: /^[0-9a-f]{40}$/.test(String(rec?.sha || '')) ? rec.sha : null } : null;
  }
  // taster: the last check step (a recipe with no check step is a fact, not an unknown)
  const ci = steps.filter((s) => s.role === 'check').map((s) => s.index).pop();
  let taster = { step: false, verdict: null, by: null };
  if (ci !== undefined) {
    const f = newestRun(id, ci, '.log'); const v = [...String(readLog(f) || '').matchAll(/^\s*VERDICT: (SHIP|REWORK)/gm)].pop();
    const run = steps[ci].runs.find((r) => r.run + '.log' === f);
    const by = run?.cost ? [run.cost.supplier, run.cost.model].filter(Boolean).join(' ') : run?.sous ? [run.sous.supplier, run.sous.model].filter(Boolean).join(' ') : '';
    taster = { step: true, verdict: v ? v[1] : null, by: by || null };
  }
  // landed: the merge station's record and the diff it put on main
  const mr = readJson(path.join(root, 'results', id + '.merge.json')); const okSha = (x) => /^[0-9a-f]{40}$/.test(String(x || ''));
  let landed = null;
  if (mr && okSha(mr.before) && okSha(mr.after)) {
    let sha = null; try { const d = await gitRun(repoOfJob(j), ['diff', '--no-renames', mr.before, mr.after]); sha = d ? crypto.createHash('sha256').update(d).digest('hex') : null; } catch {}
    landed = { via: ['local', 'github'].includes(mr.via) ? mr.via : null, commit: mr.after, diffSha: sha, at: mr.at || null };
  }
  // cost: no cook step means nothing was spent; cook steps with no receipt at all mean the cost is unknown
  const cookSteps = steps.filter((s) => s.station === 'agent'); const receipts = cookSteps.some((s) => s.runs.some((r) => r.cost));
  const usd = !cookSteps.length ? 0 : receipts || j.costUsd ? Number(j.costUsd) || 0 : null;
  const end = (j.history || []).at(-1)?.at; const ms = j.created && end ? new Date(end) - new Date(j.created) : NaN;
  return { tests, taster, landed, usd, minutes: Number.isFinite(ms) && ms >= 0 ? Math.round(ms / 6000) / 10 : null, autoMerged: !!merged.autoMerged, undone: !!merged.undone };
}
// ---- Phone Diff (SHORTLIST item 5): a merge gate's change, file by file, from git (merge base -> kitchen/<id>: the same diff the yes
// is checked against, off this thread). No file: the file list with +/- counts, protected marks and the diff's sha. ?file=: that one
// file's hunks, at most PDIFF_LINES lines / PDIFF_BYTES, with the sha of the whole diff they came from (so the app can tell when the
// change moved while Jordan read). A private order gives file names only, and refuses any file's content.
const PDIFF_LINES = 1500, PDIFF_BYTES = 96 * 1024;
async function phoneDiff(id, file) {
  const j = readJson(path.join(root, 'jobs', id + '.json')); if (!j) return { code: 404, error: 'no such job' };
  if (!mergeGate(j)) return { code: 409, error: 'This order is not waiting at a merge gate, so there is no change to read here.' };
  const priv = isJobPrivate(j);
  if (file !== null && priv) return { code: 403, error: 'Private work order: only file names are shown.' };
  let g; try { g = await gateDiff(repoOfJob(j), id); } catch { return { code: 503, error: "The change can't be read right now (git failed). Try again." }; }
  const pats = protectPatterns(); const files = [];
  for (const r of g.numstat.split('\0').filter(Boolean)) {
    const m = /^(\d+|-)\t(\d+|-)\t([\s\S]+)$/.exec(r.replace(/^\n/, '')); if (!m) continue;
    const bin = m[1] === '-';
    files.push({ path: m[3], add: bin || priv ? null : +m[1], del: bin || priv ? null : +m[2], bin, protected: pats ? pats.some((re) => re.test(m[3])) : true });
  }
  const sha = g.diff ? crypto.createHash('sha256').update(g.diff).digest('hex') : '';
  if (file === null) return { code: 200, data: { id, private: priv, sha, protectKnown: !!pats, files } };
  const f = files.find((x) => x.path === file); if (!f) return { code: 404, error: 'That file is not in this change.' };
  if (f.bin) return { code: 200, data: { id, sha, file, bin: true, hunks: '', cut: false } };
  // the file's own section of the whole diff (--no-renames: its header names the same path twice), from its first hunk on
  const head = `diff --git a/${file} b/${file}\n`; const at = g.diff.startsWith(head) ? 0 : (g.diff.indexOf('\n' + head) + 1 || -1);
  if (at < 0) return { code: 200, data: { id, sha, file, bin: false, hunks: '', cut: false } };
  const next = g.diff.indexOf('\ndiff --git ', at + head.length); let part = g.diff.slice(at, next < 0 ? undefined : next + 1);
  const h0 = part.indexOf('\n@@'); part = h0 < 0 ? '' : part.slice(h0 + 1);
  let lines = part.replace(/\n$/, '').split('\n'); let cut = false;
  if (lines.length > PDIFF_LINES) { lines = lines.slice(0, PDIFF_LINES); cut = true; }
  let hunks = lines.join('\n');
  if (Buffer.byteLength(hunks) > PDIFF_BYTES) { hunks = Buffer.from(hunks).subarray(0, PDIFF_BYTES).toString('utf8').replace(/\n[^\n]*$/, ''); cut = true; }
  return { code: 200, data: { id, sha, file, bin: false, hunks, cut } };
}
// Each cook's last 7 days (runs and passes per day) and its most recent dishes, from the kitchen's event log.
function cookHistory() {
  const days = []; for (let i = 6; i >= 0; i--) { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - i); days.push(d.toDateString()); }
  const out = {};
  for (const l of tailLines(path.join(root, 'events.jsonl'), 20000, 8 << 20)) {
    if (!l.includes('"type":"cook"')) continue;
    let e; try { e = JSON.parse(l); } catch { continue; }
    const s = String(e.supplier || ''); if (!s) continue;
    const c = out[s] ||= { days: days.map(() => 0), passed: days.map(() => 0), recent: [] };
    const i = days.indexOf(new Date(e.ts).toDateString()); if (i >= 0) { c.days[i]++; if (e.ok) c.passed[i]++; }
    c.recent.push({ ts: e.ts, job: e.job, kind: e.kind, model: e.model, ok: !!e.ok }); if (c.recent.length > 8) c.recent.shift();
  }
  return { days, cooks: out };
}
// A variable's default as kitchen/cook.ps1 fills it: kitchen.json "recipeDefaults" (state-folder copy wins) replaces the recipe's own,
// whose {{home}} is the profile folder. Keeps personal defaults (the job scout's location and skills) out of the repo.
function recipeDefault(recipe, name, v) {
  let o = null;
  for (const f of [path.join(kitchenDir, 'kitchen.json'), path.join(root, 'kitchen.json')]) {
    const d = readJson(f)?.recipeDefaults;
    if (d && typeof d === 'object' && Object.hasOwn(d, recipe) && d[recipe] && typeof d[recipe] === 'object' && Object.hasOwn(d[recipe], name)) o = String(d[recipe][name]);
  }
  if (o !== null) return o;
  return v.default != null ? String(v.default).replaceAll('{{home}}', os.userInfo().homedir) : null;
}
// The recipe book, read straight from the recipe files (every variable with its rules, so the app can build the order form).
function recipes() {
  let files = []; try { files = fs.readdirSync(recipesDir).filter((f) => /^[\w-]{1,40}\.json$/.test(f)); } catch {}
  return files.map((f) => {
    const r = readJson(path.join(recipesDir, f)); if (!r) return null;
    const vars = Object.entries(r.vars || {}).map(([name, v]) => ({ name, required: !!v.required, default: recipeDefault(f.replace(/\.json$/, ''), name, v), max: v.max || 2000 }));
    const steps = r.steps || [];
    return { name: f.replace(/\.json$/, ''), description: r.description || '', vars, steps: steps.length,
      ai: steps.some((s) => s.station === 'agent'), approve: steps.some((s) => s.approve), stations: steps.map((s) => s.station || 'script') };
  }).filter(Boolean).sort((a, b) => a.name.localeCompare(b.name));
}

// ---- running the kitchen's own scripts ----
// started from the runner thread (see run), so a burst of sign-offs never freezes the phones' streams
function ps(file, args, timeout = 60000, extraEnv = {}) {
  return run(pwsh, ['-NoProfile', '-NonInteractive', '-File', file, ...args], { timeout, windowsHide: true, maxBuffer: 8 << 20, env: { ...process.env, ...extraEnv, BRAIN_KITCHEN: root } });
}
async function kitchen(op, args = {}) {
  const { err, out } = await ps(api, ['-Channel', 'chef', '-RequestJson', JSON.stringify({ id: 'pass-' + Date.now(), op, args })]);
  try { return JSON.parse(out.trim().split(/\r?\n/).pop()); } catch { return { ok: false, error: err ? String(err.message) : 'no answer from the Yard' }; }
}
// What would the sous chef do with this order? Decides only; nothing is cooked or sent.
async function preview(body) {
  const name = String(body.recipe || ''); if (!/^[\w-]{1,40}$/.test(name)) return { ok: false, error: 'pick a spec' };
  const r = readJson(path.join(recipesDir, name + '.json')); if (!r) return { ok: false, error: `no spec named ${name}` };
  const vars = cleanVars(body.vars, r.vars); if (vars.error) return { ok: false, error: vars.error };
  const values = {};
  for (const [k, v] of Object.entries(r.vars || {})) values[k] = vars.v[k] ?? (recipeDefault(name, k, v) ?? '');
  const step = (r.steps || []).find((s) => s.station === 'agent');
  if (!step) return { ok: true, data: { action: 'none', why: 'This spec has no AI step; the Dispatcher is not needed.' } };
  const fill = (s) => String(s || '').replace(/\{\{(\w+)\}\}/g, (m, k) => (k in values ? values[k] : m));
  const a = step.args || {};
  let order = Object.entries(r.vars || {}).filter(([k, v]) => v.required && values[k]).map(([k]) => values[k]).join('\n');
  if (order && r.about) order = `About: ${r.about}.\nOrder: ${order}`;   // same as cook.ps1, so the preview matches the real decision
  const prompt = ' ' + fill(a.Prompt);   // leading space: a prompt can never be read as a parameter name
  const args = ['pick', '-Role', a.Role || 'do', '-Prompt', prompt, '-Tools', a.Tools || 'Read,Grep,Glob', '-Mode', a.Mode || 'plan',
    '-Supplier', vars.v.cook && vars.v.cook !== 'auto' ? vars.v.cook : (a.Supplier || 'auto'), '-Json'];
  if (a.Order) order = fill(a.Order);   // a recipe's own screening text wins, as in cook.ps1
  if (order) args.push('-Order', ' ' + order);
  if (/^(yes|true)$/i.test(vars.v.private || '') || a.Private === true) args.push('-Private');
  if (a.Model && !(vars.v.cook && vars.v.cook !== 'auto')) args.push('-Model', String(a.Model));
  const { err, out } = await ps(sousPs, args, 45000);
  try { return { ok: true, data: JSON.parse(out.trim().split(/\r?\n/).pop()) }; } catch { return { ok: false, error: err ? String(err.message) : 'the Dispatcher did not answer' }; }
}
// each value is capped at its recipe variable's own max (the same number the order form gets from recipes(); default 2000), so a
// full tailor posting (max 12000) goes through and the error says what is wrong
function cleanVars(vars, spec = {}) {
  const v = {}; if (vars == null) return { v };
  if (typeof vars !== 'object' || Array.isArray(vars)) return { error: 'vars must be an object' };
  for (const [k, x] of Object.entries(vars)) {
    if (!/^\w{1,40}$/.test(k) || typeof x !== 'string') return { error: `bad value for ${k}` };
    const max = Math.min(50000, Number(spec?.[k]?.max) || 2000);
    if (x.length > max) return { error: `'${k}' is longer than ${max.toLocaleString('en-US')} characters` };
    if (x.trim()) v[k] = x.trim();
  }
  return { v };
}
// After a sign-off, an order or a requeue, run one supervisor pass right away so the work starts now, not at the next minute.
let kickBusy = false;
function kick() { if (kickBusy || process.env.PASS_NO_KICK === '1') return; kickBusy = true; kitchen('tick').finally(() => { kickBusy = false; }); }
const kicked = (p) => p.then((r) => { if (r.ok) kick(); return r; });
const running = new Map();
async function act(body) {
  const op = String(body.op || '');
  switch (op) {
    // A yes always names the exact ask Jordan was shown (its approval id). If the job has moved on to another gate since (a second
    // phone, a stalled stream, a requeue), the yes is refused instead of signing off a question he never saw. kitchen.ps1 checks the
    // id again under its state lock, so the check and the grant can't be split by a tick.
    case 'approve': {
      if (!jobId(body.id)) return { ok: false, error: 'bad job id' };
      if (!approvalId(body.approval)) return { ok: false, error: 'reload the Board: this yes does not say which ask it answers' };
      const j = readJson(path.join(root, 'jobs', body.id + '.json'));
      if (!j || !j.approval || j.approval.granted || String(j.approval.id) !== body.approval) return { ok: false, error: `${body.id} now asks something else (or nothing); look again` };
      const refused = await shaRefusal(j, body.diffSha); if (refused) return { ok: false, error: refused };
      return kicked(kitchen('approve', { id: body.id, approval: body.approval }));
    }
    case 'approve-all': {   // one tap for the list Jordan just saw: oldest first, so the merge train lands them in order.
      // items: [{ id, approval }] exactly as shown. By default merge gates only: privacy holds, non-merge gates, changes touching a
      // protected file (or with no readable diff) are skipped. everything: true (Jordan ticked "also these" under the marked list he
      // was shown, 2026-10-21) signs off every listed ask that still waits for him, holds and protected changes included. Either way
      // a job whose ask changed since he looked is skipped.
      const everything = body.everything === true;
      const items = Array.isArray(body.items) ? body.items.filter((x) => x && jobId(x.id) && approvalId(x.approval)).slice(0, 30) : [];
      if (!items.length) return { ok: false, error: 'nothing to approve' };
      const now = new Map(loadJobs().map((j) => [j.id, j]));
      const approved = [], skipped = []; const seen = new Set();
      for (const it of items.sort((a, b) => parseInt(a.id.slice(1)) - parseInt(b.id.slice(1)))) {
        if (seen.has(it.id)) continue; seen.add(it.id);
        const j = now.get(it.id);
        const waiting = everything ? ['waiting-approval', 'needs-human'].includes(j?.status) : j?.status === 'waiting-approval';
        if (!j || !waiting || !j.approval || j.approval.granted || String(j.approval.id) !== it.approval || !(everything || await batchable(j)) || await shaRefusal(j, it.diffSha)) { skipped.push(it.id); continue; }
        const r = await kitchen('approve', { id: it.id, approval: it.approval }); (r.ok ? approved : skipped).push(it.id);
      }
      if (approved.length) kick();
      return { ok: approved.length > 0, data: { approved, skipped }, error: approved.length ? undefined : 'none of these still needed your yes' };
    }
    case 'kill': return jobId(body.id) ? kitchen('kill', { id: body.id }) : { ok: false, error: 'bad job id' };
    case 'requeue': {
      if (!jobId(body.id)) return { ok: false, error: 'bad job id' };
      const r = await kitchen('requeue', { id: body.id });
      if (r.ok) {
        kick();
        const m = /re-cooked recipe (\S+) as (J\d+)/.exec(String(r.data || ''));
        if (m) return { ok: true, data: { job: m[2], reordered: true, text: r.data } };
      }
      return r;
    }
    case 'undo-merge': {   // one tap: reverse an auto-merged (or any merged) change with a new commit; history kept
      if (!jobId(body.id)) return { ok: false, error: 'bad job id' };
      const { err, out } = await ps(path.join(kitchenDir, 'undo-merge.ps1'), ['-Job', body.id, '-Json'], 60000);
      try { const r = JSON.parse(out.trim().split(/\r?\n/).pop()); if (r.ok) { try { fs.appendFileSync(path.join(root, 'events.jsonl'), JSON.stringify({ ts: new Date().toISOString(), type: 'merge.undone', job: body.id, ...(typeof r.pushed === 'boolean' ? { undoPushed: r.pushed, ...(r.pushed ? {} : { undoPushWhy: String(r.pushWhy || 'no reason was given') }) } : {}) }) + '\n'); } catch {} } return r.ok ? { ok: true, data: r.message } : { ok: false, error: r.message }; } catch { return { ok: false, error: err ? String(err.message) : 'no answer' }; }   // TD-EH-10: undoPushed as on verify's event
    }
    case 'undo-push-check': return undoPushCheck();   // TD-EH-10: is an undo that stayed on this PC on GitHub now? (the banner's Check now)
    case 'clear-aside': {   // close set-aside tickets older than 24 h; the server re-checks status and age, the phone's list is a hint
      const ids = Array.isArray(body.ids) ? [...new Set(body.ids.filter(jobId))].slice(0, 50) : [];
      if (!ids.length) return { ok: false, error: 'nothing to clear' };
      const now = new Map(loadJobs().map((j) => [j.id, j]));
      const closed = [], skipped = [];
      for (const id of ids) {
        const j = now.get(id), at = j && new Date(j.history?.at(-1)?.at || j.created).getTime();
        if (!j || !['quarantined', 'killed', 'failed'].includes(j.status) || !(Date.now() - at > 86400000)) { skipped.push(id); continue; }
        const { out } = await ps(kitchenPs, ['close', '-Id', id, '-Why', 'dropped: cleared by Jordan in Chef'], 90000, { KITCHEN_FROM_CHEF: '1' });
        (new RegExp(`closed ${id}\\b`).test(out) ? closed : skipped).push(id);
      }
      return { ok: closed.length > 0, data: { closed, skipped }, error: closed.length ? undefined : 'none of these were old failed work orders any more' };
    }
    case 'stop-all': return kitchen('kill', { all: true });
    case 'tick': return kitchen('tick');
    case 'doctor': return kitchen('doctor');
    case 'diagnose': {   // "Find the fix": a read-only diagnosis order for a set-aside job
      if (!jobId(body.id)) return { ok: false, error: 'bad job id' };
      const { err, out } = await ps(path.join(kitchenDir, 'diagnose.ps1'), ['-Id', body.id, '-Json'], 60000);
      let r = null; try { r = JSON.parse(out.trim().split(/\r?\n/).pop()); } catch {}
      if (!r) return { ok: false, error: err ? String(err.message) : 'no answer from the Yard' };
      if (r.ok) kick(); return r.ok ? { ok: true, data: { job: r.diagnosis } } : { ok: false, error: r.error };
    }
    case 'cook': {
      const recipe = String(body.recipe || ''); if (!/^[\w-]{1,40}$/.test(recipe)) return { ok: false, error: 'pick a spec' };
      const c = cleanVars(body.vars, readJson(path.join(recipesDir, recipe + '.json'))?.vars); if (c.error) return { ok: false, error: c.error };
      return kicked(kitchen('cook', { recipe, vars: c.v }));
    }
    case 'wake': case 'rest': {   // bring a resting cook back on the line, or rest one for a while
      const name = String(body.name || ''); if (!/^\w[\w-]{0,29}$/.test(name)) return { ok: false, error: 'bad crew name' };   // never a leading '-': pwsh -File would read it as a parameter
      const mins = Math.round(Number(body.minutes || 60)); if (op === 'rest' && !(mins >= 1 && mins <= 1440)) return { ok: false, error: 'minutes must be 1-1440' };
      const { err, out } = await ps(sousPs, op === 'wake' ? ['wake', '-Name', name] : ['rest', '-Name', name, '-ForMin', String(mins), '-Why', 'rested by Jordan from the Chef app'], 30000);
      return err ? { ok: false, error: out.trim() || String(err.message) } : { ok: true, data: out.trim() };
    }
    case 'usage': {   // fresh reading of the Claude plan (5-hour and weekly use): one tiny haiku run
      const { err, out } = await ps(sousPs, ['usage'], 150000);
      try { const b = readJson(path.join(root, 'suppliers-board.json')); if (b) await ps(sousPs, ['board', '-Write'], 60000); } catch {}
      return err ? { ok: false, error: out.trim() || String(err.message) } : { ok: true, data: out.trim() };
    }
    case 'push-on': {   // a random topic name made here, kept in the kitchen folder
      if (!/^[A-Za-z0-9_-]{12,64}$/.test(readTopic())) fs.writeFileSync(topicPath, 'chef-' + crypto.randomBytes(12).toString('hex'));
      fs.writeFileSync(pushOnPath, `on since ${new Date().toISOString()} (from the Chef app)`); return { ok: true, data: { topic: readTopic() } };
    }
    case 'push-off': try { fs.unlinkSync(pushOnPath); } catch {} return { ok: true };
    case 'push-automerge': return pushAutoMerged(true);   // same as the 8pm check, without waiting for the clock
    case 'push-test': if (!pushOn()) return { ok: false, error: 'push alerts are off' }; push('INFO', 'Test from the Board: push alerts work.'); return { ok: true };
    case 'live-on': fs.writeFileSync(path.join(root, 'LIVE'), `on since ${new Date().toISOString()} (from the Chef app)`); return { ok: true };
    case 'kitchen-resume': try { fs.unlinkSync(path.join(root, 'PAUSED')); } catch {} kick(); return { ok: true };   // Jordan's tap: same as kitchen.ps1 resume
    case 'live-off': try { fs.unlinkSync(path.join(root, 'LIVE')); } catch {} return { ok: true };
    default: return { ok: false, error: `unknown action '${op}'` };
  }
}

// ---- talk: chats with the kitchen. kitchen/talk.ps1 does the work (sous chef, privacy, the cook); chats live in <root>\talk ----
// A message is answered in the background; the phone hears 'talk' on the live stream when the answer is in. One answer at a time
// per chat, three at most overall; an answer that takes over 5 minutes is stopped with everything it started.
const talkPs = path.join(kitchenDir, 'talk.ps1');
const talkDir = path.join(root, 'talk');
const threadId = (v) => /^T\d{1,6}$/.test(String(v || '')) ? String(v) : null;
const talking = new Map();
function readThread(id) {
  const meta = readJson(path.join(talkDir, id + '.json'));
  let messages = [];
  try { messages = fs.readFileSync(path.join(talkDir, id + '.jsonl'), 'utf8').split(/\r?\n/).filter(Boolean).map((l) => { try { return JSON.parse(l.replace(/^﻿/, '')); } catch { return null; } }).filter(Boolean); } catch {}
  if (!meta && !messages.length && !talking.has(id)) return null;
  return { id, title: meta?.title || '', private: !!meta?.private, messages: messages.slice(-200), busy: talking.get(id) || null };
}
function lastCookOf(id) {
  const lines = tailLines(path.join(talkDir, id + '.jsonl'), 20);
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const msg = JSON.parse(lines[i].replace(/^\uFEFF/, ''));
      if (msg?.role === 'kitchen' && msg.cook) return String(msg.cook);
    } catch {}
  }
  return '';
}
function threads() {
  let files = []; try { files = fs.readdirSync(talkDir).filter((f) => /^T\d{1,6}\.json$/.test(f)); } catch {}
  return files.map((f) => { const id = f.slice(0, -5); const m = readJson(path.join(talkDir, f)); return m && { id, title: m.title || '', private: !!m.private, lastCook: m.lastCook || lastCookOf(id), updated: m.updated || m.created || '', busy: talking.has(id) }; })
    .filter(Boolean).sort((a, b) => String(b.updated).localeCompare(String(a.updated)));
}
function talk(body) {
  const text = typeof body.text === 'string' ? body.text.trim() : '';
  if (!text) return { ok: false, error: 'say something first' };
  if (text.length > 6000) return { ok: false, error: 'too long for a chat (6,000 characters); place an order for long pastes' };
  if (body.thread != null && body.thread !== '' && !threadId(body.thread)) return { ok: false, error: 'bad chat id' };
  let id = threadId(body.thread);
  if (!id) { const n = [...threads().map((t) => t.id), ...talking.keys()].reduce((x, t) => Math.max(x, Number(t.slice(1))), 0); id = 'T' + (n + 1); }
  if (talking.has(id)) return { ok: false, error: 'still answering your last message' };
  if (talking.size >= 3) return { ok: false, error: 'three chats are already waiting for answers' };
  talking.set(id, new Date().toISOString());
  const isPrivate = body.private === true || readJson(path.join(talkDir, id + '.json'))?.private === true;
  const args = ['-NoProfile', '-NonInteractive', '-File', talkPs, '-Thread', id, '-Message', ' ' + text, '-Json'];
  if (isPrivate) args.push('-Private');
  let timer = null;
  const child = execFile(pwsh, args, { windowsHide: true, maxBuffer: 8 << 20, env: { ...process.env, BRAIN_KITCHEN: root } }, (err, out) => {
    clearTimeout(timer); talking.delete(id);
    if (!clients.size && String(out || '').includes('"ok":true')) push('INFO', 'The Yard answered you in Talk.');   // nobody has the Board open
    let r = null; try { r = JSON.parse(String(out || '').trim().split(/\r?\n/).pop()); } catch {}
    broadcast('talk', { thread: id, done: true, ok: !!r?.ok, error: r?.ok ? undefined : (r?.error || 'the Yard did not answer') });
  });
  timer = setTimeout(() => { if (process.platform === 'win32') execFile('taskkill', ['/T', '/F', '/PID', String(child.pid)], { windowsHide: true }, () => {}); else child.kill(); }, Number(process.env.PASS_TALK_TIMEOUT_MS) || 300000);
  broadcast('talk', { thread: id, busy: true });
  return { ok: true, thread: id, pending: true };
}

// ---- job hunt: Jordan's applications (career/tracker.json in his brain repo; never leaves this PC) + the scout's latest openings ----
const careerDir = path.resolve(process.env.PASS_CAREER_DIR || path.join(os.userInfo().homedir, 'gemini-brain', 'projects', 'career'));
const trackerPath = path.join(careerDir, 'tracker.json');
const STATUSES = ['saved', 'applied', 'interview', 'offer', 'rejected', 'closed'];
const ACTIVE = ['saved', 'applied', 'interview', 'offer'];
const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
const addDays = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
// tracker.json is Jordan's whole application history. A missing file is an empty list; a file that exists but can't be read or parsed
// (a hand-edit typo, a git conflict marker, an antivirus lock) throws, so no write ever replaces it with a near-empty list (fail closed).
function trackerLoad() {
  let raw; try { raw = fs.readFileSync(trackerPath, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return []; throw new Error('tracker.json could not be read; nothing was saved'); }
  let t; try { t = JSON.parse(raw.replace(/^﻿/, '')); } catch { t = null; }
  if (!t || typeof t !== 'object' || (t.items != null && !Array.isArray(t.items))) throw new Error('tracker.json is not valid; nothing was saved (fix it or restore tracker.json.bak)');
  return Array.isArray(t.items) ? t.items.filter((x) => x && typeof x === 'object') : [];
}
function trackerItems() { try { return trackerLoad(); } catch { return []; } }   // read-only views (brief, due count); writers use trackerLoad
// every replace keeps the previous file as tracker.json.bak, then writes a temp file and renames it over (never half a file)
function saveTracker(items) {
  fs.mkdirSync(careerDir, { recursive: true });
  if (fs.existsSync(trackerPath)) fs.copyFileSync(trackerPath, trackerPath + '.bak');
  const tmp = `${trackerPath}.tmp-${process.pid}`; fs.writeFileSync(tmp, JSON.stringify({ updated: new Date().toISOString(), items }, null, 2)); fs.renameSync(tmp, trackerPath);
}
// One writer at a time across processes: the same tracker.json.lock kitchen/tracker-lib.ps1 takes (hunt-night, pack-render). The
// holder re-reads, changes and writes with no await in between; a lock older than 60 s is a crashed writer's and is cleared.
// The same exclusive-create lock file guards lead.json (with kitchen/lead.ps1).
async function withFileLock(lock, what, fn) {
  const until = Date.now() + 15000;
  for (;;) {
    try { fs.mkdirSync(path.dirname(lock), { recursive: true }); fs.closeSync(fs.openSync(lock, 'wx')); break; } catch (e) {
      if (e.code !== 'EEXIST' && e.code !== 'EPERM' && e.code !== 'EBUSY') throw e;
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 60000) { fs.unlinkSync(lock); continue; } } catch {}
      if (Date.now() > until) throw new Error(`${what} is busy (another writer holds the lock); nothing was saved`);
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  try { return fn(); } finally { try { fs.unlinkSync(lock); } catch {} }
}
const trackerLock = trackerPath + '.lock';
const withTrackerLock = (fn) => withFileLock(trackerLock, 'tracker.json', () => fn(trackerLoad()));
function scoutOpenings() {   // the newest job scout file: "- **Role** at Company (where). Pay..." then "Fit: ..." and "Link: ..."
  const dir = path.join(careerDir, 'scout'); let files = [];
  try { files = fs.readdirSync(dir).filter((f) => /-openings\.md$/.test(f)).map((f) => ({ f, t: fs.statSync(path.join(dir, f)).mtimeMs })).sort((a, b) => b.t - a.t); } catch {}
  if (!files.length) return { file: null, at: null, items: [] };
  const text = fs.readFileSync(path.join(dir, files[0].f), 'utf8'); const items = [];
  const re = /^- \*\*(.+?)\*\* at (.+?)(?: \(([^)]*)\))?\.\s*(.*)$/gm; let m;
  while ((m = re.exec(text)) && items.length < 30) {
    const rest = text.slice(m.index + m[0].length, m.index + m[0].length + 1500); const block = rest.split(/\n\s*\n|\n- \*\*/)[0];
    const fit = /Fit:\s*(.+)/.exec(block)?.[1] || ''; const link = /Link:\s*(https?:\/\/\S+)/.exec(block)?.[1] || '';
    items.push({ role: m[1].trim(), company: m[2].trim(), where: (m[3] || '').trim(), pay: m[4].trim(), fit: fit.trim(), link });
  }
  return { file: files[0].f, at: new Date(files[0].t).toISOString(), items };
}
const cleanStr = (v, max) => typeof v === 'string' ? v.trim().slice(0, max) : '';
// follow-up cadences: two touches each, so the cap comes from the table. `days` is counted from when the step before it was logged
// (or from when the job moved into that status, for the first step).
const CADENCE = {
  applied: [{ stage: 'initial', label: 'First follow-up', days: 7 }, { stage: 'final', label: 'Final follow-up', days: 7 }],
  interview: [{ stage: 'thanks', label: 'Thank-you note', days: 1 }, { stage: 'checkin', label: 'Status check-in', days: 7 }],
};
function startCadence(it, keepDate) {   // begin the cadence for it.status; a date typed in by Jordan wins
  const steps = CADENCE[it.status];
  it.touches = 0; it.stage = steps ? steps[0].stage : '';
  if (steps && !keepDate) it.followUp = addDays(steps[0].days);
}
const stamp = () => { const d = new Date(); return `${today()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; };
function logFollowUp(it, notes) {
  const steps = CADENCE[it.status];
  if (!steps) return { ok: false, error: 'only applied or interviewing jobs have follow-ups' };
  if (it.stage === 'done') return { ok: false, error: 'both follow-ups are already sent' };
  const i = Math.max(0, steps.findIndex((s) => s.stage === it.stage));   // saved before cadences: the first step
  const base = typeof notes === 'string' ? cleanStr(notes, 2000) : String(it.notes || '');
  const line = `${stamp()} ${steps[i].label} sent`;
  const next = base ? base + '\n' + line : line;
  if (next.length > 2000) return { ok: false, error: 'notes are full: trim them first' };
  it.notes = next; it.touches = i + 1;
  if (i + 1 < steps.length) { it.stage = steps[i + 1].stage; it.followUp = addDays(steps[i + 1].days); }
  else { it.stage = 'done'; it.followUp = ''; }
  return { ok: true };
}
// a client that sends the changedAt it last saw gets a refusal instead of overwriting an edit made on another phone meanwhile
const staleEdit = (it, body) => body.changedAt != null && String(body.changedAt) !== String(it.changedAt || '');
async function tracker(body) {
  const op = String(body.op || '');
  if (op === 'inspect') {   // the fetch takes up to 30 s, so it runs outside the lock and the result lands on a fresh re-read
    if (!body.id || !/^A\d{1,5}$/.test(String(body.id))) return { ok: false, error: 'no such application' };
    const it0 = trackerLoad().find((x) => x.id === body.id); if (!it0) return { ok: false, error: 'no such application' };
    if (!it0.link) return { ok: false, error: 'no link to inspect' };
    const link = it0.link;
    const { err, out } = await ps(atsPs, ['-Url', link, '-Json'], 30000);
    let r = null; try { r = JSON.parse(out.trim().split(/\r?\n/).pop()); } catch {}
    if (!r || !r.ok) return { ok: false, error: r?.error || (err ? String(err.message) : 'not supported') };
    return withTrackerLock((items) => {
      const it = items.find((x) => x.id === body.id); if (!it) return { ok: false, error: 'no such application' };
      if (it.link !== link) return { ok: false, error: 'the link changed while inspecting; try again' };
      it.description = cleanStr(r.description, 50000);
      it.questions = Array.isArray(r.questions) ? r.questions.map((q) => ({
        label: cleanStr(q.label, 200),
        name: cleanStr(q.name || q.field_name, 100),
        required: !!q.required,
        type: cleanStr(q.type, 50),
        options: Array.isArray(q.options) ? q.options.map((o) => cleanStr(o, 200)) : []
      })) : [];
      it.inspectedAt = new Date().toISOString();
      saveTracker(items); return { ok: true, data: it };
    });
  }
  if (op === 'profile-get') { const v = profileView(); return v.error ? { ok: false, error: v.error } : { ok: true, data: v }; }
  if (op === 'profile-save') return profileSave(body);
  if (op === 'apply-prep') return applyPrep(body);
  if (op === 'apply-fill') return applyStart(body, false);
  if (op === 'apply-submit') return applyStart(body, true);
  if (op === 'pack') return trackerPack(body, trackerLoad());   // reads only; the pack-render station writes under the lock
  return withTrackerLock((items) => trackerEdit(op, body, items));
}
function trackerEdit(op, body, items) {
  if (op === 'add') {
    const it = body.item || {}; const company = cleanStr(it.company, 120), role = cleanStr(it.role, 160);
    if (!company || !role) return { ok: false, error: 'company and role are needed' };
    const link = cleanStr(it.link, 500); if (link && !/^https?:\/\//.test(link)) return { ok: false, error: 'the link must start with http' };
    if (link && items.some((x) => x.link === link)) return { ok: false, error: 'already in your list' };
    const status = STATUSES.includes(it.status) ? it.status : 'saved';
    const n = items.reduce((x, i) => Math.max(x, Number(String(i.id).slice(1)) || 0), 0) + 1;
    const item = { id: 'A' + n, company, role, link, where: cleanStr(it.where, 120), pay: cleanStr(it.pay, 160), notes: cleanStr(it.notes, 2000), status,
      savedAt: new Date().toISOString(), appliedAt: status === 'applied' ? today() : '', followUp: '', stage: '', touches: 0, source: cleanStr(it.source, 60) };
    startCadence(item, false);
    items.push(item); saveTracker(items); return { ok: true, data: item };
  }
  if (op === 'update') {
    const it = items.find((x) => x.id === body.id); if (!it || !/^A\d{1,5}$/.test(String(body.id))) return { ok: false, error: 'no such application' };
    if (staleEdit(it, body)) return { ok: false, error: 'changed on another phone; reload first' };
    const ch = body.change || {};
    if ('status' in ch) {
      if (!STATUSES.includes(ch.status)) return { ok: false, error: 'bad status' };
      const moved = ch.status !== it.status;
      if (ch.status === 'applied' && it.status !== 'applied') it.appliedAt = it.appliedAt || today();
      if (!ACTIVE.includes(ch.status) && !('followUp' in ch)) it.followUp = '';
      it.status = ch.status;
      if (moved) startCadence(it, 'followUp' in ch);
    }
    if ('followUp' in ch) { if (ch.followUp && !/^\d{4}-\d{2}-\d{2}$/.test(ch.followUp)) return { ok: false, error: 'bad date' }; it.followUp = ch.followUp || ''; }
    if ('notes' in ch) it.notes = cleanStr(ch.notes, 2000);
    if ('draft' in ch) {   // the kitchen job that tailored a resume for this role; only ever used to build a file name inside tailored/
      if (!/^J\d{1,6}$/.test(String(ch.draft))) return { ok: false, error: 'bad draft id' };
      it.drafts = [...(Array.isArray(it.drafts) ? it.drafts : []).filter((d) => d !== ch.draft), ch.draft].slice(-10);
    }
    it.changedAt = new Date().toISOString(); saveTracker(items); return { ok: true, data: it };
  }
  if (op === 'follow-up') {
    const it = items.find((x) => x.id === body.id); if (!it || !/^A\d{1,5}$/.test(String(body.id))) return { ok: false, error: 'no such application' };
    if (staleEdit(it, body)) return { ok: false, error: 'changed on another phone; reload first' };
    const r = logFollowUp(it, body.notes); if (!r.ok) return r;
    it.changedAt = new Date().toISOString(); saveTracker(items); return { ok: true, data: it };
  }
  return { ok: false, error: 'unknown job-hunt action' };
}
function trackerPack(body, items) {
  const id = cleanStr(body.id, 20);
  if (!/^A\d{1,5}$/.test(id)) return { ok: false, error: 'bad application id' };
  const it = items.find((x) => x.id === id);
  if (!it) return { ok: false, error: 'no such application' };
  const description = cleanStr(it.description || it.notes || `${it.role} at ${it.company}`, 12000);
  // the exact questions Inspect read from the posting, or whatever was typed in
  const questions = Array.isArray(it.questions) ? it.questions.map((q) => '- ' + q.label + (q.required ? ' (required)' : '') + (q.options?.length ? ': ' + q.options.join(' / ') : '')).join('\n').slice(0, 12000) : cleanStr(it.questions || '', 12000);
  const vars = {
    appId: id,
    company: cleanStr(it.company, 120),
    role: cleanStr(it.role, 160),
    description: description || it.role,
    questions,
    private: 'yes'
  };
  return kicked(kitchen('cook', { recipe: 'pack', vars }));
}
// The newest tailored draft linked to one application: a plain file tailored/<J id>-draft.md (no symlinks), first 60 KB, split into sections.
// The file name is built only from ids shaped J\d+ that the tracker holds; the path is never sent back.
// 'check' is the taster's scorecard (tailor-check appends "# Tailor check ... - Result: PASS|FAIL"); it comes first so it is never hidden
const DRAFT_SECTIONS = [['check', /tailor check/i], ['fit', /fit|evaluation/i], ['summary', /summary/i], ['bullets', /bullet|resume|experience/i], ['cover', /cover|letter|note/i], ['gaps', /gap/i]];
function draftFor(appId) {
  const it = trackerItems().find((x) => x.id === appId); if (!it) return null;
  const dir = path.join(careerDir, 'tailored'); const found = [];
  for (const j of Array.isArray(it.drafts) ? it.drafts : []) {
    if (!/^J\d{1,6}$/.test(String(j))) continue;
    const p = path.join(dir, j + '-draft.md');
    try { const st = fs.lstatSync(p); if (st.isFile() && !st.isSymbolicLink()) found.push({ job: j, p, t: st.mtimeMs }); } catch {}
  }
  found.sort((a, b) => b.t - a.t); if (!found.length) return null;
  let text = ''; try { const fd = fs.openSync(found[0].p, 'r'); try { const buf = Buffer.alloc(60 * 1024); text = buf.toString('utf8', 0, fs.readSync(fd, buf, 0, buf.length, 0)); } finally { fs.closeSync(fd); } } catch { return null; }
  const sections = {}; let cur = null;
  for (const line of text.split(/\r?\n/)) {
    const h = /^#{1,4}\s*(.+?)\s*$/.exec(line);
    if (h) { const s = DRAFT_SECTIONS.find(([, re]) => re.test(h[1])); cur = s ? s[0] : null; if (cur && !(cur in sections)) sections[cur] = ''; continue; }
    if (cur) sections[cur] += line + '\n';
  }
  for (const k of Object.keys(sections)) { sections[k] = sections[k].trim(); if (!sections[k]) delete sections[k]; }
  // the taster's verdict: a draft that failed (or was never checked) is not a ready pack
  const verdict = /^# Tailor check[\s\S]*?^- Result:\s*(PASS|FAIL)/m.exec(text);
  const check = verdict ? verdict[1].toLowerCase() : 'none';
  const coverage = /^- Keyword coverage:\s*(.+)$/m.exec(text)?.[1]?.trim() || '';
  return { job: found[0].job, at: new Date(found[0].t).toISOString(), sections, text, check, coverage };
}
// ---- apply packet: career/packets/<id>/ (kitchen/stations/apply-prep.ps1, private local cook). Chef shows every answer for review;
// Jordan's one tap ('apply-submit', with the packet hash he saw) hands it to kitchen/apply-fill.mjs, which fills the form in Edge on this
// PC. Nothing here clicks or posts a form: the script does, only after that tap, and a changed packet or an empty required answer stops it.
const packetsDir = path.join(careerDir, 'packets');
const PACKET_FILES = ['answers.json', 'cover.txt', 'link.txt', 'resume.pdf'];   // hash order: the same as apply-prep.ps1 Get-PacketHash
const applyFillPath = path.resolve(process.env.PASS_APPLY_FILL || path.join(kitchenDir, 'apply-fill.mjs'));   // env: tests only
const appIdOk = (v) => /^A\d{1,5}$/.test(String(v || ''));
const APPLIED = ['applied', 'interview', 'offer'];
function readPacket(id) {   // plain files only (no symlinks); the hash is always recomputed from the bytes, never taken from packet.json
  if (!appIdOk(id)) return null; const dir = path.join(packetsDir, id);
  try {
    const h = crypto.createHash('sha256'); const buf = {};
    for (const f of PACKET_FILES) { const p = path.join(dir, f); const st = fs.lstatSync(p); if (!st.isFile() || st.isSymbolicLink()) return null; buf[f] = fs.readFileSync(p); h.update(buf[f]); }
    const meta = JSON.parse(fs.readFileSync(path.join(dir, 'packet.json'), 'utf8').replace(/^﻿/, '')) || {};
    let list = JSON.parse(buf['answers.json'].toString('utf8').replace(/^﻿/, '')); if (!Array.isArray(list)) list = list && typeof list === 'object' ? [list] : [];
    const answers = list.filter((a) => a && typeof a === 'object').slice(0, 200).map((a) => ({ question: cleanStr(a.question, 500), name: cleanStr(a.name, 100), type: cleanStr(a.type, 50), required: !!a.required,
      options: Array.isArray(a.options) ? a.options.slice(0, 100).map((o) => cleanStr(String(o), 200)) : [], answer: cleanStr(a.answer, 5000), source: ['resume', 'profile', 'jordan'].includes(a.source) ? a.source : 'jordan', needsJordan: !!a.needsJordan, note: cleanStr(a.note, 300) }));
    const link = buf['link.txt'].toString('utf8').replace(/^﻿/, '').trim();
    return { id, company: cleanStr(meta.company, 120), role: cleanStr(meta.role, 160), link: /^https?:\/\//.test(link) ? link.slice(0, 500) : '', cover: buf['cover.txt'].toString('utf8').replace(/^﻿/, '').slice(0, 5000),
      answers, resumeName: 'resume.pdf', resumeSha256: cleanStr(meta.resumeSha256, 64), generatedAt: cleanStr(meta.generatedAt, 40), hash: h.digest('hex'), stale: packetStale(meta) };
  } catch { return null; }
}
const packetIds = () => { try { return fs.readdirSync(packetsDir).filter((d) => appIdOk(d) && fs.existsSync(path.join(packetsDir, d, 'packet.json'))); } catch { return []; } };
async function applyPrep(body) {   // (re)build one role's packet: after Jordan filled profile.json, or a role the hunt had no slot for
  const id = cleanStr(body.id, 20); if (!appIdOk(id)) return { ok: false, error: 'bad application id' };
  const it = trackerLoad().find((x) => x.id === id); if (!it) return { ok: false, error: 'no such application' };
  const vars = { appId: id, company: cleanStr(it.company, 120), role: cleanStr(it.role, 160), description: cleanStr(it.description || it.notes || '', 12000).replace(/\{\{/g, '{ {'), private: 'yes', cook: 'local' };
  return kicked(kitchen('cook', { recipe: 'apply-prep', vars }));
}
let applyRun = null;   // one fill at a time: { id, submit }
// the script's verdict: packets/<id>/fill-result.json, else the last JSON line it printed. { result: 'applied'|'filled'|'needs-you', confirmation, reason }
function fillResult(id) {
  const dir = path.join(packetsDir, id); let r = readJson(path.join(dir, 'fill-result.json'));
  if (!r) for (const l of tailLines(path.join(dir, 'fill.log'), 50).reverse()) { try { const o = JSON.parse(l); if (o && typeof o === 'object' && !Array.isArray(o)) { r = o; break; } } catch {} }
  return r && typeof r === 'object' ? r : null;
}
function settleApply(id, submit, code) {
  const r = fillResult(id) || {}; const word = String(r.result || r.status || '').toLowerCase();
  return withTrackerLock((items) => {
    const it = items.find((x) => x.id === id); if (!it || !it.apply) return { ok: false };
    const now = new Date().toISOString();
    if (submit && word === 'applied' && r.ok !== false) {   // confirmed submit: applied, with the follow-up cadence started as Mark applied does
      if (!APPLIED.includes(it.status)) { it.status = 'applied'; it.appliedAt = it.appliedAt || today(); startCadence(it, false); }
      it.apply = { ...it.apply, state: 'applied', confirmation: cleanStr(String(r.confirmation || ''), 300), doneAt: now };
      push('INFO', 'An application was sent. Open the Board.');   // no company or role: push goes through a public relay
    } else if (!submit && ['filled', 'ok', 'done'].includes(word) && r.ok !== false) it.apply = { ...it.apply, state: 'filled', reason: 'Filled in Edge on your PC. Check it there; nothing was submitted.', doneAt: now };
    else {
      it.apply = { ...it.apply, state: 'needs-you', reason: cleanStr(String(r.reason || r.error || (code ? `auto-fill stopped (exit ${code})` : 'auto-fill finished without saying how it went')), 300), doneAt: now };
      if (submit) push('HIGH', 'An application needs you: the Edge window is open on your PC.');
    }
    it.changedAt = now; saveTracker(items); return { ok: true };
  });
}
async function applyStart(body, submit) {
  const id = cleanStr(body.id, 20); if (!appIdOk(id)) return { ok: false, error: 'bad application id' };
  const it = trackerLoad().find((x) => x.id === id); if (!it) return { ok: false, error: 'no such application' };
  const pk = readPacket(id); if (!pk) return { ok: false, error: 'no apply packet for this role yet' };
  if (pk.stale.length) return { ok: false, error: `this packet was built from an older ${pk.stale.join(' and ')}; tap Rebuild packet first` };
  if (submit) {
    if (APPLIED.includes(it.status)) return { ok: false, error: 'already applied' };
    if (String(body.hash || '') !== pk.hash) return { ok: false, error: 'the packet changed since you looked at it; reload and check it again' };
    const empty = pk.answers.filter((a) => a.required && !a.answer.trim());
    if (empty.length) return { ok: false, error: `${empty.length} required answer${empty.length > 1 ? 's are' : ' is'} still empty: ${empty.slice(0, 3).map((a) => a.question).join('; ')}` };
  }
  if (!fs.existsSync(applyFillPath)) return { ok: false, error: 'auto-fill not installed yet' };
  if (applyRun) return { ok: false, error: `already filling ${applyRun.id}; one at a time` };
  applyRun = { id, submit };   // taken before the first await, so a double tap can't start two
  let fd = null;
  try {
    const marked = await withTrackerLock((items) => {
      const x = items.find((y) => y.id === id); if (!x) return { ok: false, error: 'no such application' };
      if (submit && APPLIED.includes(x.status)) return { ok: false, error: 'already applied' };
      x.apply = { state: submit ? 'submitting' : 'filling', at: new Date().toISOString(), hash: pk.hash }; x.changedAt = x.apply.at; saveTracker(items); return { ok: true };
    });
    if (!marked.ok) { applyRun = null; return marked; }
    fs.rmSync(path.join(packetsDir, id, 'fill-result.json'), { force: true });
    fd = fs.openSync(path.join(packetsDir, id, 'fill.log'), 'w');
    const args = [applyFillPath, '--item', id]; if (submit) args.push('--submit', '--packet-hash', pk.hash);
    // detached: the fill outlives a Chef restart; its own window (Edge) is what Jordan sees, the console stays hidden
    const child = spawn(process.execPath, args, { cwd: path.resolve(kitchenDir, '..'), detached: true, windowsHide: true, stdio: ['ignore', fd, fd], env: { ...process.env, PASS_CAREER_DIR: careerDir, BRAIN_KITCHEN: root } });
    let done = false; const finish = (code) => { if (done) return; done = true; applyRun = null; settleApply(id, submit, code).catch(() => {}); };
    child.on('exit', (code) => finish(code)); child.on('error', () => finish(1)); child.unref();
    return { ok: true, started: true, data: { id, started: true, state: submit ? 'submitting' : 'filling' } };
  } catch (e) { applyRun = null; return { ok: false, error: 'could not start auto-fill: ' + e.message }; }
  finally { if (fd != null) try { fs.closeSync(fd); } catch {} }
}
// a fill that ended while Chef was down: settle it from its result when shown; one silent for 30 minutes is handed back to Jordan
async function packetView(id) {
  const it = trackerItems().find((x) => x.id === id); const pk = readPacket(id); if (!it || !pk) return null;
  if (['submitting', 'filling'].includes(it.apply?.state) && applyRun?.id !== id) {
    const at = Date.parse(it.apply.at) || 0; let logT = 0; try { logT = fs.statSync(path.join(packetsDir, id, 'fill.log')).mtimeMs; } catch {}
    if ((fillResult(id) && logT >= at) || Date.now() - at > 30 * 60000) { try { await settleApply(id, it.apply.state === 'submitting', 0); } catch {} return packetView(id); }
  }
  const missing = pk.answers.filter((a) => a.required && !a.answer.trim()).length;
  return { ...pk, status: it.status, apply: it.apply || null, missingRequired: missing, filler: fs.existsSync(applyFillPath), busy: applyRun?.id || null };
}
const dueItems = () => trackerItems().filter((x) => ACTIVE.includes(x.status) && x.followUp && x.followUp <= today());

// ---- My answers: Jordan's standing answers (career/profile.json, the fields apply-prep.ps1 makes). Filled from the phone; the values never
// reach a log (the audit line holds only the op), a cloud cook, or an error message. Same safety as tracker.json and lead.json: an
// exclusive lock file, re-read inside it, a file that exists but can't be read is never written over, .bak then temp + rename.
const profilePath = path.join(careerDir, 'profile.json');
const PROFILE_FIELDS = { name: [120], email: [200, 'email'], phone: [40, 'tel'], city: [100], state: [100], country: [100], linkedin: [300, 'url'], github: [300, 'url'], website: [300, 'url'],
  workAuthorization: [200], needsSponsorship: [3, 'yesno'], salaryExpectation: [120], earliestStart: [120], willingToRelocate: [3, 'yesno'], remotePreference: [120], yearsExperience: [10, 'years'], howDidYouHear: [120] };
const EEO_FIELDS = ['gender', 'race', 'veteran', 'disability'];
const sha256File = (p) => { try { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); } catch { return ''; } };
function careerResumePath() {   // kitchen.json "career".resume (state-folder copy wins), as kitchen/tracker-lib.ps1 Get-CareerFiles reads it
  let rel = 'MASTER_RESUME.md';
  for (const f of [path.join(kitchenDir, 'kitchen.json'), path.join(root, 'kitchen.json')]) {
    const v = readJson(f)?.career?.resume;
    if (typeof v === 'string' && /\.md$/.test(v) && !path.win32.isAbsolute(v) && !/(^|[\\/])\.\.([\\/]|$)/.test(v) && !/[:*?"<>|{}]/.test(v)) rel = v;
  }
  return path.join(careerDir, rel);
}
// why a packet must be rebuilt before it is sent: profile.json changed since its answers were drawn (or it predates the record), or the
// locked resume was re-rendered, or the resume source changed and is not rendered yet
function packetStale(meta) {
  const why = [];
  if (typeof meta.profileHash !== 'string' || meta.profileHash !== sha256File(profilePath)) why.push('profile');
  const lm = readJson(path.join(careerDir, 'resume-locked.json')); const src = sha256File(careerResumePath());
  if (!meta.resumeSha256 || meta.resumeSha256 !== sha256File(path.join(careerDir, 'resume-locked.pdf')) || !src || lm?.sourceSha256 !== src || meta.resumeSourceSha256 !== src) why.push('resume');
  return why;
}
function profileLoad() {   // { exists, p } or throws when the file is there but unreadable or not a JSON object (never treated as empty)
  let raw; try { raw = fs.readFileSync(profilePath, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return { exists: false, p: {} }; throw new Error('profile.json could not be read; nothing was saved'); }
  let p; try { p = JSON.parse(raw.replace(/^﻿/, '')); } catch { p = null; }
  if (!p || typeof p !== 'object' || Array.isArray(p) || (p.eeo != null && (typeof p.eeo !== 'object' || Array.isArray(p.eeo)))) throw new Error('profile.json is not valid; nothing was saved (fix it on the PC)');
  return { exists: true, p };
}
const asText = (v, yesno) => typeof v === 'boolean' ? (v ? 'Yes' : 'No') : typeof v === 'number' ? String(v) : typeof v === 'string' ? (yesno && /^(yes|no)$/i.test(v.trim()) ? v.trim()[0].toUpperCase() + v.trim().slice(1).toLowerCase() : v) : '';
function profileView() {
  let L; try { L = profileLoad(); } catch (e) { return { error: e.message }; }
  const fields = {}; for (const [k, [, kind]] of Object.entries(PROFILE_FIELDS)) fields[k] = asText(L.p[k], kind === 'yesno');
  const eeo = {}; for (const k of EEO_FIELDS) eeo[k] = asText(L.p.eeo?.[k]);
  const all = [...Object.values(fields), ...Object.values(eeo)];
  const stale = packetIds().filter((id) => readPacket(id)?.stale.includes('profile')).length;
  return { exists: L.exists, hash: sha256File(profilePath), fields, eeo, filled: all.filter((v) => String(v).trim()).length, total: all.length, stalePackets: stale };
}
// one value from the phone: a string of the right shape, or a refusal that names the field (never the value)
function profileValue(k, v, max, kind) {
  if (typeof v !== 'string') return { error: `${k} must be text` };
  v = v.trim(); if (v.length > max) return { error: `${k} is longer than ${max} characters` };
  if (/[\u0000-\u001f\u007f]/.test(v)) return { error: `${k} has a control character` };
  if (!v) return { v };
  if (kind === 'email' && !/^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/.test(v)) return { error: `${k} does not look like an email address` };
  if (kind === 'tel' && !/^[0-9+().\-\s]{3,40}$/.test(v)) return { error: `${k} may hold only digits, spaces and + ( ) . -` };
  if (kind === 'url' && !/^https?:\/\/[^\s<>"]+$/i.test(v)) return { error: `${k} must be a link starting with https://` };
  if (kind === 'yesno' && !/^(Yes|No)$/.test(v)) return { error: `${k} must be Yes or No` };
  if (kind === 'years' && !/^\d{1,2}(\.\d)?\+?$/.test(v)) return { error: `${k} must be a number of years, like 8` };
  return { v };
}
async function profileSave(body) {
  const inP = body.profile;
  if (!inP || typeof inP !== 'object' || Array.isArray(inP)) return { ok: false, error: 'no answers sent' };
  const clean = {}; const eeo = {};
  for (const k of Object.keys(inP)) {
    if (k === 'eeo') continue;
    if (!Object.hasOwn(PROFILE_FIELDS, k)) return { ok: false, error: `unknown field: ${k.replace(/\W/g, '').slice(0, 40)}` };
    const [max, kind] = PROFILE_FIELDS[k]; const r = profileValue(k, inP[k], max, kind); if (r.error) return { ok: false, error: r.error }; clean[k] = r.v;
  }
  if (inP.eeo != null) {
    if (typeof inP.eeo !== 'object' || Array.isArray(inP.eeo)) return { ok: false, error: 'eeo must be a set of answers' };
    for (const k of Object.keys(inP.eeo)) {
      if (!EEO_FIELDS.includes(k)) return { ok: false, error: `unknown field: eeo.${k.replace(/\W/g, '').slice(0, 40)}` };
      const r = profileValue('eeo.' + k, inP.eeo[k], 150, 'text'); if (r.error) return { ok: false, error: r.error }; eeo[k] = r.v;
    }
  }
  return withFileLock(profilePath + '.lock', 'profile.json', () => {
    const L = profileLoad();   // throws on an unreadable file: the handler refuses, nothing is written
    if (typeof body.hash === 'string' && body.hash !== sha256File(profilePath)) return { ok: false, error: 'changed on another phone or the PC; reload first' };
    // template order first; keys Jordan added by hand on the PC are kept as they are
    const out = {}; for (const k of Object.keys(PROFILE_FIELDS)) out[k] = k in clean ? clean[k] : (L.p[k] ?? '');
    for (const [k, v] of Object.entries(L.p)) if (!(k in out) && k !== 'eeo') out[k] = v;
    out.eeo = { ...(L.p.eeo || {}) }; for (const k of EEO_FIELDS) out.eeo[k] = k in eeo ? eeo[k] : (out.eeo[k] ?? '');
    fs.mkdirSync(careerDir, { recursive: true });
    if (L.exists) fs.copyFileSync(profilePath, profilePath + '.bak');
    const tmp = `${profilePath}.tmp-${process.pid}`; fs.writeFileSync(tmp, JSON.stringify(out, null, 2)); fs.renameSync(tmp, profilePath);
    const v = profileView(); return { ok: true, data: v };
  });
}

// ---- push alerts to the phone (ntfy). Off until Jordan turns them on in Settings; then only short words ("J12 needs your yes"),
// never what an order or a chat says. The topic is a random name made here; kitchen/notify.ps1 does the sending.
const pushOnPath = path.join(root, 'push-on'); const topicPath = path.join(root, 'ntfy-topic.txt');
const pushOn = () => fs.existsSync(pushOnPath) && /^[A-Za-z0-9_-]{12,64}$/.test(readTopic());
function readTopic() { try { return fs.readFileSync(topicPath, 'utf8').trim(); } catch { return ''; } }
function push(level, text) { if (pushOn()) execFile(pwsh, ['-NoProfile', '-NonInteractive', '-File', path.join(kitchenDir, 'notify.ps1'), '-Level', level, '-Text', ' ' + text, '-Safe'], { windowsHide: true, timeout: 20000, env: { ...process.env, BRAIN_KITCHEN: root } }, () => {}); }

// ---- the morning brief: what happened overnight and what is waiting, from the kitchen's own files (no AI, free, private) ----
const daysUntil = (d) => { const a = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(d || '')), b = /^(\d{4})-(\d{2})-(\d{2})$/.exec(today()); return a ? Math.round((Date.UTC(+a[1], +a[2] - 1, +a[3]) - Date.UTC(+b[1], +b[2] - 1, +b[3])) / 86400000) : null; };   // whole days from today (UTC midnights, so DST can't skew it); null for a bad date
const whenWord = (n) => n < 0 ? 'overdue' : n === 0 ? 'today' : `in ${n} day${n === 1 ? '' : 's'}`;
// changes that merged under Jordan's auto-merge policy in the last day (automerged.jsonl), minus any he undid
// a short plain name for an order built from an idea ("Switch cooks when one rests for days"), from the idea's title in its goal;
// never for a private order (its words stay out of the live stream)
function labelOf(j) {
  if (!j || isJobPrivate(j)) return '';
  const m = /\(Idea I\d+: ([^.\n]{4,80})/.exec(String(j.vars?.goal || ''));
  return m ? m[1].trim() : '';
}
function autoMergedToday() {
  const rows = tailLines(path.join(root, 'automerged.jsonl'), 200).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const undone = new Set(rows.filter((r) => r.undone).map((r) => r.job)); const since = Date.now() - 24 * 3600 * 1000;
  return rows.filter((r) => !r.undone && !undone.has(r.job) && new Date(r.at).getTime() > since).map((r) => ({ id: r.job, name: r.name || r.job, why: r.why || '' })).slice(-20);
}
// ---- Since You Looked: what moved since this phone last looked (the phone keeps that time; Chef only counts) ----
// events.jsonl is append-only (kitchen.ps1), so it is read once and after that only its new bytes: no request re-scans the log. Only
// the few event types the counts need are kept, as (time, type, ticket). A file shorter than what was read (replaced) is read again.
const SINCE_TYPES = new Set(['job.done', 'job.quarantined', 'approval.requested', 'step.hold']);
// It also keeps the cost lines (time, cook, tokens, dollars) of the last 8 days for the spend and token counts on the board.
const COST_KEEP_MS = 8 * 86400000;
const evIndex = { sig: '', off: 0, first: null, rows: [], cost: [], reads: 0 };
function eventIndex() {
  const p = path.join(root, 'events.jsonl'); const sig = sigOf(p);
  if (sig === evIndex.sig) return evIndex;
  let size = -1; try { size = fs.statSync(p).size; } catch {}
  if (size < evIndex.off) Object.assign(evIndex, { off: 0, first: null, rows: [], cost: [] });
  if (size > evIndex.off) {
    const fd = fs.openSync(p, 'r'); evIndex.reads++;
    try {
      while (evIndex.off < size) {   // 4 MB at a time; only whole lines (a line still being written is read next time)
        const len = Math.min(size - evIndex.off, 4 << 20); const buf = Buffer.alloc(len); fs.readSync(fd, buf, 0, len, evIndex.off); work.indexBytes += len;
        const end = buf.lastIndexOf(10);
        if (end < 0) { if (len === 4 << 20) { evIndex.off += len; continue; } break; }   // a 4 MB line is skipped, never looped on
        for (const l of buf.subarray(0, end).toString('utf8').replace(/^\uFEFF/, '').split(/\r?\n/)) {
          if (!l) continue; let e; try { e = JSON.parse(l); } catch { continue; }
          const t = Date.parse(e?.ts); if (!Number.isFinite(t)) continue;
          if (evIndex.first === null || t < evIndex.first) evIndex.first = t;   // (TD-EH-18: lines folded back from events-pending come late)
          if (SINCE_TYPES.has(e.type) && jobId(e.job)) evIndex.rows.push({ t, type: e.type, job: e.job });
          else if (e.type === 'cost' && Date.now() - t < COST_KEEP_MS) evIndex.cost.push({ t, sup: String(e.supplier || ''), usd: Number(e.usd) || 0,
            tok: (Number(e.inputTokens) || 0) + (Number(e.outputTokens) || 0) + (Number(e.cacheReadTokens) || 0) + (Number(e.cacheWriteTokens) || 0) });
        }
        evIndex.off += end + 1;
      }
    } finally { fs.closeSync(fd); }
    if (evIndex.cost.length && Date.now() - evIndex.cost[0].t > COST_KEEP_MS) evIndex.cost = evIndex.cost.filter((c) => Date.now() - c.t < COST_KEEP_MS);
  }
  evIndex.sig = sig; return evIndex;
}
// counts since a moment: tickets plated, set aside, and asks still waiting for Jordan that came in since then (a ticket counts once).
// known: false when the log does not reach back that far (or there is no log), so the phone says "unknown", never a made-up zero.
function sinceView(sinceIso, jobs = loadJobs({ watched: true })) {
  const ms = Date.parse(String(sinceIso || '')); if (!Number.isFinite(ms)) return null;
  const ix = eventIndex(); const at = new Date(ms).toISOString();
  if (ix.first === null || ms < ix.first) return { since: at, known: false, from: ix.first === null ? null : new Date(ix.first).toISOString() };
  const ids = (types) => [...new Set(ix.rows.filter((r) => r.t >= ms && types.includes(r.type)).map((r) => r.job))];
  const st = new Map(jobs.map((j) => [j.id, j.status]));
  return { since: at, known: true, plated: ids(['job.done']), setAside: ids(['job.quarantined']),
    needsYou: ids(['approval.requested', 'step.hold']).filter((id) => ['waiting-approval', 'needs-human'].includes(st.get(id))) };
}
function brief(sinceIso = null) {
  const sinceMs = Date.now() - 14 * 3600 * 1000; const jobs = loadJobs({ watched: true });
  const evs = tailLines(path.join(root, 'events.jsonl'), 5000, 4 << 20).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((e) => e && new Date(e.ts).getTime() >= sinceMs);
  const plated = [...new Set(evs.filter((e) => e.type === 'job.done').map((e) => e.job))];
  const setAside = [...new Set(evs.filter((e) => e.type === 'job.quarantined').map((e) => e.job))];
  const name = (id) => jobs.find((j) => j.id === id)?.name || id;
  const item = (id) => { const j = jobs.find((x) => x.id === id); return { id, name: j?.name || id, label: labelOf(j) }; };
  const scout = scoutOpenings(); const saved = new Set(trackerItems().map((x) => x.link).filter(Boolean));
  const fresh = scout.at && new Date(scout.at).getTime() >= sinceMs ? scout.items.filter((x) => !saved.has(x.link)) : [];
  const board = readJson(path.join(root, 'suppliers-board.json')) || {}; const pu = board.suppliers?.claude?.planUse || null;
  const items = trackerItems();
  const drafted = items
    .filter((x) => x.status === 'saved')
    .map((x) => {
      const d = draftFor(x.id);
      return d ? { id: x.id, company: x.company, role: x.role, link: x.link, draft: d.job, check: d.check, coverage: d.coverage } : null;
    })
    .filter(Boolean);
  const packs = drafted.filter((x) => x.check === 'pass');   // only drafts the taster passed are 'ready'
  const packsNeedLook = drafted.filter((x) => x.check !== 'pass');
  const withWhen = (x) => { const days = daysUntil(x.followUp) ?? -1; return { ...x, days, when: whenWord(days) }; };
  const upcoming = items.filter((x) => ACTIVE.includes(x.status) && x.followUp && (daysUntil(x.followUp) ?? 0) >= 1 && daysUntil(x.followUp) <= 3)
    .sort((a, b) => a.followUp.localeCompare(b.followUp)).map(withWhen);
  return { at: new Date().toISOString(), needsYou: jobs.filter((j) => j.status === 'waiting-approval' || j.status === 'needs-human').map((j) => item(j.id)),
    plated: plated.map(item), setAside: setAside.map(item),
    packs, packCount: packs.length, packsNeedLook, autoMerged: autoMergedToday().map((x) => ({ ...x, label: labelOf(jobs.find((j) => j.id === x.id)) })),
    newRoles: fresh.slice(0, 5), newRoleCount: fresh.length, followUps: dueItems().map(withWhen), upcoming, applied: items.filter((x) => x.status === 'applied').length,
    interviews: items.filter((x) => x.status === 'interview').length, plan: pu ? { five: pu.five, week: pu.week } : null, live: fs.existsSync(path.join(root, 'LIVE')),
    since: sinceIso ? sinceView(sinceIso, jobs) : null, stuck: jobs.map((j) => ({ id: j.id, stuck: stuckOf(j) })).filter((x) => x.stuck), lobe: lobeBrief(), lobeSkips: lobeSkips() };   // ZG-13: the lobe line (counts, age, skipped); ZG-17: skip counts
}
// ---- when Claude (the lead) is away: Claude's weekly plan limit runs out, so Jordan can't talk to Claude for a while. The kitchen
// keeps cooking on the other cooks; Chef shows when Claude is back, Claude's last note, and keeps Jordan's notes for Claude's return
// (handoff.ps1 puts them at the top of the next boot pack). A note can also go straight to the kitchen as an idea (Jordan's tap).
const leadPath = path.join(root, 'lead.json');
const LEAD_LOW = 0.75, LEAD_OUT = 0.98;   // low: Jordan sees the card and can leave notes before Claude goes quiet
function leadSave(L) { const tmp = `${leadPath}.tmp-${process.pid}`; fs.writeFileSync(tmp, JSON.stringify(L, null, 2)); fs.renameSync(tmp, leadPath); }
// the board's copy: made again when lead.json, plan-usage.json or the event log changes, or the minute turns (resets and away times)
const leadView = () => memo('lead', [sigOf(leadPath), sigOf(path.join(root, 'plan-usage.json')), eventIndex().sig, Math.floor(Date.now() / 60000)].join('|'), leadViewNow);
function leadViewNow() {
  const L = readJson(leadPath) || {}; const now = Date.now();
  const pu = readJson(path.join(root, 'plan-usage.json'))?.claude || null;
  const resets = pu?.sevenDay?.resetsAt || null; const resetMs = resets ? new Date(resets).getTime() : 0;
  const fresh = resetMs > now;   // a reading from before the last reset says nothing about now
  const week = fresh ? Number(pu.sevenDay.used) || 0 : 0;
  const five = pu?.fiveHour?.resetsAt && new Date(pu.fiveHour.resetsAt).getTime() > now ? Number(pu.fiveHour.used) || 0 : 0;
  const until = L.away?.until ? new Date(L.away.until).getTime() : 0;
  const manual = !!L.away?.on && (!until || until > now);
  const blocked = fresh && /reject|block|exceed/i.test(String(pu?.status || '')) && /seven|week/i.test(String(pu?.window || ''));
  const mode = manual || blocked || week >= LEAD_OUT ? 'away' : week >= LEAD_LOW ? 'low' : 'here';
  const awayAt = mode === 'away' ? (L.away?.at || pu?.at || null) : null;
  let doneSince = 0;
  if (awayAt) { const t = new Date(awayAt).getTime(); for (const r of eventIndex().rows) if (r.type === 'job.done' && r.t >= t) doneSince++; }   // the event index (new bytes only), not a 5,000-line re-read
  return { mode, week, five, resetsAt: fresh ? resets : null, readAt: pu?.at || null, manual, awayAt, doneSince,
    handoff: L.handoff?.text ? { at: L.handoff.at, text: String(L.handoff.text).slice(0, 1500) } : null,
    notes: (L.notes || []).filter((n) => n.status === 'open' || n.status === 'kitchen').slice(-40).reverse() };   // done (Claude handled it) and removed notes leave Chef
}
// The World view (ZG-09, public/lobe.js): the lobe's frame, csf.json ONLY (never watch\, never the brief), read-only, from ZEITGEISTD_HOME
// (a leading ~ expands like Python's expanduser), else <kitchen>\lobe. One file read when its size or time changes (sigOf): no git, no model,
// no database. The Board is tailnet-only, so the frame goes to the phone whole, except the Yard signal titles (they name work orders): only
// their count leaves this process. Missing, oversized or broken = {ok:false, why} in fixed words (never the file's text, never an error page).
const LOBE_MAX = 2400;   // zeitgeistd csf.MAX_CHARS: a bigger file is not a frame
const LOBE_KEYS = 'meta,1_normative_charter,2_endogenous_self_state,3_exogenous_world_deltas,4_epistemic_tensions,5_decision_ready_nodes';
function lobeFile() {
  let h = String(process.env.ZEITGEISTD_HOME || '').trim();
  if (/^~(?=$|[\\/])/.test(h)) h = (process.env.USERPROFILE || process.env.HOME || '') + h.slice(1);
  return path.join(path.resolve(h || path.join(root, 'lobe')), 'csf.json');
}
const lobeView = () => { const p = lobeFile(); return memo('lobe', p + '|' + sigOf(p), () => lobeRead(p)); };
function lobeRead(p) {
  if (/[\\/](evie|evie_admin|life_admin|finances)([\\/]|$)/i.test(path.dirname(p))) return { ok: false, why: 'frame refused: the lobe home is inside a protected path, so it was not read' };   // handoff.ps1's protected list
  let st, raw; try { st = fs.statSync(p); if (st.isFile() && st.size <= LOBE_MAX) raw = fs.readFileSync(p, 'utf8'); } catch { return { ok: false, why: 'no frame yet' }; }
  if (!st.isFile()) return { ok: false, why: 'frame refused: csf.json is not a file' };
  if (raw === undefined) return { ok: false, why: `frame refused: csf.json is over ${LOBE_MAX} characters` };
  let f = null; try { f = JSON.parse(raw); } catch {}
  if (!f || typeof f !== 'object' || Array.isArray(f) || Object.keys(f).join() !== LOBE_KEYS) return { ok: false, why: 'frame refused: it is not a csf.json frame (the document 6.2 sections, in order)' };
  const self = f['2_endogenous_self_state'];
  if (self && typeof self === 'object' && 'yard_signals' in self) self.yard_signals = Array.isArray(self.yard_signals) ? self.yard_signals.length : 0;   // a count only
  return { ok: true, csf: f, health: { file: 'csf.json', bytes: st.size, writtenUtc: new Date(st.mtimeMs).toISOString() } };
}
// lead.json has two writers (this server and kitchen/lead.ps1, run by Claude). Every change re-reads the file, edits and writes it
// (temp + rename) while holding lead.json.lock, the same exclusive-create lock lead.ps1 takes, so a note added from the phone while
// Claude marks another done is never lost. A lead.json that exists but can't be parsed is refused, never replaced (fail closed).
const leadLock = leadPath + '.lock';
function leadLoad() {
  let raw; try { raw = fs.readFileSync(leadPath, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return { notes: [] }; throw new Error('lead.json could not be read'); }
  let L; try { L = JSON.parse(raw.replace(/^﻿/, '')); } catch { L = null; }
  if (!L || typeof L !== 'object' || Array.isArray(L)) throw new Error('lead.json is not valid; nothing was saved');
  if (!Array.isArray(L.notes)) L.notes = L.notes && typeof L.notes === 'object' ? [L.notes] : [];   // ConvertTo-Json writes a one-note list as an object
  return L;
}
const leadEdit = (fn) => withFileLock(leadLock, 'lead.json', () => { const L = leadLoad(); const r = fn(L); if (r?.save !== false && r?.ok) leadSave(L); return r; });
async function leadAct(body) {
  const op = String(body.op || '');
  if (op === 'note') {
    const text = cleanStr(body.text, 1000); if (text.length < 2) return { ok: false, error: 'write a note first' };
    return leadEdit((L) => {
      const n = { id: 'N' + (L.notes.reduce((m, x) => Math.max(m, Number(String(x.id).slice(1)) || 0), 0) + 1), at: new Date().toISOString(), text, status: 'open' };
      L.notes.push(n); if (L.notes.length > 200) L.notes = L.notes.slice(-200); return { ok: true, data: n };
    });
  }
  const id = String(body.id || '');
  if (op === 'drop') return leadEdit((L) => { const note = L.notes.find((x) => x.id === id); if (!note) return { ok: false, error: 'no such note' }; note.status = 'gone'; return { ok: true }; });
  if (op === 'kitchen') {   // Jordan's tap: the note becomes an idea; the autopilot builds it on the Google plan, merges still need his yes
    const note = leadLoad().notes.find((x) => x.id === id);   // the 90 s ideas call runs outside the lock; the mark lands on a fresh re-read
    if (!note || note.status !== 'open') return { ok: false, error: 'that note is not open' };
    const title = note.text.split(/[.\n!?]/)[0].slice(0, 70).trim();
    const r = await ideasAct({ op: 'add', title: title.length >= 4 ? title : 'Note from Jordan', goal: note.text.length >= 12 ? note.text : `${note.text} (from Jordan's note)`, why: "Jordan's note while Claude was away", size: 'M' });
    if (!r.ok) return r;
    return leadEdit((L) => { const n2 = L.notes.find((x) => x.id === id); if (!n2) return { ok: true, save: false, data: { idea: r.idea?.id || '' } }; n2.status = 'kitchen'; n2.idea = r.idea?.id || ''; return { ok: true, data: { idea: n2.idea } }; });
  }
  if (op === 'away') {   // Jordan says Claude is out (or back); "out" lasts until the weekly reset, or a day if that is unknown
    const v = leadView();
    return leadEdit((L) => { L.away = body.on ? { on: true, at: new Date().toISOString(), until: v.resetsAt || new Date(Date.now() + 86400000).toISOString() } : { on: false }; return { ok: true }; });
  }
  return { ok: false, error: 'unknown lead action' };
}
// ---- ZG-13: the Owner's taps on the World view (public/lobe.js) ----
// The Board READS the Charter file, the lobe's proposals.jsonl and its own pass-actions.jsonl (files only, memoized by sigOf; no
// child process, no database: taste weights live in the lobe's database, so the Board shows the Owner's own taps, not the weights).
// It WRITES only on an Owner tap (POST /api/lobe, the same auth, origin check and JSON body cap as approvals): one line in
// pass-actions.jsonl in zeitgeistd actions.tap_line()'s shape {ts, op, ok: true, who, ...fields}, and for a Charter Save, CHARTER.md
// itself (temp + rename) followed by its `charter-locked` line with the sha256 of the bytes written. The lobe applies taps on its
// next run (ZG-12 actions.py); nothing here moves a weight or imports a Charter, and nothing writes without a tap.
const TASTE_OPS = ['taste-up', 'taste-down', 'taste-mute', 'taste-focus'];
const CHARTER_MAX = 256 * 1024, CHARTER_DOMAINS = 12, CHARTER_TEXT = 300;
const PROPOSAL_DAYS = 7, PROPOSAL_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/, CHARTER_DOMAIN = /^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$/;
const actionsPath = path.join(root, 'pass-actions.jsonl');
const protectedPath = (p) => /[\\/](evie|evie_admin|life_admin|finances)([\\/]|$)/i.test(p);   // handoff.ps1's protected list, as lobeRead
function lobeHome() { return path.dirname(lobeFile()); }
// the Owner's Charter: ZEITGEISTD_CHARTER, else the Office's projects\zeitgeistd\CHARTER.md (the file zeitgeistd's charter.path names)
function charterFile() {
  const e = String(process.env.ZEITGEISTD_CHARTER || '').trim();
  return path.resolve(e || path.join(process.env.USERPROFILE || process.env.HOME || '', 'gemini-brain', 'projects', 'zeitgeistd', 'CHARTER.md'));
}
// one line of free text from the phone: control characters and line breaks out, spaces collapsed, at most max characters
const oneLine = (v, max) => (typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '');
// zeitgeistd taste.normalize_key: trimmed, spaces collapsed, lower case, 1..120 characters
const tasteKey = (v) => { const k = oneLine(v, 400).toLowerCase(); return k && k.length <= 120 ? k : ''; };
// CHARTER.md in zeitgeistd charter.py parse()'s format: {missionOrder, domains: [{name, objective, hardConstraint, dependsOn[]}]} or {error}
function charterParse(text) {
  let mission = null, cur = null, inC = false; const domains = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (inC) { inC = !line.includes('-->'); continue; }
    if (line.startsWith('<!--')) { inC = !line.includes('-->'); continue; }
    if (!line) continue;
    if (line.startsWith('## ')) { const name = line.slice(3).trim(); if (!CHARTER_DOMAIN.test(name) || domains.some((d) => d.name.toLowerCase() === name.toLowerCase())) return { error: 'a domain name is not valid' }; cur = { name, objective: '', hardConstraint: '', dependsOn: [] }; domains.push(cur); continue; }
    const i = line.indexOf(':'), key = i < 0 ? '' : line.slice(0, i).trim().toLowerCase(), val = i < 0 ? '' : line.slice(i + 1).trim();
    if (!cur) { if (key === 'mission_order') mission = val || null; continue; }
    if (key === 'objective') cur.objective = val; else if (key === 'hard_constraint') cur.hardConstraint = val;
    else if (key === 'depends_on') cur.dependsOn = val.split(',').map((s) => s.trim()).filter(Boolean); else return { error: 'a line under a domain is not objective:, hard_constraint: or depends_on:' };
  }
  if (inC) return { error: 'an HTML comment is never closed' };
  if (!domains.length || domains.some((d) => !d.objective)) return { error: 'a domain has no objective, or there is none' };
  return { missionOrder: mission, domains };
}
// the Owner's taps, newest last, from the tail of pass-actions.jsonl (successful lines only; failed taps are logged ok: false)
function ownerTaps() {
  return memo('ownerTaps', sigOf(actionsPath), () => tailLines(actionsPath, 4000, 2 << 20).map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((e) => e && typeof e === 'object' && e.ok === true && typeof e.op === 'string'));
}
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
function charterView() {
  const p = charterFile();
  if (protectedPath(path.dirname(p))) return { state: 'refused', why: 'the Charter path is inside a protected path, so it was not read' };
  let st, buf; try { st = fs.statSync(p); if (st.isFile() && st.size <= CHARTER_MAX) buf = fs.readFileSync(p); } catch { return { state: 'none' }; }
  if (!st.isFile() || !buf) return { state: 'refused', why: st.isFile() ? `CHARTER.md is over ${CHARTER_MAX} bytes` : 'CHARTER.md is not a file' };
  const sha = sha256(buf), lock = ownerTaps().filter((e) => e.op === 'charter-locked' && /^[0-9a-f]{64}$/i.test(String(e.sha256 || ''))).pop() || null;
  const parsed = charterParse(buf.toString('utf8').replace(/^﻿/, ''));
  const state = parsed.error ? 'invalid' : !lock ? 'unlocked' : lock.sha256.toLowerCase() === sha ? 'locked' : 'changed';
  return { state, why: parsed.error || '', sha256: sha, lockedAt: lock?.ts || null, charter: parsed.error ? null : parsed };
}
// the lobe's proposals (<ZEITGEISTD_HOME>\proposals.jsonl), minus the ones an Owner decision tap answered and the ones over 7 days old
function proposalsView() {
  const p = path.join(lobeHome(), 'proposals.jsonl'); if (protectedPath(path.dirname(p))) return [];
  const answered = new Set(ownerTaps().filter((e) => e.op === 'decision' && typeof e.proposal === 'string').map((e) => e.proposal)), seen = new Set(), out = [];
  for (const l of tailLines(p, 400, 1 << 20)) {
    let x; try { x = JSON.parse(l); } catch { continue; }
    if (!x || typeof x !== 'object' || !PROPOSAL_ID.test(String(x.id || '')) || !TASTE_OPS.includes(x.op) || !tasteKey(x.key) || answered.has(x.id) || seen.has(x.id)) continue;
    const t = Date.parse(x.ts || ''); if (Number.isFinite(t) && Date.now() - t > PROPOSAL_DAYS * 86400000) continue;
    seen.add(x.id); out.push({ id: x.id, op: x.op, key: tasteKey(x.key), by: oneLine(x.by, 40) || null, why: oneLine(x.why, 200) || null, ts: Number.isFinite(t) ? new Date(t).toISOString() : null });
  }
  return out.slice(-20).reverse();
}
// the Owner's taste taps by key, newest first (what the Owner tapped; the lobe holds the weights)
function tasteView() {
  const by = new Map();
  for (const e of ownerTaps()) if (TASTE_OPS.includes(e.op) && tasteKey(e.key)) { const k = tasteKey(e.key), r = by.get(k) || { key: k, n: 0 }; by.delete(k); by.set(k, { ...r, n: r.n + 1, op: e.op, at: e.ts || null }); }
  return [...by.values()].reverse().slice(0, 12);
}
const lobeOwnerView = () => memo('lobeOwner', [sigOf(charterFile()), sigOf(actionsPath), sigOf(path.join(lobeHome(), 'proposals.jsonl')), sigOf(lobeFlagsFile()), sigOf(path.join(root, 'ledger.json')), sigOf(lobeFile()), trustSigs(), Math.floor(Date.now() / 3600000)].join('|'),
  () => ({ charter: charterView(), proposals: proposalsView(), taste: tasteView(), decide: decideView(), trust: trustView() }));   // decide: ZG-25; trust: ZG-40
// the morning brief's lobe line: counts from the frame (never its words), its age, and why it was skipped (null when fresh)
function lobeBrief() {
  const v = lobeView(), n = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);
  if (!v.ok) return { decisionsReady: null, calibrationQuestions: null, postMortemsDue: null, signals24h: null, csfAgeMin: null, skipped: v.why };
  const m = v.csf.meta && typeof v.csf.meta === 'object' ? v.csf.meta : {}, c = m.counts && typeof m.counts === 'object' ? m.counts : {};
  const times = [Date.parse(m.compiled_utc), m.last_sweep_utc == null ? NaN : Date.parse(m.last_sweep_utc)].filter(Number.isFinite);
  const age = times.length ? Math.max(0, Math.floor((Date.now() - Math.min(...times)) / 60000)) : null;
  const skipped = age === null ? 'the frame\'s times cannot be read' : age > 240 ? `the frame is stale (${age} min old, the limit is 240)` : m.state !== 'ok' ? 'no sweep yet' : null;
  // calibration questions come with ZG-27 (not in the frame yet): null, never a made-up zero
  return { decisionsReady: n(c.decisions_ready), calibrationQuestions: null, postMortemsDue: n(c.post_mortems_due), signals24h: n(c.world_signals_24h), csfAgeMin: age, skipped };
}
// ZG-17: sweeps and rem runs the lobe Step skipped in the last 24 h, by kind, from <lobe home>\yard-counts.json (kitchen/stations/lobe.ps1
// writes it). Numbers only: the file holds no reasons, and only the three fixed kinds are counted. No file or an unreadable one: null.
function lobeSkips() {
  let j = null; try { const p = path.join(lobeHome(), 'yard-counts.json'); if (fs.statSync(p).size <= 65536) j = JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '')); } catch { return null; }
  const out = { sweep: 0, rem: 0, ram: 0, ollama: 0, gpu: 0 }, cut = Date.now() - 86400000;
  for (const s of Array.isArray(j?.skips) ? j.skips : []) if (s && ['sweep', 'rem'].includes(s.cmd) && ['ram', 'ollama', 'gpu'].includes(s.kind) && Date.parse(s.at) >= cut) { out[s.cmd]++; out[s.kind]++; }
  return out;
}
// CHARTER.md text from the Owner's fields (charter.py's format). Refuses the EXAMPLE seed's own words: they are not the Owner's.
function charterText(body) {
  const list = Array.isArray(body.domains) ? body.domains : [];
  if (!list.length || list.length > CHARTER_DOMAINS) return { error: `write 1 to ${CHARTER_DOMAINS} domains` };
  const doms = list.map((d) => ({ name: oneLine(d?.name, 64), objective: oneLine(d?.objective, CHARTER_TEXT), hard: oneLine(d?.hardConstraint, CHARTER_TEXT),
    deps: [...new Set(oneLine(Array.isArray(d?.dependsOn) ? d.dependsOn.join(',') : d?.dependsOn, CHARTER_TEXT).split(',').map((s) => s.trim()).filter(Boolean))] }));
  const mission = oneLine(body.missionOrder, CHARTER_TEXT);
  if (doms.some((d) => !CHARTER_DOMAIN.test(d.name))) return { error: 'a domain name must be letters, digits, space, _ or - (up to 64)' };
  if (new Set(doms.map((d) => d.name.toLowerCase())).size !== doms.length) return { error: 'two domains have the same name' };
  if (doms.some((d) => !d.objective)) return { error: 'every domain needs an objective' };
  if (doms.some((d) => d.deps.some((x) => !CHARTER_DOMAIN.test(x)))) return { error: 'depends on: domain names separated by commas' };
  if ([mission, ...doms.flatMap((d) => [d.name, d.objective, d.hard])].some((t) => /^EXAMPLE\b/i.test(t))) return { error: 'that is the EXAMPLE seed\'s wording; write your own' };
  const text = '# Normative Charter\n\n<!-- Written and locked by the Owner on the Board (World tab). A hand edit breaks the lock: Save and lock again on the Board. -->\n\n'
    + (mission ? `mission_order: ${mission}\n\n` : '') + doms.map((d) => `## ${d.name}\nobjective: ${d.objective}\n` + (d.hard ? `hard_constraint: ${d.hard}\n` : '') + `depends_on: ${d.deps.join(', ')}\n`).join('\n');
  return { text };
}
const tapSeen = new Map();   // a double tap (two phones, a slow network) within 3 s writes one line, not two
function tapAppend(who, op, fields) {
  const line = { ts: new Date().toISOString(), op, ok: true, who, ...fields }, k = JSON.stringify([who, op, fields]);
  for (const [x, t] of tapSeen) if (Date.now() - t > 3000) tapSeen.delete(x);
  if (tapSeen.has(k)) return { ok: true, duplicate: true };
  fs.appendFileSync(actionsPath, JSON.stringify(line) + '\n'); tapSeen.set(k, Date.now()); return { ok: true, data: line };
}
function lobeAct(req, body) {
  const op = String(body.op || ''), who = tailscaleUser(req) || 'key';
  if (TASTE_OPS.includes(op)) {
    const key = tasteKey(body.key); if (!key) return { ok: false, error: 'name a keyword or source (1 to 120 characters)' };
    const f = { key };
    if (op === 'taste-focus' && body.weight !== undefined) { const w = Number(body.weight); if (!(w >= 0.1 && w <= 3)) return { ok: false, error: 'a focus weight is 0.1 to 3.0' }; f.weight = w; }
    return tapAppend(who, op, f);
  }
  if (op === 'decision' && body.decision !== undefined) return decideAct(who, body);   // ZG-25: a decision node, not a proposal
  if (op === 'postmortem') return postmortemAct(who, body);
  if (op === 'decision' && body.signoff !== undefined) return signoffAct(who, body);   // ZG-40: a Brier Sign-off (claims.py), not a proposal
  if (op === 'decision') {
    const id = String(body.proposal || ''), choice = String(body.choice || '');
    if (!['apply', 'drop'].includes(choice)) return { ok: false, error: 'choose Apply or Drop' };
    if (!PROPOSAL_ID.test(id) || !proposalsView().some((x) => x.id === id)) return { ok: false, error: 'that proposal is not waiting any more' };
    return tapAppend(who, 'decision', { proposal: id, choice });
  }
  if (op === 'charter-save') {
    const p = charterFile(); if (protectedPath(path.dirname(p))) return { ok: false, error: 'the Charter path is inside a protected path; nothing was saved' };
    const t = charterText(body); if (t.error) return { ok: false, error: t.error };
    const buf = Buffer.from(t.text, 'utf8'), tmp = `${p}.tmp-${process.pid}`;
    fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(tmp, buf); fs.renameSync(tmp, p);
    return tapAppend(who, 'charter-locked', { sha256: sha256(buf), by: 'Owner' });
  }
  return { ok: false, error: 'unknown World action' };
}
// ---- ZG-25: the decision and post-mortem cards (public/lobe.js decideCard) ----
// READS the lobe's <lobe home>\flags.json (zeitgeistd decisions.py `run` writes it whole), the frame's A / B words (csf unlocked_choices, the top 3),
// the Ledger's post-mortem proof (ledger.json flags 'post-mortem-due', kitchen/ledger.ps1) and the Owner's own taps: files only, memoized by sigOf;
// no database, no child process. WRITES only on an Owner tap, through lobeAct (POST /api/lobe, the approvals' auth): one `decision` {decision,
// choice} or `postmortem` {decision, choice, day} line in pass-actions.jsonl, which decisions.py checks again before it applies it. A node that is
// not in flags.json, or that the Owner already answered since the lobe's last run, is refused. Nothing here chooses, and nothing writes on its own.
const DECIDE_CHOICES = ['A', 'B', 'neither', 'ask-more'], PM_CHOICES = ['held', 'didnt', 'unknown'], DECISION_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/, FLAGS_MAX = 1 << 20;
function lobeFlagsFile() { return path.join(lobeHome(), 'flags.json'); }
function lobeFlags() {
  const p = lobeFlagsFile();
  return memo('lobeFlags', p + '|' + sigOf(p), () => {
    if (protectedPath(path.dirname(p))) return { ok: false, why: 'the lobe home is inside a protected path, so it was not read' };
    let st, raw; try { st = fs.statSync(p); if (st.isFile() && st.size <= FLAGS_MAX) raw = fs.readFileSync(p, 'utf8'); } catch { return { ok: false, why: 'no flags.json yet: the lobe writes it on its decisions run (ZG-24)' }; }
    if (!st.isFile()) return { ok: false, why: 'flags.json is not a file' };
    if (raw === undefined) return { ok: false, why: 'flags.json is over 1 MB' };
    let f = null; try { f = JSON.parse(raw.replace(/^﻿/, '')); } catch {}
    if (!f || typeof f !== 'object' || !Array.isArray(f.decisionReady) || !Array.isArray(f.postMortemDue)) return { ok: false, why: 'flags.json is not the lobe\'s (no decisionReady or postMortemDue list)' };
    const iso = (v) => { const t = Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; };
    const ready = f.decisionReady.filter((d) => d && DECISION_ID.test(String(d.id || ''))).slice(0, 50)
      .map((d) => ({ id: d.id, loop: DECISION_ID.test(String(d.loop || '')) ? d.loop : null, question: oneLine(d.question, 200) || null, readyAt: iso(d.ready_at) }));
    const due = f.postMortemDue.filter((d) => d && DECISION_ID.test(String(d.id || '')) && [30, 60, 90].includes(d.day)).slice(0, 50)
      .map((d) => ({ id: d.id, day: d.day, dueAt: iso(d.due_at), expiresAt: iso(d.expires_at), choice: oneLine(d.choice, 20) || null }));
    return { ok: true, updated: iso(f.updated), ready, due };
  });
}
// the frame's "<id>: A <steelman> | B <steelman>" lines (csf.py unlocked_choices, the top 3) by id
function frameChoices() {
  const v = lobeView(), out = new Map(); if (!v.ok) return out;
  const s5 = v.csf['5_decision_ready_nodes'], list = s5 && Array.isArray(s5.unlocked_choices) ? s5.unlocked_choices : [];
  for (const e of list) { const t = String(e ?? ''), i = t.indexOf(': '), m = i > 0 ? /^A (.*) \| B (.*)$/.exec(t.slice(i + 2)) : null; if (m) out.set(t.slice(0, i), { a: m[1], b: m[2] }); }
  return out;
}
// the Ledger's proof per post-mortem (kitchen/ledger.ps1 flags 'post-mortem-due': still on main, undone, replaced by Jnn, none or unknown)
function ledgerProofs() {
  const l = readJson(path.join(root, 'ledger.json')), out = new Map();
  for (const f of (Array.isArray(l?.flags) ? l.flags : [])) if (f && f.rule === 'post-mortem-due' && DECISION_ID.test(String(f.id || ''))) out.set(f.id, { kind: oneLine(f.proofKind, 20) || 'unknown', say: oneLine(f.proof, 200) || 'no proof given' });
  return { built: !!l, by: out };
}
// the Owner's tap on a node since the lobe's last run (flags.json `updated`): a tap the lobe already handled and refused leaves the node waiting, so it can be tapped again
function tapFor(op, id, since, day) {
  const from = Date.parse(since || '') || 0;
  return ownerTaps().filter((e) => e.op === op && e.decision === id && (day === undefined || e.day === day) && Date.parse(e.ts) > from).pop() || null;
}
function decideView() {
  const f = lobeFlags(); if (!f.ok) return { ok: false, why: f.why, ready: [], due: [] };
  const ch = frameChoices(), lp = ledgerProofs();
  const ready = f.ready.map((d) => { const t = tapFor('decision', d.id, f.updated); return { ...d, a: ch.get(d.id)?.a ?? null, b: ch.get(d.id)?.b ?? null, answered: t ? { choice: t.choice, at: t.ts } : null }; });
  const due = f.due.map((d) => { const t = tapFor('postmortem', d.id, f.updated, d.day);
    return { ...d, proof: lp.by.get(d.id) || { kind: 'unknown', say: lp.built ? 'the Ledger has not checked it yet' : 'the Ledger has not been built yet' }, answered: t ? { choice: t.choice, at: t.ts } : null }; });
  return { ok: true, updated: f.updated, ready, due };
}
function decideAct(who, body) {
  const id = String(body.decision || ''), choice = String(body.choice || '');
  if (!DECIDE_CHOICES.includes(choice)) return { ok: false, error: 'choose A, B, Neither or Ask more' };
  const f = lobeFlags(); if (!f.ok) return { ok: false, error: 'the lobe\'s decisions cannot be read: ' + f.why };
  if (!DECISION_ID.test(id) || !f.ready.some((d) => d.id === id)) return { ok: false, error: 'that decision is not waiting for you' };
  if (tapFor('decision', id, f.updated)) return { ok: false, error: 'you already answered it; the lobe records it on its next run' };
  return tapAppend(who, 'decision', { decision: id, choice });
}
function postmortemAct(who, body) {
  const id = String(body.decision || ''), choice = String(body.choice || ''), day = Number(body.day);
  if (!PM_CHOICES.includes(choice)) return { ok: false, error: 'choose Held up, Didn\'t or Unknown' };
  const f = lobeFlags(); if (!f.ok) return { ok: false, error: 'the lobe\'s post-mortems cannot be read: ' + f.why };
  const d = DECISION_ID.test(id) ? f.due.find((x) => x.id === id) : null;
  if (!d) return { ok: false, error: 'no post-mortem is due for that decision' };
  if (d.day !== day) return { ok: false, error: `the check due is day ${d.day}` };
  if (tapFor('postmortem', id, f.updated, day)) return { ok: false, error: 'you already answered that check; the lobe records it on its next run' };
  return tapAppend(who, 'postmortem', { decision: id, choice, day });
}
// ---- ZG-30: the glass box (public/lobe.js glassHtml, app.js Activity) ----
// The lobe's events file (<lobe home>\events.jsonl, zeitgeistd telemetry.py, ZG-29), its heartbeat (config heartbeat_path, else
// <lobe home>\heartbeat.json) and its config.json are read as FILES: never the database, never a child process. Every events line is
// cleaned again here (counts, ids and kinds only: the lobe already drops text, and this is the second lock). The file is read once, then
// only its new bytes. A shorter file was rotated: it is read again, and a line the phones were already sent (same type, id and time)
// is not sent twice (lobeSent). A missing or unreadable file is { ok: false, why } in fixed words: "unknown", never empty or healthy.
const LOBE_ID = /^[A-Za-z0-9_.:#-]{1,80}$/, LOBE_TYPE = /^[A-Z][A-Z0-9_]{0,39}$/, LOBE_KEY = /^[a-z0-9_]{1,40}(\.[a-z0-9_]{1,40})?$/;
const LOBE_REASON = /^[A-Za-z0-9 _.,:%()<>=+-]{1,80}$/;   // telemetry.py REASON_RE: a SKIP reason the station wrote in plain words
const LOBE_KIND_KEYS = new Set(['rule', 'stage', 'op', 'label', 'choice', 'action', 'kind', 'run', 'status', 'folded_into', 'tap', 'proposal', 'sha256', 'rules', 'for']);   // telemetry.py KIND_KEYS
const LOBE_RING = 400, LOBE_FIRST_READ = 4 << 20;   // lines kept for the phones; the first read takes the newest 4 MiB (telemetry.max_bytes)
const BAND_WORD = { 1: 'endogenous', 2: 'fringe', 3: 'builder', 4: 'hard reality', 5: 'mainstream' };   // zeitgeistd health.py BAND_NAMES
const lobeId = (v) => (typeof v === 'string' && LOBE_ID.test(v) ? v : null);
const lobeNum = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
function lobeClean(o) {
  if (!o || typeof o !== 'object' || Array.isArray(o)) return null;
  const t = Date.parse(o.ts);
  if (!Number.isFinite(t) || !Number.isInteger(o.id) || o.id < 0 || typeof o.type !== 'string' || !LOBE_TYPE.test(o.type)) return null;
  const detail = {}, skip = o.type === 'SKIP';
  if (o.detail && typeof o.detail === 'object' && !Array.isArray(o.detail)) {
    for (const [k, v] of Object.entries(o.detail)) {
      if (Object.keys(detail).length >= 24 || !LOBE_KEY.test(k)) continue;
      if (typeof v === 'boolean' || lobeNum(v) !== null) detail[k] = v;
      else if (typeof v === 'string' && skip && k === 'reason') detail[k] = LOBE_REASON.test(v) ? v : true;
      else if (typeof v === 'string' && LOBE_KIND_KEYS.has(k.split('.').pop()) && LOBE_ID.test(v)) detail[k] = v;
    }
  }
  const layer = lobeId(o.layer);
  return { src: 'lobe', ts: new Date(t).toISOString(), type: o.type, id: o.id, layer, kind: lobeId(o.kind), target: layer === 'taste' ? null : lobeId(o.target),
    latency_ms: Number.isInteger(o.latency_ms) ? o.latency_ms : null, detail };
}
const lobeKey = (e) => `${e.type}:${e.id}:${e.ts}`;
const dayStart = (now = Date.now()) => { const d = new Date(now); d.setHours(0, 0, 0, 0); return d.getTime(); };   // gate.py day_start_utc: local midnight
const lobeDay = () => ({ from: dayStart(), sweeps: 0, skips: 0, skipWhy: {}, tokens: 0, drops: 0, passes: 0 });
const lobeIx = { p: '', sig: '', off: 0, seq: 0, ring: [], first: null, lastSweep: null, trips: [], today: lobeDay(), why: 'not read yet', reads: 0 };
function lobeIxReset() { Object.assign(lobeIx, { off: 0, ring: [], first: null, lastSweep: null, trips: [], today: lobeDay() }); }
function lobeIxAdd(e) {
  const t = Date.parse(e.ts), d = lobeIx.today;
  if (lobeIx.first === null || t < lobeIx.first) lobeIx.first = t;
  if (e.type === 'SWEEP_DONE') { if (lobeIx.lastSweep === null || t > lobeIx.lastSweep) lobeIx.lastSweep = t; if (t >= d.from) d.sweeps++; }
  if (e.type === 'BREAKER_TRIP' && Date.now() - t < 86400000) { lobeIx.trips.push({ id: e.target, ts: e.ts }); if (lobeIx.trips.length > 20) lobeIx.trips.shift(); }
  if (t >= d.from) {
    if (e.type === 'SKIP') { d.skips++; const w = typeof e.detail.reason === 'string' ? e.detail.reason : 'no plain reason'; d.skipWhy[w] = (d.skipWhy[w] || 0) + 1; }
    if (e.type === 'GATE_DROP') d.drops++;
    if (e.type === 'GATE_PASS') d.passes++;
    if (e.kind === 'CALL' && (e.layer === 'L2_STAGE2' || e.layer === 'L2_STAGE3')) d.tokens += lobeNum(e.detail.tokens) || 0;   // gate.py tokens_today's rows
  }
  lobeIx.ring.push({ seq: ++lobeIx.seq, e }); if (lobeIx.ring.length > LOBE_RING) lobeIx.ring.shift();
}
const readWhy = (e) => `the events file cannot be read (${String(e?.code || 'error').slice(0, 20)})`;
function lobeEventsIndex() {
  const p = path.join(lobeHome(), 'events.jsonl');
  if (p !== lobeIx.p) { lobeIx.p = p; lobeIx.sig = ''; lobeIxReset(); }
  if (lobeIx.today.from !== dayStart()) lobeIx.today = lobeDay();   // a new day counts from its midnight; earlier lines are not today's
  if (protectedPath(path.dirname(p))) { lobeIxReset(); lobeIx.why = 'the lobe home is inside a protected path, so it was not read'; return lobeIx; }
  const sig = sigOf(p);
  if (sig === lobeIx.sig && lobeIx.why === null) return lobeIx;
  let st; try { st = fs.statSync(p); } catch (e) {
    lobeIxReset(); lobeIx.sig = sig;
    lobeIx.why = e.code === 'ENOENT' ? 'no events file yet: the lobe writes events.jsonl on its first write to its memory (ZG-29)' : readWhy(e);
    return lobeIx;
  }
  if (!st.isFile()) { lobeIxReset(); lobeIx.sig = sig; lobeIx.why = 'events.jsonl is not a file'; return lobeIx; }
  if (st.size < lobeIx.off || lobeIx.why !== null) lobeIxReset();   // rotated (telemetry.py rewrites it smaller) or unreadable before: read it again; lobeSent keeps repeats off the phones
  let skipPart = false;
  if (lobeIx.off === 0 && st.size > LOBE_FIRST_READ) { lobeIx.off = st.size - LOBE_FIRST_READ; skipPart = true; }
  try {
    const fd = fs.openSync(p, 'r'); lobeIx.reads++;
    try {
      while (lobeIx.off < st.size) {   // 1 MiB at a time; only whole lines (a line still being written is read next time)
        const len = Math.min(st.size - lobeIx.off, 1 << 20), buf = Buffer.alloc(len); fs.readSync(fd, buf, 0, len, lobeIx.off);
        let start = 0;
        if (skipPart) { start = buf.indexOf(10) + 1; skipPart = false; if (start <= 0) { lobeIx.off += len; continue; } }
        const end = buf.lastIndexOf(10);
        if (end < start) { if (len === 1 << 20) { lobeIx.off += len; continue; } break; }   // a 1 MiB line is skipped, never looped on
        for (const l of buf.subarray(start, end).toString('utf8').split(/\r?\n/)) { if (!l) continue; let o; try { o = JSON.parse(l); } catch { continue; } const e = lobeClean(o); if (e) lobeIxAdd(e); }
        lobeIx.off += end + 1;
      }
    } finally { fs.closeSync(fd); }
  } catch (e) { lobeIxReset(); lobeIx.sig = ''; lobeIx.why = readWhy(e); return lobeIx; }
  lobeIx.why = null; lobeIx.sig = sig; return lobeIx;
}
// the newest n cleaned lobe lines, or [] (the Activity feed's history: /api/events and a new stream)
const lobeEventsTail = (n) => { const ix = lobeEventsIndex(); return ix.why === null ? ix.ring.slice(-n).map((x) => x.e) : []; };
// the live pass: lines not yet sent to the phones, each once (by type, id and time) even when a rotation reads them again
const lobeSent = new Set(); let lobeLiveSeq = -1;
function lobeLive() {
  const ix = lobeEventsIndex(), fresh = lobeLiveSeq < 0; const out = [];
  for (const x of ix.ring) {
    if (x.seq <= lobeLiveSeq) continue; const k = lobeKey(x.e); if (lobeSent.has(k)) continue;
    lobeSent.add(k); if (!fresh) out.push(x.e); if (lobeSent.size > 20000) lobeSent.delete(lobeSent.values().next().value);
  }
  lobeLiveSeq = ix.seq; return out;   // the first pass only marks what is there: history goes out in /api/stream's first message
}
// the lobe's config.json (flat keys, settings.py) and its heartbeat (health.py beat): small files, read when they change
function lobeConfig() {
  const p = path.join(lobeHome(), 'config.json');
  return memo('lobeCfg', p + '|' + sigOf(p), () => {
    let raw; try { raw = fs.readFileSync(p, 'utf8'); } catch (e) { return { ok: e.code === 'ENOENT', data: {}, why: e.code === 'ENOENT' ? null : 'config.json cannot be read' }; }
    try { const d = JSON.parse(raw.replace(/^﻿/, '')); return d && typeof d === 'object' && !Array.isArray(d) ? { ok: true, data: d, why: null } : { ok: false, data: {}, why: 'config.json is not a JSON object' }; } catch { return { ok: false, data: {}, why: 'config.json is not valid JSON' }; }
  });
}
function heartbeatFile(cfg) {
  const v = cfg.data.heartbeat_path;
  if (v === undefined || v === null) return path.join(lobeHome(), 'heartbeat.json');
  if (typeof v !== 'string' || !/\.json$/i.test(v.trim())) return null;
  let h = v.trim(); if (/^~(?=$|[\\/])/.test(h)) h = (process.env.USERPROFILE || process.env.HOME || '') + h.slice(1);
  return path.isAbsolute(h) ? h : path.join(lobeHome(), h);
}
function lobeHeartbeat(cfg) {
  const p = heartbeatFile(cfg);
  if (!p) return { ok: false, why: 'config heartbeat_path is not a path ending in .json' };
  if (protectedPath(path.dirname(p))) return { ok: false, why: 'the heartbeat is inside a protected path, so it was not read' };
  return memo('lobeHb', p + '|' + sigOf(p), () => {
    let st, raw; try { st = fs.statSync(p); if (st.isFile() && st.size <= 65536) raw = fs.readFileSync(p, 'utf8'); } catch (e) { return { ok: false, why: e.code === 'ENOENT' ? 'no heartbeat yet: no sweep, rem or csf run has finished' : 'the heartbeat cannot be read' }; }
    if (raw === undefined) return { ok: false, why: 'the heartbeat is not a file under 64 KB' };
    let h = null; try { h = JSON.parse(raw.replace(/^﻿/, '')); } catch {}
    if (!h || typeof h !== 'object' || Array.isArray(h) || !Number.isFinite(Date.parse(h.lastRun))) return { ok: false, why: 'the heartbeat is not the lobe\'s (no lastRun)' };
    const bands = (Array.isArray(h.bands) ? h.bands : []).filter((b) => b && Number.isInteger(b.band) && BAND_WORD[b.band]).map((b) => ({ band: b.band, name: BAND_WORD[b.band], sources: lobeNum(b.sources), items24h: lobeNum(b.items24h), newestUtc: Number.isFinite(Date.parse(b.newestUtc)) ? b.newestUtc : null }));
    // counts and times only: the heartbeat's error text and skip reasons stay here (their count goes out)
    return { ok: true, why: null, lastRun: h.lastRun, everyMin: Number.isInteger(h.everyMin) && h.everyMin > 0 ? h.everyMin : null, found: lobeNum(h.found), failing: !!h.error,
      bands, breakersOpen: lobeNum(h.breakersOpen), dlq: lobeNum(h.dlq), csfAgeMin: lobeNum(h.csfAgeMin), skipped: Array.isArray(h.skipped) ? h.skipped.length : 0,
      queue: h.queue && typeof h.queue === 'object' ? lobeNum(h.queue.depth) : null };
  });
}
// the glass box: what the health card shows. No database: the queue depth comes only from a heartbeat that carries it
function lobeGlassView() {
  const ix = lobeEventsIndex(), cfg = lobeConfig(), hb = lobeHeartbeat(cfg), d = ix.today;
  const ceilV = cfg.data['gate.token_ceiling'], ceiling = ceilV === undefined ? 150000 : Number.isInteger(ceilV) && ceilV > 0 ? ceilV : null;   // gate.py SETTINGS default
  const needV = cfg.data.ram_min_mb, needMb = needV === undefined ? 2500 : lobeNum(needV);   // governor.py ram_min_mb; lobe.ps1's RAM gate
  const evOk = ix.why === null;
  return {
    events: { ok: evOk, why: ix.why, oldest: evOk && ix.first !== null ? new Date(ix.first).toISOString() : null },
    heartbeat: hb, config: { ok: cfg.ok, why: cfg.why },
    today: evOk ? { sweeps: d.sweeps, skips: d.skips, skipWhy: Object.entries(d.skipWhy).sort((a, b) => b[1] - a[1]).slice(0, 6), tokens: d.tokens, drops: d.drops, passes: d.passes,
      partial: ix.first === null || ix.first > d.from } : null,
    lastSweepUtc: evOk && ix.lastSweep !== null ? new Date(ix.lastSweep).toISOString() : null, trips: evOk ? ix.trips.slice(-6) : [],
    queue: hb.ok ? hb.queue : null, queueWhy: hb.ok && hb.queue !== null ? null : hb.ok ? 'the heartbeat does not carry it yet (only health --json prints it, and the Board never opens the lobe\'s database)' : hb.why,
    ceiling, ceilingWhy: ceiling === null ? 'config gate.token_ceiling is not a whole number' : null,
    ram: { freeMb: Math.round(os.freemem() / 1048576 / 50) * 50, needMb },
  };
}
const lobeGlass = () => { const ix = lobeEventsIndex(), hp = heartbeatFile(lobeConfig()) || '-'; return memo('lobeGlass', [ix.p, ix.sig, ix.why, ix.seq, sigOf(path.join(lobeHome(), 'config.json')), hp, sigOf(hp), Math.floor(Date.now() / 60000)].join('|'), lobeGlassView); };
// ---- ZG-40: the Trust card (public/lobe.js trustCard, from state.lobeOwner.trust): who has earned trust, by numbers ----
// READS four files, memoized by sigOf; never the lobe's database, never a child process: <lobe home>\trust.json (zeitgeistd trust.py, ZG-39: the
// Foreman, world, crews and builders families), <kitchen>\scoreboard.jsonl's `brier` (kitchen/scoreboard.ps1 -Record, ZG-22: per crew model, the
// trend line), <kitchen>\watch\memory.json's unproven count (memory-truth) and <lobe home>\signoffs.jsonl (zeitgeistd claims.py, ZG-20: Brier changes
// over the threshold). Only numbers, ids, kinds and fixed words leave: no claim text, no statement, and a source's name only when the lobe marks the
// source P0. A missing or broken file is { ok: false, why } in fixed words, so the card says "unknown" with the reason, never a made-up number.
// WRITES only on an Owner tap, through lobeAct (POST /api/lobe): one `decision` {signoff, choice} line that claims.py applies on its next run.
const TRUST_MAX = 1 << 20, TRUST_BOARD_MAX = 4 << 20, SIGNOFF_ID = /^B-[0-9a-f]{16}$/, BRIER_STATUS = ['VERIFIED', 'REFUTED', 'GOALPOST_MOVED'], TREND_MS = 7 * 86400000;
const TRUST_STATUS = /^[a-z][a-z ]{0,39}$/, CREW_KEY = /^[A-Za-z0-9_.:#/+-]{1,80}$/;
const unit = (v) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1 ? Math.round(v * 10000) / 10000 : null);
const count = (v) => (Number.isInteger(v) && v >= 0 ? v : null);
const trustIso = (v) => { const t = typeof v === 'string' ? Date.parse(v) : NaN; return Number.isFinite(t) ? new Date(t).toISOString() : null; };
const trustFile = () => path.join(lobeHome(), 'trust.json'), boardFile = () => path.join(root, 'scoreboard.jsonl');
const watchFile = () => path.join(root, 'watch', 'memory.json'), signoffFile = () => path.join(lobeHome(), 'signoffs.jsonl');
function trustSigs() { return [trustFile(), boardFile(), watchFile(), signoffFile()].map((p) => p + '|' + sigOf(p)).join('|'); }
// one small file as text, or why not (missing = `none`, the caller's words)
function trustText(p, name, none, max = TRUST_MAX) {
  if (protectedPath(path.dirname(p))) return { ok: false, why: `${name} is inside a protected path, so it was not read` };
  let st, raw; try { st = fs.statSync(p); if (st.isFile() && st.size <= max) raw = fs.readFileSync(p, 'utf8'); } catch { return { ok: false, why: `no ${name} yet: ${none}` }; }
  if (!st.isFile()) return { ok: false, why: `${name} is not a file` };
  if (raw === undefined) return { ok: false, why: `${name} is over ${max >> 20} MB` };
  return { ok: true, raw: raw.replace(/^﻿/, ''), mtimeMs: st.mtimeMs };
}
const trustJson = (r) => { try { return JSON.parse(r.raw); } catch { return null; } };
// trust.json: each family's status (fixed words), Brier (the loss, 0 = always right) and how many resolved claims it is over
function trustFamilies() {
  const r = trustText(trustFile(), 'trust.json', 'the lobe writes it on its trust run (zeitgeistd trust run, ZG-39)'); if (!r.ok) return r;
  const d = trustJson(r), F = d && typeof d === 'object' && d.families && typeof d.families === 'object' && !Array.isArray(d.families) ? d.families : null;
  if (!F) return { ok: false, why: 'trust.json is not the lobe\'s (no families)' };
  const fam = (x) => (x && typeof x === 'object' ? { status: TRUST_STATUS.test(String(x.status || '')) ? x.status : 'not stated', brier: unit(x.brier), n: count(x.n) ?? 0 } : { status: 'not in trust.json', brier: null, n: 0 });
  const members = (m) => (m && typeof m === 'object' && !Array.isArray(m) ? Object.entries(m).filter(([k, v]) => CREW_KEY.test(k) && v && typeof v === 'object' && unit(v.brier) !== null && count(v.n))
    .slice(0, 20).map(([k, v]) => ({ id: k, brier: unit(v.brier), n: v.n })) : []);
  const f = F.foreman && typeof F.foreman === 'object' ? F.foreman : {}, w = F.world && typeof F.world === 'object' ? F.world : {};
  // per-source scores: ZG-39 writes none (only the mean); a later trust.json that lists them ({id, brier | trust, n}) shows its top 5 by claims
  const sources = Array.isArray(w.sources) ? w.sources.filter((s) => s && typeof s === 'object' && LOBE_ID.test(String(s.id || '')) && (unit(s.brier) !== null || unit(s.trust) !== null))
    .map((s) => ({ id: s.id, brier: unit(s.brier) ?? unit(1 - s.trust), n: count(s.n) ?? 0 })).sort((a, b) => b.n - a.n || a.id.localeCompare(b.id)).slice(0, 5) : null;
  return { ok: true, compiledUtc: trustIso(d.compiled_utc), foreman: { ...fam(F.foreman), claims: count(f.claims), pending: count(f.pending) },
    world: { ...fam(F.world), sourcesScored: count(w.sources_scored), sourcesMeanTrust: unit(w.sources_mean_trust), sources },
    crews: { ...fam(F.crews), members: members(F.crews?.members) }, builders: { ...fam(F.builders), members: members(F.builders?.members) } };
}
// scoreboard.jsonl: the newest line's brier and the newest line at least 7 days older than it (the trend), per crew model
function trustBoard() {
  const p = boardFile(); if (sigOf(p) === '-') return { ok: false, why: 'no scoreboard.jsonl yet: the Yard writes it each morning (scoreboard.ps1 -Record)' };
  const role = (x) => ({ value: unit(x?.value), claims: count(x?.claims) ?? 0 });
  const clean = (b) => ({ value: unit(b.value), claims: count(b.claims) ?? 0, pending: count(b.pending), inspector: role(b.inspector), builder: role(b.builder), missing: oneLine(b.missing, 200) || null,
    models: b.models && typeof b.models === 'object' && !Array.isArray(b.models) ? Object.entries(b.models).filter(([k, v]) => CREW_KEY.test(k) && v && typeof v === 'object').slice(0, 30).map(([k, v]) => ({ id: k, ...role(v) })) : [] });
  const rows = [];
  for (const l of tailLines(p, 400, TRUST_BOARD_MAX)) { let o; try { o = JSON.parse(l); } catch { continue; } const t = Date.parse(o?.at); if (Number.isFinite(t) && o.brier && typeof o.brier === 'object' && !Array.isArray(o.brier)) rows.push({ t, b: o.brier }); }
  if (!rows.length) return { ok: false, why: 'scoreboard.jsonl has no Brier yet: its lines from before ZG-22 carry none, and the next morning\'s line will' };
  rows.sort((a, b) => a.t - b.t);
  const last = rows[rows.length - 1], old = [...rows].reverse().find((x) => x.t <= last.t - TREND_MS) || null;
  return { ok: true, at: new Date(last.t).toISOString(), firstAt: new Date(rows[0].t).toISOString(), now: clean(last.b), weekAgo: old ? { at: new Date(old.t).toISOString(), ...clean(old.b) } : null };
}
// watch\memory.json: memory-truth's count of memory bullets with no proof (`unproven`, ZG-38; else its older `warn`). Its warning lines are never sent.
function trustWatch() {
  const r = trustText(watchFile(), 'watch\\memory.json', 'memory-truth writes it every hour'); if (!r.ok) return r;
  const d = trustJson(r), u = count(d?.unproven), w = count(d?.warn);
  if (u === null && w === null) return { ok: false, why: 'watch\\memory.json has no unproven or warn count' };
  return { ok: true, unproven: u ?? w, field: u !== null ? 'unproven' : 'warn', lastRun: trustIso(d.lastRun) };
}
// signoffs.jsonl: the pending Brier Sign-offs, and the Owner's tap on each since claims.py last wrote the file (a tap it refused leaves it waiting)
function trustSignoffs() {
  const r = trustText(signoffFile(), 'signoffs.jsonl', 'the lobe writes one when a source\'s trust would move more than it may move by itself (ZG-20)');
  if (!r.ok) return { ...r, pending: [] };
  const taps = ownerTaps().filter((e) => e.op === 'decision' && typeof e.signoff === 'string' && Date.parse(e.ts) > r.mtimeMs), out = [];
  for (const l of r.raw.split(/\r?\n/)) {
    let x; try { x = JSON.parse(l); } catch { continue; }
    if (!x || typeof x !== 'object' || !SIGNOFF_ID.test(String(x.id || '')) || x.kind !== 'brier' || x.state !== 'pending' || out.some((y) => y.id === x.id)) continue;
    const p0 = x.privacy === 'P0', t = taps.filter((e) => e.signoff === x.id).pop() || null, delta = typeof x.delta === 'number' && Math.abs(x.delta) <= 1 ? Math.round(x.delta * 10000) / 10000 : null;
    out.push({ id: x.id, privacy: /^P[0-2]$/.test(String(x.privacy || '')) ? x.privacy : null, source: p0 && LOBE_ID.test(String(x.source || '')) ? x.source : null, sourceName: p0 ? oneLine(x.source_name, 80) || null : null,
      status: BRIER_STATUS.includes(x.status) ? x.status : null, from: unit(x.from), to: unit(x.to), delta, created: trustIso(x.created), answered: t ? { choice: t.choice, at: t.ts } : null });
  }
  return { ok: true, pending: out.slice(-20) };
}
const trustView = () => memo('lobeTrust', [trustSigs(), sigOf(actionsPath), Math.floor(Date.now() / 3600000)].join('|'),
  () => ({ file: trustFamilies(), board: trustBoard(), watch: trustWatch(), signoffs: trustSignoffs() }));
function signoffAct(who, body) {
  const id = String(body.signoff || ''), choice = String(body.choice || '');
  if (!['apply', 'drop'].includes(choice)) return { ok: false, error: 'choose Apply or Drop' };
  const s = trustSignoffs(), x = SIGNOFF_ID.test(id) && s.ok ? s.pending.find((y) => y.id === id) : null;
  if (!x) return { ok: false, error: s.ok ? 'that Sign-off is not waiting any more' : 'the lobe\'s Sign-offs cannot be read: ' + s.why };
  if (x.answered) return { ok: false, error: 'you already answered it; the lobe applies it on its next run' };
  return tapAppend(who, 'decision', { signoff: id, choice });
}
// a push (counts only, with push on) the first time Claude goes away and when the week resets
let leadLast = null;
setInterval(() => {
  try {
    const m = leadView().mode; if (leadLast && m !== leadLast && (m === 'away' || leadLast === 'away')) push('INFO', m === 'away' ? 'Claude is resting until the weekly reset. The Yard keeps building. Open the Board.' : 'Claude is back. Open the Board.');
    leadLast = m;
  } catch (e) { console.error('lead:', e.message); }
}, 60000);

// the dead-supervisor alarm: the kitchen's own watchdog lives inside the tick, so when the scheduled task stops starting (a Store update
// moved pwsh, a reboot before sign-in) nothing in the kitchen notices. Chef does: no tick for 10+ minutes (and no PAUSED marker from Jordan)
// sends ONE generic push per stall (no content, no hostname); the mark is cleared when ticks resume, so the next stall is told again.
const STALL_SEC = 600; const stallMark = path.join(root, 'stall-sent.txt');
function checkStall() {
  const meta = readJson(path.join(root, 'supervisor.json')); if (!meta?.lastTick) return 'never ticked';
  const age = (Date.now() - new Date(meta.lastTick).getTime()) / 1000; const sent = fs.existsSync(stallMark);
  if (age <= STALL_SEC || fs.existsSync(path.join(root, 'PAUSED'))) { if (sent) try { fs.unlinkSync(stallMark); } catch {} return 'ok'; }
  if (sent) return 'told';
  fs.writeFileSync(stallMark, new Date().toISOString()); push('HIGH', 'The Yard stopped ticking. Open the Board.'); return 'sent';
}
setInterval(() => { try { checkStall(); } catch (e) { console.error('stall:', e.message); } }, Number(process.env.PASS_STALL_CHECK_MS) || 60000);   // tests check faster
setTimeout(() => { try { checkStall(); } catch (e) { console.error('stall:', e.message); } }, 5000).unref?.();

// once a day at 8:00 (and only with push on): a push with counts only
setInterval(() => {
  try {
    if (new Date().getHours() < 8 || !pushOn()) return;
    const mark = path.join(root, 'brief-sent.txt'); if ((() => { try { return fs.readFileSync(mark, 'utf8').trim(); } catch { return ''; } })() === today()) return;
    fs.writeFileSync(mark, today()); const b = brief();
    const bits = [b.packCount && `${b.packCount} pack${b.packCount > 1 ? 's' : ''} ready to review`, b.newRoleCount && `${b.newRoleCount} new role${b.newRoleCount > 1 ? 's' : ''}`, b.followUps.length && `${b.followUps.length} follow-up${b.followUps.length > 1 ? 's' : ''} due`,
      fs.existsSync(stallMark) && 'the Yard stopped ticking', b.needsYou.length && `${b.needsYou.length} waiting for your sign-off`, b.plated.length && `${b.plated.length} handed over overnight`, b.setAside.length && `${b.setAside.length} failed`].filter(Boolean);
    push('INFO', `Morning brief: ${bits.length ? bits.join(', ') : 'all quiet'}. Open the Board.`);
  } catch (e) { console.error('brief:', e.message); }
}, 60000);

// once a day at 8pm (and only with push on): how many changes merged on their own, a count only (no titles)
function pushAutoMerged(force = false) {
  if (!pushOn()) return { ok: false, error: 'push alerts are off' };
  if (!force && new Date().getHours() < 20) return { ok: true, data: 'not yet' };
  const mark = path.join(root, 'automerge-sent.txt');
  if (!force && (() => { try { return fs.readFileSync(mark, 'utf8').trim(); } catch { return ''; } })() === today()) return { ok: true, data: 'already sent' };
  const n = autoMergedToday().length; if (!n) return { ok: true, data: 'none' };
  fs.writeFileSync(mark, today()); push('INFO', `${n} change${n === 1 ? '' : 's'} merged on their own today`);
  return { ok: true, data: n };
}
setInterval(() => { try { pushAutoMerged(); } catch (e) { console.error('automerge push:', e.message); } }, 60000);

// ---- clients: income leads. The lead scout (recipe leadscout, public web search) finds people hiring for AI / automation work and the
// lead-pitch station has the PC's local model draft a pitch for each into <income>\leads.json. Jordan reads, edits and copies a pitch
// and sends it himself; Chef only stores his marks (sent / skipped / won). Nothing here contacts anyone.
// leads.json has two writers (this server and the station): every change holds leads.json.lock, re-reads, edits and writes (temp +
// rename). A leads.json that exists but can't be parsed is refused, never replaced (fail closed).
const incomeDir = path.resolve(process.env.PASS_INCOME_DIR || path.join(os.userInfo().homedir, 'gemini-brain', 'projects', 'income'));
const leadsPath = path.join(incomeDir, 'leads.json');
const LEAD_MARKS = ['new', 'sent', 'skipped', 'won'];
function clientsLoad() {
  let raw; try { raw = fs.readFileSync(leadsPath, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return { nextId: 1, items: [] }; throw new Error('leads.json could not be read'); }
  let d; try { d = JSON.parse(raw.replace(/^\uFEFF/, '')); } catch { d = null; }
  if (!d || typeof d !== 'object' || Array.isArray(d)) throw new Error('leads.json is not valid; nothing was saved');
  if (!Array.isArray(d.items)) d.items = d.items && typeof d.items === 'object' ? [d.items] : [];   // ConvertTo-Json writes a one-item list as an object
  return d;
}
function clientsNew() { try { return clientsLoad().items.filter((x) => x.status === 'new' && x.pitch).length; } catch { return 0; } }
function clientsView() {
  let d; try { d = clientsLoad(); } catch (e) { return { error: e.message }; }
  const scouting = loadJobs({ watched: true }).filter((j) => /^leadscout:/.test(String(j.name || '')) && ['pending', 'running'].includes(j.status)).length;
  // only http(s) links reach the page (the station keeps only those; this is the second lock on the door)
  const items = d.items.slice(-300).map((x) => ({ id: String(x.id || ''), title: String(x.title || ''), source: String(x.source || ''), link: /^https?:\/\//i.test(String(x.link || '')) ? String(x.link) : '',
    posted: String(x.posted || ''), budget: String(x.budget || ''), need: String(x.need || ''), pitch: String(x.pitch || ''), status: LEAD_MARKS.includes(x.status) ? x.status : 'new', added: x.added || '', updated: x.updated || '' }));
  return { items, scouting, offer: fs.existsSync(path.join(incomeDir, 'OFFER.md')) };
}
const clientsEdit = (fn) => withFileLock(leadsPath + '.lock', 'leads.json', () => {
  const d = clientsLoad(); const r = fn(d);
  if (r?.ok) { fs.mkdirSync(incomeDir, { recursive: true }); const tmp = `${leadsPath}.tmp-${process.pid}`; fs.writeFileSync(tmp, JSON.stringify({ ...d, updated: new Date().toISOString() }, null, 2)); fs.renameSync(tmp, leadsPath); }
  return r;
});
async function clientsAct(body) {
  const op = String(body.op || ''); const id = String(body.id || '');
  if (op === 'scout') return kicked(kitchen('cook', { recipe: 'leadscout', vars: {} }));   // one more search now, same as the nightly run
  if (!/^L\d{1,6}$/.test(id)) return { ok: false, error: 'bad lead id' };
  if (op === 'mark') {
    const status = String(body.status || ''); if (!LEAD_MARKS.includes(status)) return { ok: false, error: 'pick sent, skipped, won or new' };
    return clientsEdit((d) => { const x = d.items.find((i) => i.id === id); if (!x) return { ok: false, error: 'no such lead' }; x.status = status; x.updated = new Date().toISOString(); return { ok: true }; });
  }
  if (op === 'pitch') {   // Jordan's own edit of the draft
    const text = cleanStr(body.text, 3000); if (text.length < 10) return { ok: false, error: 'the pitch is too short' };
    return clientsEdit((d) => { const x = d.items.find((i) => i.id === id); if (!x) return { ok: false, error: 'no such lead' }; x.pitch = text; x.edited = true; x.updated = new Date().toISOString(); return { ok: true }; });
  }
  return { ok: false, error: 'unknown clients action' };
}

// ---- ideas: the kitchen's own to-do list (research teams, the coach and Jordan add; the autopilot builds; Jordan merges) ----
const ideasPs = path.join(kitchenDir, 'ideas.ps1');
// The Ledger tab: kitchen/ledger.ps1 writes ledger.json (every 5 minutes, from proof only); the watchers write watch\*.json.
// This server is a separate process from the tick, so it is also an independent watcher of the tick: a stale tick or a late
// heartbeat is reported here even when nothing inside the kitchen is running to notice.
function ledgerView() {
  const l = readJson(path.join(root, 'ledger.json'));
  const now = Date.now(), mins = (ts) => (ts ? Math.round((now - new Date(ts).getTime()) / 60000) : null);
  const watch = []; let wdir = [];
  try { wdir = fs.readdirSync(path.join(root, 'watch')).filter((f) => /^[\w-]+\.json$/.test(f)); } catch { }
  for (const f of wdir) {
    const h = readJson(path.join(root, 'watch', f));
    if (!h) { watch.push({ name: f.replace(/\.json$/, ''), late: true, say: 'heartbeat file damaged' }); continue; }
    const age = mins(h.lastRun), every = Math.max(1, Number(h.everyMin) || 60), late = age == null || age > Math.max(15, 2 * every);
    watch.push({ name: String(h.name || f), minutesAgo: age, everyMin: every, found: Number(h.found) || 0, late, whilePaused: h.whilePaused === true,
      problems: (h.problems || h.findings || []).slice(0, 20).map((p) => String(p.say || '')).filter(Boolean) });
  }
  const sup = readJson(path.join(root, 'supervisor.json')); const paused = fs.existsSync(path.join(root, 'PAUSED'));
  const tickMin = mins(sup?.lastTick);
  const alarms = [];
  if (!paused && (tickMin == null || tickMin > 15)) alarms.push(tickMin == null ? 'The Yard has no record of a tick.' : `The Yard has not ticked for ${tickMin} minutes.`);
  // TD-EH-26: while paused the paused Walkround (lastTickEnd) and the watchers marked whilePaused (the Watch, memory-truth) keep running, so
  // they still alarm when late; a pause is never read as a fault, and never hides one either
  const endMin = mins(sup?.lastTickEnd);
  if (paused && endMin != null && endMin > 15) alarms.push(`The Yard is paused, and its paused Walkround (it still minds running work and runs the watchers) last ran ${endMin} minutes ago.`);
  for (const w of watch) if (w.late && (!paused || w.whilePaused)) alarms.push(w.minutesAgo == null ? `The ${w.name} watcher has no readable heartbeat.` : `The ${w.name} watcher last ran ${w.minutesAgo} minutes ago (every ${w.everyMin}).`);
  if (!l) alarms.push('The Ledger has not been built yet (kitchen/ledger.ps1).');
  const items = (l?.items || []).slice(0, 400).map((x) => ({ id: x.id, kind: x.kind, title: x.title, from: x.from, jordans: !!x.jordans, state: x.state, owner: x.owner, why: x.why, proof: x.proof, ageDays: x.ageDays, listed: x.listed,
    chain: (x.chain || []).slice(0, 12).map((c) => ({ id: c.id, status: c.status, proof: c.proof, note: String(c.note || '').slice(0, 200), replacedBy: c.replacedBy })) }));
  return { updated: l?.updated || null, ledgerMinutesAgo: mins(l?.updated), top: l?.top || '', counts: l?.counts || {}, programs: l?.programs || [], flags: (l?.flags || []).slice(0, 60), items, watch, tickMinutesAgo: tickMin, paused, alarms };
}
function ideasView() {
  const items = (readJson(path.join(root, 'ideas.json'))?.items || []).slice(-300);
  const meta = readJson(path.join(root, 'autopilot.json')) || {};
  return { items, paused: !!meta.paused, builtToday: meta.day === today() ? Number(meta.built || 0) : 0 };   // ideas.ps1 writes the LOCAL date (a UTC date rolls over in the afternoon or evening west of UTC)
}
async function ideasAct(body) {
  const op = String(body.op || ''); const id = String(body.id || '');
  // KITCHEN_FROM_CHEF: ideas.ps1 files an idea as Jordan's (the one source that may auto-merge) only on this call from Chef
  const run = async (args) => { const { err, out } = await ps(ideasPs, [...args, '-Json'], 90000, { KITCHEN_FROM_CHEF: '1' }); try { return JSON.parse(out.trim().split(/\r?\n/).pop()); } catch { return { ok: false, error: err ? String(err.message) : 'no answer from the Yard' }; } };
  if (op === 'add') {
    const title = cleanStr(body.title, 120), goal = cleanStr(body.goal, 1400);
    if (title.length < 4 || goal.length < 12) return { ok: false, error: 'give it a short name and say what it should do' };
    return run(['add', '-Title', ' ' + title, '-Goal', ' ' + goal, '-Why', ' ' + cleanStr(body.why, 300), '-Size', ['S', 'M', 'L'].includes(body.size) ? body.size : 'M', '-Source', 'Jordan']);
  }
  if (op === 'drop' || op === 'build') { if (!/^I\d{1,5}$/.test(id)) return { ok: false, error: 'bad idea id' }; const r = await run([op, '-Id', id]); if (r.ok && op === 'build') kick(); return r; }
  // autopilot.json is also rewritten by ideas.ps1 auto/coach (read at the start of a pass, written at its end); a pause written here
  // in between was lost. ideas.ps1 pause|resume takes the same named mutex and writes temp + rename.
  if (op === 'pause' || op === 'resume') return run([op]);
  if (op === 'research') {   // send a research team on one focus (Google plan)
    const focus = cleanStr(body.focus, 600); if (focus.length < 8) return { ok: false, error: 'say what the team should research' };
    return kicked(kitchen('cook', { recipe: 'upgrades', vars: { focus, cook: 'gemini' } }));
  }
  return { ok: false, error: 'unknown ideas action' };
}

// ---- screen peek (view only): one PNG at most every 1.5 s ----
let lastShot = { at: 0, png: null, busy: null };
const shotScript = `Add-Type -AssemblyName System.Windows.Forms,System.Drawing; $b=[System.Windows.Forms.SystemInformation]::VirtualScreen; $bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height; $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left,$b.Top,0,0,$bmp.Size); $w=[Math]::Min(1600,$b.Width); $h=[int]($b.Height*$w/$b.Width); $s=New-Object System.Drawing.Bitmap $bmp,$w,$h; $m=New-Object IO.MemoryStream; $s.Save($m,[System.Drawing.Imaging.ImageFormat]::Png); [Convert]::ToBase64String($m.ToArray())`;
function screenshot() {
  if (Date.now() - lastShot.at < 1500 && lastShot.png) return Promise.resolve(lastShot.png);
  if (lastShot.busy) return lastShot.busy;
  lastShot.busy = new Promise((resolve) => {
    execFile(pwsh, ['-NoProfile', '-NonInteractive', '-Command', shotScript], { timeout: 15000, windowsHide: true, maxBuffer: 64 << 20 }, (err, out) => {
      lastShot = { at: Date.now(), png: err ? null : Buffer.from(String(out).trim(), 'base64'), busy: null };
      resolve(lastShot.png);
    });
  });
  return lastShot.busy;
}

// ---- live stream: state when it changes, plus every new event line ----
const MAX_CLIENTS = 20;
const clients = new Set();   // insertion order = oldest first
// A stream whose reader stopped (a phone asleep, a frozen tab, a half-open socket) is cut once 1 MB waits unsent, instead of
// growing in this process; EventSource reconnects and gets a fresh full state.
const SSE_MAX_BUFFER = 1 << 20;
function dropClient(c) { clients.delete(c); try { c.sse?.destroy(); } catch {} try { c.destroy(); } catch {} }
// c.sse: the phone's own compressor (see send), piped into the response; each message is flushed through it at once
function sseOut(c, msg) { if (!c.sse) return c.write(msg); c.sse.write(msg); c.sse.flush(c.sse.flushKind); }
// the first full state is allowed on top of the 1 MB (at 10x it is 1.3 MB unsent at first); once the socket drains, the plain cap holds
function sseWrite(c, msg) { if (c.destroyed || c.writableLength + (c.sse?.writableLength || 0) > SSE_MAX_BUFFER + (c.firstLen || 0)) return dropClient(c); try { sseOut(c, msg); } catch { dropClient(c); } }
let eventsSize = 0;
try { eventsSize = fs.statSync(path.join(root, 'events.jsonl')).size; } catch {}
function broadcast(type, data) { const msg = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`; for (const c of [...clients]) sseWrite(c, msg); }
// Patches, not snapshots (chef.md: a full state was 157 KB per change at 1x and 1.3 MB at 10x, parsed whole by every phone).
// A new stream gets one full `state` carrying its version v; after that each change is one `patch`: { v, base, top, upsert, remove },
// with only the top fields that moved (plus at and tickAge, so the phone's clock stays right), the jobs whose view changed and the ids
// that left. A phone applies a patch only when base is the v it holds; any gap and it reconnects once for a fresh full state
// (public/patch.js). Every phone sees the same numbered series, so the server keeps one copy, not one per phone.
const live = { v: 0, topJson: {}, jobs: new Map(), last: null };
function advance() {
  const p = stateParts(); const top = {}; let moved = false;
  for (const [k, val] of Object.entries(p.top)) { if (k === 'at' || k === 'tickAge') continue; const js = JSON.stringify(val); if (live.topJson[k] !== js) { live.topJson[k] = js; top[k] = val; moved = true; } }
  const upsert = [], seen = new Set();
  for (const x of p.jobs) { seen.add(x.view.id); if (live.jobs.get(x.view.id) !== x.json) { live.jobs.set(x.view.id, x.json); upsert.push(x.view); } }
  const remove = []; for (const id of live.jobs.keys()) if (!seen.has(id)) remove.push(id);
  for (const id of remove) live.jobs.delete(id);
  live.last = p;
  if (!live.v) { live.v = 1; return; }   // the first look: nobody holds an older copy
  if (!moved && !upsert.length && !remove.length) return;
  live.v++; broadcast('patch', { v: live.v, base: live.v - 1, top: { ...top, at: p.top.at, tickAge: p.top.tickAge }, upsert, remove });
}
// the full board at the version every open phone holds now (advance() first, so a change since the last pass reaches them as a patch)
function fullState() { advance(); const p = live.last; return { ...p.top, jobs: p.jobs.map((x) => x.view), v: live.v }; }
// Event-loop health (R7): how late the loop ran, in windows of PASS_LOOP_WINDOW_MS (default 60 s), the last 5 kept; a live pass over
// 100 ms is counted and logged. /api/health shows the numbers, so "Chef felt slow" is a number Jordan never has to report.
const LOOP_WINDOW_MS = Number(process.env.PASS_LOOP_WINDOW_MS) || 60000;
const loopH = monitorEventLoopDelay({ resolution: 10 }); loopH.enable();
const loopStat = { from: Date.now(), past: [], slowPasses: 0, windows: 0 };
const ms1 = (ns) => Math.round(ns / 1e5) / 10;
function rollLoop() { loopStat.past.push({ maxMs: ms1(loopH.max), p99Ms: ms1(loopH.percentile(99)) }); if (loopStat.past.length > 5) loopStat.past.shift(); loopH.reset(); loopStat.from = Date.now(); loopStat.windows++; }
// the first window is 5 s (start-up: reading the app files and the first full scan), then whole windows
setTimeout(() => { rollLoop(); setInterval(rollLoop, LOOP_WINDOW_MS).unref(); }, Math.min(5000, LOOP_WINDOW_MS)).unref();
function loopView() {
  const last = loopStat.past.at(-1) || null; const now = { maxMs: ms1(loopH.max), p99Ms: ms1(loopH.percentile(99)) };
  return { windowSec: LOOP_WINDOW_MS / 1000, nowSec: Math.round((Date.now() - loopStat.from) / 1000), maxMs: now.maxMs, p99Ms: now.p99Ms,
    lastMaxMs: last ? last.maxMs : null, lastP99Ms: last ? last.p99Ms : null, max5Ms: Math.max(now.maxMs, ...loopStat.past.map((x) => x.maxMs)), slowPasses: loopStat.slowPasses, windows: loopStat.windows };
}
setInterval(() => {
  if (!clients.size) return;
  const t0 = performance.now();
  try {
    advance();
    const ep = path.join(root, 'events.jsonl');
    const size = fs.existsSync(ep) ? fs.statSync(ep).size : 0;
    if (size < eventsSize) eventsSize = 0;   // rotated
    if (size > eventsSize) {
      const fd = fs.openSync(ep, 'r'); const len = Math.min(size - eventsSize, 1 << 20); const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, size - len); fs.closeSync(fd); eventsSize = size;
      for (const l of buf.toString('utf8').split(/\r?\n/).filter(Boolean)) { try { broadcast('event', JSON.parse(l)); } catch {} }
    }
    for (const e of lobeLive()) broadcast('event', e);   // ZG-30: the lobe's new lines beside the Yard's, each once (src 'lobe')
  } catch (e) { console.error('stream:', e.message); }
  const ms = performance.now() - t0; if (ms > 100) { loopStat.slowPasses++; console.error(`live pass took ${Math.round(ms)} ms`); }
}, Number(process.env.PASS_LIVE_MS) || 1000);
// a real event (an SSE comment never reaches page code) every 25 s: the phone treats 60 s of silence as a dead stream and reconnects
setInterval(() => broadcast('ping', { at: Date.now() }), 25000);

// ---- http ----
const pub = path.join(here, 'public');
// The app build: files are hashed only when a size or time changes (one stat per file every 2 s), and each file keeps its own ETag
// so the phone revalidates with a 304 instead of downloading again.
const build = { id: '', sig: '', etags: {} };
const staticCache = new Map();   // "file|etag|encoding" -> the bytes sent; a new build has new etags, so stale copies are never served
function scanBuild() {
  try {
    const files = fs.readdirSync(pub).filter((f) => fs.statSync(path.join(pub, f)).isFile()).sort();
    const sig = files.map((f) => { const st = fs.statSync(path.join(pub, f)); return `${f}:${st.size}:${st.mtimeMs}`; }).join('|');
    if (sig === build.sig) return;
    const all = crypto.createHash('sha256'); const etags = {};
    for (const f of files) { const b = fs.readFileSync(path.join(pub, f)); const h = crypto.createHash('sha256').update(b).digest('hex').slice(0, 16); etags[f] = h; all.update(f + h); }
    const id = all.digest('hex').slice(0, 10);
    if (build.id && id !== build.id) console.log(`app files changed: build ${build.id} -> ${id}`);
    Object.assign(build, { id, sig, etags });
  } catch (e) { console.error('build scan:', e.message); }
}
scanBuild(); setInterval(scanBuild, 2000);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
// Referrer-Policy same-origin, not no-referrer: under no-referrer a browser sends "Origin: null" on a same-origin POST, so originOk
// refused the sign-in form and every app action (seen in a real browser 2026-10-22). Other sites still get no referrer.
const sec = { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'same-origin', 'X-Frame-Options': 'DENY', 'Cache-Control': 'no-store',
  'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
  'Strict-Transport-Security': 'max-age=31536000',
  'Content-Security-Policy': "default-src 'self'; img-src 'self' data: blob:; style-src 'self'; script-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" };
// Compression with node's own zlib (nothing downloaded): brotli when the browser takes it (phones over Tailscale HTTPS do), else
// gzip. App files are compressed once per build at the highest level and kept in memory; answers over 1 KB are compressed as sent
// at a fast level; the live stream keeps one compressor per phone, flushed after each message, so a state resend that barely
// changed costs a few hundred bytes (brotli points back to the last copy). PASS_NO_COMPRESS=1 turns all of it off.
const COMPRESS = process.env.PASS_NO_COMPRESS !== '1';
function encodingFor(req) {
  if (!COMPRESS || !req) return '';
  const a = String(req.headers['accept-encoding'] || '').toLowerCase();
  return /(^|[\s,])br($|[\s,;])/.test(a) ? 'br' : /(^|[\s,])gzip($|[\s,;])/.test(a) ? 'gzip' : '';
}
const brOpts = (quality, size) => ({ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: quality, ...(size ? { [zlib.constants.BROTLI_PARAM_SIZE_HINT]: size } : {}) } });
function compress(buf, enc, best) {
  return enc === 'br' ? zlib.brotliCompressSync(buf, brOpts(best ? 11 : 5, buf.length)) : zlib.gzipSync(buf, { level: best ? 9 : 6 });
}
function send(res, code, body, type = 'application/json') {
  if (res.headersSent) return;
  let buf = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  const enc = Buffer.byteLength(buf) > 1024 ? encodingFor(res.req) : '';
  const head = { ...sec, 'Content-Type': type, Vary: 'Accept-Encoding' };
  if (enc) { buf = compress(Buffer.from(buf), enc, false); head['Content-Encoding'] = enc; }
  res.writeHead(code, head); res.end(buf);
}
// Request bodies: JSON only, capped in bytes (64 KB, so a full 12,000-character posting in any script fits); anything bigger is
// refused (413), never left hanging. Chunks are joined as bytes and decoded once: a character split across two chunks stays whole.
function readBody(req, maxBytes = 65536, parse = (s) => JSON.parse(s || '{}')) {
  return new Promise((resolve) => {
    const chunks = []; let size = 0; let done = false;
    req.on('data', (d) => { if (done) return; size += d.length; if (size > maxBytes) { done = true; resolve({ tooBig: true }); req.resume(); return; } chunks.push(d); });
    req.on('end', () => { if (done) return; done = true; try { resolve({ body: parse(Buffer.concat(chunks).toString('utf8')) }); } catch { resolve({ body: null }); } });
    req.on('error', () => { if (!done) { done = true; resolve({ body: null }); } });
  });
}
function audit(req, op, body, r) {
  try { fs.appendFileSync(path.join(root, 'pass-actions.jsonl'), JSON.stringify({ ts: new Date().toISOString(), op, id: body.id || body.name || body.recipe || '', ok: !!r.ok, who: tailscaleUser(req) || 'key', error: r.ok ? undefined : String(r.error || '').slice(0, 200) }) + '\n'); } catch {}
}

async function handle(req, res) {
  // DNS-rebinding guard, before anything else (login included): only the hosts Chef is really served on; a write must come from them
  if (!hostKind(req)) return send(res, 421, { ok: false, error: 'wrong host' });
  if (req.method !== 'GET' && req.method !== 'HEAD' && !originOk(req)) return send(res, 403, { ok: false, error: 'wrong origin' });
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/login') {   // sign in once with the pass key; the device keeps a signed session cookie (never the key)
    // The key travels only in the form's body (POST), never in a link, from anywhere (the PC too): a URL stays in browser history,
    // so a GET with ?key= only shows the form and never signs in.
    const html = 'text/html; charset=utf-8'; let k = null;
    if (req.method === 'POST') {
      if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/x-www-form-urlencoded')) return send(res, 415, loginForm('Send the form.'), html);
      const { body, tooBig } = await readBody(req, 2048, (s) => Object.fromEntries(new URLSearchParams(s)));
      if (tooBig) return send(res, 413, loginForm('Too long.'), html);
      k = String(body?.key ?? '').trim();
    }
    if (k === null) return send(res, 200, loginForm(url.searchParams.has('key') ? 'For safety the Board never takes the key from a link: paste it below, or open the Board with your Tailscale login.' : 'Sign in with the pass key, or open the Board with your Tailscale login.'), html);
    if (loginLocked()) return send(res, 429, loginForm('Too many wrong keys: sign-in is paused for 15 minutes.'), html);
    if (keyOk(k)) { res.writeHead(303, { ...sec, Location: '/', 'Set-Cookie': `pass=${newSession()}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${SESSION_SEC}` }); return res.end(); }
    loginFails.push(Date.now());
    return send(res, 401, loginForm('Wrong or missing key.'), html);
  }
  if (url.pathname === '/manifest.webmanifest' || url.pathname === '/icon.svg') {   // needed before login for "Add to Home Screen"
    return send(res, 200, fs.readFileSync(path.join(pub, url.pathname.slice(1))), types[path.extname(url.pathname)]);
  }
  if (url.pathname === '/api/health') return send(res, 200, { ok: true, version: VERSION, build: build.id, server: SERVER, up: Math.round(process.uptime()), loop: loopView(), work });   // no data (numbers only: loop delay, files read); for watchdogs, update.ps1 and the W4 tests
  if (!authed(req)) return send(res, 401, { ok: false, error: 'pass key required' });
  if (url.pathname === '/api/state') return send(res, 200, state());
  if (url.pathname === '/api/bye') {   // update.ps1, just before a restart (pass key only, POST): phones reconnect quietly
    if (req.method !== 'POST' || !keyOk((req.headers.authorization || '').slice(7))) return send(res, 403, { ok: false, error: 'pass key only' });
    broadcast('bye', { reason: 'restart' }); return send(res, 200, { ok: true, clients: clients.size });
  }
  if (url.pathname === '/api/towers') return send(res, 200, towers.view());   // the City (pass-app/towers.mjs); read-only
  if (url.pathname === '/api/recipes') return send(res, 200, { ok: true, data: recipes() });
  if (url.pathname === '/api/cooks') return send(res, 200, { ok: true, data: cookHistory() });
  if (url.pathname === '/api/whoami') return send(res, 200, { ok: true, who: tailscaleUser(req) || 'pass key', version: VERSION });
  if (url.pathname === '/api/audit') {
    const rows = tailLines(path.join(root, 'pass-actions.jsonl'), 200, 1 << 20).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean).reverse();
    return send(res, 200, { ok: true, data: rows });
  }
  if (url.pathname === '/api/events') {   // older history for the activity feed
    const n = Math.min(1000, Math.max(1, Number(url.searchParams.get('n')) || 300));
    const yard = tailLines(path.join(root, 'events.jsonl'), n, 4 << 20).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    return send(res, 200, { ok: true, data: [...yard, ...lobeEventsTail(Math.min(n, LOBE_RING))].sort((a, b) => String(a.ts).localeCompare(String(b.ts))) });   // ZG-30: the lobe's lines too (src 'lobe')
  }
  if (url.pathname === '/api/stream') {
    // full: the oldest stream makes room (half-open sockets from network flaps would otherwise lock every phone out with 503)
    while (clients.size >= MAX_CLIENTS) dropClient(clients.values().next().value);
    const enc = encodingFor(req);
    res.writeHead(200, { ...sec, 'Content-Type': 'text/event-stream', Connection: 'keep-alive', Vary: 'Accept-Encoding', ...(enc ? { 'Content-Encoding': enc } : {}) });
    if (enc) {   // a 1 MB window holds the last state copy, so the next one is sent as little more than what changed
      res.sse = enc === 'br' ? zlib.createBrotliCompress({ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 5, [zlib.constants.BROTLI_PARAM_LGWIN]: 20 } }) : zlib.createGzip({ level: 6 });
      res.sse.flushKind = enc === 'br' ? zlib.constants.BROTLI_OPERATION_FLUSH : zlib.constants.Z_SYNC_FLUSH;
      res.sse.on('error', () => dropClient(res)); res.sse.pipe(res);
    }
    let first = 'retry: 1500\n\n' + `event: state\ndata: ${JSON.stringify(fullState())}\n\n`;
    for (const l of tailLines(path.join(root, 'events.jsonl'), 40)) { try { first += `event: event\ndata: ${JSON.stringify(JSON.parse(l))}\n\n`; } catch {} }
    for (const e of lobeEventsTail(40)) first += `event: event\ndata: ${JSON.stringify(e)}\n\n`;   // ZG-30: the lobe's newest lines (src 'lobe')
    sseOut(res, first); res.firstLen = Buffer.byteLength(first); res.once('drain', () => { res.firstLen = 0; });
    res.on('close', () => { try { res.sse?.destroy(); } catch {} });
    clients.add(res); req.on('close', () => clients.delete(res)); res.on('close', () => clients.delete(res)); return;
  }
  if (url.pathname.startsWith('/api/job/') && url.pathname.endsWith('/diff')) {
    const id = jobId(url.pathname.slice(9, -5)); if (!id) return send(res, 400, { ok: false, error: 'bad job id' });
    const file = url.searchParams.get('file'); if (file !== null && (!file || file.length > 400 || /[\0\r\n]/.test(file))) return send(res, 400, { ok: false, error: 'bad file name' });
    const r = await phoneDiff(id, file); return send(res, r.code, r.code === 200 ? { ok: true, data: r.data } : { ok: false, error: r.error });
  }
  if (url.pathname.startsWith('/api/job/') && url.pathname.endsWith('/timeline')) {
    const id = jobId(url.pathname.slice(9, -9)); if (!id) return send(res, 400, { ok: false, error: 'bad job id' });
    const tl = jobTimeline(id); return tl ? send(res, 200, { ok: true, id, runs: tl.runs, data: tl }) : send(res, 404, { ok: false, error: 'no such job' });
  }
  if (url.pathname.startsWith('/api/job/')) {
    const id = jobId(url.pathname.slice(9)); if (!id) return send(res, 400, { ok: false, error: 'bad job id' });
    const d = await jobDetail(id); return d ? send(res, 200, { ok: true, data: d }) : send(res, 404, { ok: false, error: 'no such job' });
  }
  if (url.pathname.startsWith('/api/log/')) {
    const id = jobId(url.pathname.slice(9)); if (!id) return send(res, 400, { ok: false, error: 'bad job id' });
    const want = url.searchParams.get('run'); if (want && (!runId(want) || !want.startsWith(id + '-'))) return send(res, 400, { ok: false, error: 'bad run id' });
    let files = [];
    try { files = fs.readdirSync(runDir).filter((f) => f.startsWith(id + '-') && f.endsWith('.log')).map((f) => ({ f, t: fs.statSync(path.join(runDir, f)).mtimeMs })).sort((a, b) => a.t - b.t); } catch {}
    const pick = want ? files.find((x) => x.f === want + '.log') : files[files.length - 1];
    return send(res, 200, { ok: true, id, run: pick ? pick.f.replace(/\.log$/, '') : null, lines: pick ? tailLines(path.join(runDir, pick.f), 400, 256 * 1024) : [] });
  }
  if (url.pathname.startsWith('/api/hunt/draft/') && req.method === 'GET') {
    let id = ''; try { id = decodeURIComponent(url.pathname.slice(16)); } catch {}
    if (!/^A\d{1,5}$/.test(id)) return send(res, 400, { ok: false, error: 'bad application id' });
    const d = draftFor(id); return d ? send(res, 200, { ok: true, data: d }) : send(res, 404, { ok: false, error: 'no draft yet' });
  }
  if (url.pathname === '/api/hunt' && req.method === 'GET') {   // an unreadable tracker is an error, never an empty list Chef could save over
    let items; try { items = trackerLoad(); } catch (e) { return send(res, 200, { ok: false, error: e.message }); }
    return send(res, 200, { ok: true, data: { items, openings: scoutOpenings(), due: dueItems().length, packets: packetIds() } });
  }
  if (url.pathname === '/api/hunt/packet' && req.method === 'GET') {
    const id = cleanStr(url.searchParams.get('id'), 20); if (!appIdOk(id)) return send(res, 400, { ok: false, error: 'bad application id' });
    const v = await packetView(id); return v ? send(res, 200, { ok: true, data: v }) : send(res, 404, { ok: false, error: 'no apply packet for this role yet' });
  }
  if (url.pathname === '/api/hunt/packet/pdf' && req.method === 'GET') {   // the locked resume copy inside the packet, as a download
    const id = cleanStr(url.searchParams.get('id'), 20); if (!appIdOk(id)) return send(res, 400, { ok: false, error: 'bad application id' });
    const p = path.join(packetsDir, id, 'resume.pdf'); let st = null; try { st = fs.lstatSync(p); } catch {}
    if (!st || !st.isFile() || st.isSymbolicLink()) return send(res, 404, { ok: false, error: 'no resume in this packet' });
    const b = fs.readFileSync(p); res.writeHead(200, { ...sec, 'Content-Type': 'application/pdf', 'Content-Disposition': 'attachment; filename="resume.pdf"', 'Content-Length': b.length }); return res.end(b);
  }
  if (url.pathname === '/api/hunt/pdf' && req.method === 'GET') {
    const id = cleanStr(url.searchParams.get('id'), 20);
    if (!/^A\d{1,5}$/.test(id)) return send(res, 400, { ok: false, error: 'bad application id' });
    const packsDir = path.join(careerDir, 'packs');
    const pdfPath = path.resolve(packsDir, `${id}-resume.pdf`);
    if (!pdfPath.startsWith(packsDir + path.sep) || !fs.existsSync(pdfPath) || !fs.statSync(pdfPath).isFile()) return send(res, 404, { ok: false, error: 'pack pdf not found' });
    const pdfBytes = fs.readFileSync(pdfPath);
    res.writeHead(200, { ...sec, 'Content-Type': 'application/pdf', 'Content-Disposition': 'inline', 'Content-Length': pdfBytes.length });
    return res.end(pdfBytes);
  }
  if (url.pathname === '/api/hunt/answers' && req.method === 'GET') {
    const id = cleanStr(url.searchParams.get('id'), 20);
    if (!/^A\d{1,5}$/.test(id)) return send(res, 400, { ok: false, error: 'bad application id' });
    const packsDir = path.join(careerDir, 'packs');
    const ansPath = path.resolve(packsDir, `${id}-answers.md`);
    if (!ansPath.startsWith(packsDir + path.sep) || !fs.existsSync(ansPath) || !fs.statSync(ansPath).isFile()) return send(res, 404, { ok: false, error: 'answers not found' });
    const answers = fs.readFileSync(ansPath, 'utf8');
    return send(res, 200, { ok: true, data: { id, answers } });
  }
  if (url.pathname === '/api/ideas' && req.method === 'GET') return send(res, 200, { ok: true, data: ideasView() });
  if (url.pathname === '/api/ledger' && req.method === 'GET') return send(res, 200, { ok: true, data: ledgerView() });
  if (url.pathname === '/api/clients' && req.method === 'GET') { const v = clientsView(); return v.error ? send(res, 200, { ok: false, error: v.error }) : send(res, 200, { ok: true, data: v }); }
  if (url.pathname === '/api/brief') { const t = url.searchParams.get('since'); return send(res, 200, { ok: true, data: brief(t && Number.isFinite(Date.parse(t)) ? t : null) }); }
  if (url.pathname === '/api/since') {   // Since You Looked: counts from the event log since t (the phone's own last-seen time)
    const v = sinceView(url.searchParams.get('t')); return v ? send(res, 200, { ok: true, data: v }) : send(res, 400, { ok: false, error: 'since: t must be a date and time' });
  }
  if (url.pathname === '/api/lead' && req.method === 'GET') return send(res, 200, { ok: true, data: leadView() });
  if (url.pathname === '/api/lobe' && req.method === 'GET') return send(res, 200, lobeView());   // ZG-09: {ok, csf, health} or {ok:false, why}
  if (url.pathname === '/api/push') return send(res, 200, { ok: true, data: { on: pushOn(), topic: readTopic() } });
  if (url.pathname === '/api/talk' && req.method === 'GET') return send(res, 200, { ok: true, data: threads() });
  if (url.pathname.startsWith('/api/talk/')) {
    const id = threadId(url.pathname.slice(10)); if (!id) return send(res, 400, { ok: false, error: 'bad chat id' });
    const t = readThread(id); return t ? send(res, 200, { ok: true, data: t }) : send(res, 404, { ok: false, error: 'no such chat' });
  }
  if (url.pathname === '/api/screen') { const png = await screenshot(); return png ? send(res, 200, png, 'image/png') : send(res, 503, { ok: false, error: 'screen not available' }); }
  if (url.pathname === '/api/action' || url.pathname === '/api/preview' || url.pathname === '/api/talk' || url.pathname === '/api/hunt' || url.pathname === '/api/ideas' || url.pathname === '/api/lead' || url.pathname === '/api/clients' || url.pathname === '/api/lobe') {
    if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'POST only' });
    if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) return send(res, 415, { ok: false, error: 'json only' });
    const { body, tooBig } = await readBody(req);
    if (tooBig) return send(res, 413, { ok: false, error: 'request too large' });
    if (!body || typeof body !== 'object' || Array.isArray(body)) return send(res, 400, { ok: false, error: 'bad json' });
    if (url.pathname === '/api/preview') return send(res, 200, await preview(body));
    if (url.pathname === '/api/clients') { let r; try { r = await clientsAct(body); } catch (e) { r = { ok: false, error: 'could not save: ' + e.message }; } audit(req, 'clients-' + String(body.op || ''), { id: String(body.id || '') }, r); return send(res, 200, r); }
    if (url.pathname === '/api/ideas') { const r = await ideasAct(body); audit(req, 'ideas-' + String(body.op || ''), { id: r.idea?.id || body.id || '' }, r); return send(res, 200, r); }
    if (url.pathname === '/api/hunt') { let r; try { r = await tracker(body); } catch (e) { r = { ok: false, error: 'could not save: ' + e.message }; } audit(req, 'hunt-' + String(body.op || ''), { id: /^profile-/.test(String(body.op || '')) ? '' : r.data?.job || r.data?.id || body.id || '' }, r); return send(res, 200, r); }   // profile ops: only the op is logged, never a value
    if (url.pathname === '/api/lead') { let r; try { r = await leadAct(body); } catch (e) { r = { ok: false, error: 'could not save: ' + e.message }; } audit(req, 'lead-' + String(body.op || ''), { id: r.data?.id || body.id || '' }, r); return send(res, 200, r); }   // the words are not logged
    if (url.pathname === '/api/lobe') { let r; try { r = lobeAct(req, body); } catch (e) { r = { ok: false, error: 'could not save: ' + e.message }; } if (!r.ok) audit(req, 'lobe-' + String(body.op || ''), { id: '' }, r); return send(res, 200, r); }   // ZG-13: a tap is its own line (tapAppend); a refusal is audited, never its words
    if (url.pathname === '/api/talk') { const r = talk(body); audit(req, 'talk', { id: r.thread || body.thread || '' }, r); return send(res, 200, r); }   // the words are not logged
    // the same action while it is still running (a double tap, two phones) shares the first one's answer instead of running twice
    const key = JSON.stringify([body.op, body.id, body.approval, body.diffSha, body.items, body.name, body.recipe, body.vars]);
    if (running.has(key)) return send(res, 200, { ...(await running.get(key)), duplicate: true });
    const p = act(body); running.set(key, p);
    let r; try { r = await p; } finally { running.delete(key); }
    audit(req, String(body.op || ''), Array.isArray(body.items) ? { id: (r.data?.approved || []).join(' ') } : body, r);
    return send(res, 200, r);
  }
  const file = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const full = path.resolve(pub, file);
  if (!full.startsWith(pub + path.sep) || !fs.existsSync(full) || !fs.statSync(full).isFile()) return send(res, 404, { ok: false, error: 'not found' });
  // App files: always revalidated (no-cache), answered 304 when unchanged. sw.js carries the build, so every build installs a fresh
  // service worker that throws away the old shell.
  const rel = path.relative(pub, full).replace(/\\/g, '/'); const tag = `"${build.etags[rel] || ''}-${build.id}"`;
  const head = { ...sec, 'Cache-Control': 'no-cache', ETag: tag, 'Content-Type': types[path.extname(full)] || 'application/octet-stream', ...(file === 'sw.js' ? { 'Service-Worker-Allowed': '/' } : {}) };
  head.Vary = 'Accept-Encoding';
  if (req.headers['if-none-match'] === tag) { res.writeHead(304, head); return res.end(); }
  const enc = /\.(html|js|css|svg|json|webmanifest)$/.test(rel) ? encodingFor(req) : '';   // woff2 and png are compressed already
  const ck = `${rel}|${tag}|${enc}`; let body = staticCache.get(ck);
  if (!body) {
    const raw = fs.readFileSync(full); body = file === 'sw.js' ? Buffer.from(String(raw).replace('__BUILD__', build.id)) : raw;
    if (staticCache.size > 200) staticCache.clear();   // old builds' copies go; the current build refills on the next requests
    if (enc) {   // a fast squeeze now; the smallest one is made off the main thread and replaces it for every later load
      const plain = body; body = compress(plain, enc, false);
      (enc === 'br' ? zlib.brotliCompress : zlib.gzip)(plain, enc === 'br' ? brOpts(11, plain.length) : { level: 9 }, (e, best) => { if (!e && staticCache.has(ck)) staticCache.set(ck, best); });
    }
    staticCache.set(ck, body);
  }
  if (enc) head['Content-Encoding'] = enc;
  res.writeHead(200, head); return res.end(body);
}
const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => { console.error('request failed:', String(req.url).split('?')[0], e?.message); send(res, 500, { ok: false, error: 'the Board server hit an error; it is still running' }); });   // path only: a query can carry a key
});
process.on('uncaughtException', (e) => console.error('uncaught:', e?.message));
// A planned restart (update.ps1 asks with Ctrl+Break or a signal) tells every phone first, so it reconnects quietly instead of
// showing "can't reach the kitchen".
for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => { broadcast('bye', { reason: 'restart' }); setTimeout(() => process.exit(0), 150); });
process.on('unhandledRejection', (e) => console.error('unhandled:', e?.message || e));

// Default: 127.0.0.1 only, reached from the phone through `tailscale serve` (HTTPS). PASS_TAILSCALE_DIRECT=1 also binds the raw
// Tailscale address over plain http (old mode; Chrome shows "not secure").
const hosts = ['127.0.0.1'];
if (process.env.PASS_TAILSCALE_DIRECT === '1') {
  for (const exe of ['tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe']) {
    try { const ip = execFileSync(exe, ['ip', '-4'], { timeout: 5000, windowsHide: true }).toString().trim().split(/\s+/)[0]; if (/^100\.\d+\.\d+\.\d+$/.test(ip)) { hosts.push(ip); directHosts.add(ip); break; } } catch {}
  }
}
for (const h of hosts) {
  const s = h === hosts[0] ? server : http.createServer(server.listeners('request')[0]);
  // the main address failing to bind (port taken, a Windows-reserved range) exits, so the task's restart-on-failure and the
  // watchdog's restart can work; a process with no listener would read Running forever. The optional direct address only logs.
  s.on('error', (e) => { console.error(`listen on ${h}:${port} failed:`, e?.code || e?.message); if (s === server && !s.listening) process.exit(1); });
  s.listen(port, h, () => console.log(`Chef ${VERSION} is open on http://${h}:${port}/login (sign in with the pass key in ${keyPath})`));
}
