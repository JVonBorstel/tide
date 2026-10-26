// Tests for the Board's World view (ZG-09: pass-app/public/lobe.js and server.mjs lobeView / GET /api/lobe): synthetic frames only, never the live lobe.
// Run by tests/Test-PassApp.ps1. Pure checks on frames present, missing, stale and refused, then throwaway servers on temp kitchens. Prints [{name, pass}].
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import http from 'node:http';
import { LOBE, ago, frameOf, worldHtml, gauge, ART, sceneRows, sceneOpts, briefLobeLine, lobeSentence, lobeEventKey } from './public/lobe.js';
import crypto from 'node:crypto';
import * as P from './public/sprites.js';
import { here, NOW, at, PRIVATE, pause, checker, frame, ok, cards, oldNames, get, post, servers } from './test-lobe-kit.mjs';   // shared with test-lobe-trust.mjs

const { results, check } = checker();

// ---- 1. the frame's kind ----
{
  const r = frameOf(ok(frame()), NOW);
  check('present: a fresh frame is shown, its ages measured from compiled_utc and last_sweep_utc', r.kind === 'ok' && r.ages.compiled === 10 && r.ages.sweep === 12 && r.age === 12);
  check('missing: no view, or {ok:false, why:"no frame yet"}, is the missing line', frameOf(null, NOW).kind === 'missing' && frameOf({ ok: false, why: 'no frame yet' }, NOW).kind === 'missing');
  const st = frameOf(ok(frame({ meta: { compiled_utc: at(LOBE.staleMin + 5), last_sweep_utc: at(LOBE.staleMin + 6) } })), NOW);
  check('stale: older than 4 h (zeitgeistd health.py: 2 x every 120 min) is stale, with both ages in the line', st.kind === 'stale' && /compiled 4\.1 h ago, last sweep 4\.1 h ago/.test(st.line) && /limit is 4 h/.test(st.line));
  check('stale: the older of compile and sweep counts (a fresh compile of an old sweep is stale)', frameOf(ok(frame({ meta: { compiled_utc: at(1), last_sweep_utc: at(300) } })), NOW).kind === 'stale');
  check('stale: exactly 4 h is still fresh', frameOf(ok(frame({ meta: { compiled_utc: at(240), last_sweep_utc: at(240) } })), NOW).kind === 'ok');
  const bad = (f) => frameOf(ok(f), NOW);
  const noMeta = frame(); delete noMeta['4_epistemic_tensions'];
  const swapped = Object.fromEntries(Object.entries(frame()).reverse());
  check('refused: missing or re-ordered 6.2 sections', bad(noMeta).kind === 'refused' && bad(swapped).kind === 'refused' && bad([]).kind === 'refused' && bad('x').kind === 'refused');
  check('refused: a meta.state or meta.charter the lobe never writes', bad(frame({ meta: { state: 'hacked' } })).kind === 'refused' && bad(frame({ meta: { charter: 'MINE' } })).kind === 'refused');
  check('refused: an unreadable or future time (more than 5 min ahead)', bad(frame({ meta: { compiled_utc: 'soon' } })).kind === 'refused' && bad(frame({ meta: { compiled_utc: at(-6) } })).kind === 'refused' && bad(frame({ meta: { compiled_utc: at(-4) } })).kind === 'ok');
  const rf = frameOf({ ok: false, why: 'frame refused: csf.json is over 2400 characters' }, NOW);
  check('refused: the server\'s reason in fixed words becomes the refused line', rf.kind === 'refused' && rf.line === 'The frame was refused: csf.json is over 2400 characters. The cards come back with the next good frame.');
  check('ago: minutes, hours, days', ago(0) === '0 min' && ago(59) === '59 min' && ago(60) === '1 h' && ago(90) === '1.5 h' && ago(3000) === '2 d' && ago(null) === 'unknown');
}

// ---- 2. the markup ----
{
  const html = worldHtml(ok(frame()), { now: NOW });
  check('present: five cards in order (Charter, Open loops, Signals, Decisions ready, Lobe health)', cards(html).join() === 'charter,loops,signals,decide,health');
  check('Charter: EXAMPLE badge until locked; LOCKED after', /lobe-badge example">EXAMPLE</.test(html) && /lobe-badge locked">LOCKED</.test(worldHtml(ok(frame({ meta: { charter: 'LOCKED' } })), { now: NOW })) && !/>EXAMPLE</.test(worldHtml(ok(frame({ meta: { charter: 'LOCKED' } })), { now: NOW })));
  check('Charter: domains as chips, objectives and hard guardrails listed', /<b class="lobe-dom">WORK<\/b> ship the demo/.test(html) && /Hard guardrails/.test(html) && /no weekend crunch/.test(html));
  check('every frame word is escaped (no tag from the frame reaches the page)', !html.includes('<script>') && html.includes('&lt;script&gt;') && html.includes('sleep &lt;b&gt;7 h&lt;/b&gt;'));
  check('Open loops: the questions, how many of the total, heaviest first', html.includes('Is the demo booked?') && html.includes('2 of 7 open, heaviest first'));
  check('Signals: title, the four scores and source trust as gauges, the incentive note', html.includes('aria-label="Signal: 86"') && html.includes('aria-label="Fact: 72"') && html.includes('aria-label="Surprise: 68"') && html.includes('aria-label="Source trust: 0.71"') && html.includes('Who profits if you believe it: sells inference') && html.includes('BAND 3'));
  check('Signals: hype is a warning when high (inverted tone); an unknown trust says unknown', /<b>90<\/b><span class="lobe-hp" data-tone="bad"/.test(html) && /<span>Hype<\/span><b>12<\/b><span class="lobe-hp" data-tone="good"/.test(html) && /Source trust<\/span><b>unknown<\/b>/.test(html) && html.includes('not known'));
  check('Signals: 24 h count and the hype held back, as counts', html.includes('4 in the last 24 h · 1 loud item held back as hype'));
  check('Decisions: id with the A and B steelmen as a choice menu, marked Needs sign-off, post-mortems due', /D-0007<\/p><ol class="lobe-menu ab"><li><b>A<\/b> rebook the demo<\/li><li><b>B<\/b> send a recording<\/li>/.test(html) && html.includes('Needs sign-off') && html.includes('Post-mortems due: 1'));
  check('Lobe health: last sweep, compiled, size, 24 h counts and a freshness gauge', html.includes('<dt>Last sweep</dt><dd>12 min ago</dd>') && html.includes('2290 chars, about 573 tokens, 2 trimmed to fit') && html.includes('aria-label="Fresh for: 3.8 h"'));
  check('private: Yard signal titles never reach the page, only their count', !PRIVATE.some((t) => html.includes(t.slice(0, 20)) || html.includes('SECRET-CLIENT') || html.includes('PRIVATE-PACKET')) && html.includes('<dt>Yard events</dt><dd>2 (a count only'));
  check('private: the count the server sends (a number) is shown as it is', worldHtml(ok(frame({ s2: { yard_signals: 9 } })), { now: NOW }).includes('<dt>Yard events</dt><dd>9 (a count only'));
  check('the Glossary\'s words: Owner, Foreman, Site, Needs sign-off', ['Owner', 'Foreman', 'Site ZG', 'Needs sign-off'].every((w) => html.includes(w)));
  const names = oldNames();
  const text = (h) => h.replace(/<[^>]*>/g, ' ');
  const shown = [html, worldHtml(ok(frame({ meta: { state: 'empty: no sweep yet', last_sweep_utc: null } })), { now: NOW }), worldHtml(null), worldHtml({ ok: false, why: 'frame refused: x' })].map(text).join(' ');
  check('no old name (scripts/names-allow.json words) in any text the view shows', names.every((rx) => !rx.test(shown.replace(/AGI next month/, ''))), names.filter((rx) => rx.test(shown)).join(' '));
  check('no style attribute in the markup (strict CSP: style-src self)', !/\sstyle=/.test(html));
  check('the lookout scene says in words what it shows', /role="img" aria-label="The lookout over Site ZG: 2 of 3 signal rings on the mast, the Charter flag EXAMPLE, the lamp lit\."/.test(html));
}

// ---- 3. empty states, and missing / stale / refused as one plain line ----
{
  const e = frame({ meta: { state: 'empty: no sweep yet', last_sweep_utc: null, counts: { items_24h: 0, world_signals_24h: 0, open_loops: 0, decisions_ready: 0, post_mortems_due: 0 } },
    s1: { north_star_objectives: [], hard_guardrails: [] }, s2: { active_open_loops: [], yard_signals: [] }, s3: { actionable_signal: [], quarantined_hype_waves: [] }, s5: { unlocked_choices: [], pending_post_mortems: [] } });
  const html = worldHtml(ok(e), { now: NOW });
  check('empty frame: all five cards still drawn (never a blank card)', cards(html).length === 5);
  check('empty: Charter says what fills it and which Pour', html.includes('No Charter lines in this frame.') && html.includes('ZG-02 seeds the EXAMPLE (ZG Pour 1)') && html.includes('ZG-13, ZG Pour 2'));
  check('empty: Open loops says what fills it and which Pour', html.includes('No open loops yet.') && html.includes('ZG-11, ZG Pour 2') && html.includes('ZG-39, ZG Pour 5'));
  check('empty: Signals says what fills it and which Pour', html.includes('No world signals yet.') && html.includes('ZG-19, ZG Pour 3'));
  check('empty: Decisions says what fills it and which Pour', html.includes('No decision is ready.') && html.includes('ZG-24, ZG Pour 3'));
  check('empty: Lobe health is red with the reason (no sweep yet), never a blank card', /<p class="lobe-bad">No sweep yet: the lobe compiled an empty frame \(state "empty: no sweep yet"\)/.test(html) && html.includes('lobe-badge bad">NO SWEEP') && html.includes('<dt>Last sweep</dt><dd>never</dd>'));
  check('trimmed loops: a count with no list says the frame trimmed them', worldHtml(ok(frame({ s2: { active_open_loops: [] } })), { now: NOW }).includes('7 open; this frame trimmed them to fit its 2,400 characters.'));
  const one = (v) => worldHtml(v, { now: NOW });
  const lines = { missing: one({ ok: false, why: 'no frame yet' }), stale: one(ok(frame({ meta: { compiled_utc: at(500), last_sweep_utc: at(500) } }))), refused: one({ ok: false, why: 'frame refused: csf.json is not a file' }) };
  for (const [k, h] of Object.entries(lines)) check(`${k}: one plain line (role status), no card, no error page`, new RegExp(`^<p class="lobe-line ${k}" role="status" data-lobe="${k}">[^<]+</p>$`).test(h) && !/lobe-card|error|Error/.test(h), h.slice(0, 120));
  check('missing: the line says what writes the frame', lines.missing.includes('No frame yet') && lines.missing.includes('ZG-07, ZG Pour 1'));
  check('stale: the stale frame\'s words never show (cards hidden)', !lines.stale.includes('ship the demo') && lines.stale.includes('stale'));
}

