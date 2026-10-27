// Owns the Handover queue (our own merge queue): test a PR merged onto the latest main, then, only on Jordan's yes, move main forward to that tested commit.
// Called by the engine (lane L2) one PR at a time per repo, behind flag ship.merge-queue; tests/core/ship/test-queue.mjs; and by hand for a dry run (usage below).
//   node core/ship/queue.mjs --dir <scratch clone> --branch <pr branch> [--base main] [--remote origin] [--pr tide#30] [--test '["node","tests/x.mjs"]']
// The command line only ever dry-runs. Landing (landPr with land: true, from the engine) reads every permission from files, never from
// the caller: the upgrade switch ship.queue = new in this repo's kitchen/kitchen.json; flag ship.merge-queue on (this repo's flags.json and
// the flag.set events in <state>\tide.db); in the same event store, Jordan's "Yes" to a merge card that names this PR, given for this
// exact head sha, and a verifier's review.verdict "ship" on that head by a reviewer who is not the builder. Then main must be unmoved
// since the test, and the push is a fast-forward, never forced. scripts/merge-pr.ps1 and kitchen/train.ps1 stay the merge path until then.
// @ts-check
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath, pathToFileURL } from 'node:url';
import { git, conflictedFiles, OWNER_NOREPLY } from './git.mjs';
import { checkIdentity } from './freshen-pr.mjs';
import { isOn, readFlags, foldFlagEvents } from './flags.mjs';
import { toActivityResult, eventDraft } from './activity.mjs';
import { validate } from '../contracts/validate.mjs';
import { switchOf } from '../contracts/upgrade.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PR_REF = /^[a-z0-9][a-z0-9._-]*#[0-9]+$/;
const WO = /^WO-[A-Z0-9]+(-[A-Z0-9]+)*$/;

/**
 * @typedef {{ ok: boolean, status: 'ready' | 'landed' | 'held', reason: string, files: string[], merge: string | null, base: string | null,
 *   tests: string, events: object[], proof: string | null }} QueueReport
 */
/** @param {Partial<QueueReport>} r @returns {QueueReport} */
const report = (r) => ({ ok: false, status: 'held', reason: '', files: [], merge: null, base: null, tests: '', events: [], proof: null, ...r });
const tail = (s, n = 1500) => (s.length > n ? `...${s.slice(-n)}` : s);
/** The last event (by seq) that matches. @param {any[]} events @param {(e: any) => boolean} pred */
const lastOf = (events, pred) => events.filter((e) => e && pred(e)).sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0))[0];

/** The state folder: BRAIN_KITCHEN, else %LOCALAPPDATA%\brain-kitchen (the same rule as the Yard). */
export const stateDir = () => process.env.BRAIN_KITCHEN || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'brain-kitchen');

/**
 * Why Jordan's yes does not allow landing this PR at this head, or '' when it does. The yes is the latest decision.answered by jordan for
 * a decision whose decision.asked card is a merge card for this work order that names this PR (<repo>#<n>) in its ask, its answer is Yes,
 * and its proof is this exact head sha: a yes for another PR or sha never lands this one, and a new push needs a new yes.
 * @param {any[]} events @param {{ wo: string, pr: string, head: string }} t
 */
