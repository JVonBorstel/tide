// @ts-check
// Owns `adopt`: turning a pushed session branch or pull request plus its BRIEF.md into a work order (WO) the engine can carry, as the
// contract events that start it (wo.created, then pr.opened, or a finished build step when there is no PR yet). It refuses, naming
// every reason, when: there is no BRIEF (or its front matter fails core/contracts/brief.schema.json); the work would pass a WIP limit
// (more than maxStreams build streams open, a stream with maxCards cards waiting on Jordan, Board work not based on main); or it touches
// art paths with no decision (decide before build). Limits and path lists: core/engine/adopt.json.
// Called by its command line (below), by the engine as an activity (adoptActivity), and by tests/core/engine/test-adopt.mjs.
//   node core/engine/adopt.mjs --brief <BRIEF.md> --streams <file> [--pr <repo#n> --head <sha> [--title <text>]] [--files <file>]
//        [--repo-dir <checkout> (changed files from git: <base>...<branch>)] [--alias J<n>] [--decisions <events.jsonl>] [--write <events.jsonl>]
// --streams: a JSON list of the open stream names, or a GET /api/work answer (its streams). Unknown open streams = refuse, never guess.
// Prints one JSON line {ok, wo, refusals, events}. Writes nothing unless --write is given AND the engine's event sink is present
// (core/engine/events.mjs, WO-UPG-L2-1); the live Yard and its state folder are never touched. Exit 0 adopted, 3 refused, 2 bad input.
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath, pathToFileURL } from 'node:url';
import { validate } from '../contracts/validate.mjs';
import { parseFrontMatter } from '../contracts/frontmatter.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const CONFIG = JSON.parse(fs.readFileSync(path.join(here, 'adopt.json'), 'utf8'));

// A glob as a regex: ** any number of path parts, * one part's characters, ? one character; everything else literal.
export function globRe(glob) {
  const re = String(glob).split('**').map((part) => part.split('*').map((s) => s.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\?/g, '[^/]')).join('[^/]*')).join('.*');
  return new RegExp(`^${re}$`, 'i'); // case-insensitive: Windows paths are, so Pass-App/Public/x.png must not dodge the art rule
}
const matchAny = (file, globs) => globs.some((g) => globRe(g).test(file.replace(/\\/g, '/')));

