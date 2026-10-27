// Owns two kinds of card on the Work tab (lane L5, WO-UPG-L5-4): the A/B/C "choose" card (one tile per mock-up variant, the
// recommended one marked) and the morning card (what landed overnight, what waits, one recommendation; at most 3 taps).
// Called by queue.js (choose tiles) and view.js (the morning card). The morning card's recommended tap goes through the same tap as the
// card's own row (queue.js), so it is bound to the card and its PR head in exactly the same way.
import { store, today } from './util.js';

/** The tiles of a choose card: option letter, the variant's title, "recommended" in words (never colour alone). */
export function chooseHtml(d, ctx) {
  const { esc } = ctx; const id = esc(d.id);
  const byOpt = new Map((d.variants || []).map((v) => [v.option, v]));
  return `<div class="wk-abc n${d.options.length}" role="group" aria-label="Choose for card ${id}">${d.options.map((op) => {
    const v = byOpt.get(op); const rec = op === d.recommended;
    return `<button type="button" class="wk-tile${rec ? ' rec' : ''}" data-answer="${esc(op)}" aria-describedby="wk-ask-${id}">
      <span class="wk-tile-op">${esc(op)}</span><span class="wk-tile-t">${esc(v?.title || op)}</span>${rec ? '<span class="wk-tile-rec">Recommended</span>' : ''}</button>`;
  }).join('')}</div>`;
}

/** Morning (4:00-11:59 on this phone) until "Later" is tapped for today. */
export function morningHtml(ctx) {
  const h = new Date().getHours(); const V = ctx.V; const { esc } = ctx;
  if (h < 4 || h >= 12 || store.get('morning', '') === today() || !V.data) return '';
  const landed = V.rows.filter((r) => r.state === 'shipped' && r.stageAgeH <= 16);
  const n = V.data.queueTotal; const first = V.data.queue[0]?.decision;
  const landedText = landed.length ? `${landed.length} landed overnight (${landed.slice(0, 3).map((r) => esc(r.id)).join(', ')}${landed.length > 3 ? ' and more' : ''}).` : 'Nothing landed overnight.';
  const waitText = n ? `${n} card${n > 1 ? 's' : ''} wait${n > 1 ? '' : 's'} on you.` : 'Nothing waits on you.';
  return `<section class="wk-morning" aria-labelledby="wk-morning-h">
    <p class="wk-kind" id="wk-morning-h">Good morning</p>
    <p class="wk-ask">${landedText} ${waitText}</p>
    ${first ? `<p class="wk-why">Recommended: ${esc(first.recommended)} on <span class="mono">${esc(first.id)}</span>, ${esc(first.ask)}${first.why ? ` ${esc(first.why)}` : ''}</p>` : ''}
    <div class="wk-ans n${first ? 3 : 1}" role="group" aria-label="Morning card">
      ${first ? `<button type="button" class="wk-btn primary" data-m-rec="${esc(first.id)}" data-m-answer="${esc(first.recommended)}">${esc(first.recommended)} on ${esc(first.id)}</button>
      <button type="button" class="wk-btn" data-m-see>See cards</button>` : ''}
      <button type="button" class="wk-btn" data-m-later>Later</button>
    </div></section>`;
}

/** @param {HTMLElement} el @param {any} ctx */
export function wireMorning(el, ctx) {
  const close = () => { store.set('morning', today()); el.querySelector('.wk-morning')?.classList.add('gone'); setTimeout(() => { el.innerHTML = ''; }, ctx.reduced() ? 120 : 320); };
  el.addEventListener('click', (e) => {
    const t = /** @type {HTMLElement} */ (e.target);
    if (t.closest('[data-m-later]')) return close();
    if (t.closest('[data-m-see]')) { const hd = document.getElementById('wk-h-needs'); hd?.scrollIntoView({ block: 'start', behavior: ctx.reduced() ? 'auto' : 'smooth' }); hd?.focus({ preventScroll: true }); return close(); }
    const rec = t.closest('[data-m-rec]');
    if (rec) { if (ctx.tapCard?.(rec.dataset.mRec, rec.dataset.mAnswer)) close(); }
  });
}
