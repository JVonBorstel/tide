// The Board's Self card (ZG-45): what the system avoids, what it got wrong and how fast it closes, in one place. Pure: no fetch, no write, no timer.
// Imported by lobe.js (worldHtml draws it after Trust, with the Owner part) and app.js (selfCount, the World tab's badge); tested by pass-app/test-lobe-self.mjs.
// Data: only what the World view already has. state.lobe = csf.json (meta.ttc_median_hours, meta.trust, meta.charter, meta.counts and
// 2_endogenous_self_state.shadow_blindspots, written by zeitgeistd shadow.py ZG-23 and connectors/roadmap.py ZG-34); state.lobeOwner.decide (flags.json,
// ZG-25) and state.lobeOwner.trust (trust.json and the scoreboard, ZG-40). Every number with no data behind it says "unknown" and why. The frame's
// shadow lines are read for their numbers; a Pour's id is shown as the file spells it (so Demo Project keeps its own words until its rename date).
import { esc } from './scene.js';
import { frameOf, ago, card, sub, badge } from './lobe.js';

const arr = (x) => (Array.isArray(x) ? x : []);
const num = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);
const unk = (why) => `unknown (${esc(why)})`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
// the lines csf.py puts in shadow_blindspots: a shadow Pour (roadmap.py:220), a Blueprint it could not read or that is old (:184, :191), the Yard's
// hours unknown (:227), and a Charter domain with 0 h in 14 days (shadow.py: "INCOME_TRACK: 0 h in 14 d; unmet SYSTEM")
const POUR = /^(.+?): (\d+) of (\d+) floors touched in (\d+) days; (\d+) merged, (\d+) cooking, (\d+) with no order$/;
const BAD_PRINT = /^(.+?) roadmap: (unreadable|stale) \((.*)\)$/;
const NO_HOURS = /^roadmap shadow: yard events (.+?); Yard hours unknown/;
const DOMAIN = /^([A-Za-z0-9_ -]{1,64}): 0 h in (\d+) d(?:; unmet (.+))?$/;
export const NO_CALIB = 'the held rate before and after each answer is kept only in the lobe\'s database; flags.json and csf.json do not carry it';
const FRAME_WHY = { missing: 'no frame yet: the lobe has not written csf.json', refused: 'the frame was refused' };
const TTC_KIND = [['loop', 'open loop'], ['signoff', 'Sign-off'], ['decision', 'decision']];

// the card's numbers (pure). view = state.lobe, owner = state.lobeOwner. Each part: a number, or null and a why.
export function selfState(view, owner = null, now = Date.now()) {
  const r = frameOf(view, now), f = r.kind === 'ok' ? r.f : null;
  const fw = r.kind === 'stale' ? `the frame is stale (${ago(r.age)} old)` : FRAME_WHY[r.kind] || '';
  const lines = f ? arr(f['2_endogenous_self_state']?.shadow_blindspots).map((x) => String(x ?? '')) : [];
  const pours = [], bad = [], domains = []; let noHours = '', other = 0;
  for (const l of lines) {
    let m;
    if ((m = POUR.exec(l))) pours.push({ label: m[1], touched: +m[2], floors: +m[3], days: +m[4], merged: +m[5], building: +m[6], noOrder: +m[7] });
    else if ((m = BAD_PRINT.exec(l))) bad.push({ label: m[1], kind: m[2], why: m[3] });
    else if ((m = NO_HOURS.exec(l))) noHours = m[1];
    else if ((m = DOMAIN.exec(l))) domains.push({ name: m[1].trim(), days: +m[2], unmet: m[3] || '' });
    else other++;
  }
  const atLeast = !!(f && num(f.meta.trimmed));   // csf.py trims list entries to fit its 2,400 characters, so a count can be short
  const s = { frame: { ok: !!f, why: fw }, atLeast, other, bad };
  s.charter = f ? (f.meta.charter === 'LOCKED' ? 'locked' : 'example') : null;
  // shadow Pours: only a Pour with 0 Yard hours gets a line, so no line at all cannot tell "all fine" from "never read"
  const pw = !f ? fw : noHours ? `the Yard's events are ${noHours}, so no Pour is called shadow` : !pours.length && bad.length ? `${plural(bad.length, 'Blueprint', 'Blueprints')} not read: ${bad.map((b) => `${b.label} ${b.kind}`).join(', ')}`
    : !pours.length ? 'no Blueprint line in the frame: every Pour got hours, or no Blueprint was read' : '';
  s.pours = { n: pw ? null : pours.length, why: pw, list: pw ? [] : pours, untouched: pw ? null : pours.reduce((a, p) => a + p.noOrder, 0) };
  const ttc = f?.meta.ttc_median_hours, hasTtc = !!(ttc && typeof ttc === 'object' && ttc['7d'] && ttc['30d']);
  const dw = !f ? fw : hasTtc ? '' : 'the lobe\'s shadow graph has not stored a self-state yet (zeitgeistd shadow run, ZG-23)';
  s.domains = { n: dw ? null : domains.length, why: dw, list: dw ? [] : domains };
  s.ttc = { why: !f ? fw : hasTtc ? '' : dw, d7: hasTtc ? ttc['7d'] : null, d30: hasTtc ? ttc['30d'] : null };
  // post-mortems: flags.json through the Owner part; else the frame's count (no taps without flags.json)
  const d = owner?.decide;
  if (d?.ok) {
    const due = arr(d.due), answered = due.filter((x) => x.answered).length;
    s.pm = { due: due.length, open: due.length - answered, answered, why: '', from: 'flags.json' };
  } else {
    const c = f ? num(f.meta.counts?.post_mortems_due) : null;
    s.pm = { due: c, open: c, answered: null, why: c === null ? (f ? 'the frame has no post-mortem count' : fw) : '', from: 'csf.json', tapsWhy: d?.why || 'not sent' };
  }
  s.pm.monthWhy = `the Board keeps an answer only until the lobe's next run${s.pm.answered === null ? '' : ` (${s.pm.answered} since its last run)`}; the month's answers are in the lobe's database`;
  // the trust line: the lobe's own line in the frame (ZG-39), the crews' Brier from the scoreboard (ZG-40)
  const tl = f && typeof f.meta.trust === 'string' && f.meta.trust ? f.meta.trust : null;
  const board = owner?.trust?.board;
  s.trust = { line: tl, why: tl ? '' : f ? 'the lobe has no Foreman claim yet' : fw,
    crews: board?.ok && num(board.now?.value) !== null ? { value: board.now.value, claims: board.now.claims } : null, crewsWhy: board?.ok ? board.now?.missing || 'no crew made a scored claim in the window' : board?.why || 'not sent' };
  return s;
}

