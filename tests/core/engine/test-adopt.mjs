// Owns the tests of `adopt` (core/engine/adopt.mjs) against its acceptance lines: it refuses with no BRIEF, over the WIP limits
// (4 streams; a stream's 3 waiting cards; Board stack depth 0) and with no decision for art paths (the adopt.json list); otherwise it
// gives the contract events that start the WO. Scratch folders only (synthetic BRIEFs, example names, 2030 dates); one local git repo
// for the changed-files path. Prints "Adopt tests: N passed, M failed".
// Called by tests/Test-Adopt.ps1 and by hand: node tests/core/engine/test-adopt.mjs
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { readBrief, decideAdopt, streamsOf, globRe, changedFiles, main, adoptActivity, CONFIG } from '../../../core/engine/adopt.mjs';
import { validate } from '../../../core/contracts/validate.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tide-adopt-'));
const AT = '2030-01-07T09:00:00Z';
const briefText = (over = {}) => {
  const f = { v: '1.0', wo: 'WO-2105', stream: 'DEMO', plan: 'plans/example-plan.md#slice-3', decision: 'none', repo: 'example-owner/example-repo',
    branch: 'wo/2105-empty-state', base: 'main', worktree: 'wt/wo-2105-empty-state', budget: '40 turns', depth: 'BRAIN_AGENT_DEPTH=1', ...over };
  return `---\n${Object.entries(f).map(([k, v]) => `${k}: ${v}`).join('\n')}\n---\n# Goal\nExample: the demo list says "Nothing yet" when it is empty.\n`;
};
const put = (name, text) => { const f = path.join(dir, name); fs.writeFileSync(f, text); return f; };
const brief = (over) => readBrief(put(`BRIEF-${Math.random().toString(36).slice(2)}.md`, briefText(over)));
const base = (b, over = {}) => decideAdopt({ brief: b.brief, goal: b.goal, streams: [{ stream: 'DEMO', cards: 0 }], files: ['core/x.mjs'], at: AT, ...over });
const has = (r, re) => r.refusals.some((x) => re.test(x));

