// @ts-check
// Importer: GitHub pull requests of every Tower -> work order events (read only on GitHub: `gh pr list` only, never a write).
//   - open PRs: gh pr list --state open (branch, base, head, mergeable, checks): one call per repo.
//   - merged PRs: the Board's G2 cached read (<state>\towers-github.json, pass-app/towers.mjs) when it is fresh (default 10 minutes),
//     else gh pr list --state merged --limit 100.
//   - a failed read (rate limit, offline, gh missing, not signed in) keeps the last good read (<out>\github-last.json, this importer's own
//     file; the state folder is never written) and says why in plain words. No PR is dropped and none is invented.
// The WO id comes from the title prefix (WO-312: ...), else the branch (kitchen/J312), else the PR gets its own id (WO-PR-TIDE-21), so an
// open PR is never missing from the ledger. A PR whose title says "Port #132" replaces open PR #132 of the one other repo that has it.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { woOfTitle, woOfBranch, woOfJob, woOfPr, prRef, streamOf, isoOrNull, text } from './ids.mjs';

const OPEN_FIELDS = 'number,title,headRefName,baseRefName,headRefOid,createdAt,updatedAt,mergeable,isDraft,statusCheckRollup';
const MERGED_FIELDS = 'number,title,headRefName,mergedAt,mergeCommit';
const SHA = /^[0-9a-f]{7,40}$/;
const RECENT_DAYS = 14;

/**
 * The real gh runner: no shell, an argument list, 15 s per call. Returns { ok, data } or { ok:false, why } in fixed words.
 * @param {string[]} args
 */
export function ghRun(args) {
  try {
    const out = execFileSync(process.env.LEDGER_GH || 'gh', args, { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, maxBuffer: 32 * 1024 * 1024 });
    return { ok: true, data: JSON.parse(out) };
  } catch (e) {
    const err = /** @type {any} */ (e); const msg = `${err?.stderr || ''} ${err?.message || ''}`;
    if (err?.code === 'ENOENT') return { ok: false, why: 'gh is not installed' };
    if (/rate limit/i.test(msg)) return { ok: false, why: 'rate-limited', rateLimited: true };
    if (/auth login|not logged|authentication/i.test(msg)) return { ok: false, why: 'gh is not signed in' };
    if (err?.signal === 'SIGTERM' || /ETIMEDOUT/.test(msg)) return { ok: false, why: 'gh took over 15 s' };
    if (/could not resolve|connect|network|offline/i.test(msg)) return { ok: false, why: 'offline (GitHub could not be reached)' };
    return { ok: false, why: 'gh failed' };
  }
}

