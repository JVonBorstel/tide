// Owns the Work tab's screen (lane L5, WO-UPG-L5-4, look A "inline list"): loads GET /api/work, keeps it live through the SSE stream
// /api/work/stream, and lays out the morning card, the Needs-you queue, the streams, the work orders and the week's replay.
// Called by work.js once the board.work flag is on. Everything shown comes from the Work API (the ledger's event store); nothing is
// made up here. Offline it shows the last snapshot it saw, says so, and refuses taps (a tap must be live and confirmed).
import { syncQueue, wireQueue, prefetchHeads } from './queue.js';
import { morningHtml, wireMorning } from './cards.js';
import { makeReplay } from './replay.js';
import { esc, store, reduced, age, say } from './util.js';
const clock = (iso) => { const d = new Date(iso); return Number.isNaN(d.getTime()) ? '' : d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };

// a row's state: a shape and a word, never colour alone (DESIGN.md)
const STATE = { 'waiting-on-jordan': ['◆', 'Needs you'], moving: ['●', ''], stale: ['◌', 'Stale'], stuck: ['✕', 'Stuck'], lost: ['⊘', 'Lost'], shipped: ['✓', 'Handed over'], dropped: ['–', 'Dropped'], replaced: ['↷', 'Replaced'] };
const STAGE = { build: 'Building', review: 'In review', ci: 'Checks running', 'merge-ready': 'Ready to merge', jordan: 'Waiting on you', merged: 'Merged', docs: 'Docs', closed: 'Closed' };

/** @param {HTMLElement} sec @param {{ switchHtml: (cur: string) => string, buzz?: Function }} o */
export function makeView(sec, o) {
  const V = { data: null, rows: [], page: 1, pages: 1, total: 0, err: '', loading: true, offline: false, es: null, live: 'off', heads: new Map(), visible: false, timer: 0, sig: {} };
  sec.innerHTML = shellHtml(o.switchHtml('work'));
  const $ = (id) => sec.querySelector('#' + id);
  const ctx = { V, $, esc, say, store, age, reduced, buzz: o.buzz || (() => { }), refresh: () => soon(), canTap };
  const replay = makeReplay($('wk-replay'), ctx);
  wireQueue($('wk-queue'), ctx);
  wireMorning($('wk-morning'), ctx);
  $('wk-more').addEventListener('click', () => load(V.page + 1));
  sec.addEventListener('click', (e) => { if (e.target.closest('[data-wk-retry]')) load(1); });

  /** A tap needs a live, confirmed connection; never queued. */
  function canTap() { return navigator.onLine && V.live === 'live' && !V.offline; }

  async function load(page = 1) {
    try {
      const r = await fetch(`/api/work?page=${page}`, { cache: 'no-store', headers: { Accept: 'application/json' } });
      if (r.status === 404) { location.hash = '#/ledger'; return; }   // the flag went off
      const j = await r.json().catch(() => null);
      if (!j || !j.ok) throw new Error(j?.error || `Tide answered ${r.status}`);
      if (page === 1) { const extra = V.rows.slice(j.rows.length).filter((x) => !j.rows.some((y) => y.id === x.id)); V.data = j; V.rows = V.page > 1 ? j.rows.concat(extra) : j.rows; store.set('snap', j); }
      else V.rows = V.rows.concat(j.rows.filter((x) => !V.rows.some((y) => y.id === x.id)));
      if (page > 1) V.page = page; V.pages = Number(r.headers.get('X-Rows-Pages')) || 1; V.total = Number(r.headers.get('X-Rows-Total')) || V.rows.length;
      V.err = ''; V.loading = false; V.offline = false;
      render(); prefetchHeads(ctx);
    } catch (e) {
      V.loading = false; V.err = String(e?.message || e);
      if (!V.data) { const snap = store.get('snap', null); if (snap?.ok) { V.data = snap; V.rows = snap.rows || []; V.offline = true; } }
      render();
    }
  }
  function soon() { clearTimeout(V.timer); V.timer = setTimeout(() => load(1), 250); }

  function connect() {
    if (V.es || !V.visible || document.visibilityState !== 'visible') return;
    const es = new EventSource('/api/work/stream'); V.es = es; setLive('connecting');
    const on = (t, f) => es.addEventListener(t, (m) => { let d = null; try { d = JSON.parse(m.data); } catch { } if (d) f(d); });
    on('hello', (d) => { setLive('live'); if (!d.data.resumed) load(1); });
    on('card', () => soon());
    on('card-gone', (d) => { ctx.gone?.(d.data.decision, d.data.answer); soon(); });
    on('row', (d) => { const i = V.rows.findIndex((r) => r.id === d.data.id); if (i >= 0) { V.rows[i] = d.data; renderRows(V, $); } soon(); });
    on('top', (d) => { if (V.data) { V.data.top = d.data.top; renderTop(); } });
    on('event', (d) => replay.add(d.data));
    es.onerror = () => { if (es.readyState === EventSource.CLOSED) { V.es = null; setLive('off'); setTimeout(connect, 3000); } else setLive('reconnecting'); };
  }
  function disconnect() { V.es?.close(); V.es = null; setLive('off'); }
  function setLive(s) { if (V.live === s) return; V.live = s; renderStatus(); sec.classList.toggle('wk-notap', !canTap()); }
  addEventListener('online', () => { renderStatus(); connect(); load(1); });
  addEventListener('offline', () => { renderStatus(); sec.classList.add('wk-notap'); });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') { if (V.visible) { connect(); load(1); } } else disconnect(); });

  // ---- render (each part only when its data changed) ----
  const changed = (k, v) => { const s = JSON.stringify(v); if (V.sig[k] === s) return false; V.sig[k] = s; return true; };
  const renderStatus = () => status(V, $, sec, canTap());
  function renderTop() { const el = $('wk-top'); const t = V.data?.top || ''; if (el.textContent !== t) el.textContent = t; }
  function render() {
    renderStatus();
    const q = $('wk-queue');
    if (!V.data) {
      if (V.loading) { q.innerHTML = '<div class="wk-row wk-skel" role="listitem" aria-label="Loading"><span></span><span></span></div>'.repeat(2); $('wk-needs-meta').textContent = 'Loading…'; }
      else { q.innerHTML = `<p class="wk-empty fault" role="listitem">Could not load the Work tab: ${esc(V.err)}. <button type="button" class="wk-link" data-wk-retry>Try again</button></p>`; $('wk-needs-meta').textContent = ''; }
      return;
    }
    renderTop();
    const d = V.data;
    if (changed('morning', [d.queue.map((c) => c.decision.id), d.queueTotal, V.rows.filter((r) => r.state === 'shipped').map((r) => r.id).slice(0, 5), new Date().getHours() < 12])) $('wk-morning').innerHTML = morningHtml(ctx);
    syncQueue(q, d.queue, ctx);
    o.badge?.(d.queueTotal);
    $('wk-needs-meta').textContent = d.queueTotal ? `${d.queue.length} of ${d.queueTotal} · oldest first` : '';
    if (changed('streams', [d.streams, d.flags])) renderStreams(d, $);
    renderRows(V, $);
    replay.visible(V.visible);
  }
  return {
    show() { V.visible = true; if (!V.data) { render(); } load(1); connect(); replay.load(); },
    hide() { V.visible = false; disconnect(); replay.visible(false); },
    state: V,
  };
}

