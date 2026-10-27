// The City's data (GET /api/towers): one row per project on this PC (a Tower, a Lot or the Office) with its floors (merged work), its
// cranes (open PRs) and its stone base. Called by server.mjs (the route, towersV in the state, jobView.tower) and pass-app/test-city.mjs.
// Read-only. Sources: the state-folder kitchen.json (bootRepos, city), each repo's kitchen.repo.json, merges.jsonl, results\J*.merge.json,
// J*.pr.json, J*.ci.json, automerged.jsonl, ledger.json, git (counts, every 10 min) and GitHub (gh, read-only, every 5 min), both off the
// main thread through the server's run(). The last good GitHub read is kept in <state>	owers-github.json, so a failed read drops nothing.
// The truth rule (plans/city-god-mode-2026-10-26.md section 4): a field with no record is left out, so the phone draws nothing for it.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

const SHA = /^[0-9a-f]{40}$/;
const SLUG = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/;
const REF = /^(?!-)(?!.*\.\.)[\w./-]{1,100}$/;
const JOB = /^J\d{1,6}$/;
const ACTIVE = new Set(['pending', 'running', 'waiting-approval', 'needs-human']);
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch { return null; } };
const sigOf = (p) => { try { const st = fs.statSync(p); return `${st.size}:${st.mtimeMs}`; } catch { return '-'; } };
const isoOf = (v) => (typeof v === 'string' && Number.isFinite(Date.parse(v)) ? new Date(v).toISOString() : null);
// a folder as one comparable string (Windows paths ignore case)
export const normPath = (p) => { const r = path.resolve(String(p || '')).replace(/[\\/]+$/, ''); return process.platform === 'win32' ? r.toLowerCase() : r; };
// owner/name from any form a repo's GitHub home is written in (owner/name, an https or ssh URL); '' when it is none of those
export function slugOf(v) {
  const s = String(v || '').trim().replace(/^(?:(?:git\+)?(?:https?|ssh|git):\/\/(?:[^@/]+@)?(?:www\.)?github\.com\/|git@github\.com:)/i, '').replace(/\/+$/, '').replace(/\.git$/i, '');
  return SLUG.test(s) && !s.includes('..') ? s : '';
}
// the repo a work order changes: its merge step's Repo, else any step's Repo; '' for orders with no repo (research, career, scouts)
export function repoArgOf(j) {
  const steps = Array.isArray(j?.steps) ? j.steps : [];
  const m = steps.find((s) => /merge\.ps1$/i.test(String(s?.script || '')) && s.args?.Repo) || steps.find((s) => s?.args?.Repo);
  return m ? String(m.args.Repo) : '';
}
// "batch-run integrate-<name>: ..." in a merges.jsonl why: the Pour (the PRs tested and merged together) that floor came with
export const pourOf = (why) => /\bbatch-run (?:integrate-)?([\w.-]{1,60})/.exec(String(why || ''))?.[1] || null;
const keyOf = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^[-.]+|[-.]+$/g, '').slice(0, 40);

// ---- the Sites on this PC: the state-folder kitchen.json bootRepos (folders under the profile, or absolute), else this repo alone ----
// city (optional, state folder only, so personal names never sit in the public repo):
//   names   { <key>: 'Shown name' }                  what each building is called on the Board
//   office  '<folder name>'                          the repo drawn as the Office (default: gemini-brain)
//   history { <key>: { github: 'owner/name', ref } } an older repo whose merged PRs sit under the "public from" line, on a stone base
//                                                    of <ref>'s first-parent commits (Tide's private history; only on this Board)
export function sitesOf(root, repoHome, home = os.homedir()) {
  const errors = []; const kp = path.join(root, 'kitchen.json'); const k = readJson(kp);
  if (!k && fs.existsSync(kp)) errors.push({ error: "the state folder's kitchen.json cannot be read, so only this repo is shown" });
  const city = k?.city && typeof k.city === 'object' ? k.city : {};
  const boot = Array.isArray(k?.bootRepos) ? k.bootRepos.filter((s) => typeof s === 'string' && s.trim()) : [];
  const list = boot.length ? boot.map((p) => (path.isAbsolute(p) ? p : path.join(home, p))) : [repoHome];
  const office = String(city.office || 'gemini-brain').toLowerCase(); const names = city.names && typeof city.names === 'object' ? city.names : {};
  const sites = []; const seenPath = new Set(); const seenKey = new Set();
  for (const p of list) {
    const n = normPath(p); if (seenPath.has(n)) continue; seenPath.add(n);
    let dir = false; try { dir = fs.statSync(p).isDirectory(); } catch {}
    if (!dir) { errors.push({ error: `a folder in bootRepos is not on this PC (${path.basename(n)})` }); continue; }
    const rc = readJson(path.join(p, 'kitchen.repo.json')) || {}; const folder = path.basename(n); const slug = slugOf(rc.github);
    const site = /^[A-Za-z]{2,4}$/.test(String(rc.site || '')) ? String(rc.site).toLowerCase() : '';
    let key = keyOf(site || (slug ? slug.split('/')[1] : folder)) || 'site'; const base = key;
    for (let i = 2; seenKey.has(key); i++) key = `${base}-${i}`;
    seenKey.add(key);
    // config is looked up by key, then GitHub name, then folder name, so it holds when a Site code arrives later (tide -> td)
    const pick = (o) => [key, slug ? slug.split('/')[1].toLowerCase() : '', folder.toLowerCase()].map((k) => o?.[k]).find((v) => v !== undefined);
    const h = pick(city.history); const hist = h && slugOf(h.github) && REF.test(String(h.ref || '')) ? { slug: slugOf(h.github), ref: String(h.ref) } : null;
    const nm = pick(names); const shown = typeof nm === 'string' && nm.trim() ? nm.trim().slice(0, 40) : n === normPath(repoHome) ? 'Tide' : folder;
    sites.push({ key, name: shown, dir: p, n, folder, slug, office: folder.toLowerCase() === office, history: hist });
  }
  return { sites, errors };
}

