// Chef's pixel art as code (spec: gemini-brain projects/tide/specs/chef-art.md): one palette, every sprite as palette-indexed strings or a tiny drawing recipe, the decoder, the atlas, palette swaps and the interface chrome sprites. All original art.
// Loaded by pass-app/public/scene.js (dynamic import: the still card stays if it cannot load); tested by pass-app/test-scene.mjs. No network, no images.
// Style: 16x16 tiles, characters 16x24, 3-4 shade ramps per material, 1px warm outline ('a'), light from the top left.

// ---- the palette: one character per pixel; '.' is transparent ----
export const PALETTE = {
  a: '#2b1d1a',                                                     // outline: a warm near-black, never pure black
  b: '#5a2f22', c: '#8a4b2c', d: '#b8743f', e: '#e0a96a',           // wood
  f: '#2f3a4a', g: '#59677a', h: '#93a3b4', i: '#d3dde6',           // steel (and trousers)
  j: '#3a2f2c', k: '#6e5a4e', l: '#a8927e', m: '#d6c3a8',           // stone floor
  n: '#b9ad99', o: '#e6dccb', p: '#fffaf0', W: '#ffffff',           // cream, paper, white
  q: '#7a1f12', r: '#c2410c', s: '#f08a24', t: '#ffd36b',           // ember and flame (the app's ember is r)
  u: '#24533a', v: '#3f8a4a', w: '#8cc96a',                         // leaf
  x: '#23406e', y: '#4f86c6', z: '#9fd3f0',                         // water and glass
  A: '#8e1f1f', B: '#d8443a', C: '#f0907a',                         // tomato red, blush
  D: '#2a201e', E: '#3d2f2a', F: '#54423a',                         // the back wall
  I: '#f4e3b5', K: '#e2805a',                                       // lamp light, warm glow
  N: '#1a1412', O: '#2b211d', Q: '#3d302a', V: '#0d0a09',           // the dark interface ramp
  G: '#f1f59a', H: '#d4dd3c', J: '#9aa52a',                         // hi-vis yellow (vests, runners' hats; not EMISSIVE, so it dims)
  // swap slots, replaced per character, per cook and per sky (paletteFor); these are the defaults
  1: '#a86f48', 2: '#d39a6a', 3: '#efc39a',                         // skin: shadow, base, light
  4: '#8a6512', 5: '#d6a531', 6: '#f2d27a',                         // the crew's colour: hard hat, vest badge
  7: '#2a1a14', 8: '#4a3020',                                       // hair
  X: '#4f86c6', Y: '#7fb3e0', Z: '#bfe3fb',                         // the sky in the window: top, middle, bottom
};
export const EMISSIVE = 'stIKXYZW';                                 // light sources keep their colour at night (no tint)
export const SKIES = { dawn: ['#e0805f', '#f0a77f', '#ffe2b0'], day: ['#4f86c6', '#7fb3e0', '#bfe3fb'], dusk: ['#3d2e5c', '#a8506a', '#e2805a'], night: ['#0b1022', '#141c3a', '#1f2a48'] };
const TINT = { dawn: ['#f0a070', 0.08], day: null, dusk: ['#5a2f5c', 0.16], night: ['#141a3a', 0.32] };
const DIM = ['#0d0a14', 0.34];
export const HAIR = [['#2a1a14', '#4a3020'], ['#5a2a14', '#8a4a24'], ['#6e5a4e', '#a8927e'], ['#1a1a24', '#34344a']];
// frames per animation, as declared (the tests hold every sprite to these)
export const FRAMES = { still: 1, walk: 4, idle: 2, work: 4, flame: 3, steam: 4, sparkle: 4, bell: 2, sleep: 2, lantern: 2, glyph: 10, icon: 6, jars: 3,
  // world props: sign 3, clock hands 12, coin jar 9, heat lamp 3, fuse 2, tally 0-10, recipe cards 0-4
  sign: 3, hand: 12, jar: 9, heat: 3, fuse: 2, tally: 11, cards: 5,
  // moments (wave 2): pan flip 4, puff 4, dark smoke 6, confetti 3 colours
  flip: 4, puff: 4, smoke6: 6, confetti: 3 };
export const TIMING = { walk: 140, idle: 450, work: 120, flame: 110, steam: 260, sparkle: 90, sleep: 900, lantern: 500, bell: 160 };   // ms per frame

// ---- colour helpers (hue-shifted ramps: cool purple shadows, warm cream highlights) ----
const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const hex = (c) => '#' + c.map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('');
export const mix = (a, b, t) => { const x = rgb(a), y = rgb(b); return hex(x.map((v, i) => v + (y[i] - v) * t)); };
export const ramp3 = (base) => [mix(base, '#3a1830', 0.38), base, mix(base, '#fff3d6', 0.4)];
// the palette for one character / one sky: skin, cook colour and hair swapped in, then the room light (a palette shift, not a filter)
export function paletteFor({ skin, cook, hair = 0, sky = 'day', accent, dim = false } = {}) {
  const p = { ...PALETTE };
  if (skin) [p[1], p[2], p[3]] = ramp3(skin);
  if (cook) [p[4], p[5], p[6]] = ramp3(cook);
  if (accent) [p[4], p[5], p[6]] = accent;
  [p[7], p[8]] = HAIR[hair % HAIR.length];
  [p.X, p.Y, p.Z] = SKIES[sky] || SKIES.day;
  const t = TINT[sky];
  if (t) for (const k of Object.keys(p)) if (!EMISSIVE.includes(k)) p[k] = mix(p[k], t[0], t[1]);
  // dim: CLOSED, the room lights are down (light sources keep their colour)
  if (dim) for (const k of Object.keys(p)) if (!EMISSIVE.includes(k)) p[k] = mix(p[k], DIM[0], DIM[1]);
  return p;
}

