// Owns Resurvey (freshen-pr): bring a held PR's branch up to date by merging main into it, pushing normally (never forced), and marking it for re-review when main changed the PR's own files.
// Called by the engine's convergence workflow (lane L2, behind flag ship.resurvey), tests/core/ship/test-freshen.mjs and by hand (usage below).
//   node core/ship/freshen-pr.mjs --dir <clone> --branch <pr branch> [--base main] [--remote origin] [--pr tide#30] [--wo WO-1] [--no-push]
// Held, with the reason named, when: the identity is not a noreply address, the clone has local changes, the branch and main share no
// history, the merge conflicts (the files are named), or the remote branch moved meanwhile (a normal push is refused; never forced).
// @ts-check
import path from 'node:path'; import { pathToFileURL } from 'node:url';
import { git, NOREPLY, conflictedFiles, changedFiles } from './git.mjs';
import { toActivityResult, eventDraft } from './activity.mjs';

/**
 * @typedef {{ ok: boolean, status: 'freshened' | 'current' | 'held', reason: string, files: string[], reReview: boolean, overlap: string[],
 *   head: string | null, pushed: boolean, events: object[], proof: string | null }} FreshenReport
 */

/** @param {Partial<FreshenReport>} r @returns {FreshenReport} */
const report = (r) => ({ ok: false, status: 'held', reason: '', files: [], reReview: false, overlap: [], head: null, pushed: false, events: [], proof: null, ...r });

/**
 * The commit identity a ship step uses: the clone's user.email, which must be a GitHub noreply address (and the expected one, when given).
 * @param {string} dir @param {string} [expect]
 * @returns {{ ok: boolean, email: string, name: string, reason: string }}
 */
export function checkIdentity(dir, expect = '') {
  const email = git(dir, ['config', 'user.email']).out;
  const name = git(dir, ['config', 'user.name']).out || 'Tide ship path';
  if (!NOREPLY.test(email)) return { ok: false, email, name, reason: `the commit identity "${email || '(none)'}" is not a GitHub noreply address (<id>+<login>@users.noreply.github.com)` };
  if (expect && email !== expect) return { ok: false, email, name, reason: `the commit identity is ${email}, not the expected ${expect}` };
  return { ok: true, email, name, reason: '' };
}

/**
 * Resurvey one PR branch in a clone.
 * @param {{ dir: string, branch: string, base?: string, remote?: string, pr?: string, wo?: string | null, push?: boolean, expectEmail?: string }} o
 * @returns {FreshenReport}
 */