// ---- local records -> floors and cranes per Site ----
function jsonLines(p) {
  let text = ''; try { text = fs.readFileSync(p, 'utf8'); } catch { return []; }
  return text.split(/\r?\n/).map((l) => { try { return l.trim() ? JSON.parse(l) : null; } catch { return null; } }).filter((o) => o && typeof o === 'object');
}
// automerged.jsonl: which orders merged on their own (by 'auto') and which merges were taken down since (undone at)
function automergedOf(root) {
  const auto = new Set(); const undone = new Map();
  for (const o of jsonLines(path.join(root, 'automerged.jsonl'))) {
    if (!JOB.test(String(o.job || ''))) continue;
    if (o.undone) undone.set(o.job, isoOf(o.at)); else if (!o.type) auto.add(o.job);
  }
  return { auto, undone };
}
// id -> month of every archived order, from the archive's own index (jobs\archive\index.jsonl: one line per order, a later line for
// the same id wins, as kitchen/jobs-lib.ps1 Read-KitchenJobArchive reads it). The jobs folder is never listed (tests/Test-JobsIndex.ps1).
function archiveMonths(root) {
  const by = new Map();
  for (const o of jsonLines(path.join(root, 'jobs', 'archive', 'index.jsonl'))) if (JOB.test(String(o.id || '')) && /^\d{4}-\d{2}$/.test(String(o.month || ''))) by.set(o.id, o.month);
  return by;
}
// a job file, live or archived (jobs\archive\<month>\J*.json, its month from archiveMonths); a jobs\ file wins, as in the store
function jobFileOf(root, id, months) {
  const live = readJson(path.join(root, 'jobs', id + '.json')); if (live) return live;
  const m = months.get(id); if (!m) return null;
  return readJson(path.join(root, 'jobs', 'archive', m, id + '.json'));
}
function resultIds(root) {
  let files = []; try { files = fs.readdirSync(path.join(root, 'results')); } catch { return { merge: [], pr: [] }; }
  const ids = (ext) => files.filter((f) => f.endsWith(ext)).map((f) => f.slice(0, -ext.length)).filter((id) => JOB.test(id));
  return { merge: ids('.merge.json'), pr: ids('.pr.json') };
}
// the pr station's record of an order's pull request: { slug, number, at } or null (skipped, or not a github.com PR)
function prRecord(root, id) {
  const r = readJson(path.join(root, 'results', id + '.pr.json'));
  if (!r || r.skipped || !Number.isInteger(r.number) || r.number < 1) return null;
  const slug = slugOf(r.repo) || slugOf(String(r.url || '').replace(/\/pull\/\d+$/, ''));
  return slug ? { slug, number: r.number, at: isoOf(r.pushedAt) } : null;
}
// an order's last CI look (results\J*.ci.json, ci-wait): red, pending or green; anything else (an error look, none) is unknown
function ciOf(root, id) { const c = readJson(path.join(root, 'results', id + '.ci.json')); return ['red', 'pending', 'green'].includes(c?.state) ? c.state : null; }