// ---- drawing recipes (used by the procedural sprites below) ----
const grid = (w, h) => Array.from({ length: h }, () => Array(w).fill('.'));
const put = (g, x, y, c) => { if (c !== '.' && y >= 0 && y < g.length && x >= 0 && x < g[0].length) g[y][x] = c; };
const rect = (g, x, y, w, h, c) => { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) put(g, x + i, y + j, c); };
const blit = (g, rows, x = 0, y = 0) => rows.forEach((r, j) => [...r].forEach((c, i) => put(g, x + i, y + j, c)));
// a bevelled block: 1px outline, light top-left inner edge, dark bottom-right inner edge; round = the outline corners cut
function box(g, x, y, w, h, [d, m, l], round = false, o = 'a') {
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) {
    const edge = i === 0 || j === 0 || i === w - 1 || j === h - 1;
    if (round && (i === 0 || i === w - 1) && (j === 0 || j === h - 1)) continue;
    put(g, x + i, y + j, edge ? o : (j === 1 || i === 1) ? l : (j === h - 2 || i === w - 2) ? d : m);
  }
}
const WOOD = ['c', 'd', 'e'], DARKWOOD = ['b', 'c', 'd'], STEEL = ['g', 'h', 'i'], IRON = ['f', 'g', 'h'], PAPER = ['n', 'o', 'p'], STONE = ['k', 'l', 'm'];
// a strip: frames side by side, separated by one space (so an animation reads left to right in the source)
const strip = (rows, n) => Array.from({ length: n }, (_, f) => rows.map((r) => r.split(' ')[f]));

// ---- characters, in parts: head (12 rows), torso (6 rows, drawn over the hips), legs (7 rows, 4 walk frames) ----
// crew: a hard hat in the crew's colour (4/5/6: a ridge down the middle, light from the left), the brim over the eyes; runners: a
// hi-vis yellow hard hat (G/H/J). Torsos: a blue work shirt, a hi-vis vest with a reflective stripe (i) and the crew's colour on the
// chest badge, a tool belt; runners wear a grey shirt and the same vest
const HAT = ['.....aaaaaa.....', '...aa665455aa...', '..a6665545554a..', '..a6655545554a..', '.a665555555554a.', 'aa444444444444aa'];
const HAT_SIDE = ['.....aaaaa......', '....a66545a.....', '...a6655455a....', '...a6555455a....', '..a65555554a....', '..a4444444444a..'];
const hiVis = (rows) => rows.map((r) => r.replace(/[46]/g, (c) => (c === '6' ? 'G' : 'J')).replace(/5/g, 'H'));
const E2 = ['................', '................'];
const FACE = ['...a2a2222a1a...', '...aC22222C1a...', '...a222qq221a...', '....a111111a....'], FACE_SIDE = ['....a8722a2a....', '....a81222C2a...', '....a81222qa....', '.....a1111a.....'];
const HEAD = {
  down: [...E2, ...HAT, ...FACE],
  up: [...E2, ...HAT, '...a88888887a...', '...a78888877a...', '...a17777771a...', '....a111111a....'],
  side: [...E2, ...HAT_SIDE, ...FACE_SIDE],
  sleep: [...E2, '................', ...HAT, '...aC22222C1a...', '...a2222a221a...', '....a111111a....'],   // asleep: the hat tipped over the eyes
  waiterDown: [...E2, '................', ...hiVis(HAT.slice(1)), ...FACE],
  waiterSide: [...E2, '................', ...hiVis(HAT_SIDE.slice(1)), ...FACE_SIDE],
};
const TORSO = {
  down: ['..aayyHHHHyyaa..', '.ayyGHHHHHHJyya.', '.ayGiiiiiiiiJya.', '.a2GHH5HHHHHJ2a.', '..aaGHHHHHHJaa..', '...accchcccca...'],
  up: ['..aayyHHHHyyaa..', '.ayyGHHHHHHJyya.', '.ayGiiiiiiiiJya.', '.a2GHHHHHHHHJ2a.', '..aaGHHHHHHJaa..', '...acccccccca...'],
  side: ['....aayHHHHa....', '...ayyGHHHHJa...', '...ayGiiiiiJa...', '...ay22HH5HJa...', '....aGHHHHJa....', '....acchcccca...'],
  waiterDown: ['..aaggHHHHggaa..', '.aggGHHHHHHJgga.', '.agGiiiiiiiiJga.', '.a2GHHHHHHHHJ2a.', '..aaGHHHHHHJaa..', '...affffffffa...'],
  waiterSide: ['....aagHHHHa....', '...aggGHHHHJa...', '...agGiiiiiJa...', '...ag22HHHHJa...', '....aGHHHHJa....', '....affffffa....'],
};
const LEGS = {
  down: strip(['...agggggggga... ...agggggggga... ...agggggggga... ...agggggggga...', '....agfaagfa.... ....agfaagfa.... ....agfaagfa.... ....agfaagfa....',
    '....agfaagfa.... ....agfaagfa.... ....agfaagfa.... ....agfaagfa....', '....agfaagfa.... ....ajjaagfa.... ....agfaagfa.... ....agfaajja....',
    '....agfaagfa.... ....aaaaagfa.... ....agfaagfa.... ....agfaaaaa....', '....ajjaajja.... ........ajja.... ....ajjaajja.... ....ajja........',
    '....aaaaaaaa.... ........aaaa.... ....aaaaaaaa.... ....aaaa........'], 4),
  side: strip(['.....aggggga.... .....aggggga.... .....aggggga.... .....aggggga....', '.....agffga..... .....agffga..... .....agffga..... .....agffga.....',
    '....agfa.agfa... .....agffga..... ....afga.afga... .....agffga.....', '...agfa...agfa.. .....agfgfa..... ...afga...afga.. .....agfgfa.....',
    '...agfa...agfa.. .....ajjgfa..... ...afga...afga.. .....agajjja....', '..ajjja...ajjja. .....aaaajjja... ..ajjja...ajjja. .....ajjjaaa....',
    '..aaaaa...aaaaa. ........aaaaa... ..aaaaa...aaaaa. .....aaaa.......'], 4),
  sit: [['................', '..agggggggggga..', '.agffffffffffga.', '.aggaaaaaaaagga.', '.ajja......ajja.', '.aaaa......aaaa.', '................']],
};
export const BOB = { walk: [0, -1, 0, -1], idle: [0, 1], sleep: [0, 1] };
// one character frame: legs, then torso over the hips, then the head; a bob lifts or drops the upper body by a pixel
function body(g, head, torso, legs, bob) { blit(g, legs, 0, 17); blit(g, torso, 0, 12 + bob); blit(g, head, 0, bob); }
const STACHE = ['7887'];