/** The streams with their WIP, and the attention flags. @param {any} d @param {(id: string) => HTMLElement} $ */
function renderStreams(d, $) {
  const open = d.streams.filter((s) => !['YARD', 'DEPENDENCIES', 'OTHER'].includes(s.stream)).length;
  $('wk-streams-meta').textContent = `${open} of 4 build streams open`;
  $('wk-streams').innerHTML = d.streams.length ? d.streams.map((s) => {
    const pips = Array.from({ length: Math.max(3, Math.min(8, s.open)) }, (_, i) => `<i class="${i < s.cards ? 'c' : i < s.open ? 'f' : ''}"></i>`).join('');
    return `<div class="wk-row wk-stream" role="listitem"><div class="wk-l1"><span class="mono">${esc(s.stream)}</span><span class="wk-pips" aria-hidden="true">${pips}</span>
      <span class="wk-meta">${s.open} open${s.cards ? ` · ${s.cards} waiting on you` : ''}</span></div>
      <div class="wk-l2">${s.overLimit ? '<span class="wk-over">▲ Over the limit</span> · ' : ''}${esc(STAGE[s.stage] || s.stage || '')}${s.oldestH ? ` · oldest ${age(s.oldestH)}` : ''}${s.blockedOn ? ` · ${esc(s.blockedOn)}` : ''}</div></div>`;
  }).join('') : '<p class="wk-empty" role="listitem">No stream has open work.</p>';
  $('wk-flags').innerHTML = d.flags.length ? `<details class="wk-flags"><summary>${d.flags.length} thing${d.flags.length > 1 ? 's' : ''} to look at (stale, lost, over a limit)</summary><ul>${d.flags.slice(0, 30).map((f) => `<li>${esc(f.detail)}</li>`).join('')}</ul></details>` : '';
}
/** One work order: id, stream, PR, age; its goal; its state as a shape and a word, and what happens next. @param {any} r */
function rowHtml(r) {
  const [sym, word] = STATE[r.state] || ['○', r.state];
  // task 30 (D-11): the goal is the row's title, first; the id is small secondary text under it
  return `<div class="wk-goal">${esc(r.goal)}</div>
    <div class="wk-l1"><span class="mono">${esc(r.id)}</span><span class="wk-meta">${esc(r.stream)}${r.pr ? ` · ${esc(r.pr)}` : ''} · ${age(r.ageH)}</span></div>
    <div class="wk-l2"><span class="wk-sym" aria-hidden="true">${sym}</span><span class="${r.state === 'stuck' || r.state === 'lost' ? 'fault' : r.state === 'waiting-on-jordan' ? 'ember' : ''}">${esc(word || STAGE[r.stage] || r.stage)}</span>${r.next ? ` <span class="wk-meta">· ${esc(r.next)}</span>` : ''}</div>`;
}
/** Keyed: a row is redrawn only when its events moved; order is needs-you first, then newest (as the API sends it). @param {any} V @param {(id: string) => HTMLElement} $ */
function renderRows(V, $) {
  const list = $('wk-rows'); const have = new Map([...list.children].map((n) => [n.dataset.id, n]));
  let prev = null;
  for (const r of V.rows) {
    let n = have.get(r.id); const sig = `${r.lastSeq}|${r.state}|${Math.round(r.ageH)}`;
    if (!n) { n = document.createElement('div'); n.className = 'wk-row'; n.setAttribute('role', 'listitem'); n.dataset.id = r.id; }
    if (n.dataset.sig !== sig) { n.innerHTML = rowHtml(r); n.dataset.sig = sig; }
    if ((prev ? prev.nextSibling : list.firstChild) !== n) list.insertBefore(n, prev ? prev.nextSibling : list.firstChild);
    have.delete(r.id); prev = n;
  }
  for (const n of have.values()) n.remove();
  if (!V.rows.length && !list.querySelector('.wk-empty')) list.innerHTML = '<p class="wk-empty" role="listitem">No work orders in the ledger yet.</p>';
  $('wk-rows-meta').textContent = V.total ? `${Math.min(V.rows.length, V.total)} of ${V.total} · needs you first, then newest` : '';
  $('wk-more').hidden = V.rows.length >= V.total;
}