// who made a floor, strongest record first: a work order merged on its own, a work order, a session, else GitHub's word alone
const BY_RANK = { github: 0, session: 1, yard: 2, auto: 3 };
const joinFloor = (a, b) => ({ ...b, ...a, by: (BY_RANK[b.by] || 0) > (BY_RANK[a.by] || 0) ? b.by : a.by, job: a.job || b.job, title: a.title || b.title, pour: a.pour || b.pour, sha: a.sha || b.sha, undone: a.undone || b.undone });
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== ''));
// github: Map lower-case owner/name -> { merged: [{n, t, at, sha, job}], open: [{n, t, at, draft, ci, job}] | null } (null = never read)
export function localRecords(root, sites, jobs = [], github = new Map()) {
  const bySlug = new Map(); const byPath = new Map(sites.map((s) => [s.n, s.key]));
  for (const s of sites) { if (s.slug) bySlug.set(s.slug.toLowerCase(), { key: s.key, past: false }); if (s.history) bySlug.set(s.history.slug.toLowerCase(), { key: s.key, past: true }); }
  const floors = new Map(sites.map((s) => [s.key, new Map()])); const open = new Map(sites.map((s) => [s.key, []]));
  const add = (key, id, f) => { const m = floors.get(key); const was = m.get(id); m.set(id, was ? joinFloor(was, f) : f); };
  // 0. GitHub's merged PRs (the most complete record): the title, the merge commit, the work order from its branch (kitchen/J123)
  for (const [slug, t] of bySlug) {
    for (const p of github.get(slug)?.merged || []) add(t.key, `pr:${t.past ? 'old' : 'new'}#${p.n}`, clean({ pr: p.n, sha: p.sha, at: p.at, by: 'github', title: p.t, job: p.job, past: t.past || undefined }));
  }
  // 1. merges.jsonl: every merge a session made with scripts/merge-pr.ps1 (ok only)
  for (const r of jsonLines(path.join(root, 'merges.jsonl'))) {
    const t = bySlug.get(String(r.repo || '').toLowerCase()); const at = isoOf(r.at);
    if (r.ok !== true || !t || !Number.isInteger(r.pr) || r.pr < 1 || !at) continue;
    add(t.key, `pr:${t.past ? 'old' : 'new'}#${r.pr}`, { pr: r.pr, ...(SHA.test(r.sha) ? { sha: r.sha } : {}), at, by: 'session', ...(pourOf(r.why) ? { pour: pourOf(r.why) } : {}), ...(t.past ? { past: true } : {}) });
  }
  // 2. results\J*.merge.json: every merge a work order made (on GitHub through its PR, or locally with no PR)
  const am = automergedOf(root); const ids = resultIds(root); const live = new Map(jobs.map((j) => [j.id, j]));
  const months = archiveMonths(root);
  for (const id of ids.merge) {
    const mr = readJson(path.join(root, 'results', id + '.merge.json')); const at = isoOf(mr?.at); if (!mr || !at) continue;
    const job = live.get(id) || jobFileOf(root, id, months); const pr = mr.via === 'github' ? prRecord(root, id) : null;
    const t = pr ? bySlug.get(pr.slug.toLowerCase()) : null; const key = t?.key || byPath.get(normPath(repoArgOf(job)));
    if (!key || !job || (pr && !t)) continue;   // a PR into a repo that is not on the City (no Site, no history) is not a floor here
    const f = { ...(pr ? { pr: pr.number } : {}), ...(SHA.test(mr.after) ? { sha: mr.after } : {}), at, by: am.auto.has(id) ? 'auto' : 'yard', job: id, ...(t?.past ? { past: true } : {}) };
    if (am.undone.has(id)) f.undone = am.undone.get(id) || at;
    add(key, pr ? `pr:${t.past ? 'old' : 'new'}#${pr.number}` : `sha:${f.sha || id}`, f);
  }
  // 3. cranes: GitHub's open PRs once read (every open PR, hand PRs too); before that, the Yard's own active orders with a PR and no merge
  const read = new Set();
  for (const [slug, t] of bySlug) {
    const g = github.get(slug); if (t.past || !Array.isArray(g?.open)) continue;
    read.add(slug);
    for (const o of g.open) open.get(t.key).push(clean({ pr: o.n, title: o.t, draft: !!o.draft, ci: o.ci || (o.job ? ciOf(root, o.job) : null), job: o.job, createdAt: o.at }));
    for (const o of open.get(t.key)) if (o.ci === undefined) o.ci = null;
  }
  const merged = new Set(ids.merge);
  for (const id of ids.pr) {
    const j = live.get(id); if (!j || !ACTIVE.has(j.status) || merged.has(id)) continue;
    const pr = prRecord(root, id); const t = pr && bySlug.get(pr.slug.toLowerCase()); if (!t || t.past || read.has(pr.slug.toLowerCase())) continue;
    open.get(t.key).push({ pr: pr.number, draft: false, ci: ciOf(root, id), job: id, ...(pr.at ? { createdAt: pr.at } : {}) });
  }
  return { floors: new Map([...floors].map(([k, m]) => [k, dedupeBySha([...m.values()])])), open };
}
// one floor per merge commit: a PR merge and the same commit seen again (a sha-only record) are one floor; oldest first
function dedupeBySha(list) {
  const out = []; const bySha = new Map();
  for (const f of list) {
    const was = f.sha ? bySha.get(f.sha) : null;
    if (was) { if (!was.job && f.job) Object.assign(was, { job: f.job, by: f.by }); if (!was.pr && f.pr) was.pr = f.pr; continue; }
    out.push(f); if (f.sha) bySha.set(f.sha, f);
  }
  return out.sort((a, b) => a.at.localeCompare(b.at) || (a.pr || 0) - (b.pr || 0));
}