// ---- small authored pieces: the hands and the site tools (pencil, hammer, magnifier, test probe, crate label) ----
const HAND = ['.aaa.', 'a222a', 'a221a', '.aaa.'];
const PENCIL = ['.a.', 'aka', 'aea', 'aGa', 'aGa', 'aBa'];
const HAMMER = ['aaaa.', 'aghha', 'aaca.', '..c..', '..c..'];
const LENS = ['aaa', 'aza', 'aaa', '.c.', '.c.'];
const PROBE = ['aaa.', 'aBBa', 'aaa.'];
const LABEL = ['aaa', 'apa', 'aaa'];
const PAN = ['...aaa...', '..a.a.a..', '...aaa...', '.aaaaaaa.', 'aeeeeeeea', 'adeeeeeda', 'addddddda', 'acdddddca', '.accccca.', '..aaaaa..'];
const JAR = strip(['.aaa. .aaa. .aaa.', '.aca. .aca. .aca.', 'aaaaa aaaaa aaaaa', 'awvva atssa azyya', 'avvua assra ayyxa', 'avvua assra ayyxa', '.aaa. .aaa. .aaa.'], 3);
const CLOCHE = ['....aa....', '...aiia...', '..aaaaaa..', '.aiiiihha.', 'aiiihhhhga', 'ahhhhhggga', 'aaaaaaaaaa', '.agggggga.'];
const SUN = ['.ttt.', 'ttttt', 'ttWtt', 'ttttt', '.ttt.'];
const MOON = ['.II..', 'II...', 'II...', 'II...', '.II..'];
const DIGITS = strip(['aaa .a. aaa aaa a.a aaa aaa aaa aaa aaa', 'a.a aa. ..a ..a a.a a.. a.. ..a a.a a.a', 'a.a .a. aaa aaa aaa aaa aaa ..a aaa aaa',
  'a.a .a. a.. ..a ..a ..a a.a ..a a.a ..a', 'aaa aaa aaa aaa ..a aaa aaa ..a aaa aaa'], 10);
const ICONS = strip([
  '............ ...a....5... ............ ............ .aaaaaaaa... ....aaaa....',
  'aaaaaaaaaaaa ...a..5..5.. ..........a. ....aaaa.... .a6ppppoa... .aaaa65aaaa.',
  'a6655555554a ..aaaaaaaa.. .........a5a ...a66a5a... .a6aaapoa... .appaaaappa.',
  'aaaaaaaaaaaa ..a665555a.. ........a5a. ..a665a55a.. .a6ppppoa... .apppppppoa.',
  'apppppppppoa ..a6pppo5a.. a......a5a.. .a6655a555a. .a6aaaaoa... .appp55ppoa.',
  'apaaaapaaaoa ..a6onno5a.. 5a....a5a... .a6555a554a. .a6ppppoa... .ap555555oa.',
  'apppppppppoa ..a555555a.. .5a..a5a.... .a5555a554a. .a6aaapoa... .ap555555oa.',
  'apaaaaapppoa ..a5a5a54a.. ..5aa5a..... aaaaaaaaaaaa .a6ppppaaa.. .appp55ppoa.',
  'aonnnnnnnnna ..a55a5a4a.. ...55a...... a6555555554a .a6pppa665a. .appp44ppoa.',
  'aaaaaaaaaaaa ..a5a5a54a.. ............ aaaaaaaaaaaa .a6pppa654a. .apppppppoa.',
  '.a4a....a4a. ..a444444a.. a.a.a.a.a.a. ............ .aaaaaa554a. .aonnnnnnna.',
  '.aaa....aaa. ..aaaaaaaa.. ............ ............ .......aaa.. .aaaaaaaaaa.'], 6);
// steam: dust rising off the workbench; sparkle: a glint (also the desk lamp); flame: weld sparks; bubble: a test rig LED
const PARTICLE = {
  steam: strip(['..... ..... .l... l.l..', '..... .ml.. mlm.. ...l.', '..m.. .mml. .mlm. l..l.', '.mml. ..m.. ..l.. .....', '..... ..... ..... .....'], 4),
  sparkle: strip(['..... ..t.. ..W.. .....', '..... ..t.. .tWt. ..t..', '..W.. ttWtt WWWWW .tWt.', '..... ..t.. .tWt. ..t..', '..... ..t.. ..W.. .....'], 4),
  flame: strip(['t..s.. .t...s s...t.', '.t.t.. ..ts.. .t.t..', '..tWs. .sWt.. ..Wts.', '...s.. ...t.. .s....'], 3),
  zz: [['aaaa', '..a.', '.a..', 'aaaa'].map((r) => r.replace(/a/g, 'p'))],
  bubble: [['.s.', 'sts', '.s.']],
};