export function yesProblem(events, t) {
  const prWord = new RegExp(`(^|[^A-Za-z0-9._-])${t.pr.replace(/[.#-]/g, '\\$&')}(?![0-9])`);
  const cards = events.filter((e) => e.kind === 'decision.asked' && e.wo === t.wo && e.data && e.data.decision && e.data.decision.kind === 'merge' && prWord.test(String(e.data.decision.ask)));
  if (!cards.length) return `no merge card for ${t.wo} names ${t.pr} (a decision.asked of kind merge)`;
  const ids = new Set(cards.map((e) => e.data.decision.id));
  const yes = lastOf(events, (e) => e.kind === 'decision.answered' && e.wo === t.wo && e.data && ids.has(e.data.decision));
  if (!yes) return `Jordan has not answered the merge card for ${t.pr} (${[...ids].join(', ')})`;
  const v = validate('event', yes);
  if (!v.ok) return `the answer event does not pass the event contract: ${v.errors.slice(0, 3).join('; ')}`;
  if (yes.actor !== 'jordan') return `the answer's actor is ${yes.actor}, not jordan`;
  if (!/^yes$/i.test(yes.data.answer)) return `the latest answer is "${yes.data.answer}", not Yes`;
  if (yes.proof !== t.head) return `the yes was given for head ${String(yes.proof || 'none').slice(0, 12)}, not the PR's head ${t.head.slice(0, 12)} (a new push needs a new yes)`;
  return '';
}

/**
 * Why the review does not allow landing, or '' when it does: the latest review.verdict for this work order on this exact head says ship,
 * names its builder, and its reviewer is not the builder (CREED 6).
 * @param {any[]} events @param {{ wo: string, head: string }} t
 */
export function reviewProblem(events, t) {
  const r = lastOf(events, (e) => e.kind === 'review.verdict' && e.wo === t.wo && e.data && e.data.head === t.head);
  if (!r) return `no review.verdict for ${t.wo} on head ${t.head.slice(0, 12)}`;
  const v = validate('event', r);
  if (!v.ok) return `the review event does not pass the event contract: ${v.errors.slice(0, 3).join('; ')}`;
  if (!r.data.builder) return 'the review does not name its builder, so reviewer != builder cannot be checked';
  if (r.data.reviewer === r.data.builder) return `the reviewer ${r.data.reviewer} is the builder (CREED 6)`;
  if (r.data.verdict !== 'ship') return `the latest review on this head says ${r.data.verdict}, not ship`;
  return '';
}

/**
 * Every landing permission over what the files say: '' when all hold, else the first reason. Pure, so it is tested without a store.
 * @param {{ kitchen: any, declared: any, events: any[], wo: string, pr: string, head: string }} s
 */
export function landingProblem(s) {
  const sw = switchOf(s.kitchen, 'ship.queue');
  if (sw !== 'new') return `the upgrade switch ship.queue is ${sw}: the queue only dry-runs beside scripts/merge-pr.ps1 until it is new (Jordan's card)`;
  if (!WO.test(String(s.wo))) return 'landing needs the work order id (WO-...)';
  if (!PR_REF.test(String(s.pr))) return 'landing needs the PR as <repo>#<n>';
  if (!isOn('ship.merge-queue', { declared: s.declared, current: foldFlagEvents(s.events) })) return 'flag ship.merge-queue is off: scripts/merge-pr.ps1 stays the merge path';
  return yesProblem(s.events, s) || reviewProblem(s.events, s);
}

/**
 * The files landing reads: this repo's kitchen/kitchen.json and flags.json, and the events in <state>\tide.db (read only, through the
 * ledger's store). A file that cannot be read gives no permission: the reason is returned and nothing lands.
 * @returns {Promise<{ kitchen: any, declared: any, events: any[], error: string }>}
 */
export async function readLandingFiles() {
  let kitchen = {};
  try { kitchen = JSON.parse(fs.readFileSync(path.join(REPO, 'kitchen', 'kitchen.json'), 'utf8')); } catch (e) { return { kitchen, declared: null, events: [], error: `kitchen/kitchen.json cannot be read: ${/** @type {Error} */ (e).message}` }; }
  const declared = readFlags(path.join(REPO, 'flags.json'));
  const db = path.join(stateDir(), 'tide.db');
  try {
    const { openStore } = await import('../ledger/store.mjs');
    const store = await openStore(db, { readOnly: true });
    try { return { kitchen, declared, events: store.events(), error: '' }; } finally { store.close(); }
  } catch (e) { return { kitchen, declared, events: [], error: `the event store ${db} cannot be read: ${/** @type {Error} */ (e).message}` }; }
}

