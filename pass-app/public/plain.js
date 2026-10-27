// Plain words shared by the Board home, its rows and the City (task 30, D-11): what the home counts (Jordan's phone 10-27: "47 failed or
// stopped" counted days-old killed and quarantined orders, so the number meant nothing), times and dates in words, a tower row's state.
// Imported by app.js (renderPass, the rows' times) and city-nav.js (the cutaway); pure, no DOM, tested in node by pass-app/test-readable.mjs.

// task 32 (failure care, kitchen/failure-policy.json "care.recentHours"): a failure needs Jordan now while it is open (failed or stopped,
// not cleared) and from the last 72 h. Older ones, and every cleared order (retried, superseded, duplicate, stale, dropped: the Yard's
// one end for an order that is not done), sit in "Older", one tap away. Before task 32 it was one day and cleared orders did not show.
export const RECENT_MS = 72 * 3600e3;
const ASIDE = new Set(['quarantined', 'killed', 'failed']);
const at = (j) => new Date(j?.updated || j?.created || 0).getTime() || 0;
// { recent, older }: recent = the failures that need Jordan now; older = older failures and cleared orders; each list newest first
export function homeStats(jobs, now = Date.now()) {
  const recent = [], older = [];
  for (const j of jobs || []) {
    if (j?.cleared) older.push(j);
    else if (ASIDE.has(j?.status)) (now - at(j) < RECENT_MS ? recent : older).push(j);
  }
  const newest = (a, b) => at(b) - at(a);
  return { recent: recent.sort(newest), older: older.sort(newest) };
}
// The Failures list in groups by class (the policy's classes), the ones that most need a person first; an order with no class yet (it
// failed before failure care and the doctor has not given it words) is "Failed". Each group keeps the list's order. [{ cls, label, items }]
export const CLASS_ORDER = ['real', 'privacy', 'stopped', 'conflict', 'stale', 'flaky', 'infra', 'resting'];
export function failureGroups(list) {
  const by = new Map();
  for (const j of list || []) {
    const cls = j?.failure?.cls || (j?.status === 'killed' ? 'stopped' : 'other');
    const label = j?.failure?.label || (cls === 'stopped' ? 'Stopped' : 'Failed');
    if (!by.has(cls)) by.set(cls, { cls, label, items: [] });
    by.get(cls).items.push(j);
  }
  const rank = (c) => { const i = CLASS_ORDER.indexOf(c); return i < 0 ? CLASS_ORDER.length : i; };
  return [...by.values()].sort((a, b) => rank(a.cls) - rank(b.cls));
}
// "Cleared as stale: no human action for 4 days since it failed" (the reason is the Yard's own words)
const CLEARED_WORD = { retried: 'Retried', superseded: 'Superseded', duplicate: 'Duplicate', stale: 'Cleared as stale', dropped: 'Dropped' };
export const clearedWords = (c) => (c ? `${CLEARED_WORD[c.state] || 'Cleared'}${c.by && c.state !== 'stale' && c.state !== 'dropped' ? ` (${c.by})` : ''}: ${c.reason || 'no reason was recorded'}` : '');
// "just now", "3 min ago", "2 h ago", "1 day ago", "5 days ago"; '' for no time
export function agoWords(ts, now = Date.now()) {
  if (!ts) return ''; const s = Math.max(0, (now - new Date(ts).getTime()) / 1000); if (!Number.isFinite(s)) return '';
  if (s < 60) return 'just now'; if (s < 3600) return Math.round(s / 60) + ' min ago'; if (s < 86400) return Math.round(s / 3600) + ' h ago';
  const d = Math.round(s / 86400); return d + (d === 1 ? ' day ago' : ' days ago');
}
// the exact time a tap shows: "14:05" today, else "Oct 23, 14:05"
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
// a day in words ("Oct 23"), in the phone's own time zone
export const dayWords = (iso) => { const d = new Date(iso); return isNaN(d) ? 'an unknown day' : `${MON[d.getMonth()]} ${d.getDate()}`; };
export function exactTime(ts, now = Date.now()) {
  const d = new Date(ts); if (isNaN(d)) return ''; const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  return d.toDateString() === new Date(now).toDateString() ? hm : `${dayWords(ts)}, ${hm}`;
}
// a tower row in plain words. An open PR: "open, checks passed" / "checks running" / "checks failed" (a draft says draft); a floor: "merged Oct 23"
// or "taken down Oct 24"
const CI_WORD = { green: 'checks passed', pending: 'checks running', red: 'checks failed' };
export const openWords = (o) => [o?.draft ? 'draft' : 'open', CI_WORD[o?.ci]].filter(Boolean).join(', ');
export const floorWords = (f) => (f?.undone ? `taken down ${dayWords(f.undone)}` : `merged ${dayWords(f?.at)}`);