// ---- every sprite: { w, h, anim, draw(grid, frame) } or { w, h, anim, frames } ----
const S = {};
const add = (name, w, h, anim, draw) => { S[name] = { w, h, anim, draw }; };
const addFrames = (name, frames, anim) => { S[name] = { w: frames[0][0].length, h: frames[0].length, anim, frames }; };
for (const d of ['down', 'up', 'side']) add('chef-' + d, 16, 24, 'walk', (g, f) => body(g, HEAD[d], TORSO[d], LEGS[d === 'side' ? 'side' : 'down'][f], BOB.walk[f]));
add('chef-idle', 16, 24, 'idle', (g, f) => body(g, HEAD.down, TORSO.down, LEGS.down[0], BOB.idle[f]));
add('chef-sleep', 16, 24, 'sleep', (g, f) => body(g, HEAD.sleep, TORSO.down, LEGS.sit[0], BOB.sleep[f]));
add('stache', 4, 1, 'still', (g) => blit(g, STACHE));
add('waiter-side', 16, 24, 'walk', (g, f) => { body(g, HEAD.waiterSide, TORSO.waiterSide, LEGS.side[f], BOB.walk[f]); });
add('waiter-idle', 16, 24, 'idle', (g, f) => body(g, HEAD.waiterDown, TORSO.waiterDown, LEGS.down[0], BOB.idle[f]));
addFrames('cloche', [CLOCHE], 'still');
// work loops: hands and tools in front of the station (the crew member stands behind it); row 7 is its top. Survey table: the pencil
// draws; workbench: the hammer comes down; inspection desk: the magnifier looks; test rig: the probe moves along; handover bay: a label goes on
const W = (fn) => (g, f) => fn(g, f, [0, 1, 2, 1][f]);
add('work-board', 16, 8, 'work', W((g, f, k) => { blit(g, HAND, 1, 4); blit(g, PENCIL, 10 + (f % 2), k - 1 + (f === 2 ? 1 : 0)); blit(g, HAND, 9 + (f % 2), 2 + k); }));
add('work-stove', 16, 8, 'work', W((g, f) => { const y = [-1, 0, 2, 1][f]; blit(g, HAND, 0, 4); blit(g, HAMMER, 7, y); blit(g, HAND, 7, y + 3); }));
add('work-taste', 16, 8, 'work', W((g, f) => { const up = [3, 1, -1, 1][f]; blit(g, HAND, 1, 4); blit(g, LENS, 10, up - 2); blit(g, HAND, 9, up + 2); }));
add('work-sink', 16, 8, 'work', W((g, f, k) => { blit(g, HAND, 1, 4); blit(g, PROBE, 8 + k, 5); blit(g, HAND, 9 + k, 3); }));
add('work-plate', 16, 8, 'work', W((g, f) => { blit(g, HAND, 1, 4); blit(g, LABEL, 10, [0, 1, 3, 4][f]); blit(g, HAND, 9, [0, 0, 1, 2][f]); }));
// the room
const tile = (rows) => (g) => blit(g, rows);
add('floor-a', 16, 16, 'still', (g) => { rect(g, 0, 0, 16, 16, 'm'); rect(g, 15, 0, 1, 16, 'l'); rect(g, 0, 15, 16, 1, 'l'); for (const [x, y] of [[3, 4], [10, 9], [6, 12], [12, 3]]) put(g, x, y, 'l'); put(g, 1, 1, 'p'); });
add('floor-b', 16, 16, 'still', (g) => { rect(g, 0, 0, 16, 16, 'l'); rect(g, 15, 0, 1, 16, 'k'); rect(g, 0, 15, 16, 1, 'k'); for (const [x, y] of [[4, 10], [11, 5], [7, 2]]) put(g, x, y, 'k'); put(g, 1, 1, 'm'); });
add('wall', 16, 16, 'still', (g) => { rect(g, 0, 0, 16, 16, 'E'); for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) if ((x * 7 + y * 13) % 23 === 0) put(g, x, y, (x + y) % 2 ? 'F' : 'D'); });
add('subway', 16, 16, 'still', tile(Array.from({ length: 16 }, (_, y) => ['nnnnnnnnnnnnnnnn', 'pppppppnpppppppn', 'poooooonpoooooon', 'poooooonpoooooon', 'nnnnnnnnnnnnnnnn', 'pppnpppppppnpppp', 'ooonpoooooonpooo', 'ooonpoooooonpooo'][y % 8])));
add('window', 34, 26, 'still', (g) => {
  box(g, 0, 0, 34, 26, WOOD); rect(g, 3, 3, 28, 19, 'X');
  for (let y = 3; y < 22; y++) for (let x = 3; x < 31; x++) { const b = y < 8 ? 'X' : y < 10 ? ((x + y) % 2 ? 'X' : 'Y') : y < 15 ? 'Y' : y < 17 ? ((x + y) % 2 ? 'Y' : 'Z') : 'Z'; put(g, x, y, b); }
  rect(g, 16, 3, 2, 19, 'c'); rect(g, 3, 12, 28, 1, 'c'); rect(g, 16, 3, 1, 19, 'd'); box(g, -1, 22, 36, 4, DARKWOOD);
});
add('door', 18, 30, 'still', (g) => { box(g, 0, 0, 18, 30, DARKWOOD); box(g, 3, 3, 12, 11, WOOD); box(g, 3, 16, 12, 12, WOOD); put(g, 13, 16, 't'); put(g, 13, 17, 's'); });
// the stations (code names stay): 'counter' = a plywood top on a steel drawer cabinet (Survey table, Inspection desk, Handover bay),
// 'stove' = the Workbench (a heavy top, a red toolbox on its shelf), 'sink' = the Test rig (a gauge and an LED strip on its panel)
add('counter', 28, 20, 'still', (g) => { box(g, 0, 4, 28, 16, STEEL); for (const x of [3, 15]) { box(g, x, 7, 10, 5, IRON); box(g, x, 12, 10, 6, IRON); rect(g, x + 4, 9, 2, 1, 'i'); rect(g, x + 4, 14, 2, 1, 'i'); } box(g, 0, 0, 28, 5, WOOD); });
add('stove', 28, 20, 'still', (g) => { box(g, 0, 4, 28, 16, IRON); box(g, 3, 8, 22, 10, ['a', 'j', 'f']); box(g, 5, 12, 12, 6, ['q', 'A', 'B']); rect(g, 9, 11, 4, 1, 'a'); rect(g, 6, 14, 10, 1, 'q'); box(g, 0, 0, 28, 5, DARKWOOD); });
// busy at the workbench: the weld flash at the vice (a white core in a blue-white halo; 3 sizes)
add('oven-glow', 18, 7, 'flame', (g, f) => { const r = [1.6, 2.6, 2.1][f]; for (let y = 0; y < 7; y++) for (let x = 0; x < 18; x++) { const d = Math.hypot(x - 9, (y - 4) * 1.4); if (d < 1) put(g, x, y, 'W'); else if (d < r) put(g, x, y, 'I'); else if (d < r + 1.6 && (x + y + f) % 2) put(g, x, y, 'z'); } });
add('sink', 28, 20, 'still', (g) => { box(g, 0, 4, 28, 16, STEEL); box(g, 3, 7, 22, 11, IRON); rect(g, 4, 9, 13, 5, 'j'); ring(g, 21, 12, 0, 3.2, 'p'); ring(g, 21, 12, 2.6, 3.2, 'a'); put(g, 21, 12, 'a'); put(g, 22, 11, 'B'); put(g, 23, 10, 'B'); box(g, 0, 0, 28, 5, STEEL); rect(g, 5, 1, 3, 2, 'B'); rect(g, 9, 1, 3, 2, 'v'); });
// the station props: a drawing with a ruler and a roll (Survey table), a vice holding a block (Workbench), a clipboard and a desk lamp
// (Inspection desk), a taped crate on a pallet (Handover bay)
add('board', 16, 6, 'still', (g) => { box(g, 0, 2, 13, 4, PAPER); rect(g, 2, 3, 4, 1, 'y'); put(g, 2, 4, 'y'); put(g, 5, 4, 'y'); rect(g, 7, 4, 4, 1, 'y'); put(g, 8, 3, 'y'); rect(g, 1, 1, 11, 1, 'G'); for (const x of [3, 6, 9]) put(g, x, 1, 'J'); box(g, 12, 1, 4, 5, PAPER, true); });
add('pot', 16, 8, 'still', (g) => { box(g, 2, 2, 4, 5, IRON); box(g, 8, 2, 4, 5, IRON); rect(g, 6, 3, 2, 3, 'e'); rect(g, 12, 4, 3, 1, 'h'); rect(g, 15, 3, 1, 3, 'a'); box(g, 1, 6, 12, 2, ['a', 'f', 'g']); });
add('bowl', 16, 6, 'still', (g) => { box(g, 0, 1, 7, 5, DARKWOOD); box(g, 1, 2, 5, 4, PAPER); rect(g, 2, 0, 3, 2, 'g'); rect(g, 2, 3, 3, 1, 'k'); put(g, 2, 4, 'k'); rect(g, 12, 2, 1, 4, 'a'); rect(g, 10, 5, 5, 1, 'a'); box(g, 8, 0, 6, 3, IRON, true); rect(g, 9, 2, 4, 1, 'I'); });
add('plates', 16, 6, 'still', (g) => { box(g, 2, 0, 10, 5, WOOD); rect(g, 6, 1, 2, 3, 'n'); rect(g, 3, 2, 2, 1, 'p'); rect(g, 0, 5, 14, 1, 'a'); for (const x of [1, 6, 11]) rect(g, x, 5, 2, 1, 'c'); });
add('crate', 20, 12, 'still', (g) => { box(g, 0, 0, 20, 12, WOOD); rect(g, 1, 4, 18, 1, 'c'); rect(g, 1, 8, 18, 1, 'c'); });
add('pass', 40, 34, 'still', (g) => { box(g, 0, 0, 40, 34, IRON); box(g, 3, 3, 34, 24, ['D', 'E', 'F'], false); rect(g, 4, 4, 32, 2, 'q'); box(g, -2, 27, 44, 5, STEEL); });
add('pass-glow', 32, 20, 'still', (g) => { for (let y = 0; y < 20; y++) for (let x = 0; x < 32; x++) put(g, x, y, y < 3 ? 'K' : y === 3 ? ((x % 2) ? 'K' : 'I') : 'I'); });
add('bell', 7, 6, 'bell', (g, f) => { blit(g, f ? ['....a..', '..aaa..', '.atta..', 'atssta.', 'aaaaaaa', '.......'] : ['...a...', '..aaa..', '.atsta.', 'atssssa', 'aaaaaaa', '.......'], 0, 0); });
add('shelf', 100, 4, 'still', (g) => { box(g, 0, 0, 100, 4, DARKWOOD); });
addFrames('pan', [PAN], 'still');
addFrames('jar', JAR, 'jars');
add('rail', 100, 3, 'still', (g) => { box(g, 0, 0, 100, 3, STEEL); });
add('ticket', 11, 13, 'still', (g) => { box(g, 0, 1, 11, 12, PAPER); rect(g, 4, 0, 3, 2, 'g'); put(g, 5, 0, 'a'); });
addFrames('digit', DIGITS, 'glyph');
addFrames('sun', [SUN], 'still');
addFrames('moon', [MOON], 'still');
add('lamp', 9, 8, 'still', (g) => { rect(g, 4, 0, 1, 3, 'a'); box(g, 1, 3, 7, 4, ['q', 'r', 's'], true); rect(g, 3, 7, 3, 1, 'I'); });
add('lantern', 7, 10, 'lantern', (g, f) => { blit(g, ['..aaa..', '.a...a.', 'aaaaaaa', 'a' + (f ? 'tIIt' : 'stts') + 'a.', 'a' + (f ? 'IttI' : 'tsst') + 'a.', 'aaaaaaa', '..aaa..'], 0, 2); put(g, 6, 5, 'a'); put(g, 6, 6, 'a'); });
add('shadow', 14, 3, 'still', (g) => { rect(g, 2, 0, 10, 3, 'k'); rect(g, 0, 1, 14, 1, 'k'); });
for (const [k, v] of Object.entries(PARTICLE)) addFrames(k, v, { steam: 'steam', sparkle: 'sparkle', flame: 'flame' }[k] || 'still');
addFrames('icon', ICONS, 'icon');
// the Live call (pass-app/public/live.js): each cook at a desk, seen from the front. The desk covers the legs; the laptop's lid (its
// back to us) sits under the chin with the cook's colour as its badge, which glows while the cook works; hands type in front of it
add('desk', 48, 11, 'still', (g) => { box(g, 0, 0, 48, 4, WOOD); box(g, 2, 3, 44, 8, DARKWOOD); box(g, 6, 5, 14, 5, WOOD); put(g, 13, 7, 't'); box(g, 28, 5, 14, 5, WOOD); put(g, 35, 7, 't'); });
add('laptop', 14, 7, 'work', (g, f) => { box(g, 0, 0, 14, 7, IRON); rect(g, 1, 0, 12, 1, ['z', 'y', 'z', 'Y'][f]); blit(g, ['a55a', f % 2 ? '5665' : '5555', 'a44a'].map((r) => r.replace(/a/g, 'g')), 5, 2); });
add('laptop-shut', 14, 3, 'still', (g) => { box(g, 0, 0, 14, 3, IRON); put(g, 6, 1, '4'); put(g, 7, 1, '4'); });
add('work-type', 16, 4, 'work', (g, f) => { blit(g, HAND, 1, [0, 1, 0, 0][f]); blit(g, HAND, 10, [0, 0, 0, 1][f]); });
add('desk-wall', 48, 32, 'still', (g) => { rect(g, 0, 0, 48, 32, 'E'); for (let y = 0; y < 32; y++) for (let x = 0; x < 48; x++) if ((x * 7 + y * 13) % 23 === 0) put(g, x, y, (x + y) % 2 ? 'F' : 'D'); rect(g, 0, 19, 48, 1, 'D'); blit(g, ['.aaa.', 'aIIIa', 'aItIa', 'aIIIa', '.aaa.'], 40, 3); });
// the 9-slice panel for the interface: 2px of outline, then a highlight, then the card colour (stretched by CSS border-image)
add('panel', 9, 9, 'still', (g) => { rect(g, 0, 0, 9, 9, 'p'); for (let i = 0; i < 9; i++) { put(g, i, 0, 'a'); put(g, i, 8, 'a'); put(g, 0, i, 'a'); put(g, 8, i, 'a'); put(g, i, 7, 'o'); put(g, 7, i, 'o'); put(g, i, 1, 'W'); put(g, 1, i, 'W'); } put(g, 0, 0, '.'); put(g, 8, 0, '.'); put(g, 0, 8, '.'); put(g, 8, 8, '.'); put(g, 1, 1, 'a'); put(g, 7, 1, 'a'); put(g, 1, 7, 'a'); put(g, 7, 7, 'a'); });
// ---- the world props: what each one means is in scene.js WORLD ----
export const GLYPHS = { O: ['aaa', 'a.a', 'a.a', 'a.a', 'aaa'], P: ['aaa', 'a.a', 'aaa', 'a..', 'a..'], E: ['aaa', 'a..', 'aa.', 'a..', 'aaa'], N: ['aa.', 'a.a', 'a.a', 'a.a', 'a.a'],
  C: ['.aa', 'a..', 'a..', 'a..', '.aa'], L: ['a..', 'a..', 'a..', 'a..', 'aaa'], S: ['.aa', 'a..', '.a.', '..a', 'aa.'], D: ['aa.', 'a.a', 'a.a', 'a.a', 'aa.'], R: ['aa.', 'a.a', 'aa.', 'a.a', 'a.a'], U: ['a.a', 'a.a', 'a.a', 'a.a', 'aaa'], '!': ['.a.', '.a.', '.a.', '...', '.a.'], ' ': ['...'], '+': ['...', '.a.', 'aaa', '.a.', '...'] };
