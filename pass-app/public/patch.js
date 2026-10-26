// The live board, kept from one full state plus patches (pass-app/server.mjs advance(): `state` carries v; each `patch` is
// { v, base, top, upsert, remove }). Pure: no DOM, no network, so tests/Test-PassApp.ps1 runs it in node (pass-app/test-patch.mjs).
const byNum = (a, b) => parseInt(String(a.id).slice(1)) - parseInt(String(b.id).slice(1));
// the next board, or null when the patch does not follow the copy held (base is not its v): the caller asks for a fresh full state
export function applyPatch(s, p) {
  if (!s || !p || typeof p !== 'object' || p.base !== s.v || !Number.isInteger(p.v)) return null;
  let jobs = s.jobs; const up = Array.isArray(p.upsert) ? p.upsert : [], rm = Array.isArray(p.remove) ? p.remove : [];
  if (up.length || rm.length) {
    const at = new Map(jobs.map((j, i) => [j.id, i])); jobs = jobs.slice(); let fresh = false;
    for (const j of up) { const i = at.get(j.id); if (i === undefined) { jobs.push(j); fresh = true; } else jobs[i] = j; }
    if (rm.length) { const gone = new Set(rm); jobs = jobs.filter((j) => !gone.has(j.id)); }
    if (fresh) jobs.sort(byNum);   // the server's order: ticket number
  }
  return { ...s, ...(p.top && typeof p.top === 'object' ? p.top : {}), jobs, v: p.v };
}
// One stream's bookkeeping: a full state is taken as is; a patch that fits is applied; the first one that does not asks for a resync
// once (resync() reconnects, and the new stream starts with a full state) and the patches after it are dropped until that state comes.
export function makeFeed({ onState, resync }) {
  const F = { s: null, waiting: false, resyncs: 0 };
  F.full = (s) => { F.s = s; F.waiting = false; onState(s, null); };
  F.patch = (p) => {
    if (F.waiting) return;
    const next = applyPatch(F.s, p);
    if (!next) { F.waiting = true; F.resyncs++; resync(); return; }
    F.s = next; onState(next, p);
  };
  F.reset = (s) => { F.s = s; F.waiting = false; };
  return F;
}
