// Owns the docs step of the ship path (docs station): a work order's change note, its new names in the glossary, the names guard, and
// MAP.md rebuilt after the merge. Called by the engine after a merge (lane L2, behind flag ship.docs-step), tests/core/ship/test-docs.mjs and by hand.
//   node core/ship/docs.mjs check --wo <WO-id> [--root <repo>] [--base <ref>]   the named failures, and the dod line (exit 0 all yes, 1 failures, 2 usage)
//   node core/ship/docs.mjs map [--root <repo>]                                 rebuild kitchen/MAP.md in that checkout and say if it changed (never commits)
// @ts-check
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { pathToFileURL } from 'node:url';
import { git } from './git.mjs';

const WO = /^WO-[A-Z0-9]+(-[A-Z0-9]+)*$/; // common.schema.json woId

/** @typedef {{ name: 'change-note-missing' | 'change-note-no-effects' | 'new-names-unlisted' | 'glossary-missing' | 'names-hit' | 'names-check-error', detail: string }} Failure */
/** @typedef {{ code: number, out: string }} NamesRun */

/**
 * The names guard (scripts/check-names.ps1 -Enforce) on the lines added since base. Exit 0 clean, 1 new old-word hits, 2 bad input.
 * @param {string} root @param {string} base @returns {NamesRun}
 */
export function runNamesGuard(root, base) {
  const r = spawnSync('pwsh', ['-NoProfile', '-File', path.join(root, 'scripts', 'check-names.ps1'), '-Root', root, '-Base', base, '-Enforce'],
    { cwd: root, encoding: 'utf8', timeout: 180000, windowsHide: true, env: { ...process.env, GITHUB_HEAD_REF: '' } }); // no branch exemption after a merge
  if (r.error) return { code: 2, out: `pwsh could not run: ${r.error.message}` };
  return { code: r.status ?? 2, out: `${r.stdout || ''}${r.stderr || ''}` };
}

/**
 * The names a change note declares new, from its "New names" section: bullet lines, the name in **bold** or as the whole line.
 * Returns null when the note has no such section; [] when it says none.
 * @param {string} note
 */
