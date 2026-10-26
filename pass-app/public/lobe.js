// The Board's World view (ZG-09): the lobe's frame (csf.json) as five pixel-RPG dialogue boxes: Charter, Open loops, Signals, Decisions ready, Lobe health.
// ZG-13 adds the Owner's taps: the Charter editor (Save and lock), taste taps per signal and a Focus box, proposals as Apply / Drop, and the
// morning brief's lobe line. Taps go to POST /api/lobe (wireWorld); this file never writes anything itself and never taps on its own.
// Imported by app.js (worldHtml, paintWorld, wireWorld, worldEditing, briefLobeLine); the data is state.lobe from server.mjs lobeView; tested by pass-app/test-lobe.mjs and tests/Test-PassApp.ps1.
// Every word from the frame is escaped. A missing, stale or refused frame is one plain line (never an error page, never a blank card). Yard signal titles
// name work orders: the server sends only their count and this file shows only a count. The art is palette-indexed strings in the sprites.js format, drawn
// once into CSS variables (html.lobe-px); there is no animation loop, so calm needs only the CSS reduced-motion rule for the menu cursor.
// ZG-30 adds the Glass box card (glassHtml, from state.lobeGlass) and the lobe's lines in the Activity feed (lobeSentence, lobeEventKey).
// ZG-25 turns Decisions ready into the Owner's card (decideCard, from state.lobeOwner.decide): A / B / Neither / Ask more per node, Held up / Didn't /
// Unknown per post-mortem with the Ledger's proof, all taps through wireWorld; and a signal's three causal hops fold open on a tap (causalHops).
// ZG-40 adds the Trust card (trustCard, from state.lobeOwner.trust): Brier, claims counted and the 7-day trend for the Foreman, each crew model, the
// subcontractors and the world's sources, "unknown (why)" where a number has no data, and the Brier Sign-offs as Apply / Drop taps through wireWorld.
// ZG-45 adds the Self card after Trust, with the Owner part (lobe-self.js selfCard: shadow Pours, post-mortems, Time-to-Close, the trust line).
import { esc, skyAt } from './scene.js';
import { selfCard } from './lobe-self.js';

// zeitgeistd health.py: a frame older than 2 x every 120 min is stale; a time more than 5 min ahead of the clock is wrong
export const LOBE = { staleMin: 240, futureMin: 5 };
const TOP = ['meta', '1_normative_charter', '2_endogenous_self_state', '3_exogenous_world_deltas', '4_epistemic_tensions', '5_decision_ready_nodes'];
const STATES = ['ok', 'empty: no sweep yet'];
const MISSING = 'No frame yet: the lobe has not written csf.json. Its first sweep writes it (the lobe-sweep standing order, ZG-07, ZG Pour 1).';
const arr = (x) => (Array.isArray(x) ? x : []);
const num = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);
const utc = (s) => { const t = typeof s === 'string' ? Date.parse(s) : NaN; return Number.isFinite(t) ? t : null; };
const sec = (f, k) => (f[k] && typeof f[k] === 'object' ? f[k] : {});
const mins = (ms) => Math.max(0, Math.floor(ms / 60000));
// a time span as the Board says it: 45 min, 3.5 h, 2 d
export function ago(m) {
  if (m === null || m === undefined) return 'unknown';
  if (m < 60) return `${m} min`;
  return m < 2880 ? `${(m / 60).toFixed(1).replace(/\.0$/, '')} h` : `${Math.floor(m / 1440)} d`;
}

// ---- the frame: present, missing, refused or stale (pure) ----
// why a frame is not shown, in fixed words (never the frame's own text); '' when it is a frame the lobe writes
function refusal(f, now) {
  if (!f || typeof f !== 'object' || Array.isArray(f) || Object.keys(f).join() !== TOP.join()) return 'it is not a csf.json frame (the document 6.2 sections, in order)';
  const m = f.meta;
  if (!m || typeof m !== 'object' || !STATES.includes(m.state)) return 'its meta.state is not one the lobe writes';
  if (m.charter !== 'EXAMPLE' && m.charter !== 'LOCKED') return 'its meta.charter is not EXAMPLE or LOCKED';
  const comp = utc(m.compiled_utc), sweep = m.last_sweep_utc == null ? 0 : utc(m.last_sweep_utc);
  if (comp === null || sweep === null) return 'a time in its meta cannot be read';
  if (Math.max(comp, sweep) > now + LOBE.futureMin * 60000) return 'a time in its meta is in the future';
  return '';
}
const refusedLine = (why) => `The frame was refused: ${why}. The cards come back with the next good frame.`;
// view = state.lobe: { ok: true, csf, health } or { ok: false, why }. Returns { kind: ok | missing | refused | stale, line, f, ages, age }.
export function frameOf(view, now = Date.now()) {
  if (!view || typeof view !== 'object') return { kind: 'missing', line: MISSING };
  if (view.ok !== true) {
    const why = String(view.why || '');
    return /^frame refused: /.test(why) ? { kind: 'refused', line: refusedLine(why.slice(15)) } : { kind: 'missing', line: MISSING };
  }
  const why = refusal(view.csf, now);
  if (why) return { kind: 'refused', line: refusedLine(why) };
  const m = view.csf.meta, sweep = utc(m.last_sweep_utc);
  const ages = { compiled: mins(now - utc(m.compiled_utc)), sweep: sweep === null ? null : mins(now - sweep) };
  const age = Math.max(ages.compiled, ages.sweep ?? 0);
  if (age > LOBE.staleMin) {
    const said = `compiled ${ago(ages.compiled)} ago` + (ages.sweep === null ? ', no sweep yet' : `, last sweep ${ago(ages.sweep)} ago`);
    return { kind: 'stale', ages, age, line: `The frame is stale: ${said} (the limit is ${ago(LOBE.staleMin)}). Its cards stay hidden until the lobe-sweep standing order (every 2 h) writes a fresh one.` };
  }
  return { kind: 'ok', f: view.csf, ages, age };
}

// ---- markup (pure) ----
export const card = (k, title, badge, body, ic = k) => `<section class="lobe-card" data-card="${k}" aria-labelledby="lobe-h-${k}"><div class="lobe-head"><h2 class="lobe-name" id="lobe-h-${k}"><i class="lobe-ic" data-ic="${ic}" aria-hidden="true"></i><span>${title}</span></h2>${badge}</div><div class="lobe-box">${body}</div></section>`;
const empty = (what, who) => `<p class="lobe-empty"><b>${what}</b> ${who}</p>`;
export const sub = (t) => `<p class="lobe-sub">${t}</p>`;
const items = (list, cls = 'lobe-list') => `<ul class="${cls}">${list.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>`;
export const badge = (cls, t) => `<b class="lobe-badge ${cls}">${t}</b>`;
// "DOMAIN: words" (the Charter's lines) as a domain chip and the words
const domLine = (e) => { const t = String(e ?? ''), i = t.indexOf(': '); return i > 0 ? `<li><b class="lobe-dom">${esc(t.slice(0, i))}</b> ${esc(t.slice(i + 2))}</li>` : `<li>${esc(t)}</li>`; };

// an HP-bar gauge in ten segments; tone from how good the value is (inverted: high is bad, as for hype)
export function gauge(label, v, max, { inverted = false, text = '' } = {}) {
  if (v === null) return `<div class="lobe-g"><span>${label}</span><b>unknown</b></div>`;
  const x = Math.max(0, Math.min(1, v / max)), on = Math.round(x * 10), good = inverted ? 1 - x : x;
  const tone = good >= 0.6 ? 'good' : good >= 0.35 ? 'mid' : 'bad', shown = text || (max === 1 ? v.toFixed(2) : String(Math.round(v)));
  return `<div class="lobe-g"><span>${label}</span><b>${shown}</b><span class="lobe-hp" data-tone="${tone}" role="img" aria-label="${label}: ${shown}">${'<i class="on"></i>'.repeat(on)}${'<i></i>'.repeat(10 - on)}</span></div>`;
}

function charterCard(f, owner, now) {
  if (owner) return ownerCharterCard(f, owner, now);
  const s = sec(f, '1_normative_charter'), ex = f.meta.charter !== 'LOCKED';
  const note = ex ? 'An example, not yours yet. Only the Owner writes the Charter, and it locks on the Owner\'s tap (ZG-13, ZG Pour 2).' : 'Written and locked by the Owner.';
  const goals = arr(s.north_star_objectives), rails = arr(s.hard_guardrails);
  const body = goals.length ? sub(note) + `<ul class="lobe-list">${goals.map(domLine).join('')}</ul>` + (rails.length ? sub('Hard guardrails') + `<ul class="lobe-list rails">${rails.map(domLine).join('')}</ul>` : '')
    : empty('No Charter lines in this frame.', 'ZG-02 seeds the EXAMPLE (ZG Pour 1); the Owner\'s own Charter locks on a tap (ZG-13, ZG Pour 2).');
  return card('charter', 'Charter', ex ? badge('example', 'EXAMPLE') : badge('locked', 'LOCKED'), body);
}