/**
 * Test a PR merged onto the latest main in a scratch clone; land it only when asked and every file-held permission allows it.
 * @param {{ dir: string, branch: string, base?: string, remote?: string, pr?: string, wo?: string | null, test?: string[] | null,
 *   timeoutSec?: number, expectEmail?: string, land?: boolean }} o
 * @returns {Promise<QueueReport>}
 */
export async function landPr(o) {
  const { dir, branch } = o;
  const base = o.base || 'main'; const remote = o.remote || 'origin'; const wo = o.wo ?? null;
  const names = [branch, base];
  if (names.some((n) => !/^[A-Za-z0-9._/-]+$/.test(n) || n.startsWith('-'))) return report({ reason: `not a branch name: ${names.join(' / ')}` });
  // landing always commits as the owner's noreply address; expectEmail only changes a dry run's expected identity
  const id = checkIdentity(dir, o.land ? OWNER_NOREPLY : o.expectEmail);
  if (!id.ok) return report({ reason: id.reason });
  const as = ['-c', `user.email=${id.email}`, '-c', `user.name=${id.name}`, '-c', 'commit.gpgsign=false'];
  const st = git(dir, ['status', '--porcelain']);
  if (!st.ok) return report({ reason: `not a git checkout: ${st.err}` });
  if (st.out) return report({ reason: 'the scratch clone has local changes; the queue works only in a clean clone' });

  // 1. the latest main and the PR head
  const f = git(dir, ['fetch', '-q', remote, `refs/heads/${base}:refs/remotes/${remote}/${base}`, `refs/heads/${branch}:refs/remotes/${remote}/${branch}`]);
  if (!f.ok) return report({ reason: `fetch failed: ${f.err}` });
  const mainHead = git(dir, ['rev-parse', `${remote}/${base}`]).out;
  const prHead = git(dir, ['rev-parse', `${remote}/${branch}`]).out;
  if (!git(dir, ['merge-base', mainHead, prHead]).ok) return report({ reason: `unrelated history: ${branch} and ${base} share no commit`, base: mainHead });

  // 2. the PR merged onto it (a conflict is held with the files named)
  const co = git(dir, ['checkout', '-q', '--detach', mainHead]);
  if (!co.ok) return report({ reason: `checkout of ${base} failed: ${co.err}`, base: mainHead });
  const m = git(dir, [...as, 'merge', '--no-ff', '--no-edit', '-m', `Handover: ${o.pr || branch} onto ${base}`, '-m', `Tested on ${base} ${mainHead.slice(0, 12)} by the Handover queue.`, prHead]);
  if (!m.ok) {
    const files = conflictedFiles(dir);
    git(dir, ['merge', '--abort']);
    return report({ reason: files.length ? `${branch} conflicts with the latest ${base} in ${files.length} file(s); held (Resurvey or a person resolves it)` : `merge failed: ${m.err}`, files, base: mainHead });
  }
  const merge = git(dir, ['rev-parse', 'HEAD']).out;
  const who = git(dir, ['log', '-1', '--format=%ae%n%ce', merge]).out.split('\n');
  if (who.some((e) => e !== id.email)) return report({ reason: `the merge commit's author or committer is not ${id.email}`, merge, base: mainHead });

  // 3. the tests on the merged result
  let tests = 'no test command given';
  if (o.test && o.test.length) {
    const t = spawnSync(o.test[0], o.test.slice(1), { cwd: dir, encoding: 'utf8', timeout: (o.timeoutSec ?? 1800) * 1000, windowsHide: true });
    const out = `${t.stdout || ''}${t.stderr || ''}`;
    if (t.error || t.status !== 0) return report({ reason: `the tests failed on ${branch} merged onto ${base} (exit ${t.status ?? 'none'}${t.error ? `, ${t.error.message}` : ''})`, merge, base: mainHead, tests: tail(out) });
    tests = tail(out, 500) || 'exit 0';
  }
  const ready = { merge, base: mainHead, tests, proof: merge };
  if (!o.land) return report({ ok: true, status: 'ready', reason: `dry run: ${branch} merges cleanly onto ${base} ${mainHead.slice(0, 7)} and its tests pass; nothing pushed`, ...ready });

  // 4. landing: every permission from the files, main unmoved, then a fast-forward push
  const files = await readLandingFiles();
  const sw = switchOf(files.kitchen, 'ship.queue');
  if (sw !== 'new') return report({ reason: landingProblem({ kitchen: files.kitchen, declared: null, events: [], wo: '', pr: '', head: '' }), ...ready });
  if (files.error) return report({ reason: `${files.error}; nothing lands`, ...ready });
  const why = landingProblem({ kitchen: files.kitchen, declared: files.declared, events: files.events, wo: String(wo), pr: String(o.pr), head: prHead });
  if (why) return report({ reason: why, ...ready });
  const again = git(dir, ['fetch', '-q', remote, `refs/heads/${base}:refs/remotes/${remote}/${base}`, `refs/heads/${branch}:refs/remotes/${remote}/${branch}`]);
  const nowMain = git(dir, ['rev-parse', `${remote}/${base}`]).out;
  const nowPr = git(dir, ['rev-parse', `${remote}/${branch}`]).out;
  if (!again.ok) return report({ reason: `fetch failed: ${again.err}`, ...ready });
  if (nowMain !== mainHead) return report({ reason: `${base} moved (${mainHead.slice(0, 7)} to ${nowMain.slice(0, 7)}) after the test; held to test again on the new ${base}`, ...ready });
  if (nowPr !== prHead) return report({ reason: `${branch} moved (${prHead.slice(0, 7)} to ${nowPr.slice(0, 7)}) after the test; the yes and the review were for the old head`, ...ready });
  const p = git(dir, ['push', '-q', remote, `${merge}:refs/heads/${base}`]);
  if (!p.ok) return report({ reason: `the push to ${base} was refused (${tail(p.err, 300)}); never forced`, ...ready });
  const yes = lastOf(files.events, (e) => e.kind === 'decision.answered' && e.wo === wo && e.proof === prHead);
  const decision = yes.data.decision;
  return report({ ok: true, status: 'landed', reason: `${base} moved forward to the tested merge ${merge.slice(0, 7)} (decision ${decision})`, ...ready,
    events: [eventDraft('merged', wo, { pr: o.pr, sha: merge, decision }, merge)] });
}