// The goal: the first non-empty line under "# Goal" in the BRIEF body, else the first heading text. Plain words, capped.
function goalOf(body) {
  const lines = String(body).split(/\r?\n/);
  const at = lines.findIndex((l) => /^#\s+Goal\b/i.test(l.trim()));
  const pick = (at >= 0 ? lines.slice(at + 1) : lines).map((l) => l.trim()).find((l) => l && !l.startsWith('#'));
  return (pick || '').slice(0, 2000);
}

/** Read and check a BRIEF.md: { ok, brief, goal, error }. */
export function readBrief(file) {
  if (!file) return { ok: false, error: 'no BRIEF given (--brief <BRIEF.md>)' };
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (err) { return { ok: false, error: `no BRIEF at ${file}: ${/** @type {any} */ (err).code || /** @type {Error} */ (err).message}` }; }
  const fm = parseFrontMatter(text);
  if (!fm.ok) return { ok: false, error: `the BRIEF's front matter does not read: ${fm.error}` };
  const r = validate('brief', fm.data);
  if (!r.ok) return { ok: false, error: `the BRIEF fails the brief contract: ${r.errors.join('; ')}` };
  const goal = goalOf(fm.body);
  if (!goal) return { ok: false, error: 'the BRIEF has no goal line (a "# Goal" section with one line under it)' };
  return { ok: true, brief: fm.data, goal };
}

/** Open streams from --streams: a list of names, or a /api/work answer. null = unknown. */
export function streamsOf(doc) {
  if (Array.isArray(doc) && doc.every((s) => typeof s === 'string')) return doc.map((name) => ({ stream: name, cards: 0 }));
  if (doc && doc.ok === true && Array.isArray(doc.streams)) return doc.streams.filter((s) => s.open > 0).map((s) => ({ stream: s.stream, cards: s.cards || 0 }));
  return null;
}

// Was decision D-n answered by Jordan, in an event list? (A choose card answered A/B/C counts; a "No" or "Hold" does not.)
function decisionAnswered(events, id) {
  const ans = (events || []).filter((e) => e.kind === 'decision.answered' && e.actor === 'jordan' && e.data && e.data.decision === id).pop();
  return ans ? !['No', 'Hold'].includes(ans.data.answer) : false;
}

/**
 * The adopt decision, pure: every refusal named, and the events that start the WO when there is none.
 * @param {{ brief: any, goal: string, streams: { stream: string, cards: number }[]|null, files: string[]|null, pr?: string|null, head?: string|null,
 *   title?: string|null, alias?: string|null, decisions?: any[]|null, at: string, config?: typeof CONFIG }} o
 */
export function decideAdopt(o) {
  const c = { ...CONFIG, ...(o.config || {}) }; const b = o.brief; const refusals = [];
  if (o.streams === null) refusals.push('open build streams are unknown (pass --streams: a list of names or a /api/work answer); WIP cannot be checked, so no adopt');
  else {
    const open = new Set(o.streams.map((s) => s.stream));
    if (!open.has(b.stream) && open.size >= c.maxStreams) refusals.push(`WIP: ${open.size} build streams are open (${[...open].join(', ')}); at most ${c.maxStreams}, and ${b.stream} would be one more`);
    const mine = o.streams.find((s) => s.stream === b.stream);
    if (mine && mine.cards >= c.maxCards) refusals.push(`WIP: stream ${b.stream} has ${mine.cards} cards waiting on Jordan; at ${c.maxCards} it starts no new slice`);
  }
  if (o.files === null) refusals.push('the changed files are unknown (pass --files or --repo-dir); Board and art rules cannot be checked, so no adopt');
  const files = o.files || [];
  const board = files.filter((f) => matchAny(f, c.boardPaths)); const art = files.filter((f) => matchAny(f, c.artPaths));
  if (board.length && b.base !== 'main') refusals.push(`Board stack depth 0: ${board.length} Board file(s) (${board.slice(0, 3).join(', ')}) on a branch based on ${b.base}, not main`);
  if (art.length && b.decision === 'none') refusals.push(`decide before build: ${art.length} art file(s) (${art.slice(0, 3).join(', ')}) and the BRIEF says decision: none`);
  if (art.length && b.decision !== 'none' && !o.decisions) refusals.push(`decide before build: ${art.length} art file(s) and ${b.decision} cannot be checked (pass --decisions, the event log with Jordan's answers); unknown is not yes`);
  if (art.length && b.decision !== 'none' && o.decisions && !decisionAnswered(o.decisions, b.decision)) refusals.push(`decide before build: ${b.decision} is not answered yes (or a choice) by Jordan in the given decisions`);
  if ((o.pr && !o.head) || (!o.pr && o.head)) refusals.push('--pr and --head go together (the PR and the sha it was adopted at)');
  if (refusals.length) return { ok: false, wo: b.wo, refusals, events: [] };
  const ev = (kind, data, proof = null) => ({ v: '1.0', at: o.at, actor: 'engine', kind, wo: b.wo, data, proof });
  const created = ev('wo.created', { goal: o.goal, stream: b.stream, plan: b.plan, repo: b.repo, ...(o.alias ? { alias: o.alias } : {}) }, `adopted from BRIEF (${b.branch})`);
  const second = o.pr
    ? ev('pr.opened', { pr: o.pr, branch: b.branch, base: b.base, head: o.head, ...(o.title ? { title: o.title.slice(0, 2000) } : {}) }, `adopted ${o.pr} at ${o.head}`)
    : ev('step.done', { step: 'build', attempt: 1, exit: 0 }, `adopted pushed branch ${b.branch}; the build happened in a session`);
  const events = [created, second];
  const bad = events.map((e, i) => validate('event', { ...e, seq: i + 1 })).flatMap((r) => r.errors);
  if (bad.length) return { ok: false, wo: b.wo, refusals: [`the events would break the event contract: ${bad.join('; ')}`], events: [] };
  return { ok: true, wo: b.wo, refusals: [], events };
}

// The files a branch changed against its base, from a local checkout (no network): git diff --name-only <base>...<branch>.
export function changedFiles(repoDir, base, branch) {
  const r = spawnSync('git', ['-C', repoDir, 'diff', '--name-only', `${base}...${branch}`], { encoding: 'utf8', timeout: 30000, windowsHide: true });
  if (r.status !== 0) return { files: null, why: `git diff ${base}...${branch} failed: ${(r.stderr || '').trim().slice(0, 300)}` };
  return { files: r.stdout.split(/\r?\n/).filter(Boolean), why: '' };
}

const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const readLog = (f) => fs.readFileSync(f, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));

