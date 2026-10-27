#!/usr/bin/env node
// @ts-check
// Owns the task store's command line: numbered .md files with front matter (dev tasks and roadmap milestones) in a LOCAL, private
// folder, never in this repo. Read by the /task-orchestrate workflow (.claude/workflows/task-orchestrate.js), /task-start, /task-new
// and /roadmap-add (.claude/commands/), and by hand. Zero dependencies; Node 22 or later.
//   node tools/task.mjs where                                   the store folder and where that choice came from
//   node tools/task.mjs list [--status s] [--kind k] [--ready]  every task: id, kind, status, ready or what it waits on, title
//   node tools/task.mjs show <n>                                one file as it is (front matter and body; private text, local only)
//   node tools/task.mjs next [--lanes N] [--claim] [--resume] [--run new|<id>]   the next ready task(s); lanes never share a path; --claim marks them doing
//   node tools/task.mjs roadmap [--next]                        milestones in roadmap order with their counts; --next = the first open one
//   node tools/task.mjs new --title t [--kind milestone] [--paths a,b] [--depends 3,jordan] [--milestone m] [--priority 1-9]
//                           [--order n] [--public-title t] [--status s] [--body text | --body-file f]     a new numbered file
//   node tools/task.mjs set <n> key=value [key+=item] [key=]    change front matter fields (validated; key= removes an optional field)
//   node tools/task.mjs note <n> --text line                    append a dated line under "## Log" in the task body
//   node tools/task.mjs start <n> [--run new|<id>]              one task: pause, usage and lock checks, then claim it (or resume it)
//   node tools/task.mjs lock acquire|heartbeat --run id|release --run id|release --force|status    one orchestrator at a time
//   node tools/task.mjs pause --reason text | resume | state    stop the orchestrator at its next pick, or let it pick again
//   node tools/task.mjs usage                                   the plan usage the orchestrator obeys (go / pause / stop)
//   node tools/task.mjs check                                   every file valid, every dependency known, no cycles (exit 1 if not)
// Every command takes --store <dir> and --json (one JSON object on stdout; shape version v: 1, read-only safe for other tools).
// The store: --store, else $TIDE_TASKS_DIR, else "store" in <state>\tasks.json (state = $BRAIN_KITCHEN, else %LOCALAPPDATA%\brain-kitchen),
// else <home>\gemini-brain\projects\tide\tasks. Exit: 0 fine, 1 not found or check failed, 2 bad arguments, 3 next, start, lock: paused, usage stop or locked.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

export const TASK_STATUS = ['todo', 'doing', 'review', 'blocked', 'done', 'dropped'];
export const MILESTONE_STATUS = ['todo', 'doing', 'done', 'dropped'];
export const WIP_LIMIT = 4; // build streams open at once (build-way 3.3); --lanes never goes above it
const KNOWN = ['title', 'kind', 'status', 'priority', 'milestone', 'order', 'paths', 'depends', 'public_title'];
const FILE_RE = /^(\d+)(?:-[^\\/]*)?\.md$/;

// ---- the store -------------------------------------------------------------------------------------------------------------------
export function stateDir(env = process.env, home = os.homedir()) {
  if (env.BRAIN_KITCHEN) return env.BRAIN_KITCHEN;
  return path.join(env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'brain-kitchen');
}

/** @returns {{ dir: string, source: string }} */
export function resolveStore(flag = '', env = process.env, home = os.homedir()) {
  if (flag) return { dir: path.resolve(flag), source: '--store' };
  if (env.TIDE_TASKS_DIR) return { dir: path.resolve(env.TIDE_TASKS_DIR), source: 'TIDE_TASKS_DIR' };
  const cfg = path.join(stateDir(env, home), 'tasks.json');
  if (fs.existsSync(cfg)) {
    let store;
    try { store = JSON.parse(fs.readFileSync(cfg, 'utf8')).store; } catch (e) { throw new Error(`${cfg} is not valid JSON (${e.message})`); }
    if (typeof store !== 'string' || !store) throw new Error(`${cfg} needs {"store": "<folder>"}`);
    return { dir: path.resolve(store.replace(/%USERPROFILE%/gi, home)), source: cfg };
  }
  return { dir: path.join(home, 'gemini-brain', 'projects', 'tide', 'tasks'), source: 'default' };
}

