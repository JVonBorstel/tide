// Tests for the Board's Self card (ZG-45: pass-app/public/lobe-self.js selfState / selfCard / selfCount, and its wiring in lobe.js and app.js): pure
// checks on synthetic frames and Owner parts in server.mjs's shapes, never the live lobe. Run by tests/Test-PassApp.ps1 beside test-lobe.mjs. Prints [{name, pass}].
import fs from 'node:fs'; import path from 'node:path';
import { worldHtml } from './public/lobe.js';
import { selfState, selfCard, selfCount, NO_CALIB } from './public/lobe-self.js';
import { here, NOW, at, checker, ok, frame, cards, oldNames, PRIVATE } from './test-lobe-kit.mjs';

const { results, check } = checker();
const read = (p) => fs.readFileSync(path.join(here, p), 'utf8');
// the lines csf.py writes into shadow_blindspots (zeitgeistd connectors/roadmap.py and shadow.py), synthetic ids
const POUR4 = 'GW W4: 0 of 10 floors touched in 14 days; 2 merged, 0 cooking, 8 with no order';
const POUR3 = 'DEMO Pour3: 1 of 3 floors touched in 14 days; 0 merged, 1 cooking, 2 with no order';
const UNREAD = 'JH roadmap: unreadable (missing)', NOHOURS = 'roadmap shadow: yard events missing; Yard hours unknown, no pour called shadow';
const DOM = 'INCOME_TRACK: 0 h in 14 d; unmet SYSTEM';
const TTC = { '7d': { loop: 3.5, signoff: 0.5, decision: null }, '30d': { loop: 50, signoff: 2, decision: 24 } };
const fr = (s2 = {}, meta = {}) => ok(frame({ s2, meta: { ttc_median_hours: TTC, trust: 'foreman brier 0.08 (trust 0.92) over 3 claims; 5 unproven bullets', trimmed: 0, ...meta } }));
const due = (id, answered = null) => ({ id, day: 30, dueAt: at(60), expiresAt: at(-60 * 24 * 13), choice: 'A', proof: { kind: 'on-main', say: 'still on main' }, answered });
const board = { ok: true, at: at(60), firstAt: at(60 * 24 * 2), weekAgo: null, now: { value: 0.44, claims: 9, pending: 0, inspector: { value: 0.5, claims: 6 }, builder: { value: 0.33, claims: 3 }, missing: null, models: [] } };
const owner = (x = {}) => ({ charter: { state: 'none' }, proposals: [], taste: [], decide: { ok: true, updated: at(5), ready: [], due: [due('D-0001'), due('D-0002'), due('S-J140-A9', { choice: 'held', at: at(3) })] }, trust: { board }, ...x });
const dd = (h, label) => ((h.split(`<dt>${label}</dt><dd>`)[1] || '').split('</dd>')[0]);

// ---- ZG45-1: where the card sits ----
{
  const withOwner = cards(worldHtml(fr(), { now: NOW, owner: owner() })), noFrame = cards(worldHtml({ ok: false, why: 'no frame yet' }, { now: NOW, owner: owner() }));
  check('ZG45-1 the Self card sits on the World view after Decisions (and Trust), before Lobe health, with the Owner part', withOwner.join() === 'charter,loops,signals,taste,decide,trust,self,health', withOwner.join());
  check('ZG45-1 with no frame the Self card still shows (unknowns with the reason); the read-only view has no Self card', noFrame.join() === 'charter,taste,decide,trust,self' && !cards(worldHtml(fr(), { now: NOW })).includes('self'));
}