// the World tab's badge: shadow Pours plus post-mortems still waiting for the Owner's answer (0 when unknown)
export function selfCount(view, owner = null, now = Date.now()) {
  const s = selfState(view, owner, now);
  return (s.pours.n ?? 0) + (s.pm.open ?? 0);
}

const hrs = (h) => (num(h) === null ? 'unknown' : ago(Math.round(h * 60)));
const ttcRow = (w) => TTC_KIND.map(([k, label]) => `${label} ${hrs(w?.[k])}`).join(' · ');
const dl = (rows) => `<dl class="lobe-dl">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('')}</dl>`;
const many = (s, n) => `${s.atLeast && n ? 'at least ' : ''}${n}`;
export function selfCard(view, owner = null, now = Date.now()) {
  const s = selfState(view, owner, now), n = (s.pours.n ?? 0) + (s.pm.open ?? 0);
  const head = s.charter === 'example' ? '<p class="lobe-bad" data-self-charter="example">The Owner\'s Charter is not written yet, so the Charter domains below are the example\'s, not yours.</p>'
    : s.charter === 'locked' ? sub('Charter domains from the Owner\'s locked Charter.') : `<p class="lobe-bad" data-self-charter="unknown">Charter ${unk(s.frame.why)}.</p>`;
  const p = s.pours, dm = s.domains;
  const avoid = dl([['Shadow Pours (0 h in 14 days)', p.n === null ? unk(p.why) : many(s, p.n)],
    ['Floors with no order in them', p.untouched === null ? unk(p.why) : many(s, p.untouched)],
    ['Charter domains with 0 h in 14 days', dm.n === null ? unk(dm.why) : many(s, dm.n)]]);
  const pourList = p.list.length ? `<ul class="lobe-list" data-self="pours">${p.list.map((x) => `<li><b class="lobe-dom">${esc(x.label)}</b> ${x.touched} of ${x.floors} Floors touched in ${x.days} days; ${x.merged} merged, ${x.building} building, ${x.noOrder} with no order</li>`).join('')}</ul>` : '';
  const badList = s.bad.length && p.list.length ? sub(`Not read: ${s.bad.map((b) => `${esc(b.label)} Blueprint ${b.kind} (${esc(b.why)})`).join('; ')}.`) : '';
  const domList = dm.list.length ? `<ul class="lobe-list" data-self="domains">${dm.list.map((x) => `<li><b class="lobe-dom">${esc(x.name)}</b> 0 h in ${x.days} days${x.unmet ? `; unmet ${esc(x.unmet)}` : ''}</li>`).join('')}</ul>` : '';
  const pm = s.pm;
  const wrong = dl([['Post-mortems due', pm.due === null ? unk(pm.why) : String(pm.due) + (pm.from === 'csf.json' ? ` (from the frame; taps wait for flags.json: ${esc(pm.tapsWhy)})` : '')],
    ['Still waiting for you', pm.open === null ? unk(pm.why) : String(pm.open)],
    ['Answered this month', unk(pm.monthWhy)], ['Calibration delta', unk(NO_CALIB)]]);
  const fast = s.ttc.why ? dl([['Time-to-Close', unk(s.ttc.why)]]) : dl([['Last 7 days', ttcRow(s.ttc.d7)], ['Last 30 days', ttcRow(s.ttc.d30)], ['Screen minutes', unk('nothing measures them')]]);
  const t = s.trust;
  const trust = dl([['Foreman', t.line ? esc(t.line) : unk(t.why)], ['Crews', t.crews ? `Brier ${t.crews.value.toFixed(2)} over ${plural(t.crews.claims, 'claim', 'claims')}` : unk(t.crewsWhy)]]);
  const body = head + sub('Avoiding: Pours and Charter domains that got no hours') + avoid + pourList + badList + domList
    + sub('Got wrong: post-mortems over decisions and Sign-offs') + wrong + sub('How fast things close (medians)') + fast + sub('Trust (Brier: 0 = always right, 1 = always wrong)') + trust
    + (s.other ? sub(`${plural(s.other, 'shadow line', 'shadow lines')} in the frame not counted here (not in a shape this card reads).`) : '');
  return card('self', 'Self', n ? badge('count', String(n)) : s.frame.ok ? '' : badge('example', 'UNKNOWN'), body, 'health');
}