export function freshenPr(o) {
  const { dir, branch } = o;
  const base = o.base || 'main'; const remote = o.remote || 'origin';
  const wo = o.wo ?? null;
  if (!/^[A-Za-z0-9._/-]+$/.test(branch) || branch.startsWith('-') || !/^[A-Za-z0-9._/-]+$/.test(base) || base.startsWith('-')) return report({ reason: `not a branch name: ${branch} / ${base}` });
  const id = checkIdentity(dir, o.expectEmail);
  if (!id.ok) return report({ reason: id.reason });
  const as = ['-c', `user.email=${id.email}`, '-c', `user.name=${id.name}`, '-c', 'commit.gpgsign=false'];

  const st = git(dir, ['status', '--porcelain']);
  if (!st.ok) return report({ reason: `not a git checkout: ${st.err}` });
  if (st.out) return report({ reason: 'the clone has local changes; Resurvey works only in a clean clone' });
  const f = git(dir, ['fetch', '-q', remote, `refs/heads/${base}:refs/remotes/${remote}/${base}`, `refs/heads/${branch}:refs/remotes/${remote}/${branch}`]);
  if (!f.ok) return report({ reason: `fetch failed: ${f.err}` });
  const prHead = git(dir, ['rev-parse', `${remote}/${branch}`]).out;
  const mainHead = git(dir, ['rev-parse', `${remote}/${base}`]).out;

  const mb = git(dir, ['merge-base', prHead, mainHead]);
  if (!mb.ok || !mb.out) return report({ reason: `unrelated history: ${branch} and ${base} share no commit; a person must re-plan it (never merged with --allow-unrelated-histories)` });
  const oldBase = mb.out;
  if (oldBase === mainHead) return report({ ok: true, status: 'current', reason: `${branch} already contains ${base}`, head: prHead });

  const co = git(dir, ['checkout', '-q', '--detach', prHead]);
  if (!co.ok) return report({ reason: `checkout of ${branch} failed: ${co.err}` });
  const m = git(dir, [...as, 'merge', '--no-ff', '--no-edit', '-m', `Resurvey: merge ${base} into ${branch}`, mainHead]);
  if (!m.ok) {
    const files = conflictedFiles(dir);
    git(dir, ['merge', '--abort']);
    return report({ reason: files.length ? `merging ${base} conflicts in ${files.length} file(s); the PR is held for a person or a re-cook` : `merge failed: ${m.err}`, files });
  }
  const head = git(dir, ['rev-parse', 'HEAD']).out;
  const who = git(dir, ['log', '-1', '--format=%ae%n%ce', head]).out.split('\n');
  if (who.some((e) => e !== id.email)) return report({ reason: `the merge commit's author or committer is not ${id.email}`, head });

  // Re-review when main changed a file the PR also changes: the code under review is no longer what the verifier read.
  const prFiles = changedFiles(dir, oldBase, prHead);
  const mainFiles = new Set(changedFiles(dir, oldBase, mainHead));
  const overlap = prFiles.filter((x) => mainFiles.has(x));
  const reReview = overlap.length > 0;

  let pushed = false;
  if (o.push !== false) {
    const p = git(dir, ['push', '-q', remote, `HEAD:refs/heads/${branch}`]);
    if (!p.ok) {
      const moved = /non-fast-forward|fetch first|rejected|stale info/i.test(p.err);
      return report({ reason: moved ? `the remote ${branch} moved while Resurvey ran; the push was refused and is never forced (try again later)` : `push failed: ${p.err}`, head, reReview, overlap });
    }
    pushed = true;
  }
  const events = [];
  if (pushed && o.pr) events.push(eventDraft('pr.updated', wo, { pr: o.pr, head, why: 'freshen' }, head));
  if (reReview) events.push(eventDraft('x.ship.re-review', wo, { pr: o.pr || null, head, files: overlap.slice(0, 50) }, head));
  return report({ ok: true, status: 'freshened', reason: `merged ${base} (${mainHead.slice(0, 7)}) into ${branch}${pushed ? ' and pushed' : ' (not pushed: --no-push)'}`, head, pushed, reReview, overlap, events, proof: head });
}

/** @param {string[]} argv @returns {number} */
export function main(argv) {
  /** @type {Record<string, string>} */
  const o = {};
  let push = true;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--no-push') { push = false; continue; }
    const k = argv[i].replace(/^--/, '');
    if (!['dir', 'branch', 'base', 'remote', 'pr', 'wo', 'expect-email'].includes(k) || argv[i + 1] === undefined) { console.log(`freshen-pr: unknown or empty option ${argv[i]}`); return 2; }
    o[k] = argv[++i];
  }
  if (!o.dir || !o.branch) { console.log('usage: node core/ship/freshen-pr.mjs --dir <clone> --branch <pr branch> [--base main] [--remote origin] [--pr tide#30] [--wo WO-1] [--expect-email <noreply>] [--no-push]'); return 2; }
  const r = freshenPr({ dir: o.dir, branch: o.branch, base: o.base, remote: o.remote, pr: o.pr, wo: o.wo, push, expectEmail: o['expect-email'] });
  console.log(`Resurvey ${o.branch}: ${r.status}: ${r.reason}`);
  for (const x of r.files) console.log(`  conflict: ${x}`);
  if (r.reReview) console.log(`  re-review: main changed ${r.overlap.length} of the PR's files (${r.overlap.slice(0, 5).join(', ')})`);
  console.log(JSON.stringify(toActivityResult(r)));
  return r.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));
