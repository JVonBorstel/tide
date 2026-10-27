// @ts-check
// The old Ledger's own items, rebuilt from the events: ideas, roadmap items and the lobe's decisions, with the rules of
// kitchen/ledger.ps1 (states shipped, waiting-on-jordan, moving, stuck, lost, claimed, not-started, dropped; owners Jordan, kitchen,
// Claude; flags with a plain sentence). Ideas and roadmap items are not work orders, so they make no rows; they exist here so the
// ledger.json export can replace the old file item for item while the Board still reads it (WO-UPG-L1-2).
import path from 'node:path';
import { woOfJob, jobOfWo } from './ids.mjs';
import { proofFor } from './view.mjs';

const ALIVE = ['pending', 'running'], WAIT = ['waiting-approval', 'needs-human'], ASIDE = ['quarantined', 'failed'];
const CLAIMED = /done another way|integrated|merged by the lead|replaced by|already (does|reads|has)/i;
const ownerOf = (/** @type {string} */ s) => ({ 'waiting-on-jordan': 'Jordan', moving: 'kitchen', stuck: 'Claude', lost: 'Claude', claimed: 'Claude', 'not-started': 'kitchen' })[s] || '';
const ORDER = ['waiting-on-jordan', 'lost', 'claimed', 'stuck', 'moving', 'not-started', 'shipped', 'dropped', 'replaced'];

