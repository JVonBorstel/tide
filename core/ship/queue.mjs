// Owns the Handover queue (our own merge queue): test a PR merged onto the latest main, then, only on Jordan's yes, move main forward to that tested commit.
// Called by the engine (lane L2) one PR at a time per repo, behind flag ship.merge-queue; tests/core/ship/test-queue.mjs; and by hand for a dry run (usage below).
//   node core/ship/queue.mjs --dir <scratch clone> --branch <pr branch> [--base main] [--remote origin] [--pr tide#30] [--test '["node","tests/x.mjs"]']
// The command line only ever dry-runs. Landing is landPr({ land: true, yes, flags }) from the engine: it needs the upgrade switch ship.queue at new
// (kitchen/kitchen.json), the flag on, a decision.answered
// "Yes" event, the agent-review status when ship.review-check is on, and main unmoved since the test; the push is a fast-forward, never forced.
// scripts/merge-pr.ps1 and kitchen/train.ps1 stay the merge path while the flag is off.
// @ts-check
import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { pathToFileURL } from 'node:url';
import { git, conflictedFiles } from './git.mjs';
import { checkIdentity } from './freshen-pr.mjs';
import { isOn } from './flags.mjs';
import { toActivityResult, eventDraft } from './activity.mjs';
import { validate } from '../contracts/validate.mjs';
import { switchOf } from '../contracts/upgrade.mjs';
import fs from 'node:fs'; import { fileURLToPath } from 'node:url';

const KITCHEN_JSON = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'kitchen', 'kitchen.json');
/** The upgrade switches: kitchen/kitchen.json, read only; unreadable reads as {} (every switch old). */
const readKitchen = () => { try { return JSON.parse(fs.readFileSync(KITCHEN_JSON, 'utf8')); } catch { return {}; } };

/**
 * @typedef {{ ok: boolean, status: 'ready' | 'landed' | 'held', reason: string, files: string[], merge: string | null, base: string | null,
 *   tests: string, events: object[], proof: string | null }} QueueReport
 */
/** @param {Partial<QueueReport>} r @returns {QueueReport} */
const report = (r) => ({ ok: false, status: 'held', reason: '', files: [], merge: null, base: null, tests: '', events: [], proof: null, ...r });
const tail = (s, n = 1500) => (s.length > n ? `...${s.slice(-n)}` : s);

/**
 * Why a yes event does not allow landing, or '' when it does: a decision.answered event by Jordan, answer "Yes", that passes the contract.
 * @param {any} yes
 */
export function yesProblem(yes) {
  if (!yes) return 'no decision.answered event was given (landing needs Jordan\'s yes)';
  const v = validate('event', yes);
  if (!v.ok) return `the yes event does not pass the event contract: ${v.errors.slice(0, 3).join('; ')}`;
  if (yes.kind !== 'decision.answered') return `the yes event is a ${yes.kind}, not a decision.answered`;
  if (yes.actor !== 'jordan') return `the yes event's actor is ${yes.actor}, not jordan`;
  if (!/^yes$/i.test(yes.data.answer)) return `the answer is "${yes.data.answer}", not Yes`;
  return '';
}

/**
 * Test a PR merged onto the latest main in a scratch clone; land it only when asked and allowed.
 * @param {{ dir: string, branch: string, base?: string, remote?: string, pr?: string, wo?: string | null, test?: string[] | null,
 *   timeoutSec?: number, expectEmail?: string, land?: boolean, yes?: any, flags?: { declared?: any, current?: Record<string, boolean> },
 *   review?: { context: string, state: string, sha: string } | null, upgrade?: any }} o (upgrade: the parsed kitchen/kitchen.json, default read from the repo)
 * @returns {QueueReport}
 */
export function landPr(o) {
  const { dir, branch } = o;
  const base = o.base || 'main'; const remote = o.remote || 'origin'; const wo = o.wo ?? null;
  const names = [branch, base];
  if (names.some((n) => !/^[A-Za-z0-9._/-]+$/.test(n) || n.startsWith('-'))) return report({ reason: `not a branch name: ${names.join(' / ')}` });
  const id = checkIdentity(dir, o.expectEmail);
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

  // 4. landing: flag, yes, review, main unmoved, then a fast-forward push
  const sw = switchOf(o.upgrade ?? readKitchen(), 'ship.queue');
  if (sw !== 'new') return report({ reason: `the upgrade switch ship.queue is ${sw}: the queue only dry-runs beside scripts/merge-pr.ps1 until it is new (Jordan's card)`, ...ready });
  if (!o.pr || !/^[a-z0-9][a-z0-9._-]*#[0-9]+$/.test(o.pr)) return report({ reason: 'landing needs the PR as <repo>#<n> (for the merged event)', ...ready });
  const flags = o.flags || {};
  if (!isOn('ship.merge-queue', flags)) return report({ reason: 'flag ship.merge-queue is off: scripts/merge-pr.ps1 stays the merge path', ...ready });
  const why = yesProblem(o.yes);
  if (why) return report({ reason: why, ...ready });
  if (isOn('ship.review-check', flags)) {
    const r = o.review;
    if (!r || r.context !== 'agent-review' || r.state !== 'success' || r.sha !== prHead) return report({ reason: `flag ship.review-check is on and the PR head ${prHead.slice(0, 7)} has no successful agent-review status`, ...ready });
  }
  const again = git(dir, ['fetch', '-q', remote, `refs/heads/${base}:refs/remotes/${remote}/${base}`]);
  const nowMain = git(dir, ['rev-parse', `${remote}/${base}`]).out;
  if (!again.ok || nowMain !== mainHead) return report({ reason: again.ok ? `${base} moved (${mainHead.slice(0, 7)} to ${nowMain.slice(0, 7)}) after the test; held to test again on the new ${base}` : `fetch failed: ${again.err}`, ...ready });
  const p = git(dir, ['push', '-q', remote, `${merge}:refs/heads/${base}`]);
  if (!p.ok) return report({ reason: `the push to ${base} was refused (${tail(p.err, 300)}); never forced`, ...ready });
  const decision = o.yes.data.decision;
  return report({ ok: true, status: 'landed', reason: `${base} moved forward to the tested merge ${merge.slice(0, 7)} (decision ${decision})`, ...ready,
    events: [eventDraft('merged', wo, { pr: o.pr, sha: merge, decision }, merge)] });
}

/** @param {string[]} argv @returns {number} */
export function main(argv) {
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
  const r = landPr({ dir: o.dir, branch: o.branch, base: o.base, remote: o.remote, pr: o.pr, wo: o.wo, test, expectEmail: o['expect-email'] });
  console.log(`Handover queue ${o.branch}: ${r.status}: ${r.reason}`);
  for (const x of r.files) console.log(`  conflict: ${x}`);
  console.log(JSON.stringify(toActivityResult(r)));
  return r.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));
