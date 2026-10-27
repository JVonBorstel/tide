// Tests for the Site on the Board (pass-app/public/sites.js, multi-site design TD-4): the chip, the Floor id, the filter, the count line,
// the bar's markup, and that app.js, server.mjs and the stylesheet use them as designed. Pure, no browser, no server, no timers.
// Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it (the server's jobView.site is checked there, against real job files).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SITE_CODES, SITE_NAMES, siteOf, floorOf, siteChip, withFloor, sitesIn, siteFilterOf, bySite, siteCountLine, siteBar } from './public/sites.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const read = (p) => fs.readFileSync(path.join(here, p), 'utf8');
const out = []; const check = (name, pass) => out.push({ name, pass: !!pass });
const app = read('public/app.js'), server = read('server.mjs'), css = read('public/app.css'), sw = read('public/sw.js');
const repoCfg = fs.readFileSync(path.join(here, '..', 'kitchen', 'repo-config.ps1'), 'utf8');

// the codes are the Yard's own list, in one spelling everywhere
const psCodes = (/\$script:RepoSiteCodes = @\(([^)]*)\)/.exec(repoCfg)?.[1] || '').match(/[A-Z]+/g) || [];
const srvCodes = (/const SITE_CODES = \[([^\]]*)\]/.exec(server)?.[1] || '').match(/[A-Z]+/g) || [];
check('codes: sites.js, server.mjs and repo-config.ps1 RepoSiteCodes list the same Site codes', psCodes.length >= 4 && psCodes.join() === SITE_CODES.join() && srvCodes.join() === SITE_CODES.join());
check('codes: every code has a name', SITE_CODES.every((c) => typeof SITE_NAMES[c] === 'string' && SITE_NAMES[c].length > 1));

// what is a Site: a known code only, exact capitals
check('siteOf: a known code', siteOf({ site: 'TD' }) === 'TD' && siteOf({ site: 'GW' }) === 'GW');
check('siteOf: no Site, a lower-case code, an unknown code, markup or a non-string is no Site', ['', 'td', 'XX', '<b>', 7, null, undefined].every((s) => siteOf({ site: s }) === '') && siteOf(null) === '');

// the chip: never empty, only fixed words
check('chip: an order with no Site has no chip at all (the row reads exactly as before)', siteChip({ id: 'J1' }) === '' && siteChip({ site: '' }) === '' && siteChip({ site: 'nope' }) === '');
check('chip: the code, its Site named for screen readers and on hover', siteChip({ site: 'GW' }) === '<span class="site-chip" data-site="GW" title="Site: Demo Project" aria-label="Site Demo Project">GW</span>');
check('chip: markup in the site field never reaches the page', siteChip({ site: '<img src=x onerror=alert(1)>' }) === '');

// the Floor id beside the ticket (server.mjs sends it as people see it: GW-53)
const t = '<span class="mono">WO-0294</span>';
check('floor: the ticket then the Floor id', withFloor(t, { floor: 'GW-53' }) === `${t} · <span class="mono">GW-53</span>`);
check('floor: no Floor, or anything not an id, leaves the ticket as it was', withFloor(t, {}) === t && withFloor(t, { floor: 'GW-53 <b>' }) === t && withFloor(t, { floor: 42 }) === t && floorOf({ floor: 'B-1' }) === 'B-1');

// the filter
const jobs = [
  { id: 'J1', site: 'GW', status: 'running' }, { id: 'J2', site: 'GW', status: 'running' }, { id: 'J3', site: 'GW', status: 'running' },
  { id: 'J4', site: 'GW', status: 'waiting-approval' }, { id: 'J5', site: 'TD', status: 'pending' }, { id: 'J6', site: 'TD', status: 'pending' },
  { id: 'J7', status: 'pending' }, { id: 'J8', site: 'JH', status: 'done' }];
check('sitesIn: the Sites on the board, in code order, once each', sitesIn(jobs).join() === 'GW,JH,TD' && sitesIn([]).length === 0 && sitesIn(null).length === 0);
check('filter: All shows every order, with or without a Site', bySite(jobs, 'all').length === jobs.length);
check('filter: one Site shows only its orders (an order with no Site is not in it)', bySite(jobs, 'TD').map((j) => j.id).join() === 'J5,J6' && bySite(jobs, 'GW').length === 4);
check('filter: an unknown choice shows everything (a bad stored value never hides the board)', bySite(jobs, 'XX').length === jobs.length && bySite(jobs, undefined).length === jobs.length);
check('filter: the remembered Site holds while it has orders; else All', siteFilterOf('TD', jobs) === 'TD' && siteFilterOf('ZG', jobs) === 'all' && siteFilterOf(null, jobs) === 'all' && siteFilterOf('TD', []) === 'all');

