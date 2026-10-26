// The Site on the Board (multi-site design TD-4): the chip on a row, the Site filter and the count line. Pure: no DOM, no fetch, no storage.
// Called by app.js (row, cookCard, renderPass); pass-app/test-sites.mjs runs it in node for tests/Test-PassApp.ps1.
// A job's site comes from server.mjs jobView (stored vars.site or its Tower's, kitchen/jobs-lib.ps1 Get-KitchenJobSite) and floor is the
// Floor id as people see it (roadmap-lib.ps1 Get-SiteDisplayId: B-53 shows GW-53). Anything not a known code is no Site: no chip, no
// filter, no count line, so a board with no Sites reads exactly as before TD-4. Only fixed words and known codes reach the markup.
export const SITE_CODES = ['GW', 'JH', 'TD', 'ZG'];   // kitchen/repo-config.ps1 RepoSiteCodes
export const SITE_NAMES = { GW: 'Demo Project', JH: 'Job hunt', TD: 'Tide', ZG: 'zeitgeistd' };   // naming/GLOSSARY.md
const FLOOR_ID = /^[A-Za-z][A-Za-z0-9]{0,5}-\d{1,4}$/;
export const siteOf = (j) => (j && SITE_CODES.includes(j.site) ? j.site : '');
export const floorOf = (j) => (j && typeof j.floor === 'string' && FLOOR_ID.test(j.floor) ? j.floor : '');
// the chip after the ticket: "TD"; '' for an order with no Site (never an empty chip)
export function siteChip(j) {
  const s = siteOf(j); if (!s) return '';
  return `<span class="site-chip" data-site="${s}" title="Site: ${SITE_NAMES[s]}" aria-label="Site ${SITE_NAMES[s]}">${s}</span>`;
}
// the ticket with its Floor, as the row shows it: "WO-0294 · GW-53" (the ticket is already safe markup, app.js ticket())
export const withFloor = (ticketHtml, j) => (floorOf(j) ? `${ticketHtml} · <span class="mono">${floorOf(j)}</span>` : ticketHtml);
// the Sites on the board now, in code order
export const sitesIn = (jobs) => SITE_CODES.filter((c) => (jobs || []).some((j) => siteOf(j) === c));
// the filter in force: the remembered one while that Site has orders on the board, else All (a stale choice never hides the board)
export const siteFilterOf = (saved, jobs) => (sitesIn(jobs).includes(saved) ? saved : 'all');
export const bySite = (jobs, f) => (f === 'all' || !SITE_CODES.includes(f) ? jobs : jobs.filter((j) => siteOf(j) === f));
const NEED = new Set(['waiting-approval', 'needs-human']);
// "GW 3 building, 1 needs sign-off · TD 2 queued": orders in play per Site (needs sign-off, building, queued); a Site with none is left out
export function siteCountLine(jobs) {
  return sitesIn(jobs).map((c) => {
    const mine = jobs.filter((j) => siteOf(j) === c);
    const needs = mine.filter((j) => NEED.has(j.status)).length, building = mine.filter((j) => j.status === 'running').length, queued = mine.filter((j) => j.status === 'pending').length;
    const parts = [building && `${building} building`, needs && `${needs} ${needs === 1 ? 'needs' : 'need'} sign-off`, queued && `${queued} queued`].filter(Boolean);
    return parts.length ? `${c} ${parts.join(', ')}` : '';
  }).filter(Boolean).join(' · ');
}
// the bar over the lanes: the count line and the filter segment (All, then each Site on the board); '' when no order has a Site
export function siteBar(jobs, f) {
  const codes = sitesIn(jobs); if (!codes.length) return '';
  const line = siteCountLine(jobs);
  const btn = (k, label, name) => `<button type="button" role="radio" data-site-filter="${k}" aria-checked="${f === k}" aria-label="${name}">${label}</button>`;
  return `<div class="site-bar">${line ? `<p class="site-count">${line}</p>` : ''}<div class="seg site-seg" role="radiogroup" aria-label="Site">${
    [btn('all', 'All', 'All Sites'), ...codes.map((c) => btn(c, c, SITE_NAMES[c]))].join('')}</div></div>`;
}
