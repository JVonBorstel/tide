// Owns the small helpers the Work tab's screen files share (lane L5, WO-UPG-L5-4): escaping, this phone's own memory, motion, ages,
// and the screen-reader line. Called by view.js, queue.js, cards.js and replay.js.
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/** Per-phone conveniences only (the morning card's "Later", the last snapshot); a private window or blocked storage just forgets them. */
export const store = {
  get(k, d) { try { const v = localStorage.getItem('chef.work.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('chef.work.' + k, JSON.stringify(v)); } catch { } },
};
export const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
export const age = (h) => (h < 1 ? `${Math.max(1, Math.round(h * 60))} min` : h < 48 ? `${Math.round(h)} h` : `${Math.round(h / 24)} d`);
/** Tell a screen reader (the Board's own polite line). */
export const say = (msg) => { const a = document.getElementById('announce'); if (a) { a.textContent = ''; requestAnimationFrame(() => { a.textContent = msg; }); } };
/** Today's date on this phone, YYYY-MM-DD. */
export const today = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
