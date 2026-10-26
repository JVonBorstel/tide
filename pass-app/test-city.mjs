// Tests for the City (plans/city-god-mode-2026-10-26.md): towers.mjs (the data behind GET /api/towers) on throwaway state folders and
// a fake git. No browser, no network. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it (like test-scene.mjs).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeTowers, sitesOf, localRecords, buildTowers, versionOf, slugOf, repoArgOf, pourOf } from './towers.mjs';

const out = [];
const check = (name, pass, detail = '') => out.push({ name: detail ? `${name} (${detail})` : name, pass: !!pass });
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'city-test-'));
const W = (p, v) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, typeof v === 'string' ? v : JSON.stringify(v)); };
const lines = (rows) => rows.map((r) => JSON.stringify(r)).join('\n') + '\n';
const sha = (c) => c.repeat(40);
// a fake git: answers per command, the folder's last name picks the numbers (null = git failed)
function fakeGit(table, calls = []) {
  return async (file, args) => {
    calls.push(args.join(' ')); const dir = path.basename(args[1]); const cmd = args.slice(2).join(' '); const t = table[dir] || {};
    const pick = cmd.startsWith('rev-list --count --first-parent --before=') ? t.before : cmd.startsWith('rev-list --count --first-parent') ? t.ref
      : cmd === 'rev-list --count HEAD' ? t.commits : cmd.startsWith('log -1') ? t.last : cmd === 'remote get-url origin' ? t.remote : undefined;
    return pick === undefined || pick === null ? { err: new Error('git failed'), out: '' } : { err: null, out: String(pick) + '\n' };
  };
}
// a state folder with three repos (a tower, a lot, the Office) and the records of a few merges
function fixture(name, { kitchen, merges = [], automerged = [], results = {}, jobs = {}, archive = {}, ledger = null } = {}) {
  const root = path.join(tmp, name, 'state'); const repos = path.join(tmp, name, 'repos');
  for (const r of ['demo-project', 'side-app', 'gemini-brain', 'old-name']) fs.mkdirSync(path.join(repos, r), { recursive: true });
  W(path.join(repos, 'demo-project', 'kitchen.repo.json'), { github: 'demo-owner/demo-project' });
  W(path.join(repos, 'old-name', 'kitchen.repo.json'), { github: 'https://github.com/demo-owner/tide-demo.git', site: 'TD' });
  if (kitchen !== undefined) W(path.join(root, 'kitchen.json'), typeof kitchen === 'function' ? kitchen(repos) : kitchen);
  else fs.mkdirSync(root, { recursive: true });
  if (merges.length) W(path.join(root, 'merges.jsonl'), lines(merges));
  if (automerged.length) W(path.join(root, 'automerged.jsonl'), lines(automerged));
  for (const [f, v] of Object.entries(results)) W(path.join(root, 'results', f), v);
  for (const [id, j] of Object.entries(jobs)) W(path.join(root, 'jobs', id + '.json'), { id, ...j });
  for (const [id, j] of Object.entries(archive)) W(path.join(root, 'jobs', 'archive', '2026-10', id + '.json'), { id, ...j });
  if (ledger) W(path.join(root, 'ledger.json'), ledger);
  return { root, repos, dir: (r) => path.join(repos, r) };
}
const mergeStep = (repo) => ({ script: 'C:\\k\\stations\\merge.ps1', args: { Repo: repo } });
const boot = (repos) => ({ bootRepos: ['demo-project', 'side-app', 'gemini-brain', 'old-name'].map((r) => path.join(repos, r)) });