// ---- git: counts per repo, off the main thread (the server's run()), kept between reads ----
const GIT_OPTS = { encoding: 'utf8', timeout: 15000, windowsHide: true, maxBuffer: 1 << 20 };
async function gitOut(run, dir, args) { const { err, out } = await run('git', ['-C', dir, ...args], GIT_OPTS); return err ? null : String(out || '').trim(); }
const countOf = (s) => (s !== null && /^\d+$/.test(s) ? Number(s) : null);
async function gitFacts(run, site, firstAt) {
  const [commits, last, remote] = await Promise.all([gitOut(run, site.dir, ['rev-list', '--count', 'HEAD']), gitOut(run, site.dir, ['log', '-1', '--format=%cI']), gitOut(run, site.dir, ['remote', 'get-url', 'origin'])]);
  const g = { commits: countOf(commits), lastCommit: isoOf(last), remoteSlug: slugOf(remote), plinth: null };
  if (site.history) {
    const [n, at] = await Promise.all([gitOut(run, site.dir, ['rev-list', '--count', '--first-parent', site.history.ref]), gitOut(run, site.dir, ['log', '-1', '--format=%cI', site.history.ref])]);
    if (countOf(n) !== null) g.plinth = { commits: countOf(n), before: isoOf(at) };
  } else if (firstAt) {
    const n = countOf(await gitOut(run, site.dir, ['rev-list', '--count', '--first-parent', '--before=' + firstAt, 'HEAD']));
    if (n !== null) g.plinth = { commits: n, before: firstAt };
  }
  return g;
}