const say = (g, word, x, y, c) => [...word].forEach((ch, i) => blit(g, GLYPHS[ch].map((r) => r.replace(/a/g, c)), x + i * 4, y));
add('sign', 25, 12, 'sign', (g, f) => {
  put(g, 12, 0, 'a'); for (let i = 1; i < 3; i++) { put(g, 12 - i * 4, i, 'k'); put(g, 12 + i * 4, i, 'k'); }
  if (f === 2) { box(g, 0, 3, 25, 9, DARKWOOD); rect(g, 1, 4, 23, 7, 'c'); say(g, 'CLOSED', 1, 5, 'o'); return; }
  box(g, 0, 3, 25, 9, f ? ['q', 'q', 'A'] : PAPER); say(g, 'OPEN', 5, 5, f ? 't' : 'k');
});
const ring = (g, cx, cy, r0, r1, c) => { for (let y = 0; y < g.length; y++) for (let x = 0; x < g[0].length; x++) { const d = Math.hypot(x - cx, y - cy); if (d >= r0 && d < r1) put(g, x, y, c); } };
const hand = (g, f, len, c) => { const a = (f * Math.PI) / 6; for (let i = 1; i <= len; i++) put(g, Math.round(6 + Math.sin(a) * i), Math.round(6 - Math.cos(a) * i), c); };
add('clock', 13, 13, 'still', (g) => { ring(g, 6, 6, 0, 6.6, 'p'); ring(g, 6, 6, 5.2, 6.6, 'c'); ring(g, 6, 6, 6, 6.6, 'a'); for (const [x, y] of [[6, 2], [10, 6], [6, 10], [2, 6]]) put(g, x, y, 'k'); });
add('clock-min', 13, 13, 'hand', (g, f) => hand(g, f, 4, 'a'));
add('clock-hour', 13, 13, 'hand', (g, f) => { hand(g, f, 2, 'r'); put(g, 6, 6, 'a'); });
add('coin-jar', 9, 10, 'jar', (g, f) => {
  rect(g, 1, 0, 7, 1, 'a'); put(g, 1, 1, 'a'); put(g, 7, 1, 'a'); for (let y = 2; y < 9; y++) { put(g, 0, y, 'a'); put(g, 8, y, 'a'); } rect(g, 1, 9, 7, 1, 'a');
  for (let k = 0; k < f; k++) { const y = 8 - k; for (let x = 1; x < 8; x++) if (y > 1 || (x > 1 && x < 7)) put(g, x, y, (x + y) % 3 ? 't' : 'd'); }
  for (let y = 2; y < 8 - f + 1; y++) put(g, 2, y, 'z');
});
add('jar-lock', 9, 8, 'still', (g) => { rect(g, 0, 0, 9, 2, 'a'); rect(g, 1, 0, 7, 1, 'h'); put(g, 3, 2, 'a'); put(g, 5, 2, 'a'); put(g, 3, 3, 'a'); put(g, 5, 3, 'a'); box(g, 2, 4, 5, 4, STEEL); put(g, 4, 5, 'a'); put(g, 4, 6, 'a'); });
const STOOL = (g) => { box(g, 0, 0, 10, 3, WOOD); for (let y = 3; y < 8; y++) { put(g, 1, y, 'a'); put(g, 2, y, 'c'); put(g, 7, y, 'c'); put(g, 8, y, 'a'); } rect(g, 2, 5, 6, 1, 'c'); };
add('stool', 10, 8, 'still', STOOL);
add('chair-up', 10, 8, 'still', (g) => { const t = grid(10, 8); STOOL(t); t.reverse().forEach((r, y) => r.forEach((c, x) => put(g, x, y, c))); });
add('chef-sit', 16, 24, 'idle', (g, f) => body(g, HEAD.down, TORSO.down, LEGS.sit[0], BOB.idle[f]));
add('fuse', 10, 12, 'fuse', (g, f) => { box(g, 0, 0, 10, 12, IRON); if (!f) { box(g, 2, 2, 6, 8, STEEL); put(g, 6, 4, 'v'); return; } box(g, 2, 2, 6, 8, ['a', 'f', 'g']); rect(g, 4, 6, 1, 3, 'h'); put(g, 4, 9, 'B'); put(g, 6, 3, 'B'); put(g, 7, 1, 'a'); put(g, 1, 10, 'a'); });
add('lamp-off', 9, 8, 'still', (g) => { rect(g, 4, 0, 1, 3, 'a'); box(g, 1, 3, 7, 4, DARKWOOD, true); rect(g, 3, 7, 3, 1, 'g'); });
add('heat', 8, 6, 'heat', (g, f) => { rect(g, 3, 0, 2, 2, 'a'); box(g, 1, 2, 6, 3, IRON, true); rect(g, 2, 4, 4, 1, ['t', 's', 'B'][f]); for (const x of [2, 5]) put(g, x, 5, ['I', 'K', 'B'][f]); });
add('cork', 18, 12, 'still', (g) => { box(g, 0, 0, 18, 12, WOOD); rect(g, 1, 1, 16, 10, 'd'); for (const [x, y] of [[3, 3], [9, 2], [14, 5], [5, 8], [12, 9], [16, 2]]) put(g, x, y, 'c'); });
add('letter', 5, 4, 'still', (g) => { box(g, 0, 0, 5, 4, PAPER); put(g, 1, 1, 'a'); put(g, 2, 2, 'a'); put(g, 3, 1, 'a'); put(g, 2, 0, 'B'); });
add('hooks', 22, 3, 'still', (g) => { box(g, 0, 0, 22, 3, DARKWOOD); for (let i = 0; i < 4; i++) put(g, 3 + i * 5, 2, 'h'); });
add('hat', 6, 7, 'still', (g) => blit(g, ['......', '.aaaa.', 'a6654a', 'a6554a', 'a5554a', 'a4444a', 'aaaaaa']));   // a hard hat on its hook, in the crew's colour
add('chalk', 19, 13, 'still', (g) => { box(g, 0, 0, 19, 13, WOOD); rect(g, 1, 1, 17, 11, 'f'); });
add('tally', 17, 5, 'tally', (g, f) => { for (let i = 0; i < f; i++) { const grp = Math.floor(i / 5), k = i % 5, x0 = 1 + grp * 8; if (k < 4) rect(g, x0 + k * 2, 0, 1, 5, 'o'); else for (let j = 0; j < 7; j++) put(g, x0 - 1 + j, 4 - Math.round(j * 4 / 6), 'o'); } });
addFrames('chalk-digit', DIGITS.map((d) => d.map((r) => r.replace(/a/g, 'o'))), 'glyph');
add('recipes', 9, 8, 'cards', (g, f) => { for (let i = 0; i < f; i++) box(g, 1 + i * 2, 1 + (i % 2), 3, 5, PAPER); box(g, 0, 4, 9, 4, DARKWOOD); });
add('aside-shelf', 27, 4, 'still', (g) => { box(g, 0, 0, 27, 3, DARKWOOD); put(g, 2, 3, 'a'); put(g, 24, 3, 'a'); });
add('plate-aside', 5, 3, 'still', (g) => blit(g, ['.abb.', 'aoooa', '.aaa.']));
addFrames('smoke', PARTICLE.steam.map((fr) => fr.map((r) => r.replace(/l/g, 'k').replace(/m/g, 'l'))), 'steam');   // the dust, a shade darker
add('tag', 15, 9, 'still', (g) => { box(g, 0, 1, 15, 8, PAPER); rect(g, 6, 0, 3, 2, 'g'); put(g, 7, 0, 'a'); });
add('plus', 3, 5, 'still', (g) => blit(g, GLYPHS['+']));
// ---- moments (plans/chef-art-2.md wave 2; public/moments.js plays them): the anticipation crouch, the landing squash, the pan
// flip, a grey puff, dark smoke, a check, confetti in 3 colours and the "ORDER UP!" banner (a bevelled box, words baked in) ----
add('chef-crouch', 16, 24, 'still', (g) => body(g, HEAD.down, TORSO.down, LEGS.down[0], 2));
add('chef-squash', 16, 24, 'still', (g) => { blit(g, LEGS.down[0], 0, 17); blit(g, TORSO.down, 0, 13); blit(g, HEAD.down, 0, 2); });
add('mitt', 5, 4, 'still', (g) => blit(g, HAND));
add('pan-flip', 12, 12, 'flip', (g, f) => { box(g, 1, 9, 8, 3, IRON, true); rect(g, 9, 10, 3, 1, 'a'); const y = [6, 2, 0, 3][f]; rect(g, 3 + (f % 2), y, 3, 2, 'B'); put(g, 4 + (f % 2), y, 'C'); });
add('puff', 9, 9, 'puff', (g, f) => { ring(g, 4, 4, 0, 1.5 + f, f > 2 ? 'k' : 'l'); ring(g, 4, 4, 0.6 + f, 1.5 + f, 'm'); });
add('smoke-dark', 9, 12, 'smoke6', (g, f) => { for (let i = 0; i < 3; i++) ring(g, 2 + i * 2.5, 9 - ((f + i * 2) % 6) * 1.5, 0, 1.5 + ((f + i) % 3) * 0.6, i % 2 ? 'j' : 'D'); });
add('check', 7, 6, 'still', (g) => blit(g, ['.....av', '....avu', 'a..avu.', 'avavu..', '.avu...', '..a....']));
add('confetti', 2, 2, 'confetti', (g, f) => rect(g, 0, 0, 2, 2, 'Bty'[f]));
add('banner', 41, 11, 'still', (g) => { box(g, 0, 0, 41, 11, ['q', 'r', 's']); say(g, 'ORDER UP!', 3, 3, 'p'); });
// the legend sheet's icon per row: [sprite, frame]
export const LEGEND_ICONS = { sign: ['sign', 1], clock: ['clock', 0], sous: ['chef-sit', 0],
  fuse: ['fuse', 1], jar: ['coin-jar', 5], aside: ['plate-aside', 0], spike: ['tag', 0], heat: ['heat', 1], letters: ['letter', 0], specials: ['chalk', 0], recipes: ['recipes', 3], hats: ['hat', 0] };