function loopsCard(f) {
  const loops = arr(sec(f, '2_endogenous_self_state').active_open_loops), total = num(f.meta.counts?.open_loops) ?? loops.length;
  let body = empty('No open loops yet.', 'The gate\'s loop finder (ZG-11, ZG Pour 2) and the last session\'s loop (ZG-39, ZG Pour 5) fill this.');
  if (loops.length) body = sub(`${loops.length}${total > loops.length ? ` of ${total}` : ''} open, heaviest first`) + items(loops, 'lobe-menu');
  else if (total) body = sub(`${total} open; this frame trimmed them to fit its 2,400 characters.`);
  return card('loops', 'Open loops', total ? badge('count', String(total)) : '', body);
}

const METRICS = [['signal', 'Signal'], ['fact', 'Fact'], ['hype', 'Hype', true], ['surprise', 'Surprise']];
function signalRow(e, taps) {
  const sc = e.scores && typeof e.scores === 'object' ? e.scores : {};
  const gs = METRICS.map(([k, label, inverted]) => gauge(label, num(sc[k]), 100, { inverted })).join('') + gauge('Source trust', num(e.source_brier_trust), 1);
  const band = Number.isInteger(e.band) ? badge('band', `BAND ${e.band}`) + ' ' : '';
  return `<li class="lobe-sig"><p class="lobe-ttl">${esc(e.event)}</p><div class="lobe-gs">${gs}</div><p class="lobe-who">${band}Who profits if you believe it: ${e.incentive_note ? esc(e.incentive_note) : 'not known'}</p>${causalHops(e.causal_3rd_order_opening)}${taps ? tasteTaps(e.event) : ''}</li>`;
}
function signalsCard(f, taps = false) {
  const s3 = sec(f, '3_exogenous_world_deltas'), sig = arr(s3.actionable_signal).filter((e) => e && typeof e === 'object');
  const hype = arr(s3.quarantined_hype_waves).length, n24 = num(f.meta.counts?.world_signals_24h) ?? 0;
  const foot = sub(`${n24} in the last 24 h` + (hype ? ` · ${hype} loud ${hype === 1 ? 'item' : 'items'} held back as hype` : ''));
  const body = sig.length ? `<ul class="lobe-sigs">${sig.map((e) => signalRow(e, taps)).join('')}</ul>${foot}`
    : empty('No world signals yet.', 'Public feeds (ZG-19, ZG Pour 3) bring them in, and the gate scores them (ZG-11, ZG Pour 2).') + (hype || n24 ? foot : '');
  return card('signals', 'Signals', sig.length ? badge('count', String(sig.length)) : '', body);
}

// "<decision id>: A <steelman> | B <steelman>" (csf.py unlocked_choices) as a two-line RPG choice menu
function choice(e) {
  const t = String(e ?? ''), i = t.indexOf(': '), id = i > 0 ? t.slice(0, i) : t, m = /^A (.*) \| B (.*)$/.exec(i > 0 ? t.slice(i + 2) : '');
  const ab = m ? `<ol class="lobe-menu ab"><li><b>A</b> ${esc(m[1])}</li><li><b>B</b> ${esc(m[2])}</li></ol>` : '';
  return `<li class="lobe-dec"><p class="lobe-ttl mono">${esc(id)}</p>${ab}</li>`;
}
function decisionsCard(f) {
  const s5 = sec(f, '5_decision_ready_nodes'), ready = arr(s5.unlocked_choices), pm = arr(s5.pending_post_mortems);
  const total = num(f.meta.counts?.decisions_ready) ?? ready.length, pmHtml = pm.length ? sub(`Post-mortems due: ${pm.length}`) + items(pm) : '';
  const body = ready.length ? sub('Needs sign-off: the Owner picks A or B with a tap (ZG-25, ZG Pour 3). Read-only here.') + `<ul class="lobe-decs">${ready.map(choice).join('')}</ul>${pmHtml}`
    : empty('No decision is ready.', 'Decision nodes grow from open loops (ZG-24, ZG Pour 3); the A / B tap comes with ZG-25.') + pmHtml;
  return card('decide', 'Decisions ready', total ? badge('count', String(total)) : '', body);
}

function healthCard(f, r) {
  const m = f.meta, c = m.counts && typeof m.counts === 'object' ? m.counts : {}, self = sec(f, '2_endogenous_self_state');
  const yard = typeof self.yard_signals === 'number' ? self.yard_signals : arr(self.yard_signals).length;   // a count only, never the titles
  const head = m.state === 'ok' ? `<p class="lobe-good">Site ZG's lobe is fresh: last sweep ${ago(r.ages.sweep)} ago.</p>`
    : `<p class="lobe-bad">No sweep yet: the lobe compiled an empty frame (state "${esc(m.state)}"). Its first sweep (ZG-07, ZG Pour 1) fills it.</p>`;
  const left = Math.max(0, LOBE.staleMin - r.age);
  const rows = [['Last sweep', r.ages.sweep === null ? 'never' : `${ago(r.ages.sweep)} ago`], ['Compiled', `${ago(r.ages.compiled)} ago`],
    ['Frame', `${num(m.chars) ?? '?'} chars, about ${num(m.tokens_est) ?? '?'} tokens` + (num(m.trimmed) ? `, ${m.trimmed} trimmed to fit` : '')],
    ['Last 24 h', `${num(c.items_24h) ?? 0} items, ${num(c.world_signals_24h) ?? 0} world signals`], ['Yard events', `${yard} (a count only: work orders stay off the phone)`]];
  const body = head + gauge('Fresh for', left, LOBE.staleMin, { text: ago(left) }) + `<dl class="lobe-dl">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('')}</dl>`
    + sub('Stop-work orders, the DLQ, skipped sweeps and the budgets are on the Glass box card (ZG-30). This card reads csf.json only. The Foreman gets its cloud-safe part (csf-brief.json) in the toolbox talk (ZG-08).');
  return card('health', 'Lobe health', m.state === 'ok' ? badge('locked', 'FRESH') : badge('bad', 'NO SWEEP'), body);
}

function hud(f, r) {
  const c = f.meta.counts && typeof f.meta.counts === 'object' ? f.meta.counts : {};
  const chip = (ic, n, w) => `<span class="lobe-chip"><i class="lobe-ic s" data-ic="${ic}" aria-hidden="true"></i><b>${n}</b> ${w}</span>`;
  return `<p class="lobe-hud">${chip('loops', num(c.open_loops) ?? 0, 'open loops')}${chip('signals', num(c.world_signals_24h) ?? 0, 'signals')}${chip('decide', num(c.decisions_ready) ?? 0, 'decisions')}${chip('health', ago(r.age), 'old')}</p>`;
}

// the whole view. view = state.lobe; now = the clock (ms)
// owner = state.lobeOwner (ZG-13: the Owner's Charter file, taste taps and proposals); without it the view is ZG-09's read-only five cards
// glass = state.lobeGlass (ZG-30: the glass box card, last); it shows even with no frame, since a missing frame is when it matters most
export function worldHtml(view, { now = Date.now(), owner = null, glass = null } = {}) {
  const r = frameOf(view, now), g = glass ? glassHtml(glass, view, now) : '';
  if (r.kind !== 'ok') {
    const line = `<p class="lobe-line ${r.kind}" role="status" data-lobe="${r.kind}">${esc(r.line)}</p>`;
    return owner || g ? `<div class="lobe" data-lobe="${r.kind}">${line}${owner ? charterCard(null, owner, now) + tasteCard(owner, now) + (owner.decide ? decideCard(null, owner.decide, now) : '') + (owner.trust ? trustCard(owner.trust, now) : '') + selfCard(view, owner, now) : ''}${g}</div>` : line;
  }
  const f = r.f, o = sceneOpts(view, now);
  const label = `The lookout over Site ZG: ${o.signals} of 3 signal rings on the mast, the Charter flag ${f.meta.charter}, the lamp ${o.lit ? 'lit' : 'out'}.`;
  return `<div class="lobe" data-lobe="ok"><div class="lobe-scene" role="img" aria-label="${esc(label)}"></div>${hud(f, r)}${charterCard(f, owner, now)}${loopsCard(f)}${signalsCard(f, !!owner)}${owner ? tasteCard(owner, now) : ''}${owner?.decide ? decideCard(f, owner.decide, now) : decisionsCard(f)}${owner?.trust ? trustCard(owner.trust, now) : ''}${owner ? selfCard(view, owner, now) : ''}${healthCard(f, r)}${g}</div>`;
}