// ---- G1: towers from the Yard's own records ----
{
  const F = fixture('local', {
    kitchen: (r) => boot(r),
    merges: [
      { pr: 1, repo: 'demo-owner/demo-project', sha: sha('a'), actor: 'claude-session', why: '', at: '2026-10-20T10:00:00Z', ok: true },
      { pr: 2, repo: 'demo-owner/demo-project', sha: sha('b'), actor: 'claude-session', why: 'batch-run integrate-p4: tested together', at: '2026-10-21T10:00:00Z', ok: true },
      { pr: 3, repo: 'demo-owner/demo-project', sha: sha('c'), actor: 'claude-session', why: '', at: '2026-10-21T11:00:00Z', ok: false },
      { pr: 9, repo: 'someone/elsewhere', sha: sha('d'), actor: 'claude-session', why: '', at: '2026-10-21T11:00:00Z', ok: true },
    ],
    automerged: [{ at: '2026-10-22T09:00:00Z', job: 'J12', name: 'x', why: 'tests pass' }, { at: '2026-10-22T12:00:00Z', job: 'J12', undone: sha('e'), why: 'broke main' }],
    results: {
      'J11.merge.json': { job: 'J11', before: sha('0'), after: sha('b'), via: 'github', at: '2026-10-21T10:00:05Z' },
      'J11.pr.json': { job: 'J11', repo: 'demo-owner/demo-project', number: 2, url: 'https://github.com/demo-owner/demo-project/pull/2', pushedAt: '2026-10-21T09:00:00Z' },
      'J12.merge.json': { job: 'J12', before: sha('0'), after: sha('e'), via: 'local', at: '2026-10-22T09:00:00Z' },
      'J13.pr.json': { job: 'J13', repo: 'demo-owner/demo-project', number: 4, url: 'https://github.com/demo-owner/demo-project/pull/4', pushedAt: '2026-10-23T09:00:00Z' },
      'J13.ci.json': { state: 'red' },
      'J14.pr.json': { job: 'J14', repo: 'demo-owner/demo-project', number: 5, url: 'https://github.com/demo-owner/demo-project/pull/5', pushedAt: '2026-10-23T10:00:00Z' },
      'J14.ci.json': { state: 'error', error: 'gh down' },
      'J15.pr.json': { job: 'J15', repo: 'demo-owner/demo-project', number: 6, url: 'https://github.com/demo-owner/demo-project/pull/6', pushedAt: '2026-10-23T10:00:00Z' },
    },
    ledger: { programs: [{ repo: 'demo-project', total: 10, shipped: 4 }, { repo: 'side-app', total: 0, shipped: 0 }] },
  });
  const dp = F.dir('demo-project');
  const jobs = [{ id: 'J12', status: 'done', steps: [mergeStep(dp)] }, { id: 'J13', status: 'running', steps: [mergeStep(dp)] }, { id: 'J14', status: 'waiting-approval', steps: [mergeStep(dp)] }, { id: 'J15', status: 'done', steps: [mergeStep(dp)] }];
  F.archived = W(path.join(F.root, 'jobs', 'archive', '2026-10', 'J11.json'), { id: 'J11', status: 'closed', steps: [mergeStep(dp)] });
  const st = sitesOf(F.root, F.dir('old-name'));
  const rec = localRecords(F.root, st.sites, jobs);
  const fl = rec.floors.get('demo-project');
  check('LocalFloors_MergesJsonl: an ok merges.jsonl line is one floor (pr, sha, at, by session); a failed merge and a repo not on this PC are not', fl.some((f) => f.pr === 1 && f.sha === sha('a') && f.by === 'session') && !fl.some((f) => f.pr === 3 || f.pr === 9));
  const two = fl.filter((f) => f.pr === 2);
  check('LocalFloors_OnePerMerge: the same PR in merges.jsonl and a work order\'s merge record is one floor, with its work order (by yard) and its Pour', two.length === 1 && two[0].job === 'J11' && two[0].by === 'yard' && two[0].pour === 'p4', JSON.stringify(two));
  const loc = fl.find((f) => f.job === 'J12');
  check('LocalFloors_YardLocalMerge: a Yard merge with no PR is a floor by its merge commit; auto-merged reads by auto; an undo marks it undone (kept, never dropped)', loc && !loc.pr && loc.sha === sha('e') && loc.by === 'auto' && loc.undone === '2026-10-22T12:00:00.000Z');
  check('LocalFloors_ArchivedOrder: a merge whose work order was archived still finds its Tower (jobs\\archive)', two[0]?.job === 'J11');
  check('LocalFloors_OldestFirst: floors run oldest first', fl.map((f) => f.at).join() === [...fl.map((f) => f.at)].sort().join());
  check('Pour_FromBatchRun: "batch-run integrate-<name>" names the Pour; other words do not', pourOf('batch-run integrate-p4: x') === 'p4' && pourOf('batch B: 74/75') === null && pourOf('') === null);
  const op = rec.open.get('demo-project');
  check('Cranes_LocalPrRecords: an active work order with a PR and no merge is a crane with its CI (red; an error look is unknown); a finished one is not', op.length === 2 && op.find((o) => o.pr === 4)?.ci === 'red' && op.find((o) => o.pr === 5)?.ci === null && !op.some((o) => o.pr === 6) && op.every((o) => o.job && o.draft === false));

  let calls = []; const git = fakeGit({ 'demo-project': { commits: 40, last: '2026-10-23T08:00:00Z', before: 7 }, 'side-app': { commits: 28, last: '2026-10-10T19:00:00Z' }, 'gemini-brain': { commits: 145, last: new Date(Date.now() - 3600e3).toISOString() }, 'old-name': { commits: 3, last: '2026-10-24T00:00:00Z' } }, calls);
  const T = makeTowers({ root: F.root, repoHome: F.dir('old-name'), run: git, jobs: () => jobs, sigEveryMs: 0, gitEveryMs: 3600e3 });
  const before = T.view();
  check('Loading_BeforeGit: before the first git read the view is ok, gitAt is null and no stone base is drawn (unknown, never 0)', before.ok && before.gitAt === null && before.towers.every((t) => !t.plinth && t.commits === undefined), JSON.stringify(before.towers.map((t) => [t.key, t.plinth])));
  await T.refreshGit(); const v = T.view(); const by = (k) => v.towers.find((t) => t.key === k);
  check('Towers_Kinds: a repo with floors is a tower, one with only commits is a lot, gemini-brain is the Office', by('demo-project').kind === 'tower' && by('side-app').kind === 'lot' && by('gemini-brain').kind === 'office' && by('td').kind === 'lot');
  check('Towers_Keys: the key is the Site code (site TD -> td), else the GitHub name, else the folder; names default to the folder (this repo reads Tide)', by('td')?.name === 'Tide' && by('demo-project').name === 'demo-project' && by('side-app').repo === null && by('td').repo === 'demo-owner/tide-demo');
  check('StoneBase_Tower: a tower\'s stone base is its first-parent commits before its first floor', by('demo-project').plinth?.commits === 7 && by('demo-project').plinth.before === '2026-10-20T10:00:00.000Z' && calls.some((c) => c.includes('--before=2026-10-20T10:00:00.000Z')));
  check('StoneBase_Lot: a lot is a stone base of all its commits, with no floors and no cranes', by('side-app').plinth?.commits === 28 && by('side-app').floors.length === 0 && by('side-app').open.length === 0);
  check('Office_LastCommit: the Office carries its commit count and last commit, never floors', by('gemini-brain').commits === 145 && !!by('gemini-brain').lastCommit && by('gemini-brain').floors.length === 0 && !by('gemini-brain').plinth);
  check('Blueprint_FromLedger: a Tower with a Blueprint carries {total, shipped}; an empty one carries none', by('demo-project').blueprint?.total === 10 && by('demo-project').blueprint.shipped === 4 && !by('side-app').blueprint);
  check('Order_FixedLeftToRight: towers by first floor, then lots and the Office in bootRepos order', v.towers.map((t) => t.key).join() === 'demo-project,side-app,td,gemini-brain');
  check('Privacy_NoLocalPaths: the view carries no folder path from this PC', !JSON.stringify(v).includes(F.repos.replace(/\\/g, '\\\\')) && !JSON.stringify(v).includes(os.homedir().replace(/\\/g, '\\\\')));
  check('TowerOf_Job: a work order with a merge Repo belongs to that Tower; one with no Repo (research, career) and one on the Office belong to none',
    T.towerOf(jobs[0]) === 'demo-project' && T.towerOf({ steps: [{ script: 'agent-step.ps1', args: {} }] }) === null && T.towerOf({ steps: [mergeStep(F.dir('gemini-brain'))] }) === null && repoArgOf({ steps: [{ args: { Repo: 'x' } }] }) === 'x');
  const v1 = T.v(); W(path.join(F.root, 'merges.jsonl'), fs.readFileSync(path.join(F.root, 'merges.jsonl'), 'utf8') + lines([{ pr: 7, repo: 'demo-owner/demo-project', sha: sha('f'), actor: 'claude-session', why: '', at: '2026-10-24T10:00:00Z', ok: true }]));
  const v2 = T.v(); const v3 = T.v();
  check('TowersV_MovesOnlyOnChange: towersV stays while nothing changed and moves when a merge is recorded', /^[0-9a-f]{12}$/.test(v1) && v1 !== v2 && v2 === v3 && T.view().towers[0].floors.length === fl.length + 1);
  T.stop();
  const G = makeTowers({ root: F.root, repoHome: F.dir('old-name'), run: fakeGit({}), jobs: () => jobs, sigEveryMs: 0, gitEveryMs: 3600e3 }); await G.refreshGit();
  check('GitFails_Unknown: when git cannot answer, counts and stone bases are left out (unknown), the floors stay', G.view().towers.every((t) => !t.plinth && t.commits === undefined) && G.view().towers[0].floors.length > 0 && G.view().gitAt !== null);
  G.stop();
}
{
  // Tide's old history on Jordan's own Board: city.history in the state folder only
  const F = fixture('history', {
    kitchen: (r) => ({ bootRepos: [path.join(r, 'old-name')], city: { names: { td: 'Tide (demo)' }, history: { td: { github: 'demo-owner/old-private', ref: 'old-main' } } } }),
    merges: [
      { pr: 40, repo: 'demo-owner/old-private', sha: sha('1'), actor: 'claude-session', why: '', at: '2026-10-22T10:00:00Z', ok: true },
      { pr: 3, repo: 'demo-owner/tide-demo', sha: sha('2'), actor: 'claude-session', why: '', at: '2026-10-26T17:30:00Z', ok: true },
      { pr: 40, repo: 'demo-owner/tide-demo', sha: sha('3'), actor: 'claude-session', why: '', at: '2026-10-27T10:00:00Z', ok: true },
    ],
    results: { 'J20.merge.json': { job: 'J20', before: sha('0'), after: sha('4'), via: 'local', at: '2026-10-21T10:00:00Z' } },
    jobs: { J20: { status: 'done', steps: [] } },
  });
  W(path.join(F.root, 'jobs', 'J20.json'), { id: 'J20', status: 'done', steps: [mergeStep(F.dir('old-name'))] });
  const T = makeTowers({ root: F.root, repoHome: F.dir('old-name'), run: fakeGit({ 'old-name': { commits: 3, last: '2026-10-27T00:00:00Z', ref: 306 } }), jobs: () => [], sigEveryMs: 0, gitEveryMs: 3600e3 });
  await T.refreshGit(); const t = T.view().towers[0];
  check('History_PublicFrom: the old repo\'s floors sit under the line (past), the public repo\'s first merged PR sets publicFrom, and the same PR number in both stays two floors',
    t.floors.filter((f) => f.past).length === 2 && t.floors.filter((f) => f.pr === 40).length === 2 && t.publicFrom === '2026-10-26T17:30:00.000Z' && t.name === 'Tide (demo)', JSON.stringify(t.floors));
  check('History_StoneBase: the stone base is the old ref\'s first-parent commits (306)', t.plinth?.commits === 306);
  check('History_LocalMergeBeforeLine: a Yard merge with no PR made before the public line counts as old history', t.floors.find((f) => f.job === 'J20')?.past === true);
  T.stop();
}
{
  // empty and error states
  const E = fixture('empty', {});
  const st = sitesOf(E.root, E.dir('demo-project'));
  check('Empty_NoKitchenJson: no state kitchen.json shows this repo alone, as a lot until it has floors', st.sites.length === 1 && st.sites[0].key === 'demo-project' && st.errors.length === 0 && buildTowers(st, localRecords(E.root, st.sites)).towers[0].kind === 'lot');
  const B = fixture('broken', { kitchen: '{ not json' });
  const sb = sitesOf(B.root, B.dir('demo-project'));
  check('Error_UnreadableKitchenJson: an unreadable kitchen.json says so and still shows this repo', sb.sites.length === 1 && /cannot be read/.test(sb.errors[0]?.error || ''));
  const M = fixture('missing', { kitchen: (r) => ({ bootRepos: [path.join(r, 'demo-project'), path.join(r, 'not-here')] }) });
  const sm = sitesOf(M.root, M.dir('demo-project'));
  check('Error_MissingFolder: a bootRepos folder that is not on this PC is named in errors (folder name only) and skipped', sm.sites.length === 1 && /not on this PC \(not-here\)/.test(sm.errors[0]?.error || '') && !sm.errors[0].error.includes(M.repos));
  const T = makeTowers({ root: E.root, repoHome: E.dir('demo-project'), run: async () => { throw new Error('boom'); }, sigEveryMs: 0, gitEveryMs: 3600e3 });
  await T.refreshGit();
  check('Error_GitThrows: a runner that throws leaves the view working (ok, no counts)', T.view().ok && T.view().towers.length === 1);
  T.stop();
  check('Privacy_PrivateTitle: a floor or crane of a private work order carries no title', (() => {
    const s = { sites: [{ key: 'x', name: 'x', n: 'x', folder: 'x', slug: 'o/x', office: false }] };
    const r = { floors: new Map([['x', [{ pr: 1, at: '2026-10-01T00:00:00Z', title: 'my secret plan', job: 'J1' }, { pr: 2, at: '2026-10-02T00:00:00Z', title: 'public words', job: 'J2' }]]]), open: new Map([['x', [{ pr: 3, title: 'secret crane', job: 'J1' }]]]) };
    const b = JSON.stringify(buildTowers(s, r, new Map(), { privateJobs: new Set(['J1']) }));
    return !b.includes('secret') && b.includes('public words');
  })());
  check('Slug_AnyForm: owner/name from owner/name, https and ssh URLs; junk is none', slugOf('a/b') === 'a/b' && slugOf('https://github.com/a/b.git') === 'a/b' && slugOf('git@github.com:a/b.git') === 'a/b' && slugOf('C:\\x\\y') === '' && slugOf('a/../b') === '');
  check('Version_Stable: the same view gives the same version, a different one a new version', versionOf({ a: 1 }) === versionOf({ a: 1 }) && versionOf({ a: 1 }) !== versionOf({ a: 2 }));
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(JSON.stringify(out));
