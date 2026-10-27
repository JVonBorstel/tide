// Tests for the scene's WebGL2 renderer (public/gl.js, SCENE.md "Renderer", decision D-4): the same scene as Canvas2D pixel by pixel,
// the fallback without WebGL2, the flag, the shaders and the frame budget. Run by pass-app/test-scene.mjs, after the purpose tests.
import fs from 'node:fs';
import { layoutScene, STAGE, stageNew, stageSync, stageTick, makeKit, frameStats, paintStage, glWanted } from './public/scene.js';
import * as GL from './public/gl.js';
import * as P from './public/sprites.js';
import { busy, check, job } from './test-scene-stage.mjs';
import { T0, fullEvents, fullState } from './test-scene-world.mjs';
import { mEv } from './test-scene-purpose.mjs';

// a canvas with real pixels (RGBA, Canvas2D's source-over, whole pixels), so the two renderers can be compared pixel by pixel
const rgbOf = (css) => { const n = parseInt(String(css).slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
function pxCanvas(w, h) {
  const c = { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) };
  const put = (X, Y, r, g, b, a) => { if (X < 0 || Y < 0 || X >= c.width || Y >= c.height || !a) return; const D = c.data, i = (Y * c.width + X) * 4, k = a / 255;
    D[i] = r * k + D[i] * (1 - k); D[i + 1] = g * k + D[i + 1] * (1 - k); D[i + 2] = b * k + D[i + 2] * (1 - k); D[i + 3] = a + D[i + 3] * (1 - k); };
  const ctx = {
    imageSmoothingEnabled: true, fillStyle: '#000000',
    createImageData: (ww, hh) => ({ width: ww, height: hh, data: new Uint8ClampedArray(ww * hh * 4) }),
    putImageData: (img, x, y) => { for (let j = 0; j < img.height; j++) for (let i = 0; i < img.width; i++) { const X = x + i, Y = y + j; if (X >= 0 && Y >= 0 && X < c.width && Y < c.height) c.data.set(img.data.subarray((j * img.width + i) * 4, (j * img.width + i) * 4 + 4), (Y * c.width + X) * 4); } },
    drawImage: (img, ...a) => {
      const [sx0, sy0, sw, sh, dx, dy, dw, dh] = a.length === 8 ? a : a.length === 4 ? [0, 0, img.width, img.height, ...a] : [0, 0, img.width, img.height, a[0], a[1], img.width, img.height], S = img.data;
      for (let j = 0; j < dh; j++) for (let i = 0; i < dw; i++) { const s = ((sy0 + Math.floor(((j + 0.5) * sh) / dh)) * img.width + sx0 + Math.floor(((i + 0.5) * sw) / dw)) * 4; put(dx + i, dy + j, S[s], S[s + 1], S[s + 2], S[s + 3]); }
    },
    fillRect: (x, y, ww, hh) => { const [r, g, b] = rgbOf(ctx.fillStyle); for (let j = 0; j < hh; j++) for (let i = 0; i < ww; i++) put(x + i, y + j, r, g, b, 255); },
  };
  c.getContext = (kind = '2d') => (kind === '2d' ? ctx : null);
  return c;
}
// a WebGL2 stand-in that really draws: it keeps the buffers, the atlas texture and a framebuffer, and rasterizes each drawElements as a
// GPU does (pixel centres, one owner for a pixel on an edge two triangles share, texelFetch, premultiplied source-over). The vertex
// shader's job (p in canvas pixels from the top left) is taken as gl.js writes it; the shaders themselves run only in a browser.
// o: none (no WebGL2), throws, compiles: false, maxTex, raster: false (count calls only, for the timing run)
const GLK = Object.fromEntries(['VERTEX_SHADER', 'FRAGMENT_SHADER', 'COMPILE_STATUS', 'LINK_STATUS', 'ARRAY_BUFFER', 'ELEMENT_ARRAY_BUFFER', 'DYNAMIC_DRAW', 'STATIC_DRAW', 'FLOAT', 'UNSIGNED_BYTE',
  'UNSIGNED_SHORT', 'TRIANGLES', 'TEXTURE0', 'TEXTURE_2D', 'RGBA8', 'RGBA', 'TEXTURE_MIN_FILTER', 'TEXTURE_MAG_FILTER', 'NEAREST', 'TEXTURE_WRAP_S', 'TEXTURE_WRAP_T', 'CLAMP_TO_EDGE',
  'UNPACK_PREMULTIPLY_ALPHA_WEBGL', 'BLEND', 'ONE', 'ONE_MINUS_SRC_ALPHA', 'COLOR_BUFFER_BIT', 'MAX_TEXTURE_SIZE'].map((k, i) => [k, 0x9000 + i]));
function fakeGl(o = {}) {
  const K = GLK, raster = o.raster !== false, LOC = { p: 0, t: 1, c: 2 };
  const g = { ...K, n: { draw: 0, upload: 0, clear: 0 }, bound: {}, attrs: {}, uni: {}, tex: null, texW: 0, pre: false, fb: null, fbW: 0, fbH: 0, clearC: [0, 0, 0, 0], shaders: [] };
  const vert = (i) => {
    const b = g.bound[K.ARRAY_BUFFER].bytes, dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const A = (l) => { const a = g.attrs[l], at = i * a.stride + a.off; return Array.from({ length: a.size }, (_, k) => (a.type === K.FLOAT ? dv.getFloat32(at + k * 4, true) : dv.getUint8(at + k) / (a.norm ? 255 : 1))); };
    return { p: A(0), t: A(1), c: A(2) };
  };
  // a pixel centre exactly on an edge belongs to the triangle that walks that edge downwards (or leftwards when flat): the two triangles
  // of a quad walk their shared diagonal in opposite directions, so each such pixel is drawn once
  const E = (ax, ay, bx, by, px, py) => (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  function tri(a, b, c) {
    const [x0, y0] = a.p, [x1, y1] = b.p, [x2, y2] = c.p, area = E(x0, y0, x1, y1, x2, y2); if (!area) return;
    const s = Math.sign(area), den = s * area, own = (ux, uy, vx, vy) => { const dx = (vx - ux) * s, dy = (vy - uy) * s; return dy > 0 || (dy === 0 && dx < 0); };
    const o0 = own(x1, y1, x2, y2), o1 = own(x2, y2, x0, y0), o2 = own(x0, y0, x1, y1), T = [a.t, b.t, c.t], C = [a.c, b.c, c.c], tex = g.tex, fb = g.fb;
    const Y0 = Math.max(0, Math.floor(Math.min(y0, y1, y2))), Y1 = Math.min(g.fbH, Math.ceil(Math.max(y0, y1, y2))), X0 = Math.max(0, Math.floor(Math.min(x0, x1, x2))), X1 = Math.min(g.fbW, Math.ceil(Math.max(x0, x1, x2)));
    for (let Y = Y0; Y < Y1; Y++) for (let X = X0; X < X1; X++) {
      const px = X + 0.5, py = Y + 0.5;
      const w0 = s * E(x1, y1, x2, y2, px, py); if (w0 < 0 || (w0 === 0 && !o0)) continue;
      const w1 = s * E(x2, y2, x0, y0, px, py); if (w1 < 0 || (w1 === 0 && !o1)) continue;
      const w2 = s * E(x0, y0, x1, y1, px, py); if (w2 < 0 || (w2 === 0 && !o2)) continue;
      const lerp = (V, k) => (w0 * V[0][k] + w1 * V[1][k] + w2 * V[2][k]) / den;
      const ti = (Math.floor(lerp(T, 1)) * g.texW + Math.floor(lerp(T, 0))) * 4, d = (Y * g.fbW + X) * 4, sa = (tex[ti + 3] / 255) * lerp(C, 3); if (!sa) continue;
      for (let k = 0; k < 3; k++) fb[d + k] = Math.round(tex[ti + k] * lerp(C, k) + fb[d + k] * (1 - sa));
      fb[d + 3] = Math.round(sa * 255 + fb[d + 3] * (1 - sa));
    }
  }
  return Object.assign(g, {
    getParameter: (k) => (k === K.MAX_TEXTURE_SIZE ? (o.maxTex ?? 4096) : 0),
    createShader: (type) => ({ type }), shaderSource: (sh, src) => { sh.src = src; g.shaders.push(src); }, compileShader: () => {}, getShaderParameter: () => o.compiles !== false,
    createProgram: () => ({}), attachShader: () => {}, linkProgram: () => {}, getProgramParameter: () => true, useProgram: () => {},
    createVertexArray: () => ({}), bindVertexArray: () => {}, createBuffer: () => ({ bytes: null }), bindBuffer: (t, b) => { g.bound[t] = b; },
    bufferData: (t, d) => { g.bound[t].bytes = typeof d === 'number' ? new Uint8Array(d) : new Uint8Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength)); },
    bufferSubData: (t, off, src, so = 0, len = src.length - so) => { const k = src.BYTES_PER_ELEMENT; if (raster) g.bound[t].bytes.set(new Uint8Array(src.buffer, src.byteOffset + so * k, len * k), off); },
    getAttribLocation: (p, name) => LOC[name], enableVertexAttribArray: () => {}, vertexAttribPointer: (l, size, type, norm, stride, off) => { g.attrs[l] = { size, type, norm, stride, off }; },
    activeTexture: () => {}, bindTexture: () => {}, createTexture: () => ({}), texParameteri: () => {},
    texStorage2D: (t, lv, f, w, h) => { g.texW = w; g.tex = raster ? new Uint8Array(w * h * 4) : null; },
    pixelStorei: (k, v) => { if (k === K.UNPACK_PREMULTIPLY_ALPHA_WEBGL) g.pre = !!v; },
    texSubImage2D: (t, lv, x, y, ...r) => {
      g.n.upload++; if (!raster) return;
      const [w, h, px] = r.length === 5 ? [r[0], r[1], r[4]] : [r[2].width, r[2].height, r[2].data];
      for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) { const s = (j * w + i) * 4, d = ((y + j) * g.texW + x + i) * 4, al = px[s + 3] / 255; for (let k = 0; k < 3; k++) g.tex[d + k] = g.pre ? Math.round(px[s + k] * al) : px[s + k]; g.tex[d + 3] = px[s + 3]; }
    },
    getUniformLocation: (p, name) => name, uniform1i: (l, v) => { g.uni[l] = v; }, uniform2f: (l, a, b) => { g.uni[l] = [a, b]; },
    enable: () => {}, blendFunc: (sf, df) => { g.blend = [sf, df]; },
    viewport: (x, y, w, h) => { if (w !== g.fbW || h !== g.fbH) { g.fbW = w; g.fbH = h; g.fb = new Uint8ClampedArray(w * h * 4); } },
    clearColor: (...c) => { g.clearC = c.map((v) => Math.round(v * 255)); }, clear: () => { g.n.clear++; if (raster && g.fb) for (let i = 0; i < g.fb.length; i += 4) g.fb.set(g.clearC, i); },
    drawElements: (mode, count, type, off) => { g.n.draw++; if (!raster) return; const ix = g.bound[K.ELEMENT_ARRAY_BUFFER].bytes, I = new Uint16Array(ix.buffer, ix.byteOffset, ix.byteLength / 2); for (let q = off / 2; q < off / 2 + count; q += 3) tri(vert(I[q]), vert(I[q + 1]), vert(I[q + 2])); },
  });
}
// a page canvas that can give WebGL2 (the fake) or Canvas2D, never both, as a browser's canvas does; gl.js may swap it for a fresh one
function glCanvas(w, h, o = {}) {
  const c = pxCanvas(w, h), two = c.getContext; let gl = null;
  Object.assign(c, { listeners: {}, parentNode: {}, addEventListener: (k, f) => { c.listeners[k] = f; }, cloneNode: () => glCanvas(w, h), replaceWith: (n) => { c.replacedBy = n; } });
  c.getContext = (kind, opts) => {
    if (kind !== 'webgl2') return gl ? null : two(kind);
    if (o.throws) throw new Error('no WebGL2'); if (o.none) return null;
    if (opts) c.opts = opts; return (gl ||= fakeGl(o));
  };
  return c;
}
// pixels that differ between a Canvas2D canvas and the fake's framebuffer (both opaque or clear here: the art has no part-transparent pixel)
const pxDiff = (a, b) => { let n = 0; for (let i = 0; i < a.length; i += 4) if (a[i] !== b[i] || a[i + 1] !== b[i + 1] || a[i + 2] !== b[i + 2] || a[i + 3] !== b[i + 3]) n++; return n; };
GL.INFO.lost = false;
const pxKit = makeKit(P, pxCanvas);
// one case: two stages built the same way (one per renderer), ticked together, every frame compared
const GL_SAME = [];
function sameScene(name, build, frames, dt) {
  const s2 = build(), sg = build(), c2 = pxCanvas(s2.W, STAGE.h), cg = glCanvas(sg.W, STAGE.h), R = GL.glStage(cg, () => {}), gl = cg.getContext('webgl2');
  const row = { name, frames: 0, diff: 0, calls: [], lit: 1 };
  for (let f = 0; f < frames; f++) {
    if (f) { stageTick(s2, dt); stageTick(sg, dt); }
    const d0 = gl.n.draw, c0 = gl.n.clear; paintStage(c2.getContext('2d'), s2, pxKit); paintStage(R, sg, pxKit);
    row.frames++; row.diff += pxDiff(c2.data, gl.fb); row.calls.push(gl.n.draw - d0 + 10 * (gl.n.clear - c0));
    let lit = 0; for (let i = 3; i < gl.fb.length; i += 4) if (gl.fb[i]) lit++; row.lit = Math.min(row.lit, lit / (gl.fb.length / 4));
  }
  GL_SAME.push(row); return row;
}
const runnerEv = [{ type: 'job.done', job: 'J39', ts: new Date(Date.parse('2026-10-22T12:00:00Z')).toISOString() }];
for (const hour of [6, 12, 19, 23]) sameScene(`busy floor at ${hour}:00`, () => {
  const st = stageNew(); st.W = 224; const Lb = layoutScene(busy, runnerEv, {}, Date.parse(`2026-10-22T${String(hour).padStart(2, '0')}:00:00`));
  stageSync(st, Lb); stageSync(st, { ...Lb, runners: [{ key: 'oJ55@x', id: 'J55' }] }); return st;
}, 12, 50);
for (const [name, s] of [['every prop', fullState()], ['paused', { ...fullState(), paused: true }], ['stop-work order', { ...fullState(), breaker: true }]]) sameScene(name, () => { const st = stageNew(); st.W = 256; stageSync(st, layoutScene(s, fullEvents(), {}, T0)); return st; }, 4, 120);
sameScene('every moment', () => {
  const st = stageNew(); st.W = 192; stageSync(st, layoutScene({ ...busy, ...fullState(), jobs: busy.jobs }, [], {}, T0));
  stageSync(st, layoutScene({ ...busy, jobs: [...busy.jobs, job('J71', { status: 'waiting-approval', approval: { id: 'A7' } }), job('J74', { status: 'quarantined' })] }, mEv, {}, T0)); return st;
}, 30, 60);
const sameFrames = GL_SAME.reduce((n, r) => n + r.frames, 0), sameDiff = GL_SAME.reduce((n, r) => n + r.diff, 0);
check(`GlSameScene: renders the same scene as Canvas2D on a fixture (${GL_SAME.length} cases: ${GL_SAME.map((r) => r.name).join(', ')}; ${sameFrames} frames compared pixel by pixel, ${sameDiff} pixels differ)`,
  sameDiff === 0 && sameFrames >= 70 && GL_SAME.every((r) => r.lit > 0.95));
