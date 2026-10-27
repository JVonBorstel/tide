// Owns the tests of the Handover queue (core/ship/queue.mjs): lane L4 row "merge queue", all against a scratch clone of a throwaway origin.
// Called by tests/core/ship/test-ship.mjs.
// @ts-check
import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { landPr, yesProblem } from '../../../core/ship/queue.mjs';
import { checkFlags } from '../../../core/ship/flags.mjs';
import { toActivityResult } from '../../../core/ship/activity.mjs';
import { validate } from '../../../core/contracts/validate.mjs';
import { originWithClone, commit, g, EMAIL, setIdentity } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const YES = { v: '1.0', seq: 11, at: '2030-01-07T09:11:00Z', actor: 'jordan', kind: 'decision.answered', wo: 'WO-2001', data: { decision: 'D-7', answer: 'Yes', note: null, via: 'board', requestId: 'req-0001-example' }, proof: null };
const declared = checkFlags({ version: 1, flags: {
  'ship.merge-queue': { default: false, what: 'The example merge queue flag.', lane: 'L4' },
  'ship.review-check': { default: false, what: 'The example review check flag.', lane: 'L4' } } });
const ON = { declared, current: { 'ship.merge-queue': true } };
const NEW = { upgrade: { v: '1.0', ship: { queue: 'new' } } }; // the shape of kitchen/kitchen.json
const mainOf = (r) => g(r.seed, ['ls-remote', 'origin', 'refs/heads/main']).split('\t')[0];