// ---- front matter: a small YAML subset (key: value, [inline, lists], "- item" block lists, quotes, numbers, booleans, # comments) ----
function scalar(raw) {
  const v = raw.trim();
  if (v.startsWith('"')) { try { return { value: JSON.parse(v) }; } catch { return { error: `bad double-quoted text ${v}` }; } }
  if (v.startsWith("'")) { if (!/^'(?:[^']|'')*'$/.test(v)) return { error: `bad single-quoted text ${v}` }; return { value: v.slice(1, -1).replace(/''/g, "'") }; }
  if (/^-?\d+$/.test(v)) return { value: Number(v) };
  if (v === 'true' || v === 'false') return { value: v === 'true' };
  if (v === 'null' || v === '~') return { value: null };
  return { value: v };
}
function stripComment(v) {
  if (/^["']/.test(v.trim())) return v; // a quoted value keeps its # characters
  return v.replace(/\s+#.*$/, '');
}
function splitInline(inner) {
  const out = []; let cur = ''; let q = '';
  for (const ch of inner) {
    if (q) { cur += ch; if (ch === q) q = ''; continue; }
    if (ch === '"' || ch === "'") { q = ch; cur += ch; continue; }
    if (ch === ',') { out.push(cur); cur = ''; continue; }
    cur += ch;
  }
  if (q) return null;
  if (cur.trim() || out.length) out.push(cur);
  return out.map((s) => s.trim());
}
export function parseValue(raw) {
  const v = stripComment(raw).trim();
  if (v.startsWith('[')) {
    if (!v.endsWith(']')) return { error: `list ${v} is not closed with ]` };
    const parts = splitInline(v.slice(1, -1));
    if (!parts) return { error: `list ${v} has an unclosed quote` };
    const out = [];
    for (const p of parts) { if (!p) return { error: `list ${v} has an empty item` }; const s = scalar(p); if (s.error) return s; out.push(s.value); }
    return { value: out };
  }
  return scalar(v);
}

/** @returns {{ ok: true, data: Record<string, any>, body: string } | { ok: false, error: string }} */
export function parseFrontMatter(text) {
  const lines = String(text).replace(/^﻿/, '').split(/\r?\n/);
  if (lines[0].trim() !== '---') return { ok: false, error: 'no front matter: the first line must be ---' };
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === '---');
  if (end < 0) return { ok: false, error: 'front matter is not closed: no second --- line' };
  const data = {}; let listKey = '';
  for (let i = 1; i < end; i++) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const item = /^\s+-\s+(.*)$/.exec(line) || /^-\s+(.*)$/.exec(line);
    if (item) {
      if (!listKey) return { ok: false, error: `line ${i + 1}: a "- item" line with no "key:" above it` };
      const s = scalar(stripComment(item[1])); if (s.error) return { ok: false, error: `line ${i + 1}: ${s.error}` };
      data[listKey].push(s.value); continue;
    }
    if (/^\s/.test(line)) return { ok: false, error: `line ${i + 1} is indented but is not a "- item" line` };
    const m = /^([a-z][a-z0-9_]*):(?:\s+(.*)|\s*)$/.exec(line);
    if (!m) return { ok: false, error: `line ${i + 1} is not "key: value"` };
    if (m[1] in data) return { ok: false, error: `line ${i + 1}: "${m[1]}" appears twice` };
    const rawV = stripComment(m[2] || '').trim();
    if (!rawV) { data[m[1]] = []; listKey = m[1]; continue; } // "key:" alone opens a block list (or stays an empty list)
    listKey = '';
    const p = parseValue(rawV); if (p.error) return { ok: false, error: `line ${i + 1}: ${p.error}` };
    data[m[1]] = p.value;
  }
  return { ok: true, data, body: lines.slice(end + 1).join('\n') };
}

function quote(v) {
  const s = String(v);
  if (s === '' || /^[\s"'[\]{}#&*!|>%@`-]|[:,#\]\[]|\s$/.test(s) || /^(true|false|null|~|-?\d+)$/.test(s)) return JSON.stringify(s);
  return s;
}
function fmValue(v) {
  if (Array.isArray(v)) return `[${v.map((x) => (typeof x === 'number' ? String(x) : quote(x))).join(', ')}]`;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (v === null) return 'null';
  return quote(v);
}
/** Front matter in a fixed key order (known keys first, then the file's own extra keys in their order), then the body. */
export function formatTask(data, body) {
  const keys = [...KNOWN.filter((k) => k in data), ...Object.keys(data).filter((k) => !KNOWN.includes(k))];
  const fm = keys.filter((k) => data[k] !== undefined).map((k) => `${k}: ${fmValue(data[k])}`);
  const b = String(body || '').replace(/^\n+/, '');
  return `---\n${fm.join('\n')}\n---\n${b ? `\n${b.replace(/\n*$/, '\n')}` : ''}`;
}

// ---- one task: typed and checked --------------------------------------------------------------------------------------------------
const intIn = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
/** @returns {{ ok: true, task: any } | { ok: false, error: string }} */
export function normalize(data, id) {
  const d = { ...data };
  if ('id' in d && d.id !== id) return { ok: false, error: `id ${d.id} does not match the file number ${id}` };
  if (typeof d.title !== 'string' || !d.title.trim()) return { ok: false, error: 'title is missing' };
  const kind = d.kind ?? 'task';
  if (kind !== 'task' && kind !== 'milestone') return { ok: false, error: `kind must be task or milestone, not ${kind}` };
  const status = d.status ?? 'todo';
  const allowed = kind === 'task' ? TASK_STATUS : MILESTONE_STATUS;
  if (!allowed.includes(status)) return { ok: false, error: `status must be one of ${allowed.join(', ')}, not ${status}` };
  const priority = d.priority ?? 5;
  if (!intIn(priority, 1, 9)) return { ok: false, error: `priority must be a whole number 1-9, not ${priority}` };
  for (const k of ['milestone', 'order']) if (d[k] !== undefined && d[k] !== null && !intIn(d[k], 0, 1e9)) return { ok: false, error: `${k} must be a whole number, not ${d[k]}` };
  let paths = d.paths ?? [];
  if (typeof paths === 'string') paths = [paths];
  if (!Array.isArray(paths) || paths.some((p) => typeof p !== 'string' || !p.trim())) return { ok: false, error: 'paths must be a list of repo paths or globs' };
  let depends = d.depends ?? [];
  if (!Array.isArray(depends)) depends = [depends];
  const deps = [];
  for (const x of depends) {
    if (x === 'jordan') { deps.push('jordan'); continue; }
    const n = typeof x === 'number' ? x : (/^#?\d+$/.test(String(x)) ? Number(String(x).replace('#', '')) : NaN);
    if (!Number.isInteger(n) || n < 1) return { ok: false, error: `depends items are task numbers or "jordan", not ${JSON.stringify(x)}` };
    if (n === id) return { ok: false, error: 'a task cannot depend on itself' };
    deps.push(n);
  }
  const pt = d.public_title;
  if (pt !== undefined && (typeof pt !== 'string' || !pt.trim() || pt.length > 90 || /[\r\n]/.test(pt))) return { ok: false, error: 'public_title must be one line of at most 90 characters' };
  return { ok: true, task: { ...d, id, title: d.title.trim(), kind, status, priority, paths: paths.map((p) => p.trim()), depends: deps, milestone: d.milestone ?? null, order: d.order ?? id, public_title: pt ?? null } };
}

export function loadStore(dir) {
  /** @type {any[]} */ const tasks = []; /** @type {{ file: string, id: number|null, error: string }[]} */ const bad = [];
  if (!fs.existsSync(dir)) return { dir, tasks, bad, missing: true };
  const seen = new Map();
  for (const name of fs.readdirSync(dir).sort()) {
    const m = FILE_RE.exec(name); if (!m) continue;
    const id = Number(m[1]); const file = path.join(dir, name);
    if (seen.has(id)) { bad.push({ file, id, error: `number ${id} is used twice (also ${path.basename(seen.get(id))})` }); continue; }
    seen.set(id, file);
    const p = parseFrontMatter(fs.readFileSync(file, 'utf8'));
    if (!p.ok) { bad.push({ file, id, error: p.error }); continue; }
    const n = normalize(p.data, id);
    if (!n.ok) { bad.push({ file, id, error: n.error }); continue; }
    tasks.push({ ...n.task, file, body: p.body });
  }
  // the second file with a used number is refused, and so is the first one (neither is trusted until a person renames one)
  for (const b of bad.filter((x) => /used twice/.test(x.error))) {
    const i = tasks.findIndex((t) => t.id === b.id);
    if (i >= 0) { bad.push({ file: tasks[i].file, id: b.id, error: `number ${b.id} is used twice` }); tasks.splice(i, 1); }
  }
  return { dir, tasks, bad, missing: false };
}

// ---- readiness, order and lanes ---------------------------------------------------------------------------------------------------
/** What a task (or milestone) still waits on: [] = nothing. Each entry is plain words. */
export function waitsOn(t, byId, badIds) {
  const out = [];
  const one = (dep, via) => {
    if (dep === 'jordan') { out.push(via ? `jordan (milestone ${via})` : 'jordan'); return; }
    if (badIds.has(dep)) { out.push(`task ${dep} is malformed`); return; }
    const d = byId.get(dep);
    if (!d) out.push(`task ${dep} does not exist`);
    else if (d.status === 'dropped') out.push(`task ${dep} was dropped`);
    else if (d.status !== 'done') out.push(`task ${dep} (${d.status})`);
  };
  for (const dep of t.depends) one(dep, 0);
  if (t.kind === 'task' && t.milestone) {
    const m = byId.get(t.milestone);
    if (!m || m.kind !== 'milestone') out.push(`milestone ${t.milestone} does not exist`);
    else for (const dep of m.depends) one(dep, m.id);
  }
  return out;
}
const DONE = new Set(['done', 'dropped']);
export function analyze(store) {
  const byId = new Map(store.tasks.map((t) => [t.id, t])); const badIds = new Set(store.bad.map((b) => b.id));
  return store.tasks.map((t) => {
    const waits = waitsOn(t, byId, badIds);
    const ready = t.kind === 'task' && t.status === 'todo' && waits.length === 0;
    return { ...t, ready, waits };
  });
}
/** priority, then the milestone's roadmap order (none = last), then the number */
export function readyOrder(rows) {
  const byId = new Map(rows.map((t) => [t.id, t]));
  const mOrder = (t) => { const m = t.milestone && byId.get(t.milestone); return m ? m.order : Number.MAX_SAFE_INTEGER; };
  return rows.filter((t) => t.ready).sort((a, b) => a.priority - b.priority || mOrder(a) - mOrder(b) || a.id - b.id);
}

// Two path lists clash when any pair could name the same file. Conservative on purpose: it may keep two tasks apart that would not
// really collide, never the other way round. A task with no paths could touch anything, so it clashes with every other task.
const norm = (p) => p.replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, '').toLowerCase();
const GLOB = /[*?[{]/;
function pairClash(a, b) {
  const x = norm(a); const y = norm(b);
  const gx = GLOB.test(x); const gy = GLOB.test(y);
  if (!gx && !gy) return x === y || x.startsWith(`${y}/`) || y.startsWith(`${x}/`);
  const px = gx ? x.slice(0, x.search(GLOB)) : x; const py = gy ? y.slice(0, y.search(GLOB)) : y;
  return px.startsWith(py) || py.startsWith(px);
}
export function pathsClash(a, b) {
  if (!a.length || !b.length) return true;
  return a.some((x) => b.some((y) => pairClash(x, y)));
}

/** The orchestrator's pick. resume: this orchestrator's own in-flight tasks first (a rerun after a cap continues them). */
export function pickNext(rows, { lanes = 1, wip = WIP_LIMIT, resume = false } = {}) {
  const inflight = rows.filter((t) => t.kind === 'task' && (t.status === 'doing' || t.status === 'review'));
  const want = Math.max(1, Math.min(lanes, wip));
  if (resume) {
    const mine = inflight.filter((t) => t.claimed_by === 'orchestrator').sort((a, b) => a.id - b.id).slice(0, want);
    if (mine.length) return { tasks: mine.map((t) => ({ ...t, resume: true })), skipped: [], state: 'resume', why: `resuming ${mine.length} in-flight task(s)` };
  }
  const slots = Math.min(want, wip - inflight.length);
  if (slots <= 0) return { tasks: [], skipped: [], state: 'wip', why: `WIP limit: ${inflight.length} task(s) already in flight (limit ${wip})` };
  const chosen = []; const skipped = [];
  for (const t of readyOrder(rows)) {
    if (chosen.length >= slots) break;
    const busy = [...inflight, ...chosen].find((o) => pathsClash(t.paths, o.paths));
    if (busy) { skipped.push({ id: t.id, why: `paths clash with task ${busy.id}` }); continue; }
    chosen.push(t);
  }
  const state = chosen.length ? 'picked' : (skipped.length ? 'clash' : 'empty');
  const why = { picked: `${chosen.length} picked`, clash: 'every ready task clashes with work in flight', empty: 'nothing is ready' }[state];
  return { tasks: chosen, skipped, state, why };
}

export function roadmap(rows) {
  const ms = rows.filter((t) => t.kind === 'milestone').sort((a, b) => a.order - b.order || a.id - b.id);
  return ms.map((m) => {
    const ts = rows.filter((t) => t.kind === 'task' && t.milestone === m.id);
    const count = (f) => ts.filter(f).length;
    return { id: m.id, title: m.title, status: m.status, order: m.order, file: m.file, waits: m.waits, public_title: m.public_title,
      tasks: { total: ts.length, done: count((t) => t.status === 'done'), ready: count((t) => t.ready), inflight: count((t) => t.status === 'doing' || t.status === 'review'),
        jordan: count((t) => t.waits.some((w) => w.startsWith('jordan'))), open: count((t) => !DONE.has(t.status)) } };
  });
}
/** The first open milestone, in roadmap order, that is not waiting on anything. */
export function roadmapNext(rows) {
  const all = roadmap(rows).filter((m) => !DONE.has(m.status));
  return { next: all.find((m) => m.waits.length === 0) || null, waiting: all.filter((m) => m.waits.length).map((m) => ({ id: m.id, waits: m.waits })) };
}

export function checkStore(store) {
  const problems = store.bad.map((b) => `${path.basename(b.file)}: ${b.error}`);
  const rows = analyze(store); const byId = new Map(rows.map((t) => [t.id, t]));
  for (const t of rows) {
    for (const w of t.waits) if (/does not exist|malformed/.test(w)) problems.push(`${t.id}: depends on ${w}`);
    if (t.kind === 'task' && t.milestone && byId.get(t.milestone)?.kind === 'task') problems.push(`${t.id}: milestone ${t.milestone} is a task, not a milestone`);
  }
  // cycles: a depth-first walk over task-number dependencies
  const state = new Map(); const cycles = [];
  const walk = (id, trail) => {
    if (state.get(id) === 2) return; if (state.get(id) === 1) { cycles.push([...trail.slice(trail.indexOf(id)), id].join(' -> ')); return; }
    state.set(id, 1); const t = byId.get(id);
    for (const d of t ? t.depends.filter((x) => typeof x === 'number') : []) walk(d, [...trail, id]);
    state.set(id, 2);
  };
  for (const t of rows) walk(t.id, []);
  for (const c of cycles) problems.push(`dependency cycle: ${c}`);
  return problems;
}

// ---- pause and usage --------------------------------------------------------------------------------------------------------------
const pauseFile = (dir) => path.join(dir, '.orchestrator.json');
export function readPause(dir) {
  try { const j = JSON.parse(fs.readFileSync(pauseFile(dir), 'utf8')); return { paused: !!j.paused, reason: j.reason || '', at: j.at || '' }; } catch { return { paused: false, reason: '', at: '' }; }
}
export function writePause(dir, paused, reason = '', at = new Date().toISOString()) {
  fs.mkdirSync(dir, { recursive: true });
  writeAtomic(pauseFile(dir), `${JSON.stringify({ paused, reason, at }, null, 2)}\n`);
}
// ---- one orchestrator at a time: a lock file with a heartbeat (every pick, check and merge beats it) ------------------------------
const lockFile = (dir) => path.join(dir, '.orchestrator.lock');
export const LOCK_STALE_MINUTES = 90;
export function readLock(dir) {
  const f = lockFile(dir); if (!fs.existsSync(f)) return null;
  try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); if (typeof j.run === 'string' && j.run) return { run: j.run, at: j.at || '', heartbeat: j.heartbeat || j.at || '' }; } catch { /* unreadable: judged by its file time below */ }
  return { run: '', at: '', heartbeat: fs.statSync(f).mtime.toISOString() };
}
const ageMin = (iso, now) => { const t = Date.parse(iso); return Number.isFinite(t) ? (now.getTime() - t) / 60000 : Infinity; };
const lockText = (run, at, beat) => `${JSON.stringify({ run, at, heartbeat: beat }, null, 2)}\n`;
/** Take the lock (exclusive create). A lock whose heartbeat is older than staleMinutes is a run that died (usage cap, closed session): taken over, and said so. */
export function lockAcquire(dir, { now = new Date(), staleMinutes = LOCK_STALE_MINUTES } = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const run = `${now.toISOString().replace(/\D/g, '').slice(0, 14)}-${Math.random().toString(36).slice(2, 8)}`;
  const text = lockText(run, now.toISOString(), now.toISOString());
  try { fs.writeFileSync(lockFile(dir), text, { encoding: 'utf8', flag: 'wx' }); return { ok: true, run, tookOver: '' }; } catch (e) { if (e.code !== 'EEXIST') throw e; }
  const cur = readLock(dir); const age = ageMin(cur.heartbeat, now);
  if (age < staleMinutes) return { ok: false, run: '', why: `another orchestrator is running (run ${cur.run || 'unknown'}, last heartbeat ${Math.round(age)} min ago); if none is, run: node tools/task.mjs lock release --force` };
  writeAtomic(lockFile(dir), text);
  return { ok: true, run, tookOver: `took over a stale lock (run ${cur.run || 'unknown'}, silent for ${Math.round(age)} min)` };
}
export function lockHeartbeat(dir, run, { now = new Date() } = {}) {
  const cur = readLock(dir);
  if (!cur) return { ok: false, why: `no orchestrator lock: run ${run} lost it` };
  if (cur.run !== run) return { ok: false, why: `the lock belongs to run ${cur.run || 'unknown'}, not ${run}` };
  writeAtomic(lockFile(dir), lockText(run, cur.at, now.toISOString()));
  return { ok: true, why: 'heartbeat' };
}
export function lockRelease(dir, run, force = false) {
  const cur = readLock(dir); if (!cur) return { ok: true, why: 'no lock' };
  if (!force && cur.run !== run) return { ok: false, why: `the lock belongs to run ${cur.run || 'unknown'}, not ${run || '(none given)'}` };
  fs.rmSync(lockFile(dir), { force: true }); return { ok: true, why: `released run ${cur.run || 'unknown'}` };
}

/** Jordan's rule: the weekly limit at 95% stops; a full 5-hour window only pauses (a rerun after the reset continues). */
export function usageVerdict(file, { weeklyStop = 0.95, fiveHourPause = 1.0 } = {}) {
  let u;
  try { u = JSON.parse(fs.readFileSync(file, 'utf8')).claude; } catch { return { verdict: 'go', why: `usage unknown: ${file} not readable (not a reason to stop)`, fiveHour: null, sevenDay: null }; }
  const f = u?.fiveHour?.used; const s = u?.sevenDay?.used;
  const base = { fiveHour: f ?? null, sevenDay: s ?? null, at: u?.at ?? null };
  if (typeof s === 'number' && s >= weeklyStop) return { ...base, verdict: 'stop', why: `weekly usage ${Math.round(s * 100)}% >= ${Math.round(weeklyStop * 100)}%: stop until ${u.sevenDay.resetsAt || 'the weekly reset'}` };
  if (typeof f === 'number' && f >= fiveHourPause) return { ...base, verdict: 'pause', why: `5-hour window ${Math.round(f * 100)}% used: pause; rerun after ${u.fiveHour.resetsAt || 'the reset'}` };
  return { ...base, verdict: 'go', why: `5-hour ${f == null ? '?' : Math.round(f * 100)}%, weekly ${s == null ? '?' : Math.round(s * 100)}%` };
}

// ---- writing ----------------------------------------------------------------------------------------------------------------------
function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text, 'utf8'); fs.renameSync(tmp, file);
}
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40).replace(/-+$/, '') || 'task';
/** A new numbered file; the number is one past the highest in use (malformed files count), created exclusively so two writers never share one. */
export function createTask(dir, data, body = '') {
  fs.mkdirSync(dir, { recursive: true });
  for (let tries = 0; tries < 50; tries++) {
    const used = fs.readdirSync(dir).map((n) => FILE_RE.exec(n)).filter(Boolean).map((m) => Number(m[1]));
    const id = (used.length ? Math.max(...used) : 0) + 1;
    const n = normalize(data, id); if (!n.ok) throw new Error(n.error);
    const file = path.join(dir, `${String(id).padStart(4, '0')}-${slug(data.title)}.md`);
    try { fs.writeFileSync(file, formatTask(data, body), { encoding: 'utf8', flag: 'wx' }); return { id, file }; } catch (e) { if (e.code !== 'EEXIST') throw e; }
  }
  throw new Error('could not get a free task number after 50 tries');
}
const STRING_KEYS = ['title', 'public_title', 'merged', 'head', 'branch', 'run', 'claimed_by'];
/** Apply "key=value", "key+=item" and "key=" (remove) edits to one task, validated before anything is written. */
export function setFields(store, id, edits) {
  const t = store.tasks.find((x) => x.id === id);
  if (!t) { const b = store.bad.find((x) => x.id === id); throw new Error(b ? `task ${id} is malformed (${b.error}); fix the file by hand` : `task ${id} not found`); }
  const p = parseFrontMatter(fs.readFileSync(t.file, 'utf8')); if (!p.ok) throw new Error(p.error);
  const data = { ...p.data };
  for (const e of edits) {
    const m = /^([a-z][a-z0-9_]*)(\+?=)(.*)$/s.exec(e);
    if (!m) throw new Error(`edit "${e}" is not key=value, key+=item or key=`);
    const [, k, op, raw] = m;
    if (k === 'id') throw new Error('the number is the file name; it cannot be set');
    if (op === '=' && raw === '') { if (k === 'title') throw new Error('title cannot be removed'); delete data[k]; continue; }
    const v = parseValue(raw); if (v.error) throw new Error(`${k}: ${v.error}`);
    if (STRING_KEYS.includes(k) && typeof v.value !== 'string' && !Array.isArray(v.value)) v.value = raw.trim(); // a merge sha of only digits stays text, leading zeros too
    if (op === '+=') { const cur = data[k] === undefined ? [] : (Array.isArray(data[k]) ? data[k] : [data[k]]); const add = Array.isArray(v.value) ? v.value : [v.value]; data[k] = [...cur, ...add.filter((x) => !cur.includes(x))]; }
    else data[k] = v.value;
  }
  const n = normalize(data, id); if (!n.ok) throw new Error(n.error);
  writeAtomic(t.file, formatTask(data, p.body));
  return { id, file: t.file };
}

