// Tests for the City (plans/city-god-mode-2026-10-26.md): towers.mjs (the data behind GET /api/towers) on throwaway state folders and
// a fake git. No browser, no network. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it (like test-scene.mjs).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeTowers, sitesOf, localRecords, buildTowers, versionOf, slugOf, repoArgOf, pourOf, ciOfRollup, githubTargets, ghCall } from './towers.mjs';
import { cityOf, scaleOf, bandOf, beaconOf, needsYou, sentence, momentsDue } from './public/city.js';

for (const k of ['PASS_GH', 'PASS_GITHUB', 'PASS_GITHUB_MS', 'PASS_TOWERS_GIT_MS']) delete process.env[k];   // the suite's fake gh is for its server, not these checks
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
    const b = JSON.stringify(buildTowers(s, r, new Map(), { isPrivateJob: (id) => id === 'J1' }));
    return !b.includes('secret') && b.includes('public words');
  })());
  check('Slug_AnyForm: owner/name from owner/name, https and ssh URLs; junk is none', slugOf('a/b') === 'a/b' && slugOf('https://github.com/a/b.git') === 'a/b' && slugOf('git@github.com:a/b.git') === 'a/b' && slugOf('C:\\x\\y') === '' && slugOf('a/../b') === '');
  check('Version_Stable: the same view gives the same version, a different one a new version', versionOf({ a: 1 }) === versionOf({ a: 1 }) && versionOf({ a: 1 }) !== versionOf({ a: 2 }));
}