/** The screen's fixed parts (look A): status, top line, morning card, Needs you, Streams, Work orders, This week. @param {string} sw */
const shellHtml = (sw) => `${sw}
<div class="wk">
  <div class="wk-status" id="wk-status" role="status"></div>
  <p class="wk-top" id="wk-top"></p>
  <div id="wk-morning"></div>
  <section aria-labelledby="wk-h-needs"><div class="wk-sec"><h2 id="wk-h-needs" tabindex="-1">Needs you</h2><span class="wk-meta" id="wk-needs-meta"></span></div>
    <div id="wk-queue" class="wk-list" role="list" aria-labelledby="wk-h-needs"></div></section>
  <section aria-labelledby="wk-h-streams"><div class="wk-sec"><h2 id="wk-h-streams">Streams</h2><span class="wk-meta" id="wk-streams-meta"></span></div>
    <div id="wk-streams" class="wk-list" role="list" aria-labelledby="wk-h-streams"></div><div id="wk-flags"></div></section>
  <section aria-labelledby="wk-h-rows"><div class="wk-sec"><h2 id="wk-h-rows">Work orders</h2><span class="wk-meta" id="wk-rows-meta"></span></div>
    <div id="wk-rows" class="wk-list" role="list" aria-labelledby="wk-h-rows"></div><button class="wk-more" id="wk-more" type="button" hidden>Show more</button></section>
  <section aria-labelledby="wk-h-week"><div class="wk-sec"><h2 id="wk-h-week">This week</h2><span class="wk-meta" id="wk-week-meta"></span></div><div id="wk-replay"></div></section>
</div>`;

/** Offline, a failed refresh, or a dropped line: said in words, and taps are greyed while they cannot be sent. @param {any} V @param {(id: string) => HTMLElement} $ @param {HTMLElement} sec @param {boolean} tapOk */
function status(V, $, sec, tapOk) {
  const el = $('wk-status'); let h = '';
  if (V.offline || !navigator.onLine) h = `<p class="wk-line warn">Offline: this is the last snapshot${V.data?.at ? `, from ${esc(clock(V.data.at))}` : ''}. Taps need a live connection.</p>`;
  else if (V.err && V.data) h = `<p class="wk-line warn">Could not refresh: ${esc(V.err)}. <button type="button" class="wk-link" data-wk-retry>Try again</button></p>`;
  else if (V.live === 'reconnecting') h = '<p class="wk-line">Reconnecting… taps wait until the line is back.</p>';
  if (el.innerHTML !== h) el.innerHTML = h;
  sec.classList.toggle('wk-notap', !tapOk);
}