// ---- ZG-40: the Trust card (pure). t = state.lobeOwner.trust from server.mjs trustView: { file, board, watch, signoffs }, numbers, ids and kinds only ----
// One row per family: the Foreman, every crew model, the subcontractors, the world's claims and its top 5 sources. Each row: Brier (the loss: 0 = always
// right, 1 = always wrong), the claims it is counted over, and the 7-day trend arrow; every number with no data behind it says "unknown" and why.
export const TREND_WORD = { better: '↓ better', worse: '↑ worse', flat: '→ flat' };
const b2 = (v) => v.toFixed(2);
// the Brier now against 7 days before: lower is better. null when either side has no number.
export function trendOf(now, then) {
  if (num(now) === null || num(then) === null) return null;
  const d = Math.round((now - then) * 100);
  const dir = d < 0 ? 'better' : d > 0 ? 'worse' : 'flat';
  return { dir, say: dir === 'flat' ? `${TREND_WORD.flat} (${b2(now)} both)` : `${TREND_WORD[dir]} (${b2(then)} → ${b2(now)})` };
}
const unk = (why) => `unknown (${esc(why)})`;
// one row: kind chip, name, a Brier gauge (high is bad), then claims counted, any extra facts and the trend, each "unknown (why)" without data
function trustRow({ key, kind, name, brier, brierWhy, claims, claimsWhy, extra = [], trend, trendWhy }) {
  const g = brier === null ? `<div class="lobe-g"><span>Brier</span><b>${unk(brierWhy)}</b></div>` : gauge('Brier', brier, 1, { inverted: true, text: b2(brier) });
  const facts = [claims === null ? `claims counted ${unk(claimsWhy)}` : `${claims} ${claims === 1 ? 'claim' : 'claims'} counted`, ...extra,
    trend ? `7-day trend ${trend.say}` : `7-day trend ${unk(trendWhy)}`];
  return `<li class="lobe-dec" data-trust="${esc(key)}"${trend ? ` data-trend="${trend.dir}"` : ''}><p class="lobe-ttl"><b class="lobe-dom">${kind}</b> ${esc(name)}</p>${g}<p class="lobe-who">${facts.join(' · ')}</p></li>`;
}
const crewName = (id) => (id === 'unknown' ? 'unknown model' : id);
function foremanRow(file, watch) {
  const fm = file.ok ? file.foreman : null, scored = fm && fm.n > 0 && fm.brier !== null;
  const why = !file.ok ? file.why : fm.claims ? `${fm.n} of ${fm.claims} claims resolved so far` : `the lobe says "${fm.status}"`;
  const unproven = watch?.ok ? esc(`${watch.unproven} unproven ${watch.unproven === 1 ? 'bullet' : 'bullets'} in memory (memory-truth's ${watch.field} count)`) : `unproven bullets ${unk(watch?.why || 'not sent')}`;
  return trustRow({ key: 'foreman', kind: 'FOREMAN', name: 'The Foreman', brier: scored ? fm.brier : null, brierWhy: why, claims: fm ? fm.n : null, claimsWhy: file.why,
    extra: [unproven], trend: null, trendWhy: file.ok ? 'trust.json keeps no history yet' : file.why });
}
function crewRows(board) {
  if (!board?.ok) return trustRow({ key: 'crews', kind: 'CREWS', name: 'Every crew', brier: null, brierWhy: board?.why || 'not sent', claims: null, claimsWhy: board?.why || 'not sent', trend: null, trendWhy: board?.why || 'not sent' });
  const nowB = board.now, old = board.weekAgo, noOld = `no scoreboard line from 7 days before; the first with Brier is from ${dateOf(board.firstAt)}`;
  const roles = sub(`Inspector said ship: ${nowB.inspector.value === null ? 'unknown' : b2(nowB.inspector.value)} over ${nowB.inspector.claims} · build crews said the tests pass: ${nowB.builder.value === null ? 'unknown' : b2(nowB.builder.value)} over ${nowB.builder.claims}`
    + (nowB.pending ? ` · ${nowB.pending} kept ${nowB.pending === 1 ? 'merge is' : 'merges are'} still inside ${nowB.pending === 1 ? 'its' : 'their'} 7 days` : '') + `. From the scoreboard of ${dateOf(board.at)}.`);
  const all = trustRow({ key: 'crews', kind: 'CREWS', name: 'Every crew', brier: nowB.value, brierWhy: nowB.missing || 'no crew made a scored claim in the window', claims: nowB.claims,
    trend: old ? trendOf(nowB.value, old.value) : null, trendWhy: old ? 'no crew Brier 7 days before' : noOld });
  const models = [...nowB.models].sort((a, b) => b.claims - a.claims || a.id.localeCompare(b.id)).map((m) => {
    const was = old?.models.find((x) => x.id === m.id);
    return trustRow({ key: 'crew:' + m.id, kind: 'CREW', name: crewName(m.id), brier: m.value, brierWhy: 'no scored claim in the window', claims: m.claims,
      trend: was ? trendOf(m.value, was.value) : null, trendWhy: !old ? noOld : 'it had no Brier 7 days before' });
  });
  return `<ul class="lobe-decs">${all}${models.join('')}</ul>${roles}`;
}
function builderRows(file) {
  const b = file.ok ? file.builders : null;
  if (!b || b.status !== 'ok' || !b.members.length) {
    const why = !file.ok ? file.why : `nothing scores them yet: trust.json's builders family says "${b.status}"`;
    return trustRow({ key: 'builders', kind: 'SUBS', name: 'Subcontractors', brier: null, brierWhy: why, claims: null, claimsWhy: why, trend: null, trendWhy: why });
  }
  return b.members.map((m) => trustRow({ key: 'sub:' + m.id, kind: 'SUB', name: m.id, brier: m.brier, claims: m.n, trend: null, trendWhy: 'trust.json keeps no history yet' })).join('');
}
function worldRows(file) {
  if (!file.ok) return trustRow({ key: 'world', kind: 'WORLD', name: 'World claims', brier: null, brierWhy: file.why, claims: null, claimsWhy: file.why, trend: null, trendWhy: file.why });
  const w = file.world, scored = w.n > 0 && w.brier !== null;
  const mean = w.sourcesMeanTrust === null ? `mean source trust ${unk(w.sourcesScored ? 'not stated' : 'no source scored yet')}` : `mean trust ${b2(w.sourcesMeanTrust)} over ${w.sourcesScored ?? '?'} scored ${w.sourcesScored === 1 ? 'source' : 'sources'}`;
  const fam = trustRow({ key: 'world', kind: 'WORLD', name: 'World claims', brier: scored ? w.brier : null, brierWhy: `the lobe says "${w.status}"`, claims: w.n, extra: [mean], trend: null, trendWhy: 'trust.json keeps no history yet' });
  const top = w.sources?.length ? w.sources.map((s) => trustRow({ key: 'source:' + s.id, kind: 'SOURCE', name: s.id, brier: s.brier, brierWhy: 'not stated', claims: s.n, trend: null, trendWhy: 'trust.json keeps no history yet' })).join('')
    : `<li class="lobe-dec" data-trust="sources"><p class="lobe-who"><b class="lobe-dom">SOURCES</b> Top 5 sources ${unk(w.sources ? 'trust.json lists none scored yet' : 'trust.json carries no per-source scores yet, only their mean')}</p></li>`;
  return fam + top;
}
const SIGNOFF_WORD = { apply: 'Apply', drop: 'Drop' };
function signoffItem(s, now) {
  const who = s.sourceName || s.source ? esc(s.sourceName || s.source) : `a ${s.privacy || 'private'} source (its name stays in the lobe)`;
  const move = s.from === null || s.to === null ? 'a change of unknown size' : `trust ${b2(s.from)} → ${b2(s.to)}${s.delta === null ? '' : ` (${s.delta > 0 ? '+' : ''}${s.delta.toFixed(2)})`}`;
  const taps = s.answered ? `<p class="lobe-good">You chose ${SIGNOFF_WORD[s.answered.choice] || esc(s.answered.choice)} ${agoAt(s.answered.at, now)}. The lobe applies it on its next run.</p>`
    : `<p class="lobe-row"><button type="button" class="btn primary" data-signoff="${esc(s.id)}" data-choice="apply">Apply</button><button type="button" class="btn" data-signoff="${esc(s.id)}" data-choice="drop">Drop</button></p>`;
  return `<li class="lobe-dec" data-signoff-node="${esc(s.id)}"><p class="lobe-ttl mono">${esc(s.id)}</p><p class="lobe-who">${s.status ? `<b class="lobe-dom">${esc(s.status)}</b> ` : ''}${who}: ${move}${s.created ? `, proposed ${agoAt(s.created, now)}` : ''}</p>${taps}</li>`;
}
export function trustCard(t, now = Date.now()) {
  const file = t?.file || { ok: false, why: 'not sent' }, so = t?.signoffs || { ok: false, why: 'not sent', pending: [] };
  const open = arr(so.pending).filter((s) => !s.answered).length;
  const head = file.ok ? sub(`Brier: 0 = always right, 1 = always wrong. From trust.json (${file.compiledUtc ? `${agoAt(file.compiledUtc, now)}` : 'time unknown'}) and the scoreboard; numbers only, no claim text.`)
    : `<p class="lobe-bad" data-trust-file="unknown">trust.json unknown: ${esc(file.why)}.</p>` + sub('The Foreman, subcontractor and world rows wait for it; the crews come from the scoreboard.');
  const so0 = so.ok ? (so.pending.length ? sub(`Sign-offs: ${so.pending.length}. A source's trust would move more than the lobe may move it alone; nothing changes until you tap Apply.`) + `<ul class="lobe-decs">${so.pending.map((s) => signoffItem(s, now)).join('')}</ul>`
    : empty('No Sign-off waiting.', 'A change to a source\'s trust over the threshold waits here for your Apply or Drop (ZG-20).'))
    : sub(`Sign-offs unknown: ${esc(so.why)}.`);
  const body = head + sub('Foreman') + `<ul class="lobe-decs">${foremanRow(file, t?.watch)}</ul>` + sub('Crews') + crewRows(t?.board)
    + sub('Subcontractors') + `<ul class="lobe-decs">${builderRows(file)}</ul>` + sub('World') + `<ul class="lobe-decs">${worldRows(file)}</ul>` + so0;
  return card('trust', 'Trust', open ? badge('count', String(open)) : file.ok ? '' : badge('example', 'UNKNOWN'), body, 'decide');   // the signpost icon: app.css draws no trust icon of its own
}