// ---- G2: GitHub (a fake gh through the same runner; nothing leaves this PC) ----
{
  const F = fixture('github', {
    kitchen: (r) => ({ bootRepos: [path.join(r, 'demo-project'), path.join(r, 'old-name')], city: { history: { 'tide-demo': { github: 'demo-owner/old-private', ref: 'old-main' } } } }),
    merges: [{ pr: 2, repo: 'demo-owner/demo-project', sha: sha('b'), actor: 'claude-session', why: '', at: '2026-10-21T10:00:30Z', ok: true }],
    results: {
      'J30.pr.json': { job: 'J30', repo: 'demo-owner/demo-project', number: 9, url: 'https://github.com/demo-owner/demo-project/pull/9', pushedAt: '2026-10-23T09:00:00Z' },
      'J31.ci.json': { state: 'red' },
    },
  });
  W(path.join(F.root, 'jobs', 'archive', '2026-10', 'J33.json'), { id: 'J33', status: 'closed', vars: { private: 'yes' }, steps: [] });
  W(path.join(F.root, 'jobs', 'archive', '2026-10', 'J11.json'), { id: 'J11', status: 'closed', steps: [] });
  const jobs = [{ id: 'J30', status: 'running', steps: [mergeStep(F.dir('demo-project'))] }, { id: 'J31', status: 'running', steps: [mergeStep(F.dir('demo-project'))] }, { id: 'J32', status: 'running', vars: { private: 'yes' }, steps: [] }];
  const isPrivate = (j) => ['yes', 'true'].includes(String(j?.vars?.private || ''));
  const gh = { calls: [], fail: false, merged: {}, open: {} };
  gh.merged['demo-owner/demo-project'] = [
    { number: 1, title: 'First floor', mergedAt: '2026-10-20T09:00:00Z', mergeCommit: { oid: sha('a') }, headRefName: 'feature-a' },
    { number: 2, title: 'Second floor', mergedAt: '2026-10-21T10:00:00Z', mergeCommit: { oid: sha('b') }, headRefName: 'kitchen/J11' },
    { number: 3, title: 'my secret plan', mergedAt: '2026-10-22T10:00:00Z', mergeCommit: { oid: sha('c') }, headRefName: 'kitchen/J33' },
    { number: 4, title: 'ghost order words', mergedAt: '2026-10-22T11:00:00Z', mergeCommit: { oid: sha('d') }, headRefName: 'kitchen/J99' },
  ];
  gh.open['demo-owner/demo-project'] = [
    { number: 10, title: 'Crane with red CI', isDraft: false, createdAt: '2026-10-24T09:00:00Z', headRefName: 'kitchen/J31', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }, { status: 'COMPLETED', conclusion: 'FAILURE' }] },
    { number: 11, title: 'Draft crane', isDraft: true, createdAt: '2026-10-24T10:00:00Z', headRefName: 'hand-branch', statusCheckRollup: [] },
    { number: 12, title: 'secret crane words', isDraft: false, createdAt: '2026-10-24T11:00:00Z', headRefName: 'kitchen/J32', statusCheckRollup: [{ status: 'IN_PROGRESS', conclusion: '' }] },
  ];
  gh.merged['demo-owner/old-private'] = [{ number: 2, title: 'Old floor two', mergedAt: '2026-10-19T10:00:00Z', mergeCommit: { oid: sha('9') }, headRefName: 'x' }];
  gh.merged['demo-owner/tide-demo'] = []; gh.open['demo-owner/tide-demo'] = [];
  const git = fakeGit({ 'demo-project': { commits: 40, last: '2026-10-23T08:00:00Z', before: 7 }, 'old-name': { commits: 3, last: '2026-10-27T00:00:00Z', ref: 306 } });
  const run = async (file, args, opts) => {
    if (file === 'git') return git(file, args, opts);
    gh.calls.push(args.join(' '));
    if (gh.fail) return { err: Object.assign(new Error('exit 4'), { code: 4 }), out: 'To get started with GitHub CLI, please run:  gh auth login' };
    if (args[0] === 'api') return { err: null, out: JSON.stringify({ resources: { graphql: { remaining: 4321 } } }) };
    const slug = args[args.indexOf('-R') + 1]; const state = args[args.indexOf('--state') + 1];
    return { err: null, out: JSON.stringify((state === 'merged' ? gh.merged : gh.open)[slug] || []) };
  };
  const logs = [];
  const T = makeTowers({ root: F.root, repoHome: F.dir('old-name'), run, jobs: () => jobs, isPrivate, sigEveryMs: 0, gitEveryMs: 3600e3, github: { everyMs: 3600e3, off: false, log: (l) => logs.push(l) } });
  await T.refreshGit(); const before = T.view();
  check('GitHub_Loading: before the first read githubAt is null and the City shows the local records (the session merge, the Yard\'s crane)', before.githubAt === null && !before.githubError && before.towers.find((t) => t.key === 'demo-project').floors.some((f) => f.pr === 2) && before.towers.find((t) => t.key === 'demo-project').open.some((o) => o.pr === 9));
  await T.refreshGithub(); await new Promise((r) => setTimeout(r, 0)); await T.refreshGit();   // the stone base is counted again from GitHub's first floor
  const v = T.view(); const dp = v.towers.find((t) => t.key === 'demo-project'); const td = v.towers.find((t) => t.key === 'td');
  const f = (n) => dp.floors.find((x) => x.pr === n);
  check('GitHub_MergedFloors: every merged PR is a floor with its title and merge commit; one merged by a session keeps by session', dp.floors.length === 4 && f(1).by === 'github' && f(1).title === 'First floor' && f(1).sha === sha('a') && f(2).by === 'session' && f(2).title === 'Second floor' && f(2).job === 'J11', JSON.stringify(dp.floors));
  check('GitHub_Privacy: a private work order\'s floor and crane carry no title; an order whose file cannot be found counts as private', !('title' in f(3)) && f(3).job === 'J33' && !('title' in f(4)) && !JSON.stringify(v).includes('secret') && !JSON.stringify(v).includes('ghost order words'));
  const o = (n) => dp.open.find((x) => x.pr === n);
  check('GitHub_Cranes: GitHub\'s open PRs replace the Yard\'s own crane list: CI from the checks (a failure is red, unfinished is pending), a draft carries no load, none is unknown', dp.open.length === 3 && !o(9) && o(10).ci === 'red' && o(10).job === 'J31' && o(10).title === 'Crane with red CI' && o(11).draft === true && o(11).ci === null && o(12).ci === 'pending');
  check('GitHub_History: the old repo is read for merged PRs only (no open list), under the line', gh.calls.some((c) => c.includes('-R demo-owner/old-private --state merged')) && !gh.calls.some((c) => c.includes('-R demo-owner/old-private --state open')) && td.floors.some((x) => x.past && x.pr === 2 && x.title === 'Old floor two'));
  check('GitHub_FullThenIncremental: the first read takes every merged PR (limit 1000)', gh.calls.filter((c) => c.includes('-R demo-owner/demo-project --state merged'))[0].includes('--limit 1000'), gh.calls[0]);
  const at1 = v.githubAt; const v1 = v.v; gh.calls.length = 0; await new Promise((r) => setTimeout(r, 5)); await T.refreshGithub(); const v2 = T.view();
  check('GitHub_FullThenIncremental: the next read searches merged:>= a day before the newest (limit 200), and the old repo is not read again the same day', gh.calls.some((c) => c.includes('-R demo-owner/demo-project --state merged') && c.includes('--search merged:>=2026-10-21') && c.includes('--limit 200')) && !gh.calls.some((c) => c.includes('old-private')), gh.calls.join(' | '));
  check('GitHub_VersionStill: a read that found nothing new moves githubAt but not towersV', v2.v === v1 && v2.githubAt > at1 && T.githubAt() === v2.githubAt, JSON.stringify(v2.towers) === JSON.stringify(v.towers) ? 'same towers' : 'towers moved');
  check('GitHub_Measured: each read records its time, the lists read and the GraphQL points left', T.githubStats().reads === 4 && T.githubStats().left === 4321 && Number.isFinite(T.githubStats().ms) && /GitHub read 4 lists in \d+ ms; 4321 GraphQL points left/.test(logs.at(-1)), logs.at(-1));
  gh.fail = true; await T.refreshGithub(); const v3 = T.view(); const dp3 = v3.towers.find((t) => t.key === 'demo-project');
  check('GitHub_FailKeepsLastGood: a failed read says why in plain words, keeps githubAt at the last good read and drops no floor or crane', v3.githubError === 'demo-owner/demo-project: gh is not signed in' && v3.githubAt === v2.githubAt && dp3.floors.length === 4 && dp3.open.length === 3 && v3.v !== v2.v, String(v3.githubError));
  T.stop();
  const T2 = makeTowers({ root: F.root, repoHome: F.dir('old-name'), run: async () => ({ err: new Error('offline'), out: '' }), jobs: () => jobs, isPrivate, sigEveryMs: 0, gitEveryMs: 3600e3, github: { everyMs: 3600e3, off: true } });
  const v4 = T2.view();
  check('GitHub_LastGoodAfterRestart: a new server shows the last good read from towers-github.json before it reads again', v4.githubAt === v2.githubAt && v4.towers.find((t) => t.key === 'demo-project').floors.length === 4 && fs.existsSync(path.join(F.root, 'towers-github.json')));
  const calls0 = gh.calls.length; await T2.refreshGithub();
  check('GitHub_Off: with PASS_GITHUB=off (here off: true) nothing is read', gh.calls.length === calls0);
  T2.stop();
  check('CI_Rollup: no checks is unknown; all passed (or skipped) is green; a cancelled or errored one is red; a queued commit status is pending',
    ciOfRollup([]) === null && ciOfRollup(null) === null && ciOfRollup([{ status: 'COMPLETED', conclusion: 'SUCCESS' }, { status: 'COMPLETED', conclusion: 'SKIPPED' }]) === 'green' && ciOfRollup([{ conclusion: 'CANCELLED', status: 'COMPLETED' }]) === 'red' && ciOfRollup([{ state: 'ERROR' }]) === 'red' && ciOfRollup([{ state: 'PENDING' }]) === 'pending' && ciOfRollup([{ state: 'SUCCESS' }]) === 'green');
  check('GitHub_Targets: each repo\'s GitHub home (kitchen.repo.json, else its origin remote) once, plus the old history repo; never the Office',
    JSON.stringify(githubTargets([{ key: 'a', slug: 'o/a' }, { key: 'b', slug: '' }, { key: 'c', slug: 'o/c', office: true }, { key: 'd', slug: 'o/a', history: { slug: 'o/old' } }], new Map([['b', { remoteSlug: 'o/b' }]]))) === JSON.stringify([{ slug: 'o/a', past: false }, { slug: 'o/b', past: false }, { slug: 'o/old', past: true }]));
  check('GitHub_PlainErrors: gh\'s failures are said in plain words, never its raw output', (await ghCall(async () => ({ err: Object.assign(new Error('spawn gh ENOENT'), { code: 'ENOENT' }), out: '' }), ['pr'])).error === 'gh is not installed' && (await ghCall(async () => ({ err: new Error('x'), out: 'HTTP 404: Not Found (https://api.github.com/x)' }), ['pr'])).error === 'the repo is not on GitHub');
  check('Config_KeyFallback: shown names and history are found by key, else GitHub name, else folder name (so they hold when a Site code arrives)', td.floors.some((x) => x.past) && td.publicFrom === undefined);
}

