// The speed budget's numbers: turns the probe's raw frames and entries into metrics, takes the median of the runs, judges each metric
// against pass-app/speed/budget.json, and writes the size report and the markdown table. Called by pass-app/speed/run.mjs; pure except sizeReport.
import fs from 'node:fs'; import path from 'node:path'; import zlib from 'node:zlib';

const round = (v, d = 1) => (v === null || v === undefined || Number.isNaN(v) ? null : Math.round(v * 10 ** d) / 10 ** d);
// nearest-rank percentile of a list of numbers; null for an empty list
export function pct(list, p) {
  if (!list.length) return null;
  const s = [...list].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(p * s.length) - 1))];
}
// frame work in the given phases: every vsync that ran a callback, and the painted ones (a canvas draw happened)
export function frameStats(frames, phases) {
  const f = frames.filter((x) => phases.includes(x.phase)), all = f.map((x) => x.work), painted = f.filter((x) => x.draws > 0).map((x) => x.work);
  return { n: all.length, painted: painted.length, p50: round(pct(all, 0.5), 2), p95: round(pct(all, 0.95), 2), p99: round(pct(all, 0.99), 2),
    paintP95: round(pct(painted, 0.95), 2), max: round(all.length ? Math.max(...all) : null, 2),
    over16: all.filter((w) => w > 16.7).length, over33: all.filter((w) => w > 33.3).length, drawsMax: f.length ? Math.max(...f.map((x) => x.draws)) : 0 };
}
// INP the way Chrome reports it for a page with under 50 interactions: the slowest interaction (an interaction's longest event)
export function inpOf(events) {
  const by = new Map(); for (const e of events) by.set(e.id, Math.max(by.get(e.id) || 0, e.ms));
  return by.size ? Math.max(...by.values()) : null;
}
// one run's flat metrics from the busy page and the calm page
export function summarize(busy, calm) {
  const S = busy.speed, scene = frameStats(S.frames, ['busy']), zoom = frameStats(S.frames, ['zoom']), flight = frameStats(S.frames, ['flight']);
  const taps = S.events.filter((e) => e.phase === 'tap' || e.phase === 'flight');
  return { firstUsefulPaintMs: round(S.fup, 0), fcpMs: round(S.fcp, 0), lcpMs: round(S.lcp, 0), cls: round(S.shifts, 3), inpMs: round(inpOf(taps), 0),
    frameP50Ms: scene.p50, frameP95Ms: scene.p95, frameP99Ms: scene.p99, paintP95Ms: scene.paintP95, longFrames16: scene.over16, longFrames33: scene.over33,
    zoomP95Ms: zoom.n ? zoom.p95 : null, flightP95Ms: flight.n ? flight.p95 : null, drawsMax: scene.drawsMax, sceneFrames: scene.n,
    loafCount: S.loaf.filter((x) => x.phase !== 'load').length, heapMB: round(busy.heapMB, 1), domNodes: busy.nodes, canvases: busy.canvases,
    idleRafPerSec: round(calm.rafPerSec, 1), idleScriptPct: round(calm.scriptPct, 2), stage: busy.stage, notes: [...busy.notes, ...calm.notes] };
}
// the median of each numeric metric over the runs (a metric a run could not take is left out of its median)
export function medianOf(runs) {
  const out = {};
  for (const k of Object.keys(runs[0] || {})) {
    const v = runs.map((r) => r[k]).filter((x) => typeof x === 'number');
    out[k] = v.length ? round(pct(v, 0.5), 3) : runs[0][k];
  }
  out.notes = [...new Set(runs.flatMap((r) => r.notes || []))];
  return out;
}
// each budgeted metric: ok (within target), warn (over target, within the hard limit), over (over the hard limit), n/a (not measured)
export function judge(m, budget) {
  return Object.entries(budget.metrics).map(([key, b]) => {
    const v = m[key], has = typeof v === 'number';
    const status = !has ? 'n/a' : v > b.hard ? 'over' : v > b.target ? 'warn' : 'ok';
    return { key, label: b.label, unit: b.unit || '', value: has ? v : null, target: b.target, hard: b.hard, status };
  });
}
// the Board's shipped files, raw and brotli (information only; a loud warning past budget.size.warnBrotliKB for the scripts)
export function sizeReport(pub, warnKB) {
  const files = fs.readdirSync(pub).filter((f) => /\.(js|css|html)$/.test(f)).sort().map((f) => {
    const buf = fs.readFileSync(path.join(pub, f));
    const br = zlib.brotliCompressSync(buf, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
    return { file: f, rawKB: round(buf.length / 1024, 1), brotliKB: round(br / 1024, 1) };
  });
  const sum = (sel) => round(files.filter(sel).reduce((a, x) => a + x.brotliKB, 0), 1);
  const scriptsKB = sum((x) => x.file.endsWith('.js'));
  return { files, scriptsBrotliKB: scriptsKB, totalBrotliKB: sum(() => true), warnBrotliKB: warnKB, warn: scriptsKB > warnKB };
}
const fmt = (v, unit) => (v === null ? 'not measured' : `${v}${unit ? ' ' + unit : ''}`);
const MARK = { ok: 'ok', warn: 'over target', over: 'OVER HARD LIMIT', 'n/a': 'n/a' };
// the job summary: the verdict line, the budget table, the extra numbers, the size report
export function markdown({ rows, median, size, enforce, runs, profile }) {
  const bad = rows.filter((r) => r.status === 'over').length, warn = rows.filter((r) => r.status === 'warn').length;
  const mode = enforce ? 'ENFORCING: a metric over its hard limit fails this check' : 'REPORT ONLY: nothing here fails the check yet (see pass-app/SPEED.md to enforce)';
  const L = ['## Phone speed budget', '', `${mode}. Median of ${runs} run(s); ${profile}.`, '', `${bad} over the hard limit, ${warn} over target.`, '',
    '| Metric | Value | Target | Hard limit | Status |', '|---|---|---|---|---|',
    ...rows.map((r) => `| ${r.label} | ${fmt(r.value, r.unit)} | ${r.target} | ${r.hard} | ${MARK[r.status]} |`), '',
    `Also measured: frame p50 ${fmt(median.frameP50Ms, 'ms')}, painted-frame p95 ${fmt(median.paintP95Ms, 'ms')}, frames over 16.7 ms ${fmt(median.longFrames16)},`
    + ` long animation frames ${fmt(median.loafCount)}, most canvas draws in one frame ${fmt(median.drawsMax)}, DOM nodes ${fmt(median.domNodes)},`
    + ` canvases ${fmt(median.canvases)}, FCP ${fmt(median.fcpMs, 'ms')}, LCP ${fmt(median.lcpMs, 'ms')}, stage ${median.stage}.`, ''];
  if (median.notes.length) L.push('Notes: ' + median.notes.join('; ') + '.', '');
  L.push(`### Size (information only; warns past ${size.warnBrotliKB} KB brotli of scripts)`, '',
    `Scripts ${size.scriptsBrotliKB} KB brotli, everything ${size.totalBrotliKB} KB brotli${size.warn ? ' **(over the warning line)**' : ''}.`, '',
    '| File | Raw KB | Brotli KB |', '|---|---|---|', ...size.files.map((f) => `| ${f.file} | ${f.rawKB} | ${f.brotliKB} |`), '');
  return L.join('\n');
}