// ---- ZG-25: the Owner's decision and post-mortem card (pure). d = state.lobeOwner.decide from server.mjs decideView ----
// Law 1: nothing is recommended. A and B (and Neither, Ask more) are the same plain button; the steelmen show as the lobe wrote them.
export const DECIDE_WORD = { A: 'A', B: 'B', neither: 'Neither', 'ask-more': 'Ask more' };
export const PM_WORD = { held: 'Held up', didnt: "Didn't", unknown: 'Unknown' };
const PROOF_CLS = { 'on-main': 'lobe-good', undone: 'lobe-bad', replaced: 'lobe-bad' };
const dateOf = (iso) => { const t = utc(iso); return t === null ? 'an unknown date' : new Date(t).toISOString().slice(0, 10); };
// a signal's causal tree (ZG-26 csf causal_3rd_order_opening): up to three hops, folded until the Owner taps; a list, or one string with "->" between hops
export function causalHops(c) {
  const raw = Array.isArray(c) ? c : typeof c === 'string' ? c.split(/\s*(?:->|→)\s*/) : [];
  const hops = raw.map((x) => (typeof x === 'string' ? x : x && typeof x === 'object' ? String(x.text ?? x.event ?? '') : '')).map((s) => s.trim()).filter(Boolean).slice(0, 3);
  return hops.length ? `<details class="lobe-seed" data-causal><summary>What could follow: ${hops.length} ${hops.length === 1 ? 'hop' : 'hops'}</summary><ol class="lobe-list">${hops.map((h, i) => `<li><b class="lobe-dom">Hop ${i + 1}</b> ${esc(h)}</li>`).join('')}</ol></details>` : '';
}
function decideNode(x, now) {
  const known = x.a !== null && x.a !== undefined && x.b !== null && x.b !== undefined;
  const ab = known ? `<ol class="lobe-menu ab"><li><b>A</b> ${esc(x.a)}</li><li><b>B</b> ${esc(x.b)}</li></ol>` : '';
  const taps = x.answered ? `<p class="lobe-good">You chose ${esc(DECIDE_WORD[x.answered.choice] || x.answered.choice)} ${agoAt(x.answered.at, now)}. The lobe records it on its next run.</p>`
    : known ? `<p class="lobe-row">${Object.entries(DECIDE_WORD).map(([c, w]) => `<button type="button" class="btn" data-decide="${esc(x.id)}" data-choice="${c}">${w}</button>`).join('')}</p>`
      : sub('A and B are not in this frame: it carries the top 3 nodes. They show here when this one is in the top 3, and the taps with them.');
  return `<li class="lobe-dec" data-node="${esc(x.id)}"><p class="lobe-ttl mono">${esc(x.id)}</p>${x.question ? `<p class="lobe-ttl">${esc(x.question)}</p>` : ''}${ab}${x.readyAt ? sub(`Ready ${agoAt(x.readyAt, now)}.`) : ''}${taps}</li>`;
}
function postMortem(x, now) {
  const pf = x.proof || { kind: 'unknown', say: 'not sent' };
  const proof = `<p class="${PROOF_CLS[pf.kind] || 'lobe-sub'}" data-proof="${esc(pf.kind)}">Ledger: ${esc(pf.say)}</p>`;
  const taps = x.answered ? `<p class="lobe-good">You said ${esc(PM_WORD[x.answered.choice] || x.answered.choice)} ${agoAt(x.answered.at, now)}. The lobe records it on its next run.</p>`
    : `<p class="lobe-row">${Object.entries(PM_WORD).map(([c, w]) => `<button type="button" class="btn" data-pm="${esc(x.id)}" data-day="${Number(x.day)}" data-choice="${c}">${w}</button>`).join('')}</p>`;
  return `<li class="lobe-dec" data-pm-node="${esc(x.id)}"><p class="lobe-ttl mono">${esc(x.id)}</p><p class="lobe-who">Day ${Number(x.day)} check${x.choice ? `: you chose ${esc(DECIDE_WORD[x.choice] || x.choice)}` : ''}. Did it hold up?</p>${proof}`
    + `${sub(`Answer by ${dateOf(x.expiresAt)}; unanswered, the lobe records it as unknown.`)}${taps}</li>`;
}
export function decideCard(f, d, now = Date.now()) {
  if (!d || d.ok !== true) return card('decide', 'Decisions ready', badge('example', 'UNKNOWN'), `<p class="lobe-bad">Decisions unknown: ${esc(d?.why || 'not sent')}.</p>`
    + sub('Nothing can be answered until the lobe\'s decisions run writes its flags.json (ZG-24).'));
  const ready = arr(d.ready), due = arr(d.due), open = ready.filter((x) => !x.answered).length + due.filter((x) => !x.answered).length;
  const law = sub('Only you decide. Nothing here picks for you or marks a better option; each tap is one line the lobe records on its next run.');
  const rHtml = ready.length ? sub(`Needs sign-off: ${ready.length}`) + `<ul class="lobe-decs">${ready.map((x) => decideNode(x, now)).join('')}</ul>` : empty('No decision is waiting.', 'Decision nodes grow from open loops (ZG-24); each waits here for your tap.');
  const pHtml = due.length ? sub(`Post-mortems due: ${due.length}`) + `<ul class="lobe-decs">${due.map((x) => postMortem(x, now)).join('')}</ul>` : '';
  return card('decide', 'Decisions ready', open ? badge('count', String(open)) : '', law + rHtml + pHtml);
}