// ---- 4. pixel art: sprites.js format, every index in the palette, the scene ----
{
  const sizes = Object.entries(ART).map(([k, rows]) => [k, rows.every((r) => r.length === rows[0].length), [...rows.join('')].every((c) => c === '.' || P.PALETTE[c])]);
  check('art: every lobe sprite is a rectangle of palette characters', sizes.every(([, rect, pal]) => rect && pal), sizes.filter(([, a, b]) => !a || !b).map(([k]) => k).join());
  check('art: the five card icons are 16x16, the dialogue box 12x12, the globe tab 12x12 (like the tab icons)', ['charter', 'loops', 'signals', 'decide', 'health'].every((k) => ART[k].length === 16 && ART[k][0].length === 16) && ART.dlg.length === 12 && ART.globe[0].length === 12);
  const skies = ['dawn', 'day', 'dusk', 'night'].map((sky) => sceneRows(P, { sky, signals: 3, locked: true, lit: true }));
  check('scene: 160 x 40 art pixels in every sky, every index defined (toRGBA decodes it)', skies.every((rows) => rows.length === 40 && rows.every((r) => r.length === 160)) && skies.every((rows, i) => P.toRGBA(rows, P.paletteFor({ sky: ['dawn', 'day', 'dusk', 'night'][i] })).length === 160 * 40 * 4));
  check('scene: the globe decodes in the tab accent palettes, plain and dark', P.toRGBA(ART.globe, { ...P.PALETTE, ...P.TAB_DARK }).length === 12 * 12 * 4);
  const lit = sceneRows(P, { sky: 'day', signals: 0, locked: false, lit: true }).join(''), out = sceneRows(P, { sky: 'day', signals: 0, locked: false, lit: false }).join('');
  check('scene: the lookout\'s window is lit only while the frame is fresh', lit.includes('I') && lit !== out);
  const rings = (n) => sceneRows(P, { sky: 'day', signals: n, locked: false, lit: true }).join('').split('t').length;
  check('scene: one gold ring per world signal on the mast, at most 3', rings(1) > rings(0) && rings(3) > rings(2));
  // noon on this PC's clock (the sky is the viewer's local hour), and a frame compiled 10 min before that same instant: NOW is 18:00 UTC,
  // which is noon only at UTC-6, so a frame from NOW was hours in the future (refused, lamp out) in every other zone
  const noon = new Date(2026, 9, 23, 12, 0, 0).getTime();
  const o = sceneOpts(ok(frame({ s3: { actionable_signal: Array(5).fill({ event: 'x', band: 2 }) }, from: noon })), noon);
  check('scene facts: signals capped at 3, sky from the hour, lamp out for a stale or empty frame', o.signals === 3 && o.sky === 'day' && o.lit && !sceneOpts(ok(frame({ meta: { compiled_utc: at(900), last_sweep_utc: at(900) } })), NOW).lit && !sceneOpts(ok(frame({ meta: { state: 'empty: no sweep yet' } })), NOW).lit);
  check('gauge: ten segments, the value in words', (gauge('X', 47, 100).match(/<i/g) || []).length === 10 && gauge('X', 47, 100).includes('aria-label="X: 47"') && gauge('X', null, 100).includes('unknown'));
}

// ---- 5. the stylesheet: fits a phone, calm under reduced motion ----
{
  const css = fs.readFileSync(path.join(here, 'public', 'app.css'), 'utf8'), lobeCss = css.slice(css.indexOf('/* ZG-09 World view'));
  const widths = [...lobeCss.matchAll(/(?<![-\w])(?:min-)?width:(\d+)px/g)].map((m) => Number(m[1]));
  check('fits 360 px: no fixed width in the World view over 320 px, and the scene shrinks with its column', widths.every((w) => w <= 320) && /\.lobe-scene\{[^}]*max-width:100%/.test(lobeCss) && /\.lobe-box\{[^}]*overflow-wrap:anywhere/.test(lobeCss), widths.join());
  check('calm: the only animation (the menu cursor) stops under reduced motion', (lobeCss.match(/animation:/g) || []).length === 2 && /@media \(prefers-reduced-motion:reduce\)\{\.lobe-menu li:first-child::before\{animation:none\}\}/.test(lobeCss));
  check('the World tab wears its pixel globe, plain and lit, like the other tabs', /html\.px \.bar a\[data-view=world\] svg\{background-image:var\(--px-tab-world\)\}/.test(lobeCss) && /\[aria-current=page\] svg\{background-image:var\(--px-tab-world-on\)\}/.test(lobeCss));
}

