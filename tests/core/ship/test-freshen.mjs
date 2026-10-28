// Owns the tests of Resurvey (core/ship/freshen-pr.mjs) and the force-push guard (core/ship/git.mjs): lane L4 row "freshen-pr".
// Called by tests/core/ship/test-ship.mjs. Throwaway git repos only (a bare origin in the temp folder).
// @ts-check
import fs from 'node:fs'; import path from 'node:path';
import { freshenPr } from '../../../core/ship/freshen-pr.mjs';
import { toActivityResult } from '../../../core/ship/activity.mjs';
import { git, forceReason } from '../../../core/ship/git.mjs';
import { validate } from '../../../core/contracts/validate.mjs';
import { originWithClone, commit, g, EMAIL, setIdentity } from './lib.mjs';

const asEvent = (d, seq) => ({ v: '1.0', seq, at: '2030-01-07T09:00:00Z', actor: 'engine', ...d });
const fwd = (p) => p.replace(/\\/g, '/');

/** A PR branch "feature" from main, then main moves; returns the repos. @param {Record<string, string>} prFiles @param {Record<string, string>} mainFiles */
function setup(prFiles, mainFiles) {
  const r = originWithClone({ 'README.md': 'example\n', 'src/a.txt': 'one\ntwo\nthree\nfour\nfive\n', 'src/b.txt': 'b\n' });
  g(r.seed, ['checkout', '-q', '-b', 'feature']);
  const prHead = commit(r.seed, prFiles, 'the PR');
  g(r.seed, ['push', '-q', 'origin', 'feature']);
  g(r.seed, ['checkout', '-q', 'main']);
  commit(r.seed, mainFiles, 'main moves');
  g(r.seed, ['push', '-q', 'origin', 'main']);
  return { ...r, prHead };
}

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export function run(check) {
  // ---- acceptance: never force
  const forced = [['push', '--force'], ['push', '-f', 'origin', 'x'], ['push', 'origin', '+HEAD:refs/heads/x'], ['push', '--force-with-lease'], ['push', '--force-if-includes'],
    ['push', '--mirror'], ['push', '--delete', 'origin', 'x'], ['push', 'origin', ':x'], ['push', '-qf', 'origin', 'x']];
  for (const a of forced) {
    let threw = '';
    try { git(process.cwd(), a); } catch (e) { threw = /** @type {Error} */ (e).message; }
    check(`freshen: the git guard refuses "git ${a.join(' ')}"`, forceReason(a) && /^refused: /.test(threw), threw || 'ran');
  }
  check('freshen: the git guard allows a normal push', !forceReason(['push', '-q', 'origin', 'HEAD:refs/heads/x']) && !forceReason(['push', '-u', 'origin', 'x']) && !forceReason(['fetch', '-f']));

  // a clean Resurvey: main changed a different file, so no re-review
  const a = setup({ 'src/b.txt': 'b changed by the PR\n' }, { 'README.md': 'main moved\n' });
  const ra = freshenPr({ expectEmail: EMAIL, dir: a.clone, branch: 'feature', pr: 'example#41', wo: 'WO-2001' });
  const remoteHead = g(a.seed, ['ls-remote', 'origin', 'refs/heads/feature']).split('\t')[0];
  check('freshen: main is merged into the PR branch and pushed normally', ra.ok && ra.status === 'freshened' && ra.pushed && remoteHead === ra.head, ra.reason);
  check('freshen: the merge commit is by the noreply identity', g(a.clone, ['log', '-1', '--format=%ae %ce', String(ra.head)]) === `${EMAIL} ${EMAIL}`);
  check('freshen: the PR head before Resurvey is kept in the history (no rewrite)', git(a.clone, ['merge-base', '--is-ancestor', a.prHead, String(ra.head)]).ok);
  check('freshen: no re-review mark when main changed none of the PR files', ra.reReview === false && ra.overlap.length === 0 && !ra.events.some((e) => /** @type {any} */ (e).kind === 'x.ship.re-review'));
  const pu = /** @type {any} */ (ra.events.find((e) => /** @type {any} */ (e).kind === 'pr.updated'));
  check('freshen: a pr.updated event (why freshen) passes the event contract', pu && validate('event', asEvent(pu, 30)).ok, pu ? validate('event', asEvent(pu, 30)).errors.join('; ') : 'none');
  const act = toActivityResult(ra);
  check('freshen: the activity result passes the activity-result contract', validate('activity-result', act).ok && act.exit === 0, validate('activity-result', act).errors.join('; '));
  const again = freshenPr({ expectEmail: EMAIL, dir: a.clone, branch: 'feature' });
  check('freshen: a branch that already contains main is current (nothing pushed)', again.ok && again.status === 'current' && !again.pushed, again.reason);

  // ---- acceptance: the re-review mark is set (main changed a file the PR changes, without a conflict)
  const b = setup({ 'src/a.txt': 'ONE\ntwo\nthree\nfour\nfive\n' }, { 'src/a.txt': 'one\ntwo\nthree\nfour\nFIVE\n' });
  const rb = freshenPr({ expectEmail: EMAIL, dir: b.clone, branch: 'feature', pr: 'example#42', wo: 'WO-2002' });
  const mark = /** @type {any} */ (rb.events.find((e) => /** @type {any} */ (e).kind === 'x.ship.re-review'));
  check('freshen: the re-review mark is set when main changed one of the PR files', rb.ok && rb.reReview && JSON.stringify(rb.overlap) === '["src/a.txt"]' && mark && mark.data.files[0] === 'src/a.txt', rb.reason);
  check('freshen: the re-review mark is an event the contract accepts (x.ship namespace)', mark && validate('event', asEvent(mark, 31)).ok, mark ? validate('event', asEvent(mark, 31)).errors.join('; ') : 'none');

  // a conflict is held with the files named, and the clone is left clean
  const c = setup({ 'src/a.txt': 'one\nTWO by the PR\nthree\nfour\nfive\n' }, { 'src/a.txt': 'one\ntwo by main\nthree\nfour\nfive\n' });
  const rc = freshenPr({ expectEmail: EMAIL, dir: c.clone, branch: 'feature' });
  check('freshen: a conflict with main is held with the files named', !rc.ok && rc.status === 'held' && JSON.stringify(rc.files) === '["src/a.txt"]' && /conflicts in 1 file/.test(rc.reason), rc.reason);
  check('freshen: a held conflict leaves the clone clean and the remote branch unchanged', g(c.clone, ['status', '--porcelain']) === '' && g(c.seed, ['ls-remote', 'origin', 'refs/heads/feature']).startsWith(c.prHead));
  check('freshen: a held result is a failed activity (exit 1)', toActivityResult(rc).exit === 1 && validate('activity-result', toActivityResult(rc)).ok);

  // ---- acceptance: unrelated history is held
  const u = originWithClone();
  g(u.seed, ['checkout', '-q', '--orphan', 'stray']);
  g(u.seed, ['rm', '-rq', '--cached', '.']);
  commit(u.seed, { 'other.txt': 'no shared history\n' }, 'an unrelated root');
  g(u.seed, ['push', '-q', 'origin', 'stray']);
  const ru = freshenPr({ expectEmail: EMAIL, dir: u.clone, branch: 'stray' });
  check('freshen: a branch with unrelated history is held, never merged', !ru.ok && /unrelated history/.test(ru.reason) && !ru.pushed, ru.reason);

  // ---- acceptance: never force (tested by refusing a non-fast-forward): the remote branch moves while Resurvey runs
  const n = setup({ 'src/b.txt': 'the PR\n' }, { 'README.md': 'main moved again\n' });
  g(n.seed, ['checkout', '-q', '-b', 'side', 'feature']);
  const sideSha = commit(n.seed, { 'src/c.txt': 'someone else pushed\n' }, 'pushed meanwhile');
  g(n.seed, ['push', '-q', 'origin', 'side']);
  const hook = path.join(n.clone, '.git', 'hooks', 'pre-push');
  fs.writeFileSync(hook, `#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\ngit --git-dir="${fwd(n.origin)}" update-ref refs/heads/feature ${sideSha}\nexit 0\n`, { mode: 0o755 });
  const rn = freshenPr({ expectEmail: EMAIL, dir: n.clone, branch: 'feature' });
  const after = g(n.seed, ['ls-remote', 'origin', 'refs/heads/feature']).split('\t')[0];
  check('freshen: a non-fast-forward is refused and held, never forced', !rn.ok && rn.status === 'held' && /never forced/.test(rn.reason) && !rn.pushed, rn.reason);
  check("freshen: after the refused push the remote keeps the other person's commit", after === sideSha, `remote ${after}`);
  fs.rmSync(hook);

  // the identity is checked before anything runs
  const i = setup({ 'src/b.txt': 'x\n' }, { 'README.md': 'y\n' });
  setIdentity(i.clone, 'someone@example.com');
  const ri = freshenPr({ expectEmail: EMAIL, dir: i.clone, branch: 'feature' });
  check('freshen: a commit identity that is not a noreply address is held', !ri.ok && /not a GitHub noreply address/.test(ri.reason), ri.reason);
  setIdentity(i.clone);
  const rdef = freshenPr({ dir: i.clone, branch: 'feature' });
  check("freshen: by default a noreply address other than the owner's is held", !rdef.ok && rdef.reason.includes('not the expected 104696717+VonBorstel-J@users.noreply.github.com'), rdef.reason);
  const rx =freshenPr({ expectEmail: EMAIL, dir: i.clone, branch: 'feature', expectEmail: '2000002+other@users.noreply.github.com' });
  check('freshen: a noreply identity that is not the expected one is held', !rx.ok && /not the expected/.test(rx.reason), rx.reason);
  fs.writeFileSync(path.join(i.clone, 'dirty.txt'), 'x');
  const rd = freshenPr({ expectEmail: EMAIL, dir: i.clone, branch: 'feature' });
  check('freshen: a clone with local changes is held', !rd.ok && /local changes/.test(rd.reason), rd.reason);
  check('freshen: an option-looking branch name is refused', !freshenPr({ expectEmail: EMAIL, dir: i.clone, branch: '--force' }).ok);
}
