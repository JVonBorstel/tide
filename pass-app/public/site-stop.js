// The Board's per-Site stops (TD-8, multi-site design section 5). Imported by app.js: the banners (renderBanners) and the Sites rows in
// the settings sheet (openSettings). Pure text, no DOM, tested in node by tests/Test-PassApp.ps1. Only the existing banner, set-row and
// btn looks; nothing new to draw. items: state.siteStops from the server ([{code, stopped, stopWork, stopWorkUntil}]); none = nothing.
import { esc } from './scene.js';

const defaultWhen = (iso) => new Date(iso).toLocaleString([], { hour: 'numeric', minute: '2-digit' });
const list = (items) => (Array.isArray(items) ? items : []).filter((x) => x && /^[A-Z]{2,3}$/.test(x.code || ''));

// One banner per Site the Owner stopped (calm, with Resume) and one per Site whose own Stop-work order is open (many of its steps failed).
// The global pause has its own banner and still wins; these never say the whole Yard stopped.
export function siteStopBanners(items, { when = defaultWhen } = {}) {
  const out = [];
  for (const s of list(items)) {
    const c = esc(s.code);
    if (s.stopped) out.push(`<div class="banner calm" data-site-stop="${c}">Site ${c} stopped by you: none of its new work starts. Its running work, the watchers and the other Sites carry on.<button class="btn" data-set="site-resume" data-site="${c}">Resume ${c}</button></div>`);
    if (s.stopWork) {
      const t = s.stopWorkUntil && !Number.isNaN(new Date(s.stopWorkUntil).getTime()) ? ` until about ${esc(when(s.stopWorkUntil))}, then one trial step runs first` : '';
      out.push(`<div class="banner" data-site-breaker="${c}">Stop-work order on ${c}: most of its recent steps failed, so its new work waits${t}. The other Sites carry on.</div>`);
    }
  }
  return out;
}

// The settings sheet's Sites group: one tap per Site, Stop work on this Site or Resume. '' with no Sites registered.
export function siteStopRows(items) {
  const rows = list(items).map((s) => {
    const c = esc(s.code);
    return s.stopped
      ? `<button class="set-row" data-set="site-resume" data-site="${c}"><i class="set-ic" aria-hidden="true">▶</i><span>Resume Site ${c}<small>Stopped by you. Its new work starts again on the next pass.</small></span></button>`
      : `<button class="set-row" data-set="site-pause" data-site="${c}"><i class="set-ic" aria-hidden="true">■</i><span>Stop work on Site ${c}<small>None of its new work starts. Running work and the other Sites carry on.</small></span></button>`;
  });
  return rows.length ? `<h3 class="set-label">Sites</h3><div class="set-group">${rows.join('')}</div>` : '';
}
