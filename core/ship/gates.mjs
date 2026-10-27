// Owns the CI gates of the ship path: WO id in the PR title, no generated file in a PR's diff, and the decision gate for the Board's look.
// Called by scripts/check-wo-title.mjs, scripts/check-generated.mjs, scripts/check-decision-gate.mjs (the ci.yml "gates" job) and tests/core/ship/test-gates.mjs.
// Each gate is report-only unless its mode is "enforce" (one env line per gate in ci.yml; switching one to enforce is Jordan's card).
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
import { git } from './git.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const GATES_FILE = path.join(here, 'gates.json');

/** @typedef {{ status: 'pass' | 'fail' | 'skip', lines: string[] }} Verdict */
/** @typedef {{ title: string, body: string, author: string, headRef: string } | null} PullRequest */

/** @param {string} [file] */
export function loadGates(file = GATES_FILE) { return JSON.parse(fs.readFileSync(file, 'utf8')); }

/** A repo-relative glob as a regex: * stays in one folder, ** crosses folders, ? is one character. @param {string} glob */
export function globToRegex(glob) {
  let r = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') { r += glob[i + 2] === '/' ? '(?:.*/)?' : '.*'; i += glob[i + 2] === '/' ? 2 : 1; }
    else if (c === '*') r += '[^/]*';
    else if (c === '?') r += '[^/]';
    else r += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${r}$`);
}
/** @param {string} file @param {string[]} globs */
export const matchAny = (file, globs) => globs.some((g) => globToRegex(g).test(file.replace(/\\/g, '/')));

/**
 * The pull request of a GitHub Actions event file (GITHUB_EVENT_PATH), or null for any other event (a push to main).
 * @param {string | undefined} eventPath
 * @returns {PullRequest}
 */
export function readPullRequest(eventPath) {
  if (!eventPath || !fs.existsSync(eventPath)) return null;
  const ev = JSON.parse(fs.readFileSync(eventPath, 'utf8'));
  const pr = ev && ev.pull_request;
  if (!pr) return null;
  return { title: String(pr.title || ''), body: String(pr.body || ''), author: String((pr.user && pr.user.login) || ''), headRef: String((pr.head && pr.head.ref) || '') };
}

/** The files a change touches: base..HEAD by tree (in CI, base is HEAD^1 of GitHub's merge commit). @param {string} cwd @param {string} base */
export function diffFiles(cwd, base) {
  const r = git(cwd, ['diff', '--name-only', base, 'HEAD']);
  if (!r.ok) throw new Error(`git diff ${base} HEAD failed: ${r.err || `exit ${r.code}`}`);
  return r.out ? r.out.split('\n').map((s) => s.trim()).filter(Boolean) : [];
}

/** @param {PullRequest} pr @param {any} cfg @returns {Verdict} */
export function woTitleGate(pr, cfg = loadGates().woTitle) {
  if (!pr) return { status: 'skip', lines: ['not a pull request (a push): nothing to check'] };
  if ((cfg.skipAuthors || []).includes(pr.author)) return { status: 'skip', lines: [`opened by ${pr.author}, which names its own titles`] };
  const m = new RegExp(cfg.pattern).exec(pr.title);
  return m ? { status: 'pass', lines: [`the title starts with ${m[1]}`] }
    : { status: 'fail', lines: ['the title does not start with a work order id and a colon (WO-312: ..., WO-UPG-L4-1: ...)', `title: ${pr.title.slice(0, 120)}`] };
}

/** @param {string[]} files @param {PullRequest} pr @param {any} cfg @returns {Verdict} */
export function generatedGate(files, pr, cfg = loadGates().generated) {
  if (!pr) return { status: 'skip', lines: ['not a pull request (a push): the docs step rebuilds generated files on main'] };
  if (matchAny(pr.headRef, cfg.allowBranches || [])) return { status: 'skip', lines: [`branch ${pr.headRef} is the docs step's own, which rebuilds them`] };
  const hits = files.filter((f) => matchAny(f, cfg.paths));
  return hits.length ? { status: 'fail', lines: [`${hits.length} generated file(s) changed; leave them to the docs step after the merge:`, ...hits.map((f) => `- ${f}`)] }
    : { status: 'pass', lines: [`no generated file changed (${files.length} files checked against ${cfg.paths.length} paths)`] };
}