/** @param {{ at: string, internal: { fold: { wos: Map<string, any>, snap: any } } }} v */
export function legacyLedger(v) {
  const { wos, snap } = v.internal.fold; const now = Date.parse(v.at);
  const days = (/** @type {string|null|undefined} */ t) => { const x = Date.parse(t || ''); return Number.isNaN(x) ? null : Math.round((now - x) / 8640000) / 10; };
  const W = (/** @type {string} */ j) => wos.get(String(woOfJob(j) || ''));
  // an order's repo: its vars.repo checkout, else the first repo read (the Yard's own checkout, as Repo-Of in kitchen/ledger.ps1)
  const norm = (/** @type {string} */ p) => path.resolve(p).replace(/[\\/]+$/, '').toLowerCase();
  const byDir = new Map([...snap.repos.values()].filter((r) => r.dir).map((r) => [norm(r.dir), r]));
  const repoOf = (/** @type {any} */ y) => (y?.repoPath ? byDir.get(norm(String(y.repoPath))) : [...snap.repos.values()][0]);
  const replacedBy = (/** @type {any} */ w) => (w?.replacedBy ? jobOfWo(w.replacedBy) || w.replacedBy : '');
  /** kitchen/ledger.ps1 Order-Fact @param {string} j */
  function fact(j) {
    const w = W(j); if (!w?.yard) return { id: j, status: 'missing', proof: '', note: 'no job file', replacedBy: '' };
    const y = w.yard; let proof = proofFor(w, snap).proof || '';
    if (y.status === 'done' && !y.code && !proof) proof = `order finished (${y.recipe})`;
    return { id: j, status: y.status, recipe: y.recipe, created: w.createdAt, proof, note: y.closed?.reason || (y.status === 'done' && y.code && !proof ? 'done, but no commit on main names it' : ''), replacedBy: replacedBy(w), approval: '' };
  }
  /** follow replacements to the end, the starting orders oldest first (cycle-safe) @param {string[]} start */
  function chain(start) {
    const seen = /** @type {string[]} */ ([]);
    const first = [...new Set(start.filter(Boolean))].sort((a, b) => String(W(a)?.createdAt || '9').localeCompare(String(W(b)?.createdAt || '9')));
    for (const s of first) { let x = s; while (x && !seen.includes(x)) { seen.push(x); x = replacedBy(W(x)); } }
    return seen.map(fact);
  }
  const closed = (/** @type {string} */ j) => W(j)?.yard?.closed || null;
  const claimed = (/** @type {string} */ j) => { const c = closed(j); return !!c && !c.replacedBy && !c.proof && !c.dropped && CLAIMED.test(c.reason || ''); };
  /** kitchen/ledger.ps1 State-Of @param {any[]} ch */
  function stateOf(ch) {
    if (!ch.length) return 'not-started';
    if (ch.some((c) => c.proof)) return 'shipped';
    const last = ch[ch.length - 1];
    if (WAIT.includes(last.status)) return 'waiting-on-jordan';
    if (ALIVE.includes(last.status)) return 'moving';
    if (ASIDE.includes(last.status)) return 'stuck';
    if (claimed(last.id)) return 'claimed';
    if (closed(last.id)?.dropped) return 'dropped';
    return 'lost';
  }
  const items = /** @type {any[]} */ ([]); const inChain = new Set();
  // ---- ideas: the idea's own order, every order whose goal says "(Idea I12:", then their replacements
  const byIdea = new Map();
  // the goal's "(Idea I12:" text, or an archived order's own idea field (its summary line has no goal)
  for (const w of wos.values()) { const idea = /\(Idea (I\d+):/.exec(String(w.goal || ''))?.[1] || w.yard?.idea; if (idea && w.alias) { if (!byIdea.has(idea)) byIdea.set(idea, []); byIdea.get(idea).push(w.alias); } }
  const links = snap.links || {}; const drops = snap.drops || {};
  for (const i of snap.ideas?.items || []) {
    const ch = chain([i.job, ...(byIdea.get(i.id) || [])]); for (const c of ch) inChain.add(c.id);
    let state = stateOf(ch); let proof = ch.filter((c) => c.proof).map((c) => `${c.id}: ${c.proof}`).join('; '); let why = '';
    const last = ch[ch.length - 1];
    if (links[i.id]) { state = 'shipped'; proof = `linked: ${links[i.id].proof} (${links[i.id].why})`; }
    else if (state !== 'shipped' && i.status === 'dropped') {
      if (drops[i.id]) { state = 'dropped'; why = 'you dropped it in Chef'; }
      else if (!ch.length) { state = 'lost'; why = 'marked dropped, but not by you, and never built'; }
    }
    if (state === 'lost' && !why) why = `its last order ${last.id} was ${last.status}${last.note ? ` (${last.note})` : ''} and nothing replaced it`;
    if (state === 'claimed') why = `order ${last.id} was closed as done another way (${last.note}), with no proof linked`;
    if (state === 'dropped' && !why && ch.length) { const c = closed(last.id); why = /jordan/i.test(String(c?.by || '')) ? 'you dropped it in Chef' : `dropped by ${c?.by || 'the kitchen'}, not by you: ${c?.reason || ''}`; }
    if (state === 'stuck') why = `order ${last.id} is set aside`;
    if (state === 'waiting-on-jordan') why = `order ${last.id} waits for your yes`;
    const since = ch.length ? closed(last.id)?.at || last.created : i.at;
    items.push({ id: i.id, kind: 'idea', title: i.title, from: i.source, jordans: /^Jordan/.test(i.source), score: i.score, size: i.size, state, owner: ownerOf(state), why, proof, listed: i.status, since: since || '', ageDays: days(since), chain: ch });
  }
  // ---- orders that belong to no idea and are not finished (sub-orders show under their parent)
  for (const w of wos.values()) {
    const y = w.yard; if (!y || !w.alias || inChain.has(w.alias) || y.parent || ![...ALIVE, ...WAIT, ...ASIDE].includes(y.status)) continue;
    const ch = chain([w.alias]); const state = stateOf(ch); if (state === 'shipped') continue;
    items.push({ id: w.alias, wo: w.id, kind: 'order', title: String(y.name || w.goal || '').replace(/^improve:\s*/, ''), from: y.recipe, jordans: false, score: 0, size: '', state, owner: ownerOf(state),
      why: state === 'waiting-on-jordan' ? 'waits for your yes' : state === 'stuck' ? 'set aside' : '', proof: '', listed: y.status, since: w.createdAt, ageDays: days(w.createdAt), chain: ch });
    for (const c of ch) inChain.add(c.id);
  }
  // ---- roadmaps (repos that opt in): proof is the change note on main, a commit naming the item, or a manual link
  const programs = [];
  for (const rm of snap.roadmaps.values()) {
    if (!rm.ok) continue;
    const repo = snap.repos.get(rm.repo); const changes = new Set(repo?.changes || []); const ids = repo?.ids || {};
    const jobsOf = (/** @type {string} */ id) => [...wos.values()].filter((w) => w.yard?.recipe === 'roadmap-item' && String(w.yard.item || '').toUpperCase() === id.toUpperCase() && path.basename(String(w.yard.repoPath || '')).toLowerCase() === rm.repo.toLowerCase()).sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
    let done = 0;
    for (const it of rm.items) {
      const js = jobsOf(it.id); const alive = js.filter((w) => [...ALIVE, ...WAIT].includes(w.yard.status)); const aside = js.filter((w) => ASIDE.includes(w.yard.status));
      const blockers = it.depends_on.filter((/** @type {string} */ d) => !changes.has(d));
      const rmState = changes.has(it.id) ? 'merged' : alive.length ? 'cooking' : aside.length ? 'set-aside' : it.owner_only ? 'owner-only' : blockers.length ? 'blocked' : 'ready';
      const job = alive.length ? alive[alive.length - 1].alias : aside.length && rmState === 'set-aside' ? aside[aside.length - 1].alias : '';
      let proof = changes.has(it.id) ? `docs/changes/${it.id}.md on ${repo?.main}` : ids[it.id] ? `commit ${ids[it.id]} on ${repo?.main}` : rmState === 'merged' ? 'roadmap: merged' : '';
      if (links[it.id]) proof = `linked: ${links[it.id].proof}`;
      let state = proof ? 'shipped' : ({ cooking: 'moving', 'set-aside': 'stuck' })[rmState] || 'not-started';
      if (state === 'moving' && job && WAIT.includes(W(job)?.yard?.status)) state = 'waiting-on-jordan';
      if (state === 'shipped') { done++; continue; }
      const why = ({ blocked: `waits for ${blockers.join(', ')}`, 'owner-only': 'an owner step (protected files)', cooking: `order ${job}`, 'set-aside': `order ${job} is set aside` })[rmState] || 'ready to build';
      items.push({ id: it.id, kind: 'roadmap', title: it.title, from: rm.repo, jordans: false, score: 0, size: it.size, state, owner: ownerOf(state), why, proof: '', listed: rmState, since: '', ageDays: null, wave: it.wave, chain: job ? [fact(job)] : [] });
    }
    programs.push({ repo: rm.repo, total: rm.items.length, shipped: done, stuck: items.filter((x) => x.kind === 'roadmap' && x.from === rm.repo && x.state === 'stuck').length });
  }
  // ---- drift between systems: the idea list or a finished order says one thing, the proof another
  const drift = /** @type {any[]} */ ([]);
  for (const it of items) {
    if (it.kind !== 'idea') continue;
    if (it.listed === 'failed' && it.state === 'shipped') drift.push({ id: it.id, what: `the idea list says failed, but it shipped (${it.proof})` });
    if (it.listed === 'merged' && it.state !== 'shipped') drift.push({ id: it.id, what: `the idea list says merged, but no proof was found (${it.why})` });
  }
  for (const w of wos.values()) {
    const y = w.yard; if (!y || y.status !== 'done' || !y.code || y.parent || !w.alias) continue;
    const repo = repoOf(y);
    if (repo?.ok && !repo.ids?.[w.alias]) drift.push({ id: w.alias, what: `order finished, but no commit on main in ${path.basename(repo.dir || repo.repo)} names it` });
  }
  // ---- flags, as kitchen/ledger.ps1 words them
  const flags = /** @type {any[]} */ ([]);
  for (const it of items) {
    const a = it.ageDays;
    if (it.state === 'lost') flags.push({ id: it.id, rule: 'lost', owner: 'Claude', pri: it.jordans ? 1 : 3, say: `${it.title}: lost. ${it.why}.` });
    else if (it.state === 'dropped' && /not by you/.test(it.why)) flags.push({ id: it.id, rule: 'dropped-not-by-you', owner: 'Jordan', pri: 2, say: `${it.title}: ${it.why}. Keep it dropped or build it again?` });
    else if (it.state === 'claimed') flags.push({ id: it.id, rule: 'claimed-no-proof', owner: 'Claude', pri: 2, say: `${it.title}: said to be done another way, but no proof is linked. Link the commit or re-open it.` });
    else if (it.state === 'waiting-on-jordan' && a !== null && a >= 0.5) flags.push({ id: it.id, rule: 'waiting-on-you', owner: 'Jordan', pri: 1, say: `${it.title}: waiting on you for ${a} days.` });
    else if (it.state === 'stuck' && a !== null && a >= 1) flags.push({ id: it.id, rule: 'stuck', owner: 'Claude', pri: 2, say: `${it.title}: set aside for ${Math.round(a)} days, nobody on it.` });
    else if (it.kind === 'idea' && it.jordans && it.state === 'not-started' && a !== null && a >= 3) flags.push({ id: it.id, rule: 'your-idea-waiting', owner: 'kitchen', pri: 1, say: `Your idea '${it.title}' has waited ${Math.round(a)} days.` });
    else if (it.kind === 'idea' && it.state === 'not-started' && it.score >= 90 && a !== null && a >= 7) flags.push({ id: it.id, rule: 'valuable-waiting', owner: 'kitchen', pri: 3, say: `'${it.title}' (score ${it.score}) has waited ${Math.round(a)} days.` });
  }
  for (const d of drift) flags.push({ id: d.id, rule: 'drift', owner: 'Claude', pri: 2, say: `${d.id}: ${d.what}.` });
  // ---- the lobe's decisions: one flag each (owner Jordan); a post-mortem carries the Ledger's proof for its Sign-off row
  const lobe = snap.lobe; const lobeOut = { ok: !!lobe?.ok, why: lobe?.why || 'the lobe was not imported', updated: lobe?.updated ?? null, decisionsReady: lobe?.ok ? lobe.decisionReady.length : null, postMortemsDue: lobe?.ok ? lobe.postMortemDue.length : null };
  if (lobe?.ok) {
    for (const d of lobe.decisionReady) flags.push({ id: d.id, rule: 'decision-ready', owner: 'Jordan', pri: 2, readyAt: d.readyAt || '', say: `Decision ${d.id} is ready for you: A, B, neither or ask more, on the World tab.` });
    for (const d of lobe.postMortemDue) {
      const pf = decisionProof(d.id); const by = d.expiresAt ? ` by ${d.expiresAt.slice(0, 10)}` : '';
      flags.push({ id: d.id, rule: 'post-mortem-due', owner: 'Jordan', pri: 2, day: d.day, dueAt: d.dueAt || '', expiresAt: d.expiresAt || '', proofKind: pf.kind, proof: pf.say, order: pf.order,
        say: `Post-mortem due: ${d.id}, the day-${d.day} check. Held up, didn't, or unknown? On the World tab${by}. Ledger: ${pf.say}.` });
    }
  } else if (lobe && !lobe.missing) flags.push({ id: 'flags.json', rule: 'lobe-flags-unreadable', owner: 'Claude', pri: 2, say: `The lobe's ${lobe.why}; decisions and post-mortems are unknown.` });
  /** kitchen/ledger.ps1 Decision-Proof @param {string} did */
  function decisionProof(did) {
    const m = /^S-(J\d{1,5})-/.exec(did); if (!m) return { kind: 'none', order: '', say: 'a lobe decision, not a work order: the Ledger has no proof for it' };
    const jid = m[1]; const w = W(jid);
    if (w?.yard?.undoneAt) return { kind: 'undone', order: jid, say: `undone: the merge of ${jid} was reversed${/^\d{4}-/.test(w.yard.undoneAt) ? ` on ${w.yard.undoneAt.slice(0, 10)}` : ''}` };
    if (w?.replacedBy) return { kind: 'replaced', order: jid, say: `replaced by ${replacedBy(w)}` };
    if (!w?.yard) return { kind: 'unknown', order: jid, say: `unknown: no work order file for ${jid}` };
    for (const r of snap.repos.values()) {
      if (!r?.ok || !r.ids?.[jid]) continue;
      if (r.reverted?.includes(jid)) return { kind: 'undone', order: jid, say: `undone: commit ${r.ids[jid]} on ${r.main} reverts it` };
      return { kind: 'on-main', order: jid, say: `still on main: commit ${r.ids[jid]} on ${r.main}` };
    }
    return { kind: 'unknown', order: jid, say: `unknown: no commit on main names ${jid}` };
  }
  items.sort((a, b) => ORDER.indexOf(a.state) - ORDER.indexOf(b.state) || Number(b.jordans) - Number(a.jordans) || b.score - a.score || String(a.id).localeCompare(String(b.id)));
  return { items, programs, flags, drift, lobe: lobeOut, inChain };
}
