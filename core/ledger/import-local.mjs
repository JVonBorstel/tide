// @ts-check
// Importer: what is on this PC -> snapshot events (read only: git read commands, file reads; no fetch, no write).
//   - per repo: `git worktree list --porcelain`, the branches merged into main, and the ids named on main (newest commit first; a revert
//     as the newest commit naming an id means it was undone) -> one x.local.repo event per change.
//   - plan files (plans/*.md): `wo:` front matter lines and the slice tokens each plan names (S7b, G4, TD-6) -> one x.local.plans event.
//   - work/<WO>/BRIEF.md and REPORT.md front matter (core/contracts/frontmatter.mjs) -> one x.local.briefs event.
// Snapshots carry no work order (wo null, kind x.local.*); the view joins them to rows by branch, WO id and token. Each snapshot's source
// key is a hash of its content, so a rerun with nothing changed adds 0 events.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { parseFrontMatter } from '../contracts/frontmatter.mjs';
import { isWo } from './ids.mjs';

/** @param {string} repo @param {string[]} args @returns {string | null} */
function git(repo, args) {
  try { return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true, maxBuffer: 64 * 1024 * 1024 }); } catch { return null; }
}
const hash = (/** @type {unknown} */ v) => crypto.createHash('sha1').update(JSON.stringify(v)).digest('hex').slice(0, 16);
export const ID_IN_TEXT = /(?<![A-Za-z0-9-])(J\d{1,5}|WO-[A-Z0-9]+(?:-[A-Z0-9]+)*)(?![\dA-Za-z])/g;
export const SLICE_TOKEN = /(?<![\w-])(S\d+[a-z]|G\d+|TD-\d+)(?![\w-])/g;

/**
 * One repo's facts.
 * @param {string} repo the checkout path
 * @param {string} name a short name for the row (tide)
 */
