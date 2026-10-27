// Owns the tests of the Handover queue (core/ship/queue.mjs): lane L4 row "merge queue", all against scratch clones of a throwaway origin.
// Called by tests/core/ship/test-ship.mjs. Landing runs in a copy of core/ with its own kitchen/kitchen.json, flags.json and a scratch
// state folder (BRAIN_KITCHEN) holding a tide.db, because landing reads every permission from those files and from nothing else.
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { landPr, yesProblem, reviewProblem, landingProblem } from '../../../core/ship/queue.mjs';
import { checkFlags } from '../../../core/ship/flags.mjs';
import { toActivityResult } from '../../../core/ship/activity.mjs';
import { OWNER_NOREPLY } from '../../../core/ship/git.mjs';
import { validate } from '../../../core/contracts/validate.mjs';
import { originWithClone, commit, g, EMAIL, setIdentity, tempDir } from './lib.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const HEAD = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const WO = 'WO-2001'; const PR = 'example#44';
const mainOf = (r) => g(r.seed, ['ls-remote', 'origin', 'refs/heads/main']).split('\t')[0];
const declared = checkFlags({ version: 1, flags: { 'ship.merge-queue': { default: false, what: 'The example merge queue flag.', lane: 'L4' } } });
const NEW = { upgrade: { v: '1.0', ship: { queue: 'new' } } }; // the shape of kitchen/kitchen.json

/** Contract events for one PR head: the flag on, the merge card, Jordan's yes for the head, a verifier's ship. */
function permits(head = HEAD, o = {}) {
  const ev = (seq, actor, kind, wo, data, proof = null) => ({ v: '1.0', seq, at: `2030-01-07T09:${String(seq).padStart(2, '0')}:00Z`, actor, kind, wo, data, proof });
  const card = { v: '1.0', id: 'D-7', wo: WO, kind: 'merge', ask: o.ask || `Merge ${PR} (an example)?`, options: ['Yes', 'Hold', 'No'], recommended: 'Yes', why: 'Tests and review are green.', answer: null, note: null, at: '2030-01-07T09:00:00Z', answeredAt: null, via: null };
  return [
    ev(1, 'engine', 'flag.set', null, { flag: 'ship.merge-queue', on: true, decision: 'D-6' }),
    ev(2, 'engine', 'decision.asked', WO, { decision: card }),
    ev(3, 'jordan', 'decision.answered', WO, { decision: 'D-7', answer: o.answer || 'Yes', note: null, via: 'board', requestId: 'req-0007-example' }, o.yesFor || head),
    ev(4, 'crew:verifier-1', 'review.verdict', WO, { verdict: o.verdict || 'ship', reasons: 'Read every line.', head: o.reviewHead || head, reviewer: 'crew:verifier-1', builder: o.builder === undefined ? 'crew:builder-1' : o.builder }),
  ].filter(Boolean);
}

/** A PR branch "feature" from main, then main moves. @param {Record<string, string>} prFiles @param {Record<string, string>} mainFiles @param {string} [email] */
function setup(prFiles, mainFiles, email = EMAIL) {
  const r = originWithClone({ 'README.md': 'example\n', 'src/a.txt': 'one\ntwo\nthree\n', 'test.mjs': 'process.exit(0)\n' });
  setIdentity(r.clone, email);
  g(r.seed, ['checkout', '-q', '-b', 'feature']);
  const prHead = commit(r.seed, prFiles, 'the PR');
  g(r.seed, ['push', '-q', 'origin', 'feature']);
  g(r.seed, ['checkout', '-q', 'main']);
  const mainHead = commit(r.seed, mainFiles, 'main moves');
  g(r.seed, ['push', '-q', 'origin', 'main']);
  return { ...r, prHead, mainHead };
}
const TEST = [process.execPath, 'test.mjs'];