/** The command line. @param {string[]} argv @param {(line: string) => void} [say] */
export async function main(argv, say = console.log, now = () => new Date()) {
  const o = {}; const known = ['brief', 'streams', 'pr', 'head', 'title', 'files', 'repo-dir', 'alias', 'decisions', 'write'];
  for (let i = 0; i < argv.length; i += 2) {
    const k = String(argv[i]).replace(/^--/, '');
    if (!known.includes(k) || argv[i + 1] === undefined) { say(JSON.stringify({ ok: false, error: `unknown or empty option ${argv[i]}; known: --${known.join(', --')}` })); return 2; }
    o[k] = argv[i + 1];
  }
  const br = readBrief(o.brief);
  if (!br.ok) { say(JSON.stringify({ ok: false, wo: null, refusals: [br.error], events: [] })); return 3; }
  let streams = null; let files = null; let decisions = null;
  try {
    if (o.streams) streams = streamsOf(readJson(o.streams));
    if (o.files) files = readJson(o.files);
    else if (o['repo-dir']) files = changedFiles(o['repo-dir'], br.brief.base, br.brief.branch).files;
    if (o.decisions) decisions = readLog(o.decisions);
  } catch (err) { say(JSON.stringify({ ok: false, error: `an input file does not read: ${/** @type {Error} */ (err).message}` })); return 2; }
  if (o.alias && !/^J[0-9]+$/.test(o.alias)) { say(JSON.stringify({ ok: false, error: '--alias is a Yard job id (J312)' })); return 2; }
  const r = decideAdopt({ brief: br.brief, goal: br.goal, streams, files, pr: o.pr || null, head: o.head || null, title: o.title || null, alias: o.alias || null, decisions, at: now().toISOString() });
  if (r.ok && o.write) {
    const sinkFile = path.join(here, 'events.mjs');
    if (!fs.existsSync(sinkFile)) { say(JSON.stringify({ ...r, ok: false, refusals: ['--write needs the engine event sink (core/engine/events.mjs, WO-UPG-L2-1); nothing written'] })); return 3; }
    const { fileSink } = await import(pathToFileURL(sinkFile).href);
    const sink = fileSink(o.write);
    if (sink.forWo(r.wo).some((e) => e.kind === 'wo.created')) { say(JSON.stringify({ ...r, ok: false, refusals: [`${r.wo} is already in ${o.write}; nothing written`] })); return 3; }
    // One locked write for both events (appendAll), so a failure never leaves wo.created alone.
    const drafts = r.events.map(({ v, ...e }) => e);
    r.events = sink.appendAll ? sink.appendAll(drafts) : drafts.map((e) => sink.append(e));
  }
  say(JSON.stringify(r));
  return r.ok ? 0 : 3;
}

/**
 * adopt as an engine activity: args { Brief, Streams (file), Files (file) or RepoDir, Pr, Head, Title, Alias, Decisions }; the activity
 * result's out is the JSON line above. exit 0 adopted, 3 refused (the engine reads 3 as a failed step with the reasons; never retried blindly).
 * @param {{ now?: () => Date }} [deps]
 */
export function adoptActivity(deps = {}) {
  return async (/** @type {{ args: Record<string, any>, idempotencyKey: string }} */ a) => {
    const map = { Brief: 'brief', Streams: 'streams', Files: 'files', RepoDir: 'repo-dir', Pr: 'pr', Head: 'head', Title: 'title', Alias: 'alias', Decisions: 'decisions' };
    const argv = Object.entries(map).filter(([k]) => a.args[k] !== undefined && a.args[k] !== null).flatMap(([k, flag]) => [`--${flag}`, String(a.args[k])]);
    const lines = []; const exit = await main(argv, (l) => lines.push(l), deps.now);
    const res = { v: '1.0', ok: exit === 0, exit, out: lines.join('\n').slice(-65536), proof: `adopt exit ${exit} (${a.idempotencyKey})` };
    const r = validate('activity-result', res);
    if (!r.ok) throw new Error(`adopt result is not valid: ${r.errors.join('; ')}`);
    return res;
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).then((c) => { process.exitCode = c; });
