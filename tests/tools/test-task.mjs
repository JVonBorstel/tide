// Owns the task orchestrator's tests: the task CLI (tools/task.mjs: front matter, readiness and order, dependencies incl. "jordan",
// path-clash lanes, WIP limit, pause/resume, usage verdicts, malformed files, new/set/note, roadmap, store choice) and the workflow's
// control flow (.claude/workflows/task-orchestrate.js run against a fake agent(): pick, work, verify rounds, merge one at a time, gate,
// plan, escalation to Jordan, stops). Prints one counts line: "Task tests: N passed, M failed, 0 skipped".
// Called by tests/Test-TaskCli.ps1 (verify-all, the tests Step, CI Core step). Scratch folders under TEMP only, removed at the end;
// never the live task store or state folder; no network, no git, no model. All task data is invented.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import * as T from '../../tools/task.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const results = [];
const check = (name, pass, detail = '') => { results.push({ name: !pass && detail ? `${name} (${detail})` : name, pass: !!pass }); return !!pass; };
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tide-task-test-'));
let n = 0;
const newStore = () => { const d = path.join(root, `s${++n}`); fs.mkdirSync(d, { recursive: true }); return d; };
const put = (dir, name, text) => fs.writeFileSync(path.join(dir, name), text, 'utf8');
const fm = (lines, body = 'Body text.') => `---\n${lines.join('\n')}\n---\n\n${body}\n`;
const env0 = (extra = {}) => ({ BRAIN_KITCHEN: path.join(root, 'state-none'), ...extra });
function cli(args, env = env0()) { const lines = []; const code = T.main(args, { say: (s) => lines.push(s), env, home: path.join(root, 'home') }); const text = lines.join('\n'); let json = null; try { json = JSON.parse(text); } catch { /* text mode */ } return { code, text, json }; }
const ids = (r) => r.json.tasks.map((t) => t.id);