/** Append one dated line under "## Log" at the end of the body (private notes: why a task waits, what a run saw). */
export function addNote(store, id, text, at = new Date().toISOString()) {
  const t = store.tasks.find((x) => x.id === id); if (!t) throw new Error(`task ${id} not found`);
  const p = parseFrontMatter(fs.readFileSync(t.file, 'utf8')); if (!p.ok) throw new Error(p.error);
  const line = `- ${at.slice(0, 16).replace('T', ' ')} ${text.replace(/\s+/g, ' ')}`;
  const body = p.body.replace(/\s+$/, '');
  const next = /(^|\n)## Log\n/.test(body) ? `${body}\n${line}\n` : `${body}${body ? '\n\n' : ''}## Log\n${line}\n`;
  writeAtomic(t.file, formatTask(p.data, next));
  return { id, file: t.file };
}

// ---- command line -----------------------------------------------------------------------------------------------------------------
const VALUE_FLAGS = ['--store', '--status', '--kind', '--lanes', '--reason', '--title', '--paths', '--depends', '--milestone', '--priority', '--order', '--public-title', '--body', '--body-file', '--wip', '--text', '--run', '--stale-minutes'];
export function parseArgs(argv) {
  const flags = {}; const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (VALUE_FLAGS.includes(a)) { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); flags[a.slice(2)] = argv[++i]; }
    else if (a.startsWith('--')) flags[a.slice(2)] = true;
    else pos.push(a);
  }
  return { flags, pos };
}
const listOf = (s) => String(s).split(',').map((x) => x.trim()).filter(Boolean);
const pub = (t) => { const { body, ...rest } = t; return rest; }; // JSON output never carries the body; `show` is the only way to read it
const row = (t) => `${String(t.id).padStart(4)}  ${t.kind === 'milestone' ? 'M' : 'T'}  ${t.status.padEnd(7)}  p${t.priority}  ${t.ready ? 'READY'.padEnd(24) : (t.waits.length ? `waits: ${t.waits.join(', ')}`.slice(0, 24).padEnd(24) : ''.padEnd(24))}  ${t.title}`;

