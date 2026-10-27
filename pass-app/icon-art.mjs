// Tide's app icon as code: a 32x32 pixel grid in the sprites.js palette (a night skyline over an ember dusk, the tide rolling in front),
// written out as public/icon.svg (16 px a pixel, crisp edges) and as the PNGs Android and iOS want (icon-192.png, icon-512.png:
// whole-pixel scales of the same grid, encoded here with zlib, no browser and no dependency).
//   node pass-app/icon-art.mjs            writes all three files
// Full bleed for "maskable"; the skyline and the wave crest sit inside the 80% safe circle.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { PALETTE } from './public/sprites.js';

const N = 32, PX = 16;

export function iconGrid() {
  const g = Array.from({ length: N }, () => Array(N).fill('N')), art = new Set();   // art: the cells of the skyline (the SVG's <g id="art">)
  const set = (x, y, c, isArt = false) => { if (x >= 0 && x < N && y >= 0 && y < N) { g[y][x] = c; if (isArt) art.add(y * N + x); else art.delete(y * N + x); } };
  // dusk: slate night at the top (not the app's own dark, so the icon's edge shows on a dark home screen), ember toward the horizon
  const band = (y) => (y < 8 ? 'f' : y < 12 ? 'q' : y < 16 ? 'r' : 's');
  // each band's first row carries every fourth pixel of the band above: a light pixel dither, no gradients
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) g[y][x] = y && band(y) !== band(y - 1) && x % 4 === 1 ? band(y - 1) : band(y);
  for (const [x, y] of [[4, 2], [9, 5], [25, 3], [29, 6], [13, 1], [22, 7]]) set(x, y, 'p');
  // towers: [left, top, width], all inside the maskable safe circle; the tallest carries a mast and a red aviation light
  const towers = [[8, 15, 3], [12, 10, 4], [17, 7, 4], [22, 12, 3]];
  for (const [l, t, w] of towers) {
    for (let y = t; y < 24; y++) for (let x = l; x < l + w; x++) set(x, y, 'a', true);
    for (let y = t + 2; y < 23; y += 2) for (let x = w > 2 ? l + 1 : l; x < (w > 2 ? l + w - 1 : l + 1); x++) if ((y * 7 + x * 3) % 4) set(x, y, (y + x) % 3 ? 't' : 'I', true);
  }
  for (let y = 5; y < 7; y++) set(18, y, 'a', true);
  set(18, 4, 'B', true);
  // the tide: rolling swells, foam on the crests, deeper water below
  const top = (x) => 23 + Math.round(1.4 * Math.sin((2 * Math.PI * (x - 2)) / 12));
  for (let x = 0; x < N; x++) {
    const t0 = top(x), crest = t0 <= top(x - 1) && t0 <= top(x + 1);
    for (let y = t0; y < N; y++) set(x, y, y === t0 ? (crest ? 'p' : 'z') : y === t0 + 1 ? (crest ? 'z' : 'y') : y < t0 + 4 ? 'y' : y === t0 + 4 && x % 2 ? 'y' : 'x');
  }
  g.art = art;
  return g;
}

// one <path> per colour, each a list of same-colour runs along a row; inArt picks the skyline cells or the background cells
function layer(g, inArt, indent) {
  const runs = new Map(), key = (x, y) => (g.art.has(y * N + x) === inArt ? g[y][x] : null);
  for (let y = 0; y < N; y++) for (let x = 0; x < N;) {
    const k = key(x, y); let e = x + 1; while (e < N && key(e, y) === k) e++;
    if (k) { const c = PALETTE[k]; if (!runs.has(c)) runs.set(c, []); runs.get(c).push(`M${x * PX} ${y * PX}h${(e - x) * PX}v${PX}h-${(e - x) * PX}z`); }
    x = e;
  }
  return [...runs].map(([c, d]) => `${indent}<path fill="${c}" d="${d.join('')}"/>`).join('\n');
}

export function iconSvg(g = iconGrid()) {
  const paths = `${layer(g, false, '  ')}
  <g id="art">
${layer(g, true, '  ')}
  </g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" shape-rendering="crispEdges">
  <!-- Tide's app icon (D-13), drawn by pass-app/icon-art.mjs: a night skyline over an ember dusk with the tide rolling in. 32x32 at 16 px a pixel,
       sprites.js palette only. Full bleed for "maskable"; the skyline and the wave crest sit inside the 80% safe circle. -->
${paths}
</svg>
`;
}

const CRC = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function chunk(type, data) {
  const len = Buffer.alloc(4), crc = Buffer.alloc(4), td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  len.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

// the grid as an RGB PNG, each pixel a scale x scale square (a whole number, so edges stay crisp)
export function iconPng(scale, g = iconGrid()) {
  const size = N * scale, row = 1 + size * 3, raw = Buffer.alloc(size * row);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const hex = PALETTE[g[Math.floor(y / scale)][Math.floor(x / scale)]], o = y * row + 1 + x * 3;
    raw[o] = parseInt(hex.slice(1, 3), 16); raw[o + 1] = parseInt(hex.slice(3, 5), 16); raw[o + 2] = parseInt(hex.slice(5, 7), 16);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2;   // 8-bit RGB, no interlace
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), 'public');
  fs.writeFileSync(path.join(pub, 'icon.svg'), iconSvg());
  fs.writeFileSync(path.join(pub, 'icon-192.png'), iconPng(6));
  fs.writeFileSync(path.join(pub, 'icon-512.png'), iconPng(16));
  console.log('icon written: icon.svg, icon-192.png, icon-512.png');
}