// ---- ZG-30: the glass box (pure). g = state.lobeGlass from server.mjs lobeGlassView: counts, ids, kinds and times only ----
const n0 = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);
const thou = (x) => (x === null ? 'unknown' : Math.round(x).toLocaleString('en-US'));
const unknown = (why) => `unknown: ${esc(why || 'no reason given')}`;
// red, unknown or ok, with the reasons in fixed words. Red: the frame older than 2 x the sweep interval, or a Stop-work order open.
export function glassState(g, view, now = Date.now()) {
  const hb = g?.heartbeat?.ok ? g.heartbeat : null, every = n0(hb?.everyMin) ?? LOBE.staleMin / 2, limit = 2 * every;
  const r = frameOf(view, now), red = [], unk = [];
  let age = r.kind === 'ok' || r.kind === 'stale' ? r.age : null;
  if (age === null && hb && n0(hb.csfAgeMin) !== null && utc(hb.lastRun) !== null) age = hb.csfAgeMin + mins(now - utc(hb.lastRun));   // the heartbeat's age, aged since
  if (age === null) unk.push(r.kind === 'refused' ? 'the frame was refused' : 'no frame to age');
  else if (age > limit) red.push(`the frame is ${ago(age)} old (the limit is 2 x ${ago(every)} = ${ago(limit)})`);
  if (!hb) unk.push(`the heartbeat: ${g?.heartbeat?.why || 'not sent'}`);
  else if (n0(hb.breakersOpen)) red.push(`${hb.breakersOpen} Stop-work ${hb.breakersOpen === 1 ? 'order' : 'orders'} open`);
  if (!g?.events?.ok) unk.push(`the events file: ${g?.events?.why || 'not sent'}`);
  return { kind: red.length ? 'red' : unk.length ? 'unknown' : 'ok', red, unk, age, limit };
}
export function glassHtml(g, view, now = Date.now()) {
  const s = glassState(g, view, now), hb = g?.heartbeat?.ok ? g.heartbeat : null, d = g?.today || null, evOk = !!g?.events?.ok;
  const head = s.kind === 'red' ? `<p class="lobe-bad" data-glass="red">Needs a look: ${esc(s.red.join('; '))}.</p>`
    : s.kind === 'unknown' ? `<p class="lobe-bad" data-glass="unknown">Health unknown: ${esc(s.unk.join('; '))}.</p>` : '<p class="lobe-good" data-glass="ok">The lobe is running: fresh frame, no Stop-work order open.</p>';
  const more = s.kind === 'red' && s.unk.length ? sub(`Also unknown: ${esc(s.unk.join('; '))}.`) : '';
  const sweepAt = utc(g?.lastSweepUtc), why = (w) => unknown(w);
  const skipWords = d && d.skipWhy?.length ? ` (${d.skipWhy.map(([w, k]) => `${esc(w)} ${n0(k) ?? '?'}`).join(', ')})` : '';
  const partial = d?.partial ? ' (at least: the events file starts after midnight)' : '';
  const tokens = d ? n0(d.tokens) : null, ceiling = n0(g?.ceiling);
  const rows = [
    ['Last sweep', sweepAt !== null ? `${ago(mins(now - sweepAt))} ago` : evOk ? 'none in the events file' : why(g?.events?.why)],
    ['Sweeps today', d ? `${n0(d.sweeps) ?? 0} run, ${n0(d.skips) ?? 0} skipped${skipWords}${partial}` : why(g?.events?.why)],
    ['Gate today', d ? `${n0(d.passes) ?? 0} passed, ${n0(d.drops) ?? 0} dropped` : why(g?.events?.why)],
    ['Tokens today', d ? `${thou(tokens)} of ${ceiling === null ? unknown(g?.ceilingWhy) : thou(ceiling)}${partial}` : why(g?.events?.why)],
    ['Queue', n0(g?.queue) !== null ? `${g.queue} waiting` : why(g?.queueWhy)],
    ['DLQ', hb && n0(hb.dlq) !== null ? `${hb.dlq} unresolved` : why(hb ? 'the heartbeat has no dlq count' : g?.heartbeat?.why)],
    ['Stop-work orders', hb && n0(hb.breakersOpen) !== null ? `${hb.breakersOpen} open at the last run` : why(hb ? 'the heartbeat has no count' : g?.heartbeat?.why)],
    ['Last run', hb ? `${ago(mins(now - utc(hb.lastRun)))} ago${hb.failing ? `, with ${n0(hb.found) ?? 'some'} ${hb.found === 1 ? 'problem' : 'problems'}` : ''}` : why(g?.heartbeat?.why)],
  ];
  const trips = (g?.trips || []).filter((t) => t && t.id);
  if (trips.length) rows.push(['Tripped in 24 h', trips.map((t) => `${esc(t.id)} ${utc(t.ts) === null ? '' : ago(mins(now - utc(t.ts))) + ' ago'}`).join(', ')]);
  const bands = hb?.bands?.length ? sub('Bands: last fetch') + `<dl class="lobe-dl">${hb.bands.map((b) => `<dt>Band ${b.band} ${esc(b.name)}</dt><dd>${!n0(b.sources) ? 'no sources yet' : utc(b.newestUtc) === null ? `${b.sources} sources, nothing fetched yet` : `${ago(mins(now - utc(b.newestUtc)))} ago, ${b.sources} sources, ${n0(b.items24h) ?? 0} items in 24 h`}</dd>`).join('')}</dl>`
    : sub(`Bands: ${hb ? 'the heartbeat lists none yet' : why(g?.heartbeat?.why)}.`);
  const ram = g?.ram || {}, budgets = `<p class="lobe-sub" data-budgets>Budgets: RAM ${thou(n0(ram.freeMb))} MB free (a sweep needs ${thou(n0(ram.needMb))} MB) · tokens ${d ? thou(tokens) : 'unknown'} of ${ceiling === null ? 'unknown' : thou(ceiling)} today</p>`;
  const gauges = d && ceiling ? gauge('Tokens used', tokens, ceiling, { inverted: true, text: `${Math.round((tokens / ceiling) * 100)}%` }) : '';
  const bdg = s.kind === 'red' ? badge('bad', 'RED') : s.kind === 'unknown' ? badge('example', 'UNKNOWN') : badge('locked', 'OK');
  return `<section class="lobe-card" data-card="glass" aria-labelledby="lobe-h-glass"><div class="lobe-head"><h2 class="lobe-name" id="lobe-h-glass"><i class="lobe-ic" data-ic="health" aria-hidden="true"></i><span>Glass box</span></h2>${bdg}</div>`
    + `<div class="lobe-box">${head}${more}${budgets}${gauges}<dl class="lobe-dl">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('')}</dl>${bands}`
    + sub('Counts, ids and kinds only: no item text leaves the lobe. Read from its events file and heartbeat; the Board never opens its database.') + '</div></section>';
}

// ---- ZG-30: one lobe line in the Activity feed (src 'lobe'): [tone, html], the Glossary's words, counts, ids and kinds only ----
const SKIP_WORDS = [[/\bram\b|memory/i, 'low RAM'], [/model|ollama/i, 'model down'], [/governor/i, 'the governor'], [/claude|window/i, 'the Claude window']];
export function lobeSentence(e) {
  const dt = e?.detail && typeof e.detail === 'object' ? e.detail : {}, num = (k) => n0(dt[k]), tgt = e?.target ? ` <span class="mono">${esc(e.target)}</span>` : '';
  const L = '<b>Lobe</b>', t = String(e?.type || '');
  if (t === 'SWEEP_START') return ['', `${L} sweep started`];
  if (t === 'SWEEP_DONE') return [dt.error ? 'fail' : '', `${L} sweep done: ${num('scored') ?? 0} scored, ${num('dropped') ?? 0} dropped, ${thou(num('tokens') ?? 0)} tokens${num('dlq') ? `, ${num('dlq')} to the DLQ` : ''}${dt.error ? ' · it failed' : ''}`];
  if (t === 'INGEST') return ['', `${L} took in new items${e.layer ? ` (${esc(e.layer)})` : ''}${num('items') !== null ? `: ${num('items')}` : ''}`];
  if (t === 'GATE_PASS') return ['', `${L} gate passed item${tgt}${e.layer ? ` at ${esc(e.layer)}` : ''}`];
  if (t === 'GATE_DROP') {
    const score = Object.keys(dt).find((k) => /score|signal|total/.test(k) && num(k) !== null);
    const by = typeof dt.rule === 'string' ? `rule <span class="mono">${esc(dt.rule)}</span>` : score ? `${esc(score.replace(/_/g, ' '))} ${num(score)}` : 'no rule or score given';
    return ['', `${L} gate dropped item${tgt}: ${by}`];
  }
  if (t === 'BREAKER_TRIP') return ['fail', `<b>Stop-work order</b> on the lobe's${tgt || ' connector'}`];
  if (t === 'SKIP') {
    const r = typeof dt.reason === 'string' ? dt.reason : '', word = SKIP_WORDS.find(([rx]) => rx.test(r));
    return ['ask', `${L} skipped a ${typeof dt.run === 'string' ? esc(dt.run) : 'run'}: ${word ? `<b>${word[1]}</b>${r ? ` (${esc(r)})` : ''}` : r ? esc(r) : 'no plain reason given'}`];
  }
  if (t === 'CSF_RECOMPILED') return ['', `${L} frame rewritten`];
  if (t === 'CSF_REFUSED') return ['fail', `${L} frame refused; the last good one stays`];
  if (t === 'QUARANTINE') return ['fail', `${L} item${tgt} held back`];
  return ['', `${L} <span class="mono">${esc(t)}</span>${tgt}`];
}
// the Activity feed drops a repeat lobe line by its type and id (after a rotation the Board reads lines again): one key per line
export const lobeEventKey = (e) => (e?.src === 'lobe' ? `lobe:${e.type}:${e.id}:${e.ts}` : `${e?.ts}${e?.type}${e?.job}`);