try {
  // ---- front matter --------------------------------------------------------------------------------------------------------------
  {
    const p = T.parseFrontMatter(fm(['title: Make the thing  # a comment', 'status: todo', 'priority: 2', 'paths:', '  - core/x/**', '  - "tests/a, b.ps1"', 'depends: [3, jordan, "#4"]', "public_title: 'It''s neutral'", 'flag: true']));
    check('frontmatter: parses key/value, block list, inline list, quotes, comments', p.ok && p.data.title === 'Make the thing' && p.data.priority === 2
      && p.data.paths.join('|') === 'core/x/**|tests/a, b.ps1' && p.data.depends.join('|') === '3|jordan|#4' && p.data.public_title === "It's neutral" && p.data.flag === true);
    const n1 = T.normalize(p.data, 7);
    check('frontmatter: depends "#4" and 3 become numbers, jordan stays', n1.ok && n1.task.depends.join('|') === '3|jordan|4');
    const round = T.parseFrontMatter(T.formatTask({ title: 'a: b # c', paths: ['x/{a,b}.js', 'y/**'], depends: [2, 'jordan'], public_title: 'true', extra: 'keep me' }, 'B'));
    check('frontmatter: format then parse round-trips special strings and keeps extra keys', round.ok && round.data.title === 'a: b # c' && round.data.paths[0] === 'x/{a,b}.js'
      && round.data.public_title === 'true' && round.data.extra === 'keep me' && round.body.trim() === 'B');
  }

  // ---- malformed files -----------------------------------------------------------------------------------------------------------
  {
    const d = newStore();
    put(d, '0001-good.md', fm(['title: good']));
    put(d, '0002-nofm.md', 'title: no front matter\n');
    put(d, '0003-open.md', '---\ntitle: never closed\n');
    put(d, '0004-badline.md', fm(['title: x', 'this is not a key value']));
    put(d, '0005-dup.md', fm(['title: x', 'title: y']));
    put(d, '0006-status.md', fm(['title: x', 'status: someday']));
    put(d, '0007-notitle.md', fm(['status: todo']));
    put(d, '0008-dep.md', fm(['title: x', 'depends: [soon]']));
    put(d, '0009-a.md', fm(['title: a'])); put(d, '0009-b.md', fm(['title: b']));
    put(d, '0010-idmismatch.md', fm(['id: 11', 'title: x']));
    put(d, '0012-needsbad.md', fm(['title: needs a bad one', 'depends: [4]']));
    put(d, '0013-selfdep.md', fm(['title: x', 'depends: [13]']));
    put(d, '0014-indent.md', fm(['title: x', '  stray: indented']));
    put(d, '0015-prio.md', fm(['title: x', 'priority: 12']));
    put(d, 'README.md', '# not a task\n');
    const s = T.loadStore(d);
    const badIds = s.bad.map((b) => b.id).sort((a, b) => a - b);
    check('malformed: each broken file is refused with a reason, good ones load', s.tasks.map((t) => t.id).sort((a, b) => a - b).join(',') === '1,12'
      && badIds.join(',') === '2,3,4,5,6,7,8,9,9,10,13,14,15', `bad ${badIds.join(',')}`);
    check('malformed: reasons are plain words', /first line must be ---/.test(s.bad.find((b) => b.id === 2).error) && /not closed/.test(s.bad.find((b) => b.id === 3).error)
      && /appears twice/.test(s.bad.find((b) => b.id === 5).error) && /used twice/.test(s.bad.find((b) => b.id === 9).error) && /indented/.test(s.bad.find((b) => b.id === 14).error));
    check('malformed: README.md and other names are not tasks', !s.bad.some((b) => /README/.test(b.file)));
    const nx = cli(['next', '--store', d, '--json']);
    check('malformed: next never picks a malformed file and still picks good ones', nx.code === 0 && ids(nx).join(',') === '1' && nx.json.malformed === 13);
    const l = cli(['list', '--store', d, '--json']);
    check('malformed: a task depending on a malformed one waits and says why', l.json.tasks.find((t) => t.id === 12).waits.join() === 'task 4 is malformed');
    const c = cli(['check', '--store', d, '--json']);
    check('malformed: check exits 1 and lists every problem', c.code === 1 && c.json.problems.length >= 14);
    check('malformed: set refuses a malformed task', cli(['set', '6', 'status=todo', '--store', d]).code === 1);
    const before = fs.readFileSync(path.join(d, '0001-good.md'), 'utf8');
    check('set: an invalid edit is refused and the file is unchanged', cli(['set', '1', 'status=maybe', '--store', d]).code === 1 && fs.readFileSync(path.join(d, '0001-good.md'), 'utf8') === before);
  }

  // ---- readiness, order, dependencies ----------------------------------------------------------------------------------------------
  {
    const d = newStore();
    put(d, '0001-m-late.md', fm(['title: later milestone', 'kind: milestone', 'order: 2']));
    put(d, '0002-m-first.md', fm(['title: first milestone', 'kind: milestone', 'order: 1']));
    put(d, '0003-m-jordan.md', fm(['title: needs jordan', 'kind: milestone', 'order: 3', 'depends: [jordan]']));
    put(d, '0010-a.md', fm(['title: a', 'milestone: 1', 'paths: [a/**]']));
    put(d, '0011-b.md', fm(['title: b', 'milestone: 2', 'paths: [b/**]']));
    put(d, '0012-c.md', fm(['title: c', 'priority: 1', 'paths: [c/**]']));
    put(d, '0013-d.md', fm(['title: d', 'paths: [d/**]']));
    put(d, '0014-e.md', fm(['title: e', 'depends: [jordan]', 'paths: [e/**]']));
    put(d, '0015-f.md', fm(['title: f', 'depends: [16]', 'paths: [f/**]']));
    put(d, '0016-g.md', fm(['title: g', 'status: doing', 'paths: [g/**]']));
    put(d, '0017-h.md', fm(['title: h', 'depends: [18]', 'paths: [h/**]']));
    put(d, '0018-i.md', fm(['title: i', 'status: done', 'paths: [i/**]']));
    put(d, '0019-j.md', fm(['title: j', 'depends: [99]', 'paths: [j/**]']));
    put(d, '0020-k.md', fm(['title: k', 'milestone: 3', 'paths: [k/**]']));
    put(d, '0021-l.md', fm(['title: l', 'depends: [22]', 'paths: [l/**]']));
    put(d, '0022-m.md', fm(['title: m', 'status: dropped', 'paths: [m/**]']));
    const rows = T.analyze(T.loadStore(d));
    const order = T.readyOrder(rows).map((t) => t.id);
    check('order: priority first, then milestone roadmap order, then number', order.join(',') === '12,11,10,13,17', order.join(','));
    const w = (id) => rows.find((t) => t.id === id).waits.join('; ');
    check('deps: "jordan" means waiting on Jordan', w(14) === 'jordan');
    check('deps: a task waits on an unfinished dependency and names its status', w(15) === 'task 16 (doing)');
    check('deps: a done dependency frees the task', rows.find((t) => t.id === 17).ready);
    check('deps: an unknown dependency is named', w(19) === 'task 99 does not exist');
    check('deps: a dropped dependency is named, never treated as done', w(21) === 'task 22 was dropped');
    check('deps: a task inherits its milestone\'s jordan dependency', w(20) === 'jordan (milestone 3)');
    check('deps: milestones are never picked as work', !rows.find((t) => t.id === 1).ready);
    const nx = cli(['next', '--store', d, '--json']);
    check('next: one lane by default, the first in order', ids(nx).join(',') === '12' && nx.json.state === 'picked');
  }

  // ---- lanes: path clashes and the WIP limit ---------------------------------------------------------------------------------------
  {
    const c = T.pathsClash;
    check('clash: the same file clashes', c(['a/b.js'], ['a/b.js']));
    check('clash: a folder and a file inside it clash', c(['core/ledger'], ['core/ledger/x.mjs']));
    check('clash: siblings with a shared name prefix do not', !c(['tests/Test-Ship.ps1'], ['tests/Test-ShipX.ps1']));
    check('clash: a glob and a file under it clash', c(['core/ledger/**'], ['core/ledger/db.mjs']));
    check('clash: a glob and an unrelated file do not', !c(['core/ledger/**'], ['tests/Test-CoreLedger.ps1']));
    check('clash: a name glob and a file it could match clash', c(['tests/Test-Core*.ps1'], ['tests/Test-CoreLedger.ps1']));
    check('clash: case and slashes are normalized (Windows)', c(['Core\\Ledger\\**'], ['core/ledger/a.mjs']));
    check('clash: no declared paths clashes with everything', c([], ['x']) && c(['x'], []));
    const d = newStore();
    put(d, '0001-a.md', fm(['title: a', 'paths: [core/ledger/**]']));
    put(d, '0002-b.md', fm(['title: b', 'paths: [core/ledger/db.mjs]']));
    put(d, '0003-c.md', fm(['title: c', 'paths: [pass-app/work/**]']));
    put(d, '0004-d.md', fm(['title: d']));
    put(d, '0005-e.md', fm(['title: e', 'paths: [docs/x.md]']));
    put(d, '0006-f.md', fm(['title: f', 'paths: [scripts/y.ps1]']));
    put(d, '0007-g.md', fm(['title: g', 'paths: [tools/z.mjs]']));
    const two = cli(['next', '--lanes', '2', '--store', d, '--json']);
    check('lanes: two lanes skip the task whose paths clash', ids(two).join(',') === '1,3' && two.json.skipped.some((s) => s.id === 2 && /clash with task 1/.test(s.why)));
    const nine = cli(['next', '--lanes', '9', '--store', d, '--json']);
    check('lanes: never above the WIP limit of 4, and says so', ids(nine).length === 4 && /WIP limit/.test(nine.json.note) && ids(nine).join(',') === '1,3,5,6');
    check('lanes: a task with no paths never runs beside another', !ids(nine).includes(4));
    check('lanes: --lanes 0 is a bad argument', cli(['next', '--lanes', '0', '--store', d]).code === 2);
    const claim = cli(['next', '--lanes', '2', '--claim', '--store', d, '--json']);
    const s = T.analyze(T.loadStore(d));
    check('claim: --claim marks the picked tasks doing, claimed by the orchestrator', ids(claim).join(',') === '1,3' && s.filter((t) => t.status === 'doing' && t.claimed_by === 'orchestrator').map((t) => t.id).join(',') === '1,3');
    const after = cli(['next', '--lanes', '4', '--store', d, '--json']);
    check('lanes: in-flight tasks count toward WIP and their paths block clashing ones', ids(after).join(',') === '5,6' && after.json.skipped.some((x) => x.id === 2));
    cli(['set', '5', 'status=review', '--store', d]); cli(['set', '6', 'status=doing', 'claimed_by=session', '--store', d]);
    const full = cli(['next', '--store', d, '--json']);
    check('WIP: four in flight means nothing new starts', ids(full).length === 0 && full.json.state === 'wip');
    const res = cli(['next', '--lanes', '4', '--resume', '--store', d, '--json']);
    check('resume: --resume returns the orchestrator\'s own in-flight tasks, not a session\'s', ids(res).join(',') === '1,3' && res.json.tasks.every((t) => t.resume) && res.json.state === 'resume');
    const d2 = newStore();
    put(d2, '0001-a.md', fm(['title: a', 'status: doing', 'paths: [a/**]']));
    put(d2, '0002-b.md', fm(['title: b', 'paths: [a/b.js]']));
    const cl = cli(['next', '--store', d2, '--json']);
    check('state: "clash" when every ready task clashes with work in flight', ids(cl).length === 0 && cl.json.state === 'clash');
    const d3 = newStore(); put(d3, '0001-a.md', fm(['title: a', 'status: done']));
    check('state: "empty" when nothing is ready (the orchestrator then plans)', cli(['next', '--store', d3, '--json']).json.state === 'empty');
  }

  // ---- pause / resume and usage ----------------------------------------------------------------------------------------------------
  {
    const d = newStore(); put(d, '0001-a.md', fm(['title: a', 'paths: [a]']));
    check('pause: needs a reason', cli(['pause', '--store', d]).code === 2);
    check('pause: writes the flag', cli(['pause', '--reason', 'lunch', '--store', d]).code === 0 && T.readPause(d).paused && T.readPause(d).reason === 'lunch');
    const p = cli(['next', '--claim', '--store', d, '--json']);
    check('pause: next stops at the pick (exit 3), picks nothing and claims nothing', p.code === 3 && p.json.paused && p.json.tasks.length === 0
      && T.loadStore(d).tasks[0].status === 'todo');
    check('pause: state reports it', /PAUSED/.test(cli(['state', '--store', d]).text));
    check('resume: clears the flag and next picks again', cli(['resume', '--store', d]).code === 0 && cli(['next', '--store', d, '--json']).json.tasks.length === 1);
    const st = path.join(root, 'state-usage'); fs.mkdirSync(st, { recursive: true });
    const usage = (f, s) => fs.writeFileSync(path.join(st, 'plan-usage.json'), JSON.stringify({ claude: { at: '2030-01-01T00:00:00Z', fiveHour: { used: f, resetsAt: '2030-01-01T05:00:00Z' }, sevenDay: { used: s, resetsAt: '2030-01-07T00:00:00Z' } } }));
    const env = env0({ BRAIN_KITCHEN: st });
    usage(0.5, 0.95);
    const stop = cli(['next', '--store', d, '--json'], env);
    check('usage: weekly at 95% stops (exit 3, nothing picked)', stop.code === 3 && stop.json.stop === 'stop' && stop.json.tasks.length === 0);
    usage(1.0, 0.5);
    const pz = cli(['next', '--store', d, '--json'], env);
    check('usage: a full 5-hour window only pauses, naming the reset', pz.code === 3 && pz.json.stop === 'pause' && /2030-01-01T05/.test(pz.json.reason));
    usage(0.99, 0.94);
    check('usage: 99% of the 5-hour window and 94% weekly still go (get the most done)', cli(['next', '--store', d, '--json'], env).json.tasks.length === 1);
    check('usage: no usage file is "unknown", not a stop', T.usageVerdict(path.join(root, 'nope.json')).verdict === 'go');
  }

  // ---- new, set, note, show, roadmap -----------------------------------------------------------------------------------------------
  {
    const d = path.join(newStore(), 'fresh'); // does not exist yet: new creates it
    const m = cli(['new', '--kind', 'milestone', '--title', 'Ledger lane', '--order', '1', '--public-title', 'Ledger', '--store', d, '--json']);
    const a = cli(['new', '--title', 'Private words here', '--milestone', '1', '--paths', 'core/ledger/**,tests/Test-CoreLedger.ps1', '--depends', 'jordan', '--public-title', 'Ledger import', '--body', '## Goal\nsecret plan', '--store', d, '--json']);
    check('new: numbers from 1, creates the folder, names the file from the title', m.code === 0 && m.json.id === 1 && a.json.id === 2 && /0002-private-words-here\.md$/.test(a.json.file));
    const t2 = T.loadStore(d).tasks.find((t) => t.id === 2);
    check('new: fields land typed', t2.milestone === 1 && t2.paths.length === 2 && t2.depends.join() === 'jordan' && t2.public_title === 'Ledger import' && /secret plan/.test(t2.body));
    put(d, '0007-hand.md', fm(['title: hand made']));
    check('new: the next number is one past the highest in use', cli(['new', '--title', 'x', '--store', d, '--json']).json.id === 8);
    check('new: refuses a bad field without writing a file', cli(['new', '--title', 'x', '--priority', '0', '--store', d]).code === 1 && !fs.readdirSync(d).some((f) => f.startsWith('0009')));
    const sx = T.createTask(d, { title: 'race' }); fs.writeFileSync(path.join(d, '0010-squatter.md'), fm(['title: squat']));
    check('new: an exclusive create never reuses a taken number', sx.id === 9 && T.createTask(d, { title: 'after' }).id === 11);
    check('set: key=value and key+=item', cli(['set', '2', 'status=review', 'pr=41', 'depends+=8', '--store', d]).code === 0
      && (() => { const t = T.loadStore(d).tasks.find((x) => x.id === 2); return t.status === 'review' && t.pr === 41 && t.depends.join() === 'jordan,8'; })());
    check('set: key= removes an optional field; title cannot be removed; id cannot be set', cli(['set', '2', 'pr=', '--store', d]).code === 0 && !('pr' in T.loadStore(d).tasks.find((x) => x.id === 2))
      && cli(['set', '2', 'title=', '--store', d]).code === 1 && cli(['set', '2', 'id=5', '--store', d]).code === 1);
    check('set: the body survives an edit', /secret plan/.test(T.loadStore(d).tasks.find((x) => x.id === 2).body));
    check('note: appends dated lines under ## Log', cli(['note', '2', '--text', 'first', '--store', d]).code === 0 && cli(['note', '2', '--text', 'second', '--store', d]).code === 0
      && /## Log\n- \d{4}-\d\d-\d\d \d\d:\d\d first\n- \d{4}-\d\d-\d\d \d\d:\d\d second/.test(T.loadStore(d).tasks.find((x) => x.id === 2).body));
    const l = cli(['list', '--store', d, '--json']);
    check('privacy: list and next JSON never carry a task body', !JSON.stringify(l.json).includes('secret plan') && !JSON.stringify(cli(['next', '--store', d, '--json']).json).includes('secret plan'));
    check('show: prints the whole file (local use only)', /secret plan/.test(cli(['show', '2', '--store', d]).text) && cli(['show', '99', '--store', d]).code === 1);
    // roadmap
    const r = newStore();
    put(r, '0001-m2.md', fm(['title: second', 'kind: milestone', 'order: 2']));
    put(r, '0002-m1.md', fm(['title: first', 'kind: milestone', 'order: 1', 'status: done']));
    put(r, '0003-m3.md', fm(['title: third', 'kind: milestone', 'order: 3', 'depends: [jordan]']));
    put(r, '0004-t.md', fm(['title: t', 'milestone: 1', 'status: done']));
    put(r, '0005-t.md', fm(['title: t', 'milestone: 1']));
    put(r, '0006-t.md', fm(['title: t', 'milestone: 3']));
    const rm = cli(['roadmap', '--store', r, '--json']);
    check('roadmap: milestones in roadmap order with task counts', rm.json.milestones.map((x) => x.id).join(',') === '2,1,3' && rm.json.milestones[1].tasks.total === 2 && rm.json.milestones[1].tasks.done === 1 && rm.json.milestones[1].tasks.ready === 1);
    const rn = cli(['roadmap', '--next', '--store', r, '--json']);
    check('roadmap --next: the first open milestone not waiting on anything', rn.json.next.id === 1 && rn.json.waiting.some((x) => x.id === 3 && x.waits.join() === 'jordan'));
    check('roadmap: a task in a jordan milestone counts as needing Jordan', rm.json.milestones[2].tasks.jordan === 1);
    cli(['set', '1', 'status=done', '--store', r]);
    check('roadmap --next: null when every open milestone waits', cli(['roadmap', '--next', '--store', r, '--json']).json.next === null);
    // check: cycles
    const cy = newStore();
    put(cy, '0001-a.md', fm(['title: a', 'depends: [2]'])); put(cy, '0002-b.md', fm(['title: b', 'depends: [3]'])); put(cy, '0003-c.md', fm(['title: c', 'depends: [1]']));
    const cc = cli(['check', '--store', cy, '--json']);
    check('check: finds a dependency cycle', cc.code === 1 && cc.json.problems.some((p) => /cycle: 1 -> 2 -> 3 -> 1/.test(p)));
    check('check: a clean store passes', cli(['check', '--store', r]).code === 0);
  }

  // ---- start (one task) and the one-orchestrator lock ------------------------------------------------------------------------------
  {
    const d = newStore();
    put(d, '0001-a.md', fm(['title: a', 'paths: [a]']));
    put(d, '0002-b.md', fm(['title: b', 'depends: [jordan]']));
    put(d, '0003-c.md', fm(['title: c', 'status: review', 'pr: 9']));
    put(d, '0004-m.md', fm(['title: m', 'kind: milestone']));
    cli(['pause', '--reason', 'away', '--store', d]);
    const sp = cli(['start', '1', '--run', 'new', '--store', d, '--json']);
    check('start: paused stops /task-start too (exit 3), claims nothing, takes no lock', sp.code === 3 && sp.json.paused && T.loadStore(d).tasks[0].status === 'todo' && !T.readLock(d));
    cli(['resume', '--store', d]);
    const st = path.join(root, 'state-start'); fs.mkdirSync(st, { recursive: true });
    fs.writeFileSync(path.join(st, 'plan-usage.json'), JSON.stringify({ claude: { fiveHour: { used: 0.2 }, sevenDay: { used: 0.97, resetsAt: '2030-01-07T00:00:00Z' } } }));
    const su = cli(['start', '1', '--store', d, '--json'], env0({ BRAIN_KITCHEN: st }));
    check('start: a usage stop stops /task-start too (exit 3)', su.code === 3 && su.json.stop === 'stop' && T.loadStore(d).tasks[0].status === 'todo');
    const ok = cli(['start', '1', '--run', 'new', '--store', d, '--json']);
    const t1 = T.loadStore(d).tasks.find((t) => t.id === 1);
    check('start: a ready task is claimed with this run id, under the lock', ok.code === 0 && ok.json.state === 'picked' && ok.json.run && t1.status === 'doing' && t1.claimed_by === 'orchestrator' && t1.run === ok.json.run && T.readLock(d).run === ok.json.run);
    const again = cli(['start', '1', '--run', 'new', '--store', d, '--json']);
    check('lock: a second orchestrator is refused while the first is alive (exit 3)', again.code === 3 && /another orchestrator is running/.test(again.json.reason) && again.json.state === 'locked');
    check('start: an in-flight task resumes, unchanged', (() => { const r = cli(['start', '3', '--run', ok.json.run, '--store', d, '--json']); return r.code === 0 && r.json.state === 'resume' && r.json.tasks[0].resume && r.json.tasks[0].pr === 9; })());
    check('start: a task waiting on jordan is not started (exit 1, says why)', (() => { const r = cli(['start', '2', '--run', ok.json.run, '--store', d, '--json']); return r.code === 1 && /waits on: jordan/.test(r.json.why); })());
    check('start: a milestone or a missing number is not started', cli(['start', '4', '--store', d]).code === 1 && cli(['start', '99', '--store', d]).code === 1 && cli(['start', '--store', d]).code === 2);
    check('lock: a run id that does not hold the lock is refused', cli(['next', '--run', 'someone-else', '--store', d, '--json']).code === 3 && cli(['lock', 'heartbeat', '--run', 'x', '--store', d]).code === 3);
    const before = T.readLock(d).heartbeat;
    const nx = cli(['next', '--claim', '--run', ok.json.run, '--store', d, '--json']);
    check('lock: next with the holder\'s run id beats the heartbeat', nx.code === 0 && T.readLock(d).heartbeat >= before && nx.json.run === ok.json.run);
    check('lock: release by someone else is refused; by the holder it frees', cli(['lock', 'release', '--run', 'x', '--store', d]).code === 1 && cli(['lock', 'release', '--run', ok.json.run, '--store', d]).code === 0 && !T.readLock(d));
    fs.writeFileSync(path.join(d, '.orchestrator.lock'), JSON.stringify({ run: 'dead-run', at: '2020-01-01T00:00:00Z', heartbeat: '2020-01-01T00:00:00Z' }));
    const take = cli(['lock', 'acquire', '--store', d, '--json']);
    check('lock: a stale lock (a run that died at a usage cap) is taken over and said so', take.code === 0 && /took over a stale lock \(run dead-run/.test(take.json.tookOver) && T.readLock(d).run === take.json.run);
    check('lock: release --force frees any lock; status reads it', cli(['lock', 'status', '--store', d]).text.includes(take.json.run) && cli(['lock', 'release', '--force', '--store', d]).code === 0 && /not locked/.test(cli(['lock', 'status', '--store', d]).text));
    fs.writeFileSync(path.join(d, '.orchestrator.lock'), 'garbage');
    check('lock: an unreadable lock is judged by its file time (fresh = held)', cli(['lock', 'acquire', '--store', d]).code === 3);
    check('lock: bad sub-commands and values are bad arguments', cli(['lock', 'frob', '--store', d]).code === 2 && cli(['lock', 'heartbeat', '--store', d]).code === 2 && cli(['lock', 'acquire', '--stale-minutes', '0', '--store', d]).code === 2);
    cli(['set', '1', 'merged=0123456', '--store', d]);
    check('set: a merge sha made only of digits stays text', T.loadStore(d).tasks.find((t) => t.id === 1).merged === '0123456');
  }

  // ---- where the store is ----------------------------------------------------------------------------------------------------------
  {
    const home = path.join(root, 'home'); const st = path.join(root, 'state-cfg'); fs.mkdirSync(st, { recursive: true });
    check('store: --store wins', T.resolveStore('X:/a', { TIDE_TASKS_DIR: 'Y:/b' }, home).source === '--store');
    check('store: then TIDE_TASKS_DIR', T.resolveStore('', { TIDE_TASKS_DIR: path.join(root, 'envstore'), BRAIN_KITCHEN: st }, home).dir === path.join(root, 'envstore'));
    fs.writeFileSync(path.join(st, 'tasks.json'), JSON.stringify({ store: '%USERPROFILE%/private-tasks' }));
    const c = T.resolveStore('', { BRAIN_KITCHEN: st }, home);
    check('store: then "store" in the state folder\'s tasks.json, %USERPROFILE% expanded', c.dir === path.resolve(home, 'private-tasks') && c.source.endsWith('tasks.json'));
    fs.writeFileSync(path.join(st, 'tasks.json'), '{nope');
    check('store: a broken tasks.json is a bad argument, never a silent default', cli(['where'], { BRAIN_KITCHEN: st }).code === 2);
    check('store: default is <home>/gemini-brain/projects/tide/tasks', T.resolveStore('', { BRAIN_KITCHEN: path.join(root, 'none') }, home).dir === path.join(home, 'gemini-brain', 'projects', 'tide', 'tasks'));
    check('cli: unknown command and missing values are bad arguments', cli(['frobnicate']).code === 2 && cli(['list', '--store']).code === 2);
  }

  // ---- the workflow, against a fake agent() ----------------------------------------------------------------------------------------
  const wfFile = path.join(repo, '.claude', 'workflows', 'task-orchestrate.js');
  const wfSrc = fs.readFileSync(wfFile, 'utf8').replace(/\r\n/g, '\n'); // a Windows checkout may hold CRLF
  {
    const metaText = /^export const meta = (\{[\s\S]*?\n\})\n/m.exec(wfSrc)[1];
    check('workflow: meta is a pure literal (no ${}, calls or spreads)', !/\$\{|\.\.\.|\w\(/.test(metaText.replace(/'[^']*'/g, "''")));
    const meta = new Function(`return ${metaText}`)();
    const used = [...wfSrc.matchAll(/phase\('([A-Za-z]+)'\)|phase: '([A-Za-z]+)'/g)].map((m) => m[1] || m[2]);
    check('workflow: every phase used is declared in meta.phases', meta.name === 'task-orchestrate' && used.every((u) => meta.phases.some((p) => p.title === u)), used.join(','));
    check('workflow: no Date.now, Math.random or argless new Date (they break resume)', !/Date\.now\(|Math\.random\(|new Date\(\)/.test(wfSrc));
  }
  const AsyncFunction = (async () => {}).constructor;
  async function runWf(args, handler) {
    const body = wfSrc.replace(/^export const meta\s*=/m, 'const meta =');
    const calls = []; const logs = []; let live = 0; let maxMerge = 0;
    const agent = async (prompt, opts = {}) => {
      calls.push({ prompt, opts });
      const isMerge = /^merge /.test(opts.label || '');
      if (isMerge) { live++; maxMerge = Math.max(maxMerge, live); }
      await new Promise((r) => setTimeout(r, isMerge ? 5 : 1));
      try { return await handler(opts.label || '', prompt, opts, calls); } finally { if (isMerge) live--; }
    };
    const parallel = (thunks) => Promise.all(thunks.map((t) => Promise.resolve().then(t).catch(() => null)));
    const fn = new AsyncFunction('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', body);
    let out; let error = null;
    try { out = await fn(agent, parallel, null, () => {}, (m) => logs.push(m), args, { total: null }, null); } catch (e) { error = e; }
    return { out, calls, logs, error, maxMerge, labels: calls.map((c) => c.opts.label) };
  }
  const H = 'abcdef1234567890abcdef1234567890abcdef12'; const H2 = '1234567abcdef1234567abcdef1234567abcdef1';
  const CTX = { checkout: 'X:\\repo', cli: 'X:\\repo\\tools\\task.mjs', store: 'X:\\store', wtRoot: 'X:\\wt', mainSha: 'abc123', visibility: 'PUBLIC', run: 'r1' };
  const task = (id, extra = {}) => ({ id, public_title: `Public ${id}`, paths: [`p${id}/**`], resume: false, pr: 0, branch: '', ...extra });
  const pickSeq = (...batches) => { let i = 0; return () => { const b = batches[Math.min(i++, batches.length - 1)]; return { ...CTX, paused: false, stop: '', reason: '', state: b.length ? 'picked' : 'empty', why: b.length ? 'picked' : 'nothing is ready', tasks: b }; }; };
  const built = (pr) => ({ ok: true, pr, branch: `task/${pr}`, worktree: `X:\\wt\\task-${pr}`, head: H, tests: 'Suite 3/0', outsidePaths: [], privacyScan: 'hits 0', blocked: '' });
  const green = { testsPass: true, tests: 'PARTIAL PASS: 2 of 9 suites', failing: [], ci: 'green', ciFailing: [], head: H };
  const ship = { verdict: 'SHIP', head: H, fixes: [], notes: [], privacyOk: true, why: 'fine' };
  const mergedOk = { merged: true, sha: 'm1', refusal: '', behind: false, passAppChanged: false, boardRedeploy: 'not needed', worktreeRemoved: true };
  const gateOk = { base: 'g1', privacyRan: true, privacyHits: 0, testsOk: true, tests: 'ok', tidyTask: 0, problems: [], paused: false };
  const plan0 = { milestone: 0, raised: [], milestoneDone: false, why: 'the roadmap waits on Jordan' };
  const dont = { verdict: "DON'T SHIP", head: H, fixes: ['wrong approach'], notes: [], privacyOk: true, why: 'no' };
  const std = (pick, over = {}) => (label, prompt) => {
    for (const [k, v] of Object.entries(over)) if (label.startsWith(k)) return typeof v === 'function' ? v(label, prompt) : v;
    if (label.startsWith('pick')) return pick();
    if (label.startsWith('work') || label.startsWith('fix')) return built(Number(/(\d+)/.exec(label)[1]));
    if (label.startsWith('checks') || label.startsWith('ci ')) return green;
    if (label.startsWith('review')) return ship;
    if (label.startsWith('merge')) return mergedOk;
    if (label.startsWith('gate')) return gateOk;
    if (label.startsWith('plan')) return plan0;
    return { ok: true, why: 'done' };
  };
  const promptOf = (r, l) => (r.calls.find((c) => c.opts.label === l) || { prompt: '' }).prompt;

  {
    const r = await runWf('', std(pickSeq([task(5)], [])));
    const byLabel = (l) => r.calls.find((c) => c.opts.label === l);
    check('wf happy path: work -> checks + review -> merge -> plan (nothing) -> final gate -> unlock', !r.error && r.out.merged.length === 1 && r.out.merged[0].task === 5
      && r.labels.join(',') === 'pick (resume),work 5,checks 5,review 5,merge 5,pick,plan,gate (final),unlock', r.error ? r.error.message : r.labels.join(','));
    check('wf models: pick and merge haiku, review and plan and gate sonnet, work inherits', byLabel('pick (resume)').opts.model === 'haiku' && byLabel('merge 5').opts.model === 'haiku'
      && byLabel('review 5').opts.model === 'sonnet' && byLabel('plan').opts.model === 'sonnet' && byLabel('gate (final)').opts.model === 'sonnet' && byLabel('work 5').opts.model === undefined);
    check('wf lock: the first pick takes the lock and resumes, later picks carry the run id, the end releases it',
      /next --lanes 1 --claim --resume --run new --json/.test(byLabel('pick (resume)').prompt) && /next --lanes 1 --claim --run r1 --json/.test(byLabel('pick').prompt)
      && /lock release --run r1/.test(byLabel('unlock').prompt) && /lock heartbeat --run r1/.test(byLabel('checks 5').prompt) && /lock heartbeat --run r1/.test(byLabel('merge 5').prompt));
    const w = byLabel('work 5').prompt;
    check('wf work: own worktree and branch, noreply identity, trailer, PR title from the public title only, PR body ending',
      w.includes('X:\\wt\\task-5') && w.includes('-b task/5 origin/main') && w.includes('user.email=204934145+JVonBorstel@users.noreply.github.com')
      && w.includes('Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>') && w.includes('--title "WO-TASK-5: Public 5"') && w.includes('🤖 Generated with [Claude Code](https://claude.com/claude-code)'));
    check('wf work: privacy scan before every push counts "hits", never "live"; never force', /Before every push/.test(w) && w.includes('public-tide-scan.ps1') && /"hits" array/.test(w) && /never a hit count/.test(w) && /never --force/.test(w));
    check('wf rules: never close, reopen or approve a PR (builder, checks, reviewer, merge)', /never close, reopen, approve/.test(w) && /close, approve or merge/.test(byLabel('checks 5').prompt)
      && /close, approve or merge/.test(byLabel('review 5').prompt) && /never close or reopen a PR/.test(byLabel('merge 5').prompt));
    check('wf review: independent reviewer, read-only, records the head it reviews first', /INDEPENDENT REVIEWER/.test(byLabel('review 5').prompt) && /did not build it/.test(byLabel('review 5').prompt) && /FIRST record the commit you review/.test(byLabel('review 5').prompt));
    const mp = byLabel('merge 5').prompt;
    check('wf merge: only through scripts/merge-pr.ps1, pinned to the reviewed head', mp.includes(`scripts\\merge-pr.ps1 -Repo JVonBorstel/tide -Pr 5 -ExpectHead ${H}`) && /Never `gh pr merge`/.test(mp));
    check('wf Board: "pass-app changed" comes from the merged diff, never the builder; a skipped redeploy leaves a note', mp.includes('gh pr diff 5 -R JVonBorstel/tide --name-only') && mp.includes('pass-app\\update.ps1')
      && /not from anyone's report/.test(mp) && /note 5 --text "Board not redeployed/.test(mp) && !/touchesPassApp/.test(wfSrc));
    check('wf gate: privacy counts the scanner\'s "hits", never its "live" counts', /"hits" array/.test(byLabel('gate (final)').prompt) && !/sum of "live"/.test(wfSrc));
    check('wf: never sees or sends the private title (only public_title travels)', !r.calls.some((c) => /Private words/.test(c.prompt)));
  }
  {
    let reviews = 0;
    const r = await runWf('', std(pickSeq([task(6)], []), { review: () => (++reviews < 3 ? { verdict: 'SHIP AFTER FIXES', head: H, fixes: [`fix #${reviews}`], notes: ['a slip'], privacyOk: true, why: 'w' } : ship) }));
    check('wf fix rounds: fixes loop back to the builder until SHIP, then merge', r.out.merged.length === 1 && r.labels.filter((l) => /^fix 6\./.test(l)).length === 2
      && promptOf(r, 'fix 6.1').includes('1. fix #1'));
    check('wf gate: reviewer notes reach the final gate as tidy-up material', promptOf(r, 'gate (final)').includes('task 6 (PR #6): a slip'));
  }
  {
    const r = await runWf('--rounds 2', std(pickSeq([task(7)], []), { review: { ...dont, fixes: ['use `$HOME` and "quotes" \\ here'] } }));
    const esc = promptOf(r, 'escalate 7'); const noteLine = esc.split('\n').find((l) => l.includes('note 7 --text')) || '';
    check('wf --rounds 2: exactly 2 fix rounds, then the task waits on Jordan, no merge', r.out.merged.length === 0 && r.out.needJordan.length === 1 && !r.labels.some((l) => /^merge/.test(l))
      && r.labels.filter((l) => /^fix 7\./.test(l)).length === 2 && r.labels.filter((l) => l === 'review 7').length === 3 && esc.includes('set 7 status=todo depends+=jordan') && !/pause --reason/.test(esc));
    const noteText = (/--text "(.*)"`$/.exec(noteLine) || [])[1] || '';
    check('wf escalate: the note text carries no quote, $, backtick or backslash for a shell', /^needs Jordan: .*use HOME and quotes here/.test(noteText) && !/["'$`\\]/.test(noteText));
    const d3 = await runWf('', std(pickSeq([task(17)], []), { review: dont }));
    check('wf default --rounds 3: 3 fix rounds, 4 reviews, then Jordan', d3.labels.filter((l) => /^fix 17\./.test(l)).length === 3 && d3.labels.filter((l) => l === 'review 17').length === 4 && d3.out.needJordan.length === 1);
  }
  {
    const r = await runWf('', std(() => ({ ...CTX, paused: true, stop: '', reason: 'dinner', state: 'paused', why: '', run: '', tasks: [] })));
    check('wf pause: stops at the pick, works nothing, has no lock to release', r.out.stopped === 'paused: dinner' && r.labels.join(',') === 'pick (resume)');
    const u = await runWf('', std(() => ({ ...CTX, paused: false, stop: 'stop', reason: 'weekly usage 96%', state: 'stop', why: '', run: '', tasks: [] })));
    check('wf usage: a usage stop ends the run, works nothing', /weekly usage 96%/.test(u.out.stopped) && u.labels.length === 1);
    const l = await runWf('', std(() => ({ ...CTX, paused: false, stop: 'stop', reason: 'another orchestrator is running (run r0, last heartbeat 3 min ago)', state: 'locked', why: '', run: '', tasks: [] })));
    check('wf lock: a second orchestrator stops at its first pick and never releases the other\'s lock', /another orchestrator is running/.test(l.out.stopped) && l.labels.join(',') === 'pick (resume)');
    const n = await runWf('', std(() => ({ ...CTX, run: '', paused: false, stop: '', reason: '', state: 'picked', why: '', tasks: [task(30)] })));
    check('wf lock: no run id back from the first pick = nothing starts', /took no lock/.test(n.out.stopped) && !n.labels.some((x) => /^work/.test(x)));
  }
  {
    let plans = 0;
    const r = await runWf('', std(pickSeq([], [task(8)], []), { plan: () => (++plans === 1 ? { milestone: 3, raised: [8], milestoneDone: false, why: 'raised' } : plan0) }));
    check('wf plan: nothing ready -> plan raises tasks -> they are worked', r.out.merged.map((m) => m.task).join() === '8' && r.labels.slice(0, 4).join(',') === 'pick (resume),plan,pick,work 8');
    check('wf plan: a plan that raises nothing ends the run with its reason', /nothing to work: the roadmap waits on Jordan/.test(r.out.stopped));
    check('wf plan: blocked tasks are checked first', /Blocked tasks first/.test(promptOf(r, 'plan')));
    const np = await runWf('--no-plan', std(pickSeq([])));
    check('wf --no-plan: never plans', !np.labels.includes('plan'));
  }
  {
    const r = await runWf('--lanes 9 --gate-every 3', std(pickSeq([task(1), task(2), task(3)], [])));
    check('wf lanes: above the WIP limit is capped at 4 and logged', /--lanes 9 is above the WIP limit/.test(r.logs.join('\n')) && /next --lanes 4 --claim/.test(r.calls[0].prompt));
    check('wf lanes: three tasks merged, merges one at a time', r.out.merged.length === 3 && r.maxMerge === 1, `max concurrent merges ${r.maxMerge}`);
    check('wf gate: a gate after every --gate-every merges, none repeated at the end', r.labels.filter((l) => l === 'gate').length === 1 && !r.labels.includes('gate (final)'));
    const gp = await runWf('--gate-every 1', std(pickSeq([task(31)], [task(32)], []), { gate: { ...gateOk, privacyHits: 2 } }));
    check('wf gate: privacy hits stop the run for Jordan', /privacy scan hit/.test(gp.out.stopped) && !gp.labels.includes('work 32'));
  }
  {
    const r = await runWf('', std(pickSeq([task(9)], []), { review: { ...ship, privacyOk: false, why: 'title has private words' } }));
    check('wf privacy: private text in public pauses the orchestrator and waits on Jordan', /pause --reason/.test(promptOf(r, 'escalate 9')) && /privacy problem/.test(r.out.stopped) && !r.labels.some((l) => /^merge/.test(l)));
  }
  {
    const r = await runWf('', std(pickSeq([task(10)], []), { work: () => null }));
    check('wf cap: an agent that dies (usage cap) stops the run; the task stays in flight for a rerun', r.out.died.length === 1 && /run again to resume/.test(r.out.stopped) && !r.labels.includes('escalate 10'));
  }
  {
    let m = 0;
    const r = await runWf('', std(pickSeq([task(11)], []), { merge: () => (++m === 1 ? { ...mergedOk, merged: false, sha: '', refusal: 'branch is behind main', behind: true } : mergedOk) }));
    check('wf merge refused (behind): the builder brings main in, then it merges', r.out.merged.length === 1 && promptOf(r, 'fix 11.1').includes('normal merge (never rebase, never force-push)'));
    const h = await runWf('', std(pickSeq([task(12)], []), { merge: { ...mergedOk, merged: false, sha: '', refusal: 'merge freeze window' } }));
    check('wf merge refused (freeze, red main): held, the task leaves the in-flight set and waits on Jordan, no fix round', h.out.held.length === 1 && !h.labels.some((l) => /^fix/.test(l))
      && promptOf(h, 'hold 12').includes('set 12 status=blocked depends+=jordan') && /To retry: set status=review/.test(promptOf(h, 'hold 12')));
  }
  {
    let reviews = 0;
    const mv = await runWf('', std(pickSeq([task(13)], []), { review: () => (++reviews === 1 ? { ...ship, head: H2 } : ship) }));
    check('wf head pin: reviewer and checks saw different commits -> verify again (not a fix round), then merge the reviewed one', mv.out.merged.length === 1 && mv.labels.filter((l) => l === 'review 13').length === 2
      && !mv.labels.some((l) => /^fix/.test(l)) && promptOf(mv, 'merge 13').includes(`-ExpectHead ${H}`));
    const always = await runWf('', std(pickSeq([task(14)], []), { review: { ...ship, head: H2 } }));
    check('wf head pin: a head that keeps moving is held, never merged', always.out.held.length === 1 && !always.labels.some((l) => /^merge/.test(l)));
  }
  {
    let ci = 0;
    const p1 = await runWf('', std(pickSeq([task(15)], []), { checks: { ...green, testsPass: false, failing: ['Test-X'], tests: 'FAILED: Test-X', ci: 'pending' }, 'ci ': () => (++ci === 1 ? { ...green, testsPass: true, ci: 'green' } : green), fix: built(15) }));
    check('wf CI pending after a failed suite: the failure is kept (never overwritten to pass), the builder fixes it before any merge',
      p1.labels.indexOf('fix 15.1') > -1 && p1.labels.indexOf('fix 15.1') < (p1.labels.indexOf('merge 15') === -1 ? Infinity : p1.labels.indexOf('merge 15')) && promptOf(p1, 'fix 15.1').includes('failing suites: Test-X'));
    const pend = await runWf('', std(pickSeq([task(16)], []), { checks: { ...green, ci: 'pending' }, 'ci ': { ...green, ci: 'pending' } }));
    check('wf CI pending with suites passing: waits twice more, then holds (waits on Jordan) instead of guessing', pend.out.held.length === 1 && pend.labels.filter((l) => l === 'ci 16').length === 2 && promptOf(pend, 'hold 16').includes('depends+=jordan'));
  }
  {
    const one = await runWf('18', std(pickSeq([task(18)])));
    check('wf single task (/task-start 18): start checks pause, usage and the lock; one task, no plan, final gate, unlock', /Single-task mode, task 18/.test(one.calls[0].prompt) && one.calls[0].prompt.includes('start 18 --run new --json')
      && one.out.merged.length === 1 && !one.labels.includes('plan') && one.labels.includes('gate (final)') && one.labels.at(-1) === 'unlock');
    const ps = await runWf('18', std(() => ({ ...CTX, paused: true, stop: '', reason: 'away', state: 'paused', why: '', run: '', tasks: [] })));
    check('wf single task: a paused store stops /task-start before any work', ps.out.stopped === 'paused: away' && ps.labels.length === 1);
    const pv = await runWf({ repo: 'example-owner/private-site' }, std(() => ({ ...CTX, visibility: 'PRIVATE', paused: false, stop: 'stop', reason: '', state: '', why: '', run: '', tasks: [task(16)] })));
    check('wf: refuses a repo that is not public, before any work', /not public \(PRIVATE\)/.test(pv.out.stopped) && pv.labels.join() === 'pick (resume)' && /visibility -q \.visibility/.test(pv.calls[0].prompt));
    check('wf: --repo must be owner/name', (await runWf({ repo: 'nope' }, std(pickSeq([])))).error !== null);
    const bad = await runWf('--lanes two', std(pickSeq([])));
    check('wf: bad arguments fail before any agent runs', bad.error && bad.calls.length === 0);
    check('wf: --max defaults to 40 (the 1000-agent cap)', /lanes: 1, max: 40,/.test(wfSrc));
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
const failed = results.filter((r) => !r.pass);
for (const f of failed) console.log(`FAIL: ${f.name}`);
console.log(`Task tests: ${results.length - failed.length} passed, ${failed.length} failed, 0 skipped`);
process.exitCode = failed.length ? 1 : 0;