export const SPRITES = S;

// ---- decoding: name -> frames (each an array of strings, one character per pixel) ----
const cache = new Map();
export function framesOf(name) {
  if (cache.has(name)) return cache.get(name);
  const s = S[name]; if (!s) throw new Error('no sprite ' + name);
  const out = s.frames || Array.from({ length: FRAMES[s.anim] }, (_, f) => { const g = grid(s.w, s.h); s.draw(g, f); return g.map((r) => r.join('')); });
  cache.set(name, out); return out;
}
// one frame to RGBA bytes (pure; flip = mirrored for walking left)
export function toRGBA(rows, pal, flip = false) {
  const h = rows.length, w = rows[0].length, px = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const c = rows[y][flip ? w - 1 - x : x]; if (c === '.') continue;
    const v = pal[c]; if (!v) throw new Error(`palette index ${c} undefined`);
    const [r, g, b] = rgb(v), i = (y * w + x) * 4; px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255;
  }
  return px;
}
// a strip canvas of every frame of one sprite in one palette (mk(w, h) makes a canvas: DOM, OffscreenCanvas or a test mock)
export function stripOf(mk, name, pal = PALETTE, flip = false) {
  const fr = framesOf(name), s = S[name], c = mk(s.w * fr.length, s.h), ctx = c.getContext('2d');
  fr.forEach((rows, f) => { const img = ctx.createImageData(s.w, s.h); img.data.set(toRGBA(rows, pal, flip)); ctx.putImageData(img, f * s.w, 0); });
  return { img: c, w: s.w, h: s.h, n: fr.length };
}
// the atlas: every sprite in the base palette, shelf-packed into one canvas no wider than 512 px
export function packAtlas(maxW = 512) {
  const at = {}; let x = 0, y = 0, rowH = 0;
  for (const name of Object.keys(S).sort((a, b) => S[b].h - S[a].h)) {
    const s = S[name], w = s.w * framesOf(name).length;
    if (x + w > maxW) { x = 0; y += rowH; rowH = 0; }
    at[name] = { x, y, w: s.w, h: s.h, n: framesOf(name).length }; x += w; rowH = Math.max(rowH, s.h);
  }
  return { at, w: maxW, h: y + rowH };
}
export function buildAtlas(mk, pal = PALETTE) {
  const L = packAtlas(), c = mk(L.w, L.h), ctx = c.getContext('2d');
  for (const [name, r] of Object.entries(L.at)) framesOf(name).forEach((rows, f) => { const img = ctx.createImageData(r.w, r.h); img.data.set(toRGBA(rows, pal)); ctx.putImageData(img, r.x + f * r.w, r.y); });
  return { canvas: c, ...L };
}

