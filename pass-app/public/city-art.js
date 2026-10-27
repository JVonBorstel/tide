// The City's pixel art as palette-indexed strings (the sprites.js format; its PALETTE keys, its outline 'a', light from the top left).
// Read by public/city.js; tested by pass-app/test-city.mjs. Original art, no images, no network. Crane paint G/H are local here.
import { GLYPHS } from './sprites.js';

// 3x5 glyphs: sprites.js's own, plus the letters and digits the City's signs need
export const GL = { ...GLYPHS, A: ['.a.', 'a.a', 'aaa', 'a.a', 'a.a'], G: ['.aa', 'a..', 'a.a', 'a.a', '.aa'], H: ['a.a', 'a.a', 'aaa', 'a.a', 'a.a'],
  M: ['a.a', 'aaa', 'aaa', 'a.a', 'a.a'], '?': ['aa.', '..a', '.a.', '...', '.a.'], '-': ['...', '...', 'aaa', '...', '...'],
  0: ['aaa', 'a.a', 'a.a', 'a.a', 'aaa'], 1: ['.a.', 'aa.', '.a.', '.a.', 'aaa'], 2: ['aaa', '..a', 'aaa', 'a..', 'aaa'], 3: ['aaa', '..a', '.aa', '..a', 'aaa'],
  4: ['a.a', 'a.a', 'aaa', '..a', '..a'], 5: ['aaa', 'a..', 'aaa', '..a', 'aaa'], 6: ['aaa', 'a..', 'aaa', 'a.a', 'aaa'], 7: ['aaa', '..a', '..a', '.a.', '.a.'],
  8: ['aaa', 'a.a', 'aaa', 'a.a', 'aaa'], 9: ['aaa', 'a.a', 'aaa', '..a', 'aaa'] };
// crane paint (yellow and its shadow), from S7's free keys, kept local so S7's palette is untouched
export const PAINT = { G: '#e2a52b', H: '#9c6a12' };
// a crew member: hard hat in the crew's colour (4 5 6), skin (2), hi-vis vest (s t), steel trousers (g); two frames: still, and a step
export const WORKER = [['.565.', '44444', '.222.', 'tssst', '2sts2', '.g.g.', '.a.a.'], ['.565.', '44444', '.222.', 'tssst', '2sts2', '.gg..', '.a.a.']];
// the tool at the crew's station (scene.js stations as site words)
export const TOOLS = {
  survey: ['..a..', '.aza.', '..h..', '.h.h.', 'h...h'],
  build: ['aa...', 'ah...', '.h...', '.h...', 'cccc.'],
  inspect: ['aaaa', 'appa', 'akka', 'appa', 'aaaa'],
  test: ['aaaaa', 'afvfa', 'afffa', 'aaaaa', '.a.a.'],
  handover: ['aaaaa', 'adcda', 'acdca', 'adcda', 'aaaaa'],
};
export const PALLET = ['adcda', 'acdca', 'aaaaa'];
export const LOCK = ['.aa.', 'a..a', 'aaaa', 'atta', 'aaaa'];
export const FLAG = ['at..', 'att.', 'at..', 'a...', 'a...'];   // the "new floors" pennant on a roof
export const SKIP = ['a.....a', 'akkkkka', 'akjjjka', '.aaaaa.'];   // the skip a taken-down floor sits in
// tower skins: stone, brick, steel, cream (a ramp each: shadow, base, light); a tower keeps its skin by its place in the row
export const RAMPS = [['k', 'l', 'm'], ['b', 'c', 'd'], ['f', 'g', 'h'], ['n', 'o', 'p']];
// the beacon's three ages and the crane's CI tag
export const BEACON = { warm: 't', amber: 's', red: 'B' };
export const CI = { red: 'B', pending: 's', green: 'v' };