// ---- G3: the model (public/city.js cityOf): one truth test per row of the design's section 4.1 ----
{
  const NOW = Date.parse('2026-10-26T20:00:00Z'); const ago = (ms) => new Date(NOW - ms).toISOString(); const H = 36e5, M = 6e4;
  const fl = (n, o = {}) => Array.from({ length: n }, (_, i) => ({ pr: i + 1, at: ago((n - i) * 2 * 864e5), by: 'github', ...o }));
  const tide = { key: 'td', name: 'Tide', kind: 'tower', folder: 'brain-monitor', repo: 'demo-owner/tide-demo', publicFrom: ago(H), plinth: { commits: 306, before: ago(3 * 864e5) },
    floors: [...fl(10, { past: true }), { pr: 11, at: ago(2 * H), by: 'session' }, { pr: 12, at: ago(30 * M), by: 'yard', job: 'J1' }, { pr: 13, at: ago(5 * H), undone: ago(H), job: 'J9' }],
    open: [{ pr: 20, ci: 'red', draft: false, createdAt: ago(H) }, { pr: 21, ci: null, draft: true, createdAt: ago(2 * H) }, { pr: 22, ci: 'green', draft: false, createdAt: ago(3 * H), job: 'J5' },
      { pr: 23, ci: 'pending', draft: false, createdAt: ago(10 * M), job: 'J6' }, { pr: 24, ci: 'green', createdAt: ago(M) }] };
  const gw = { key: 'demo-project', name: 'Demo', kind: 'tower', folder: 'demo-project', repo: 'demo-owner/demo-project', floors: fl(40), open: [], blueprint: { total: 98, shipped: 62 } };
  const lot = { key: 'side-app', name: 'Side app', kind: 'lot', folder: 'side-app', floors: [], open: [], plinth: { commits: 28 } };
  const office = { key: 'gemini-brain', name: 'gemini-brain', kind: 'office', folder: 'gemini-brain', floors: [], open: [], commits: 145, lastCommit: ago(3 * H) };
  const TW = { ok: true, githubAt: ago(2 * M), githubError: null, towers: [tide, gw, lot, office] };
  const job = (id, o) => ({ id, status: 'running', step: 2, steps: 4, station: 'agent', role: 'do', cook: 'claude sonnet', updated: ago(M), ...o });
  const S = { paused: true, live: true, breaker: false, stalled: false, spent: 5, budget: 20, githubAt: ago(2 * M),
    jobs: [job('J5', { tower: 'td' }), job('J6', { tower: 'td', status: 'waiting-approval' }), job('J7', { tower: 'td' }), job('J8', { tower: 'td', role: 'plan', private: true }),
      job('J10', { tower: 'td', station: 'tests', role: '' }), job('J11', { tower: 'td', step: 4 }), ...Array.from({ length: 7 }, (_, i) => job('J3' + i, { tower: 'td', status: 'pending' })),
      job('J40', { tower: 'td', status: 'needs-human', updated: ago(5 * H) }), job('J50', {}), job('J51', { status: 'pending' }), job('J52', { status: 'waiting-approval', private: true })],
    mainStatus: [{ tower: 'brain-monitor', state: 'red' }, { tower: 'demo-project', state: 'unreadable' }],
    freeze: { repos: [{ name: 'demo-project', windows: [{ from: ago(H), to: new Date(NOW + H).toISOString() }] }, { name: 'brain-monitor', windows: [{ from: new Date(NOW + 5 * H).toISOString(), to: new Date(NOW + 9 * H).toISOString(), fromText: '10-27 00:00' }] }] },
    undoUnpushed: [{ job: 'J9', state: 'unpushed' }], automergePause: { until: new Date(NOW + H).toISOString() } };
  const EV = [{ type: 'approval.requested', job: 'J6', ts: ago(90 * M) }, { type: 'approval.requested', job: 'J52', ts: ago(30 * M) }, { type: 'budget.stop', ts: ago(H) }];
  const C = cityOf(TW, S, EV, NOW, { lastSeen: ago(H) }); const L = (k) => C.lots.find((l) => l.key === k);
  const td = L('td');
  check('Model_Kinds: towers, a lot and the Office from /api/towers; orders with no Tower (research, career, private) go to the Yard lot', C.lots.map((l) => l.kind).join() === 'tower,tower,lot,office' && C.yard.running === 1 && C.yard.queued === 1 && C.yard.waiting === 1 && C.yard.private === true);
  check('Model_Floors: one floor per merged PR; a taken-down floor is not counted', td.floors === 12 && L('demo-project').floors === 40);
  check('Model_SharedScale: one k for every tower (the smallest of 1, 2, 5 ... that fits 80 art px), heights in rows of k', C.k === 1 && td.rows === 12 && scaleOf([{ kind: 'tower', floors: fl(129) }]) === 5 && scaleOf([{ kind: 'tower', floors: fl(40) }, { kind: 'tower', floors: fl(3) }]) === 1 && scaleOf([{ kind: 'tower', floors: fl(41) }]) === 2);
  check('Model_TowerBands: a Tower level keeps the newest 22 floors whole and bands older ones in k (at most 20 bands)', bandOf([{ kind: 'tower', floors: fl(129) }]) === 10 && bandOf([{ kind: 'tower', floors: fl(122) }]) === 5);
  check('Model_StoneBase: drawn iff the commit count is known; a lot is all stone base', td.plinth === 306 && L('demo-project').plinth === 0 && L('side-app').plinth === 28);
  check('Model_PublicLine: the "public from" line sits above the old floors, only when publicFrom is sent', td.publicAt === 10 && L('demo-project').publicAt === null);
  check('Model_LitWindows: lit iff the floor merged in the last 24 h', td.lit === 2 && L('demo-project').lit === 0);
  check('Model_NewFlag: floors since the phone\'s last look are new; with no last look, none is', td.fresh === 1 && cityOf(TW, S, EV, NOW).lots[0].fresh === 0);
  check('Model_Blueprint: the planned outline iff the Tower has a Blueprint', L('demo-project').blueprint?.total === 98 && td.blueprint === null);
  check('Model_Cranes: one per open PR; 3 shown, sign-off first, then a crew on it, then red CI, then the newest; the rest are "+N"', td.cranes.map((c) => c.pr).join() === '23,22,20' && td.craneMore === 2, td.cranes.map((c) => c.pr).join());
  check('Model_CraneTag: red, pending or green from CI; none when unknown; a draft carries no load', td.cranes.find((c) => c.pr === 20).ci === 'red' && td.cranes.find((c) => c.pr === 23).ci === 'pending' && cityOf({ towers: [{ ...tide, open: [tide.open[1]] }] }, {}, [], NOW).lots[0].cranes[0].ci === null && cityOf({ towers: [{ ...tide, open: [tide.open[1]] }] }, {}, [], NOW).lots[0].cranes[0].draft === true);
  check('Model_Crews: a running order on the Tower is a crew (its crew colour, its station\'s tool, its height = step/steps); 3, then "+N"; a private one shows a lock', td.crews.length === 3 && td.crewMore === 1 && td.crews[0].cook === 'claude' && td.crews[0].tool === 'build' && td.crews[0].lift === 0.5 && td.crews.find((c) => c.id === 'J8').private && td.crews.find((c) => c.id === 'J8').tool === 'survey' && td.crews.find((c) => c.id === 'J10').tool === 'test' && td.cranes.find((c) => c.pr === 22).crew?.id === 'J5');
  check('Model_Pallets: queued orders on the Tower are pallets at the base: 5, then "+N"', td.pallets === 5 && td.palletMore === 2);
  check('Model_Beacon: a sign-off waiting on the Tower lights a beacon; its colour from when it was asked: warm, amber at 1 h, red at 4 h', td.beacon === 'red' && td.cranes.find((c) => c.pr === 23).beacon === 'amber' && beaconOf(NOW - 10 * M, NOW) === 'warm' && td.waiting === 2 && C.yard.beacon === 'warm');
  check('Model_Scaffold: red main puts up scaffolding, matched by folder name or GitHub name; unreadable shows "?"; no record draws nothing', td.scaffold === 'red' && L('demo-project').scaffold === '?' && cityOf(TW, { ...S, mainStatus: [{ tower: 'tide-demo', state: 'red' }] }, [], NOW).lots[0].scaffold === 'red' && cityOf(TW, { ...S, mainStatus: [] }, [], NOW).lots[0].scaffold === null);
  check('Model_Freeze: barrier tape while a window is on now; a "closes" sign for one still ahead', L('demo-project').tape === 'now' && td.tape === null && td.closes === '10-27 00:00');
  check('Model_Skip: a floor taken down in the last 24 h sits in the skip; "?" iff its undo is not on GitHub yet', td.skip.length === 1 && td.skip[0].unknown === true && cityOf(TW, { ...S, undoUnpushed: [] }, [], NOW).lots[0].skip[0].unknown === false && cityOf(TW, S, [], NOW + 864e5).lots[0].skip.length === 0);
  check('Model_ManualHandover: the "manual handover" tag on the cranes while auto-merge is paused', td.manual === true && cityOf(TW, { ...S, automergePause: null }, [], NOW).lots[0].manual === false && L('side-app').manual === false);
  check('Model_Gate: PAUSED (never CLOSED), OPEN lit with AI crews on, the STOP tag for a stop-work order, the clock stopped when stalled', C.gate.paused === true && C.gate.live === true && C.gate.breaker === false && C.gate.stalled === false && cityOf(TW, { breaker: true, stalled: true }, [], NOW).gate.breaker && cityOf(TW, {}, [], NOW).gate.paused === null);
  check('Model_Budget: 8 segments, floor(8 x spent / budget) clamped; the padlock iff the cap stopped work today; nothing without a budget', C.gate.budget.level === 2 && C.gate.budget.stop === true && cityOf(TW, { spent: 99, budget: 20 }, [], NOW).gate.budget.level === 8 && cityOf(TW, { spent: 5 }, [], NOW).gate.budget === null);
  check('Model_GithubSign: shown iff the last good read is over 10 min old or the read failed', C.gate.github === null && cityOf({ ...TW, githubAt: ago(12 * M) }, {}, [], NOW).gate.github.text === 'GitHub read 12 min ago' && cityOf({ ...TW, githubError: 'gh is not signed in' }, S, [], NOW).gate.github.err === true);
  check('Model_Sky: the sky is the real hour (dawn, day, dusk, night), never the weather', C.sky === cityOf(TW, S, [], NOW).sky && ['dawn', 'day', 'dusk', 'night'].includes(C.sky));
  check('Model_Office: its windows are lit iff a commit in the last 24 h', L('gemini-brain').lit === 1 && cityOf({ towers: [{ ...office, lastCommit: ago(30 * H) }] }, {}, [], NOW).lots[0].lit === 0);
  const bare = cityOf({ ok: true, towers: [{ key: 'x', name: 'x', kind: 'tower', floors: [{ at: ago(30 * H) }], open: [] }] }, {}, [], NOW).lots[0];
  check('Model_TruthRule: a tower with no state and no records draws no crane, crew, pallet, beacon, scaffold, tape, skip, stone base or line', bare.cranes.length + bare.crews.length + bare.pallets + bare.lit === 0 && bare.beacon === null && bare.scaffold === null && bare.tape === null && bare.closes === null && bare.skip.length === 0 && bare.plinth === 0 && bare.publicAt === null && bare.blueprint === null);
  check('Model_States: loading (no answer yet) and error ({ok:false}) are said, never drawn as an empty City', cityOf(null, S, [], NOW).loading === true && cityOf({ ok: false, error: 'boom' }, S, [], NOW).error === 'boom' && cityOf(TW, S, [], NOW).error === null);
  check('Strip_QuietUnlessNeeded: the horizon strip calls out a beacon, a red main or PAUSED, and is quiet otherwise', needsYou(C) === true && needsYou(cityOf({ towers: [gw] }, { paused: false }, [], NOW)) === false && needsYou(cityOf({ towers: [] }, { paused: true }, [], NOW)) === true);
  check('TextTwin_Sentences: each building in words, numbers only (no titles)', sentence(td) === 'Tide: 12 floors, 5 under construction, 2 new today, 5 crews at work, 2 sign-offs waiting, main is red, closes 10-27 00:00' && sentence(L('side-app')) === 'Side app: a lot of 28 commits, no floors yet' && sentence(L('gemini-brain')) === 'gemini-brain: the Office, a commit in the last day', sentence(td));
  const before = cityOf({ towers: [{ ...tide, open: tide.open.slice(0, 1) }] }, {}, [], NOW); const after = cityOf({ towers: [{ ...tide, floors: [...tide.floors, { pr: 30, at: ago(M) }, { pr: 31, at: ago(M) }], open: tide.open.slice(0, 2) }] }, { mainStatus: [{ tower: 'td', state: 'red' }] }, [], NOW);
  const due = momentsDue(before, after, [{ type: 'approval.requested', job: 'J6', ts: ago(M) }, { type: 'step.started', job: 'J5', ts: ago(5 * M) }, { type: 'merge.undone', job: 'J50', ts: ago(M) }], NOW, S.jobs);
  check('Moments_Due: a Pour of 2 floors, a new crane and red scaffolding from what changed; a beacon from a fresh event; events over 2 min old and orders with no Tower play nothing', due.map((m) => m.type).join() === 'pour,crane,scaffold-up,beacon-on' && due[0].say === 'Tide: Pour: 2 floors' && due[3].key === 'td', due.map((m) => m.type).join());
}