check(`GlOneDraw: each frame clears once and is one draw call (${GL_SAME.flatMap((r) => r.calls).filter((n) => n === 11).length} of ${sameFrames} frames)`,
  GL_SAME.every((r) => r.calls.every((n) => n === 11)));   // 10 x clears + draws
// the atlas filling up mid-frame, and a frame over MAX_QUADS: the queued quads are drawn first, so the picture still matches
const slabs = Array.from({ length: 50 }, (_, i) => { const c = pxCanvas(300, 300); c.getContext().fillStyle = '#' + ((Math.imul(i + 1, 2654435761) >>> 8) & 0xffffff).toString(16).padStart(6, '0'); c.getContext().fillRect(0, 0, 300, 300); return c; });
const ref = pxCanvas(420, 320), fc = glCanvas(420, 320), glFR = GL.glStage(fc), fgl = fc.getContext('webgl2');
for (const [i, c] of slabs.entries()) for (const x of [ref.getContext(), glFR]) { x.drawImage(c, i * 2, i); x.drawImage(c, 10, 10, 40, 30, 300 + (i % 3) * 5, 200 + i, 40, 30); }
glFR.flush();
const glCrowd = pxCanvas(64, 48), cc = glCanvas(64, 48), glCR = GL.glStage(cc), cgl = cc.getContext('webgl2');
for (let i = 0; i < GL.MAX_QUADS + 300; i++) for (const x of [glCrowd.getContext(), glCR]) { x.fillStyle = '#' + ((i * 40503) & 0xffffff).toString(16).padStart(6, '0'); x.fillRect(i % 61, (i * 7) % 45, 3, 3); }
glCR.flush();
check(`GlAtlasFull: when the atlas fills mid-frame (${glFR.resets} restart, ${fgl.n.draw} draw calls) and when a frame passes ${GL.MAX_QUADS} quads (${cgl.n.draw} draw calls), the picture still matches Canvas2D (${pxDiff(ref.data, fgl.fb)} and ${pxDiff(glCrowd.data, cgl.fb)} pixels differ)`,
  glFR.resets >= 1 && fgl.n.draw >= 2 && cgl.n.draw >= 2 && pxDiff(ref.data, fgl.fb) === 0 && pxDiff(glCrowd.data, cgl.fb) === 0);
