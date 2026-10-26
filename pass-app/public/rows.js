// Keyed rows (pass-app/README.md "Live board"): one element per key, kept from one render to the next. A row's element is made again
// only when its markup changed; the others are moved into order (or left alone) and rows whose key is gone are removed. So a change
// to one job touches one row, instead of rebuilding the whole board (chef.md: 52-72 ms per change at 1x, 496-598 ms at 10x).
// Events stay delegated on the board, so a replaced row needs no listeners. Pure DOM calls only (firstChild, nextSibling, insertBefore,
// replaceChild, removeChild), so pass-app/test-patch.mjs runs it against a tiny fake DOM.
const fromHtml = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstChild; };
// items in display order; key(item) -> string; html(item) -> markup of one element; sig(item) -> what decides a remake (default: the
// markup; a row with a ticking clock passes its markup without the clock). Returns the elements made this time.
export function syncList(parent, items, { key, html, sig, make = fromHtml }) {
  const map = parent._keyed || (parent._keyed = new Map()); const seen = new Set(); const made = [];
  let ref = parent.firstChild;
  for (const it of items) {
    const k = key(it), h = sig ? sig(it) : html(it); seen.add(k); let ent = map.get(k);
    if (!ent || ent.sig !== h) {
      const el = make(sig ? html(it) : h); el._key = k; made.push(el);
      if (ent && ent.el.parentNode === parent) { if (ref === ent.el) ref = el; parent.replaceChild(el, ent.el); }
      ent = { el, sig: h }; map.set(k, ent);
    }
    if (ent.el === ref) ref = ref.nextSibling; else parent.insertBefore(ent.el, ref);
  }
  // every row still wanted now sits before ref, in order; what is left from ref on is gone (or was never ours)
  while (ref) { const n = ref.nextSibling; parent.removeChild(ref); ref = n; }
  for (const k of map.keys()) if (!seen.has(k)) map.delete(k);
  return made;
}
// a long list shows its first `n` rows; the page asks for 50 more when the "showing N of M" line scrolls into view (or is tapped)
export const WINDOW_FIRST = 20, WINDOW_STEP = 50;
export const windowed = (list, n) => ({ shown: list.slice(0, Math.max(0, n)), more: Math.max(0, list.length - n) });
