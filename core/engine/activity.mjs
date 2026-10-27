// @ts-check
// Owns the engine's activities: the contract call {wo, name, args, idempotencyKey, timeoutSec, maxMB} -> {ok, exit, out, proof}
// (core/contracts/activity*.schema.json, v 1.0), run at most once per idempotency key, and today's Yard stations wrapped as activities
// through scripts/run-bounded.ps1. The stations are never edited; they are only started, read only, the way the Yard starts them.
// Called by core/engine/driver.mjs (both engines: the fake and the Temporal worker) and tests/core/engine/test-activity.mjs.
//   once(activity, impl, store)        run impl unless the store already holds a result for the key (a crash after the effect replays it)
//   stationActivities({ ... })         name -> impl for the stations below; a station that changes things runs only when mode is 'new'
import fs from 'node:fs'; import path from 'node:path'; import crypto from 'node:crypto'; import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { validate } from '../contracts/validate.mjs';

export const V = '1.0';
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const OUT_CAP = 65536;                                         // activity-result.out maxLength
export const DEFAULTS = { timeoutSec: 900, maxMB: 3000 };

/** @typedef {{ v: string, wo: string, name: string, args: Record<string, any>, idempotencyKey: string, timeoutSec: number, maxMB: number }} Activity */
/** @typedef {{ v: string, ok: boolean, exit: number, out: string, proof: string|null }} Result */
/** @typedef {(a: Activity) => Promise<Result>} Impl */
/** @typedef {{ get: (key: string) => Result|null, put: (key: string, r: Result) => void, intent: (key: string, info: any) => void, intentOf: (key: string) => any }} Store */
/** A probe answers, after a crash mid-run, whether a step that changes things already took effect (from the outside world, not memory). */
/** @typedef {(a: Activity) => Promise<{ state: 'done'|'not-done'|'unknown', why: string }>} Probe */

const must = (name, doc) => { const r = validate(name, doc); if (!r.ok) throw new Error(`${name} is not valid: ${r.errors.join('; ')}`); return doc; };

// Plain values only (the contract refuses nested objects); null-valued args are left out so stations see only what was given.
/** @returns {Activity} */
export function makeActivity({ wo, name, args = {}, idempotencyKey, timeoutSec = DEFAULTS.timeoutSec, maxMB = DEFAULTS.maxMB }) {
  const clean = Object.fromEntries(Object.entries(args).filter(([, x]) => x !== null && x !== undefined));
  return must('activity', { v: V, wo, name, args: clean, idempotencyKey, timeoutSec, maxMB });
}

/** @returns {Result} */
export function result(exit, out = '', proof = null) {
  const text = String(out ?? '');
  const tail = text.length > OUT_CAP ? text.slice(text.length - OUT_CAP) : text;
  return must('activity-result', { v: V, ok: exit === 0, exit, out: tail, proof: proof || null });
}

/** @returns {Store} */
export function memoryStore() {
  const m = new Map();
  return { get: (k) => m.get(k) ?? null, put: (k, r) => { m.set(k, r); }, intent: (k, i) => { m.set(`${k}#intent`, i); }, intentOf: (k) => m.get(`${k}#intent`) ?? null };
}