// ---- ZG-13: the Owner's cards (pure markup). owner = { charter: {state, why, sha256, lockedAt, charter}, proposals: [], taste: [] } ----
const TASTE_WORD = { 'taste-up': 'Up', 'taste-down': 'Down', 'taste-mute': 'Muted', 'taste-focus': 'Focus' };
const PROPOSE_WORD = { 'taste-up': 'Raise', 'taste-down': 'Lower', 'taste-mute': 'Mute', 'taste-focus': 'Focus on' };
const agoAt = (iso, now = Date.now()) => { const t = utc(iso); return t === null ? 'at an unknown time' : `${ago(mins(now - t))} ago`; };
// the up / down / mute taps under one signal; the key is the signal's title (the frame names no source: csf.py)
export function tasteTaps(title) {
  const k = String(title ?? '').replace(/\s+/g, ' ').trim().slice(0, 120); if (!k) return '';
  const b = (op, w, label) => `<button type="button" class="text-btn lobe-tap" data-taste="${op}" data-key="${esc(k)}" aria-label="${label}: ${esc(k)}">${w}</button>`;
  return `<p class="lobe-taps">${b('taste-up', 'Up', 'More like this')}${b('taste-down', 'Down', 'Less like this')}${b('taste-mute', 'Mute', 'Mute this')}</p>`;
}
const field = (name, label, value, { max = 300, hint = '' } = {}) => `<label class="lobe-f"><span>${label}</span><input name="${name}" maxlength="${max}" autocomplete="off" value="${esc(value)}"${hint ? ` placeholder="${esc(hint)}"` : ''}></label>`;
export function domFieldset(i, d = {}) {
  return `<fieldset class="lobe-dfs" data-dom="${i}"><legend>Domain ${i + 1}</legend>${field('name', 'Domain', d.name || '', { max: 64, hint: 'a short name, like WORK' })}${field('objective', 'Objective', d.objective || '', { hint: 'a result you can check' })}`
    + `${field('hardConstraint', 'Hard constraint', d.hardConstraint || '', { hint: 'a line it never crosses (optional)' })}${field('dependsOn', 'Depends on', (d.dependsOn || []).join(', '), { hint: 'other domains, commas between (optional)' })}</fieldset>`;
}
let editorOpen = false;
function charterEditor(c) {
  const doms = c?.domains?.length ? c.domains : [{}];
  return `<details class="lobe-edit" data-lobe-edit${editorOpen ? ' open' : ''}><summary>${c ? 'Edit and lock again' : 'Write your Charter'}</summary><form class="lobe-form" data-charter-form novalidate>`
    + field('missionOrder', 'Mission order', c?.missionOrder || '', { hint: 'which domain wins when they compete (optional)' })
    + `<div data-doms>${doms.map((d, i) => domFieldset(i, d)).join('')}</div>`
    + `<p class="lobe-row"><button type="button" class="btn" data-charter-add>Add a domain</button><button type="submit" class="btn primary">Save and lock</button></p>`
    + sub('Save and lock is your tap: the Board writes CHARTER.md and logs the lock with its fingerprint (sha256). The lobe imports it on its next run. A hand edit later breaks the lock until you lock again here.')
    + '</form></details>';
}
function ownerCharterCard(f, owner, now = Date.now()) {
  const o = owner.charter || { state: 'none' }, frameLocked = f?.meta.charter === 'LOCKED', mine = o.charter;
  const head = {
    none: '<p class="lobe-bad">Your Charter isn\'t written yet.</p>' + sub('Only you write it: your domains, what each must achieve, the line each never crosses. Write it below and tap Save and lock.'),
    unlocked: '<p class="lobe-bad">Your CHARTER.md is written but not locked.</p>' + sub('The lobe imports only a locked Charter. Check it below and tap Save and lock.'),
    locked: frameLocked ? `<p class="lobe-good">Written and locked by the Owner (${agoAt(o.lockedAt, now)}).</p>`
      : `<p class="lobe-good">Locked by you ${agoAt(o.lockedAt, now)}.</p>` + sub('The lobe imports it on its next run; the EXAMPLE badge goes then.'),
    changed: '<p class="lobe-bad">CHARTER.md changed after your lock (a hand edit?).</p>' + sub('The lobe keeps your locked version. Check it below and tap Save and lock to lock this one.'),
    invalid: `<p class="lobe-bad">CHARTER.md cannot be read as a Charter: ${esc(o.why)}.</p>` + sub('Write it again below and tap Save and lock.'),
    refused: `<p class="lobe-bad">The Charter was not read: ${esc(o.why)}.</p>`,
  }[o.state] || '<p class="lobe-bad">The Charter\'s state is unknown.</p>';
  const yours = mine ? `<ul class="lobe-list">${mine.domains.map((d) => `<li><b class="lobe-dom">${esc(d.name)}</b> ${esc(d.objective)}</li>`).join('')}</ul>`
    + (mine.domains.some((d) => d.hardConstraint) ? sub('Hard guardrails') + `<ul class="lobe-list rails">${mine.domains.filter((d) => d.hardConstraint).map((d) => `<li><b class="lobe-dom">${esc(d.name)}</b> ${esc(d.hardConstraint)}</li>`).join('')}</ul>` : '') : '';
  // the frame's lines: shown as the Owner's only once the lobe has imported a locked Charter; the EXAMPLE seed stays folded and labelled
  const s = f ? sec(f, '1_normative_charter') : {}, goals = arr(s.north_star_objectives), rails = arr(s.hard_guardrails);
  const seed = f && !frameLocked && goals.length ? `<details class="lobe-seed"><summary>The lobe's EXAMPLE seed (placeholders, not yours)</summary><ul class="lobe-list">${goals.map(domLine).join('')}</ul>${rails.length ? `<ul class="lobe-list rails">${rails.map(domLine).join('')}</ul>` : ''}</details>` : '';
  const badgeHtml = frameLocked ? badge('locked', 'LOCKED') : o.state === 'none' ? badge('bad', 'NOT WRITTEN') : f ? badge('example', 'EXAMPLE') : o.state === 'locked' ? badge('locked', 'LOCKED') : badge('bad', 'NOT LOCKED');
  return card('charter', 'Charter', badgeHtml, head + yours + seed + charterEditor(mine));
}
function tasteCard(owner, now = Date.now()) {
  const props = arr(owner.proposals), taps = arr(owner.taste);
  const focus = '<form class="lobe-focus" data-taste-focus><label class="lobe-f"><span>Focus on ...</span><input name="key" maxlength="120" autocomplete="off" placeholder="a keyword or source"></label><button type="submit" class="btn">Focus</button></form>';
  const prop = (x) => `<li class="lobe-prop"><p class="lobe-ttl">${PROPOSE_WORD[x.op] || esc(x.op)} "${esc(x.key)}"</p>${x.why ? `<p class="lobe-who">Why: ${esc(x.why)}</p>` : ''}<p class="lobe-who">From ${x.by ? esc(x.by) : 'a proposal'}, ${agoAt(x.ts, now)}</p>`
    + `<p class="lobe-row"><button type="button" class="btn primary" data-prop="${esc(x.id)}" data-choice="apply">Apply</button><button type="button" class="btn" data-prop="${esc(x.id)}" data-choice="drop">Drop</button></p></li>`;
  const propHtml = props.length ? sub(`Proposals waiting for you: ${props.length}. None changes anything until you tap Apply; unanswered, each goes after 7 days.`) + `<ul class="lobe-props">${props.map(prop).join('')}</ul>`
    : empty('No proposals.', 'A crew or the Foreman may suggest a taste change (ZG-12); it waits here for your Apply or Drop.');
  const tapHtml = taps.length ? sub('Your recent taps') + `<ul class="lobe-list">${taps.map((t) => `<li><b class="lobe-dom">${TASTE_WORD[t.op] || esc(t.op)}</b> ${esc(t.key)}${t.n > 1 ? ` (${t.n} taps)` : ''}</li>`).join('')}</ul>` : '';
  return card('taste', 'Your taste', props.length ? badge('count', String(props.length)) : '',
    sub('Only your taps move your taste. The lobe applies them on its next run and keeps the weights (0.1 to 3.0).') + focus + propHtml + tapHtml);
}
// the morning brief's lobe line (counts only, never the frame's words); '' when the server sent no lobe part
export function briefLobeLine(l) {
  if (!l || typeof l !== 'object') return '';
  const n = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null), open = ' <a class="text-btn" href="#/world">World</a>';
  if (l.skipped) return `<li class="bad"><b>Lobe:</b> skipped, ${esc(l.skipped)}.${open}</li>`;
  const bits = [[n(l.decisionsReady), 'decision ready', 'decisions ready'], [n(l.postMortemsDue), 'post-mortem due', 'post-mortems due'], [n(l.calibrationQuestions), 'calibration question', 'calibration questions'], [n(l.signals24h), 'world signal in 24 h', 'world signals in 24 h']]
    .filter(([v]) => v !== null).map(([v, one, many]) => `${v} ${v === 1 ? one : many}`);
  return `<li${n(l.decisionsReady) ? ' class="hot"' : ''}><b>Lobe:</b> ${bits.length ? bits.join(', ') : 'no counts yet'}; frame ${ago(n(l.csfAgeMin))} old.${open}</li>`;
}

