// The Board's "main is red" banner (TD-EH-03a): one line per Tower whose main verify last found red: since when, which suites, why.
// Imported by app.js (renderBanners, mainStatusBanners); pure text, no DOM, tested in node by tests/Test-PassApp.ps1. Existing .banner look.
import { esc, ticket } from './scene.js';

const defaultWhen = (iso) => new Date(iso).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' });
// how long, as the rest of the Board says it (45 min, 3.5 h)
const span = (ms) => { const m = Math.max(0, Math.round(ms / 60000)); return m < 60 ? `${m} min` : `${(m / 60).toFixed(1).replace(/\.0$/, '')} h`; };
const stop = (s) => (/[.!?]$/.test(s) ? s : s + '.');

// towers: state.mainStatus from the server (pass-app/server.mjs mainStatusView). A green Tower says nothing; a red or unreadable one is
// a banner with the Board's fault dot. Returns the banners' markup, in the order given.
export function mainStatusBanners(towers, { when = defaultWhen, now = Date.now() } = {}) {
  const out = [];
  for (const t of Array.isArray(towers) ? towers : []) {
    if (t?.state === 'unreadable') { out.push(`<div class="banner" data-main-status="unreadable">Main status for ${esc(t.tower)} cannot be read, so whether its main is red is unknown.</div>`); continue; }
    if (t?.state !== 'red') continue;
    const at = t.since ? new Date(t.since).getTime() : NaN;
    const parts = [`Main is red: ${esc(t.tower)}, ${Number.isNaN(at) ? 'since an unknown time' : `since at least ${esc(when(t.since))} (${span(now - at)})`}.`];
    if ((t.suites || []).length) parts.push(`Failed: ${esc(t.suites.join(', '))}.`);
    parts.push(t.why ? `Why: ${esc(stop(String(t.why)))}` : 'No reason was recorded.');
    if (t.sha) parts.push(`Last checked ${esc(String(t.sha).slice(0, 12))}${/^J\d+$/.test(t.job || '') ? ` by Work order ${esc(ticket(t.job))}` : ''}.`);
    out.push(`<div class="banner" data-main-status="red">${parts.join(' ')}</div>`);
  }
  return out;
}