// the count line
check('count line: the design example, word for word', siteCountLine(jobs.slice(0, 6)) === 'GW 3 building, 1 needs sign-off · TD 2 queued');
check('count line: plural sign-off; a Site with nothing in play is left out; no Sites, no line', siteCountLine([{ site: 'ZG', status: 'needs-human' }, { site: 'ZG', status: 'waiting-approval' }, { site: 'TD', status: 'done' }]) === 'ZG 2 need sign-off' && siteCountLine([{ status: 'running' }]) === '' && siteCountLine([]) === '');

// the bar
const bar = siteBar(jobs, 'TD');
check('bar: no order with a Site, no bar (the board is exactly as before TD-4)', siteBar([{ id: 'J1', status: 'running' }], 'all') === '' && siteBar([], 'all') === '');
check('bar: the count line, then a segment All plus each Site on the board', bar.startsWith('<div class="site-bar"><p class="site-count">GW 3 building, 1 needs sign-off · TD 2 queued</p><div class="seg site-seg" role="radiogroup" aria-label="Site">') && (bar.match(/data-site-filter=/g) || []).length === 4);
check('bar: the Site in force is the checked one, the others are not', /data-site-filter="TD" aria-checked="true"/.test(bar) && /data-site-filter="all" aria-checked="false"/.test(bar) && (bar.match(/aria-checked="true"/g) || []).length === 1);
check('bar: buttons are real buttons with names (screen readers say "Demo Project", not "GW")', /<button type="button" role="radio" data-site-filter="GW" aria-checked="false" aria-label="Demo Project">GW<\/button>/.test(bar));
check('bar: Sites with only finished orders still get a button but no count', /data-site-filter="JH"/.test(bar) && !/JH \d/.test(bar));

// the server's display id is roadmap-lib.ps1 Get-SiteDisplayId, mirrored: run its own source here
const fn = /function siteDisplayId\(block, id\) \{[\s\S]*?\n\}/.exec(server)?.[0] || '';
const re = /const FLOOR_ID = (\/.*\/);/.exec(server)?.[1] || '/x^/';
const sdi = fn ? new Function(`const FLOOR_ID = ${re}; ${fn}; return siteDisplayId;`)() : () => null;
const gw = { code: 'GW', id_prefix: 'B' };
check('display id: B-42 shows GW-42 (digits as stored), b-7 too (the prefix match ignores case, like -ine)', sdi(gw, 'B-42') === 'GW-42' && sdi(gw, 'B-0042') === 'GW-0042' && sdi(gw, 'b-7') === 'GW-7');
check('display id: no site block, another prefix, or not an id is returned unchanged', sdi(null, 'B-42') === 'B-42' && sdi(gw, 'NN-3') === 'NN-3' && sdi(gw, 'B-12345') === 'B-12345' && sdi(gw, 'hello') === 'hello' && sdi({ code: 'TD', id_prefix: 'TD' }, 'TD-7') === 'TD-7');

// the wiring in app.js
check('app.js: imports the Site helpers from sites.js', /import \{ siteChip, withFloor, siteBar, siteFilterOf, bySite \} from '\.\/sites\.js'/.test(app));
check('app.js: every list row and every card on the stove carries the chip', app.includes('const meta = [siteChip(j) + withFloor(`<span class="mono">${ticket(j.id)}</span>`, j), stuckChip(j)];') && app.includes('<div class="row-side cook-side">${siteChip(j)}<span class="mono ticket-no">'));
check('app.js: the lanes are the filtered orders and the bar is the first block', app.includes('const jobs = bySite(s.jobs, siteF);') && app.includes("const blocks = [sites && { k: 'sites', h: sites },"));
check('app.js: the filter is remembered on this phone, and a change redraws the board', app.includes("S.siteFilter = store.get('siteFilter', 'all');") && app.includes("store.set('siteFilter', S.siteFilter)") && /changed\('pass', \[[^\]]*S\.siteFilter\]\)/.test(app));
check('sw.js: sites.js is in the offline shell', sw.includes("'/sites.js'"));

// phone at 360 px, pixel tokens, reduced motion
const rules = css.slice(css.indexOf('/* TD-4 the Site on the Board'));
check('css: the chip uses the pixel tokens (notch, steel, ember) and the mono face', /\.site-chip\{[^}]*clip-path:var\(--px-notch-s\)/.test(rules) && /var\(--px-steel\)/.test(rules) && /--site:var\(--px-ember\)/.test(rules) && /font:700 11px\/16px var\(--mono\)/.test(rules));
check('css: nothing fixed-width (reads at 360 px); the count line wraps instead of pushing the page wider', !/width:\s*\d{3,}px/.test(rules) && /\.site-count\{[^}]*overflow-wrap:anywhere/.test(rules));
check('css: no motion in the Site rules (nothing for reduced motion to stop); the segment buttons keep the 44 px touch rule', !/animation|@keyframes/.test(rules) && /\.site-seg button\{[^}]*transition:none/.test(rules) && /\.seg button[^{]*\{min-height:44px\}/.test(css));

console.log(JSON.stringify(out));