/** A PR branch "feature" from main, then main moves. @param {Record<string, string>} prFiles @param {Record<string, string>} mainFiles */
function setup(prFiles, mainFiles) {
  const r = originWithClone({ 'README.md': 'example\n', 'src/a.txt': 'one\ntwo\nthree\n', 'test.mjs': 'process.exit(0)\n' });
  g(r.seed, ['checkout', '-q', '-b', 'feature']);
  const prHead = commit(r.seed, prFiles, 'the PR');
  g(r.seed, ['push', '-q', 'origin', 'feature']);
  g(r.seed, ['checkout', '-q', 'main']);
  const mainHead = commit(r.seed, mainFiles, 'main moves');
  g(r.seed, ['push', '-q', 'origin', 'main']);
  return { ...r, prHead, mainHead };
}
const TEST = [process.execPath, 'test.mjs'];

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export function run(check) {
  // ---- acceptance: dry run on a scratch clone; a PR that conflicts with the latest main is held with the files named
  const c = setup({ 'src/a.txt': 'one\nTWO by the PR\nthree\n' }, { 'src/a.txt': 'one\ntwo by main\nthree\n' });
  const rc = landPr({ dir: c.clone, branch: 'feature', pr: 'example#41', test: TEST });
  check('queue: a PR that conflicts with the latest main is held with the files named', !rc.ok && rc.status === 'held' && JSON.stringify(rc.files) === '["src/a.txt"]' && /conflicts with the latest main in 1 file/.test(rc.reason), rc.reason);
  check('queue: the held conflict leaves the scratch clone clean and main unchanged', g(c.clone, ['status', '--porcelain']) === '' && mainOf(c) === c.mainHead);
  check('queue: a held result is a failed activity that passes the contract', validate('activity-result', toActivityResult(rc)).ok && toActivityResult(rc).exit === 1);

  // a clean dry run: merged onto the latest main, tested, nothing pushed
  const d = setup({ 'src/b.txt': 'new in the PR\n' }, { 'README.md': 'main moved\n' });
  const rd = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42', test: TEST });
  check('queue: a dry run tests the PR merged onto the latest main and pushes nothing', rd.ok && rd.status === 'ready' && rd.base === d.mainHead && mainOf(d) === d.mainHead, rd.reason);
  check('queue: the tested merge has the latest main as first parent and the PR head as second', rd.merge && g(d.clone, ['rev-parse', `${rd.merge}^1`, `${rd.merge}^2`]) === `${d.mainHead}\n${d.prHead}`);

  // ---- acceptance: the noreply identity is checked
  check('queue: the merge commit is by the noreply identity', g(d.clone, ['log', '-1', '--format=%ae %ce', String(rd.merge)]) === `${EMAIL} ${EMAIL}`);
  setIdentity(d.clone, 'someone@example.com');
  const ri = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42' });
  check('queue: a commit identity that is not a noreply address is held before anything runs', !ri.ok && /not a GitHub noreply address/.test(ri.reason) && ri.merge === null, ri.reason);
  setIdentity(d.clone);
  const rx = landPr({ dir: d.clone, branch: 'feature', expectEmail: '2000002+other@users.noreply.github.com' });
  check('queue: a noreply identity that is not the expected account is held', !rx.ok && /not the expected/.test(rx.reason), rx.reason);

  // tests that fail on the merged result hold it
  const t = setup({ 'test.mjs': 'console.log("1 failed"); process.exit(1)\n' }, { 'README.md': 'm\n' });
  const rt = landPr({ dir: t.clone, branch: 'feature', test: TEST });
  check('queue: tests that fail on the merged result hold the PR, with their output', !rt.ok && /tests failed/.test(rt.reason) && /1 failed/.test(rt.tests), rt.reason);

  // ---- landing runs only on a yes event, with the flag on
  const off = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42', test: TEST, land: true, yes: YES, flags: { declared }, upgrade: NEW });
  check('queue: landing is refused while flag ship.merge-queue is off (merge-pr.ps1 stays the path)', !off.ok && /ship.merge-queue is off/.test(off.reason) && mainOf(d) === d.mainHead, off.reason);
  const sw = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42', land: true, yes: YES, flags: ON });
  check('queue: landing is refused while the upgrade switch ship.queue is old (the repo kitchen.json)', !sw.ok && /ship.queue is old/.test(sw.reason), sw.reason);
  const shadow = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42', land: true, yes: YES, flags: ON, upgrade: { upgrade: { v: '1.0', ship: { queue: 'shadow' } } } });
  check('queue: in shadow the queue only dry-runs (landing refused)', !shadow.ok && /ship.queue is shadow/.test(shadow.reason), shadow.reason);
  const noYes = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42', land: true, flags: ON, upgrade: NEW });
  check('queue: landing is refused without a yes event', !noYes.ok && /no decision.answered event/.test(noYes.reason), noYes.reason);
  check('queue: a "No" answer, a non-jordan actor or another kind is not a yes', /not Yes/.test(yesProblem({ ...YES, data: { ...YES.data, answer: 'No' } })) && /event contract|not jordan/.test(yesProblem({ ...YES, actor: 'engine' })) && yesProblem(YES) === '');
  check('queue: a yes event that breaks the contract is refused', /event contract/.test(yesProblem({ ...YES, v: undefined })));
  const noReview = landPr({ dir: d.clone, branch: 'feature', pr: 'example#42', land: true, yes: YES, flags: { declared, current: { 'ship.merge-queue': true, 'ship.review-check': true } }, upgrade: NEW });
  check('queue: with ship.review-check on, landing needs a successful agent-review on the PR head', !noReview.ok && /agent-review/.test(noReview.reason), noReview.reason);
  const noPr = landPr({ dir: d.clone, branch: 'feature', land: true, yes: YES, flags: ON, upgrade: NEW });
  check('queue: landing needs the PR ref for the merged event', !noPr.ok && /<repo>#<n>/.test(noPr.reason), noPr.reason);
  check('queue: none of the refused landings moved main', mainOf(d) === d.mainHead);

  // main moves after the test: held, to test again
  const mv = setup({ 'src/b.txt': 'b\n' }, { 'README.md': 'm1\n' });
  g(mv.seed, ['checkout', '-q', '-b', 'later']);
  const later = commit(mv.seed, { 'src/c.txt': 'landed meanwhile\n' }, 'another PR landed');
  g(mv.seed, ['push', '-q', 'origin', 'later']);
  const moveMain = ['git', `--git-dir=${mv.origin}`, 'update-ref', 'refs/heads/main', later];
  const rm = landPr({ dir: mv.clone, branch: 'feature', pr: 'example#43', test: moveMain, land: true, yes: YES, flags: ON, upgrade: NEW });
  check('queue: main moving after the test holds the PR to test again (never lands an untested result)', !rm.ok && /moved .* after the test/.test(rm.reason) && mainOf(mv) === later, rm.reason);

  // a full landing: flag on, a yes, review when required; main fast-forwards to the tested merge
  const ok = setup({ 'src/b.txt': 'b\n' }, { 'README.md': 'm2\n' });
  const rv = landPr({ dir: ok.clone, branch: 'feature', pr: 'example#44', wo: 'WO-2001', test: TEST, land: true, yes: YES,
    flags: { declared, current: { 'ship.merge-queue': true, 'ship.review-check': true } }, review: { context: 'agent-review', state: 'success', sha: ok.prHead }, upgrade: NEW });
  check('queue: with the flag on, a yes and the review, main fast-forwards to the tested merge', rv.ok && rv.status === 'landed' && mainOf(ok) === rv.merge && g(ok.clone, ['rev-parse', `${rv.merge}^1`]) === ok.mainHead, rv.reason);
  const ev = /** @type {any} */ (rv.events[0]);
  const full = ev && { v: '1.0', seq: 12, at: '2030-01-07T09:12:00Z', actor: 'engine', ...ev };
  check('queue: the merged event (sha and decision) passes the event contract', full && validate('event', full).ok && full.data.decision === 'D-7', full ? validate('event', full).errors.join('; ') : 'none');

  // the command line dry-runs only
  const cli = spawnSync(process.execPath, [path.join(repo, 'core/ship/queue.mjs'), '--dir', c.clone, '--branch', 'feature'], { encoding: 'utf8', timeout: 30000 });
  check('queue: the command line names the conflicted file and exits 1', cli.status === 1 && /conflict: src\/a.txt/.test(cli.stdout), cli.stdout + cli.stderr);
  const land = spawnSync(process.execPath, [path.join(repo, 'core/ship/queue.mjs'), '--dir', c.clone, '--branch', 'feature', '--land', 'yes'], { encoding: 'utf8', timeout: 30000 });
  check('queue: the command line has no way to land (usage error)', land.status === 2, land.stdout);
}