// ---- the City's seams with S7 (read-only imports) and its byte budget ----
{
  const sp = await import('./public/sprites.js'); const sc = await import('./public/scene.js');
  const need = { 'sprites.js': [sp, ['PALETTE', 'paletteFor', 'toRGBA', 'SKIES', 'GLYPHS', 'mix', 'EMISSIVE']], 'scene.js': [sc, ['skyAt', 'cookOf', 'stationFor', 'COOK_COLORS', 'ticket', 'esc', 'applyCss', 'stepWord', 'mountScene', 'makeLoop']] };
  const moved = Object.entries(need).flatMap(([f, [mod, names]]) => names.filter((n) => mod[n] === undefined).map((n) => `${f} no longer exports ${n}`));
  check(`Seams_S7Exports: every sprites.js and scene.js export the City reads is still there${moved.length ? ' (MOVED: ' + moved.join('; ') + ')' : ''}`, moved.length === 0);
  const zl = await import('node:zlib');
  const files = ['city.js', 'city-art.js', 'city-nav.js'].filter((f) => fs.existsSync(new URL('./public/' + f, import.meta.url)));
  const br = files.reduce((n, f) => n + zl.brotliCompressSync(fs.readFileSync(new URL('./public/' + f, import.meta.url))).length, 0);
  check(`Budget_CityBytes: city.js + city-art.js + city-nav.js are at most 16,000 bytes brotli (${br} B in ${files.join(', ')})`, files.includes('city.js') && br <= 16000);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(JSON.stringify(out));