// ---- ZG45-1: the full card ----
{
  const v = fr({ shadow_blindspots: [POUR4, POUR3, UNREAD, DOM, 'something <b>else</b>'] }), o = owner(), h = selfCard(v, o, NOW), s = selfState(v, o, NOW);
  check('ZG45-1 shadow Pours: one per pour line, Floors with no order summed (8 + 2), Charter domains with 0 h counted', s.pours.n === 2 && s.pours.untouched === 10 && s.domains.n === 1
    && dd(h, 'Shadow Pours (0 h in 14 days)') === '2' && dd(h, 'Floors with no order in them') === '10' && dd(h, 'Charter domains with 0 h in 14 days') === '1');
  check('ZG45-1 each shadow Pour is listed with its id as the file spells it and the Glossary\'s words (Floors, building)', h.includes('<b class="lobe-dom">GW W4</b> 0 of 10 Floors touched in 14 days; 2 merged, 0 building, 8 with no order')
    && h.includes('<b class="lobe-dom">DEMO Pour3</b> 1 of 3 Floors touched'));
  check('ZG45-1 a Blueprint not read is named beside the count; the domain line with its unmet dependency; an odd line is counted, never shown', h.includes('Not read: JH Blueprint unreadable (missing).')
    && h.includes('<b class="lobe-dom">INCOME_TRACK</b> 0 h in 14 days; unmet SYSTEM') && h.includes('1 shadow line in the frame not counted here') && !h.includes('else'));
  check('ZG45-1 post-mortems from flags.json: 3 due, 2 still waiting (one answered since the lobe\'s run)', dd(h, 'Post-mortems due') === '3' && dd(h, 'Still waiting for you') === '2');
  check('ZG45-1 answered this month and the calibration delta are unknown with the reason (the Board does not read the lobe\'s database)', dd(h, 'Answered this month').startsWith('unknown (the Board keeps an answer only until the lobe&#39;s next run (1 since its last run)')
    && dd(h, 'Calibration delta') === `unknown (${NO_CALIB.replace(/'/g, '&#39;')})`);
  check('ZG45-1 Time-to-Close medians over 7 and 30 days, an unknown median says unknown, screen minutes unknown', dd(h, 'Last 7 days') === 'open loop 3.5 h · Sign-off 30 min · decision unknown'
    && dd(h, 'Last 30 days') === 'open loop 2 d · Sign-off 2 h · decision 24 h' && dd(h, 'Screen minutes') === 'unknown (nothing measures them)');
  check('ZG45-1 the trust line: the lobe\'s Foreman line from the frame and the crews\' Brier from the scoreboard', dd(h, 'Foreman') === 'foreman brier 0.08 (trust 0.92) over 3 claims; 5 unproven bullets' && dd(h, 'Crews') === 'Brier 0.44 over 9 claims');
  check('ZG45-1 the badge and selfCount: shadow Pours plus post-mortems waiting (2 + 2)', h.includes('lobe-badge count">4<') && selfCount(v, o, NOW) === 4);
  check('ZG45-1 a trimmed frame says "at least" (csf.py may have dropped lines to fit)', dd(selfCard(fr({ shadow_blindspots: [POUR4] }, { trimmed: 3 }), o, NOW), 'Shadow Pours (0 h in 14 days)') === 'at least 1');
}

// ---- the Charter: not written yet, said plainly ----
{
  const ex = selfCard(fr(), owner(), NOW), lk = selfCard(fr({}, { charter: 'LOCKED' }), owner(), NOW);
  check('Charter not written: the card says so plainly (the domains are the example\'s)', ex.includes(`data-self-charter="example">The Owner's Charter is not written yet, so the Charter domains below are the example's, not yours.`)
    && !lk.includes('not written yet') && lk.includes('locked Charter'));
}

// ---- unknown, never a guessed 0 ----
{
  const none = selfCard({ ok: false, why: 'no frame yet' }, { decide: { ok: false, why: 'no flags.json yet: the lobe writes it on its decisions run (ZG-24)', ready: [], due: [] } }, NOW);
  check('empty: no frame = every row unknown with the reason, the UNKNOWN badge, the Charter unknown', none.includes('lobe-badge example">UNKNOWN') && dd(none, 'Shadow Pours (0 h in 14 days)') === 'unknown (no frame yet: the lobe has not written csf.json)'
    && dd(none, 'Time-to-Close') === 'unknown (no frame yet: the lobe has not written csf.json)' && dd(none, 'Foreman').startsWith('unknown (no frame yet') && dd(none, 'Crews') === 'unknown (not sent)'
    && none.includes('data-self-charter="unknown">Charter unknown (no frame yet') && dd(none, 'Post-mortems due').startsWith('unknown (no frame yet'));
  const stale = selfState(ok(frame({ meta: { compiled_utc: at(300), last_sweep_utc: at(300) } })), null, NOW);
  check('stale: a frame over the limit is not counted (unknown, the frame is stale)', stale.pours.n === null && stale.pours.why === 'the frame is stale (5 h old)');
  const nl = selfState(fr(), null, NOW), nh = selfState(fr({ shadow_blindspots: [POUR4, NOHOURS] }), null, NOW), ur = selfState(fr({ shadow_blindspots: [UNREAD] }), null, NOW);
  check('no Blueprint line at all is unknown (only a 0-hour Pour writes a line, so none cannot tell fine from never read)', nl.pours.n === null && nl.pours.why === 'no Blueprint line in the frame: every Pour got hours, or no Blueprint was read');
  check('Yard hours unknown: no Pour is called shadow, said with the events state', nh.pours.n === null && nh.pours.why === 'the Yard\'s events are missing, so no Pour is called shadow');
  check('only an unreadable Blueprint: unknown and named, never an empty shadow', ur.pours.n === null && ur.pours.why === '1 Blueprint not read: JH unreadable' && selfCount(fr({ shadow_blindspots: [UNREAD] }), null, NOW) === 1);   // 1 = the frame's post-mortem; the unknown Pours add 0
  const nt = selfState(fr({ shadow_blindspots: [DOM] }, { ttc_median_hours: null, trust: null }), null, NOW);
  check('no self-state yet: Charter domains and Time-to-Close unknown (the shadow graph has not run); no Foreman claim says so', nt.domains.n === null && /has not stored a self-state yet/.test(nt.ttc.why)
    && nt.trust.why === 'the lobe has no Foreman claim yet');
  const fromFrame = selfCard(fr(), { decide: { ok: false, why: 'no flags.json yet', ready: [], due: [] } }, NOW);
  check('no flags.json: post-mortems due from the frame\'s count, saying the taps wait for flags.json', dd(fromFrame, 'Post-mortems due') === '1 (from the frame; taps wait for flags.json: no flags.json yet)' && dd(fromFrame, 'Still waiting for you') === '1');
}

