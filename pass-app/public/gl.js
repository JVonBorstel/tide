// The stage's WebGL2 renderer (pass-app/SCENE.md "Renderer"): it takes the same calls as a Canvas2D context (drawImage with 3, 5 or 9
// arguments, fillRect with fillStyle), so drawStage in scene.js draws through either one unchanged. Every sprite strip and baked layer
// is copied once into one atlas texture (shelf-packed; started again when full); a frame is quads in one buffer and one drawElements.
// scene.js loads this file only behind its flag (?gl in the address, or Settings > About > WebGL2 renderer) and keeps Canvas2D when
// glStage returns null: no WebGL2, only a software WebGL2, shaders that do not build, or a lost context. No imports, no network.
export const ATLAS = 2048, MAX_QUADS = 2048;
// what the Board shows in Settings > About: on, or why not (the last reason it gave up)
export const INFO = { on: false, why: 'not tried', lost: false };
const OPTS = { alpha: true, antialias: false, depth: false, stencil: false, premultipliedAlpha: true, preserveDrawingBuffer: false, failIfMajorPerformanceCaveat: true };
// p: the corner in canvas pixels (top left is 0,0), t: the atlas texel, c: a colour the texel is multiplied by (white for sprites)
export const VS = `#version 300 es
in vec2 p; in vec2 t; in vec4 c; uniform vec2 view; out vec2 vt; out vec4 vc;
void main() { vt = t; vc = c; gl_Position = vec4(p.x * 2.0 / view.x - 1.0, 1.0 - p.y * 2.0 / view.y, 0.0, 1.0); }`;
// texelFetch at whole texels: crisp pixels with no filtering and no rounding at the atlas's edges (highp: texels up to 2048)
export const FS = `#version 300 es
precision highp float; uniform highp sampler2D tex; in vec2 vt; in vec4 vc; out vec4 o;
void main() { o = texelFetch(tex, ivec2(vt), 0) * vc; }`;
const WHITE = 0xffffffff, LE = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1;
const off = (why) => { INFO.on = false; INFO.why = why; return null; };
// '#rgb' or '#rrggbb' as one 32-bit colour in memory order (r, g, b, a); anything else is black, the Canvas2D default
export function colorOf(css) {
  let h = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(css || ''))?.[1] || '000';
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
  const n = parseInt(h, 16); return ((n >> 16) & 255 | ((n >> 8) & 255) << 8 | (n & 255) << 16 | 255 << 24) >>> 0;
}
function build(gl) {
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null; };
  const v = sh(gl.VERTEX_SHADER, VS), f = sh(gl.FRAGMENT_SHADER, FS); if (!v || !f) return null;
  const p = gl.createProgram(); gl.attachShader(p, v); gl.attachShader(p, f); gl.linkProgram(p);
  return gl.getProgramParameter(p, gl.LINK_STATUS) ? p : null;
}
// a Canvas2D-shaped context over WebGL2 on `canvas`, or null (INFO.why says why). If it gives up after taking the canvas's context, it
// puts a fresh canvas in its place (a canvas keeps the first kind of context it gave out), so the caller can ask that one for '2d'.
// onLost: called once if the browser takes the context away (the GPU reset, too many contexts); scene.js then draws with Canvas2D.
export function glStage(canvas, onLost) {
  if (INFO.lost) return off(INFO.why);
  if (!LE) return off('a big-endian device');
  let gl = null; try { gl = canvas.getContext('webgl2', OPTS); } catch { gl = null; }
  if (!gl) return off('no WebGL2 here (or only a software one)');
  const fail = (why) => { const c = canvas.cloneNode?.(false); if (c && canvas.parentNode) canvas.replaceWith(c); return off(why); };
  if (!(gl.getParameter(gl.MAX_TEXTURE_SIZE) >= ATLAS)) return fail(`textures under ${ATLAS} px`);
  const prog = build(gl); if (!prog) return fail('the shaders did not build');
  gl.useProgram(prog);
  const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
  // the quads: 4 corners of 20 bytes each (x, y, u, v as floats, the colour as 4 bytes); the index buffer is made once
  const buf = new ArrayBuffer(MAX_QUADS * 4 * 20), F = new Float32Array(buf), U = new Uint32Array(buf);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer()); gl.bufferData(gl.ARRAY_BUFFER, buf.byteLength, gl.DYNAMIC_DRAW);
  const attr = (name, size, type, norm, offset) => { const l = gl.getAttribLocation(prog, name); gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, size, type, norm, 20, offset); };
  attr('p', 2, gl.FLOAT, false, 0); attr('t', 2, gl.FLOAT, false, 8); attr('c', 4, gl.UNSIGNED_BYTE, true, 16);
  const idx = new Uint16Array(MAX_QUADS * 6);
  for (let q = 0; q < MAX_QUADS; q++) idx.set([q * 4, q * 4 + 1, q * 4 + 2, q * 4 + 2, q * 4 + 1, q * 4 + 3], q * 6);
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.createBuffer()); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW);
  // the atlas: a 2x2 white block at 0,0 (fillRect's colour source), then strips and layers on shelves with a 1 px gutter
  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, ATLAS, ATLAS);
  for (const k of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_2D, k, gl.NEAREST);
  for (const k of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T]) gl.texParameteri(gl.TEXTURE_2D, k, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 2, 2, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(16).fill(255));
  gl.uniform1i(gl.getUniformLocation(prog, 'tex'), 0);
  const view = gl.getUniformLocation(prog, 'view');
  gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);   // premultiplied source-over, as Canvas2D draws
  // the shelf packer: a strip or layer canvas never changes once made, so it is uploaded once per atlas generation
  let slots = new WeakMap(), gen = 0, ax = 3, ay = 0, rowH = 2, n = 0, fresh = true, lastCss = null, lastCol = 0;
  const R = { kind: 'webgl2', canvas, fillStyle: '#000000', imageSmoothingEnabled: false, frames: 0, calls: 0, uploads: 0, resets: 0, lost: false };
  function submit() {
    if (!n) return;
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, F, 0, n * 20); gl.drawElements(gl.TRIANGLES, n * 6, gl.UNSIGNED_SHORT, 0); R.calls++; n = 0;
  }
  function slotOf(img) {
    const s = slots.get(img); if (s && s.g === gen) return s;
    const w = img.width, h = img.height; if (!(w > 0 && h > 0) || w + 1 > ATLAS || h + 1 > ATLAS) return null;
    if (ax + w > ATLAS) { ax = 0; ay += rowH + 1; rowH = 0; }
    if (ay + h > ATLAS) { submit(); gen++; R.resets++; ax = 3; ay = 0; rowH = 2; slots = new WeakMap(); }   // full: draw what is queued, start again
    gl.texSubImage2D(gl.TEXTURE_2D, 0, ax, ay, gl.RGBA, gl.UNSIGNED_BYTE, img); R.uploads++;
    const t = { x: ax, y: ay, g: gen }; slots.set(img, t); ax += w + 1; rowH = Math.max(rowH, h); return t;
  }
  function quad(dx, dy, dw, dh, u, v, uw, vh, col) {
    if (R.lost) return;
    if (fresh) { fresh = false; const W = canvas.width, H = canvas.height; gl.viewport(0, 0, W, H); gl.uniform2f(view, W, H); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT); }
    if (n === MAX_QUADS) submit();
    let i = n * 20; n++;
    for (let k = 0; k < 4; k++, i += 5) { const r = k & 1, b = k >> 1; F[i] = dx + r * dw; F[i + 1] = dy + b * dh; F[i + 2] = u + r * uw; F[i + 3] = v + b * vh; U[i + 4] = col; }
  }
  // (no array per call: a frame allocates nothing, as in scene.js)
  R.drawImage = function (img, a, b, c, d, e, f, g, h) {
    if (!img || R.lost) return;
    const s = slotOf(img), k = arguments.length; if (!s) return;
    if (k >= 9) quad(e, f, g, h, s.x + a, s.y + b, c, d, WHITE);
    else if (k >= 5) quad(a, b, c, d, s.x, s.y, img.width, img.height, WHITE);
    else quad(a, b, img.width, img.height, s.x, s.y, img.width, img.height, WHITE);
  };
  R.fillRect = (x, y, w, h) => { if (R.fillStyle !== lastCss) { lastCss = R.fillStyle; lastCol = colorOf(lastCss); } quad(x, y, w, h, 0.5, 0.5, 0, 0, lastCol); };
  // the end of a frame: one draw call for everything queued (more only if a frame passed MAX_QUADS or filled the atlas)
  R.flush = () => { submit(); if (!fresh) R.frames++; fresh = true; };
  canvas.addEventListener?.('webglcontextlost', () => { R.lost = INFO.lost = true; off('the graphics context was lost'); onLost?.(); }, { once: true });
  INFO.on = true; INFO.why = ''; return R;
}