// no WebGL2: glStage says so and the canvas can still draw with Canvas2D (a fresh one when gl.js gave up after taking the context)
const FALL = [['no WebGL2', { none: true }, /no WebGL2/], ['getContext throws', { throws: true }, /no WebGL2/], ['the shaders do not build', { compiles: false }, /shaders/], ['textures under 2048 px', { maxTex: 1024 }, /2048/]]
  .map(([name, o, why]) => { const c = glCanvas(32, 16, o), r = GL.glStage(c), two = (c.replacedBy || c).getContext('2d'); return { name, ok: r === null && why.test(GL.INFO.why) && !GL.INFO.on && !!two && two.fillRect !== undefined, swapped: !!c.replacedBy }; });
const sceneSrc = fs.readFileSync(new URL('./public/scene.js', import.meta.url), 'utf8');
check(`GlFallback: falls back when WebGL2 is missing (${FALL.length} cases: ${FALL.map((f) => f.name + (f.ok ? '' : ' FAILED')).join(', ')}): glStage gives null, says why, and the stage draws with Canvas2D (a fresh canvas when the context was already taken: ${FALL.filter((f) => f.swapped).length})`,
  FALL.every((f) => f.ok) && FALL.filter((f) => f.swapped).length === 2 && /gl = GLM\?\.glStage\(root\.querySelector\('canvas'\), remount\), canvas = root\.querySelector\('canvas'\)/.test(sceneSrc) && /ctx: gl \|\| canvas\.getContext\('2d'\)/.test(sceneSrc));
