// The City's data (GET /api/towers): one row per project on this PC (a Tower, a Lot or the Office) with its floors (merged work), its
// cranes (open PRs) and its stone base. Called by server.mjs (the route, towersV in the state, jobView.tower) and pass-app/test-city.mjs.
// Read-only. Sources: the state-folder kitchen.json (bootRepos, city), each repo's kitchen.repo.json, merges.jsonl, results\J*.merge.json,
// J*.pr.json, J*.ci.json, automerged.jsonl, ledger.json, and git (counts, off the main thread through the server's run(), every 10 min).
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
    const h = city.history?.[key]; const hist = h && slugOf(h.github) && REF.test(String(h.ref || '')) ? { slug: slugOf(h.github), ref: String(h.ref) } : null;
    const shown = typeof names[key] === 'string' && names[key].trim() ? names[key].trim().slice(0, 40) : n === normPath(repoHome) ? 'Tide' : folder;
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
// a job file, live or archived (jobs\archive\<month>\J*.json)
function jobFileOf(root, id, months) {
  const live = readJson(path.join(root, 'jobs', id + '.json')); if (live) return live;
  for (const m of months) { const j = readJson(path.join(root, 'jobs', 'archive', m, id + '.json')); if (j) return j; }
  return null;
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

export function localRecords(root, sites, jobs = []) {
  const bySlug = new Map(); const byPath = new Map(sites.map((s) => [s.n, s.key]));
  for (const s of sites) { if (s.slug) bySlug.set(s.slug.toLowerCase(), { key: s.key, past: false }); if (s.history) bySlug.set(s.history.slug.toLowerCase(), { key: s.key, past: true }); }
  const floors = new Map(sites.map((s) => [s.key, new Map()])); const open = new Map(sites.map((s) => [s.key, []]));
  const add = (key, id, f) => { const m = floors.get(key); const was = m.get(id); m.set(id, was ? { ...f, ...was, job: was.job || f.job, by: was.job ? was.by : f.by, pour: was.pour || f.pour } : f); };
  // 1. merges.jsonl: every merge a session made with scripts/merge-pr.ps1 (ok only)
  for (const r of jsonLines(path.join(root, 'merges.jsonl'))) {
    const t = bySlug.get(String(r.repo || '').toLowerCase()); const at = isoOf(r.at);
    if (r.ok !== true || !t || !Number.isInteger(r.pr) || r.pr < 1 || !at) continue;
    add(t.key, `pr:${t.past ? 'old' : 'new'}#${r.pr}`, { pr: r.pr, ...(SHA.test(r.sha) ? { sha: r.sha } : {}), at, by: 'session', ...(pourOf(r.why) ? { pour: pourOf(r.why) } : {}), ...(t.past ? { past: true } : {}) });
  }
  // 2. results\J*.merge.json: every merge a work order made (on GitHub through its PR, or locally with no PR)
  const am = automergedOf(root); const ids = resultIds(root); const live = new Map(jobs.map((j) => [j.id, j]));
  let months = []; try { months = fs.readdirSync(path.join(root, 'jobs', 'archive')).filter((m) => /^\d{4}-\d{2}$/.test(m)).sort().reverse(); } catch {}
  for (const id of ids.merge) {
    const mr = readJson(path.join(root, 'results', id + '.merge.json')); const at = isoOf(mr?.at); if (!mr || !at) continue;
    const job = live.get(id) || jobFileOf(root, id, months); const pr = mr.via === 'github' ? prRecord(root, id) : null;
    const t = pr ? bySlug.get(pr.slug.toLowerCase()) : null; const key = t?.key || byPath.get(normPath(repoArgOf(job)));
    if (!key || !job || (pr && !t)) continue;   // a PR into a repo that is not on the City (no Site, no history) is not a floor here
    const f = { ...(pr ? { pr: pr.number } : {}), ...(SHA.test(mr.after) ? { sha: mr.after } : {}), at, by: am.auto.has(id) ? 'auto' : 'yard', job: id, ...(t?.past ? { past: true } : {}) };
    if (am.undone.has(id)) f.undone = am.undone.get(id) || at;
    add(key, pr ? `pr:${t.past ? 'old' : 'new'}#${pr.number}` : `sha:${f.sha || id}`, f);
  }
  // 3. cranes from the Yard's own records: an active order with a PR and no merge yet (GitHub's open list replaces these when read)
  const merged = new Set(ids.merge);
  for (const id of ids.pr) {
    const j = live.get(id); if (!j || !ACTIVE.has(j.status) || merged.has(id)) continue;
    const pr = prRecord(root, id); const t = pr && bySlug.get(pr.slug.toLowerCase()); if (!t || t.past) continue;
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

// ---- the view ----
function blueprints(root) {
  const out = new Map();
  const programs = readJson(path.join(root, 'ledger.json'))?.programs;
  for (const p of Array.isArray(programs) ? programs : []) {
    if (p && typeof p.repo === 'string' && Number.isInteger(p.total) && p.total > 0 && Number.isInteger(p.shipped) && p.shipped >= 0) out.set(p.repo.toLowerCase(), { total: p.total, shipped: Math.min(p.shipped, p.total) });
  }
  return out;
}
// a floor or crane of a private work order carries no title (the CREED privacy rule; titles come from GitHub, slice G2)
const scrub = (x, priv) => (x.title && x.job && priv.has(x.job) ? (({ title, ...rest }) => rest)(x) : x);
export function buildTowers({ sites, errors = [] }, rec, gitBy = new Map(), extra = {}) {
  const bp = extra.blueprints || new Map(); const priv = extra.privateJobs || new Set(); const rows = [];
  for (const s of sites) {
    const g = gitBy.get(s.key) || {}; const floors = (rec.floors.get(s.key) || []).map((f) => scrub(f, priv)); const open = (rec.open.get(s.key) || []).map((o) => scrub(o, priv));
    const kind = s.office ? 'office' : floors.length || open.length ? 'tower' : 'lot';
    const t = { key: s.key, name: s.name, kind, repo: s.slug || g.remoteSlug || null, floors: kind === 'office' ? [] : floors, open: kind === 'office' ? [] : open };
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
export function makeTowers({ root, repoHome, run, jobs = () => [], isPrivate = () => false, home = os.homedir(), gitEveryMs = Number(process.env.PASS_TOWERS_GIT_MS) || 600000, sigEveryMs = 3000 }) {
  const git = { by: new Map(), at: null, busy: null, ver: 0 }; const memo = { sig: '', checked: 0, body: null, v: '' };
  // the Sites are read again when the state kitchen.json changes, and at most every 30 s otherwise (a repo's kitchen.repo.json, a new folder)
  const sm = { sig: '', at: 0, val: null };
  const sitesNow = () => { const sig = sigOf(path.join(root, 'kitchen.json')); if (sm.val && sm.sig === sig && Date.now() - sm.at < 30000) return sm.val; Object.assign(sm, { sig, at: Date.now(), val: sitesOf(root, repoHome, home) }); return sm.val; };
  const inputSig = () => {
    const files = ['kitchen.json', 'merges.jsonl', 'automerged.jsonl', 'ledger.json', 'results'].map((f) => sigOf(path.join(root, f)));
    const r = resultIds(root); const live = new Map(jobs().map((j) => [j.id, j]));
    const recs = [...r.merge.map((id) => id + '.merge.json'), ...r.pr.flatMap((id) => [id + '.pr.json', id + '.ci.json'])].map((f) => f + sigOf(path.join(root, 'results', f)));
    const states = r.pr.map((id) => `${id}:${live.get(id)?.status || '-'}:${live.has(id) && isPrivate(live.get(id)) ? 1 : 0}`);
    return [...files, ...recs, ...states, git.ver].join('|');
  };
  function compute() {
    const st = sitesNow(); const list = jobs(); const rec = localRecords(root, st.sites, list);
    const privateJobs = new Set(list.filter((j) => isPrivate(j)).map((j) => j.id));
    const body = buildTowers(st, rec, git.by, { blueprints: blueprints(root), privateJobs });
    return { gitAt: git.at, ...body };
  }
  function current() {
    const now = Date.now();
    if (memo.body && now - memo.checked < sigEveryMs) return memo;
    memo.checked = now; const sig = inputSig(); if (memo.body && sig === memo.sig) return memo;
    const body = compute(); Object.assign(memo, { sig, body, v: versionOf(body) }); return memo;
  }
  async function refreshGit() {
    if (git.busy) return git.busy;
    git.busy = (async () => {
      const st = sitesNow(); const rec = localRecords(root, st.sites, jobs()); const next = new Map();
      for (const s of st.sites) next.set(s.key, await gitFacts(run, s, (rec.floors.get(s.key) || [])[0]?.at || null));
      const moved = JSON.stringify([...next]) !== JSON.stringify([...git.by]);
      git.by = next; git.at = new Date().toISOString(); if (moved) git.ver++;
    })().catch(() => {}).finally(() => { git.busy = null; memo.checked = 0; });
    return git.busy;
  }
  const timer = setInterval(() => refreshGit(), gitEveryMs); timer.unref?.();
  setTimeout(() => refreshGit(), 0).unref?.();
  return {
    // GET /api/towers: { ok, at, gitAt, v, towers, errors }; never throws (a failure is { ok: false, error })
    view() { try { const m = current(); return { ok: true, at: new Date().toISOString(), v: m.v, ...m.body }; } catch (e) { return { ok: false, error: 'the City could not be read: ' + String(e?.message || e).slice(0, 200) }; } },
    v() { try { return current().v; } catch { return null; } },
    // jobView.tower: the key of the Tower a work order builds on, or null (research, career and scouts belong to the Yard lot)
    towerOf(j) { const r = repoArgOf(j); if (!r) return null; const n = normPath(r); return sitesNow().sites.find((s) => s.n === n && !s.office)?.key || null; },
    refreshGit,
    stop() { clearInterval(timer); },
  };
}