/** @param {string[]} argv @param {{ say?: (s: string) => void, env?: any, home?: string }} [io] */
export function main(argv, io = {}) {
  const say = io.say || ((s) => process.stdout.write(`${s}\n`)); const env = io.env || process.env; const home = io.home || os.homedir();
  let a;
  try { a = parseArgs(argv); } catch (e) { say(`task: ${e.message}`); return 2; }
  const { flags, pos } = a; const [cmd, ...rest] = pos; const json = !!flags.json;
  const out = (obj, text) => { say(json ? JSON.stringify({ v: 1, ...obj }) : text); };
  let where;
  try { where = resolveStore(/** @type {string} */ (flags.store || ''), env, home); } catch (e) { say(`task: ${e.message}`); return 2; }
  const dir = where.dir;
  const num = (s) => { const n = Number(String(s).replace(/^#/, '')); return Number.isInteger(n) && n > 0 ? n : null; };
  const shape = (t, status) => ({ id: t.id, title: t.title, public_title: t.public_title, paths: t.paths, priority: t.priority, milestone: t.milestone, status, resume: !!t.resume, pr: t.pr ?? null, branch: t.branch ?? null, rounds: t.rounds ?? 0 });
  const claimEdits = (run) => ['status=doing', 'claimed_by=orchestrator', ...(run ? [`run=${run}`] : [])];
  // pause, then usage, then the lock (--run new takes it; --run <id> must still hold it and beats it). Returns { stop: [json, text] } or the run.
  const preflight = () => {
    const pause = readPause(dir); const usage = usageVerdict(path.join(stateDir(env, home), 'plan-usage.json'));
    if (pause.paused) return { stop: [{ paused: true, stop: '', reason: pause.reason, state: 'paused', usage, tasks: [] }, `PAUSED: ${pause.reason || 'no reason given'} (node tools/task.mjs resume)`] };
    if (usage.verdict !== 'go') return { stop: [{ paused: false, stop: usage.verdict, reason: usage.why, state: usage.verdict, usage, tasks: [] }, `${usage.verdict.toUpperCase()}: ${usage.why}`] };
    if (flags.run === undefined) return { stop: null, run: '', took: '', usage };
    if (typeof flags.run !== 'string') return { stop: [{ paused: false, stop: 'stop', reason: '--run needs "new" or a run id', state: 'locked', usage, tasks: [] }, 'task: --run needs "new" or a run id'] };
    if (flags.run === 'new') {
      const l = lockAcquire(dir); if (!l.ok) return { stop: [{ paused: false, stop: 'stop', reason: l.why, state: 'locked', usage, tasks: [] }, `LOCKED: ${l.why}`] };
      return { stop: null, run: l.run, took: l.tookOver, usage };
    }
    const h = lockHeartbeat(dir, flags.run); if (!h.ok) return { stop: [{ paused: false, stop: 'stop', reason: h.why, state: 'locked', usage, tasks: [] }, `LOCKED: ${h.why}`] };
    return { stop: null, run: flags.run, took: '', usage };
  };
  try {
    switch (cmd) {
      case 'where': out({ store: dir, source: where.source, exists: fs.existsSync(dir) }, `${dir}  (from ${where.source}${fs.existsSync(dir) ? '' : '; does not exist yet'})`); return 0;
      case 'list': case undefined: {
        const store = loadStore(dir); let rows = analyze(store);
        if (flags.status) rows = rows.filter((t) => t.status === flags.status);
        if (flags.kind) rows = rows.filter((t) => t.kind === flags.kind);
        if (flags.ready) rows = rows.filter((t) => t.ready);
        out({ store: dir, tasks: rows.map(pub), malformed: store.bad },
          [store.missing ? `no store yet at ${dir}` : `${dir}: ${store.tasks.length} file(s)`, ...rows.map(row), ...store.bad.map((b) => `MALFORMED ${path.basename(b.file)}: ${b.error}`)].join('\n'));
        return 0;
      }
      case 'show': {
        const id = num(rest[0]); if (!id) { say('task: show needs a task number'); return 2; }
        const store = loadStore(dir); const t = analyze(store).find((x) => x.id === id);
        if (!t) { const b = store.bad.find((x) => x.id === id); say(b ? `task ${id} is malformed: ${b.error}` : `task ${id} not found in ${dir}`); return 1; }
        out({ task: { ...pub(t), body: t.body } }, fs.readFileSync(t.file, 'utf8').trimEnd()); return 0;
      }
      case 'next': {
        const lanes = flags.lanes === undefined ? 1 : Number(flags.lanes);
        if (!Number.isInteger(lanes) || lanes < 1) { say('task: --lanes must be a whole number of 1 or more'); return 2; }
        const wip = flags.wip === undefined ? WIP_LIMIT : Number(flags.wip);
        const capped = lanes > wip ? `--lanes ${lanes} is above the WIP limit; using ${wip}` : '';
        const pf = preflight(); if (pf.stop) { out(pf.stop[0], pf.stop[1]); return 3; }
        const { usage, run } = pf;
        const store = loadStore(dir); const rows = analyze(store);
        const pick = pickNext(rows, { lanes, wip, resume: !!flags.resume });
        if (flags.claim) for (const t of pick.tasks.filter((x) => !x.resume)) setFields(store, t.id, claimEdits(run));
        const tasks = pick.tasks.map((t) => shape(t, flags.claim && !t.resume ? 'doing' : t.status));
        out({ paused: false, stop: '', reason: '', run, tookOver: pf.took, usage, tasks, skipped: pick.skipped, state: pick.state, why: pick.why, note: capped, malformed: store.bad.length },
          [capped, `${pick.why} (usage: ${usage.why})`, ...tasks.map((t) => `${t.resume ? 'RESUME' : 'NEXT'} ${t.id}: ${t.title}  [${t.paths.join(', ') || 'no paths: runs alone'}]`), ...pick.skipped.map((s) => `  skipped ${s.id}: ${s.why}`)].filter(Boolean).join('\n'));
        return 0;
      }
      case 'start': { // one task (/task-start): the same pause, usage and lock checks as next, then claim it or resume it
        const id = num(rest[0]); if (!id) { say('task: start needs a task number'); return 2; }
        const pf = preflight(); if (pf.stop) { out(pf.stop[0], pf.stop[1]); return 3; }
        const store = loadStore(dir); const t = analyze(store).find((x) => x.id === id);
        let tasks = []; let state = 'empty'; let why;
        if (!t) { const b = store.bad.find((x) => x.id === id); why = b ? `task ${id} is malformed: ${b.error}` : `task ${id} not found in ${dir}`; }
        else if (t.kind !== 'task') why = `${id} is a milestone, not a task`;
        else if (t.status === 'doing' || t.status === 'review') { tasks = [{ ...shape(t, t.status), resume: true }]; state = 'resume'; why = `resuming task ${id} (${t.status})`; }
        else if (t.ready) { setFields(store, id, claimEdits(pf.run)); tasks = [shape(t, 'doing')]; state = 'picked'; why = `claimed task ${id}`; }
        else why = `task ${id} is ${t.status}${t.waits.length ? `, waits on: ${t.waits.join(', ')}` : ''}`;
        out({ paused: false, stop: '', reason: '', run: pf.run, tookOver: pf.took, usage: pf.usage, tasks, state, why }, `${why}${pf.run ? ` (run ${pf.run})` : ''}`);
        return tasks.length ? 0 : 1;
      }
      case 'lock': {
        const sub = rest[0]; const stale = flags['stale-minutes'] === undefined ? LOCK_STALE_MINUTES : Number(flags['stale-minutes']);
        if (!Number.isFinite(stale) || stale <= 0) { say('task: --stale-minutes must be a number above 0'); return 2; }
        const run = typeof flags.run === 'string' ? flags.run : '';
        if (sub === 'acquire') { const l = lockAcquire(dir, { staleMinutes: stale }); out(l, l.ok ? `locked: run ${l.run}${l.tookOver ? ` (${l.tookOver})` : ''}` : `LOCKED: ${l.why}`); return l.ok ? 0 : 3; }
        if (sub === 'heartbeat') { if (!run) { say('task: lock heartbeat needs --run <id>'); return 2; } const h = lockHeartbeat(dir, run); out(h, h.ok ? `heartbeat: run ${run}` : `LOST: ${h.why}`); return h.ok ? 0 : 3; }
        if (sub === 'release') { if (!run && !flags.force) { say('task: lock release needs --run <id> or --force'); return 2; } const r = lockRelease(dir, run, !!flags.force); out(r, r.ok ? r.why : `NOT RELEASED: ${r.why}`); return r.ok ? 0 : 1; }
        if (sub === 'status') { const l = readLock(dir); out({ lock: l }, l ? `locked by run ${l.run || 'unknown'}, last heartbeat ${l.heartbeat}` : 'not locked'); return 0; }
        say('task: lock acquire | heartbeat --run <id> | release --run <id> | release --force | status'); return 2;
      }
      case 'roadmap': {
        const rows = analyze(loadStore(dir));
        if (flags.next) { const r = roadmapNext(rows); out(r, r.next ? `NEXT milestone ${r.next.id}: ${r.next.title} (${r.next.tasks.done}/${r.next.tasks.total} tasks done, ${r.next.tasks.ready} ready)\n  file: ${r.next.file}` : `no open milestone is free to start${r.waiting.length ? `; waiting: ${r.waiting.map((w) => `${w.id} on ${w.waits.join(', ')}`).join('; ')}` : ''}`); return 0; }
        const ms = roadmap(rows);
        out({ milestones: ms }, ms.length ? ms.map((m) => `${String(m.id).padStart(4)}  ${m.status.padEnd(7)}  ${m.tasks.done}/${m.tasks.total} done, ${m.tasks.ready} ready, ${m.tasks.inflight} in flight${m.tasks.jordan ? `, ${m.tasks.jordan} need Jordan` : ''}${m.waits.length ? `  waits: ${m.waits.join(', ')}` : ''}  ${m.title}`).join('\n') : 'no milestones yet (node tools/task.mjs new --kind milestone --title ...)');
        return 0;
      }
      case 'new': {
        if (typeof flags.title !== 'string') { say('task: new needs --title'); return 2; }
        const data = { title: flags.title };
        if (flags.kind) data.kind = flags.kind; if (flags.status) data.status = flags.status;
        for (const k of ['priority', 'milestone', 'order']) if (flags[k] !== undefined) data[k] = Number(flags[k]);
        if (flags.paths) data.paths = listOf(flags.paths);
        if (flags.depends) data.depends = listOf(flags.depends).map((x) => (/^\d+$/.test(x) ? Number(x) : x));
        if (flags['public-title']) data.public_title = flags['public-title'];
        const body = flags['body-file'] ? fs.readFileSync(String(flags['body-file']), 'utf8') : (typeof flags.body === 'string' ? flags.body : '');
        const r = createTask(dir, data, body);
        out(r, `created ${r.id}: ${r.file}`); return 0;
      }
      case 'set': {
        const id = num(rest[0]); if (!id || rest.length < 2) { say('task: set needs a task number and at least one key=value'); return 2; }
        const r = setFields(loadStore(dir), id, rest.slice(1)); out(r, `updated ${r.id}: ${r.file}`); return 0;
      }
      case 'note': {
        const id = num(rest[0]); if (!id || typeof flags.text !== 'string' || !flags.text.trim()) { say('task: note needs a task number and --text "<line>"'); return 2; }
        const r = addNote(loadStore(dir), id, flags.text.trim()); out(r, `noted on ${r.id}: ${r.file}`); return 0;
      }
      case 'pause': {
        if (typeof flags.reason !== 'string' || !flags.reason.trim()) { say('task: pause needs --reason "<why>"'); return 2; }
        writePause(dir, true, flags.reason.trim()); out({ paused: true, reason: flags.reason.trim() }, `paused: the orchestrator stops at its next pick (${flags.reason.trim()})`); return 0;
      }
      case 'resume': writePause(dir, false); out({ paused: false }, 'resumed: the orchestrator picks again (start it with /task-orchestrate)'); return 0;
      case 'state': { const p = readPause(dir); out(p, p.paused ? `PAUSED since ${p.at}: ${p.reason}` : 'running (not paused)'); return 0; }
      case 'usage': { const u = usageVerdict(path.join(stateDir(env, home), 'plan-usage.json')); out(u, `${u.verdict}: ${u.why}`); return 0; }
      case 'check': {
        const store = loadStore(dir); const problems = store.missing ? [`no store at ${dir}`] : checkStore(store);
        out({ ok: problems.length === 0, problems, files: store.tasks.length + store.bad.length }, problems.length ? problems.map((p) => `PROBLEM ${p}`).join('\n') : `ok: ${store.tasks.length} file(s), no problems`);
        return problems.length ? 1 : 0;
      }
      default: say(`task: unknown command ${cmd} (where, list, show, next, start, lock, roadmap, new, set, note, pause, resume, state, usage, check)`); return 2;
    }
  } catch (e) { say(`task: ${e.message}`); return 1; }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));
