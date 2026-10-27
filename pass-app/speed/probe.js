// The in-page probe of the speed budget: times every animation-frame callback (work per frame, grouped by vsync), counts canvas draws,
// and keeps paint, layout-shift, interaction and long-frame entries. Injected by pass-app/speed/scenario.mjs before the Board's scripts.
// It reads nothing from the app's own code, so it measures any renderer (Canvas2D today, WebGL later) the same way.
(() => {
  const P = (window.__speed = { phase: 'load', frames: [], rafs: 0, draws: 0, events: [], shifts: 0, fcp: null, lcp: null, fup: null, loaf: [] });
  const raf = window.requestAnimationFrame.bind(window);
  let cur = null;
  // one entry per vsync that ran any callback: the summed JS work, the draws made, and the phase the runner had set
  window.requestAnimationFrame = (cb) => raf((ts) => {
    const t0 = performance.now(), d0 = P.draws;
    try { cb(ts); } finally {
      const work = performance.now() - t0; P.rafs++;
      if (cur && cur.ts === ts) { cur.work += work; cur.draws += P.draws - d0; } else { cur = { ts, work, draws: P.draws - d0, phase: P.phase }; P.frames.push(cur); }
    }
  });
  const C2 = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype, draw = C2 && C2.drawImage;
  if (draw) C2.drawImage = function (...a) { P.draws++; return draw.apply(this, a); };
  const watch = (type, fn, extra = {}) => { try { new PerformanceObserver((l) => l.getEntries().forEach(fn)).observe({ type, buffered: true, ...extra }); } catch { /* not in this browser */ } };
  // FCP is the paint entry that is not 'first-paint'; LCP's entry type is looked up by its 'largest-' prefix (Chrome's own list)
  watch('paint', (e) => { if (e.name !== 'first-paint') P.fcp = e.startTime; });
  const lcpType = (PerformanceObserver.supportedEntryTypes || []).find((t) => t.startsWith('largest-'));
  if (lcpType) watch(lcpType, (e) => { P.lcp = e.startTime; });
  watch('layout-shift', (e) => { if (!e.hadRecentInput) P.shifts += e.value; });
  watch('event', (e) => { if (e.interactionId) P.events.push({ name: e.name, id: e.interactionId, ms: e.duration, phase: P.phase }); }, { durationThreshold: 16 });
  watch('long-animation-frame', (e) => P.loaf.push({ ms: e.duration, phase: P.phase }));
  // first useful paint: the app's own mark when it sets one, else the first frame painted after the headline has words and the scene
  // slot has content (the status line, the scene or its still card, and the first number)
  const useful = () => { const s = document.getElementById('summary'), sc = document.getElementById('scene-pass'); return !!(s && s.textContent.trim() && sc && sc.firstElementChild); };
  const done = (t) => { if (P.fup === null) P.fup = t; };
  watch('mark', (e) => { if (e.name === 'board-first-useful') done(e.startTime); });
  const mo = new MutationObserver(() => { if (P.fup !== null || !useful()) return; mo.disconnect(); raf(() => setTimeout(() => done(performance.now()), 0)); });
  mo.observe(document, { childList: true, subtree: true, characterData: true });
})();