/** @param {string} p */
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } }
/** @param {any[] | undefined} list @returns {'success'|'failure'|'pending'|null} */
function ciOf(list) {
  if (!Array.isArray(list) || !list.length) return null;
  const w = (/** @type {any} */ c) => String(c?.conclusion || c?.state || '').toUpperCase();
  if (list.some((c) => ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE'].includes(w(c)))) return 'failure';
  if (list.some((c) => (c?.status && String(c.status).toUpperCase() !== 'COMPLETED') || ['PENDING', 'EXPECTED', ''].includes(w(c)))) return 'pending';
  return 'success';
}
const goalOf = (/** @type {string} */ t) => text(String(t || '').replace(/^\s*WO-[A-Z0-9-]+\s*:\s*/, ''), 500) || 'untitled pull request';

/**
 * @param {{ repos: string[], state?: string, out: string, run?: (args: string[]) => any, now?: Date, cacheFreshMin?: number }} o
 */
export function importGithub(o) {
  const now = o.now || new Date(); const run = o.run || ghRun; const fresh = (o.cacheFreshMin ?? 10) * 60000;
  const lastPath = path.join(o.out, 'github-last.json');
  const last = readJson(lastPath) || { repos: {} };
  const cache = o.state ? readJson(path.join(o.state, 'towers-github.json')) : null;
  const cacheFresh = !!cache?.at && now.getTime() - Date.parse(cache.at) <= fresh && now.getTime() >= Date.parse(cache.at) - 60000;
  const cacheRepos = new Map(Object.entries(cache?.repos || {}).map(([k, v]) => [k.toLowerCase(), v]));
  /** @type {any[]} */ const events = []; const report = /** @type {any} */ ({ state: 'ok', cache: cache ? (cacheFresh ? 'fresh' : 'old') : 'none', repos: [] });
  const next = { at: last.at || null, repos: { ...last.repos } };
  /** @type {Map<string, any[]>} */ const openBy = new Map();

  for (const slug of o.repos) {
    const key = slug.toLowerCase(); const prev = last.repos[key] || {}; const r = { slug, open: 0, merged: 0, openFrom: 'gh', mergedFrom: 'gh', error: /** @type {string|null} */ (null) };
    let open = run(['pr', 'list', '-R', slug, '--state', 'open', '--limit', '100', '--json', OPEN_FIELDS]);
    if (open.ok && Array.isArray(open.data)) next.repos[key] = { ...(next.repos[key] || {}), open: open.data, openAt: now.toISOString() };
    else { r.error = open.why || 'gh gave no list'; if (open.rateLimited) report.state = 'rate-limited'; r.openFrom = prev.open ? 'last-good' : 'none'; open = { ok: true, data: prev.open || [] }; }
    let merged;
    const c = cacheRepos.get(key);
    if (cacheFresh && Array.isArray(c?.merged)) { merged = c.merged.map((/** @type {any} */ m) => ({ number: m.n, title: m.t, mergedAt: m.at, sha: m.sha, job: m.job })); r.mergedFrom = 'cache'; }
    else {
      const m = run(['pr', 'list', '-R', slug, '--state', 'merged', '--limit', '100', '--json', MERGED_FIELDS]);
      if (m.ok && Array.isArray(m.data)) { merged = m.data.map((/** @type {any} */ x) => ({ number: x.number, title: x.title, mergedAt: x.mergedAt, sha: x.mergeCommit?.oid, branch: x.headRefName })); next.repos[key] = { ...(next.repos[key] || {}), merged, mergedAt: now.toISOString() }; }
      else { r.error = r.error || m.why || 'gh gave no list'; if (m.rateLimited) report.state = 'rate-limited'; merged = prev.merged || []; r.mergedFrom = prev.merged ? 'last-good' : 'none'; }
    }
    openBy.set(key, open.data);
    const mergedNums = new Set(merged.map((/** @type {any} */ m) => m.number));
    // open PRs
    for (const p of open.data) {
      const n = Number(p.number); if (!Number.isInteger(n) || n < 1) continue;
      const pr = prRef(slug, n); const branch = String(p.headRefName || ''); const head = String(p.headRefOid || '').toLowerCase();
      const wo = woOfTitle(p.title) || woOfBranch(branch) || woOfPr(slug, n); const at = isoOrNull(p.createdAt) || now.toISOString();
      if (!woOfBranch(branch)) events.push({ key: `gh:${key}#${n}:created`, at, actor: 'github', kind: 'wo.created', wo, data: { goal: goalOf(p.title), stream: streamOf(branch, wo), repo: slug }, proof: null });
      if (!SHA.test(head) || !branch || !p.baseRefName) continue;
      events.push({ key: `gh:${key}#${n}:opened`, at, actor: 'github', kind: 'pr.opened', wo, data: { pr, branch, base: String(p.baseRefName), head, title: text(p.title, 500) || pr }, proof: `${slug} pull ${n}` });
      const mg = p.mergeable === 'CONFLICTING' ? 'conflicting' : p.mergeable === 'MERGEABLE' ? 'yes' : 'unknown';
      const upAt = isoOrNull(p.updatedAt) || at;
      events.push({ key: `gh:${key}#${n}:head:${head}:${mg}`, at: upAt, actor: 'github', kind: 'pr.updated', wo, data: { pr, head, why: mg === 'conflicting' ? 'conflict' : 'push', mergeable: mg }, proof: null });
      const ci = ciOf(p.statusCheckRollup);
      if (ci) events.push({ key: `gh:${key}#${n}:ci:${head}:${ci}`, at: upAt, actor: 'github', kind: 'ci.result', wo, data: { pr, head, conclusion: ci, checks: p.statusCheckRollup.length, failed: p.statusCheckRollup.filter((/** @type {any} */ x) => /FAIL|ERROR|CANCEL|TIMED/i.test(String(x?.conclusion || x?.state || ''))).length }, proof: null });
      r.open++;
    }
    // a PR that was open at the last good read and is now neither open nor merged was closed unmerged
    if (r.openFrom === 'gh') for (const p of prev.open || []) {
      if (open.data.some((/** @type {any} */ x) => x.number === p.number) || mergedNums.has(p.number) || !SHA.test(String(p.headRefOid || ''))) continue;
      const wo = woOfTitle(p.title) || woOfBranch(p.headRefName) || woOfPr(slug, p.number);
      events.push({ key: `gh:${key}#${p.number}:closed`, at: now.toISOString(), actor: 'github', kind: 'pr.updated', wo, data: { pr: prRef(slug, p.number), head: String(p.headRefOid).toLowerCase(), why: 'closed' }, proof: null });
    }
    // merged PRs: those that name a work order, and every one merged in the last RECENT_DAYS days
    for (const m of merged) {
      const n = Number(m.number); const sha = String(m.sha || '').toLowerCase(); if (!Number.isInteger(n) || !SHA.test(sha)) continue;
      const named = woOfTitle(m.title) || (m.job ? woOfJob(String(m.job)) : null) || woOfBranch(m.branch);
      const recent = now.getTime() - Date.parse(m.mergedAt || 0) <= RECENT_DAYS * 864e5;
      if (!named && !recent) continue;
      const wo = named || woOfPr(slug, n); const at = isoOrNull(m.mergedAt) || now.toISOString();
      if (!woOfBranch(m.branch) && !m.job) events.push({ key: `gh:${key}#${n}:created`, at, actor: 'github', kind: 'wo.created', wo, data: { goal: goalOf(m.title), stream: streamOf(m.branch || '', wo), repo: slug }, proof: null });
      events.push({ key: `gh:${key}#${n}:merged`, at, actor: 'github', kind: 'merged', wo, data: { pr: prRef(slug, n), sha }, proof: `merge commit ${sha}` });
      r.merged++;
    }
    report.repos.push(r);
  }
  // ports: "Port #132" / "private #133" in a title replaces open PR 132 of the one other repo that has it open
  for (const slug of o.repos) {
    const key = slug.toLowerCase();
    for (const p of [...(openBy.get(key) || []), ...((next.repos[key]?.merged) || [])]) {
      for (const mm of String(p.title || '').matchAll(/(?:port(?:s|ed)?|private)\s+#(\d+)/gi)) {
        const n = Number(mm[1]); const others = [...openBy].filter(([k, l]) => k !== key && l.some((x) => x.number === n));
        if (others.length !== 1) continue;
        const [ok, ol] = others[0]; const src = ol.find((x) => x.number === n);
        const from = woOfTitle(src.title) || woOfBranch(src.headRefName) || woOfPr(ok, n); const by = woOfTitle(p.title) || woOfBranch(p.headRefName || p.branch) || woOfPr(slug, p.number);
        if (from !== by) events.push({ key: `gh:${ok}#${n}:ported:${key}#${p.number}`, at: now.toISOString(), actor: 'github', kind: 'replaced', wo: from, data: { by, reason: `ported to ${prRef(slug, p.number)}` }, proof: null });
      }
    }
  }
  if (report.state === 'ok' && report.repos.some((/** @type {any} */ r) => r.error)) report.state = report.repos.every((/** @type {any} */ r) => r.error) ? 'offline' : 'partial';
  if (report.repos.some((/** @type {any} */ r) => !r.error)) next.at = now.toISOString();
  fs.mkdirSync(o.out, { recursive: true });
  const tmp = `${lastPath}.tmp-${process.pid}`; fs.writeFileSync(tmp, JSON.stringify(next)); fs.renameSync(tmp, lastPath);
  report.lastGoodAt = next.at;
  return { events, report };
}