// ---- ZG-13: the taps (DOM). Every write is a click or a submit by the Owner; nothing here runs on a timer or on render ----
let dirty = false, wiredEl = null;
// true while the Owner is typing in the World view: app.js holds the redraw so a live patch never wipes a half-written Charter
export function worldEditing() {
  if (dirty) return true;
  const a = typeof document !== 'undefined' ? document.activeElement : null;
  return !!(wiredEl && a && wiredEl.contains(a) && /^(INPUT|TEXTAREA)$/.test(a.tagName));
}
// el = #world-body; post: the body in, {ok, error} out; toast(msg, {bad}); confirm({title, html, yes}) -> boolean; after() redraws
export function wireWorld(el, { post, toast, confirm, after = () => {} }) {
  if (!el || wiredEl === el) return; wiredEl = el;
  const send = async (body, btn, okMsg) => {
    if (btn) { if (btn.disabled) return null; btn.disabled = true; }
    const r = await post(body).catch(() => ({ ok: false, error: 'not sent' }));
    if (btn) btn.disabled = false;
    if (r?.ok) toast(okMsg); else toast(`Not done: ${r?.error || 'unknown error'}`, { bad: true });
    return r;
  };
  el.addEventListener('input', (e) => { if (e.target.closest('[data-charter-form]')) dirty = true; });
  el.addEventListener('toggle', (e) => { if (e.target.matches?.('[data-lobe-edit]')) editorOpen = e.target.open; }, true);
  el.addEventListener('click', async (e) => {
    const t = e.target.closest('[data-taste]');
    if (t) { const key = t.dataset.key; await send({ op: t.dataset.taste, key }, t, `${TASTE_WORD[t.dataset.taste]}: "${key}". The lobe applies it on its next run.`); return; }
    const dc = e.target.closest('[data-decide]');   // ZG-25: the Owner's answer to a decision node, asked once more before it is sent
    if (dc) {
      const id = dc.dataset.decide, c = dc.dataset.choice, w = DECIDE_WORD[c] || c;
      const yes = await confirm({ title: `${w} for ${id}?`, html: `<p>${c === 'ask-more' ? 'The lobe opens the question again and asks for more.' : 'Your answer is final; the 30, 60 and 90-day check-ins start from it.'} The lobe records it on its next run.</p>`, yes: w });
      if (!yes) return;
      const r = await send({ op: 'decision', decision: id, choice: c }, dc, `${w}: sent for ${id}. The lobe records it on its next run.`); if (r?.ok) after(); return;
    }
    const pm = e.target.closest('[data-pm]');
    if (pm) { const w = PM_WORD[pm.dataset.choice] || pm.dataset.choice; const r = await send({ op: 'postmortem', decision: pm.dataset.pm, choice: pm.dataset.choice, day: Number(pm.dataset.day) }, pm, `${w}: sent for ${pm.dataset.pm}. The lobe records it on its next run.`); if (r?.ok) after(); return; }
    const so = e.target.closest('[data-signoff]');   // ZG-40: a Brier Sign-off, Apply or Drop: one `decision` {signoff, choice} line
    if (so) { const w = SIGNOFF_WORD[so.dataset.choice] || so.dataset.choice; const r = await send({ op: 'decision', signoff: so.dataset.signoff, choice: so.dataset.choice }, so, `${w}: sent for ${so.dataset.signoff}. The lobe applies it on its next run.`); if (r?.ok) after(); return; }
    const p = e.target.closest('[data-prop]');
    if (p) { const r = await send({ op: 'decision', proposal: p.dataset.prop, choice: p.dataset.choice }, p, p.dataset.choice === 'apply' ? 'Applied. The lobe makes the change on its next run.' : 'Dropped.'); if (r?.ok) after(); return; }
    if (e.target.closest('[data-charter-add]')) {
      const box = el.querySelector('[data-doms]'); const n = box ? box.querySelectorAll('[data-dom]').length : 0;
      if (box && n < 12) { box.insertAdjacentHTML('beforeend', domFieldset(n)); dirty = true; box.lastElementChild.querySelector('input')?.focus(); }
    }
  });
  el.addEventListener('submit', async (e) => {
    const form = e.target; e.preventDefault();
    if (form.matches('[data-taste-focus]')) {
      const input = form.querySelector('input[name=key]'), key = input.value.trim(); if (!key) return;
      const r = await send({ op: 'taste-focus', key }, form.querySelector('button'), `Focus: "${key}". The lobe applies it on its next run.`); if (r?.ok) { input.value = ''; input.blur(); }
      return;
    }
    if (!form.matches('[data-charter-form]')) return;
    const val = (root, k) => root.querySelector(`[name=${k}]`)?.value.trim() || '';
    const domains = [...form.querySelectorAll('[data-dom]')].map((fs) => ({ name: val(fs, 'name'), objective: val(fs, 'objective'), hardConstraint: val(fs, 'hardConstraint'), dependsOn: val(fs, 'dependsOn') }))
      .filter((d) => d.name || d.objective || d.hardConstraint || d.dependsOn);
    if (!domains.length) { toast('Not done: write at least one domain', { bad: true }); return; }
    const yes = await confirm({ title: 'Save and lock your Charter?', html: `<p>${domains.length} domain${domains.length === 1 ? '' : 's'}: ${domains.map((d) => esc(d.name || '?')).join(', ')}. The lobe imports it on its next run.</p>`, yes: 'Save and lock' });
    if (!yes) return;
    const r = await send({ op: 'charter-save', missionOrder: val(form, 'missionOrder'), domains }, form.querySelector('[type=submit]'), 'Charter saved and locked. The lobe imports it on its next run.');
    if (r?.ok) { dirty = false; editorOpen = false; document.activeElement?.blur?.(); after(); }
  });
}

// ---- pixel art (sprites.js format: one palette character per pixel, '.' transparent; light from the top left, warm outline 'a') ----
const SIGN_A = ['..aaaaaaaaaaa...', '.assssssssssqa..', 'asrrrrrrrrrrqa..', '.aqqqqqqqqqqqa..', '..aaaaaaaaaaa...'];
const flipTo = (rows, map) => rows.map((r) => [...r].reverse().map((ch) => map[ch] || ch).join(''));
const POST = '......acda......';
export const ART = {
  charter: ['.aa.............', 'ahia............', 'agaaaaaaaaaaa...', 'agasssssssssa...', 'agasrrrrrrrrra..', 'agasrrtttrrrrqa.', 'agasrtrrrtrrrqa.', 'agasrrtttrrrqa..',
    'agasrrrrrrrrqa..', 'agaqqqqqqqqqa...', 'agaaaaaaaaaa....', 'aga.............', 'aga.............', 'aga.............', 'agga............', 'aaaa............'],
  loops: ['................', '...aaaaaaaaaa...', '..appppppppppa..', '.apppprrrrpppoa.', '.appprrpprrppoa.', '.appppppprrppoa.', '.apppppprrpppoa.', '.appppprrppppoa.',
    '.appppprrppppoa.', '.apppppppppppoa.', '.appppprrppppoa.', '..aooooooooooa..', '...aaaaoaaaaa...', '......aoa.......', '.....aa.........', '................'],
  signals: ['.......aa.......', '..t...atsa...t..', '.t.....aa.....t.', 't..t..ahga..t..t', 't.t...ahga...t.t', 't.t..ahgaga..t.t', '.t...agahga...t.', '.....ahagha.....',
    '....ahgagaga....', '....agahagha....', '...ahagahagha...', '...agahagahga...', '..ahgagahagaha..', '..agahagahagha..', '.aaaaaaaaaaaaaa.', '.akkkkkkkkkkkka.'],
  decide: ['......aaaa......', ...SIGN_A, POST, ...flipTo(SIGN_A, { s: 'w', r: 'v', q: 'u' }), POST, POST, POST, '....aaaaaaaa....'],
  health: ['................', '..aaa.....aaa...', '.aBBBa...aBBBa..', 'aBWCBBa.aBBBBBa.', 'aBCBBBBaBBBBBBa.', 'aBBBBBBBBBBBBBa.', 'aBBBBBBBBBBBBAa.', '.aBBBBBBBBBBAa..',
    '..aBBBBBBBBAa...', '...aBBBBBBAa....', '....aBBBBAa.....', '.....aBBAa......', '......aAa.......', '.......a........', '................', '................'],
  cursor: ['a....', 'ara..', 'arra.', 'arrra', 'arra.', 'ara..', 'a....'],
  // the dialogue box: a double frame (outline, steel ring, outline), 9-sliced by CSS border-image at 4 px
  dlg: ['..aaaaaaaa..', '.ahhhhhhhha.', 'ahaaaaaaaaha', 'ahaWWWWWWaha', 'ahaWppppoaha', 'ahaWppppoaha', 'ahaWppppoaha', 'ahaWppppoaha', 'ahaooooooaha', 'ahaaaaaaaaha', '.ahhhhhhhha.', '..aaaaaaaa..'],
  // the World tab: a globe in the tab icons' accent slots 4-6 (plain ink, lit ember), like sprites.js TAB_ICONS
  globe: ['...aaaaaa...', '..ap6655pa..', '.app65555pa.', 'ap6555pp55oa', 'ap555ppp54oa', 'app55pppp4oa', 'apppppp655oa', 'appp5pp554oa', '.app5ppp4oa.', '.aooo4ooooa.', '..aaooooaa..', '...aaaaaa...'],
  cloud: ['....ppp.......', '..ppppppp.pp..', '.pppppppppppp.', 'oooooooooooooo', '.nnnnnnnnnnnn.'],
};
const STARS = [[8, 3], [27, 9], [46, 2], [63, 7], [88, 4], [104, 10], [131, 2], [152, 6], [71, 12], [140, 11]];