export function repoFacts(repo, name) {
  const out = { repo: name, ok: false, main: '', head: '', ids: /** @type {Record<string, string>} */ ({}), reverted: /** @type {string[]} */ ([]), mergedBranches: /** @type {string[]} */ ([]), worktrees: /** @type {Array<{path: string, branch: string}>} */ ([]), why: '' };
  if (!fs.existsSync(repo)) { out.why = 'the checkout folder does not exist'; return out; }
  let main = '';
  for (const ref of ['refs/heads/main', 'refs/heads/master', 'refs/remotes/origin/main']) if (git(repo, ['rev-parse', '--verify', '--quiet', ref]) !== null) { main = ref; break; }
  if (!main) { out.why = 'no main branch could be read'; return out; }
  out.main = main.replace(/^refs\/(heads|remotes)\//, ''); out.head = String(git(repo, ['rev-parse', '--short', main]) || '').trim();
  const log = git(repo, ['log', main, '-n', '4000', '--format=%h%x1f%s%x1f%b%x1e']) || '';
  for (const rec of log.split('\x1e')) {
    const parts = rec.trim().split('\x1f'); if (parts.length < 2) continue;
    const [h, subject] = parts; const textOf = parts.slice(1).join(' '); const rev = /^Revert\b/.test(subject);
    for (const m of textOf.matchAll(ID_IN_TEXT)) { const k = m[1]; if (out.ids[k]) continue; out.ids[k] = h; if (rev) out.reverted.push(k); }
  }
  out.mergedBranches = String(git(repo, ['for-each-ref', `--merged=${main}`, '--format=%(refname:short)', 'refs/heads']) || '').split('\n').map((s) => s.trim()).filter(Boolean).sort();
  let cur = /** @type {any} */ (null);
  for (const l of String(git(repo, ['worktree', 'list', '--porcelain']) || '').split('\n')) {
    if (l.startsWith('worktree ')) { if (cur) out.worktrees.push(cur); cur = { path: l.slice(9).trim(), branch: '' }; }
    else if (l.startsWith('branch ') && cur) cur.branch = l.slice(7).trim().replace(/^refs\/heads\//, '');
  }
  if (cur) out.worktrees.push(cur);
  out.ok = true; return out;
}

/** @param {string} dir the plans folder @param {string} rel how plan paths are written (plans) */
export function planFacts(dir, rel = 'plans') {
  const plans = [];
  let files = []; try { files = fs.readdirSync(dir).filter((f) => /\.md$/i.test(f)); } catch { return { ok: false, plans, why: `no plans folder at ${dir}` }; }
  for (const f of files.sort()) {
    let raw = ''; try { raw = fs.readFileSync(path.join(dir, f), 'utf8'); } catch { continue; }
    const head = raw.split('\n').slice(0, 40).join('\n'); const wos = new Set();
    for (const m of head.matchAll(/^wo:\s*(.+)$/gim)) for (const w of m[1].split(/[,\s]+/)) if (isWo(w)) wos.add(w);
    const tokens = [...new Set([...raw.matchAll(SLICE_TOKEN)].map((m) => m[1]))].sort().slice(0, 500);
    let mtime = ''; try { mtime = fs.statSync(path.join(dir, f)).mtime.toISOString(); } catch { }
    plans.push({ file: `${rel}/${f}`, wo: [...wos].sort(), tokens, mtime });
  }
  return { ok: true, plans, why: '' };
}

/** @param {string} dir the work folder (work/<WO>/BRIEF.md) @param {string} rel how paths are written (work) */
export function briefFacts(dir, rel = 'work') {
  const items = [];
  let subs = []; try { subs = fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort(); } catch { return { ok: false, items, why: `no work folder at ${dir}` }; }
  for (const s of subs) {
    const one = /** @type {any} */ ({ dir: `${rel}/${s}` });
    for (const [file, key] of [['BRIEF.md', 'brief'], ['REPORT.md', 'report']]) {
      const p = path.join(dir, s, file); if (!fs.existsSync(p)) continue;
      one[key] = `${rel}/${s}/${file}`;
      let fm = /** @type {any} */ (null); try { fm = parseFrontMatter(fs.readFileSync(p, 'utf8')); } catch (e) { fm = { ok: false, error: String(/** @type {any} */ (e)?.message || e) }; }
      if (!fm.ok) { one[`${key}Error`] = String(fm.error).slice(0, 200); continue; }
      for (const k of ['wo', 'plan', 'stream', 'decision', 'status', 'branch', 'pr']) if (fm.data[k] != null && one[k] == null) one[k] = typeof fm.data[k] === 'object' ? JSON.stringify(fm.data[k]) : fm.data[k];
    }
    if (!one.wo && isWo(s)) one.wo = s;
    if (one.brief || one.report) items.push(one);
  }
  return { ok: true, items, why: '' };
}

/**
 * @param {{ repos: Array<{ path: string, name: string }>, plans?: string, work?: string, now?: Date }} o
 */
export function importLocal(o) {
  const at = (o.now || new Date()).toISOString(); /** @type {any[]} */ const events = []; const report = /** @type {any} */ ({ repos: [], plans: null, briefs: null });
  for (const r of o.repos) {
    const f = repoFacts(r.path, r.name);
    report.repos.push({ repo: r.name, ok: f.ok, why: f.why, worktrees: f.worktrees.length, ids: Object.keys(f.ids).length });
    events.push({ key: `local:repo:${r.name}:${hash(f)}`, at, actor: 'import', kind: 'x.local.repo', wo: null, data: f, proof: f.ok ? `git log ${f.main} at ${f.head}` : null });
  }
  if (o.plans) {
    const p = planFacts(o.plans); report.plans = { ok: p.ok, files: p.plans.length, why: p.why };
    events.push({ key: `local:plans:${hash(p)}`, at, actor: 'import', kind: 'x.local.plans', wo: null, data: p, proof: null });
  }
  if (o.work) {
    const b = briefFacts(o.work); report.briefs = { ok: b.ok, items: b.items.length, why: b.why };
    events.push({ key: `local:briefs:${hash(b)}`, at, actor: 'import', kind: 'x.local.briefs', wo: null, data: b, proof: null });
  }
  return { events, report };
}
