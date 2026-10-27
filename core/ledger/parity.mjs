// @ts-check
// Parity: the new view against the Ledger kitchen/ledger.ps1 builds (ledger.json). Every old item is matched to a row with the same
// state, or explained (a named reason the new ledger differs on purpose), or listed as unexplained. The cutover rule (docs/changes):
// shadow and new need 0 unexplained items on a scratch copy of the live state folder.
import { woOfJob } from './ids.mjs';
import { fold, exportLedgerJson } from './view.mjs';

/**
 * Why a state differs, or null when no known reason covers it.
 * @param {string} oldState @param {any} row
 */
export function stateReason(oldState, row) {
  const s = row.state;
  if (oldState === s) return '';
  if (s === 'shipped' && oldState !== 'shipped') return `new proof the old ledger does not read: ${row.proof}`;
  if (oldState === 'claimed' && s === 'lost') return 'the row contract has no "claimed" state: a close "done another way" with no proof is lost, with that reason in blockedOn';
  if (s === 'stale') return `stale is a new state (build-way 3.1): ${row.blockedOn}`;
  if (s === 'waiting-on-jordan' && row.decision) return `an open decision card (${row.decision})`;
  if (s === 'replaced') return `${row.next} (a replaced event; the old ledger shows a replacement inside the chain of the idea instead)`;
  if (s === 'dropped' && ['lost', 'dropped'].includes(oldState)) return 'a dropped event (Jordan\'s drop) closes it';
  if (oldState === 'not-started' && s === 'moving') return 'a Yard order exists, so it is moving (the old ledger says not-started for an idea or roadmap item before its order)';
  return null;
}

/**
 * An idea's state is about the idea, not its last order: it ships through any order in its chain or a manual link, and Jordan drops
 * the idea itself in Chef. Those are idea-level facts a work order row does not carry.
 * @param {any} it the old idea item @param {string} job its last order
 */
export function ideaReason(it, job) {
  const proof = String(it.proof || '');
  if (it.state === 'shipped' && proof.startsWith('linked:')) return `the idea shipped through a manual proof link (ledger-links.json), which no importer reads yet (card); its last order ${job} has no proof`;
  const other = (Array.isArray(it.chain) ? it.chain : []).find((/** @type {any} */ c) => c?.proof && c.id !== job);
  if (it.state === 'shipped' && other) return `the idea shipped through ${other.id} (${other.proof}); the row is its last order ${job}, which has no proof of its own`;
  if (it.state === 'dropped' && /Chef/.test(String(it.why || ''))) return `Jordan dropped the idea in Chef (an idea-level drop, pass-actions.jsonl); its last order ${job} closed without a drop`;
  return null;
}

/**
 * @param {any} old the old ledger.json document
 * @param {{ rows: any[] }} view the new view
 * @param {any[]} events the events the view was built from (to tell an excluded sub-order from a missing order)
 */