const glLc = glCanvas(32, 16); let lostCalls = 0; const LR = GL.glStage(glLc, () => lostCalls++); glLc.listeners.webglcontextlost?.({});
let lostThrew = false; try { LR.drawImage(slabs[0], 0, 0); LR.fillRect(0, 0, 1, 1); LR.flush(); } catch { lostThrew = true; }
const afterLost = GL.glStage(glCanvas(32, 16)), lostWhy = GL.INFO.why;
check(`GlContextLost: a lost WebGL2 context falls back to Canvas2D for the rest of the visit (onLost ran ${lostCalls} time; later stages get null: "${lostWhy}"); drawing on the lost context throws nothing`,
  lostCalls === 1 && LR.lost && GL.INFO.lost && !lostThrew && afterLost === null && /lost/.test(lostWhy) && /const remount = \(\) => \{ for \(const el of mounted\) if \(el\._px\) \{ dropStage\(el\._px\); el\._px = null;/.test(sceneSrc));
GL.INFO.lost = false;
// behind a flag: ?gl (or ?gl=1) for this visit, Settings > About kept on this phone, ?gl=0 turns a kept one off; without it gl.js is never loaded
const FLAGS = [['', null, false], ['?gl', null, true], ['?hud&gl=1', null, true], ['', '1', true], ['?gl=0', '1', false], ['?glow', null, false], ['', '0', false], ['?fps&gl', '0', true]];
const appGl = fs.readFileSync(new URL('./public/app.js', import.meta.url), 'utf8');
check(`GlFlag: the WebGL2 renderer is behind a flag, off by default (${FLAGS.length} cases); gl.js is imported only when the flag is on, and Settings > About has its switch and says which renderer draws`,
  FLAGS.every(([q, k, want]) => glWanted(q, k) === want) && (sceneSrc.match(/import\('\.\/gl\.js'\)/g) || []).length === 2 && /glWanted\(location\.search, glk\) \? import\('\.\/gl\.js'\)/.test(sceneSrc) && /\(on \? import\('\.\/gl\.js'\) : Promise\.resolve\(null\)\)/.test(sceneSrc)
  && /id="gl-switch" \$\{sceneGl\(\) \? 'checked' : ''\}/.test(appGl) && /if \(e\.target\.id === 'gl-switch'\) return void sceneGl\(e\.target\.checked\);/.test(appGl) && /<dt>Scene renderer<\/dt>/.test(appGl));
const okC = glCanvas(8, 8); GL.glStage(okC); const okGl = okC.getContext('webgl2');
check('GlShaders: crisp pixels as on the Canvas2D stage (texelFetch at whole texels, nearest, no antialiasing), premultiplied source-over, and a software-only WebGL2 is refused (failIfMajorPerformanceCaveat)',
  /texelFetch\(tex, ivec2\(vt\), 0\) \* vc/.test(GL.FS) && /precision highp float/.test(GL.FS) && /p\.x \* 2\.0 \/ view\.x - 1\.0, 1\.0 - p\.y \* 2\.0 \/ view\.y/.test(GL.VS) && okGl.shaders.length === 2
  && okC.opts.antialias === false && okC.opts.failIfMajorPerformanceCaveat === true && okC.opts.premultipliedAlpha === true && okGl.blend.join() === [GLK.ONE, GLK.ONE_MINUS_SRC_ALPHA].join() && okGl.pre === true && GL.colorOf('#c2410c') === (0xc2 | 0x41 << 8 | 0x0c << 16 | 255 << 24) >>> 0 && GL.colorOf('nope') === (255 << 24) >>> 0);
// the frame budget (pass-app/speed/budget.json, the scene's frame work p95): a busy floor drawn every frame for 600 frames at 120 Hz
// steps, tick + draw through gl.js (the work the frame meter and the speed probe time); node has no GPU, so the GL calls cost nothing
// here: this is the CPU side the code controls. Every frame is one draw call and each strip is uploaded once (the -1: the white block for fillRect).
const target = JSON.parse(fs.readFileSync(new URL('./speed/budget.json', import.meta.url), 'utf8')).metrics.frameP95Ms.target;
const glBst = stageNew(); glBst.W = 256; stageSync(glBst, layoutScene({ ...busy, ...fullState(), jobs: busy.jobs }, runnerEv, {}, T0));
const bc = glCanvas(256, STAGE.h, { raster: false }), glBR = GL.glStage(bc), bgl = bc.getContext('webgl2'), work = [];
const seenImg = new Set(), drawImg = glBR.drawImage; glBR.drawImage = function (img) { seenImg.add(img); return drawImg.apply(this, arguments); };   // the strips and layers it was given
for (let f = 0; f < 600; f++) { const t0 = performance.now(); stageTick(glBst, 1000 / 120); paintStage(glBR, glBst, pxKit); work.push(performance.now() - t0); }
const fs95 = frameStats(work.slice(30));
check(`GlFrameBudget: frame time inside the speed budget (tick + draw p95 ${fs95.p95} ms, p50 ${fs95.p50} ms over ${fs95.n} warm frames; budget ${target} ms, a 120 Hz frame); ${bgl.n.draw} draw calls for 600 frames; ${bgl.n.upload - 1} uploads for ${seenImg.size} strips and layers drawn (each once; ${glBR.resets} atlas restarts)`,
  fs95.p95 <= target && bgl.n.draw === 600 && bgl.n.upload - 1 === seenImg.size && glBR.resets === 0);
