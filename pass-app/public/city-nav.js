// The City's navigation (semantic zoom): the routes, the breadcrumb, the camera move between levels, and the gestures on the canvas.
// Used by public/city.js (mountCity); tested by pass-app/test-city.mjs. Each level is a hash route, so Back (Android's, the browser's, Esc)
// zooms out one level. Levels: #/pass or #/city = the City; #/city/<key> = one building; #/city/<key>/f/<pr> = a floor (G6).
const KEY = /^[a-z0-9][a-z0-9._-]{0,47}$/;
// the City's route from a location hash: { level, key, pr } (level 0 for #/pass and anything that is not a City route)
export function routeOf(hash) {
  const p = String(hash || '').replace(/^#\/?/, '').split('/');
  if (p[0] !== 'city' || !KEY.test(p[1] || '')) return { level: 0, key: null, pr: null };
  if (p[2] === 'f' && /^\d{1,7}$/.test(p[3] || '')) return { level: 2, key: p[1], pr: Number(p[3]) };
  return { level: 1, key: p[1], pr: null };
}
export const hashOf = (r) => (!r?.key ? '#/pass' : r.level >= 2 && r.pr ? `#/city/${r.key}/f/${r.pr}` : `#/city/${r.key}`);
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
// crisp at its whole-number scale. Under reduced motion it is an instant cut.
export function cameraMove(canvas, atX, zoomIn, reduced, done) {
  if (reduced || !canvas?.animate) { done(); return; }
  const s = zoomIn ? 2.2 : 0.6; const origin = `${Math.round(atX * 100)}% 85%`;
  const a = canvas.animate([{ transform: 'scale(1)', transformOrigin: origin }, { transform: `scale(${s})`, transformOrigin: origin }], { duration: zoomIn ? 280 : 220, easing: 'cubic-bezier(.2,.7,.3,1)' });
  a.onfinish = a.oncancel = () => done();
}