export function compareLedgers(old, view, events) {
  const byAlias = new Map(view.rows.filter((r) => r.alias).map((r) => [r.alias, r]));
  const byId = new Map(view.rows.map((r) => [r.id, r]));
  const { wos } = fold(events);
  const exp = /** @type {any} */ (view).internal ? exportLedgerJson(/** @type {any} */ (view)) : { items: [] };
  const exported = new Map(exp.items.map((/** @type {any} */ x) => [`${x.kind}|${x.id}`, x]));
  const roadmaps = /** @type {any} */ (view).internal?.fold?.snap?.roadmaps;
  const items = [];
  for (const it of Array.isArray(old?.items) ? old.items : []) {
    const id = String(it?.id || ''); const oldState = String(it?.state || 'unknown'); const kind = String(it?.kind || '');
    const out = { old: id, kind, oldState, new: /** @type {string|null} */ (null), newState: /** @type {string|null} */ (null), verdict: 'unexplained', reason: '' };
    // ideas and roadmap items: the export rebuilds them with the old rules (legacy.mjs), so they are compared item for item
    const ex = exported.get(`${kind}|${id}`);
    if (ex && (kind === 'idea' || kind === 'roadmap')) {
      out.new = ex.wo || ex.id; out.newState = ex.state;
      // the same state is not enough: an idea's chain (its orders, in order) must match too
      const ids = (/** @type {any} */ x) => (Array.isArray(x?.chain) ? x.chain.map((/** @type {any} */ c) => String(c?.id || '')).join(',') : '');
      if (ex.state === oldState && (kind !== 'idea' || ids(it) === ids(ex))) { out.verdict = 'same'; out.reason = `the export's own ${kind} item`; items.push(out); continue; }
      if (ex.state === oldState) { out.reason = `same state, but the chain differs: old ${ids(it) || 'none'}, new ${ids(ex) || 'none'}`; items.push(out); continue; }
      if (ex.state === 'shipped') { out.verdict = 'explained'; out.reason = `new proof the old ledger does not read: ${ex.proof}`; items.push(out); continue; }
      out.reason = `the old ledger says ${oldState}, the export's own ${kind} item says ${ex.state}${ex.why ? ` (${ex.why})` : ''}: no known reason`; items.push(out); continue;
    }
    if (kind === 'roadmap') {
      const rm = roadmaps?.get(String(it.from || ''));
      if (!rm) { out.verdict = 'explained'; out.reason = `the roadmap of ${it.from} was not imported (its checkout was not given and no Yard order names it)`; }
      else if (!rm.ok) { out.verdict = 'explained'; out.reason = `the roadmap of ${it.from} could not be read: ${rm.why}`; }
      else if (!ex) out.reason = `the old ledger lists ${id} (${oldState}); the export does not: no known reason`;
      else out.reason = `the old ledger says ${oldState}, the export ${ex.state}: no known reason`;
      items.push(out); continue;
    }
    let job = kind === 'order' ? id : '';
    if (kind === 'idea') {
      const chain = Array.isArray(it.chain) ? it.chain : [];
      if (!chain.length) { out.verdict = 'explained'; out.reason = `an idea that was never built (${oldState}): ideas are not work orders, so it has no row until an order is made`; items.push(out); continue; }
      job = String(chain[chain.length - 1]?.id || '');
    }
    const row = byAlias.get(job) || byId.get(String(woOfJob(job) || ''));
    if (!row) {
      const w = wos.get(String(woOfJob(job) || ''));
      if (w?.yard?.parent) { out.verdict = 'explained'; out.reason = `${job} is a sub-order of ${w.yard.parent}: it shows under its parent, as in the old ledger`; }
      else if (w) { out.verdict = 'unexplained'; out.reason = `${job} was imported but has no row`; }
      else out.reason = `${job || id} was not imported (no job file and no archive line)`;
      items.push(out); continue;
    }
    out.new = row.id; out.newState = row.state;
    let why = stateReason(oldState, row);
    if (why === null && kind === 'idea') why = ideaReason(it, job);
    if (why === '') { out.verdict = 'same'; out.reason = kind === 'idea' ? `the row of its last order ${job}` : ''; }
    else if (why) { out.verdict = 'explained'; out.reason = kind === 'idea' ? `idea ${id} -> its last order ${job}: ${why}` : why; }
    else out.reason = `the old ledger says ${oldState}, the new one ${row.state}${row.blockedOn ? ` (${row.blockedOn})` : ''}: no known reason`;
    items.push(out);
  }
  const oldIds = new Set(items.map((i) => i.new).filter(Boolean));
  const newOnly = view.rows.filter((r) => !oldIds.has(r.id));
  const reasonNew = (/** @type {any} */ r) => (!r.alias ? 'a GitHub PR or engine order: a source the old ledger does not read'
    : ['shipped', 'dropped', 'replaced', 'lost'].includes(r.state) ? 'a finished or closed order: the old ledger lists only unfinished orders and ideas'
      : 'an order the old ledger lists inside an idea\'s chain or not at all');
  const groups = new Map(); for (const r of newOnly) { const k = reasonNew(r); groups.set(k, (groups.get(k) || 0) + 1); }
  const count = (/** @type {string} */ v) => items.filter((i) => i.verdict === v).length;
  const lobe = (Array.isArray(old?.flags) ? old.flags : []).filter((/** @type {any} */ f) => ['decision-ready', 'post-mortem-due'].includes(f?.rule)).length;
  return {
    ok: count('unexplained') === 0, old: items.length, same: count('same'), explained: count('explained'), unexplained: count('unexplained'),
    newOnly: newOnly.length, newOnlyWhy: Object.fromEntries(groups), lobeFlagsNotImported: lobe, items,
  };
}