// scene drawing on a grid of palette characters
const blank = (w, h) => Array.from({ length: h }, () => new Array(w).fill('.'));
const dot = (g, x, y, c) => { if (c !== '.' && y >= 0 && y < g.length && x >= 0 && x < g[0].length) g[y][x] = c; };
const stampAt = (g, rows, x, y) => rows.forEach((r, j) => { for (let i = 0; i < r.length; i++) dot(g, x + i, y + j, r[i]); });
const area = (g, x, y, w, h, c) => { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) dot(g, x + i, y + j, c); };
function skyAndLand(g, sky, P) {
  const W = g[0].length;
  for (let y = 0; y < 30; y++) for (let x = 0; x < W; x++) dot(g, x, y, y < 8 || (y === 8 && x % 2) ? 'X' : y < 17 || (y === 17 && x % 2) ? 'Y' : 'Z');
  if (sky === 'night') for (const [x, y] of STARS) dot(g, x, y, 'I');
  stampAt(g, P.framesOf(sky === 'night' || sky === 'dusk' ? 'moon' : 'sun')[0], 16, 4);
  if (sky !== 'night') { stampAt(g, ART.cloud, 52, 3); stampAt(g, ART.cloud, 98, 8); }
  for (let x = 0; x < W; x++) {
    const far = 17 + Math.round(4 * Math.sin(x * 0.07) + 2 * Math.sin(x * 0.19 + 1)), near = 24 + Math.round(2 * Math.sin(x * 0.05 + 2) + 1.5 * Math.sin(x * 0.13));
    for (let y = far; y < 30; y++) dot(g, x, y, y === far ? 'i' : y > far + 3 && (x + y) % 4 === 0 ? 'g' : 'h');
    for (let y = near; y < 30; y++) dot(g, x, y, y === near ? 'w' : y > near + 2 && (x * 3 + y) % 5 === 0 ? 'u' : 'v');
  }
  for (let y = 30; y < g.length; y++) for (let x = 0; x < W; x++) dot(g, x, y, (x * 7 + y * 13) % 11 === 0 ? 'u' : (x * 5 + y * 3) % 17 === 0 ? 'w' : 'v');
  for (let x = 44; x < 128; x++) { const y = 33 + Math.round(1.5 * Math.sin(x * 0.08)); dot(g, x, y, 'm'); dot(g, x, y + 1, 'l'); dot(g, x, y + 2, (x % 3) ? 'l' : 'k'); }
  for (const [x, y, c] of [[12, 36, 't'], [24, 38, 'B'], [70, 38, 't'], [150, 35, 'B'], [142, 38, 't']]) dot(g, x, y, c);
}
// the radio mast: a steel lattice, a red light, one gold ring per world signal (at most 3)
function mast(g, cx, rings) {
  for (let y = 6; y < 32; y++) {
    const half = 1 + Math.floor((y - 6) / 7);
    dot(g, cx - half - 1, y, 'a'); dot(g, cx + half + 1, y, 'a');
    for (let x = cx - half; x <= cx + half; x++) dot(g, x, y, (x - cx + y) % 4 === 0 || (cx - x + y) % 4 === 0 ? 'h' : (x === cx - half ? 'g' : '.'));
  }
  area(g, cx - 1, 3, 3, 3, 'r'); dot(g, cx, 3, 't'); dot(g, cx - 1, 2, 'a'); dot(g, cx, 2, 'a'); dot(g, cx + 1, 2, 'a');
  for (let i = 0; i < rings; i++) {
    const r = 5 + i * 3;
    for (let k = -3; k <= 3; k++) { const a = (k * Math.PI) / 10, dx = Math.round(r * Math.cos(a)), dy = Math.round(r * Math.sin(a)); dot(g, cx + dx, 4 + dy, 't'); dot(g, cx - dx, 4 + dy, 't'); }
  }
}
// the signpost: board A (ember) points left, board B (leaf) points right
function signpost(g, x) {
  area(g, x + 7, 17, 2, 16, 'd'); for (let y = 17; y < 33; y++) { dot(g, x + 6, y, 'a'); dot(g, x + 9, y, 'a'); dot(g, x + 8, y, 'c'); }
  stampAt(g, SIGN_A, x, 19); stampAt(g, flipTo(SIGN_A, { s: 'w', r: 'v', q: 'u' }), x + 4, 25);
}
// the lookout tower: legs and braces, a ladder, the cabin with its window (lit while the frame is fresh), the roof, the Charter flag
function tower(g, x0, { locked, lit }, P) {
  for (const lx of [x0 + 2, x0 + 20]) for (let y = 15; y < 33; y++) { dot(g, lx, y, 'a'); dot(g, lx + 1, y, 'd'); dot(g, lx + 2, y, 'c'); dot(g, lx + 3, y, 'a'); }
  for (let i = 0; i <= 16; i++) { dot(g, x0 + 5 + i, 17 + Math.round(i * 0.8), 'b'); dot(g, x0 + 19 - i, 17 + Math.round(i * 0.8), 'b'); }
  for (let y = 16; y < 33; y++) { dot(g, x0 + 10, y, 'c'); dot(g, x0 + 13, y, 'c'); if (y % 3 === 0) area(g, x0 + 11, y, 2, 1, 'd'); }
  area(g, x0, 7, 26, 9, 'a'); area(g, x0 + 1, 8, 24, 7, 'd'); area(g, x0 + 1, 8, 24, 1, 'e'); area(g, x0 + 1, 14, 24, 1, 'c');
  area(g, x0 + 5, 9, 15, 4, 'a'); area(g, x0 + 6, 10, 13, 2, lit ? 'I' : 'D'); if (lit) area(g, x0 + 6, 10, 4, 1, 't');
  for (let y = 2; y < 8; y++) { const w = 6 + (y - 2) * 4, x = x0 + 13 - w / 2; area(g, x, y, w, 1, y === 2 ? 'a' : y === 3 ? 's' : y === 7 ? 'q' : 'r'); dot(g, x - 1, y, 'a'); dot(g, x + w, y, 'a'); }
  for (let y = 0; y < 8; y++) dot(g, x0 + 27, y, 'a');
  area(g, x0 + 28, 0, 5, 3, locked ? 'v' : '5'); area(g, x0 + 28, 0, 5, 1, locked ? 'w' : '6'); area(g, x0 + 28, 3, 5, 1, 'a');
  for (let i = 0; i < 8; i++) { dot(g, x0 + 4 - i, 11 - Math.floor(i / 3), 'h'); dot(g, x0 + 4 - i, 12 - Math.floor(i / 3), 'g'); }
  stampAt(g, P.framesOf('lantern')[lit ? 1 : 0], x0 - 9, 23);
}
// the scene's facts from the frame (fresh or not, signals, the Charter) and the sky from the hour
export function sceneOpts(view, now = Date.now()) {
  const r = frameOf(view, now), s3 = r.f ? sec(r.f, '3_exogenous_world_deltas') : {};
  return { sky: skyAt(new Date(now).getHours()), signals: Math.min(3, arr(s3.actionable_signal).length), locked: r.f?.meta.charter === 'LOCKED', lit: r.kind === 'ok' && r.f.meta.state === 'ok' };
}
// the lookout, 160 x 40 art pixels (one handheld screen wide); P = the sprites.js module (its sun, moon and lantern)
export function sceneRows(P, o) {
  const g = blank(160, 40);
  skyAndLand(g, o.sky, P); mast(g, 30, o.signals); signpost(g, 76); tower(g, 118, o, P);
  return g.map((r) => r.join(''));
}

// ---- painting (DOM): every sprite once into a CSS variable on root; the scene again when its facts or the hour change ----
const INK = ['#5c5953', '#8a857c', '#b5afa5'], INK_DARK = ['#8a857c', '#b5afa5', '#d6c3a8'], EMBER = ['#7a1f12', '#c2410c', '#f08a24'];
let paintedKey = '', chromeDone = false;
function urlOf(P, rows, pal) {
  const c = document.createElement('canvas'); c.width = rows[0].length; c.height = rows.length;
  const ctx = c.getContext('2d'), img = ctx.createImageData(c.width, c.height); img.data.set(P.toRGBA(rows, pal)); ctx.putImageData(img, 0, 0);
  return `url("${c.toDataURL()}")`;
}
function paintChrome(root, P) {
  const set = (k, rows, pal = P.PALETTE) => root.style.setProperty(k, urlOf(P, rows, pal));
  for (const k of ['charter', 'loops', 'signals', 'decide', 'health']) set('--lobe-ic-' + k, ART[k]);
  set('--lobe-cur', ART.cursor); set('--lobe-dlg', ART.dlg); set('--lobe-dlg-dark', ART.dlg, { ...P.PALETTE, a: P.PALETTE.V, p: P.PALETTE.O, W: P.PALETTE.Q, o: P.PALETTE.N });
  const tab = {};
  for (const [suf, acc, ui] of [['', INK], ['-on', EMBER], ['-dark', INK_DARK, P.TAB_DARK], ['-on-dark', EMBER, P.TAB_DARK]]) { const pal = { ...P.PALETTE, ...(ui || {}) }; [pal[4], pal[5], pal[6]] = acc; tab[suf] = urlOf(P, ART.globe, pal); }
  const dark = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
  const tabs = () => { const d = dark?.matches ? '-dark' : ''; root.style.setProperty('--px-tab-world', tab[d]); root.style.setProperty('--px-tab-world-on', tab['-on' + d]); };
  tabs(); dark?.addEventListener?.('change', tabs);
}
// root: the element that carries the variables (document.documentElement); view = state.lobe (or null at start-up). Resolves true once painted.
export async function paintWorld(root, view = null, now = Date.now()) {
  if (!root?.style || typeof document === 'undefined') return false;
  let P; try { P = await import('./sprites.js'); if (!document.createElement('canvas').getContext('2d')) return false; } catch { return false; }
  try {
    if (!chromeDone) { paintChrome(root, P); chromeDone = true; }
    const o = sceneOpts(view, now), key = JSON.stringify(o);
    if (key !== paintedKey) { root.style.setProperty('--lobe-scene', urlOf(P, sceneRows(P, o), P.paletteFor({ sky: o.sky }))); paintedKey = key; }
    root.classList.add('lobe-px'); return true;
  } catch { return false; }   // no art: the cards keep their words and plain frames
}
