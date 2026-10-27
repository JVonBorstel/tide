// Owns the Work tab's week replay (lane L5, WO-UPG-L5-4): the last 7 days of the event log as one bar per day, a slider to pick a day,
// and that day's snapshot in plain words (what was asked, answered, merged, moved). Play steps through the week.
// Called by view.js. The events come from GET /api/work/events?days=7 and then the live stream. Reduced motion: no Play, no movement;
// each day is a still snapshot.
import { esc, reduced, store } from './util.js';

const DAYS = 7;
const KIND_WORDS = {
  'wo.created': (e) => `${e.wo} started${e.data?.goal ? `: ${e.data.goal}` : ''}`,
  'stage.entered': (e) => `${e.wo} moved to ${e.data?.stage || 'a new stage'}`,
  'step.failed': (e) => `${e.wo}: ${e.data?.step || 'a step'} failed${e.data?.retry ? ', retrying' : ''}`,
  'pr.opened': (e) => `${e.wo} opened ${e.data?.pr || 'a PR'}`,
  'pr.updated': (e) => `${e.data?.pr || e.wo} ${e.data?.why === 'closed' ? 'was closed' : `moved to ${String(e.data?.head || '').slice(0, 7)}`}`,
  'ci.result': (e) => `CI ${e.data?.conclusion || ''} on ${e.data?.pr || e.wo}`,
  'review.verdict': (e) => `Review of ${e.wo}: ${e.data?.verdict || ''}`,
  'decision.asked': (e) => `Card ${e.data?.decision?.id || ''} asked: ${e.data?.decision?.ask || ''}`,
  'decision.answered': (e) => `You answered ${e.data?.decision || ''}: ${e.data?.answer || ''}`,
  'flag.set': (e) => `Flag ${e.data?.flag || ''} turned ${e.data?.on ? 'on' : 'off'}`,
  merged: (e) => `${e.wo} merged${e.data?.pr ? ` (${e.data.pr})` : ''}`,
  'docs.done': (e) => `${e.wo}: docs done`, closed: (e) => `${e.wo} closed`, dropped: (e) => `${e.wo} dropped`, replaced: (e) => `${e.wo} replaced by ${e.data?.by || ''}`,
};
const words = (e) => (KIND_WORDS[e.kind] || ((x) => `${x.wo || ''} ${x.kind}`))(e);
const midnight = (d) => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; };

