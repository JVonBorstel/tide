// The stage's frame loop decisions (Chef 2.8.0, Tide W4; pass-app/SCENE.md "Frame rate"): how often to look, whether the stage can be
// seen, and whether a frame is a new picture. Split from scene.js (its 600-line standard); scene.js and test-scene.mjs use it.
import { stageCalm, drawStage, STAGE } from './scene.js';
// fps: 10 when still, 60 while a crew member walks (a walk at 30 looks choppy), else 30 (sprite frames change every 90-900 ms)
export const stageWalking = (st) => [...st.actors.values()].some((a) => a.path.length > 0);
export const stageFps = (st) => (stageCalm(st) ? 10 : stageWalking(st) ? STAGE.fps : 30);
// the frame's key: drawStage's calls on a stand-in context; the same key is the same picture, so no draw
const imgIds = new WeakMap(); let imgN = 0;
const imgId = (img) => { if (!img || typeof img !== 'object') return String(img); if (!imgIds.has(img)) imgIds.set(img, ++imgN); return imgIds.get(img); };
export function frameKey(st, kit) {
  const parts = [];
  const rec = { set fillStyle(v) { parts.push('f' + v); }, get fillStyle() { return ''; },
    drawImage: (img, ...a) => { parts.push(imgId(img) + ':' + a.join(',')); }, fillRect: (...a) => { parts.push('r' + a.join(',')); } };
  drawStage(rec, st, kit); return parts.join('|');
}
// drawn only while seen: page shown, motion allowed, in the page and on screen (an IntersectionObserver sets visible)
export const stageOk = (sc, doc = globalThis.document, reducedMotion = false) => !doc?.hidden && !reducedMotion && !!sc.root?.isConnected && sc.visible !== false && !!sc.root.offsetParent;
// the frame loop, capped at fps; it asks for no frame while the page is hidden, the stage is off screen, or motion is reduced
export function makeLoop({ raf, fps = STAGE.fps, ok, frame }) {
  const L = { raf: 0, last: 0, frames: 0 };
  const step = (now) => {
    L.raf = 0; if (!ok()) { L.last = 0; return; }
    const cap = typeof fps === 'function' ? fps() : fps;   // a function: 10 fps while nothing moves
    if (!L.last || now - L.last >= 1000 / cap - 1) { frame(L.last ? Math.min(100, now - L.last) : 0); L.last = now; L.frames++; }
    L.raf = raf(step);
  };
  L.start = () => { if (!L.raf && ok()) L.raf = raf(step); return L; };
  return L;
}
