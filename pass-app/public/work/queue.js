// Owns the Needs-you queue on the Work tab (lane L5, WO-UPG-L5-4): one row per card, oldest first (at most 7, as GET /api/work sends
// them), Yes / Hold / No (or A / B / C) plus a note, and the tap itself.
// Called by view.js. A tap is bound to the exact card (its decision id) and, when the card's order has an open PR, to the head sha this
// row shows (If-Match): the server refuses a tap on code that moved after Jordan looked. A tap is never queued: offline or while the
// live line is down the buttons say so and do nothing. One requestId per tap, kept for a retry, so a retry can never answer twice.
import { chooseHtml } from './cards.js';
import { reduced } from './util.js';

const KIND = { merge: 'Merge', look: 'Look', close: 'Close', resume: 'Resume', publish: 'Publish', install: 'Install', question: 'Question', choose: 'Choose' };
const rid = () => (crypto.randomUUID ? crypto.randomUUID() : [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join(''));

/** One card's row (inside a collapsible wrapper, so it can grow in and fold away without a jump). */
function cardHtml(c, ctx) {
  const d = c.decision; const { esc } = ctx; const id = esc(d.id);
  const head = ctx.V.heads.get(d.wo);
  const opts = d.kind === 'choose' && d.variants ? chooseHtml(d, ctx)
    : `<div class="wk-ans n${d.options.length}" role="group" aria-label="Answer card ${id}">${d.options.map((op) => `<button type="button" class="wk-btn${op === d.recommended ? ' primary' : ''}" data-answer="${esc(op)}" aria-describedby="wk-ask-${id}">${esc(op)}${op === d.recommended ? '<span class="sr-only"> (recommended)</span>' : ''}</button>`).join('')}</div>`;
  return `<div class="wk-fold"><div class="wk-card-in">
    <p class="wk-kind">${esc(KIND[d.kind] || d.kind)} · <span class="mono">${id}</span></p>
    <p class="wk-ask" id="wk-ask-${id}">${esc(d.ask)}</p>
    ${d.why ? `<p class="wk-why">${esc(d.why)}</p>` : ''}
    <p class="wk-facts"><span class="mono">${esc(d.wo || '')}</span>${c.stream ? ` · ${esc(c.stream)}` : ''} · ${ctx.age(c.ageH)}<span class="wk-head">${headText(head, esc)}</span></p>
    ${opts}
    <button type="button" class="wk-note-btn" aria-expanded="false" aria-controls="wk-note-${id}">Add a note</button>
    <div class="wk-note" id="wk-note-${id}" hidden><label for="wk-note-t-${id}">Note for ${id} (optional)</label><textarea id="wk-note-t-${id}" maxlength="2000" rows="2"></textarea></div>
    <p class="wk-msg" role="status" aria-live="polite"></p>
  </div></div>`;
}
const headText = (head, esc) => (head && head !== 'none' ? ` · code <span class="mono">${esc(head.slice(0, 7))}</span>` : '');

/**
 * Keep the list in step with the queue: new cards grow in, answered ones fold away, the rest keep their DOM (focus, a half-typed note).
 * @param {HTMLElement} list @param {any[]} queue @param {any} ctx
 */
export function syncQueue(list, queue, ctx) {
  const have = new Map([...list.querySelectorAll(':scope > .wk-card')].map((n) => [n.dataset.card, n]));
  list.querySelectorAll(':scope > .wk-skel, :scope > .wk-empty').forEach((n) => n.remove());
  let prev = null;
  for (const c of queue) {
    let n = have.get(c.decision.id);
    if (!n) {
      n = document.createElement('div'); n.className = 'wk-card'; n.setAttribute('role', 'listitem'); n.dataset.card = c.decision.id; n.dataset.wo = c.decision.wo || '';
      n.setAttribute('aria-labelledby', `wk-ask-${c.decision.id}`); n.innerHTML = cardHtml(c, ctx);
      if (list.children.length && !reduced()) { n.classList.add('enter'); requestAnimationFrame(() => requestAnimationFrame(() => n.classList.remove('enter'))); }
    }
    n._card = c;
    if ((prev ? prev.nextSibling : list.firstChild) !== n) list.insertBefore(n, prev ? prev.nextSibling : list.firstChild);
    have.delete(c.decision.id); prev = n;
  }
  for (const n of have.values()) if (!n.classList.contains('busy')) fold(n);
  if (!queue.length && !list.querySelector('.wk-empty') && !list.querySelector('.wk-card:not(.gone)')) {
    const p = document.createElement('p'); p.className = 'wk-empty'; p.setAttribute('role', 'listitem'); p.textContent = 'Nothing waits on you.'; list.appendChild(p);
  }
}

/** Fold a row away (grid rows 1fr -> 0fr, a fade), then remove it. Reduced motion: a short fade only. @param {HTMLElement} n */
function fold(n) {
  if (n.classList.contains('gone')) return;
  n.classList.add('gone'); n.setAttribute('aria-hidden', 'true'); n.querySelectorAll('button, textarea').forEach((b) => { b.disabled = true; });
  const done = () => n.remove();
  n.addEventListener('transitionend', (e) => { if (e.target === n && e.propertyName !== 'opacity') done(); });
  setTimeout(done, reduced() ? 160 : 420);
}

/** Learn the PR head each card's order is at (the ETag of GET /api/work/:id), so the row can show it and the tap can name it. */
export async function prefetchHeads(ctx) {
  const wos = [...new Set((ctx.V.data?.queue || []).map((c) => c.decision.wo).filter(Boolean))];
  await Promise.all(wos.map((wo) => headOf(wo, ctx)));
}
async function headOf(wo, ctx) {
  try {
    const r = await fetch(`/api/work/${encodeURIComponent(wo)}`, { cache: 'no-store', headers: { Accept: 'application/json' } });
    const tag = (r.headers.get('ETag') || '').replace(/^W\//, '').replace(/"/g, '');
    if (r.ok && /^([0-9a-f]{7,40}|none)$/.test(tag)) {
      ctx.V.heads.set(wo, tag);
      document.querySelectorAll(`#wk-queue .wk-card[data-wo="${CSS.escape(wo)}"] .wk-head`).forEach((el) => { el.innerHTML = headText(tag, ctx.esc); });
      return tag;
    }
  } catch { }
  return null;
}

/** @param {HTMLElement} list @param {any} ctx */
export function wireQueue(list, ctx) {
  ctx.gone = (id) => { const n = list.querySelector(`.wk-card[data-card="${CSS.escape(id)}"]`); if (n && !n.classList.contains('busy')) fold(n); };
  ctx.tapCard = (id, answer) => { const b = list.querySelector(`.wk-card[data-card="${CSS.escape(id)}"] [data-answer="${CSS.escape(answer)}"]`); if (b) b.click(); return !!b; };
  list.addEventListener('click', (e) => {
    const t = /** @type {HTMLElement} */ (e.target);
    const nb = t.closest('.wk-note-btn');
    if (nb) { const box = list.querySelector('#' + nb.getAttribute('aria-controls')); const open = box.hidden; box.hidden = !open; nb.setAttribute('aria-expanded', String(open)); nb.textContent = open ? 'Hide the note' : 'Add a note'; if (open) box.querySelector('textarea')?.focus(); return; }
    const b = t.closest('[data-answer]'); if (b) tap(b.closest('.wk-card'), b, ctx);
  });
}

/** @param {HTMLElement} row @param {HTMLElement} btn @param {any} ctx */
async function tap(row, btn, ctx) {
  if (!row || row.classList.contains('busy') || row.classList.contains('gone')) return;
  const c = row._card; const d = c.decision; const msg = row.querySelector('.wk-msg'); const answer = btn.dataset.answer;
  const tell = (text, bad = false) => { msg.textContent = text; msg.classList.toggle('fault', bad); };
  if (!ctx.canTap()) return tell('Not sent: taps need a live connection, and nothing is queued. Tap again when the line is back.', true);
  let head = ctx.V.heads.get(d.wo);
  if (!head) { head = await headOf(d.wo, ctx); if (!head) return tell('Could not check which code this card is about. Tap again.', true); return tell('This card now shows the code it is about: look, then tap again.'); }
  row.classList.add('busy'); row.setAttribute('aria-busy', 'true'); btn.setAttribute('aria-pressed', 'true');
  row.querySelectorAll('button[data-answer]').forEach((x) => { x.disabled = true; });
  tell(`Sending ${answer}…`);
  const key = `${d.id}|${answer}`; row._rid ||= {}; row._rid[key] ||= rid();
  let r = null, j = null;
  try {
    r = await fetch('/api/decide', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json', 'If-Match': `"${head}"` },
      body: JSON.stringify({ decision: d.id, answer, note: row.querySelector('textarea')?.value.trim() || null, via: 'board', requestId: row._rid[key] }) });
    j = await r.json().catch(() => null);
  } catch { }
  const undo = () => { row.classList.remove('busy'); row.removeAttribute('aria-busy'); btn.removeAttribute('aria-pressed'); row.querySelectorAll('button[data-answer]').forEach((x) => { x.disabled = false; }); };
  if (r && r.ok && j?.ok) {
    ctx.buzz(12); ctx.say(`${answer} recorded for ${d.id}.`); tell(`${answer}: recorded.`);
    const q = ctx.V.data.queue; const i = q.findIndex((x) => x.decision.id === d.id); if (i >= 0) { q.splice(i, 1); ctx.V.data.queueTotal = Math.max(0, ctx.V.data.queueTotal - 1); }
    row.classList.remove('busy'); fold(row); ctx.refresh(); return;
  }
  undo();
  if (!r) return tell('Not recorded: the Board could not be reached. Nothing was queued; tap again (it is safe: one tap counts once).', true);
  if (r.status === 409) { tell('Already answered.'); fold(row); ctx.refresh(); return; }
  if (r.status === 412 || r.status === 428) { ctx.V.heads.delete(d.wo); await headOf(d.wo, ctx); return tell(`${j?.error || 'The code moved after you looked.'} The row now shows the new code.`, true); }
  tell(j?.error || `Not recorded: the Board answered ${r.status}.`, true);
}