/** @param {HTMLElement} root @param {any} ctx */
export function makeReplay(root, ctx) {
  const R = { events: [], loaded: false, loading: false, day: DAYS - 1, playing: 0, shown: false, err: '' };
  root.innerHTML = `<div class="wk-week">
    <div class="wk-bars" aria-hidden="true">${Array.from({ length: DAYS }, () => '<span class="wk-bar"><i></i></span>').join('')}</div>
    <input type="range" class="wk-range" id="wk-range" min="0" max="${DAYS - 1}" step="1" value="${DAYS - 1}" aria-label="Day to replay">
    <div class="wk-days" aria-hidden="true">${Array.from({ length: DAYS }, () => '<span></span>').join('')}</div>
    <div class="wk-week-acts"><button type="button" class="wk-btn wk-play" id="wk-play" aria-pressed="false">Play the week</button></div>
    <div class="wk-snap" id="wk-snap" aria-live="polite"></div></div>`;
  const range = root.querySelector('#wk-range'); const play = root.querySelector('#wk-play'); const snap = root.querySelector('#wk-snap');
  range.addEventListener('input', () => { stop(); R.day = Number(range.value); paint(); });
  play.addEventListener('click', () => (R.playing ? stop() : start()));

  function days() {
    const end = midnight(new Date()); const out = [];
    for (let i = DAYS - 1; i >= 0; i--) { const s = new Date(end); s.setDate(s.getDate() - i); const e = new Date(s); e.setDate(e.getDate() + 1); out.push({ s, e, list: [] }); }
    for (const ev of R.events) { const t = new Date(ev.at); const d = out.find((x) => t >= x.s && t < x.e); if (d) d.list.push(ev); }
    return out;
  }
  function paint() {
    const ds = days(); const max = Math.max(1, ...ds.map((d) => d.list.length));
    play.hidden = reduced();
    root.querySelectorAll('.wk-bar').forEach((b, i) => { b.firstChild.style.setProperty('--h', String(ds[i].list.length / max)); b.classList.toggle('on', i === R.day); });
    root.querySelectorAll('.wk-days span').forEach((s, i) => { s.textContent = i === DAYS - 1 ? 'Today' : ds[i].s.toLocaleDateString([], { weekday: 'short' }); s.classList.toggle('on', i === R.day); });
    const d = ds[R.day]; const label = R.day === DAYS - 1 ? 'Today' : d.s.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'short' });
    range.value = String(R.day); range.setAttribute('aria-valuetext', `${label}: ${d.list.length} event${d.list.length === 1 ? '' : 's'}`);
    const count = (k) => d.list.filter((e) => e.kind === k).length;
    const parts = [[count('decision.asked'), 'card', 'cards', 'asked'], [count('decision.answered'), 'tap', 'taps'], [count('merged'), 'merge', 'merges'], [count('stage.entered'), 'stage move', 'stage moves'], [count('step.failed'), 'failed step', 'failed steps']]
      .filter(([n]) => n).map(([n, one, many, verb]) => `${n} ${n === 1 ? one : many}${verb ? ` ${verb}` : ''}`);
    const ctxEl = ctx.$('wk-week-meta'); if (ctxEl) ctxEl.textContent = R.loaded ? `${R.events.length} events in 7 days` : R.err ? '' : 'Loading…';
    const html = R.err && !R.loaded ? `<p class="wk-empty fault">Could not load the week: ${esc(R.err)}</p>`
      : `<p class="wk-snap-h"><b>${esc(label)}</b>${parts.length ? ` · ${esc(parts.join(', '))}` : ' · nothing happened'}</p>
        ${d.list.length ? `<ol class="wk-ev">${d.list.slice(-20).reverse().map((e) => `<li><time class="mono" datetime="${esc(e.at)}">${esc(new Date(e.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }))}</time> ${esc(words(e))}</li>`).join('')}</ol>${d.list.length > 20 ? `<p class="wk-meta">and ${d.list.length - 20} earlier</p>` : ''}` : ''}`;
    if (snap.innerHTML === html) return;
    if (reduced() || !R.shown) { snap.innerHTML = html; return; }
    snap.classList.add('swap'); requestAnimationFrame(() => { snap.innerHTML = html; requestAnimationFrame(() => snap.classList.remove('swap')); });
  }
  function start() { if (reduced()) return; R.day = 0; paint(); play.setAttribute('aria-pressed', 'true'); play.textContent = 'Stop'; R.playing = setInterval(() => { if (R.day >= DAYS - 1) return stop(); R.day++; paint(); }, 1100); }
  function stop() { if (!R.playing) return; clearInterval(R.playing); R.playing = 0; play.setAttribute('aria-pressed', 'false'); play.textContent = 'Play the week'; }

  return {
    async load() {
      if (R.loading) return; R.loading = true;
      try {
        const r = await fetch(`/api/work/events?days=${DAYS}`, { cache: 'no-store', headers: { Accept: 'application/json' } });
        const j = await r.json().catch(() => null);
        if (!j?.ok) throw new Error(j?.error || `Tide answered ${r.status}`);
        R.events = j.events; R.loaded = true; R.err = ''; store.set('week', { at: j.at, n: j.events.length });
      } catch (e) { R.err = String(e?.message || e); }
      R.loading = false; paint(); R.shown = true;
    },
    add(e) { if (!R.loaded || R.events.some((x) => x.seq === e.seq)) return; R.events.push(e); if (R.day === DAYS - 1) paint(); },
    visible(on) { if (!on) stop(); },
  };
}