// ---- interface chrome sprites (scene.js turns them into CSS variables: --px-<name>) ----
// tabs in bar order (S6b: site board, walkie-talkie, pulse, hard hat, ledger, clipboard); plain, lit, and -dark with a cream outline
export const TAB_ICONS = ['pass', 'talk', 'activity', 'cooks', 'ledger', 'order'];
const INK = ['#5c5953', '#8a857c', '#b5afa5'], INK_DARK = ['#8a857c', '#b5afa5', '#d6c3a8'], EMBER = ['#7a1f12', '#c2410c', '#f08a24'];
export const TAB_DARK = { a: PALETTE.o, p: PALETTE.Q, o: PALETTE.F, n: PALETTE.k };   // outline, paper, paper shade, paper shadow
export function chromeSprites(mk) {
  const out = {};
  const one = (key, w, h, n, paint) => { const c = mk(w * n, h), ctx = c.getContext('2d'); for (let f = 0; f < n; f++) { const g = grid(w, h); paint(g, f); const img = ctx.createImageData(w, h); img.data.set(toRGBA(g.map((r) => r.join('')), out._pal)); ctx.putImageData(img, f * w, 0); } out[key] = c; };
  out._pal = paletteFor({ skin: '#d39a6a', cook: '#d97757' });
  // loading: a chef stirring a pot (4 frames); offline: the sleepy chef and a lantern (2); empty: a chef by an empty cloche (2)
  one('load', 32, 32, 4, (g, f) => { blit(g, framesOf('chef-idle')[f % 2], 8, 0); blit(g, framesOf('pot')[0], 8, 18); blit(g, framesOf('work-stove')[f], 8, 13); blit(g, framesOf('steam')[f], 13, 12); });
  one('off', 32, 32, 2, (g, f) => { blit(g, framesOf('crate')[0], 4, 20); blit(g, framesOf('chef-sleep')[f], 6, 4); blit(g, framesOf('lantern')[f], 23, 20); blit(g, framesOf('zz')[0], 20, 2 + f); });
  one('empty', 32, 32, 2, (g, f) => { blit(g, framesOf('chef-idle')[f], 2, 6); blit(g, framesOf('cloche')[0], 19, 22); });
  TAB_ICONS.forEach((k, i) => { for (const [suf, acc, ui] of [['', INK], ['-on', EMBER], ['-dark', INK_DARK, TAB_DARK], ['-on-dark', EMBER, TAB_DARK]]) { const pal = { ...out._pal, ...ui }; [pal[4], pal[5], pal[6]] = acc; out._tmp = pal; const c = mk(12, 12), ctx = c.getContext('2d'), img = ctx.createImageData(12, 12); img.data.set(toRGBA(ICONS[i], pal)); ctx.putImageData(img, 0, 0); out['tab-' + k + suf] = c; } });
  for (const [k, ui] of [['panel', null], ['panel-dark', { a: PALETTE.V, p: PALETTE.O, W: PALETTE.Q, o: PALETTE.N }]]) { const c = mk(9, 9), ctx = c.getContext('2d'), img = ctx.createImageData(9, 9); img.data.set(toRGBA(framesOf('panel')[0], { ...PALETTE, ...(ui || {}) })); ctx.putImageData(img, 0, 0); out[k] = c; }
  delete out._pal; delete out._tmp;
  return out;
}