function testBrief() {
  const missing = readBrief(path.join(dir, 'nope.md'));
  check('refuses with no BRIEF: a missing file is refused, naming it', !missing.ok && /no BRIEF at/.test(missing.error), missing.error);
  check('refuses with no BRIEF: no --brief at all is refused', !readBrief('').ok && /no BRIEF given/.test(readBrief('').error));
  const noFm = readBrief(put('plain.md', '# Goal\nno front matter\n'));
  check('refuses with no BRIEF: a file without front matter is refused', !noFm.ok && /front matter/.test(noFm.error), noFm.error);
  const bad = brief({ depth: 'BRAIN_AGENT_DEPTH=9' });
  check('refuses with no BRIEF: front matter that fails the brief contract is refused with the contract\'s reason', !bad.ok && /brief contract/.test(bad.error), bad.error);
  const noGoal = readBrief(put('nogoal.md', briefText().replace(/# Goal\n.*\n/, '')));
  check('refuses with no BRIEF: a BRIEF with no goal line is refused', !noGoal.ok && /no goal/.test(noGoal.error), noGoal.error);
  const ok = brief();
  check('reads a valid BRIEF: its fields and its goal line', ok.ok && ok.brief.wo === 'WO-2105' && ok.brief.depth === 1 && /Nothing yet/.test(ok.goal), JSON.stringify(ok));
  const fixture = readBrief(path.join(root, 'core/contracts/fixtures/brief/valid/BRIEF.md'));
  check('reads the contract\'s own BRIEF.md fixture', fixture.ok, fixture.error);
}

function testWip() {
  const b = brief();
  const four = ['A1', 'A2', 'A3', 'A4'].map((s) => ({ stream: s, cards: 0 }));
  const over = base(b, { streams: four });
  check(`refuses over the WIP limits: a 5th stream when ${CONFIG.maxStreams} are open`, !over.ok && has(over, /WIP: 4 build streams/), over.refusals.join(' | '));
  const inOpen = base(b, { streams: [...four.slice(0, 3), { stream: 'DEMO', cards: 1 }] });
  check('WIP: a slice in a stream that is already open is fine at 4 streams', inOpen.ok, inOpen.refusals.join(' | '));
  const cards = base(b, { streams: [{ stream: 'DEMO', cards: CONFIG.maxCards }] });
  check(`refuses over the WIP limits: a stream with ${CONFIG.maxCards} cards waiting on Jordan starts no new slice`, !cards.ok && has(cards, /cards waiting/), cards.refusals.join(' | '));
  const unknown = base(b, { streams: null });
  check('refuses over the WIP limits: unknown open streams are refused, not guessed', !unknown.ok && has(unknown, /unknown/), unknown.refusals.join(' | '));
  const stacked = base(brief({ base: 'wo/2104-parent' }), { files: ['pass-app/work/list.mjs'] });
  check('refuses over the WIP limits: Board stack depth 0 (Board files on a branch not based on main)', !stacked.ok && has(stacked, /stack depth 0/), stacked.refusals.join(' | '));
  const otherStack = base(brief({ base: 'wo/2104-parent' }), { files: ['core/x.mjs'] });
  check('WIP: non-Board work on a parent branch is not refused here (the brief contract caps the depth)', otherStack.ok, otherStack.refusals.join(' | '));
  const api = streamsOf({ ok: true, streams: [{ stream: 'A1', open: 2, cards: 1 }, { stream: 'GONE', open: 0, cards: 0 }] });
  check('streams: a /api/work answer counts only streams with open work; a list of names works too; anything else is unknown',
    api.length === 1 && api[0].stream === 'A1' && streamsOf(['X']).length === 1 && streamsOf({ nope: 1 }) === null, JSON.stringify(api));
}

function testArt() {
  const art = ['pass-app/public/sprites/tower.png'];
  const none = base(brief(), { files: art });
  check('refuses with no decision for art paths (adopt.json artPaths)', !none.ok && has(none, /decide before build/), none.refusals.join(' | '));
  const withD = base(brief({ decision: 'D-7' }), { files: art });
  check('art paths with a decision id but no decisions log are refused, not adopted unchecked', !withD.ok && has(withD, /cannot be checked/), withD.refusals.join(' | '));
  check('globs are case-insensitive: Pass-App/Public/... is still an art path', !base(brief(), { files: ['Pass-App/Public/sprites/x.png'] }).ok);
  const yes = [{ kind: 'decision.answered', actor: 'jordan', data: { decision: 'D-7', answer: 'B' } }];
  const no = [{ kind: 'decision.answered', actor: 'jordan', data: { decision: 'D-7', answer: 'No' } }];
  check('art paths: with a decisions log, the decision must be answered by Jordan (a choice counts; No does not)',
    base(brief({ decision: 'D-7' }), { files: art, decisions: yes }).ok && !base(brief({ decision: 'D-7' }), { files: art, decisions: no }).ok && !base(brief({ decision: 'D-7' }), { files: art, decisions: [] }).ok);
  const unknown = base(brief(), { files: null });
  check('art paths: unknown changed files are refused (the art rule cannot be checked)', !unknown.ok && has(unknown, /changed files are unknown/));
  check('globs: ** spans folders, * stays in one, dots are literal', globRe('pass-app/public/**').test('pass-app/public/a/b.png') && !globRe('pass-app/*.mjs').test('pass-app/x/y.mjs') && !globRe('a.b').test('axb'));
}

function testEvents() {
  const b = brief({ base: 'main' });
  const r = base(b, { pr: 'example#41', head: 'aaaaaaa1', title: 'WO-2105: empty state', alias: 'J9001' });
  const valid = r.events.every((e, i) => validate('event', { ...e, seq: i + 1 }).ok);
  check('adopted PR: wo.created (goal, stream, plan, repo, alias) then pr.opened, all contract-valid', r.ok && r.events.map((e) => e.kind).join() === 'wo.created,pr.opened' && r.events[0].data.alias === 'J9001' && valid, JSON.stringify(r).slice(0, 300));
  const branch = base(b);
  check('adopted pushed branch (no PR yet): wo.created then a finished build step, so the engine waits for the push', branch.ok && branch.events[1].kind === 'step.done' && branch.events[1].data.step === 'build');
  check('--pr without --head is refused', !base(b, { pr: 'example#41' }).ok);
  const all = base(brief({ base: 'wo/2104-parent', decision: 'none' }), { streams: ['A1', 'A2', 'A3', 'A4'].map((s) => ({ stream: s, cards: 0 })), files: ['pass-app/public/x.png'] });
  check('every refusal is named at once, not only the first', all.refusals.length === 3, all.refusals.join(' | '));
}

async function testCli() {
  const lines = []; const say = (l) => lines.push(l); const now = () => new Date(AT);
  const b = put('cli-BRIEF.md', briefText()); const s = put('streams.json', JSON.stringify(['DEMO'])); const f = put('files.json', JSON.stringify(['core/x.mjs']));
  const ok = await main(['--brief', b, '--streams', s, '--files', f], say, now);
  check('cli: adopted is exit 0 with one JSON line; nothing written without --write', ok === 0 && JSON.parse(lines[0]).ok === true && fs.readdirSync(dir).every((x) => !x.endsWith('.jsonl')), lines[0]);
  const refused = await main(['--brief', path.join(dir, 'none.md'), '--streams', s], say, now);
  check('cli: refused is exit 3, with the reasons', refused === 3 && /no BRIEF at/.test(lines[1]), lines[1]);
  check('cli: an unknown option is exit 2', (await main(['--force', 'yes'], say, now)) === 2);
  const out = put('events.jsonl', '');
  const w = await main(['--brief', b, '--streams', s, '--files', f, '--write', out], say, now);
  const sinkHere = fs.existsSync(path.join(root, 'core/engine/events.mjs'));
  check(sinkHere ? 'cli --write: appends the events through the engine sink (seq from the log)' : 'cli --write: without the engine sink (WO-UPG-L2-1 not merged) it refuses and writes nothing',
    sinkHere ? w === 0 && fs.readFileSync(out, 'utf8').trim().split('\n').length === 2 : w === 3 && fs.readFileSync(out, 'utf8') === '', lines[lines.length - 1]);
  const act = await adoptActivity({ now })({ args: { Brief: b, Streams: s, Files: f }, idempotencyKey: 'WO-2105:adopt:a1:r1' });
  check('activity: adopt as an engine activity returns a contract-valid result (exit 0, the JSON line in out)', act.ok && act.exit === 0 && validate('activity-result', act).ok && /"ok":true/.test(act.out));
}

function testGit() {
  const repo = path.join(dir, 'repo'); fs.mkdirSync(repo);
  const git = (...a) => spawnSync('git', ['-C', repo, '-c', 'user.email=example@example.com', '-c', 'user.name=Example', ...a], { encoding: 'utf8' });
  git('init', '-q', '-b', 'main'); fs.writeFileSync(path.join(repo, 'a.txt'), 'a'); git('add', '.'); git('commit', '-qm', 'a');
  git('checkout', '-qb', 'wo/2105-empty-state'); fs.mkdirSync(path.join(repo, 'pass-app/public'), { recursive: true }); fs.writeFileSync(path.join(repo, 'pass-app/public/x.css'), 'x'); git('add', '.'); git('commit', '-qm', 'b');
  const c = changedFiles(repo, 'main', 'wo/2105-empty-state');
  check('changed files: read from a local checkout with git diff base...branch (no network)', c.files && c.files.join() === 'pass-app/public/x.css', JSON.stringify(c));
  const bad = changedFiles(repo, 'main', 'no-such-branch');
  check('changed files: an unknown branch is "unknown" with the reason, never an empty list', bad.files === null && /failed/.test(bad.why));
}

try { testBrief(); testWip(); testArt(); testEvents(); await testCli(); testGit(); } catch (err) { check('the adopt suite ran to the end', false, err.stack.split('\n').slice(0, 3).join(' / ')); } finally { fs.rmSync(dir, { recursive: true, force: true }); }
for (const r of results) console.log(`${r.pass ? 'ok  ' : 'FAIL'} ${r.name}`);
const failed = results.filter((r) => !r.pass).length;
console.log(`Adopt tests: ${results.length - failed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
