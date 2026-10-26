// The City's navigation (semantic zoom): the routes, the breadcrumb, the camera move between levels, and the gestures on the canvas.
// Used by public/city.js (mountCity); tested by pass-app/test-city.mjs. Each level is a hash route, so Back (Android's, the browser's, Esc)
// zooms out one level. Levels: #/pass or #/city = the City; #/city/<key> = one building; #/city/<key>/f/<pr>[/old] = a floor or an open
// PR (/old: a floor under the "public from" line, whose number the public repo may reuse).
import { windowed, WINDOW_FIRST, WINDOW_STEP } from './rows.js';
const KEY = /^[a-z0-9][a-z0-9._-]{0,47}$/;
// the City's route from a location hash: { level, key, pr } (level 0 for #/pass and anything that is not a City route)
export function routeOf(hash) {
  const p = String(hash || '').replace(/^#\/?/, '').split('/');
  if (p[0] !== 'city' || !KEY.test(p[1] || '')) return { level: 0, key: null, pr: null };
  if (p[2] === 'f' && /^\d{1,7}$/.test(p[3] || '')) return { level: 2, key: p[1], pr: Number(p[3]), ...(p[4] === 'old' ? { old: true } : {}) };
  return { level: 1, key: p[1], pr: null };
}
export const hashOf = (r) => (!r?.key ? '#/pass' : r.level >= 2 && r.pr ? `#/city/${r.key}/f/${r.pr}${r.old ? '/old' : ''}` : `#/city/${r.key}`);
// one level up (what Back and Esc do)
export const upOf = (r) => (r.level >= 2 ? { level: 1, key: r.key, pr: null } : { level: 0, key: null, pr: null });
// the neighbour building for a sideways swipe on a building (it wraps around); the gate and the Yard lot are not in the ring
export function neighbourOf(keys, key, dir) { const i = keys.indexOf(key); return i < 0 || !keys.length ? null : keys[(i + dir + keys.length) % keys.length]; }
// the breadcrumb: City › Tide › Floor 121 (each crumb but the last is a link, at least 44 px tall)
export function crumbsHtml(r, nameOf, esc) {
  if (!r.level) return '';
  const parts = [['#/pass', 'City'], [`#/city/${r.key}`, nameOf(r.key)], ...(r.level >= 2 ? [[null, `PR #${r.pr}`]] : [])];
  return `<nav class="city-crumbs" aria-label="Where you are in the City">${parts.map(([h, t], i) => (i < parts.length - 1 && h ? `<a href="${h}">${esc(t)}</a>` : `<span aria-current="page">${esc(t)}</span>`)).join('<i aria-hidden="true">›</i>')}</nav>`;
}
// what a gesture means: { gesture, at (0..1 across), dx, scale } -> a route, or null (nothing to do)
export function gestureTo(g, r, hit, keys) {
  if (g.gesture === 'tap') return hit && hit !== 'gate' ? { level: 1, key: hit, pr: null } : null;
  if (g.gesture === 'pinch-out') return hit && !r.level ? { level: 1, key: hit, pr: null } : null;
  if (g.gesture === 'pinch-in') return r.level ? upOf(r) : null;
  if (g.gesture === 'swipe' && r.level === 1) { const k = neighbourOf(keys, r.key, g.dx < 0 ? 1 : -1); return k ? { level: 1, key: k, pr: null } : null; }
  return null;
}
// pointer input on the canvas (Pointer Events only; touch-action pan-y keeps the page scrolling): tap, sideways swipe, pinch, long-press
export function attachGestures(el, { at, onGesture, onLong, buzz = () => {} }) {
  el.style.touchAction = 'pan-y';
  const pts = new Map(); let down = null; let pinch0 = 0; let longT = 0;
  const across = (e) => { const r = el.getBoundingClientRect(); return r.width ? (e.clientX - r.left) / r.width : 0.5; };
  el.addEventListener('pointerdown', (e) => {
    pts.set(e.pointerId, [e.clientX, e.clientY]); clearTimeout(longT);
    if (pts.size === 2) { const [a, b] = [...pts.values()]; pinch0 = Math.hypot(a[0] - b[0], a[1] - b[1]); down = null; return; }
    down = { x: e.clientX, y: e.clientY, at: across(e), long: false };
    longT = setTimeout(() => { if (down && onLong) { down.long = true; buzz(12); onLong(at(down.at)); } }, 500);
  });
  el.addEventListener('pointermove', (e) => { if (pts.has(e.pointerId)) pts.set(e.pointerId, [e.clientX, e.clientY]); if (down && Math.hypot(e.clientX - down.x, e.clientY - down.y) > 10) clearTimeout(longT); });
  const up = (e) => {
    clearTimeout(longT);
    if (pts.size === 2 && pinch0) {
      const [a, b] = [...pts.values()]; const s = Math.hypot(a[0] - b[0], a[1] - b[1]) / pinch0; const r = el.getBoundingClientRect();
      pts.delete(e.pointerId); pinch0 = 0; if (s > 1.25 || s < 0.8) onGesture({ gesture: s > 1 ? 'pinch-out' : 'pinch-in', at: ((a[0] + b[0]) / 2 - r.left) / (r.width || 1) });
      return;
    }
    pts.delete(e.pointerId); if (!down || down.long || e.type === 'pointercancel') { down = null; return; }
    const dx = e.clientX - down.x, dy = e.clientY - down.y;
    if (Math.abs(dx) > 48 && Math.abs(dx) > 1.5 * Math.abs(dy)) onGesture({ gesture: 'swipe', dx, at: down.at });
    else if (Math.hypot(dx, dy) < 12) onGesture({ gesture: 'tap', at: down.at });
    down = null;
  };
  el.addEventListener('pointerup', up); el.addEventListener('pointercancel', up);
  el.addEventListener('contextmenu', (e) => e.preventDefault());
}
// the camera move: the old picture scales toward the tapped building (zoom in 280 ms, out 220 ms, ease-out), then the new level is drawn
// crisp at its whole-number scale. Under reduced motion it is an instant cut. A timer ends a move whose clock stalls (a hidden page).
export function cameraMove(canvas, atX, zoomIn, reduced, done) {
  if (reduced || !canvas?.animate) { done(); return; }
  const s = zoomIn ? 2.2 : 0.6; const origin = `${Math.round(atX * 100)}% 85%`; const ms = zoomIn ? 280 : 220; let fin = 0;
  const a = canvas.animate([{ transform: 'scale(1)', transformOrigin: origin }, { transform: `scale(${s})`, transformOrigin: origin }], { duration: ms, easing: 'cubic-bezier(.2,.7,.3,1)' });
  const end = () => { if (!fin++) { a.cancel?.(); done(); } }; a.onfinish = a.oncancel = end; setTimeout(end, ms + 150);
}
// ---- a building's own level: the cutaway (one row per floor, newest first, open PRs on top; windowed by rows.js: 20, then 50 more a tap) and a floor's sheet; T = one /api/towers row
const day = (iso) => String(iso || '').slice(5, 10);
const BY = { yard: 'by the Yard', auto: 'by the Yard (auto-merged)', session: 'by a Claude session', github: 'on GitHub' };
const wo = (id) => (/^J\d{1,6}$/.test(id || '') ? `WO-${id.slice(1).padStart(4, '0')}` : '');
export function cutawayHtml(T, esc, n = WINDOW_FIRST) {
  if (!T) return '';
  const floors = (T.floors || []).slice().reverse(); const { shown, more } = windowed(floors, n); const row = (h, b, t, m) => `<li><a href="${h}"><b>${b}</b><span>${esc(t || '')}</span><i>${esc(m)}</i></a></li>`;
  const open = (T.open || []).map((o) => row(`#/city/${T.key}/f/${o.pr}`, `#${o.pr}`, o.title, `building${o.draft ? ', draft' : ''}${o.ci ? ', CI ' + o.ci : ''}`));
  let line = !!T.publicFrom; const rows = shown.map((f) => { const div = line && f.past ? ((line = false), `<li class="city-line">public from ${esc(day(T.publicFrom))}</li>`) : ''; return div + (f.pr ? row(`#/city/${T.key}/f/${f.pr}${f.past ? '/old' : ''}`, `#${f.pr}`, f.title, `${day(f.at)}${f.undone ? ', taken down' : ''}`) : `<li><span class="city-nopr"><b>${esc(wo(f.job) || 'merge')}</b><i>${esc(day(f.at))}, no PR</i></span></li>`); });
  return `<ol class="city-cut" aria-label="${esc(T.name)}: floors, newest first">${open.join('')}${rows.join('')}</ol>${more > 0 ? `<button class="city-more" type="button" data-city-more>Show ${Math.min(more, WINDOW_STEP)} more of ${floors.length} floors</button>` : ''}`;
}
export function floorHtml(T, pr, old, esc) {
  const f = (T?.floors || []).filter((x) => x.pr === pr && !!x.past === old).pop(); const o = !old && (T?.open || []).find((x) => x.pr === pr);
  if (!f && !o) return `<p class="city-cap" role="status">No floor or open PR #${pr} on this building.</p>`;
  const x = f || o; const dd = (k, v) => (v ? `<dt>${k}</dt><dd>${v}</dd>` : '');
  const gh = T.repo && !old && /^[\w.-]+\/[\w.-]+$/.test(T.repo) ? `<a href="https://github.com/${esc(T.repo)}/pull/${pr}" target="_blank" rel="noopener noreferrer">PR #${pr} on GitHub</a>` : '';
  return `<section class="city-sheet"><h2>PR #${pr}${x.title ? ': ' + esc(x.title) : ''}</h2><dl>${f ? dd('Merged', esc(String(f.at).replace('T', ' ').slice(0, 16)) + ' ' + esc(BY[f.by] || '')) + dd('Pour', f.pour ? `${esc(f.pour)}: ${T.floors.filter((y) => y.pour === f.pour).length} floors tested together` : '') + dd('Taken down', esc(day(f.undone))) + dd('Before the line', f.past ? 'yes (the older history)' : '') : dd('Under construction', `since ${esc(day(o.createdAt))}${o.draft ? ', a draft' : ''}`) + dd('CI', esc(o.ci || 'unknown'))}${dd('Work order', wo(x.job) ? `<a href="#/job/${esc(x.job)}">${wo(x.job)}</a>` : '')}</dl>${gh}</section>`;
}