/** @param {string[]} files @param {PullRequest} pr @param {any} cfg @returns {Verdict} */
export function decisionGate(files, pr, cfg = loadGates().decision) {
  if (!pr) return { status: 'skip', lines: ['not a pull request (a push): nothing to check'] };
  const art = files.filter((f) => matchAny(f, cfg.paths));
  if (!art.length) return { status: 'pass', lines: [`no file of the Board's look changed (${files.length} files checked)`] };
  const ids = [...new Set(`${pr.title}\n${pr.body}`.match(/\bD-[0-9]+\b/g) || [])];
  const head = `${art.length} file(s) of the Board's look changed`;
  if (ids.length) return { status: 'pass', lines: [`${head}; decision named: ${ids.join(', ')} (whether it is answered is checked by the merge queue against the record, not here)`] };
  return { status: 'fail', lines: [`${head}, and the PR names no decision (D-<n>) in its title or body:`, ...art.slice(0, 20).map((f) => `- ${f}`), 'Mock-ups first: 2-3 labelled variants, an A/B/C card, then the build.'] };
}

/**
 * Command-line options shared by the gate scripts: --mode report|enforce, --summary <file>, --event <file>, --base <ref>, --root <dir>,
 * and --title/--body/--author/--head to check a PR by hand. Unknown options are a usage error.
 * @param {string[]} argv
 */
export function parseArgs(argv) {
  /** @type {Record<string, string>} */
  const o = { mode: process.env.GATE_MODE || 'report', summary: process.env.GITHUB_STEP_SUMMARY || '', event: process.env.GITHUB_EVENT_PATH || '', base: 'HEAD^1', root: process.cwd() };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i].replace(/^--/, '');
    if (!['mode', 'summary', 'event', 'base', 'root', 'title', 'body', 'author', 'head'].includes(k) || argv[i + 1] === undefined) throw new Error(`unknown or empty option ${argv[i]}`);
    o[k] = argv[++i];
  }
  if (o.mode !== 'report' && o.mode !== 'enforce') throw new Error(`--mode is report or enforce, not ${o.mode}`);
  return o;
}

/** The PR to check: --title (by hand) wins over the event file. @param {Record<string, string>} o @returns {PullRequest} */
export function prFrom(o) {
  if (o.title !== undefined) return { title: o.title, body: o.body || '', author: o.author || '', headRef: o.head || '' };
  return readPullRequest(o.event);
}

/**
 * Print a gate's verdict, add it to the step summary, and return the exit code: 1 only for a fail in enforce mode.
 * @param {string} name @param {Verdict} v @param {Record<string, string>} o
 */
export function finish(name, v, o) {
  const word = v.status === 'fail' ? (o.mode === 'enforce' ? 'FAIL' : 'FAIL (report only)') : v.status.toUpperCase();
  const line = `Gate ${name}: ${word}`;
  console.log(line);
  for (const l of v.lines) console.log(`  ${l}`);
  if (o.summary) {
    try { fs.appendFileSync(o.summary, [`### ${line}`, '', ...v.lines.map((l) => (l.startsWith('- ') ? l : `- ${l}`)), ''].join('\n') + '\n'); }
    catch (e) { console.log(`  (the step summary could not be written: ${/** @type {Error} */ (e).message})`); }
  }
  return v.status === 'fail' && o.mode === 'enforce' ? 1 : 0;
}

/**
 * The whole run of one gate script, so each script is three lines. A usage error exits 2. A gate that could not run (git failed) says
 * so in the log and the summary; it exits 2 in enforce mode and 0 in report mode, so a report-only gate never blocks a PR.
 * @param {string} name @param {(o: Record<string, string>) => Verdict} decide @param {string[]} argv
 */
export function runGate(name, decide, argv) {
  let o;
  try { o = parseArgs(argv); } catch (e) { console.log(`Gate ${name}: usage error: ${/** @type {Error} */ (e).message}`); return 2; }
  try { return finish(name, decide(o), o); } catch (e) {
    finish(name, { status: 'fail', lines: [`could not run: ${/** @type {Error} */ (e).message}`] }, o);
    return o.mode === 'enforce' ? 2 : 0;
  }
}