// ---- the rules: escaping, privacy, Glossary words, the pixel theme ----
{
  const v = fr({ shadow_blindspots: ['GW <script>x</script>: 0 of 2 floors touched in 14 days; 0 merged, 0 cooking, 2 with no order', DOM] }, { trust: 'foreman brier <i>0.1</i> (trust 0.9) over 1 claims; 0 unproven bullets' });
  const h = selfCard(v, owner(), NOW), full = selfCard(fr({ shadow_blindspots: [POUR4, POUR3, UNREAD, DOM] }), owner(), NOW);
  check('every word from the frame is escaped', !h.includes('<script>') && h.includes('GW &lt;script&gt;x&lt;/script&gt;') && !h.includes('<i>0.1</i>'));
  check('private: the Yard signal titles in the frame never reach the card', PRIVATE.every((p) => !full.includes(p) && !full.includes(p.split(': ')[1])));
  check('the Glossary\'s words, no old name (scripts/names-allow.json) in the card\'s text', /Pours/.test(full) && /Floors/.test(full) && /Sign-off/.test(full) && /Blueprint/.test(full)
    && oldNames().every((re) => !re.test(full.replace(/<[^>]+>/g, ' ')) && !re.test(selfCard(fr({ shadow_blindspots: [POUR4, NOHOURS] }), owner(), NOW).replace(/<[^>]+>/g, ' '))));
  const cls = (x) => new Set([...x.matchAll(/class="([^"]+)"/g)].flatMap((m) => m[1].split(/\s+/))), used = cls(full);
  const world = cls(worldHtml(fr(), { now: NOW, owner: { ...owner(), trust: undefined } }).replace(/<section class="lobe-card" data-card="self"[\s\S]*?<\/section>/, ''));   // the World view's classes before this card
  check('the pixel theme: no style attribute, and only classes the World view already uses (no new CSS)', !/style=/.test(full) && [...used].every((c) => world.has(c)), [...used].filter((c) => !world.has(c)).join());
}

// ---- static: pure, wired, cached ----
{
  const src = read('public/lobe-self.js'), app = read('public/app.js'), idx = read('public/index.html'), sw = read('public/sw.js'), lobe = read('public/lobe.js');
  check('pure: lobe-self.js has no fetch, timer, storage, DOM or write', !/\bfetch\(|setTimeout|setInterval|localStorage|document\.|XMLHttpRequest|WebSocket|\bpost\(/.test(src));
  check('ZG45-1 app.js only wires the World tab\'s badge count (selfCount into #count-world); index.html has the badge', /import \{ selfCount \} from '\.\/lobe-self\.js'/.test(app) && /\$\('count-world'\)[^\n]*selfCount\(s\.lobe, s\.lobeOwner/.test(app)
    && (app.match(/selfCount\(/g) || []).length === 1 && /data-view="world">[^\n]*id="count-world" hidden/.test(idx));
  check('lobe.js draws it from the view\'s own data, and the offline shell caches lobe-self.js', /import \{ selfCard \} from '\.\/lobe-self\.js'/.test(lobe) && (lobe.match(/selfCard\(view, owner, now\)/g) || []).length === 2 && sw.includes("'/lobe-self.js'"));
}

process.stdout.write(JSON.stringify(results));
process.exit(results.every((r) => r.pass) ? 0 : 1);