// ---- ZG-13: the Owner's cards (pure markup) and the brief's lobe line ----
{
  const none = { charter: { state: 'none' }, proposals: [], taste: [] };
  const mine = { missionOrder: 'WORK first', domains: [{ name: 'WORK', objective: 'ship <i>it</i>', hardConstraint: 'no crunch', dependsOn: [] }] };
  const html = worldHtml(ok(frame()), { now: NOW, owner: none });
  check('ZG13 cards with the Owner: Charter, Open loops, Signals, Your taste, Decisions ready, Lobe health', cards(html).join() === 'charter,loops,signals,taste,decide,self,health');
  check('ZG13 not written: the Charter card says so plainly, badge NOT WRITTEN', html.includes("Your Charter isn't written yet.") && html.includes('lobe-badge bad">NOT WRITTEN'));
  check('ZG13 not written: the EXAMPLE seed is folded away and labelled, never shown as the Owner\'s', /<details class="lobe-seed"><summary>The lobe's EXAMPLE seed \(placeholders, not yours\)<\/summary>/.test(html) && !/<\/p><ul class="lobe-list"><li><b class="lobe-dom">WORK<\/b> ship the demo/.test(html.split('lobe-seed')[0]));
  const inputs = [...html.matchAll(/<input name="(\w+)"[^>]*value="([^"]*)"/g)];
  check('ZG13 not written: the editor starts empty (no seed words in any field) with Save and lock', inputs.length >= 5 && inputs.every(([, , v]) => v === '') && html.includes('Save and lock'));
  const missing = worldHtml({ ok: false, why: 'no frame yet' }, { now: NOW, owner: none });
  check('ZG13 no frame: the plain line, then the Charter editor and Your taste (writing a Charter needs no frame)', /^<div class="lobe" data-lobe="missing"><p class="lobe-line missing"/.test(missing) && cards(missing).join() === 'charter,taste,self' && missing.includes('data-charter-form'));
  const locked = worldHtml(ok(frame()), { now: NOW, owner: { charter: { state: 'locked', lockedAt: at(30), charter: mine }, proposals: [], taste: [] } });
  check('ZG13 locked, frame still EXAMPLE: "Locked by you", the badge goes on the next run, the Owner\'s own lines escaped', locked.includes('Locked by you 30 min ago.') && locked.includes('the EXAMPLE badge goes then') && locked.includes('ship &lt;i&gt;it&lt;/i&gt;') && locked.includes('value="WORK"') && locked.includes('Edit and lock again'));
  const lockedL = worldHtml(ok(frame({ meta: { charter: 'LOCKED' } })), { now: NOW, owner: { charter: { state: 'locked', lockedAt: at(30), charter: mine }, proposals: [], taste: [] } });
  check('ZG13 locked and imported: "Written and locked by the Owner", LOCKED badge, no seed fold', lockedL.includes('Written and locked by the Owner') && lockedL.includes('lobe-badge locked">LOCKED') && !lockedL.includes('lobe-seed'));
  const changed = worldHtml(ok(frame()), { now: NOW, owner: { charter: { state: 'changed', charter: mine }, proposals: [], taste: [] } });
  check('ZG13 hand edit: red, the locked version stays until the Owner locks again', changed.includes('<p class="lobe-bad">CHARTER.md changed after your lock'));
  check('ZG13 per signal: Up / Down / Mute taps keyed by the escaped title', html.includes('data-taste="taste-up" data-key="Model &lt;script&gt;alert(1)&lt;/script&gt; beats benchmark"') && html.includes('data-taste="taste-mute"') && !html.includes('<script>'));
  check('ZG13 without the Owner part, no tap and no editor (ZG-09 read-only view)', !worldHtml(ok(frame()), { now: NOW }).includes('data-taste') && !worldHtml(ok(frame()), { now: NOW }).includes('data-charter-form'));
  check('ZG13 Focus on ... box', html.includes('data-taste-focus') && html.includes('Focus on ...'));
  const props = worldHtml(ok(frame()), { now: NOW, owner: { charter: { state: 'none' }, taste: [{ key: 'rust', op: 'taste-up', n: 2 }], proposals: [{ id: 'P-1', op: 'taste-mute', key: 'crypto', by: 'crew', why: '<b>loud</b>', ts: at(60) }] } });
  check('ZG13 proposals as Apply / Drop cards that change nothing until tapped', props.includes('Mute "crypto"') && props.includes('data-prop="P-1" data-choice="apply">Apply') && props.includes('data-prop="P-1" data-choice="drop">Drop') && props.includes('&lt;b&gt;loud&lt;/b&gt;') && props.includes('None changes anything until you tap Apply'));
  check('ZG13 the Owner\'s recent taste taps', props.includes('<b class="lobe-dom">Up</b> rust (2 taps)'));
  const words = oldNames();
  const shown = [html, missing, locked, props].join(' ').replace(/<[^>]*>/g, ' ').replace(/AGI next month/, '');
  check('ZG13 no old name in the Owner cards', words.every((rx) => !rx.test(shown)), words.filter((rx) => rx.test(shown)).join(' '));
  check('ZG13 no style attribute in the Owner cards (strict CSP)', !/\sstyle=/.test(html + props));
  const bl = briefLobeLine({ decisionsReady: 2, calibrationQuestions: null, postMortemsDue: 1, signals24h: 4, csfAgeMin: 30, skipped: null });
  check('ZG13 brief line: counts and age, an unknown count left out (never a made-up zero)', bl.includes('2 decisions ready, 1 post-mortem due, 4 world signals in 24 h; frame 30 min old.') && !bl.includes('calibration') && bl.startsWith('<li class="hot">'));
  check('ZG13 brief line: a skipped lobe is red with the reason; no lobe part, no line', briefLobeLine({ skipped: 'no frame yet' }) === '<li class="bad"><b>Lobe:</b> skipped, no frame yet. <a class="text-btn" href="#/world">World</a></li>' && briefLobeLine(undefined) === '');
}

// ---- ZG-30: the Glass box card and the lobe's lines in the Activity feed (pure, synthetic state.lobeGlass) ----
{
  const hb = (x = {}) => ({ ok: true, why: null, lastRun: at(20), everyMin: 120, found: 0, failing: false, breakersOpen: 0, dlq: 0, csfAgeMin: 8, skipped: 0, queue: null,
    bands: [{ band: 1, name: 'endogenous', sources: 2, items24h: 5, newestUtc: at(30) }, { band: 3, name: 'builder', sources: 0, items24h: 0, newestUtc: null }], ...x });
  const glass = (x = {}) => ({ events: { ok: true, why: null, oldest: at(3000) }, heartbeat: hb(), config: { ok: true, why: null },
    today: { sweeps: 3, skips: 0, skipWhy: [], tokens: 42000, drops: 7, passes: 20, partial: false }, lastSweepUtc: at(12), trips: [],
    queue: null, queueWhy: 'the heartbeat does not carry it yet', ceiling: 150000, ceilingWhy: null, ram: { freeMb: 6100, needMb: 2500 }, ...x });
  const G = (g, view = ok(frame())) => worldHtml(view, { now: NOW, glass: g });
  const fine = G(glass());
  check('ZG30-2 the Glass box card comes last, after the five cards; without state.lobeGlass the view is unchanged', cards(fine).join() === 'charter,loops,signals,decide,health,glass' && cards(worldHtml(ok(frame()), { now: NOW })).length === 5);
  check('ZG30-2 healthy: OK badge, last sweep age, sweeps run vs skipped, gate counts, tokens of the ceiling', fine.includes('lobe-badge locked">OK') && fine.includes('data-glass="ok"') && fine.includes('<dt>Last sweep</dt><dd>12 min ago</dd>')
    && fine.includes('<dt>Sweeps today</dt><dd>3 run, 0 skipped</dd>') && fine.includes('<dt>Gate today</dt><dd>20 passed, 7 dropped</dd>') && fine.includes('<dt>Tokens today</dt><dd>42,000 of 150,000</dd>'));
  check('ZG30-2 the budgets line: RAM free vs what a sweep needs, tokens today vs the ceiling (build standard: budgets on the Board)', fine.includes('<p class="lobe-sub" data-budgets>Budgets: RAM 6,100 MB free (a sweep needs 2,500 MB) · tokens 42,000 of 150,000 today</p>') && fine.includes('aria-label="Tokens used: 28%"'));
  check('ZG30-2 per band: last fetch age, sources and items; a band with no sources says so', fine.includes('<dt>Band 1 endogenous</dt><dd>30 min ago, 2 sources, 5 items in 24 h</dd>') && fine.includes('<dt>Band 3 builder</dt><dd>no sources yet</dd>'));
  check('ZG30-2 queue depth: unknown with the reason when no file carries it (never a made-up 0); shown when the heartbeat carries it', fine.includes('<dt>Queue</dt><dd>unknown: the heartbeat does not carry it yet</dd>') && G(glass({ queue: 14 })).includes('<dt>Queue</dt><dd>14 waiting</dd>'));
  // ZG30-3: a tripped breaker
  const trip = G(glass({ heartbeat: hb({ breakersOpen: 1, failing: true, found: 1 }), trips: [{ id: 'connector.rss', ts: at(40) }] }));
  check('ZG30-3 a tripped Stop-work order: RED badge, the reason, the open count and which tripped', trip.includes('lobe-badge bad">RED') && trip.includes('Needs a look: 1 Stop-work order open.') && trip.includes('<dt>Stop-work orders</dt><dd>1 open at the last run</dd>') && trip.includes('<dt>Tripped in 24 h</dt><dd>connector.rss 40 min ago</dd>') && trip.includes('with 1 problem'));
  // ZG30-3: a DLQ item
  check('ZG30-3 a DLQ item: the unresolved count', G(glass({ heartbeat: hb({ dlq: 2 }) })).includes('<dt>DLQ</dt><dd>2 unresolved</dd>') && fine.includes('<dt>DLQ</dt><dd>0 unresolved</dd>'));
  // ZG30-3: a skipped sweep
  const sk = G(glass({ today: { sweeps: 1, skips: 2, skipWhy: [['free RAM 2400 MB is under 2500 MB', 1], ['model down', 1]], tokens: 0, drops: 0, passes: 0, partial: false } }));
  check('ZG30-3 a skipped sweep: run vs skipped today with each plain reason and its count', sk.includes('<dt>Sweeps today</dt><dd>1 run, 2 skipped (free RAM 2400 MB is under 2500 MB 1, model down 1)</dd>'));
  check('ZG30-2 a count from a file that starts after midnight says "at least"', G(glass({ today: { sweeps: 1, skips: 0, skipWhy: [], tokens: 5, drops: 0, passes: 0, partial: true } })).includes('1 run, 0 skipped (at least: the events file starts after midnight)'));
  // ZG30-3: a stale frame
  const staleView = ok(frame({ meta: { compiled_utc: at(300), last_sweep_utc: at(310) } }));
  const st = G(glass(), staleView);
  check('ZG30-3 a stale frame (older than 2 x the interval): RED with the age and the limit', st.includes('lobe-badge bad">RED') && st.includes('Needs a look: the frame is 5.2 h old (the limit is 2 x 2 h = 4 h).') && cards(st).join() === 'glass');
  check('ZG30-2 the limit follows the heartbeat\'s everyMin (every 60 min: a 2.5 h old frame is red)', G(glass({ heartbeat: hb({ everyMin: 60 }) }), ok(frame({ meta: { compiled_utc: at(150), last_sweep_utc: at(150) } }))).includes('the limit is 2 x 1 h = 2 h'));
  check('ZG30-2 no frame: the heartbeat\'s csfAgeMin, aged since its run, still turns it red', G(glass({ heartbeat: hb({ csfAgeMin: 230 }) }), null).includes('Needs a look: the frame is 4.2 h old'));
  // missing or unreadable: unknown with the reason, never empty or healthy
  const miss = G(glass({ events: { ok: false, why: 'no events file yet: the lobe writes events.jsonl on its first write to its memory (ZG-29)', oldest: null }, today: null, lastSweepUtc: null }));
  check('rule: a missing events file is UNKNOWN with the reason, never OK and never zero counts', miss.includes('lobe-badge example">UNKNOWN') && miss.includes('Health unknown: the events file: no events file yet') && !miss.includes('data-glass="ok"') && !/0 run|0 passed/.test(miss) && miss.includes('<dt>Sweeps today</dt><dd>unknown: no events file yet'));
  const noHb = G(glass({ heartbeat: { ok: false, why: 'no heartbeat yet: no sweep, rem or csf run has finished' }, queueWhy: 'no heartbeat yet: no sweep, rem or csf run has finished' }));
  check('rule: a missing heartbeat is unknown with its reason in every row it feeds (DLQ, Stop-work orders, bands)', noHb.includes('lobe-badge example">UNKNOWN') && noHb.includes('<dt>DLQ</dt><dd>unknown: no heartbeat yet') && noHb.includes('<dt>Stop-work orders</dt><dd>unknown: no heartbeat yet') && noHb.includes('Bands: unknown: no heartbeat yet'));
  check('rule: red wins, and the unknown parts are still named', G(glass({ heartbeat: hb({ breakersOpen: 2 }), events: { ok: false, why: 'events.jsonl is not a file' }, today: null })).includes('Also unknown: the events file: events.jsonl is not a file.'));
  check('ZG30-2 the card shows on a missing frame (when it matters most) and on a stale one', cards(G(glass(), null)).join() === 'glass' && /^<div class="lobe" data-lobe="missing"><p class="lobe-line missing"/.test(G(glass(), null)));
  // ZG30-1: the lobe's lines in the Activity feed
  const ev = (type, x = {}) => ({ src: 'lobe', ts: at(5), type, id: 9, layer: 'L2_STAGE1', kind: type, target: 'i42', latency_ms: null, detail: {}, ...x });
  const say = (e) => lobeSentence(e)[1].replace(/<[^>]+>/g, '');
  check('ZG30-1 GATE_DROP shows the rule, or the score when there is no rule', say(ev('GATE_DROP', { detail: { rule: 'dedupe.near_title' } })) === 'Lobe gate dropped item i42: rule dedupe.near_title' && say(ev('GATE_DROP', { detail: { signal_score: 31 } })) === 'Lobe gate dropped item i42: signal score 31');
  check('ZG30-1 SKIP shows the reason: RAM, model down, governor, Claude window', say(ev('SKIP', { detail: { run: 'sweep', reason: 'free RAM 2400 MB is under 2500 MB' } })) === 'Lobe skipped a sweep: low RAM (free RAM 2400 MB is under 2500 MB)'
    && say(ev('SKIP', { detail: { reason: 'model down' } })).includes('model down') && say(ev('SKIP', { detail: { reason: 'governor: busy' } })).includes('the governor') && say(ev('SKIP', { detail: { reason: 'Claude window 90%' } })).includes('the Claude window') && say(ev('SKIP', { detail: { reason: true } })).endsWith('no plain reason given'));
  check('ZG30-1 a tripped breaker is a Stop-work order line in the Failures filter', lobeSentence(ev('BREAKER_TRIP', { target: 'connector.rss' }))[0] === 'fail' && say(ev('BREAKER_TRIP', { target: 'connector.rss' })) === 'Stop-work order on the lobe\'s connector.rss');
  check('ZG30-1 sweeps: started, and done with counts and the DLQ', say(ev('SWEEP_START')) === 'Lobe sweep started' && say(ev('SWEEP_DONE', { detail: { scored: 4, dropped: 2, tokens: 1234, dlq: 1 } })) === 'Lobe sweep done: 4 scored, 2 dropped, 1,234 tokens, 1 to the DLQ');
  check('ZG30-1 every word is escaped; an unknown type shows as its id', !lobeSentence(ev('X_Y', { target: null, type: '<b>X</b>' }))[1].includes('<b>X</b>') && say(ev('CONNECTOR_DOWN')) === 'Lobe CONNECTOR_DOWN i42');
  check('ZG29 Unresolved: a repeat lobe line has the same key (type, id, time); SWEEP_START and its row differ by type; Yard lines keep their old key',
    lobeEventKey(ev('GATE_DROP')) === lobeEventKey({ ...ev('GATE_DROP'), detail: { rule: 'x' } }) && lobeEventKey(ev('SWEEP_START')) !== lobeEventKey(ev('SWEEP_DONE')) && lobeEventKey({ ts: 't', type: 'job.done', job: 'J1' }) === 'tjob.doneJ1');
  const names = oldNames();
  const shown = [fine, trip, sk, st, miss, noHb, ...['SWEEP_START', 'SWEEP_DONE', 'INGEST', 'GATE_PASS', 'GATE_DROP', 'BREAKER_TRIP', 'SKIP', 'CSF_RECOMPILED', 'CSF_REFUSED', 'QUARANTINE'].map((t) => lobeSentence(ev(t))[1])].join(' ').replace(/<[^>]*>/g, ' ');
  check('ZG30 the Glossary\'s words: no old name in the card or the feed lines', names.every((rx) => !rx.test(shown)) && !/breaker/i.test(shown), names.filter((rx) => rx.test(shown)).join(' '));
  check('ZG30 no style attribute in the Glass box (strict CSP; CSS tokens only)', !/\sstyle=/.test(fine + trip + miss));
}

// ---- ZG-25: the Owner's decision and post-mortem card, and the causal hops (pure, synthetic state.lobeOwner.decide) ----
{
  const node = (id, x = {}) => ({ id, loop: 'L' + id, question: 'Rebook <b>the</b> demo?', readyAt: at(90), a: 'rebook the demo', b: 'send a recording', answered: null, ...x });
  const pm = (id, day, kind, say, x = {}) => ({ id, day, dueAt: at(1440), expiresAt: '2026-11-05T18:00:00Z', choice: 'approve', proof: { kind, say }, answered: null, ...x });
  const dec = (x = {}) => ({ ok: true, updated: at(30), ready: [node('D-0007'), node('D-0042', { a: null, b: null, question: 'Move?' })],
    due: [pm('S-J140-A9', 30, 'on-main', 'still on main: commit abc1234 on main'), pm('S-J141-A10', 60, 'replaced', 'replaced by J150'), pm('S-J142-A11', 90, 'undone', 'undone: commit def5678 on main reverts it'), pm('D-0003', 30, 'none', 'a lobe decision, not a work order: the Ledger has no proof for it', { choice: 'B' })], ...x });
  const own = (d) => ({ charter: { state: 'none' }, proposals: [], taste: [], decide: d });
  const html = worldHtml(ok(frame()), { now: NOW, owner: own(dec()) });
  const nodeOf = (h, id) => (h.split(`data-node="${id}"`)[1] || '').split(/<li class="lobe-dec"|<\/ul>/)[0];   // one node, up to the next node or the list's end
  const pmOf = (h, id) => (h.split(`data-pm-node="${id}"`)[1] || '').split(/<li class="lobe-dec"|<\/ul>/)[0];
  check('ZG25-1 the Owner\'s Decisions card takes the read-only one\'s place (same order of cards)', cards(html).join() === 'charter,loops,signals,taste,decide,self,health' && (html.match(/data-card="decide"/g) || []).length === 1);
  const n7 = nodeOf(html, 'D-0007');
  check('ZG25-1 decision card: the A and B steelmen, then A / B / Neither / Ask more taps for that node', /<li><b>A<\/b> rebook the demo<\/li><li><b>B<\/b> send a recording<\/li>/.test(n7)
    && ['A', 'B', 'neither', 'ask-more'].every((c) => n7.includes(`data-decide="D-0007" data-choice="${c}"`)) && />Neither</.test(n7) && />Ask more</.test(n7));
  check('ZG25-1 Law 1: the four taps look the same (no primary, nothing marked better) and the card says nothing picks for you', (n7.match(/class="btn"/g) || []).length === 4 && !/primary|recommend|best/i.test(n7) && html.includes('Nothing here picks for you'));
  check('ZG25-1 a node whose A / B are not in the frame (top 3) has no tap, and says why', !nodeOf(html, 'D-0042').includes('data-decide') && nodeOf(html, 'D-0042').includes('it carries the top 3 nodes'));
  check('ZG25-1 the question is escaped', n7.includes('Rebook &lt;b&gt;the&lt;/b&gt; demo?') && !html.includes('<b>the</b>'));
  const p9 = pmOf(html, 'S-J140-A9');
  check('ZG25-1 post-mortem card: Held up / Didn\'t / Unknown for the day due, with what was chosen and the answer-by date', ['held', 'didnt', 'unknown'].every((c) => p9.includes(`data-pm="S-J140-A9" data-day="30" data-choice="${c}"`)) && />Held up</.test(p9) && />Didn't</.test(p9)
    && p9.includes('Day 30 check: you chose approve. Did it hold up?') && p9.includes('Answer by 2026-11-05; unanswered, the lobe records it as unknown.'));
  check('ZG25-1 the Ledger\'s proof on each: still on main (good), replaced by Jnn and undone (bad), none for a lobe decision', p9.includes('<p class="lobe-good" data-proof="on-main">Ledger: still on main: commit abc1234 on main</p>')
    && pmOf(html, 'S-J141-A10').includes('<p class="lobe-bad" data-proof="replaced">Ledger: replaced by J150</p>') && pmOf(html, 'S-J142-A11').includes('data-proof="undone"') && pmOf(html, 'D-0003').includes('data-proof="none"') && pmOf(html, 'D-0003').includes('you chose B'));
  check('ZG25-1 the badge counts what still waits for a tap (2 ready + 4 due)', /data-card="decide"[^]*?lobe-badge count">6</.test(html));
  const done = worldHtml(ok(frame()), { now: NOW, owner: own(dec({ ready: [node('D-0007', { answered: { choice: 'ask-more', at: at(10) } })], due: [pm('S-J140-A9', 30, 'on-main', 'x', { answered: { choice: 'didnt', at: at(5) } })] })) });
  check('ZG25-1 an answered node shows the answer and no tap, until the lobe\'s next run', nodeOf(done, 'D-0007').includes('You chose Ask more 10 min ago. The lobe records it on its next run.') && !done.includes('data-decide=') && pmOf(done, 'S-J140-A9').includes('You said Didn&#39;t 5 min ago') && !done.includes('data-pm=') && !/lobe-badge count/.test(done.split('data-card="decide"')[1].split('</section>')[0]));
  const unk = worldHtml(ok(frame()), { now: NOW, owner: own({ ok: false, why: 'no flags.json yet: the lobe writes it on its decisions run (ZG-24)', ready: [], due: [] }) });
  check('ZG25 no flags.json: UNKNOWN with the reason, no tap (never an empty "nothing waiting")', unk.includes('lobe-badge example">UNKNOWN') && unk.includes('Decisions unknown: no flags.json yet') && !unk.includes('data-decide') && !unk.includes('No decision is waiting'));
  const empty0 = worldHtml(ok(frame()), { now: NOW, owner: own({ ok: true, updated: at(5), ready: [], due: [] }) });
  check('ZG25 read and empty: "No decision is waiting", no badge', empty0.includes('No decision is waiting.') && !/lobe-badge count/.test(empty0.split('data-card="decide"')[1].split('</section>')[0]));
  const noFrame = worldHtml({ ok: false, why: 'no frame yet' }, { now: NOW, owner: own(dec()) });
  check('ZG25 no frame: the decision card still shows (flags.json needs no frame)', cards(noFrame).join() === 'charter,taste,decide,self' && noFrame.includes('data-pm="S-J140-A9"'));
  check('ZG25 without the Owner part (ZG-09 read-only view) there is no decision tap', !worldHtml(ok(frame()), { now: NOW }).includes('data-decide') && worldHtml(ok(frame()), { now: NOW }).includes('Read-only here.'));
  // ZG25-1: the three hops of a causal tree open on a tap (ZG-26's csf field causal_3rd_order_opening on a signal)
  const sig = (c) => worldHtml(ok(frame({ s3: { actionable_signal: [{ event: 'Chip export rule', band: 4, scores: { signal: 90 }, causal_3rd_order_opening: c }] } })), { now: NOW });
  const four = sig(['GPU prices rise', 'local models <i>win</i>', 'Tide runs cheaper', 'a fourth']);
  check('ZG25-1 causal tree: three hops, folded (a tap opens them), escaped; a fourth is never shown', /<details class="lobe-seed" data-causal><summary>What could follow: 3 hops<\/summary>/.test(four) && four.includes('<b class="lobe-dom">Hop 3</b> Tide runs cheaper') && four.includes('local models &lt;i&gt;win&lt;/i&gt;') && !four.includes('a fourth') && !/data-causal open/.test(four));
  check('ZG25-1 causal tree: one string with "->" between hops; none or junk shows nothing', sig('a -> b').includes('What could follow: 2 hops') && !sig(undefined).includes('data-causal') && !sig(42).includes('data-causal') && !sig([null, {}]).includes('data-causal'));
  const names = oldNames();
  const shown = [html, done, unk, empty0, noFrame, four].join(' ').replace(/<[^>]*>/g, ' ').replace(/AGI next month/, '');
  check('ZG25 the Glossary\'s words: no old name; Owner words (you, Needs sign-off)', names.every((rx) => !rx.test(shown)) && html.includes('Needs sign-off: 2'), names.filter((rx) => rx.test(shown)).join(' '));
  check('ZG25 no style attribute (strict CSP; CSS tokens only)', !/\sstyle=/.test(html + done + four));
}

// ---- 6. the server: GET /api/lobe and the live stream, on throwaway kitchens ----
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'board-lobe-'));
const { boot, stop, crashed } = servers(tmp);
const put = (dir, text) => { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'csf.tmp.json'), text); fs.renameSync(path.join(dir, 'csf.tmp.json'), path.join(dir, 'csf.json')); };
const dump = (f) => JSON.stringify(f);   // compact, like csf.py dump()
try {
  const [A, B, C] = await Promise.all([boot('a', ''), boot('b', path.join(tmp, 'elsewhere')), boot('c', path.join(tmp, 'evie', 'lobe'))]);
  check('servers: three throwaway servers started', !!(A.key && B.key && C.key));
  const lobeA = path.join(A.root, 'lobe');
  // no frame
  const none = await get(A, '/api/lobe');
  check('ZG09-1 no file: GET /api/lobe is {ok:false, why:"no frame yet"}', none.code === 200 && none.json?.ok === false && none.json?.why === 'no frame yet');
  check('ZG09-1 same auth as every route: no key, 401', (await get(A, '/api/lobe', false)).code === 401);
  check('no frame: the board state carries it and the view is the one missing line', (await get(A, '/api/state')).json?.lobe?.why === 'no frame yet' && /^<p class="lobe-line missing"/.test(worldHtml((await get(A, '/api/state')).json.lobe)));
  // the live stream: a csf.json change reaches an open phone as a patch carrying lobe, within 2 s
  let wrote = 0, seenAt = 0, patch = null; const events = [];
  const rq = http.get({ host: '127.0.0.1', port: A.port, path: '/api/stream', agent: false, headers: { Authorization: 'Bearer ' + A.key } }, (res) => {
    let buf = ''; res.setEncoding('utf8');
    res.on('data', (d) => { buf += d; for (let i = buf.indexOf('\n\n'); i >= 0; i = buf.indexOf('\n\n')) { const m = buf.slice(0, i); buf = buf.slice(i + 2); events.push(m); if (wrote && !seenAt && /^event: patch/m.test(m) && /"lobe":\{"ok":true/.test(m)) { seenAt = Date.now(); patch = m; } } });
  });
  rq.on('error', () => {});
  for (let i = 0; i < 40 && !events.some((m) => /^event: state/m.test(m)); i++) await pause(100);
  const live = Date.now();
  put(lobeA, dump(frame({ from: live }))); wrote = Date.now();
  for (let i = 0; i < 40 && !seenAt; i++) await pause(100);
  check('ZG09-3 a csf.json change reaches an open phone as a lobe patch on /api/stream within 2 s', seenAt > 0 && seenAt - wrote <= 2000, seenAt ? `${seenAt - wrote} ms` : 'no patch');
  check('private: the patch carries the Yard signals as a count, never their titles', !!patch && /"yard_signals":2/.test(patch) && !PRIVATE.some((t) => patch.includes(t)) && !patch.includes('SECRET-CLIENT'));
  rq.destroy();
  const got = await get(A, '/api/lobe');
  check('ZG09-1 EXAMPLE frame: {ok, csf, health} read from <kitchen>\\lobe\\csf.json', got.json?.ok === true && got.json.csf.meta.charter === 'EXAMPLE' && got.json.health?.file === 'csf.json' && got.json.health.bytes > 0);
  check('private: GET /api/lobe and /api/state carry no Yard signal title', !got.body.includes('SECRET-CLIENT') && !(await get(A, '/api/state')).body.includes('PRIVATE-PACKET') && got.json.csf['2_endogenous_self_state'].yard_signals === 2);
  check('EXAMPLE frame: the markup from the served frame has the five cards and the EXAMPLE badge', cards(worldHtml(got.json)).length === 5 && worldHtml(got.json).includes('>EXAMPLE<'));
  check('the frame on disk is never changed by the Board (read-only)', fs.readFileSync(path.join(lobeA, 'csf.json'), 'utf8') === dump(frame({ from: live })));
  // stale frame
  put(lobeA, dump(frame({ meta: { compiled_utc: at(400, Date.now()), last_sweep_utc: at(410, Date.now()) } })));
  const stale = await get(A, '/api/lobe');
  check('stale frame: served whole, and the view is one red line with the reason', stale.json?.ok === true && /^<p class="lobe-line stale"/.test(worldHtml(stale.json)) && worldHtml(stale.json).includes('stale: compiled 6.7 h ago'));
  // refused: too big, not JSON, wrong sections, a folder
  put(lobeA, ' '.repeat(2401));
  check('refused: a file over 2,400 characters is not read', (await get(A, '/api/lobe')).json?.why === 'frame refused: csf.json is over 2400 characters');
  put(lobeA, '{"meta": SECRET-NOT-JSON');
  const nj = await get(A, '/api/lobe');
  check('refused: not JSON, in fixed words; the file text never leaves', /^frame refused: it is not a csf\.json frame/.test(nj.json?.why || '') && !nj.body.includes('SECRET-NOT-JSON'));
  put(lobeA, JSON.stringify({ meta: {}, hello: 'SECRET-SHAPE' }));
  check('refused: JSON without the 6.2 sections', /^frame refused/.test((await get(A, '/api/lobe')).json?.why || ''));
  fs.rmSync(path.join(lobeA, 'csf.json')); fs.mkdirSync(path.join(lobeA, 'csf.json'));
  check('refused: csf.json that is a folder', (await get(A, '/api/lobe')).json?.why === 'frame refused: csf.json is not a file');
  // ZEITGEISTD_HOME wins over <kitchen>\lobe; a protected home is never read
  put(path.join(tmp, 'elsewhere'), dump(frame({ meta: { charter: 'LOCKED' } })));
  put(path.join(B.root, 'lobe'), dump(frame()));
  check('ZEITGEISTD_HOME wins over <kitchen>\\lobe', (await get(B, '/api/lobe')).json?.csf?.meta?.charter === 'LOCKED');
  put(path.join(tmp, 'evie', 'lobe'), dump(frame({ s1: { north_star_objectives: ['WORK: PROTECTED-MARKER'] } })));
  const prot = await get(C, '/api/lobe');
  check('a lobe home inside a protected path is refused and not read', /^frame refused: the lobe home is inside a protected path/.test(prot.json?.why || '') && !prot.body.includes('PROTECTED-MARKER'));
  // ---- ZG-13: the Owner's taps through POST /api/lobe, on a throwaway kitchen with its own Office folder ----
  const D = await boot('d', path.join(tmp, 'd-lobe'));
  const office = path.join(D.root + '-office'), charterP = path.join(office, 'CHARTER.md'), acts = path.join(D.root, 'pass-actions.jsonl');
  const lines = () => { try { return fs.readFileSync(acts, 'utf8').split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
  const owner = async () => (await get(D, '/api/state')).json?.lobeOwner;
  check('ZG13 the board state carries the Owner part; no CHARTER.md = "none"', (await owner())?.charter?.state === 'none' && Array.isArray((await owner()).proposals));
  check('ZG13 same auth as approvals: no key 401, a foreign Origin 403, GET-only callers cannot write', (await post(D, { op: 'taste-up', key: 'x' }, { auth: false })).code === 401 && (await post(D, { op: 'taste-up', key: 'x' }, { origin: 'https://evil.example' })).code === 403 && lines().length === 0);
  const seed = await post(D, { op: 'charter-save', domains: [{ name: 'JOB_TRACK', objective: 'EXAMPLE - one job track' }] });
  check('ZG13 the EXAMPLE seed\'s words are refused; nothing written, the refusal logged ok:false', seed.json?.ok === false && /EXAMPLE/.test(seed.json.error) && !fs.existsSync(charterP) && lines().every((l) => l.ok === false && l.op === 'lobe-charter-save'));
  check('ZG13 a Charter with no objective or a bad name is refused', (await post(D, { op: 'charter-save', domains: [{ name: 'WORK', objective: '' }] })).json?.ok === false && (await post(D, { op: 'charter-save', domains: [{ name: '<x>', objective: 'y' }] })).json?.ok === false && !fs.existsSync(charterP));
  const save = await post(D, { op: 'charter-save', missionOrder: 'WORK, then HOME', domains: [{ name: 'WORK', objective: 'ship the demo\nby Friday', hardConstraint: 'no weekend crunch', dependsOn: 'HOME' }, { name: 'HOME', objective: 'sleep 7 h' }] });
  const bytes = fs.existsSync(charterP) ? fs.readFileSync(charterP) : Buffer.alloc(0), last = lines().pop() || {};
  check('ZG13 Save and lock writes CHARTER.md in charter.py\'s format', save.json?.ok === true && /^mission_order: WORK, then HOME$/m.test(bytes.toString()) && /## WORK\r?\nobjective: ship the demo by Friday\r?\nhard_constraint: no weekend crunch\r?\ndepends_on: HOME/.test(bytes.toString()) && /## HOME\r?\nobjective: sleep 7 h\r?\ndepends_on: \r?\n/.test(bytes.toString()));
  check('ZG13 ... and one charter-locked line in tap_line\'s shape with the sha256 of the bytes written', Object.keys(last).join() === 'ts,op,ok,who,sha256,by' && last.op === 'charter-locked' && last.ok === true && last.who === 'key' && last.by === 'Owner' && last.sha256 === crypto.createHash('sha256').update(bytes).digest('hex') && Number.isFinite(Date.parse(last.ts)));
  await pause(50);
  const o1 = await owner();
  check('ZG13 the card reads it back: locked, the Owner\'s domains', o1?.charter?.state === 'locked' && o1.charter.charter.domains.map((d) => d.name).join() === 'WORK,HOME' && o1.charter.charter.domains[0].dependsOn[0] === 'HOME');
  fs.appendFileSync(charterP, '\n<!-- a hand edit -->\n'); await pause(50);
  check('ZG13 a hand edit after the lock shows as changed (the lobe keeps the locked rows)', (await owner())?.charter?.state === 'changed');
  const n0 = lines().length;
  const up = await post(D, { op: 'taste-up', key: '  Rust   Lang ' }), dup = await post(D, { op: 'taste-up', key: 'rust lang' });
  const t = lines().slice(n0);
  check('ZG13 a taste tap is one line {ts, op, ok, who, key}, the key as the lobe stores it; a double tap writes once', up.json?.ok && dup.json?.duplicate === true && t.length === 1 && Object.keys(t[0]).join() === 'ts,op,ok,who,key' && t[0].key === 'rust lang' && t[0].op === 'taste-up');
  check('ZG13 down, mute and focus taps; a bad key or weight is refused', (await post(D, { op: 'taste-down', key: 'hype' })).json?.ok && (await post(D, { op: 'taste-mute', key: 'crypto' })).json?.ok && (await post(D, { op: 'taste-focus', key: 'local models', weight: 2.5 })).json?.ok
    && (await post(D, { op: 'taste-up', key: '' })).json?.ok === false && (await post(D, { op: 'taste-up', key: 'x'.repeat(121) })).json?.ok === false && (await post(D, { op: 'taste-focus', key: 'a', weight: 9 })).json?.ok === false && (await post(D, { op: 'taste-set', key: 'a' })).json?.ok === false);
  check('ZG13 the card lists the Owner\'s taps by key, newest first', (await owner())?.taste?.map((x) => x.key).join() === 'local models,crypto,hype,rust lang');
  const old = new Date(Date.now() - 8 * 86400000).toISOString();
  fs.mkdirSync(path.join(tmp, 'd-lobe'), { recursive: true });
  fs.writeFileSync(path.join(tmp, 'd-lobe', 'proposals.jsonl'), [{ id: 'P-1', op: 'taste-mute', key: 'Crypto', by: 'crew', why: 'loud', ts: new Date().toISOString() }, { id: 'P-OLD', op: 'taste-up', key: 'x', ts: old }, { id: 'P-BAD', op: 'charter-locked', key: 'x' }, 'not json'].map((x) => typeof x === 'string' ? x : JSON.stringify(x)).join('\n') + '\n');
  await pause(50);
  check('ZG13 proposals: pending ones shown; over 7 days, or not a taste op, left out', (await owner())?.proposals?.map((x) => x.id).join() === 'P-1');
  check('ZG13 a decision on a proposal that is not waiting, or with no choice, is refused', (await post(D, { op: 'decision', proposal: 'P-OLD', choice: 'apply' })).json?.ok === false && (await post(D, { op: 'decision', proposal: 'P-1', choice: 'maybe' })).json?.ok === false);
  const dec = await post(D, { op: 'decision', proposal: 'P-1', choice: 'apply' }), dl = lines().pop();
  check('ZG13 Apply is one decision line {proposal, choice}; the proposal then leaves the card', dec.json?.ok && dl.op === 'decision' && dl.proposal === 'P-1' && dl.choice === 'apply' && dl.ok === true && (await owner())?.proposals?.length === 0);
  check('ZG13 an unknown op writes no tap', (await post(D, { op: 'approve', id: 'x' })).json?.ok === false && lines().pop().ok === false);
  check('ZG13 every successful line is an Owner tap (ok true, who not an agent word, ts parses)', lines().filter((l) => l.ok).every((l) => l.ok === true && !/^(agent|auto|bot|crew|cron|foreman|lobe|model|system|zeitgeistd)\b/i.test(l.who) && Number.isFinite(Date.parse(l.ts))));
  const bNone = (await get(D, '/api/brief')).json?.data?.lobe;
  check('ZG13 brief(): no frame = every count null and skipped says why', !!bNone && Object.keys(bNone).join() === 'decisionsReady,calibrationQuestions,postMortemsDue,signals24h,csfAgeMin,skipped' && bNone.skipped === 'no frame yet' && bNone.decisionsReady === null);
  put(path.join(tmp, 'd-lobe'), dump(frame({ from: Date.now() })));
  const bOk = (await get(D, '/api/brief')).json?.data?.lobe;
  check('ZG13 brief(): a fresh frame gives the counts, its age and skipped null', bOk?.decisionsReady === 1 && bOk.postMortemsDue === 1 && bOk.signals24h === 4 && bOk.calibrationQuestions === null && bOk.csfAgeMin === 12 && bOk.skipped === null);
  await pause(40);   // the same size within one clock tick (about 16 ms on Windows) would read as the same file (sigOf: size and mtime)
  put(path.join(tmp, 'd-lobe'), dump(frame({ from: Date.now() - 300 * 60000 })));
  check('ZG13 brief(): a stale frame is skipped with the reason', /^the frame is stale \(31\d min old, the limit is 240\)$/.test((await get(D, '/api/brief')).json?.data?.lobe?.skipped || ''));
  check('ZG13 the brief carries counts only: no frame words', !(await get(D, '/api/brief')).body.includes('ship the demo'));
  // ---- ZG-25: decision and post-mortem taps through POST /api/lobe (lobe home d-lobe; flags.json in zeitgeistd decisions.py flags()'s shape) ----
  const homeD = path.join(tmp, 'd-lobe'), flagsP = path.join(homeD, 'flags.json'), ledgerP = path.join(D.root, 'ledger.json');
  const decOf = async () => (await owner())?.decide;
  const nd = lines().length, d0 = await decOf(), r0 = await post(D, { op: 'decision', decision: 'D-0007', choice: 'A' });
  check('ZG25 no flags.json: decide is unknown with the reason, and a decision tap is refused (nothing written as a tap)', d0?.ok === false && /^no flags\.json yet/.test(d0.why) && r0.json?.ok === false && lines().slice(nd).every((l) => l.ok === false));
  await pause(40);
  put(homeD, dump(frame({ from: Date.now() })));
  const isoAgo = (ms) => new Date(Date.now() - ms).toISOString();
  const flagsDoc = (updated, ready = ['D-0007', 'D-0042']) => JSON.stringify({ updated, decisionReady: [...ready.map((id) => ({ id, loop: 'L' + id.slice(2), question: `Question for ${id}`, ready_at: isoAgo(3600000) })), { id: 'bad id <x>', loop: 'x' }],
    postMortemDue: [{ id: 'S-J140-A9', day: 30, due_at: isoAgo(86400000), expires_at: new Date(Date.now() + 12 * 86400000).toISOString(), choice: 'approve' }, { id: 'D-0003', day: 45, due_at: isoAgo(1), expires_at: isoAgo(1), choice: 'A' }] });
  fs.writeFileSync(flagsP, flagsDoc(isoAgo(60000)));
  fs.writeFileSync(ledgerP, JSON.stringify({ ok: true, updated: new Date().toISOString(), top: 'Ledger', counts: {}, items: [], flags: [{ id: 'S-J140-A9', rule: 'post-mortem-due', owner: 'Jordan', pri: 2, day: 30, proofKind: 'on-main', proof: 'still on main: commit abc1234 on main', say: 'x' }] }));
  await pause(50);
  const dv = await decOf();
  check('ZG25 decide from flags.json: ready nodes with the frame\'s A / B (top 3 only), post-mortems with the Ledger\'s proof; a bad id or day is dropped', dv?.ok === true && dv.ready.map((x) => x.id).join() === 'D-0007,D-0042' && dv.ready[0].a === 'rebook the demo' && dv.ready[0].b === 'send a recording' && dv.ready[1].a === null
    && dv.due.map((x) => x.id).join() === 'S-J140-A9' && dv.due[0].proof.kind === 'on-main' && /abc1234/.test(dv.due[0].proof.say) && dv.ready[0].question === 'Question for D-0007', JSON.stringify(dv));
  const nb = lines().length;
  const bad = [await post(D, { op: 'decision', decision: 'D-0007', choice: 'C' }), await post(D, { op: 'decision', decision: 'D-9999', choice: 'A' }), await post(D, { op: 'decision', decision: '', choice: 'A' }),
    await post(D, { op: 'postmortem', decision: 'S-J140-A9', choice: 'maybe', day: 30 }), await post(D, { op: 'postmortem', decision: 'S-J140-A9', choice: 'held', day: 60 }), await post(D, { op: 'postmortem', decision: 'D-0003', choice: 'held', day: 45 })];
  check('ZG25 refused: a choice that is not A / B / Neither / Ask more, an id not waiting, a post-mortem with a bad choice, the wrong day or none due', bad.every((r) => r.json?.ok === false) && lines().slice(nb).every((l) => l.ok === false), bad.map((r) => r.json?.error).join(' | '));
  check('ZG25 same auth as approvals: no key 401, a foreign Origin 403, nothing written', (await post(D, { op: 'decision', decision: 'D-0007', choice: 'A' }, { auth: false })).code === 401 && (await post(D, { op: 'postmortem', decision: 'S-J140-A9', choice: 'held', day: 30 }, { origin: 'https://evil.example' })).code === 403 && lines().filter((l) => l.ok && (l.op === 'postmortem' || l.decision)).length === 0);
  const ta = await post(D, { op: 'decision', decision: 'D-0007', choice: 'A' }), la = lines().pop();
  check('ZG25 A is one `decision` line {decision, choice} in tap_line\'s shape (decisions.py reads it)', ta.json?.ok === true && Object.keys(la).join() === 'ts,op,ok,who,decision,choice' && la.op === 'decision' && la.decision === 'D-0007' && la.choice === 'A' && la.ok === true && la.who === 'key' && Number.isFinite(Date.parse(la.ts)));
  await pause(50);
  const dv2 = await decOf(), again = await post(D, { op: 'decision', decision: 'D-0007', choice: 'B' });
  check('ZG25 the node shows the answer; a second answer before the lobe\'s run is refused', dv2?.ready[0].answered?.choice === 'A' && again.json?.ok === false && /already answered/.test(again.json.error) && lines().filter((l) => l.ok && l.op === 'decision' && l.decision).length === 1);
  const tn = await post(D, { op: 'decision', decision: 'D-0042', choice: 'ask-more' });
  check('ZG25 Ask more is a decision line too (the lobe opens the loop again)', tn.json?.ok === true && lines().pop().choice === 'ask-more');
  const tp = await post(D, { op: 'postmortem', decision: 'S-J140-A9', choice: 'held', day: 30 }), lp = lines().pop();
  check('ZG25 Held up is one `postmortem` line {decision, choice, day}', tp.json?.ok === true && Object.keys(lp).join() === 'ts,op,ok,who,decision,choice,day' && lp.op === 'postmortem' && lp.choice === 'held' && lp.day === 30);
  await pause(50);
  check('ZG25 the post-mortem shows the answer; a second one is refused', (await decOf())?.due[0].answered?.choice === 'held' && (await post(D, { op: 'postmortem', decision: 'S-J140-A9', choice: 'didnt', day: 30 })).json?.ok === false);
  await pause(40);
  fs.writeFileSync(flagsP, flagsDoc(new Date().toISOString(), ['D-0007']));   // the lobe ran after the tap and D-0007 is still waiting: it refused the tap
  await pause(50);
  const dv3 = await decOf();
  check('ZG25 after the lobe\'s run a node still waiting can be tapped again (the lobe refused the old tap); an applied one leaves the card', dv3?.ready.map((x) => x.id).join() === 'D-0007' && dv3.ready[0].answered === null && (await post(D, { op: 'decision', decision: 'D-0007', choice: 'neither' })).json?.ok === true);
  fs.writeFileSync(flagsP, '{"decisionReady": SECRET-FLAGS'); await pause(50);
  const dv4 = await decOf(), sBody = (await get(D, '/api/state')).body;
  check('ZG25 a broken flags.json is unknown in fixed words; its text never leaves', dv4?.ok === false && /not the lobe's/.test(dv4.why) && !sBody.includes('SECRET-FLAGS'));
  check('ZG25 every tap line is the Owner\'s (who is the signed-in user, never an agent word), and no tap was written without a POST', lines().filter((l) => l.ok && (l.op === 'postmortem' || l.decision)).length === 4 && lines().filter((l) => l.ok).every((l) => !/^(agent|auto|bot|crew|cron|foreman|lobe|model|system|zeitgeistd)\b/i.test(l.who)));
  const pushed = (() => { try { return fs.readFileSync(D.root + '-notify.txt', 'utf8'); } catch { return ''; } })();
  check('ZG25 push alerts never carry content: no question, steelman or id in any push', !/Question for|rebook the demo|D-0007|S-J140/.test(pushed));
  // ---- ZG-30: the lobe's events file and heartbeat on a throwaway kitchen (the lines in telemetry.py's exact shape) ----
  const homeE = path.join(tmp, 'e-lobe'), evp = path.join(homeE, 'events.jsonl'); fs.mkdirSync(homeE, { recursive: true });
  const E = await boot('e', homeE);
  const g0 = (await get(E, '/api/state')).json?.lobeGlass;
  check('ZG30 no events file: lobeGlass.events is ok:false with the reason, no counts (unknown, never empty)', g0?.events?.ok === false && /^no events file yet/.test(g0.events.why) && g0.today === null && g0.heartbeat?.ok === false && /^no heartbeat yet/.test(g0.heartbeat.why));
  const iso = (msAgo) => new Date(Date.now() - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const line = (id, type, x = {}) => JSON.stringify({ ts: iso(60000 - id * 1000), at: iso(60000 - id * 1000), type, layer: 'L2_STAGE1', target: 'i' + id, latency_ms: null, detail: {}, id, kind: type, trace: 'sweep-abc', ...x });
  const L = [line(1, 'SWEEP_START', { detail: { derived: true } }), line(2, 'GATE_DROP', { detail: { rule: 'dedupe.near_title', title: 'SECRET-TITLE about a person', error: true } }),
    line(3, 'GATE_PASS', { layer: 'L2_STAGE2', kind: 'PASS' }), line(4, 'CALL', { layer: 'L2_STAGE2', kind: 'CALL', detail: { tokens: 1200 } }), line(5, 'CALL', { layer: 'L2_STAGE3', kind: 'CALL', detail: { tokens: 800 } }),
    line(6, 'SWEEP_DONE', { layer: 'sweep', kind: 'SWEEP_DONE', latency_ms: 4000, detail: { scored: 1, dropped: 1, tokens: 2000, tokens_today: 2000, dlq: 1 } }),
    line(7, 'SKIP', { layer: 'schedule', kind: 'SKIP', target: 'sweep', detail: { run: 'sweep', reason: 'free RAM 2400 MB is under 2500 MB' } }), line(8, 'BREAKER_TRIP', { layer: 'connector', kind: 'BREAKER_TRIP', target: 'connector.rss' }),
    line(9, 'TASTE', { layer: 'taste', target: 'my-private-keyword', kind: 'TASTE' }), '{"torn": ', 'not json'];
  fs.writeFileSync(evp, L.join('\n') + '\n');
  fs.writeFileSync(path.join(homeE, 'heartbeat.json'), JSON.stringify({ name: 'lobe', lastRun: iso(30000), everyMin: 120, checked: 12, found: 2, ms: 900, error: 'breaker connector.rss is OPEN; SECRET-ERROR-TEXT C:\\Users\\x', bands: [{ band: 2, name: 'fringe', sources: 3, items24h: 9, newestUtc: iso(600000) }, { band: 9, name: 'bogus' }], breakersOpen: 1, dlq: 1, csfAgeMin: 30, skipped: ['sweep: SECRET-SKIP-WORDS'] }));
  await pause(60);
  const sE = await get(E, '/api/state'), gE = sE.json?.lobeGlass;
  check('ZG30-2 from files: sweeps run vs skipped today, gate counts, tokens today (stage-2/3 CALL rows, as gate.py counts them), the ceiling, the trip', gE?.events?.ok === true && gE.today?.sweeps === 1 && gE.today.skips === 1 && gE.today.passes === 1 && gE.today.drops === 1 && gE.today.tokens === 2000 && gE.ceiling === 150000 && gE.trips.map((t) => t.id).join() === 'connector.rss' && gE.today.skipWhy[0][0] === 'free RAM 2400 MB is under 2500 MB', JSON.stringify(gE?.today));
  check('ZG30-2 from the heartbeat: breakers open, DLQ, per band last fetch (an unknown band dropped), RAM free and needed', gE?.heartbeat?.ok === true && gE.heartbeat.breakersOpen === 1 && gE.heartbeat.dlq === 1 && gE.heartbeat.bands.length === 1 && gE.heartbeat.bands[0].name === 'fringe' && gE.ram.needMb === 2500 && gE.ram.freeMb > 0);
  check('rule: counts, ids and kinds only: no detail text, no heartbeat error text or skip words, no taste keyword reach the phone', !sE.body.includes('SECRET') && !sE.body.includes('C:\\\\Users') && !sE.body.includes('my-private-keyword') && gE.heartbeat.failing === true && gE.heartbeat.skipped === 1);
  const hist = (await get(E, '/api/events?n=50')).json?.data || [], lobeH = hist.filter((e) => e.src === 'lobe');
  check('ZG30-1 /api/events carries the lobe lines (src lobe) beside the Yard\'s, cleaned, torn and bad lines skipped', lobeH.length === 9 && lobeH.find((e) => e.type === 'GATE_DROP')?.detail?.rule === 'dedupe.near_title' && !('title' in lobeH.find((e) => e.type === 'GATE_DROP').detail) && lobeH.find((e) => e.type === 'GATE_DROP').detail.error === true && lobeH.find((e) => e.type === 'TASTE').target === null);
  // the live stream: a new line arrives once; after a rotation (the file rewritten smaller) the lines already sent are not sent again
  const got30 = []; let sawState = false;
  const rq30 = http.get({ host: '127.0.0.1', port: E.port, path: '/api/stream', agent: false, headers: { Authorization: 'Bearer ' + E.key } }, (res) => {
    let buf = ''; res.setEncoding('utf8');
    res.on('data', (d) => { buf += d; for (let i = buf.indexOf('\n\n'); i >= 0; i = buf.indexOf('\n\n')) { const m = buf.slice(0, i); buf = buf.slice(i + 2); if (/^event: state/m.test(m)) sawState = true; const x = /^event: event\ndata: (.*)$/m.exec(m); if (x) { try { const e = JSON.parse(x[1]); if (e.src === 'lobe') got30.push(e); } catch {} } } });
  });
  rq30.on('error', () => {});
  for (let i = 0; i < 40 && !sawState; i++) await pause(100);
  await pause(1300);
  const firstN = got30.length;
  check('ZG30-1 a new stream gets the lobe\'s newest lines in its first message', firstN === 9, String(firstN));
  const L10 = line(10, 'CSF_RECOMPILED', { layer: 'csf', kind: 'CSF_RECOMPILED' }); fs.appendFileSync(evp, L10 + '\n');
  for (let i = 0; i < 30 && got30.length === firstN; i++) await pause(100);
  await pause(1200);
  check('ZG30-1 an appended line reaches an open phone once, within 3 s', got30.slice(firstN).map((e) => e.id).join() === '10', got30.slice(firstN).map((e) => e.id).join());
  const before = got30.length;
  fs.writeFileSync(evp, [L[5], L[6], L10, line(11, 'GATE_DROP', { detail: { signal_score: 12 } })].join('\n') + '\n');   // rotation: smaller, kept lines first
  for (let i = 0; i < 30 && got30.length === before; i++) await pause(100);
  await pause(1500);
  check('ZG29 Unresolved: after a rotation only the new line is sent; repeat lines (same type and id) are dropped', got30.slice(before).map((e) => e.id).join() === '11', got30.slice(before).map((e) => `${e.type}:${e.id}`).join());
  rq30.destroy();
  const gR = (await get(E, '/api/state')).json?.lobeGlass;
  check('ZG30-2 after the rotation the counts are rebuilt from the file, not added twice', gR?.today?.sweeps === 1 && gR.today.skips === 1 && gR.today.drops === 1 && gR.trips.length === 0, JSON.stringify(gR?.today));
  // unreadable: the events file is a folder; a broken heartbeat
  fs.rmSync(evp); fs.mkdirSync(evp); fs.writeFileSync(path.join(homeE, 'heartbeat.json'), '{"lastRun": SECRET');
  await pause(60);
  const gU = (await get(E, '/api/state'));
  check('rule: an unreadable events file and a broken heartbeat are unknown with the reason (never healthy), and their text never leaves', gU.json?.lobeGlass?.events?.ok === false && gU.json.lobeGlass.events.why === 'events.jsonl is not a file' && gU.json.lobeGlass.today === null
    && gU.json.lobeGlass.heartbeat.ok === false && /not the lobe's/.test(gU.json.lobeGlass.heartbeat.why) && !gU.body.includes('SECRET') && /Health unknown/.test(worldHtml(gU.json.lobe, { glass: gU.json.lobeGlass })));
  check('ZG30-1 the unreadable file adds no lobe line to /api/events', ((await get(E, '/api/events?n=50')).json?.data || []).every((e) => e.src !== 'lobe'));
} catch (e) { crashed(check, e); } finally { await stop(); }

// ---- 7. the route reads one JSON file: no git, no model, no database on the event loop ----
{
  const src = fs.readFileSync(path.join(here, 'server.mjs'), 'utf8');
  const body = src.slice(src.indexOf('function lobeFile()'), src.indexOf('// lead.json has two writers'));
  check('ZG09-3 the lobe reader uses fs.statSync and fs.readFileSync only (no git, no child process, no worker, no sqlite)', body.length > 200 && /fs\.statSync/.test(body) && /fs\.readFileSync/.test(body) && !/exec|spawn|Worker|sqlite|git|fetch\(/.test(body));
  check('ZG09-3 the state carries the lobe (so a change is a patch) and /api/lobe sits behind the auth check', /lead: leadView\(\), lobe: lobeView\(\)/.test(src) && src.indexOf("url.pathname === '/api/lobe'") > src.indexOf('if (!authed(req)) return send(res, 401'));
}

// ---- ZG-13: the Owner reader and writer: files only, writes only from the POST route ----
{
  const src = fs.readFileSync(path.join(here, 'server.mjs'), 'utf8');
  const body = src.slice(src.indexOf('// ---- ZG-13: the Owner\'s taps on the World view'), src.indexOf('function lobeAct(req, body)'));
  check('ZG13 the Owner readers use fs and crypto only (no child process, no worker, no database)', body.length > 2000 && !/exec|spawn|Worker|sqlite|fetch\(/.test(body));
  const writes = [...src.matchAll(/tapAppend\(|lobeAct\(/g)].length;
  check('ZG13 lobeAct is called only from POST /api/lobe, and tapAppend only from lobeAct and its ZG-25 and ZG-40 helpers (no automatic write)', writes === 9 && src.indexOf("if (url.pathname === '/api/lobe') { let r; try { r = lobeAct(req, body)") > src.indexOf("if (req.method !== 'POST') return send(res, 405"), String(writes));
  const lobeSrc = fs.readFileSync(path.join(here, 'public', 'lobe.js'), 'utf8'), wire = lobeSrc.slice(lobeSrc.indexOf('export function wireWorld'));
  check('ZG13 the view posts only inside click and submit handlers (no timer, no render-time write)', !/setInterval|setTimeout/.test(wire) && (wire.match(/\bpost\(/g) || []).length === 1 && !/\bpost\(/.test(lobeSrc.slice(0, lobeSrc.indexOf('export function wireWorld'))));
}
// ---- ZG-25: the decision readers read files only, and the two tap writers are reached only from lobeAct ----
{
  const src = fs.readFileSync(path.join(here, 'server.mjs'), 'utf8');
  const body = src.slice(src.indexOf('// ---- ZG-25: the decision and post-mortem cards'), src.indexOf('// ---- ZG-30: the glass box'));
  check('ZG25-3 no database on the event loop: the decision readers use fs only (no child process, no worker, no sqlite, no memory.db, no fetch)', body.length > 2000 && /fs\.readFileSync/.test(body) && !/child_process|execFile|execSync|(?<!\.)\bexec\(|spawn|Worker|sqlite|memory\.db|fetch\(|require\(/.test(body));   // RegExp .exec( is not a process
  const calls = (name) => (src.match(new RegExp(`\\b${name}\\(`, 'g')) || []).length;
  check('ZG25 decideAct and postmortemAct are called only from lobeAct (one call each, behind POST /api/lobe), and each writes through tapAppend', calls('decideAct') === 2 && calls('postmortemAct') === 2
    && /if \(op === 'decision' && body\.decision !== undefined\) return decideAct\(who, body\)/.test(src.slice(src.indexOf('function lobeAct(req, body)'))) && (body.match(/tapAppend\(/g) || []).length === 2);
  check('ZG25 the board state carries the decisions inside the Owner part (a flags.json change is a patch)', /decide: decideView\(\)/.test(src) && /sigOf\(lobeFlagsFile\(\)\)/.test(src));
}
// ---- ZG-30: the glass box reads files only: nothing on the event loop opens the database or starts a process ----
{
  const src = fs.readFileSync(path.join(here, 'server.mjs'), 'utf8');
  const body = src.slice(src.indexOf('// ---- ZG-30: the glass box'), src.indexOf('// a push (counts only, with push on)'));
  check('ZG30-3 the glass box readers use fs only (no child process, no worker, no sqlite, no database file, no fetch)', body.length > 3000 && !/exec|spawn|Worker|sqlite|memory\.db|fetch\(|require\(/.test(body));
  check('ZG30-1 the live pass sends the lobe lines through lobeLive (once each) and the state carries lobeGlass', /for \(const e of lobeLive\(\)\) broadcast\('event', e\)/.test(src) && /lobeGlass: lobeGlass\(\)/.test(src));
  const app = fs.readFileSync(path.join(here, 'public', 'app.js'), 'utf8');
  check('ZG30-1 app.js: lobe lines through lobeSentence, every dedupe by lobeEventKey, the Glass box from state.lobeGlass', /if \(e\.src === 'lobe'\) return lobeSentence\(e\)/.test(app) && (app.match(/lobeEventKey/g) || []).length >= 7 && !/x\.ts === e\.ts && x\.type === e\.type/.test(app) && /glass: S\.state\.lobeGlass/.test(app));
}
console.log(JSON.stringify(results));
process.exit(results.every((r) => r.pass) ? 0 : 1);
