// @ts-check
// The ledger view: a pure fold over the events (build-way 3.1, contract row.schema.json). Same events in, same rows out; nothing here
// reads a file or the clock except through its arguments. Also: Jordan's decision queue (oldest first), the streams with their WIP,
// the attention flags, the feature flag values (a projection of flag.set events over L4's flags.json defaults), and the ledger.json
// export in the shape pass-app/server.mjs reads today.
import { jobOfWo, text } from './ids.mjs';
import { CONTRACT_V } from './store.mjs';
import { legacyLedger } from './legacy.mjs';

export const STAGES = ['build', 'review', 'ci', 'merge-ready', 'jordan', 'merged', 'docs', 'closed'];
const rank = (/** @type {string} */ s) => STAGES.indexOf(s);
const FINISHED = new Set(['shipped', 'dropped', 'replaced']);
const OPEN = new Set(['moving', 'waiting-on-jordan', 'stuck', 'stale']);
/** Streams that are not build streams for the WIP limit: the old Yard's own orders, dependency bumps, and PRs no rule places (OTHER). */
export const NOT_BUILD_STREAMS = new Set(['YARD', 'DEPENDENCIES', 'OTHER']);
export const WIP = { streams: 4, cardsPerStream: 3, stackDepth: 2, stackDepthFlagged: 0 };
/** Streams where stacks are not allowed at all (flags, not stacks: build-way 3.3). */
export const NO_STACK_STREAMS = new Set(['ART', 'CITY', 'BOARD']);
const PLAN_RE = /^plans\/[A-Za-z0-9._/-]+\.md(#[A-Za-z0-9._-]+)?$/;
const REL_RE = /^(?![A-Za-z]:)(?![\\/~])(?![a-z][a-z0-9+.-]*:)(?!.*\.\.)[^\s<>|"*?]+$/;
const hours = (/** @type {number} */ ms) => Math.max(0, Math.round(ms / 360000) / 10);

/** @typedef {import('./store.mjs').Event} Event */

/**
 * Fold every event into per-work-order state plus the latest snapshots.
 * @param {Event[]} events in seq order
 */
export function fold(events) {
  /** @type {Map<string, any>} */ const wos = new Map();
  /** @type {Map<string, any>} */ const decisions = new Map();
  /** @type {Map<string, any>} */ const flagSets = new Map();
  const snap = { repos: /** @type {Map<string, any>} */ (new Map()), plans: /** @type {any} */ (null), briefs: /** @type {any} */ (null), site: /** @type {any} */ (null),
    ideas: /** @type {any} */ (null), links: /** @type {any} */ (null), drops: /** @type {any} */ (null), roadmaps: /** @type {Map<string, any>} */ (new Map()), lobe: /** @type {any} */ (null) };
  const get = (/** @type {string} */ id, /** @type {string} */ at) => {
    let w = wos.get(id);
    if (!w) { w = { id, alias: jobOfWo(id), goal: null, stream: null, repo: null, createdAt: at, plan: null, stage: 'build', stageAt: at, attempts: 0, pr: null, branch: null, base: null, head: null, mergeable: null, prAt: at, ci: null, review: null, decisions: [], merged: null, closedProof: null, dod: {}, dropped: null, replacedBy: null, yard: null, failed: null, prClosed: false, lastSeq: 1 }; wos.set(id, w); }
    return w;
  };
  const setStage = (/** @type {any} */ w, /** @type {string} */ s, /** @type {string} */ at) => { if (w.stage !== s) { w.stage = s; w.stageAt = at; } };
  for (const e of events) {
    const d = /** @type {any} */ (e.data);
    if (e.kind === 'x.local.repo') { snap.repos.set(d.repo, d); continue; }
    if (e.kind === 'x.local.plans') { snap.plans = d; continue; }
    if (e.kind === 'x.local.briefs') { snap.briefs = d; continue; }
    if (e.kind === 'x.yard.site') { snap.site = d; continue; }
    if (e.kind === 'x.yard.ideas') { snap.ideas = d; continue; }
    if (e.kind === 'x.yard.links') { snap.links = d.links; continue; }
    if (e.kind === 'x.yard.drops') { snap.drops = d.drops; continue; }
    if (e.kind === 'x.local.roadmap') { snap.roadmaps.set(d.repo, d); continue; }
    if (e.kind === 'x.lobe.flags') { snap.lobe = d; continue; }
    if (e.kind === 'flag.set') { flagSets.set(d.flag, { on: d.on, decision: d.decision, at: e.at, seq: e.seq }); continue; }
    if (!e.wo) continue;
    const w = get(e.wo, e.at); w.lastSeq = Math.max(w.lastSeq, Number(e.seq) || 1);
    switch (e.kind) {
      case 'wo.created':
        if (w.goal === null) { w.goal = d.goal; w.stream = d.stream; w.createdAt = e.at; w.stageAt = w.stageAt < e.at ? w.stageAt : e.at; }
        if (d.plan && !w.plan) w.plan = d.plan; if (d.repo && !w.repo) w.repo = d.repo; if (d.alias) w.alias = d.alias; if (d.private) w.private = true; break;
      case 'stage.entered': setStage(w, d.stage, e.at); if (rank(d.stage) >= rank('merged')) { if (e.proof) w.closedProof = e.proof; } else w.closedProof = null; break;
      case 'step.started': case 'step.done': w.attempts = Math.max(w.attempts, d.attempt); if (e.kind === 'step.done') w.failed = null; break;
      case 'step.failed': w.attempts = Math.max(w.attempts, d.attempt); w.failed = d.retry ? null : { reason: d.reason, step: d.step, at: e.at }; break;
      case 'pr.opened':
        if (!w.pr || w.pr === d.pr) { w.pr = d.pr; w.branch = d.branch; w.base = d.base; w.head = d.head; w.prAt = e.at; }
        if (rank(w.stage) < rank('review')) setStage(w, 'review', e.at); break;
      case 'pr.updated':
        if (w.pr && w.pr !== d.pr) break;
        if (d.why === 'closed') { w.prClosed = true; break; }
        if (d.why === 'reopened') w.prClosed = false;
        if (w.head !== d.head) w.prAt = e.at;
        w.head = d.head; if (d.mergeable) w.mergeable = d.mergeable; break;
      case 'ci.result':
        if (w.head && d.head !== w.head) break;
        w.ci = d.conclusion;
        if (rank(w.stage) < rank('jordan')) setStage(w, d.conclusion === 'success' ? 'merge-ready' : 'ci', e.at); break;
      case 'review.verdict': w.review = { verdict: d.verdict, head: d.head }; break;
      case 'decision.asked': { const dec = { ...d.decision, wo: d.decision.wo ?? e.wo }; decisions.set(dec.id, dec); if (!w.decisions.includes(dec.id)) w.decisions.push(dec.id); break; }
      case 'decision.answered': { const dec = decisions.get(d.decision); if (dec && dec.answer == null) Object.assign(dec, { answer: d.answer, note: d.note ?? null, answeredAt: e.at, via: d.via }); break; }
      case 'merged': w.merged = { pr: d.pr, sha: d.sha, at: e.at }; if (rank(w.stage) < rank('merged')) setStage(w, 'merged', e.at); break;
      case 'docs.done': w.dod = d.dod; if (rank(w.stage) < rank('docs')) setStage(w, 'docs', e.at); break;
      case 'closed': w.closedProof = e.proof; setStage(w, 'closed', e.at); break;
      case 'dropped': w.dropped = { reason: d.reason, decision: d.decision }; break;
      case 'replaced': if (d.by !== w.id) w.replacedBy = d.by; break;
      case 'x.yard.status': w.yard = d; if (d.replacedBy && !w.replacedBy) { /* the replaced event carries it */ } break;
      default: break;
    }
  }
  // decisions answered for an order that never asked (a decision.answered with no decision.asked) stay unknown; they are not invented
  for (const dec of decisions.values()) if (dec.wo && !wos.has(dec.wo)) get(dec.wo, dec.at);
  return { wos, decisions, flagSets, snap };
}

/** @param {any} d @returns {any} a decision object as the contract shapes it */
function decisionOut(d) {
  const o = { v: CONTRACT_V, id: d.id, wo: d.wo ?? null, kind: d.kind, ask: d.ask, options: d.options, recommended: d.recommended, ...(d.why !== undefined ? { why: d.why } : {}),
    ...(d.variants ? { variants: d.variants } : {}), answer: d.answer ?? null, note: d.note ?? null, at: d.at, answeredAt: d.answeredAt ?? null, via: d.via ?? null, ...(d.standing !== undefined ? { standing: d.standing } : {}) };
  return o;
}

/** The plan of a row: its own, else the brief's, else exactly one plan naming its WO, else exactly one naming its slice token. @returns {{ plan: string | null, why: string | null }} */
function planOf(/** @type {any} */ w, /** @type {any} */ brief, /** @type {any} */ plans) {
  if (w.plan && PLAN_RE.test(w.plan)) return { plan: w.plan, why: null };
  if (brief?.plan && PLAN_RE.test(String(brief.plan))) return { plan: String(brief.plan), why: null };
  const list = Array.isArray(plans?.plans) ? plans.plans : [];
  const byWo = list.filter((/** @type {any} */ p) => p.wo.includes(w.id));
  if (byWo.length === 1 && PLAN_RE.test(byWo[0].file)) return { plan: byWo[0].file, why: null };
  if (byWo.length > 1) return { plan: null, why: `${byWo.length} plans name ${w.id} (${byWo.map((/** @type {any} */ p) => p.file).join(', ')})` };
  const tok = /(?<![\w-])(S\d+[a-z]|G\d+|TD-\d+)(?![\w-])/.exec(String(w.goal || ''))?.[1];
  if (!tok) return { plan: null, why: null };
  const byTok = list.filter((/** @type {any} */ p) => p.tokens.includes(tok));
  if (byTok.length === 1 && PLAN_RE.test(byTok[0].file)) return { plan: byTok[0].file, why: null };
  return { plan: null, why: byTok.length ? `${byTok.length} plans name ${tok}` : null };
}

/** The proof a work order shipped: a merge sha, a close with proof, or (a finished Yard code order) a commit on main naming it. @param {any} w @param {any} snap */
export function proofFor(w, snap) {
  const mp = w.yard?.status === 'done' && w.yard.code ? mainProof(w, snap.repos) : { proof: null, undone: null };
  return { proof: w.merged ? `merge commit ${w.merged.sha} (${w.merged.pr})` : w.closedProof || mp.proof || null, undone: mp.undone };
}

/** Proof on main for a Yard order: the newest commit on main that names its alias (not a revert). */
export function mainProof(/** @type {any} */ w, /** @type {Map<string, any>} */ repos) {
  if (!w.alias) return { proof: null, undone: null };
  // the order's own repo when it names one (vars.repo) and that checkout was read; else every repo read
  const norm = (/** @type {string} */ p) => String(p).replace(/[\\/]+$/, '').replace(/\\/g, '/').toLowerCase();
  const own = w.yard?.repoPath ? [...repos.values()].filter((r) => r?.dir && norm(r.dir) === norm(w.yard.repoPath)) : [];
  for (const r of own.length ? own : repos.values()) {
    if (!r?.ok || !r.ids?.[w.alias]) continue;
    if (r.reverted?.includes(w.alias)) return { proof: null, undone: `commit ${r.ids[w.alias]} on ${r.main} in ${r.repo} reverts it` };
    return { proof: `commit ${r.ids[w.alias]} on ${r.main} in ${r.repo}`, undone: null };
  }
  return { proof: null, undone: null };
}

/**
 * The whole view.
 * @param {Event[]} events
 * @param {{ now: Date, staleH?: number, flagDefaults?: any, recentH?: number }} o
 */
export function buildView(events, o) {
  const now = o.now.getTime(); const staleH = o.staleH ?? 24;
  const { wos, decisions, flagSets, snap } = fold(events);
  const briefs = new Map((snap.briefs?.items || []).filter((/** @type {any} */ b) => b.wo).map((/** @type {any} */ b) => [b.wo, b]));
  const paused = snap.site?.paused === true;
  /** @type {any[]} */ const rows = []; /** @type {any[]} */ const flags = [];
  const openDec = (/** @type {any} */ w) => w.decisions.map((/** @type {string} */ id) => decisions.get(id)).filter((/** @type {any} */ d) => d && d.answer == null);
  for (const w of wos.values()) {
    const y = w.yard; const ys = y?.status;
    if (y?.parent && !['waiting-approval', 'needs-human', 'quarantined', 'failed'].includes(ys)) continue;   // sub-orders show under their parent, as in kitchen/ledger.ps1
    let stage = w.stage, stageAt = w.stageAt, state = 'moving', owner = 'crew', blockedOn = /** @type {string|null} */ (null), next = /** @type {string|null} */ (null);
    const pf = proofFor(w, snap); const proof = pf.proof; const mp = { undone: pf.undone };
    const open = openDec(w); const answered = w.decisions.map((/** @type {string} */ id) => decisions.get(id)).filter((/** @type {any} */ d) => d && d.answer != null);
    if (w.replacedBy) { state = 'replaced'; owner = 'nobody'; next = `continues as ${w.replacedBy}`; }
    else if (w.dropped) { state = 'dropped'; owner = 'nobody'; blockedOn = null; next = null; }
    else if (proof) {
      state = 'shipped'; owner = 'nobody';
      if (rank(stage) < rank('merged')) { stage = 'merged'; stageAt = w.merged?.at || stageAt; }
      next = stage === 'merged' ? 'docs station: change note, glossary, names, MAP after the merge' : stage === 'docs' ? 'close the work order' : null;
    } else if (open.length) {
      const d = open.sort((/** @type {any} */ a, /** @type {any} */ b) => String(a.at).localeCompare(String(b.at)))[0];
      state = 'waiting-on-jordan'; owner = 'jordan'; blockedOn = `Jordan: ${d.kind} card ${d.id}`; next = `your tap on ${d.id}`;
      if (rank(stage) < rank('jordan')) { stage = 'jordan'; stageAt = d.at; }
    } else if (ys === 'waiting-approval' || ys === 'needs-human') {
      state = 'waiting-on-jordan'; owner = 'jordan'; blockedOn = ys === 'needs-human' ? 'Jordan: the Yard order needs a person' : 'Jordan: the Yard order waits for your yes';
      next = 'your tap on the Board (Chef sign-off)';
    } else if (w.yard ? ys === 'quarantined' || ys === 'failed' : w.failed) {   // a Yard order's own status decides; its failed step gives the reason
      state = 'stuck'; blockedOn = `set aside: ${text(w.failed?.reason || 'the Yard set it aside', 300)}`; next = 'retry with a fresh crew, re-plan, or drop (a card)';
    } else if (ys === 'closed' || ys === 'killed' || (ys === 'done' && !proof)) {
      const c = y.closed;
      if (c?.dropped) {   // as kitchen/ledger.ps1: dropped; a drop not made by Jordan is a question for him (a no-decision flag below)
        state = 'dropped'; owner = 'nobody';
        if (!/jordan/i.test(String(c.by || ''))) w.dropNotByJordan = `dropped by ${c.by || 'the Yard'}, not by Jordan: ${text(c.reason, 200)}. Keep it dropped or build it again?`;
      }
      else {
        state = 'lost'; owner = 'nobody';
        blockedOn = ys === 'done' ? (mp.undone ? `undone: ${mp.undone}` : 'done, but no commit on main names it')
          : c?.reason && /done another way|integrated|merged by the lead|replaced by|already (does|reads|has)/i.test(c.reason) ? `closed as done another way, with no proof: ${text(c.reason, 200)}`
          : `${ys} and nothing replaced it${c?.reason ? `: ${text(c.reason, 200)}` : ''}`;
        next = 'link proof, re-open, or drop (a card)';
      }
    } else if (w.prClosed) { state = 'lost'; owner = 'nobody'; blockedOn = `${w.pr} was closed without merging`; next = 're-open, replace, or drop (a card)'; }
    else if (w.pr && w.mergeable === 'conflicting') { state = 'stale'; blockedOn = 'conflict with main'; next = 'freshen-pr: merge main in, rerun CI, re-review'; }
    else if (w.pr && hours(now - Date.parse(w.prAt)) > staleH) { state = 'stale'; blockedOn = `no push for ${Math.round(hours(now - Date.parse(w.prAt)))} h`; next = 'freshen-pr: merge main in, rerun CI'; }
    else {
      if (w.ci === 'failure') blockedOn = `CI failed on ${String(w.head || '').slice(0, 7)}`;
      else if (paused && w.yard && (ys === 'pending' || ys === 'running')) blockedOn = 'the Yard is paused';
      next = stage === 'build' ? (w.yard ? 'the Yard cooks it' : 'build (crew)') : stage === 'review' ? 'verifier review and CI' : stage === 'ci' ? (w.ci === 'failure' ? 'fix CI (crew)' : 'wait for CI') : stage === 'merge-ready' ? 'a merge card for Jordan' : null;
    }
    const brief = briefs.get(w.id); const pl = planOf(w, brief, snap.plans);
    const row = {
      v: CONTRACT_V, id: w.id, alias: w.alias && /^J\d+$/.test(w.alias) ? w.alias : null, goal: text(w.goal || w.id, 2000) || w.id, stream: w.stream || 'OTHER', owner,
      plan: pl.plan, decision: (open[0] || answered[answered.length - 1])?.id ?? null, repo: w.repo, branch: w.branch, base: w.base, pr: w.pr, stackParent: null,
      stage, state, blockedOn, next, ageH: hours(now - Date.parse(w.createdAt)), stageAgeH: hours(now - Date.parse(stageAt)), attempts: w.attempts || (y?.attempt ?? 0),
      dod: w.dod || {}, brief: brief?.brief && REL_RE.test(brief.brief) ? brief.brief : null, report: brief?.report && REL_RE.test(brief.report) ? brief.report : null,
      proof: proof ? text(proof, 500) : null, lastSeq: w.lastSeq,
    };
    if (state !== 'shipped' && rank(row.stage) >= rank('merged')) row.stage = 'merge-ready';   // merged needs proof (contract): never claim it without
    if (w.dropNotByJordan) flags.push({ wo: w.id, flag: 'no-decision', detail: `${w.id}: ${w.dropNotByJordan}` });
    rows.push(Object.assign(row, { _planWhy: pl.why, _createdAt: w.createdAt }));
  }
  // stacks: a PR based on another row's branch (same repo) is stacked on it
  const byBranch = new Map(rows.filter((r) => r.branch && r.pr).map((r) => [`${String(r.pr).split('#')[0]}|${r.branch}`, r]));
  for (const r of rows) if (r.base && r.pr && !/^(main|master)$/.test(r.base)) { const p = byBranch.get(`${String(r.pr).split('#')[0]}|${r.base}`); if (p && p.id !== r.id) r.stackParent = p.id; }
  const byId = new Map(rows.map((r) => [r.id, r]));
  const depthOf = (/** @type {any} */ r) => { let d = 0, c = r; const seen = new Set(); while (c?.stackParent && !seen.has(c.id) && d < 50) { seen.add(c.id); d++; c = byId.get(c.stackParent); } return d; };

  // attention flags
  for (const r of rows) {
    if (r.state === 'stale') flags.push({ wo: r.id, flag: 'stale', detail: `${r.id}: ${r.blockedOn}` });
    if (r.state === 'lost') flags.push({ wo: r.id, flag: 'lost', detail: `${r.id}: ${r.blockedOn || 'lost'}` });
    const depth = depthOf(r), limit = NO_STACK_STREAMS.has(r.stream) ? WIP.stackDepthFlagged : WIP.stackDepth;
    if (OPEN.has(r.state) && depth > limit) flags.push({ wo: r.id, flag: 'stack-too-deep', detail: `${r.id} is stacked ${depth} deep (the limit for ${r.stream} is ${limit})` });
    if (OPEN.has(r.state) && !r.plan && !NOT_BUILD_STREAMS.has(r.stream)) flags.push({ wo: r.id, flag: 'no-plan', detail: `${r.id}: ${r._planWhy || 'no plan names it'}` });
    if (r.state === 'waiting-on-jordan' && !r.decision) flags.push({ wo: r.id, flag: 'no-decision', detail: `${r.id} waits on Jordan with no decision card (${r.blockedOn})` });
  }
  // the queue: open cards, oldest first
  const queueAll = [...decisions.values()].filter((d) => d.answer == null).sort((a, b) => String(a.at).localeCompare(String(b.at)) || String(a.id).localeCompare(String(b.id)))
    .map((d) => { const r = byId.get(d.wo); return { decision: decisionOut(d), goal: text(r?.goal || `${d.kind} card ${d.id}`, 2000), stream: r?.stream ?? null, ageH: hours(now - Date.parse(d.at)) }; });
  // streams and WIP
  const groups = new Map();
  for (const r of rows) { if (!OPEN.has(r.state)) continue; if (!groups.has(r.stream)) groups.set(r.stream, []); groups.get(r.stream).push(r); }
  const streams = [...groups].map(([stream, list]) => {
    const oldest = list.reduce((/** @type {any} */ a, /** @type {any} */ b) => (b.ageH > a.ageH ? b : a));
    const cards = list.filter((/** @type {any} */ r) => r.state === 'waiting-on-jordan').length;
    const deep = list.some((/** @type {any} */ r) => depthOf(r) > (NO_STACK_STREAMS.has(stream) ? WIP.stackDepthFlagged : WIP.stackDepth));
    return { stream, open: list.length, stage: oldest.stage, oldestH: oldest.ageH, blockedOn: oldest.blockedOn, cards, overLimit: cards >= WIP.cardsPerStream || deep };
  }).sort((a, b) => b.oldestH - a.oldestH || a.stream.localeCompare(b.stream));
  const build = streams.filter((s) => !NOT_BUILD_STREAMS.has(s.stream));
  if (build.length > WIP.streams) {
    for (const s of build.slice(WIP.streams)) s.overLimit = true;
    flags.push({ wo: null, flag: 'over-wip', detail: `${build.length} build streams are open; the limit is ${WIP.streams} (${build.map((s) => s.stream).join(', ')})` });
  }
  for (const s of streams) if (s.cards >= WIP.cardsPerStream) flags.push({ wo: null, flag: 'over-wip', detail: `${s.stream} has ${s.cards} cards waiting on Jordan; at ${WIP.cardsPerStream} it starts no new slices` });
  // feature flag values: L4's flags.json defaults, then flag.set events (the last one wins)
  const flagValues = flagProjection(o.flagDefaults, flagSets);
  const count = (/** @type {string} */ s) => rows.filter((r) => r.state === s).length;
  const shipped24 = rows.filter((r) => r.state === 'shipped' && r.stageAgeH <= 24).length;
  const top = `Work: ${queueAll.length} cards and ${count('waiting-on-jordan')} orders waiting on Jordan, ${count('stale')} stale, ${count('stuck')} stuck, ${count('lost')} lost, ${count('moving')} moving; ${shipped24} shipped in the last 24 h; ${build.length} of ${WIP.streams} build streams open${paused ? '; the Yard is paused' : ''}`;
  const order = ['waiting-on-jordan', 'stale', 'stuck', 'lost', 'moving', 'shipped', 'dropped', 'replaced'];
  rows.sort((a, b) => order.indexOf(a.state) - order.indexOf(b.state) || b.ageH - a.ageH || a.id.localeCompare(b.id));
  const internal = { rowMeta: rows.map((r) => ({ planWhy: r._planWhy, createdAt: r._createdAt })), fold: { wos, decisions, snap } };
  for (const r of rows) { delete r._planWhy; delete r._createdAt; }
  return { at: o.now.toISOString(), top, queue: queueAll.slice(0, 7), queueTotal: queueAll.length, queueAll, streams, rows, flags, flagValues, paused, internal };
}

/**
 * Feature flag values. Defaults come from L4's flags.json; its shape is not a contract yet (UNVERIFIED), so three shapes are read:
 * { flags: { name: { default } } }, { flags: [{ name|flag, default }] } and { name: boolean }. An unknown flag is off.
 * @param {any} defaults @param {Map<string, any>} sets
 */
export function flagProjection(defaults, sets) {
  /** @type {Map<string, boolean>} */ const def = new Map();
  const src = defaults?.flags ?? defaults;
  if (Array.isArray(src)) { for (const f of src) if (f && (f.name || f.flag)) def.set(String(f.name || f.flag), f.default === true || f.default === 'on'); }
  else if (src && typeof src === 'object') for (const [k, v] of Object.entries(src)) { if (k.startsWith('_') || k === 'v') continue; def.set(k, v === true || v === 'on' || (typeof v === 'object' && v !== null && (/** @type {any} */ (v).default === true || /** @type {any} */ (v).default === 'on'))); }
  const names = [...new Set([...def.keys(), ...sets.keys()])].sort();
  return names.map((flag) => { const s = sets.get(flag); return { flag, on: s ? s.on === true : def.get(flag) === true, default: def.get(flag) === true, declared: def.has(flag), decision: s?.decision ?? null, at: s?.at ?? null, from: s ? 'event' : def.has(flag) ? 'default' : 'unknown' }; });
}

/**
 * The ledger.json export: the shape pass-app/server.mjs ledgerView() and towers.mjs blueprints() read today (kitchen/ledger.ps1 writes
 * the same keys). New states keep their names; the Board shows them as text. Finished rows older than recentH are left out, as the old
 * ledger leaves out shipped orders.
 * @param {ReturnType<typeof buildView>} v @param {{ recentH?: number }} [o]
 */
export function exportLedgerJson(v, o = {}) {
  const recentH = o.recentH ?? 168;
  const ownerWord = /** @type {Record<string,string>} */ ({ crew: 'kitchen', jordan: 'Jordan', nobody: '' });
  const lg = legacyLedger(/** @type {any} */ (v));
  // the old ledger's ideas, roadmap items and unfinished orders first (its own rules), then every other row the old file never had
  const rowItems = v.rows.filter((r) => !(r.alias && lg.inChain.has(r.alias)) && (!FINISHED.has(r.state) || r.stageAgeH <= recentH)).map((r) => ({
    id: r.alias || r.id, wo: r.id, kind: 'order', title: r.goal, from: r.stream, jordans: false, score: 0, size: '',
    state: r.state, owner: r.state === 'lost' || r.state === 'stuck' ? 'Claude' : ownerWord[r.owner] ?? '', why: r.blockedOn || '', proof: r.proof || '', listed: r.stage,
    since: new Date(Date.parse(v.at) - r.ageH * 3600000).toISOString(), ageDays: Math.round(r.ageH / 2.4) / 10,
    chain: [{ id: r.alias || r.id, status: r.stage, proof: r.proof || '', note: r.next || '', replacedBy: r.state === 'replaced' && r.next ? r.next.replace(/^continues as /, '') : '' }],
  }));
  // no cap: the old file had none, and a cap would drop items silently (the Board's reader takes the first 400 itself)
  const items = [...lg.items, ...rowItems];
  const ruleOwner = /** @type {Record<string,[string, number]>} */ ({ lost: ['Claude', 1], stale: ['Claude', 2], 'stack-too-deep': ['Claude', 2], 'no-plan': ['Claude', 3], 'no-decision': ['Jordan', 2], 'over-wip': ['Jordan', 2] });
  // the view's own flags for rows that are not Yard orders (the old rules flag those), Jordan's cards, then the old flags
  const flags = v.flags.filter((f) => !f.wo || !jobOfWo(f.wo)).map((f) => ({ id: f.wo || f.flag, rule: f.flag, owner: ruleOwner[f.flag]?.[0] || 'Claude', pri: ruleOwner[f.flag]?.[1] || 3, say: f.detail }))
    // ids and the goal only: the card's question stays in tide.db and on the Board (ledger.json is read by more than the Board, ZG-25)
    .concat(v.queueAll.map((c) => ({ id: c.decision.id, rule: 'waiting-on-you', owner: 'Jordan', pri: 1, say: `${c.goal}: card ${c.decision.id} (${c.decision.kind}) waits on you (${c.ageH} h); the question is on the Board.` })), lg.flags)
    .sort((a, b) => a.pri - b.pri || String(a.id).localeCompare(String(b.id)));
  // counts keep their old meaning (the old items); the rows the old file never had are counted under work
  const n = (/** @type {string} */ s) => lg.items.filter((r) => r.state === s).length;
  const rn = (/** @type {string} */ s) => rowItems.filter((r) => r.state === s).length;
  return {
    ok: true, updated: v.at, top: v.top, source: 'core/ledger (tide.db)',
    counts: { waitingOnJordan: n('waiting-on-jordan'), lost: n('lost'), claimed: n('claimed'), stuck: n('stuck'), moving: n('moving'), notStarted: n('not-started'), shipped: n('shipped'), stale: n('stale'),
      yourIdeasOpen: lg.items.filter((x) => x.jordans && !['shipped', 'dropped'].includes(x.state)).length, flags: flags.length, drift: lg.drift.length, decisionsReady: lg.lobe.decisionsReady, postMortemsDue: lg.lobe.postMortemsDue, cards: v.queueTotal },
    work: { rows: rowItems.length, lost: rn('lost'), stuck: rn('stuck'), stale: rn('stale'), moving: rn('moving'), shipped: rn('shipped'), waitingOnJordan: rn('waiting-on-jordan') },
    lobe: lg.lobe, programs: lg.programs, flags, drift: lg.drift, items,
  };
}