// One file per key, named by its sha256 (keys may hold any characters), written to a temp name then renamed: a crash leaves the old
// state or the new one, never half a result.
/** @param {string} dir @returns {Store} */
export function fileStore(dir) {
  const file = (k) => path.join(dir, `${crypto.createHash('sha256').update(k).digest('hex').slice(0, 32)}.json`);
  const read = (k) => { try { const j = JSON.parse(fs.readFileSync(file(k), 'utf8')); return j.key === k ? j.result : null; } catch { return null; } };
  const write = (k, r) => {
    fs.mkdirSync(dir, { recursive: true });
    const tmp = `${file(k)}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({ key: k, result: r }));
    fs.renameSync(tmp, file(k));
  };
  return { get: read, put: write, intent: (k, i) => write(`${k}#intent`, i), intentOf: (k) => read(`${k}#intent`) };
}

/**
 * Run an activity once per idempotency key. A stored result is handed back with replayed: true and impl is not called again.
 * A step that changes things (impl.effectful) also writes an intent record before it starts. If a crash left an intent and no result,
 * the step may or may not have taken effect, so it is never simply rerun: impl.probe looks at the outside world first.
 *   done -> recorded as done (exit 0), not run again;  not-done -> run again (the effect never happened);
 *   unknown, or no probe -> held for Jordan (exit 10, a stuck card), never a blind second run.
 * hooks.afterIntent runs after the intent is written; hooks.afterStore after the result is stored (the kill tests stop the process there).
 * @param {Activity} a @param {Impl & { effectful?: boolean, probe?: Probe }} impl @param {Store} store
 * @param {{ afterStore?: (r: Result) => void, afterIntent?: () => void }} [hooks]
 */
export async function once(a, impl, store, hooks = {}) {
  const had = store.get(a.idempotencyKey);
  if (had) return { result: had, replayed: true };
  if (impl.effectful) {
    const before = store.intentOf(a.idempotencyKey);
    if (before) {
      let p;
      try { p = impl.probe ? await impl.probe(a) : { state: 'unknown', why: 'this step has no probe' }; } catch (err) { p = { state: 'unknown', why: `the probe failed: ${/** @type {Error} */ (err).message}` }; }
      if (p.state !== 'not-done') {
        const r = p.state === 'done'
          ? result(0, `${a.name} was interrupted by a crash, and it had already taken effect: ${p.why}`, `probe after a crash (${a.idempotencyKey})`)
          : result(10, `${a.name} was interrupted by a crash and whether it took effect is unknown (${p.why}); held, not run twice`);
        store.put(a.idempotencyKey, r);
        return { result: r, replayed: false, recovered: p.state };
      }
    }
    store.intent(a.idempotencyKey, { at: new Date().toISOString(), pid: process.pid });
    if (hooks.afterIntent) hooks.afterIntent();
  }
  let r;
  try { r = await impl(a); } catch (err) { r = result(1, `activity ${a.name} threw: ${/** @type {Error} */ (err).message}`); }
  must('activity-result', r);
  store.put(a.idempotencyKey, r);
  if (hooks.afterStore) hooks.afterStore(r);
  return { result: r, replayed: false };
}

// The Yard stations the engine may call (kitchen/stations/<name>.ps1). params: the station's own parameters this wrapper passes;
// readOnly: the station only reads (safe in shadow). Anything else changes things and runs only when the engine switch is 'new'.
export const STATIONS = {
  'ci-wait': { params: ['Repo'], readOnly: true },
  freshen: { params: ['Repo'], readOnly: false },
  merge: { params: ['Repo'], readOnly: false, needsDecision: true },
  verify: { params: ['Repo'], readOnly: false },
};

// PowerShell single-quoted literal: every quote character PowerShell accepts (' and the curly ones) is doubled, so no value can end
// the string early. Values are never put inside double quotes, where $ and backtick would be read.
export const psQuote = (s) => "'" + String(s).replace(/['‘’‚‛]/g, (q) => q + q) + "'";

// The command line for one station run, through run-bounded (time limit + memory cap on the whole process tree). -Command, not -File:
// with -File, "-ScriptArgs -Repo x" reads -Repo as run-bounded's own (missing) parameter, so the station's named arguments go in as an
// array literal of quoted strings. The station's exit code comes back through $LASTEXITCODE.
export function stationCommand(a, { root = repoRoot, repoPath = (/** @type {string} */ r) => r } = {}) {
  const spec = STATIONS[a.name];
  const pass = spec.params.filter((p) => a.args[p] !== undefined).flatMap((p) => [`-${p}`, String(p === 'Repo' ? repoPath(a.args[p]) : a.args[p])]);
  const script = [`& ${psQuote(path.join(root, 'scripts', 'run-bounded.ps1'))}`, '-Script', psQuote(path.join(root, 'kitchen', 'stations', `${a.name}.ps1`)),
    '-TimeoutSeconds', String(a.timeoutSec), '-MaxMB', String(a.maxMB), ...(pass.length ? ['-ScriptArgs', `@(${pass.map(psQuote).join(',')})`] : [])].join(' ');
  return ['-NoProfile', '-NonInteractive', '-Command', `${script}; exit $LASTEXITCODE`];
}

/** Run one process; resolve with its exit code and the tail of stdout+stderr. Never rejects. */
export function runProcess(exe, argv, { env = process.env, cwd = repoRoot, timeoutSec = 900 } = {}) {
  return new Promise((resolve) => {
    let out = ''; let done = false;
    const child = spawn(exe, argv, { env, cwd, windowsHide: true });
    const add = (b) => { out += b.toString(); if (out.length > OUT_CAP * 2) out = out.slice(out.length - OUT_CAP); };
    // run-bounded enforces the real limit; this outer guard only catches a wrapper that never returns (limit + 60 s).
    const guard = setTimeout(() => { if (!done) { child.kill(); } }, (timeoutSec + 60) * 1000);
    child.stdout.on('data', add); child.stderr.on('data', add);
    child.on('error', (err) => { done = true; clearTimeout(guard); resolve({ exit: 127, out: `could not start ${exe}: ${err.message}` }); });
    child.on('close', (code) => { if (done) return; done = true; clearTimeout(guard); resolve({ exit: code === null ? 124 : code, out }); });
  });
}

/**
 * name -> impl for every station in STATIONS. Each run sets KITCHEN_JOB to the WO's Yard alias (stations read their job record) and
 * BRAIN_KITCHEN to the given state folder (tests pass a scratch copy). Refusals are results with a reason, never a throw:
 * exit 127 (not wired: no alias, or a station that changes things while mode is not 'new'), exit 2 (merge without a decision id, or
 * one that answered() does not confirm as Jordan's Yes on this WO: the default confirms nothing, so a merge needs the caller's check).
 * Stations take -Repo as a local checkout path: repoPath(owner/name) gives it; no path for the repo is exit 127, never a guess.
 * Stations that change things are effectful (once() writes an intent first); probes[name] checks after a crash whether one already took
 * effect. merge's default probe asks GitHub whether the PR is merged (ghMergeProbe); freshen and verify have none, so a crash mid-run
 * holds the order for Jordan instead of running them twice.
 * @param {{ mode?: 'shadow'|'new', kitchen?: string, root?: string, pwsh?: string, repoPath?: (repo: string) => string|null, run?: typeof runProcess,
 *   answered?: (decision: string, wo: string) => boolean, probes?: Record<string, Probe> }} o
 * @returns {Record<string, Impl>}
 */
export function stationActivities({ mode = 'shadow', kitchen = '', root = repoRoot, pwsh = 'pwsh', repoPath = () => null, run = runProcess, answered = () => false, probes } = {}) {
  const probeOf = probes || { merge: ghMergeProbe(run) };
  const impl = (name) => async (/** @type {Activity} */ a) => {
    const spec = STATIONS[name];
    if (!spec.readOnly && mode !== 'new') return result(127, `${name} changes things; while the engine switch is ${mode} only the Yard runs it`);
    if (spec.needsDecision && !/^D-[0-9]+$/.test(String(a.args.Decision || ''))) return result(2, `${name} refused: no answered decision id in args.Decision`);
    if (spec.needsDecision && !answered(String(a.args.Decision), a.wo)) return result(2, `${name} refused: ${a.args.Decision} is not a Yes from Jordan on ${a.wo} in the event log`);
    if (!/^J[0-9]+$/.test(String(a.args.Alias || ''))) return result(127, `${name} needs the WO's Yard job alias (J<n>) for KITCHEN_JOB; ${a.wo} has none yet`);
    const checkout = spec.params.includes('Repo') && a.args.Repo !== undefined ? repoPath(String(a.args.Repo)) : '';
    if (checkout === null || checkout === undefined) return result(127, `${name} needs a local checkout for ${a.args.Repo}; none is configured (worker --repos)`);
    const env = { ...process.env, KITCHEN_JOB: String(a.args.Alias), ...(kitchen ? { BRAIN_KITCHEN: kitchen } : {}), ...(spec.needsDecision ? { KITCHEN_APPROVED: '1' } : {}) };
    const r = await run(pwsh, stationCommand(a, { root, repoPath: () => String(checkout) }), { env, cwd: root, timeoutSec: a.timeoutSec });
    return result(r.exit, r.out, `kitchen/stations/${name}.ps1 exit ${r.exit} (${a.idempotencyKey})`);
  };
  return Object.fromEntries(Object.keys(STATIONS).map((n) => {
    const fn = /** @type {any} */ (impl(n));
    fn.effectful = !STATIONS[n].readOnly;
    if (probeOf[n]) fn.probe = probeOf[n];
    return [n, fn];
  }));
}

/**
 * merge's probe: is the PR merged on GitHub? (gh pr view <n> --repo <owner/name> --json state). MERGED = done; OPEN or CLOSED = not
 * done (the merge station starts from GitHub's main, so running it again is safe); anything else = unknown.
 * @returns {Probe}
 */
export function ghMergeProbe(run = runProcess, gh = 'gh') {
  return async (a) => {
    const m = /^[a-z0-9][a-z0-9._-]*#([0-9]+)$/.exec(String(a.args.Pr || ''));
    if (!m || !/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+$/.test(String(a.args.Repo || ''))) return { state: 'unknown', why: 'no PR number or owner/name repo to look up' };
    const r = await run(gh, ['pr', 'view', m[1], '--repo', String(a.args.Repo), '--json', 'state', '-q', '.state'], { timeoutSec: 60 });
    const state = String(r.out || '').trim();
    if (r.exit !== 0) return { state: 'unknown', why: `gh pr view exited ${r.exit}` };
    if (state === 'MERGED') return { state: 'done', why: `${a.args.Pr} is merged on GitHub` };
    if (state === 'OPEN' || state === 'CLOSED') return { state: 'not-done', why: `${a.args.Pr} is ${state.toLowerCase()} on GitHub` };
    return { state: 'unknown', why: `gh said "${state.slice(0, 40)}"` };
  };
}
