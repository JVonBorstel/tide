// Owns the Work tab's place on the Board (lane L5, WO-UPG-L5-4, look A "inline list"): the view section, the tab, the flag check.
// Called by pass-app/public/app.js through its one L5 seam (a dynamic import, so a missing or failing file never stops the Board).
// The tab is behind the board.work flag: GET /api/work answers 404 while it is off, and then nothing here is shown. When it is on, the
// Ledger tab becomes "Work" and both screens carry a Work | Ledger switch (the old Ledger stays one tap away until cutover).
// The screen itself (view.js, queue.js, cards.js, replay.js, work.css) loads only once the flag is on.

const W = { on: null, view: null, mounted: false, ledgerLabel: '', ledgerHref: '' };

/**
 * @param {{ titles: Record<string, string>, buzz?: (ms?: number) => void }} o
 */
export function mountWork(o) {
  if (W.mounted) return; W.mounted = true;
  o.titles.work = 'Work';
  const main = document.getElementById('main'); if (!main) return;
  const sec = document.createElement('section');
  sec.className = 'view'; sec.id = 'view-work'; sec.hidden = true; sec.setAttribute('aria-labelledby', 'screen-title');
  main.appendChild(sec);
  sec.addEventListener('click', (e) => { if (/** @type {HTMLElement} */ (e.target).closest('[data-wk-probe]')) { sec.innerHTML = ''; shown(sec, o); } });
  new MutationObserver(() => shown(sec, o)).observe(sec, { attributes: true, attributeFilter: ['hidden'] });
  probe(o, sec);
  setInterval(() => { if (document.visibilityState === 'visible') probe(o, sec); }, 300000);
  // a #/work link opened before this file arrived: route again now that the view exists
  if (/^#\/?work\b/.test(location.hash)) dispatchEvent(new HashChangeEvent('hashchange'));
}

/** Is the flag on? 404 = off; anything else unknown keeps what we knew (a blip never hides the tab). */
function probe(o, sec) { return check(o, sec); }
async function check(o, sec) {
  let code = 0, error = "can't reach the Board";
  try { const r = await fetch('/api/work?page=1', { headers: { Accept: 'application/json' }, cache: 'no-store' }); code = r.status; const j = await r.json().catch(() => null); error = j?.error || `the Board answered ${code}`; if (j?.ok) badge(j.queueTotal); } catch { }
  if (code === 200) setOn(true, o, sec); else if (code === 404) setOn(false, o, sec);
  return { code, error };
}

function setOn(on, o, sec) {
  if (W.on === on) return; W.on = on;
  const link = document.querySelector('.bar a[data-view="ledger"]');
  if (link && !W.ledgerHref) { W.ledgerHref = link.getAttribute('href') || '#/ledger'; W.ledgerLabel = link.querySelector('span')?.textContent || 'Ledger'; }
  if (link) {
    link.setAttribute('href', on ? '#/work' : W.ledgerHref); link.classList.toggle('wk-on', on); const sp = link.querySelector('span'); if (sp) sp.textContent = on ? 'Work' : W.ledgerLabel;
    if (on && !link.querySelector('#count-work')) link.insertAdjacentHTML('beforeend', '<b class="dot-count" id="count-work" hidden></b>');
    if (!on) link.querySelector('#count-work')?.remove();
  }
  const lv = document.getElementById('view-ledger');
  let sw = document.getElementById('wk-switch-ledger');
  if (on && lv && !sw) { sw = document.createElement('div'); sw.id = 'wk-switch-ledger'; sw.innerHTML = switchHtml('ledger'); lv.prepend(sw); }
  if (!on) { sw?.remove(); if (/^#\/?work\b/.test(location.hash)) location.hash = '#/ledger'; }
  if (on) load(o, sec);
}

/** The tab's own count: the cards waiting on Jordan (the Ledger's count is hidden while Work holds its place). @param {number} n */
function badge(n) { const b = document.getElementById('count-work'); if (!b) return; b.hidden = !(n > 0); b.textContent = n > 0 ? String(n) : ''; b.setAttribute('aria-label', `${n} card${n === 1 ? '' : 's'} wait on you`); }

export const switchHtml = (cur) => `<nav class="wk-switch" aria-label="Work or the old Ledger"><a href="#/work"${cur === 'work' ? ' aria-current="page"' : ''}>Work</a><a href="#/ledger"${cur === 'ledger' ? ' aria-current="page"' : ''}>Ledger</a></nav>`;

let loading = null;
function load(o, sec) {
  if (!loading) {
    css();
    loading = import('./view.js').then((m) => { W.view = m.makeView(sec, { ...o, switchHtml, badge }); if (!sec.hidden) W.view.show(); return m; })
      .catch((e) => { loading = null; sec.innerHTML = `${switchHtml('work')}<p class="empty-line fault" role="alert">The Work screen could not load (${String(e?.message || e).replace(/[<>&]/g, '')}). Pull down to try again.</p>`; });
  }
  return loading;
}

function css() { if (!document.getElementById('wk-css')) { const l = document.createElement('link'); l.id = 'wk-css'; l.rel = 'stylesheet'; l.href = '/work/work.css'; document.head.appendChild(l); } }
/** What the screen shows while the flag and the first answer are on their way (the same rows the screen then fills). */
const loadingHtml = () => `${switchHtml('work')}<div class="wk"><div class="wk-sec"><h2>Needs you</h2><span class="wk-meta" id="wk-needs-meta">Loading…</span></div>
  <div id="wk-queue" class="wk-list" role="list">${'<div class="wk-row wk-skel" role="listitem" aria-label="Loading"><span></span><span></span></div>'.repeat(2)}</div></div>`;

/** The view was shown or hidden by app.js (its showView sets hidden). */
function shown(sec, o) {
  if (!sec.hidden) {
    // app.js marks the tab whose data-view matches; Work lives in the Ledger tab's place
    document.querySelector('.bar a[data-view="ledger"]')?.setAttribute('aria-current', 'page');
    // opened while we thought the flag was off: ask again before sending Jordan back to the Ledger
    if (W.on !== true) {
      css(); if (!sec.firstChild) sec.innerHTML = loadingHtml();
      probe(o, sec).then((r) => {
        if (W.on === true || sec.hidden) return;
        if (r.code === 404) { location.hash = '#/ledger'; return; }
        const q = sec.querySelector('#wk-queue'); const m = sec.querySelector('#wk-needs-meta'); if (m) m.textContent = '';
        if (q) q.innerHTML = `<p class="wk-empty fault" role="listitem">Could not load the Work tab: ${String(r.error).replace(/[<>&]/g, '')}. <button type="button" class="wk-link" data-wk-probe>Try again</button></p>`;
      });
      return;
    }
    load(o, sec).then(() => W.view?.show());
  } else W.view?.hide();
}