/** A copy of core/ (with flags.json and a kitchen.json) and a scratch state folder; run() lands through it in a child node. */
function landingBench(kitchen = NEW) {
  const root = tempDir('bench');
  fs.cpSync(path.join(repo, 'core'), path.join(root, 'core'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'flags.json'), path.join(root, 'flags.json'));
  fs.mkdirSync(path.join(root, 'kitchen'));
  fs.writeFileSync(path.join(root, 'kitchen', 'kitchen.json'), JSON.stringify(kitchen));
  fs.writeFileSync(path.join(root, 'driver.mjs'), [
    "import { landPr } from './core/ship/queue.mjs'; import { openStore } from './core/ledger/store.mjs';",
    'const a = JSON.parse(process.argv[2]);',
    "if (a.op === 'seed') { const s = await openStore(a.db); s.append(a.events); s.close(); console.log(JSON.stringify({ ok: true })); }",
    'else console.log(JSON.stringify(await landPr(a.args)));',
  ].join('\n'));
  const state = tempDir('state');
  const flag = Number(process.versions.node.split('.')[0]) < 23 ? ['--experimental-sqlite', '--no-warnings'] : [];
  const run = (a) => {
    const r = spawnSync(process.execPath, [...flag, path.join(root, 'driver.mjs'), JSON.stringify(a)], { encoding: 'utf8', timeout: 120000, env: { ...process.env, BRAIN_KITCHEN: state } });
    const last = (r.stdout || '').trim().split('\n').pop() || '';
    try { return JSON.parse(last); } catch { return { ok: false, reason: `driver failed (exit ${r.status}): ${(r.stderr || r.stdout || '').slice(-400)}` }; }
  };
  return { root, state, run, seed: (events) => run({ op: 'seed', db: path.join(state, 'tide.db'), events: events.map(({ seq, ...e }) => e) }) };
}

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
async function testDryRun(check) {
  // ---- acceptance: dry run on a scratch clone; a PR that conflicts with the latest main is held with the files named
  const c = setup({ 'src/a.txt': 'one\nTWO by the PR\nthree\n' }, { 'src/a.txt': 'one\ntwo by main\nthree\n' });
  const rc = await landPr({ dir: c.clone, branch: 'feature', pr: PR, test: TEST, expectEmail: EMAIL });
  check('queue: a PR that conflicts with the latest main is held with the files named', !rc.ok && rc.status === 'held' && JSON.stringify(rc.files) === '["src/a.txt"]' && /conflicts with the latest main in 1 file/.test(rc.reason), rc.reason);
  check('queue: the held conflict leaves the scratch clone clean and main unchanged', g(c.clone, ['status', '--porcelain']) === '' && mainOf(c) === c.mainHead);
  check('queue: a held result is a failed activity that passes the contract', validate('activity-result', toActivityResult(rc)).ok && toActivityResult(rc).exit === 1);

  const d = setup({ 'src/b.txt': 'new in the PR\n' }, { 'README.md': 'main moved\n' });
  const rd = await landPr({ dir: d.clone, branch: 'feature', pr: PR, test: TEST, expectEmail: EMAIL });
  check('queue: a dry run tests the PR merged onto the latest main and pushes nothing', rd.ok && rd.status === 'ready' && rd.base === d.mainHead && mainOf(d) === d.mainHead, rd.reason);
  check('queue: the tested merge has the latest main as first parent and the PR head as second', rd.merge && g(d.clone, ['rev-parse', `${rd.merge}^1`, `${rd.merge}^2`]) === `${d.mainHead}\n${d.prHead}`);

  // ---- acceptance: the noreply identity is checked (default: exactly the owner's address)
  check('queue: the merge commit is by the expected identity (author and committer)', g(d.clone, ['log', '-1', '--format=%ae %ce', String(rd.merge)]) === `${EMAIL} ${EMAIL}`);
  const other = await landPr({ dir: d.clone, branch: 'feature', pr: PR });
  check("queue: by default any noreply address other than the owner's is held", !other.ok && other.reason.includes(`not the expected ${OWNER_NOREPLY}`), other.reason);
  setIdentity(d.clone, 'someone@example.com');
  const ri = await landPr({ dir: d.clone, branch: 'feature', pr: PR, expectEmail: 'someone@example.com' });
  check('queue: an identity that is not a noreply address is held before anything runs', !ri.ok && /not a GitHub noreply address/.test(ri.reason) && ri.merge === null, ri.reason);
  setIdentity(d.clone);
  const landOther = await landPr({ dir: d.clone, branch: 'feature', pr: PR, expectEmail: EMAIL, land: true, wo: WO });
  check("queue: landing ignores expectEmail and needs the owner's address", !landOther.ok && landOther.reason.includes(OWNER_NOREPLY), landOther.reason);

  const t = setup({ 'test.mjs': 'console.log("1 failed"); process.exit(1)\n' }, { 'README.md': 'm\n' });
  const rt = await landPr({ dir: t.clone, branch: 'feature', test: TEST, expectEmail: EMAIL });
  check('queue: tests that fail on the merged result hold the PR, with their output', !rt.ok && /tests failed/.test(rt.reason) && /1 failed/.test(rt.tests), rt.reason);

  // fix 3, in this repo: its own kitchen.json says ship.queue old, so nothing lands whatever the caller passes
  setIdentity(d.clone, OWNER_NOREPLY);
  const live = await landPr({ dir: d.clone, branch: 'feature', pr: PR, wo: WO, land: true });
  check("queue: in this repo landing is refused by its own kitchen.json (ship.queue old), whatever the caller passes", !live.ok && /ship.queue is old/.test(live.reason) && mainOf(d) === d.mainHead, live.reason);

  // the command line dry-runs only
  const cli = spawnSync(process.execPath, [path.join(repo, 'core/ship/queue.mjs'), '--dir', c.clone, '--branch', 'feature', '--expect-email', EMAIL], { encoding: 'utf8', timeout: 30000 });
  check('queue: the command line names the conflicted file and exits 1', cli.status === 1 && /conflict: src\/a.txt/.test(cli.stdout), cli.stdout + cli.stderr);
  const land = spawnSync(process.execPath, [path.join(repo, 'core/ship/queue.mjs'), '--dir', c.clone, '--branch', 'feature', '--land', 'yes'], { encoding: 'utf8', timeout: 30000 });
  check('queue: the command line has no way to land (usage error)', land.status === 2, land.stdout);
}

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
function testPermissions(check) {
  // ---- the landing permissions, over events (pure)
  const ok = (ev, kitchen = NEW) => landingProblem({ kitchen, declared, events: ev, wo: WO, pr: PR, head: HEAD });
  check('queue: every permission present (switch new, flag on, yes for this PR and head, review by another crew) allows landing', ok(permits()) === '', ok(permits()));
  check('queue: the permission events pass the event contract', permits().every((e) => validate('event', e).ok), permits().map((e) => validate('event', e).errors.join(';')).join(' | '));
  check('queue: switch ship.queue old or shadow refuses landing', /ship.queue is old/.test(ok(permits(), {})) && /ship.queue is shadow/.test(ok(permits(), { upgrade: { v: '1.0', ship: { queue: 'shadow' } } })));
  check('queue: the flag is read from flag.set events only (none: off)', /ship.merge-queue is off/.test(ok(permits().filter((e) => e.kind !== 'flag.set'))));
  check('queue: a flag declared nowhere in flags.json stays off', /is off/.test(landingProblem({ kitchen: NEW, declared: checkFlags({ version: 1, flags: {} }), events: permits(), wo: WO, pr: PR, head: HEAD })));
  // fix 2: the yes is bound to this PR and this head
  check('queue: a yes on a card for another PR does not land this one', /no merge card for WO-2001 names example#44/.test(ok(permits(HEAD, { ask: 'Merge example#45 (other)?' }))));
  check('queue: a card for example#440 is not a card for example#44', /no merge card/.test(ok(permits(HEAD, { ask: 'Merge example#440?' }))));
  check('queue: a yes given for another sha (a new push since) does not land', /a new push needs a new yes/.test(ok(permits(HEAD, { yesFor: 'b'.repeat(40) }))));
  check('queue: a yes for another work order does not land', /no merge card for WO-2002/.test(landingProblem({ kitchen: NEW, declared, events: permits(), wo: 'WO-2002', pr: PR, head: HEAD })));
  check('queue: a later "No" replaces the yes', /not Yes/.test(ok([...permits(), { ...permits()[2], seq: 5, data: { ...permits()[2].data, answer: 'No', requestId: 'req-0008-example' } }])));
  check('queue: a "Hold" answer does not land', /"Hold", not Yes/.test(ok(permits(HEAD, { answer: 'Hold' }))));
  check('queue: an answer not by jordan does not land', /contract|not jordan/.test(yesProblem([...permits().slice(0, 2), { ...permits()[2], actor: 'engine' }], { wo: WO, pr: PR, head: HEAD })));
  // fix 1: reviewer != builder, on this head
  check('queue: no review on this head refuses landing', /no review.verdict/.test(ok(permits().filter((e) => e.kind !== 'review.verdict'))));
  check('queue: a review of another head refuses landing', /no review.verdict/.test(ok(permits(HEAD, { reviewHead: 'c'.repeat(40) }))));
  const same = reviewProblem(permits(HEAD, { builder: 'crew:verifier-1' }), { wo: WO, head: HEAD });
  check('queue: a review whose reviewer is the builder refuses landing', /is the builder|contract/.test(same), same);
  const noBuilder = reviewProblem(permits(HEAD, { builder: null }).map((e) => (e.kind === 'review.verdict' ? { ...e, data: Object.fromEntries(Object.entries(e.data).filter(([k]) => k !== 'builder')) } : e)), { wo: WO, head: HEAD });
  check('queue: a review that does not name its builder refuses landing', /builder|contract/.test(noBuilder) && noBuilder !== '', noBuilder);
  check('queue: a review that says fix refuses landing', /says fix, not ship/.test(ok(permits(HEAD, { verdict: 'fix' }))));
}

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
function testBench(check) {
  // ---- fix 3: landing reads the switch, the flags and the events from files only (a copy of core/ and a scratch state folder)
  const sqliteOk = Number(process.versions.node.split('.')[0]) > 22 || Number(process.versions.node.split('.')[1]) >= 5;
  if (!sqliteOk) { check('queue: Node 22.5 or later for the landing bench (node:sqlite)', false, process.versions.node); return; }
  const bench = landingBench();
  const L = setup({ 'src/b.txt': 'b\n' }, { 'README.md': 'm2\n' }, OWNER_NOREPLY);
  const args = { dir: L.clone, branch: 'feature', pr: PR, wo: WO, test: TEST, land: true };
  const empty = bench.run({ op: 'land', args });
  check('queue: with no event store in the state folder nothing lands, and the reason is named', !empty.ok && /event store .* cannot be read/.test(empty.reason) && mainOf(L) === L.mainHead, empty.reason);
  const seeded = bench.seed(permits(L.prHead).map((e) => (e.kind === 'decision.answered' ? { ...e, proof: 'd'.repeat(40) } : e)));
  check('queue: the bench store takes the permission events', seeded.ok, JSON.stringify(seeded));
  const stale = bench.run({ op: 'land', args });
  check('queue: from files, a yes for another head refuses landing', !stale.ok && /new push needs a new yes/.test(stale.reason) && mainOf(L) === L.mainHead, stale.reason);
  bench.seed([{ ...permits(L.prHead)[2], data: { ...permits(L.prHead)[2].data, requestId: 'req-0009-example' } }]);
  const landed = bench.run({ op: 'land', args });
  check('queue: with every permission in the files, main fast-forwards to the tested merge', landed.ok && landed.status === 'landed' && mainOf(L) === landed.merge && g(L.clone, ['rev-parse', `${landed.merge}^1`]) === L.mainHead, landed.reason);
  check('queue: the landed merge is by the owner noreply address', landed.merge && g(L.clone, ['log', '-1', '--format=%ae %ce', landed.merge]) === `${OWNER_NOREPLY} ${OWNER_NOREPLY}`);
  const ev = landed.events && landed.events[0];
  const full = ev && { v: '1.0', seq: 12, at: '2030-01-07T09:12:00Z', actor: 'engine', ...ev };
  check('queue: the merged event (sha and decision) passes the event contract', full && validate('event', full).ok && full.data.decision === 'D-7', full ? validate('event', full).errors.join('; ') : 'none');

  // main or the PR moving after the test holds it (a bench whose permissions match each new PR head)
  const mv = setup({ 'src/b.txt': 'b\n' }, { 'README.md': 'm1\n' }, OWNER_NOREPLY);
  g(mv.seed, ['checkout', '-q', '-b', 'later']);
  const later = commit(mv.seed, { 'src/c.txt': 'landed meanwhile\n' }, 'another PR landed');
  g(mv.seed, ['push', '-q', 'origin', 'later']);
  const b2 = landingBench();
  b2.seed(permits(mv.prHead));
  const rm = b2.run({ op: 'land', args: { ...args, dir: mv.clone, test: ['git', `--git-dir=${mv.origin}`, 'update-ref', 'refs/heads/main', later] } });
  check('queue: main moving after the test holds the PR to test again (never lands an untested result)', !rm.ok && /main moved .* after the test/.test(rm.reason) && mainOf(mv) === later, rm.reason);
  const pp = setup({ 'src/b.txt': 'b\n' }, { 'README.md': 'm3\n' }, OWNER_NOREPLY);
  g(pp.seed, ['checkout', '-q', 'feature']);
  const pushed = commit(pp.seed, { 'src/d.txt': 'pushed after the yes\n' }, 'a new push');
  g(pp.seed, ['push', '-q', 'origin', 'feature:refs/heads/side2']);
  g(pp.seed, ['checkout', '-q', 'main']);
  const b3 = landingBench();
  b3.seed(permits(pp.prHead));
  const rp = b3.run({ op: 'land', args: { ...args, dir: pp.clone, test: ['git', `--git-dir=${pp.origin}`, 'update-ref', 'refs/heads/feature', pushed] } });
  check('queue: a push to the PR after the test holds it (the yes and the review were for the old head)', !rp.ok && /feature moved .* old head/.test(rp.reason) && mainOf(pp) === pp.mainHead, rp.reason);
}

/** @param {(name: string, pass: unknown, detail?: string) => void} check */
export async function run(check) {
  await testDryRun(check);
  testPermissions(check);
  testBench(check);
}
