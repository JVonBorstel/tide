// ZG-17: the morning brief's World line, counts only: "World: 2 decisions ready, 1 question, 14 signals since yesterday; sweeps skipped 3x (RAM)".
// Pure (no DOM, no fetch): app.js renders it from brief().lobe plus brief().lobeSkips as skips; tests/Test-PassApp.ps1 runs it in node. kitchen/stations/lobe.ps1
// Format-WorldLine says the same words in the phone push. A zero or unknown count says nothing, and all zero is no line. Every part is a
// number and fixed words: nothing from the frame's text, a source, a link or a skip reason ever reaches it.
const n = (x) => (Number.isInteger(x) && x > 0 ? x : 0);
const KINDS = [['ram', 'RAM'], ['ollama', 'Ollama'], ['gpu', 'graphics card']];   // server.mjs lobeSkips: why a sweep or rem run waited
const say = (v, one, many) => (v ? `${v} ${v === 1 ? one : many}` : '');
export function worldLine(l) {
  if (!l || typeof l !== 'object') return '';
  const s = l.skips && typeof l.skips === 'object' ? l.skips : {};
  const counts = [say(n(l.decisionsReady), 'decision ready', 'decisions ready'), say(n(l.calibrationQuestions), 'question', 'questions'),
    say(n(l.signals24h), 'signal since yesterday', 'signals since yesterday')].filter(Boolean);
  const sweep = n(s.sweep), rem = n(s.rem), all = sweep + rem;
  const kinds = KINDS.map(([k, w], i) => ({ w, v: n(s[k]), i })).filter((x) => x.v).sort((a, b) => b.v - a.v || a.i - b.i).map((x) => x.w);
  const skip = all ? `${rem ? (sweep ? 'runs' : 'rem runs') : 'sweeps'} skipped ${all}x${kinds.length ? ` (${kinds.join(', ')})` : ''}` : '';
  if (!counts.length && !skip) return '';
  return `World: ${counts.join(', ')}${counts.length && skip ? '; ' : ''}${skip}`;
}