export function newNamesOf(note) {
  const m = /^#{2,3}\s+New names\s*$([\s\S]*?)(?=^#{1,3}\s|(?![\s\S]))/m.exec(note);
  if (!m) return null;
  const names = [];
  for (const line of m[1].split(/\r?\n/)) {
    const b = /^\s*[-*]\s+(?:\*\*(.+?)\*\*|(.+?))\s*(?:[:(,-]|$)/.exec(line);
    if (b) names.push((b[1] || b[2]).trim());
  }
  return names.filter((n) => n && !/^none\b/i.test(n));
}

/**
 * The docs step's check of one work order in a checkout. Each problem is a named failure; the dod line follows the contract
 * (common.schema.json dod: yes / no / n/a).
 * @param {{ root: string, wo: string, base?: string, names?: (root: string, base: string) => NamesRun }} opt
 */
export function checkDocs(opt) {
  const { root, wo } = opt;
  if (!WO.test(wo)) throw new Error(`not a work order id: ${wo}`);
  /** @type {Failure[]} */
  const failures = [];
  const rel = `docs/changes/${wo}.md`;
  const notePath = path.join(root, rel);
  const note = fs.existsSync(notePath) ? fs.readFileSync(notePath, 'utf8') : null;
  if (note === null) failures.push({ name: 'change-note-missing', detail: `${rel} does not exist` });
  else {
    const missing = ['L1', 'L2', 'L3', 'L4'].filter((l) => !new RegExp(`\\b${l}\\b`).test(note));
    if (missing.length) failures.push({ name: 'change-note-no-effects', detail: `${rel} does not say the ${missing.join(', ')} effect (person, business, MSP, community)` });
  }
  let glossary = 'n/a';
  if (note !== null) {
    const names = newNamesOf(note);
    if (names === null) { failures.push({ name: 'new-names-unlisted', detail: `${rel} has no "## New names" section (list them, or write "- none")` }); glossary = 'no'; }
    else if (names.length) {
      const gPath = path.join(root, 'docs', 'GLOSSARY.md');
      const g = fs.existsSync(gPath) ? fs.readFileSync(gPath, 'utf8') : '';
      const absent = names.filter((n) => !g.includes(`**${n}**`));
      for (const n of absent) failures.push({ name: 'glossary-missing', detail: `"${n}" is new in ${rel} but not a bold name in docs/GLOSSARY.md` });
      glossary = absent.length ? 'no' : 'yes';
    }
  }
  let names = 'n/a';
  if (opt.base) {
    const r = (opt.names || runNamesGuard)(root, opt.base);
    if (r.code === 0) names = 'yes';
    else if (r.code === 1) {
      names = 'no';
      const found = r.out.split(/\r?\n/).filter((l) => /^FOUND\b/.test(l)).slice(0, 20);
      failures.push({ name: 'names-hit', detail: `the names guard found ${found.length || 'new'} old word(s) since ${opt.base}${found.length ? `: ${found.join(' | ')}` : ''}` });
    } else { names = 'no'; failures.push({ name: 'names-check-error', detail: `the names guard could not run (exit ${r.code}): ${r.out.trim().split(/\r?\n/).slice(-2).join(' ')}` }); }
  }
  const dod = { 'change-note': note !== null && !failures.some((f) => f.name === 'change-note-no-effects') ? 'yes' : 'no', glossary, names };
  return { ok: failures.length === 0, failures, dod };
}

/**
 * The docs.done event for a work order whose check passed (core/contracts event.schema.json). Throws if the check did not pass.
 * @param {{ wo: string, dod: Record<string, string>, ok: boolean, seq: number, at: string }} a
 */
export function docsDoneEvent(a) {
  if (!a.ok) throw new Error('docs.done is written only when the docs step passed');
  return { v: '1.0', seq: a.seq, at: a.at, actor: 'engine', kind: 'docs.done', wo: a.wo, data: { dod: a.dod }, proof: null };
}

/**
 * Rebuild kitchen/MAP.md in a checkout of main (after a merge) with scripts/make-map.ps1, and say whether it changed. It never commits
 * or pushes: the engine opens the docs PR from a ship/docs-* branch, which the generated-files gate allows.
 * @param {string} root
 */
export function rebuildMap(root) {
  const r = spawnSync('pwsh', ['-NoProfile', '-File', path.join(root, 'scripts', 'make-map.ps1'), '-Root', root], { cwd: root, encoding: 'utf8', timeout: 180000, windowsHide: true });
  if (r.error || r.status !== 0) return { ok: false, changed: false, detail: `make-map failed (exit ${r.status ?? 'none'}): ${(r.error && r.error.message) || (r.stdout + r.stderr).trim().split(/\r?\n/).pop()}` };
  const s = git(root, ['status', '--porcelain', '--', 'kitchen/MAP.md']);
  if (!s.ok) return { ok: false, changed: false, detail: `git status failed: ${s.err}` };
  return { ok: true, changed: s.out.length > 0, detail: s.out ? 'kitchen/MAP.md changed: the engine opens a docs PR from ship/docs-map-<sha>' : 'kitchen/MAP.md is current' };
}

/** @param {string[]} argv @returns {number} */
export function main(argv) {
  const [cmd, ...rest] = argv;
  /** @type {Record<string, string>} */
  const o = { root: process.cwd() };
  for (let i = 0; i < rest.length; i += 2) {
    const k = rest[i].replace(/^--/, '');
    if (!['wo', 'root', 'base'].includes(k) || rest[i + 1] === undefined) { console.log(`docs: unknown or empty option ${rest[i]}`); return 2; }
    o[k] = rest[i + 1];
  }
  if (cmd === 'map') { const r = rebuildMap(o.root); console.log(`Docs step map: ${r.detail}`); return r.ok ? 0 : 1; }
  if (cmd !== 'check' || !o.wo || !WO.test(o.wo)) { console.log('usage: node core/ship/docs.mjs check --wo <WO-id> [--root <repo>] [--base <ref>] | map [--root <repo>]'); return 2; }
  const r = checkDocs({ root: o.root, wo: o.wo, base: o.base });
  for (const f of r.failures) console.log(`FAIL: ${f.name}: ${f.detail}`);
  console.log(`Docs step ${o.wo}: ${r.ok ? 'pass' : `${r.failures.length} failure(s)`}; dod ${Object.entries(r.dod).map(([k, v]) => `${k} ${v}`).join(' | ')}`);
  return r.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));