/** @param {string[]} argv @returns {Promise<number>} */
export async function main(argv) {
  /** @type {Record<string, string>} */
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i].replace(/^--/, '');
    if (!['dir', 'branch', 'base', 'remote', 'pr', 'wo', 'test', 'expect-email'].includes(k) || argv[i + 1] === undefined) { console.log(`queue: unknown or empty option ${argv[i]} (the command line only dry-runs)`); return 2; }
    o[k] = argv[++i];
  }
  if (!o.dir || !o.branch) { console.log('usage: node core/ship/queue.mjs --dir <scratch clone> --branch <pr branch> [--base main] [--remote origin] [--pr tide#30] [--test \'["node","tests/x.mjs"]\']'); return 2; }
  let test = null;
  if (o.test) { try { test = JSON.parse(o.test); } catch { test = null; } if (!Array.isArray(test) || !test.length || test.some((x) => typeof x !== 'string')) { console.log('queue: --test is a JSON array of strings'); return 2; } }
  const r = await landPr({ dir: o.dir, branch: o.branch, base: o.base, remote: o.remote, pr: o.pr, wo: o.wo, test, expectEmail: o['expect-email'] });
  console.log(`Handover queue ${o.branch}: ${r.status}: ${r.reason}`);
  for (const x of r.files) console.log(`  conflict: ${x}`);
  console.log(JSON.stringify(toActivityResult(r)));
  return r.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = await main(process.argv.slice(2));