// ---- GitHub: merged and open PRs, their CI and titles; read-only, off the main thread, every 5 min ----
// gh is `gh` on PATH, or PASS_GH (a .mjs or .js file runs under node: the tests' fake). PASS_GITHUB=off turns the reads off.
const GH_MERGED = 'number,title,mergedAt,mergeCommit,headRefName';
const GH_OPEN = 'number,title,isDraft,createdAt,headRefName,statusCheckRollup';
const oneLine = (v, max) => (typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '');
const jobOfBranch = (b) => /^kitchen\/(J\d{1,6})$/.exec(String(b || ''))?.[1] || undefined;
// what went wrong, in plain words (never gh's raw output)
function ghWhy(err, out) {
  const t = `${err?.message || ''} ${err?.code || ''} ${out || ''}`;
  return /auth login|not logged|HTTP 401|Bad credentials/i.test(t) ? 'gh is not signed in' : /rate limit/i.test(t) ? 'GitHub rate limit reached'
    : /ENOENT/.test(t) ? 'gh is not installed' : /ETIMEDOUT|timed out|SIGTERM|killed/i.test(t) ? 'gh took over 15 s' : /HTTP 404|Could not resolve/i.test(t) ? 'the repo is not on GitHub' : 'gh failed';
}
export async function ghCall(run, args, gh = process.env.PASS_GH || 'gh') {
  const viaNode = /\.(m?js|cjs)$/i.test(gh); const t0 = Date.now();
  const { err, out } = await run(viaNode ? process.execPath : gh, viaNode ? [gh, ...args] : args, { encoding: 'utf8', timeout: 15000, windowsHide: true, maxBuffer: 32 << 20 });
  const ms = Date.now() - t0;
  if (err) return { ok: false, ms, error: ghWhy(err, out) };
  try { return { ok: true, ms, data: JSON.parse(out) }; } catch { return { ok: false, ms, error: 'gh gave an answer that is not JSON' }; }
}
// a PR's checks (statusCheckRollup: check runs and commit statuses): any failure is red, anything unfinished is pending, else green;
// no checks at all is unknown (null)
export function ciOfRollup(list) {
  if (!Array.isArray(list) || !list.length) return null;
  const word = (c) => String(c?.conclusion || c?.state || '').toUpperCase();
  if (list.some((c) => ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE'].includes(word(c)))) return 'red';
  if (list.some((c) => (c?.status && String(c.status).toUpperCase() !== 'COMPLETED') || ['PENDING', 'EXPECTED', ''].includes(word(c)))) return 'pending';
  return 'green';
}
const slimMerged = (p) => clean({ n: p?.number, t: oneLine(p?.title, 140), at: isoOf(p?.mergedAt), sha: SHA.test(p?.mergeCommit?.oid || '') ? p.mergeCommit.oid : undefined, job: jobOfBranch(p?.headRefName) });
const slimOpen = (p) => ({ ...clean({ n: p?.number, t: oneLine(p?.title, 140), at: isoOf(p?.createdAt), job: jobOfBranch(p?.headRefName) }), draft: !!p?.isDraft, ci: ciOfRollup(p?.statusCheckRollup) });
const goodPr = (p) => Number.isInteger(p.n) && p.n > 0 && !!p.at;
// one repo's lists, read again: merged in full the first time, then only those merged since a day before the newest one kept
async function readRepo(run, t, c, now) {
  const errs = []; let reads = 0; const next = { ...c };
  if (!(c.privateAt && now - Date.parse(c.privateAt) < 864e5)) {   // private or public, once a day (not a list: not counted in reads)
    const r = await ghCall(run, ['api', `repos/${t.slug}`, '--jq', '.private']);
    if (r.ok && typeof r.data === 'boolean') Object.assign(next, { private: r.data, privateAt: new Date(now).toISOString() }); else errs.push(`${t.slug}: ${r.error || 'gh gave no visibility'}`);
  }
  if (t.office) return { next, errs, reads };   // the Office: only whether it is private (it has no floors)
  if (!(t.past &&c.merged && now - Date.parse(c.mergedAt || 0) < 864e5)) {   // an old history repo: once a day is plenty
    const newest = (c.merged || []).map((p) => p.at).sort().pop();
    const since = newest ? new Date(Date.parse(newest) - 864e5).toISOString().slice(0, 10) : null;
    const r = await ghCall(run, ['pr', 'list', '-R', t.slug, '--state', 'merged', '--json', GH_MERGED, ...(since ? ['--search', `merged:>=${since}`, '--limit', '200'] : ['--limit', '1000'])]); reads++;
    if (r.ok && Array.isArray(r.data)) {
      const byN = new Map((c.merged || []).map((p) => [p.n, p])); for (const p of r.data.map(slimMerged).filter(goodPr)) byN.set(p.n, p);
      next.merged = [...byN.values()].sort((a, b) => a.n - b.n); next.mergedAt = new Date(now).toISOString();
    } else errs.push(`${t.slug}: ${r.error || 'gh gave no list'}`);
  }
  if (!t.past) {
    const r = await ghCall(run, ['pr', 'list', '-R', t.slug, '--state', 'open', '--limit', '100', '--json', GH_OPEN]); reads++;
    if (r.ok && Array.isArray(r.data)) next.open = r.data.map(slimOpen).filter(goodPr).sort((a, b) => a.n - b.n); else errs.push(`${t.slug}: ${r.error || 'gh gave no list'}`);
  }
  return { next, errs, reads };
}
// the repos to read: every Tower's or Lot's GitHub home (kitchen.repo.json github, else its origin remote) and each old history repo;
// the Office's only for whether it is private
export function githubTargets(sites, gitBy = new Map()) {
  const out = new Map();
  for (const s of sites) {
    const slug = s.slug || gitBy.get(s.key)?.remoteSlug; if (slug) out.set(slug.toLowerCase(), s.office ? { slug, past: false, office: true } : { slug, past: false });
    if (s.history && !out.has(s.history.slug.toLowerCase())) out.set(s.history.slug.toLowerCase(), { slug: s.history.slug, past: true });
  }
  return [...out.values()];
}
export function makeGithub({ root, run, targets, everyMs = Number(process.env.PASS_GITHUB_MS) || 300000, off = process.env.PASS_GITHUB === 'off', log = () => {} }) {
  const file = path.join(root, 'towers-github.json'); const saved = readJson(file);
  const gh = { repos: new Map(Object.entries(saved?.repos || {}).map(([k, v]) => [k.toLowerCase(), v])), at: isoOf(saved?.at), error: null, ver: 0, busy: null, stats: null };
  async function refresh() {
    if (off) return;
    if (gh.busy) return gh.busy;
    gh.busy = (async () => {
      const lists = () => JSON.stringify([...gh.repos].map(([k, c]) => [k, c.merged, c.open, c.private]));   // what is drawn, not when it was read
      const t0 = Date.now(); let reads = 0; const errs = []; const before = lists();
      for (const t of targets()) {
        const r = await readRepo(run, t, gh.repos.get(t.slug.toLowerCase()) || {}, Date.now());
        gh.repos.set(t.slug.toLowerCase(), r.next); reads += r.reads; errs.push(...r.errs);
      }
      const rl = await ghCall(run, ['api', 'rate_limit']);   // free: asking for the limit does not use it
      gh.stats = { ms: Date.now() - t0, reads, left: rl.ok ? rl.data?.resources?.graphql?.remaining ?? null : null };
      const error = errs.length ? errs[0] : null; const moved = lists() !== before || error !== gh.error;
      gh.error = error; if (!errs.length) gh.at = new Date().toISOString();
      if (moved) gh.ver++;
      try { const tmp = `${file}.tmp-${process.pid}`; fs.writeFileSync(tmp, JSON.stringify({ at: gh.at, repos: Object.fromEntries(gh.repos) })); fs.renameSync(tmp, file); } catch {}
      log(`towers: GitHub read ${reads} lists in ${gh.stats.ms} ms; ${gh.stats.left ?? 'unknown'} GraphQL points left${error ? '; ' + error : ''}`);
    })().catch((e) => { gh.error = 'the GitHub read failed: ' + String(e?.message || e).slice(0, 120); gh.ver++; }).finally(() => { gh.busy = null; });
    return gh.busy;
  }
  const timer = off ? null : setInterval(() => refresh(), everyMs); timer?.unref?.();
  return { gh, refresh, stop() { if (timer) clearInterval(timer); } };
}

// ---- the view ----
function blueprints(root) {
  const out = new Map();
  const programs = readJson(path.join(root, 'ledger.json'))?.programs;
  for (const p of Array.isArray(programs) ? programs : []) {
    if (p && typeof p.repo === 'string' && Number.isInteger(p.total) && p.total > 0 && Number.isInteger(p.shipped) && p.shipped >= 0) out.set(p.repo.toLowerCase(), { total: p.total, shipped: Math.min(p.shipped, p.total) });
  }
  return out;
}
// a floor or crane of a private work order carries no title (the CREED privacy rule); priv(id) is true for a private order, and for one
// whose file cannot be found (unknown counts as private)
const untitled = ({ title, ...rest }) => rest;
const scrub = (x, priv) => (x.title && x.job && priv(x.job) ? untitled(x) : x);
// A private repo on the City (Jordan's privacy bar, review F3): a Site whose GitHub repo is private, or whose visibility is not known yet
// (fail closed: before the first git and GitHub reads), is marked private: a padlock, no GitHub link, and a neutral key (so its name is in
// no route or link). A Site with no GitHub home (git read, no origin on GitHub) is not. Task 30 (D-11, Jordan 10-27): on his own signed-in
// Board (tailnet and key only) a private repo keeps its real name and its PR titles; only demo, fixture and screenshot mode (alias: true,
// the server reads PASS_CITY_ALIAS=1) draws it as "Private project" with counts only. A private work order's title stays out either way.
// vis(slug) -> true (private), false (public), undefined (not read yet); slugs lower-case
export const isPrivateSite = (s, g, vis) => { const slug = s.slug || g?.remoteSlug; return slug ? vis(slug.toLowerCase()) !== false : !g; };
// the key and name each Site shows: its own, or private, private-2 ... (and, with alias, "Private project", "Private project 2" ...) in
// bootRepos order
export function shownAs(sites, priv, alias = true) {
  const out = new Map(); const taken = new Set(sites.filter((s) => !priv(s)).map((s) => s.key)); let n = 0;
  for (const s of sites) {
    if (!priv(s)) { out.set(s.key, { key: s.key, name: s.name }); continue; }
    let k; do { n++; k = n > 1 ? `private-${n}` : 'private'; } while (taken.has(k));
    out.set(s.key, { key: k, name: alias ? (n > 1 ? `Private project ${n}` : 'Private project') : s.name, private: true });
  }
  return out;
}
export function buildTowers({ sites, errors = [] }, rec, gitBy = new Map(), extra = {}) {
  const bp = extra.blueprints || new Map(); const priv = extra.isPrivateJob || (() => false); const vis = extra.repoPrivate || (() => undefined); const rows = []; const alias = !!extra.alias;
  const shown = shownAs(sites, (s) => isPrivateSite(s, gitBy.get(s.key), vis), alias);
  for (const s of sites) {
    const g = gitBy.get(s.key) || {}; const as = shown.get(s.key); const oldPriv = !!s.history && vis(s.history.slug.toLowerCase()) !== false;
    // a private Site's floors and cranes carry no title; nor do the old floors from a private history repo (under the "public from" line)
    const hide = (x) => (alias && (as.private || (x.past && oldPriv)) ? untitled(x) : x);
    const floors = (rec.floors.get(s.key) || []).map((f) => hide(scrub(f, priv))); const open = (rec.open.get(s.key) || []).map((o) => hide(scrub(o, priv)));
    const kind = s.office ? 'office' : floors.length || open.length ? 'tower' : 'lot';
    // folder and repo stay on a private row only so the phone can match the state's own records (main status, freeze), which already
    // name them; the City never draws either
    const t = { key: as.key, name: as.name, ...(as.private ? { private: true } : {}), kind, folder: s.folder, repo: s.slug || g.remoteSlug || null, floors: kind === 'office' ? [] : floors, open: kind === 'office' ? [] : open };
    if (kind === 'tower' && g.plinth) t.plinth = g.plinth;
    if (kind === 'lot' && g.commits !== null && g.commits !== undefined) t.plinth = { commits: g.commits, before: g.lastCommit || null };
    if (kind === 'office') { if (g.commits !== null && g.commits !== undefined) t.commits = g.commits; if (g.lastCommit) t.lastCommit = g.lastCommit; }
    if (s.history && kind === 'tower') {   // the public repo's first merged PR; a Yard merge with no PR before it was made in the old history
      const first = floors.find((f) => !f.past && f.pr); if (first) { t.publicFrom = first.at; for (const f of floors) if (!f.pr && f.at < first.at) f.past = true; }
    }
    if (bp.has(s.folder.toLowerCase())) t.blueprint = bp.get(s.folder.toLowerCase());
    rows.push(t);
  }
  // left to right: towers by their first floor (a tower never moves), then lots and the Office in bootRepos order
  const first = (t) => t.floors[0]?.at || t.open.map((o) => o.createdAt || '').sort()[0] || '9';
  const rank = { tower: 0, lot: 1, office: 2 };
  const ordered = rows.map((t, i) => ({ t, i })).sort((a, b) => rank[a.t.kind] - rank[b.t.kind] || (a.t.kind === 'tower' ? first(a.t).localeCompare(first(b.t)) : 0) || a.i - b.i).map((x) => x.t);
  return { towers: ordered, errors };
}
// the version the phone compares (state towersV): it moves only when what /api/towers says moved
export const versionOf = (body) => crypto.createHash('sha1').update(JSON.stringify(body)).digest('hex').slice(0, 12);

// makeTowers: the server's one instance. run(file, args, opts) -> {err, out} is the server's off-thread runner.
// github: { everyMs, off, log } for the GitHub reads (tests pass their own; the server takes the defaults)
export function makeTowers({ root, repoHome, run, jobs = () => [], isPrivate = () => false, alias = process.env.PASS_CITY_ALIAS === '1', home = os.homedir(), gitEveryMs = Number(process.env.PASS_TOWERS_GIT_MS) || 600000, sigEveryMs = 3000, github = {} }) {
  const git = { by: new Map(), at: null, busy: null, ver: 0 }; const memo = { sig: '', checked: 0, body: null, v: '' };
  // the Sites are read again when the state kitchen.json changes, and at most every 30 s otherwise (a repo's kitchen.repo.json, a new folder)
  const sm = { sig: '', at: 0, val: null };
  const sitesNow = () => { const sig = sigOf(path.join(root, 'kitchen.json')); if (sm.val && sm.sig === sig && Date.now() - sm.at < 30000) return sm.val; Object.assign(sm, { sig, at: Date.now(), val: sitesOf(root, repoHome, home) }); return sm.val; };
  const G = makeGithub({ root, run, targets: () => githubTargets(sitesNow().sites, git.by), ...github });
  const vis = (slug) => G.gh.repos.get(slug)?.private;   // true / false from GitHub; undefined until read (counts as private)
  const inputSig = () => {
    const files = ['kitchen.json', 'merges.jsonl', 'automerged.jsonl', 'ledger.json', 'results'].map((f) => sigOf(path.join(root, f)));
    const r = resultIds(root); const live = new Map(jobs().map((j) => [j.id, j]));
    const recs = [...r.merge.map((id) => id + '.merge.json'), ...r.pr.flatMap((id) => [id + '.pr.json', id + '.ci.json'])].map((f) => f + sigOf(path.join(root, 'results', f)));
    const states = r.pr.map((id) => `${id}:${live.get(id)?.status || '-'}:${live.has(id) && isPrivate(live.get(id)) ? 1 : 0}`);
    return [...files, ...recs, ...states, git.ver, G.gh.ver].join('|');
  };
  // privacy of a work order named on a floor or crane: its live file, else its archived one (kept: archived files do not change);
  // an order whose file cannot be found counts as private (no title), never as public
  const archived = new Map();
  function privacyOf(list) {
    const live = new Map(list.map((j) => [j.id, j]));
    let months = null;
    return (id) => {
      if (live.has(id)) return !!isPrivate(live.get(id));
      if (!archived.has(id)) {
        months ??= archiveMonths(root);
        const j = jobFileOf(root, id, months); archived.set(id, j ? !!isPrivate(j) : null);
      }
      const p = archived.get(id); return p === null ? true : p;
    };
  }
  function compute() {
    const st = sitesNow(); const list = jobs(); const rec = localRecords(root, st.sites, list, G.gh.repos);
    const body = buildTowers(st, rec, git.by, { blueprints: blueprints(root), isPrivateJob: privacyOf(list), repoPrivate: vis, alias });
    return { gitAt: git.at, githubAt: G.gh.at, githubError: G.gh.error, ...body };
  }
  function current() {
    const now = Date.now();
    if (memo.body && now - memo.checked < sigEveryMs) return memo;
    memo.checked = now; const sig = inputSig(); if (memo.body && sig === memo.sig) return memo;
    // the version is what is drawn: the towers, the errors and a GitHub failure; not gitAt or githubAt (a read that found nothing new
    // moves only the state's githubAt, never towersV)
    const body = compute(); Object.assign(memo, { sig, body, v: versionOf([body.towers, body.errors, body.githubError]) }); return memo;
  }
  async function refreshGit() {
    if (git.busy) return git.busy;
    git.busy = (async () => {
      const st = sitesNow(); const rec = localRecords(root, st.sites, jobs(), G.gh.repos); const next = new Map();
      for (const s of st.sites) next.set(s.key, await gitFacts(run, s, (rec.floors.get(s.key) || [])[0]?.at || null));
      const moved = JSON.stringify([...next]) !== JSON.stringify([...git.by]);
      git.by = next; git.at = new Date().toISOString(); if (moved) git.ver++;
    })().catch(() => {}).finally(() => { git.busy = null; memo.checked = 0; });
    return git.busy;
  }
  // GitHub after git (a repo's origin remote can name its GitHub home); the stone bases are counted again after GitHub's first floors
  const refreshGithub = () => G.refresh().finally(() => { memo.checked = 0; });
  const timer = setInterval(() => refreshGit(), gitEveryMs); timer.unref?.();
  setTimeout(() => refreshGit().then(refreshGithub).then(refreshGit), 0).unref?.();
  return {
    // GET /api/towers: { ok, at, gitAt, githubAt, githubError, v, towers, errors }; never throws (a failure is { ok: false, error })
    view() { try { const m = current(); return { ok: true, at: new Date().toISOString(), v: m.v, ...m.body, githubAt: G.gh.at }; } catch (e) { return { ok: false, error: 'the City could not be read: ' + String(e?.message || e).slice(0, 200) }; } },
    v() { try { return current().v; } catch { return null; } },
    // the state's githubAt: when GitHub was last read in full (the phone's "GitHub read N min ago" sign), null before any good read
    githubAt: () => G.gh.at,
    githubStats: () => G.gh.stats,
    // jobView.tower: the key of the Tower a work order builds on (a private one's neutral key, as /api/towers shows it), or null
    // (research, career and scouts belong to the Yard lot)
    towerOf(j) {
      const r = repoArgOf(j); if (!r) return null; const n = normPath(r); const { sites } = sitesNow(); const s = sites.find((x) => x.n === n && !x.office);
      return s ? shownAs(sites, (x) => isPrivateSite(x, git.by.get(x.key), vis)).get(s.key).key : null;
    },
    refreshGit, refreshGithub,
    stop() { clearInterval(timer); G.stop(); },
  };
}
