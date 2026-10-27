// Chef, the phone client. One live stream (Server-Sent Events) feeds everything; every action is a POST the server checks and logs.
// Design: "the pass at 9pm on a good night" (pass-app/DESIGN.md). Views render only when their data changes; clocks tick in place.
// Everything shown that came from the kitchen is escaped. Routes: #/pass #/talk #/talk/T2 #/activity #/cooks #/job/J3
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const icon = (n) => `<svg aria-hidden="true"><use href="#i-${n}"/></svg>`;
// Styles in markup are written data-css="...", never as a style attribute (the CSP has no 'unsafe-inline'): applyCss (scene.js) sets them
// through style.setProperty on every node any renderer adds, before the next paint.
new MutationObserver((ms) => { for (const m of ms) for (const n of m.addedNodes) applyCss(n); }).observe(document.documentElement, { childList: true, subtree: true });
const store = { get(k, d) { try { const v = localStorage.getItem('chef.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('chef.' + k, JSON.stringify(v)); } catch {} } };
const S = { state: null, events: [], recipes: [], view: 'pass', feedFilter: 'all', feedQuery: '', conn: 'connecting', openJob: null, openSig: '',
  log: null, sig: {}, seenNeeds: new Set(), seenCook: new Set(), first: true, showPlated: false, cook: 'auto', unauth: false, lastNeeds: -1,
  talk: { id: null, data: null, sending: null, privateNext: false, unread: 0 } };
// offline hydration: the last board and brief are kept in localStorage (never log tails or activity) so a cold start paints at once
const SNAP = (s) => ({ ...s, recvAt: undefined, jobs: (s.jobs || []).map((j) => ({ ...j, tail: undefined, activity: undefined })) });
const HYDRATE = (raw) => (raw && typeof raw === 'object' && Array.isArray(raw.jobs) && raw.jobs.every((j) => j && typeof j === 'object' && typeof j.id === 'string') ? raw : null);
// a stored brief must have the lists renderBrief reads, or it is dropped (a bad one would blank the page on boot)
const HYDRATE_BRIEF = (raw) => (raw && typeof raw === 'object' && ['needsYou', 'plated', 'setAside', 'followUps'].every((k) => Array.isArray(raw[k])) ? raw : null);
// everything the first paint needs from storage, with no fetch: the board, how old it is, and the brief
const BOOT = (get) => { const state = HYDRATE(get('lastState', null)); return { state, savedAt: Number(get('lastStateAt', 0)) || 0, stale: !!state, brief: HYDRATE_BRIEF(get('lastBrief', null)) }; };
const OFFLINE_TEXT = (at) => { if (!at) return 'Offline · showing the last known board'; const m = Math.floor((Date.now() - at) / 60000); return 'Offline · showing board from ' + (m < 1 ? 'just now' : m < 60 ? m + 'm ago' : m < 1440 ? Math.floor(m / 60) + 'h ago' : Math.floor(m / 1440) + 'd ago'); };
Object.assign(S, BOOT((k, d) => store.get(k, d)));

// ---------- words, numbers, time ----------
// a ticket number is safe in any template or attribute as it is: only letters, digits, '-', '_' and '.' survive (an event or idea
// row written by a cook can't smuggle markup through a job field)
const ticket = (id) => 'WO-' + String(id || '').replace(/^J/, '').replace(/[^\w.-]/g, '').slice(0, 24).padStart(4, '0');
// a work-order number typed or linked as WO-207, WO-0207 or J207 opens the stored job J207 (links stay #/job/J207)
const jobIdOf = (s) => { const m = /^WO-0*(\d{1,6})$/i.exec(String(s || '')); return m ? 'J' + Number(m[1]) : String(s || ''); };
// The one label table (Tide GLOSSARY.md, status table): what each stored job status shows. The stored values never change.
// 'running' shows as Inspection while its step is the tests, verify or the taster review (an agent step with Role check).
// Not used for the job-hunt tracker statuses (STATUS_WORD below). Any other value shows as it is.
const STATUS_LABEL = { pending: 'Queued', running: 'Building', 'running:inspection': 'Inspection', 'waiting-approval': 'Needs sign-off', 'needs-human': 'Needs sign-off', done: 'Handed over', quarantined: 'Failed', failed: 'Failed', killed: 'Stopped', closed: 'Closed out' };
const statusLabel = (j) => { const s = String(j?.status ?? ''); const st = Array.isArray(j?.steps) ? (j.steps[Number(j.step) - 1] || {}) : (j || {}); if (s === 'running' && (['tests', 'verify'].includes(st.station) || (st.station === 'agent' && String(st.role || '').toLowerCase() === 'check'))) return STATUS_LABEL['running:inspection']; return s !== 'running:inspection' && Object.hasOwn(STATUS_LABEL, s) ? STATUS_LABEL[s] : s; };
// the order's pull request on GitHub: a small link on the job sheet, only ever to a github.com pull request page
const prLink = (p) => p && Number.isInteger(p.number) && /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+$/.test(String(p.url || '')) ? `<p class="why-line"><a href="${esc(p.url)}" target="_blank" rel="noopener noreferrer">PR #${p.number}</a></p>` : '';
const jobLink = (id) => /^J\d{1,6}$/.test(String(id || '')) ? `<a href="#/job/${id}">${ticket(id)}</a>` : esc(ticket(id));
const NEEDS = (j) => j.status === 'waiting-approval' || j.status === 'needs-human';
const ASIDE = (j) => ['quarantined', 'killed', 'failed'].includes(j.status);
const OLD_ASIDE = (j) => ASIDE(j) && since(j.updated) > 86400;
const isOldRecipe = (j) => ASIDE(j) && !!j.created && ((Date.now() - new Date(j.created).getTime()) >= 12 * 3600 * 1000) && !!(j.recipe || title(j.name).kind);
const money = (x) => '$' + (Number(x) || 0).toFixed(2);
const fmtTokens = (n) => { n = Number(n) || 0; if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M'; if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k'; return String(Math.round(n)); };
const isToday = (ts) => ts && new Date(ts).toDateString() === new Date().toDateString();
const clock = (ts) => new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const clockS = (ts) => new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
function mmss(sec) { sec = Math.max(0, Math.floor(sec)); const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60; return (h ? h + ':' + String(m).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(s).padStart(2, '0'); }
function ago(ts) { if (!ts) return ''; const s = (Date.now() - new Date(ts)) / 1000; if (s < 60) return 'now'; if (s < 3600) return Math.round(s / 60) + 'm'; if (s < 86400) return Math.round(s / 3600) + 'h'; return Math.round(s / 86400) + 'd'; }
function words(sec) { sec = Math.round(sec); if (sec < 60) return sec + 's'; if (sec < 3600) return Math.round(sec / 60) + ' min'; return (sec / 3600).toFixed(1).replace(/\.0$/, '') + ' h'; }
// "N min", rounded up (30 s reads "1 min"): the words of every back-off line, the same as kitchen/backoff-lib.ps1 Format-WaitMinutes
const minWords = (sec) => Math.max(1, Math.ceil((Number(sec) || 0) / 60)) + ' min';
// "waiting 8 min before retry" for a pending order still in its back-off (TD-EH-08); '' when it is not waiting to retry
const retryWaitText = (j) => (j?.retry && j.notBefore && new Date(j.notBefore) > Date.now() ? `waiting ${minWords(-since(j.notBefore))} before retry` : '');
const since = (ts) => (Date.now() - new Date(ts).getTime()) / 1000;
const human = (s) => String(s || '').replace(/[-_]+/g, ' ');
const cap = (s) => { s = String(s || ''); return s.charAt(0).toUpperCase() + s.slice(1); };
const who = (j) => j.station === 'agent' ? (j.cook || j.supplier || 'Dispatcher picks') : human(j.station);
// "improve: split kitchen.ps1" reads as a kind (small label) and a title
function title(name) { const m = /^([a-z][\w-]{1,15}):\s+(.+)$/i.exec(String(name || '')); return m ? { kind: cap(human(m[1]).toLowerCase()), text: cap(m[2]) } : { kind: '', text: cap(name) }; }
const titleHtml = (name) => { const t = title(name); return `${t.kind ? `<span class="kind">${esc(t.kind)}</span>` : ''}${esc(t.text)}`; };
// plain words for an order on a phone: the idea's short title when the server has one (j.label), else the goal's first clause
// without file paths ("kitchen/stations/lint.ps1" reads as "lint"), at most ~60 characters
function plain(text) {
  let s = String(text || '').replace(/\s*\(Idea I\d+:[\s\S]*$/, '').replace(/\.{3}$|…$/, '');
  s = s.replace(/(?:[\w.-]+[\\/])+([\w-]+)\.(?:ps1|psm1|mjs|js|json|md|css|html)\b/g, '$1').replace(/\b([\w-]+)\.(?:ps1|psm1|mjs|json|md)\b/g, '$1');
  s = s.split(/(?<=[a-z0-9)])[.;:]\s|\s\(?\d\)\s/)[0].trim();
  if (s.length > 60) s = s.slice(0, 58).replace(/\s+\S*$/, '') + '…';
  return cap(s);
}
const unslug = (s) => /^[\w]+(-[\w]+)+$/.test(s) ? s.replace(/-/g, ' ') : s;   // "fix-budget-spend-rotation" reads as words
const nameOf = (j) => { const t = title(j?.name); return { kind: t.kind, text: j?.label ? cap(unslug(j.label)) : plain(t.text) }; };
const nameHtml = (j) => { const t = nameOf(j); return `${t.kind ? `<span class="kind">${esc(t.kind)}</span>` : ''}${esc(t.text)}`; };
// an approval text that starts by repeating the job's name says only the new part
function askText(j) {
  const t = String(j.approval?.text || ''); const ask = t.startsWith(j.name + ': ') ? t.slice(j.name.length + 2) : t.replace(/^[^:]{0,80}\.\.\.: /, '');
  if (/start step \d+ of \d+ \(merge\)$/.test(ask)) return 'Add this change to the Tower. It was built on its own copy, all the tests passed and the reviewer signed off. Nothing changes until you approve.';
  const m = /^start step (\d+) of (\d+) \((\w+)\)$/.exec(ask); if (m) return `Run step ${m[1]} of ${m[2]} (${human(m[3])}).`;
  return cap(ask);
}
// "fail: exit 1 broken" -> "Failed: broken (exit 1)"
const FAIL_WORD = { fail: 'Failed', crash: 'Crashed', timeout: 'Ran out of time', taster: 'The Inspector sent it back', memcap: 'Used too much memory', hung: 'Stopped responding', logflood: 'Wrote too much output' };
function reason(last) {
  const m = /^(fail|crash|timeout|taster|memcap|hung|logflood)(?::\s*(.*))?$/s.exec(String(last || '')); if (!m) return cap(last);
  let d = (m[2] || '').trim(); const x = /^exit (-?\d+):?\s*(.*)$/s.exec(d);
  if (x) { const tail = x[2].replace(/^(error|fail(ed)?):\s*/i, '').trim(); d = (tail ? tail + ' ' : '') + `(exit ${x[1]})`; }
  return FAIL_WORD[m[1]] + (d ? ': ' + d : '');
}
const buzz = (ms = 8) => { try { navigator.vibrate?.(ms); } catch {} };
const ord = (n) => n + (n % 10 === 1 && n % 100 !== 11 ? 'st' : n % 10 === 2 && n % 100 !== 12 ? 'nd' : n % 10 === 3 && n % 100 !== 13 ? 'rd' : 'th');

// ---------- server ----------
async function api(path, opts = {}) {
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), opts.timeout || 30000);
  try {
    const r = await fetch(path, { ...opts, signal: ctl.signal, headers: opts.body ? { 'Content-Type': 'application/json' } : undefined });
    if (r.status === 401) { S.unauth = true; renderBanners(); return { ok: false, error: 'this device is not signed in' }; }
    return await r.json().catch(() => ({ ok: false, error: `the server answered ${r.status}` }));
  } catch (e) { return { ok: false, error: e.name === 'AbortError' ? 'the Yard took too long to answer' : "can't reach the Yard" }; }
  finally { clearTimeout(t); }
}
// one tap = one action: while an action is on its way, more taps on it (or the same action anywhere) are ignored
const inflight = new Set();
async function act(body, { btn, ok, timeout = 90000 } = {}) {
  const key = body.op + '|' + (body.id || body.name || body.recipe || '');
  if (inflight.has(key)) return { ok: false, busy: true };
  inflight.add(key); btn?.classList.add('busy'); btn?.setAttribute('aria-busy', 'true');
  const r = await api('/api/action', { method: 'POST', body: JSON.stringify(body), timeout }).finally(() => { inflight.delete(key); btn?.classList.remove('busy'); btn?.removeAttribute('aria-busy'); });
  if (r.ok) { if (ok) toast(ok); } else toast(`Not done: ${r.error || 'unknown error'}`, { bad: true, sticky: true });
  return r;
}
function toast(msg, { bad = false, sticky = false, action = null } = {}) {
  const el = document.createElement('div'); el.className = 'toast' + (bad ? ' bad' : ''); el.setAttribute('role', bad ? 'alert' : 'status');
  el.innerHTML = `<span class="msg">${esc(msg)}</span>${action ? `<button data-a>${esc(action.label)}</button>` : ''}<button data-x aria-label="Dismiss">${icon('x')}</button>`;
  el.querySelector('[data-x]').onclick = () => el.remove();
  if (action) el.querySelector('[data-a]').onclick = () => { el.remove(); action.fn(); };
  $('toasts').append(el); while ($('toasts').children.length > 2) $('toasts').firstChild.remove();
  if (!sticky) setTimeout(() => el.remove(), 4500);
}
function confirmBox({ title, html, yes = 'Yes', danger = false }) {
  return new Promise((resolve) => {
    const d = $('confirm'); $('confirm-title').textContent = title; $('confirm-text').innerHTML = html;
    const y = $('confirm-yes'); y.textContent = yes; y.className = 'btn ' + (danger ? 'danger' : 'primary');
    const done = (v) => { d.close(); resolve(v); };
    y.onclick = () => done(true); $('confirm-no').onclick = () => done(false); d.oncancel = (e) => { e.preventDefault(); done(false); };
    d.showModal(); $('confirm-no').focus();
  });
}

// Approve all: the list shown is exactly what is approved, oldest first, so the merge train lands them in that order.
// Only merge gates whose change is known and touches no protected file (the server checks again): privacy holds, plain step gates
// and guardrail changes each need their own look. Each item carries the approval id shown, so a job that moved on is skipped.
const PROTECTED = (j) => !!(j.change && (j.change.unknown || (j.change.protected || []).length));
const BATCH = (j) => j.status === 'waiting-approval' && !!j.approval && j.approval.kind !== 'hold' && j.approval.gate === 'merge' && !!j.change && !PROTECTED(j);
const changeLine = (j) => j.change ? (j.change.unknown ? 'change not readable' : `${Number(j.change.files) || 0} file${j.change.files === 1 ? '' : 's'}, +${Number(j.change.add) || 0} −${Number(j.change.del) || 0}`) : '';
// pass/fail counts from the TESTS.txt summary lines ("N passed, M failed", or ALL PASS); null when unreadable
const testCounts = (t) => { t = String(t || ''); let pass = 0, fail = 0, seen = false; for (const m of t.matchAll(/(\d+) passed(?:, (\d+) failed)?/gi)) { pass += +m[1]; fail += +m[2] || 0; seen = true; } return seen ? { pass, fail } : /ALL PASS/.test(t) ? { pass: 0, fail: 0, all: true } : null; };
const protectedMark = (j) => `<span class="prot-mark">${icon('lock')}Protected file${j.change?.protected?.length ? ': ' + esc(j.change.protected.slice(0, 3).join(', ')) : ''}</span>`;
// TD-EH-15: a merge gate whose last look at GitHub's checks failed says why (gh down or signed out), so a wait for the Owner's tap has a cause
const ciLookText = (j) => (j.approval?.gate === 'merge' && j.approval?.ciLook ? "Couldn't read GitHub's checks: " + j.approval.ciLook.error : '');
const ciLookMark = (j) => (ciLookText(j) ? `<div class="row-ask ci-look-failed">${esc(ciLookText(j))}</div>` : '');
// Why an ask is not in the safe batch: shown next to it, so "also these" is a choice made with eyes open.
const closerLook = (j) => j.approval?.kind === 'hold' ? 'Hold: ' + (askText(j).split('.')[0] || 'needs your say')
  : j.approval?.gate === 'merge' && PROTECTED(j) ? 'Protected file' + (j.change?.protected?.length ? ': ' + j.change.protected.slice(0, 3).join(', ') : '')
  : 'Step gate: ' + (askText(j).split('.')[0] || 'start the next step');
async function approveAll(btn) {
  const byId = (a, b) => parseInt(a.id.slice(1)) - parseInt(b.id.slice(1));
  const list = (S.state?.jobs || []).filter(BATCH).sort(byId);
  const more = (S.state?.jobs || []).filter((j) => NEEDS(j) && !BATCH(j) && j.approval?.id).sort(byId);
  if (!list.length && !more.length) return;
  const html = `${list.length ? `<ol class="batch-list">${list.map((j) => `<li><b>${ticket(j.id)}</b> ${esc(nameOf(j).text)}<small>${esc(askText(j).split('.')[0])} · ${esc(changeLine(j))}</small></li>`).join('')}</ol>
    <p>Merges go one at a time, oldest first. Each is merged, then checked on main, before the next one starts. A failed check undoes only that one.</p>` : ''}
    ${more.length ? `<p><b>These need a closer look</b> (privacy holds, protected files, step gates):</p><ul class="batch-list held">${more.map((j) => `<li><b>${ticket(j.id)}</b> ${esc(nameOf(j).text)}${j.approval?.gate === 'merge' && PROTECTED(j) ? ' ' + protectedMark(j) : `<small>${esc(closerLook(j))}</small>`}</li>`).join('')}</ul>
    <label class="aa-more"><input type="checkbox" id="aa-more"> Also approve these ${more.length}</label>` : ''}`;
  const n = list.length + more.length;
  if (!await confirmBox({ title: list.length ? `Approve ${list.length} merge${list.length > 1 ? 's' : ''}?` : `Approve ${more.length} ask${more.length > 1 ? 's' : ''}?`, html, yes: 'Approve' })) return;
  const all = !!$('aa-more')?.checked;
  const pick = all ? [...list, ...more].sort(byId) : list;
  if (!pick.length) { toast('Nothing approved: tick "Also approve these" to include them.'); return; }
  buzz();
  const r = await act({ op: 'approve-all', items: pick.map((j) => ({ id: j.id, approval: j.approval.id })).map((it, i) => ({ ...it, diffSha: pick[i].change?.sha || undefined })), everything: all }, { btn, timeout: 240000 });
  if (r.ok) { const a = r.data?.approved || [], sk = r.data?.skipped || []; toast(`${a.length} of ${n} approved.${sk.length ? ` ${sk.length} had moved on or need their own look.` : ''}`); }
}
async function clearAside(btn) {
  const list = (S.state?.jobs || []).filter(OLD_ASIDE);
  if (!list.length) return;
  const html = `<ol class="batch-list">${list.map((j) => `<li><b>${ticket(j.id)}</b> ${esc(nameOf(j).text)}<small>${esc(ago(j.updated))} ago</small></li>`).join('')}</ol><p>They are closed, not deleted. Their history stays.</p>`;
  if (!await confirmBox({ title: `Clear ${list.length} old ${list.length === 1 ? 'work order' : 'work orders'}?`, html, yes: `Clear ${list.length}`, danger: true })) return;
  buzz();
  const ids = list.map((j) => j.id);
  const r = await act({ op: 'clear-aside', ids }, { btn });
  if (r.ok) { const sk = r.data?.skipped || []; toast(`${(r.data?.closed || []).length} cleared.${sk.length ? ` ${sk.length} had moved on.` : ''}`); }
}

// ---------- the actions on a job (every view uses these) ----------
const jobOf = (id) => S.state?.jobs.find((x) => x.id === id) || { id, name: '', step: 1, steps: 1 };
async function doJob(kind, id, btn) {
  const j = jobOf(id);
  if (kind === 'approve') {
    const hold = j.approval?.kind === 'hold' ? '<p>It was held because the work order looks private. Your sign-off lets a Cloud crew take this one step.</p>' : '';
    const asked = j.approval?.id;   // the yes names this exact ask; if the job has moved on since, the server refuses it
    if (!asked) return toast(`${ticket(id)} has nothing to approve right now. Pull to refresh.`, { bad: true });
    const change = j.approval?.gate === 'merge' && j.change ? `<p>${esc(changeLine(j))}${PROTECTED(j) ? ' ' + protectedMark(j) : ''}</p>` : '';
    // inspection gate: a merge gate shows tests, files and whether the diff was opened; the yes carries the diff sha it was shown
    // Phone Diff: the file list comes from git (the same diff the yes is checked against); its sha is the one the yes carries
    let det = null, pd = null;
    if (j.approval?.gate === 'merge') [det, pd] = await Promise.all([api('/api/job/' + id).then((r) => r.data || null), api(`/api/job/${id}/diff`).then((r) => r.ok ? r.data : null)]);
    const sha = pd?.sha || det?.diffSha || null; const dc = det?.change; const tc = testCounts(dc?.tests);
    const nFiles = pd ? pd.files.length : (dc?.files || []).length;
    const check = sha ? `<ul class="inspect"><li class="${tc && !tc.fail ? 'ok' : 'warn'}">Tests: ${tc ? (tc.all ? 'all passed' : `${Number(tc.pass)} passed, ${Number(tc.fail)} failed`) : 'unknown'}</li><li>Files modified: ${pd || dc ? Number(nFiles) : esc(changeLine(j) || 'unknown')}</li><li class="warn" data-diffstate>${pd?.private ? 'Private work order: file names only' : 'Diff not opened'}</li></ul>${pd ? phoneDiffHtml(pd) : '<p class="note">The file list could not be read right now.</p>'}` : '';
    const ask = confirmBox({ title: `Approve ${ticket(id)}?`, html: `<p>${esc(title(j.name).text)}</p><div class="quote">${esc(askText(j) || j.name)}</div>${change}${ciLookText(j) ? `<p>${esc(ciLookText(j))}</p>` : ''}${check}${hold}`, yes: sha && !pd?.private ? 'Approve without reading' : 'Approve' });
    $('confirm-text')._onPd = () => { const st = $('confirm-text').querySelector('[data-diffstate]'); if (!st) return; const n = $('confirm-text').querySelectorAll('.pd-file.read').length; st.textContent = `Diff opened: ${n} of ${Number(nFiles)} file${nFiles === 1 ? '' : 's'} read`; st.className = 'ok'; $('confirm-yes').textContent = 'Approve'; };
    if (!await ask) return;
    buzz(); sceneApproved(); await act({ op: 'approve', id, approval: asked, ...(sha ? { diffSha: sha } : {}) }, { btn, ok: `${ticket(id)} approved. Starting now.` });
  } else if (kind === 'reject' || kind === 'stop') {
    const reject = kind === 'reject';
    if (!await confirmBox({ title: `${reject ? 'Reject' : 'Cancel'} ${ticket(id)}?`, html: `<p>${esc(title(j.name).text)}</p><p>${reject ? "It won't run." : 'The crew stops now, with everything it started.'} You can retry it later.</p>`, yes: reject ? 'Reject' : 'Cancel work order', danger: true })) return;
    await act({ op: 'kill', id }, { btn, ok: `${ticket(id)} ${reject ? 'rejected' : 'cancelled'}` });
  } else if (kind === 'retry') {
    if (isOldRecipe(j)) {
      if (!await confirmBox({ title: `Order ${ticket(id)} again?`, html: `<p>${esc(title(j.name).text)}</p><p>Today's spec will be built again as a new work order and this one closed out.</p>`, yes: 'Order it again' })) return;
      const r = await act({ op: 'requeue', id }, { btn });
      if (r.ok && r.data?.job) toast(`${ticket(r.data.job)} is queued`, { action: { label: 'Open', fn: () => go('#/job/' + r.data.job) } });
      else if (r.ok) toast(`${ticket(id)} is back in the queue`);
    } else {
      if (!await confirmBox({ title: `Retry ${ticket(id)}?`, html: `<p>${esc(title(j.name).text)}</p><p>It goes back in the queue at step ${Number(j.step)} of ${Number(j.steps)}, which runs again from its start.</p>`, yes: 'Retry' })) return;
      await act({ op: 'requeue', id }, { btn, ok: `${ticket(id)} is back in the queue` });
    }
  } else if (kind === 'diagnose') {
    if (!await confirmBox({ title: `Find the fix for ${ticket(id)}?`, html: `<p>A crew reads why it failed (its record, its log and the Yard's code) and explains the fix. It only reads; nothing is changed.${j.private ? '' : ''}</p>`, yes: 'Find the fix' })) return;
    const r = await act({ op: 'diagnose', id }, { btn }); if (r.ok && r.data?.job) toast(`${ticket(r.data.job)} is looking into it`, { action: { label: 'Open', fn: () => go('#/job/' + r.data.job) } });
  } else if (kind === 'undo-merge') {
    if (!await confirmBox({ title: `Undo ${ticket(id)}?`, html: `<p>${esc(title(j.name).text)}</p><p>This adds a change that reverses the merge. Nothing is deleted; you can order it again.</p>`, yes: 'Undo merge', danger: true })) return;
    await act({ op: 'undo-merge', id }, { btn, ok: `Undid ${ticket(id)}` });
  } else if (kind === 'logs') return openLog(id, null);
  else if (kind === 'open') return go('#/job/' + id);
  else if (kind === 'menu') return rowMenu(id);
  if (S.openJob === id) loadJob(id);
}
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-do]'); if (!b) return;
  e.preventDefault(); e.stopPropagation(); closeSwipes(); if ($('row-menu').open && b.dataset.do !== 'menu') closeSheet('row-menu');
  doJob(b.dataset.do, b.dataset.id, b);
});
function rowMenu(id) {
  const j = jobOf(id); $('row-menu-title').textContent = ticket(id);
  const items = [['open', 'Open work order'], ['logs', 'Logs']];
  if (NEEDS(j)) items.unshift(['approve', 'Approve'], ['reject', 'Reject']);
  if (j.status === 'running' || j.status === 'pending') items.push(['stop', 'Cancel work order']);
  if (ASIDE(j)) items.unshift(['retry', retryLabel(j)]);
  $('row-menu-body').innerHTML = `<div class="set-group">${items.map(([k, l]) => `<button class="set-row${['reject', 'stop'].includes(k) ? ' danger' : ''}" data-do="${k}" data-id="${id}"><span>${l}</span></button>`).join('')}</div>`;
  openSheet('row-menu');
}

// ---------- routing ----------
const TITLES = { pass: 'Board', talk: 'Talk', activity: 'Activity', cooks: 'Live', ledger: 'Ledger', world: 'World' };
function go(h) { if (location.hash === h) route(); else location.hash = h; }
function route() {
  const [a, b0] = location.hash.replace(/^#\/?/, '').split('/'); const b = a === 'job' ? jobIdOf(b0) : b0;
  if (a === 'job' && /^J\d+$/.test(b || '')) { for (const d of ['hunt-sheet', 'ideas-sheet', 'clients-sheet', 'chats-sheet', 'menu-sheet', 'cook-sheet', 'agent-sheet']) if ($(d).open) closeSheet(d, false); openJob(b); return; }
  if (a === 'talk') openTalk(/^T\d+$/.test(b || '') ? b : (b === 'new' ? null : S.talk.id ?? store.get('talkLast', null)));
  if ($('job-sheet').open) closeSheet('job-sheet', false);
  setView(TITLES[a] ? a : 'pass');
  // #/pass/needs (the home-screen shortcut): straight to what needs Jordan, once the board is there
  if ((a || 'pass') === 'pass' && b === 'needs') { const to = () => $('sec-needs')?.scrollIntoView({ block: 'start' }); to(); setTimeout(to, 600); }
}
function setView(v) {
  // a soft cross-fade between tabs where the browser can do it (and motion is welcome)
  if (S.view !== v && document.startViewTransition && !S.first && !matchMedia('(prefers-reduced-motion: reduce)').matches) { document.startViewTransition(() => showView(v)); return; }
  showView(v);
}
function showView(v) {
  const changedView = S.view !== v; S.view = v; $('screen-title').textContent = TITLES[v];
  for (const k of Object.keys(TITLES)) $('view-' + k).hidden = k !== v;
  document.querySelectorAll('.bar a').forEach((a) => a.dataset.view === v ? a.setAttribute('aria-current', 'page') : a.removeAttribute('aria-current'));
  if (changedView) { S.sig = {}; window.scrollTo({ top: 0 }); }
  renderAll();
}
// pull down at the top of a list to refresh: reconnects the live feed, or loads the new version if one is waiting
(function pullToRefresh() {
  let y0 = null, pulled = 0; const ptr = $('ptr'), txt = $('ptr-text'), LIMIT = 72;
  addEventListener('touchstart', (e) => { y0 = scrollY <= 0 && !document.querySelector('dialog[open]') && e.touches.length === 1 ? e.touches[0].clientY : null; pulled = 0; }, { passive: true });
  addEventListener('touchmove', (e) => {
    if (y0 == null) return; pulled = Math.max(0, e.touches[0].clientY - y0);
    if (pulled < 8) { ptr.classList.remove('show'); return; }
    ptr.classList.add('show'); ptr.style.setProperty('--pull', Math.min(pulled, LIMIT * 1.4) + 'px');
    const ready = pulled > LIMIT; ptr.classList.toggle('ready', ready); txt.textContent = ready ? 'Release to refresh' : 'Pull to refresh';
  }, { passive: true });
  addEventListener('touchend', async () => {
    if (y0 == null) return; const go_ = pulled > LIMIT; y0 = null; ptr.style.removeProperty('--pull');
    if (!go_) { ptr.classList.remove('show', 'ready'); return; }
    buzz(); txt.textContent = 'Refreshing…'; ptr.classList.add('busy');
    if (S.updateReady) return applyUpdate();
    reconnect(); S.sig = {}; const r = await api('/api/events?n=400');
    if (r.ok) { const have = new Set(S.events.map(lobeEventKey)); S.events = [...r.data.filter((e) => !have.has(lobeEventKey(e))), ...S.events].sort((a, b) => String(a.ts).localeCompare(String(b.ts))); }
    renderAll(); setTimeout(() => ptr.classList.remove('show', 'ready', 'busy'), 350);
  });
})();
window.addEventListener('hashchange', route);

// ---------- the pass (job board) ----------
function row(j, kind) {
  const meta = [siteChip(j) + withFloor(`<span class="mono">${ticket(j.id)}</span>`, j), stuckChip(j)];
  let glyph = 'g-queue', side = '', extra = '', swipe = '', cls = 'row';
  if (kind === 'need') {
    glyph = 'g-need'; meta.push(esc(who(j)), `waiting <span data-ago="${esc(j.updated || '')}">${ago(j.updated)}</span>`);
    extra = `${j.approval?.text ? `<div class="row-ask">${esc(askText(j))}</div>` : ''}${j.approval?.gate === 'merge' && PROTECTED(j) ? `<div class="row-ask">${protectedMark(j)}</div>` : ''}${ciLookMark(j)}<div class="row-buttons"><button class="btn primary" data-do="approve" data-id="${j.id}">Approve</button><button class="btn" data-do="reject" data-id="${j.id}">Reject</button></div>`;
  } else if (kind === 'cook') {
    return cookCard(j);
  } else if (kind === 'rail') {
    cls += ' compact'; meta.push(esc(who(j)));
    const wait = j.notBefore && new Date(j.notBefore) > Date.now(); const rw = retryWaitText(j);
    side = `<span class="pos">${wait ? 'in ' + words(-since(j.notBefore)) : ord(j.pos) + ' up'}</span>`;
    if (rw) extra = `<div class="row-reason">${esc(cap(rw))}${j.last ? ' · ' + esc(reason(j.last)) : ''}</div>`;
    swipe = `<button class="swipe-act danger" data-do="stop" data-id="${j.id}" tabindex="-1">Cancel</button>`;
  } else if (kind === 'aside') {
    glyph = 'g-fail'; meta.push(esc(statusLabel(j).toLowerCase()), ago(j.updated));
    extra = j.last ? `<div class="row-reason">${esc(reason(j.last))}</div>` : '';
    swipe = `<button class="swipe-act" data-do="retry" data-id="${j.id}" tabindex="-1">Retry</button>`;
  } else { glyph = 'g-done'; cls += ' compact'; meta.push(esc(who(j)), j.cost ? money(j.cost) : '', ago(j.updated)); }
  const more = kind !== 'need' && kind !== 'done' ? `<button class="icon-btn row-more" data-do="menu" data-id="${j.id}" aria-label="Actions for ${ticket(j.id)}">${icon('more')}</button>` : '';
  return `<li class="${cls}" data-row="${j.id}" ${swipe ? 'data-swipe' : ''}>${swipe}<div class="row-inner">
    <a class="row-link" href="#/job/${j.id}" aria-label="${esc(ticket(j.id) + ', ' + nameOf(j).text)}"></a>
    <span class="glyph ${glyph}" aria-hidden="true"></span>
    <div class="row-main"><div class="row-title">${nameHtml(j)}</div><div class="row-meta">${meta.filter(Boolean).join(' · ')}</div>${extra}</div>
    <div class="row-side">${side}${more}</div></div></li>`;
}
// an order on the stove, as a live card: the cook's badge (pulsing in its colour), a strip with one segment per step (the current
// one shimmering), the step in kitchen words, what the cook is doing right now, and how much of the step's time limit is used.
// A card slides in only the first time its order shows up, never on a refresh (renderPass adds the enter class to a new card).
// stable: the card without its ticking parts (the clock and the time bar, which the 1 s ticker moves in place), as its row signature
function cookCard(j, stable = false) {
  const c = cookOf(j), cookName = c === 'hand' ? 'yard hand' : c === 'sous' ? 'Dispatcher' : c;
  const n = Math.max(1, j.steps || 1), at = Math.min(n, j.step || 1);
  const strip = Array.from({ length: n }, (_, i) => `<i class="${i < at - 1 ? 'done' : i === at - 1 ? 'now' : ''}"></i>`).join('');
  const act = activityWord(j);
  const pct = j.limit && !stable ? Math.min(100, since(j.since) / j.limit * 100) : 0;
  return `<li class="row cook-card" data-row="${j.id}" data-swipe data-css="--cook:${COOK_COLORS[c]}"><button class="swipe-act danger" data-do="stop" data-id="${j.id}" tabindex="-1">Cancel</button><div class="row-inner">
    <a class="row-link" href="#/job/${j.id}" aria-label="${esc(`${ticket(j.id)}, ${nameOf(j).text}, step ${at} of ${n}, ${cookName}`)}"></a>
    <span class="cook-badge" aria-hidden="true"><b>${esc(cookName.charAt(0).toUpperCase())}</b></span>
    <div class="row-main"><div class="row-title">${nameHtml(j)}</div>
      <div class="cook-step"><span class="strip" aria-hidden="true">${strip}</span><span class="step-word">Step ${at} of ${n} · ${esc(stepWord(j))}</span></div>
      <div class="cook-now">${act ? `<span class="dots" aria-hidden="true"><i></i><i></i><i></i></span><span>${esc(act)}</span>` : `<span class="faint">${esc(cap(cookName))} is on it</span>`}</div>
      ${j.limit ? `<div class="hair${pct > 75 ? ' warn' : ''}" aria-hidden="true"><i data-pct="${esc(j.since)}" data-limit="${Number(j.limit)}" data-css="width:${pct}%"></i></div>` : ''}</div>
    <div class="row-side cook-side">${siteChip(j)}<span class="mono ticket-no">${ticket(j.id)}</span><span class="clock" aria-hidden="true" data-since="${esc(j.since || '')}">${stable ? '' : mmss(since(j.since))}</span><span class="cook-name">${esc(cookName)}</span>
      <button class="icon-btn row-more" data-do="menu" data-id="${j.id}" aria-label="Actions for ${ticket(j.id)}">${icon('more')}</button></div></div></li>`;
}
// The board is keyed (public/rows.js): each block (the stuck alarm, a section, the quiet card) and each row inside a section is kept
// between renders and made again only when its own markup changed, so one job's change touches one row. Long lists (On the rail, Set
// aside, and Plated after "Show all") show their first 20 rows and 50 more each time the "showing N of M" line scrolls into view.
S.win = { rail: WINDOW_FIRST, aside: WINDOW_FIRST, plated: WINDOW_FIRST };
S.siteFilter = store.get('siteFilter', 'all');   // TD-4: the Site filter, remembered on this phone
const newest = (a, b) => (String(a.updated) < String(b.updated) ? 1 : String(a.updated) > String(b.updated) ? -1 : 0);   // ISO times: plain order (localeCompare cost ms at 10x)
const secShell = (id, title, hot) => `<section class="sec${hot ? ' hot' : ''}" id="sec-${id}" aria-labelledby="h-${id}"><h2 class="sec-head" id="h-${id}"><span>${title}<span class="n"></span></span></h2><ul class="rows"></ul><p class="empty-line" hidden></p><div class="sec-after"></div></section>`;
const setHtml = (el, html) => { if (el && el._html !== html) { el.innerHTML = html; el._html = html; } };
const moreLine = (key, shown, total) => total > shown ? `<button class="show-all win-more" data-more="${key}">Showing ${shown} of ${total} · show ${Math.min(WINDOW_STEP, total - shown)} more${icon('chev')}</button>` : '';
function fillSec(el, { list, kind, count, empty = '', after = '' }) {
  const n = el.querySelector('.n'), ul = el.querySelector('.rows'), p = el.querySelector('.empty-line');
  if (n.textContent !== String(count ?? list.length)) n.textContent = String(count ?? list.length);
  ul.hidden = !list.length; p.hidden = !!list.length; setHtml(p, list.length ? '' : empty);
  const made = syncList(ul, list, { key: (j) => j.id, html: (j) => row(j, kind), sig: kind === 'cook' ? (j) => cookCard(j, true) : undefined });
  setHtml(el.querySelector('.sec-after'), after);
  return made;
}
const moreSeen = typeof IntersectionObserver === 'function' ? new IntersectionObserver((es) => { for (const e of es) if (e.isIntersecting) showMore(e.target.dataset.more); }, { rootMargin: '200px' }) : null;
function showMore(key) { if (!(key in S.win)) return; S.win[key] += WINDOW_STEP; S.sig.pass = ''; renderAll(); }
function renderPass() {
  const s = S.state; if (!s) { $('board').innerHTML = offlineCard() || '<div class="skeleton" aria-label="Opening the Board"><i></i><i></i><i></i></div>'; $('board')._keyed = null; return; }
  const siteF = siteFilterOf(S.siteFilter, s.jobs), sites = siteBar(s.jobs, siteF);   // TD-4: the lanes of one Site, or all
  const jobs = bySite(s.jobs, siteF); const byId = (a, b) => parseInt(a.id.slice(1)) - parseInt(b.id.slice(1));
  const needs = jobs.filter(NEEDS).sort(byId), cooking = jobs.filter((j) => j.status === 'running').sort(byId);
  const rail = jobs.filter((j) => j.status === 'pending').sort(byId).map((j, i) => ({ ...j, pos: i + 1 }));
  const aside = jobs.filter(ASIDE).sort(newest);
  const plated = jobs.filter((j) => j.status === 'done').sort(newest);
  // the headline says the state of the kitchen in one sentence; the line under it counts the rest (each a jump to its section)
  const n = (k, one, many) => `${k} ${k === 1 ? one : many}`;
  const L = STATUS_LABEL, low = (s) => s.toLowerCase(), asideWord = `${low(L.failed)} or ${low(L.killed)}`;
  const head = needs.length ? [`hot`, `${n(needs.length, 'work order needs', 'work orders need')} your sign-off.`]
    : cooking.length ? ['', `${n(cooking.length, 'work order', 'work orders')} ${low(L.running)}.`]
    : rail.length ? ['', `${n(rail.length, 'work order', 'work orders')} ${low(L.pending)}.`] : ['', 'All quiet.'];
  const parts = [];
  if (needs.length && cooking.length) parts.push(`<a href="#/pass" data-jump="cooking">${cooking.length} ${low(L.running)}</a>`);
  if ((needs.length || cooking.length) && rail.length) parts.push(`<a href="#/pass" data-jump="rail">${rail.length} ${low(L.pending)}</a>`);
  if (aside.length) parts.push(`<a href="#/pass" data-jump="aside" class="bad">${aside.length} ${asideWord}</a>`);
  const platedToday = plated.filter((j) => isToday(j.updated)).length;
  if (s.due) parts.unshift(`<a href="#/pass" data-hunt class="bad">${Number(s.due)} follow-up${s.due > 1 ? 's' : ''} due</a>`);
  parts.push(platedToday ? `<a href="#/pass" data-jump="plated">${platedToday} ${low(L.done)} today</a>` : `Nothing ${low(L.done)} today`);
  setHtml($('summary'), `<p class="headline-text ${head[0]}">${head[1]}</p><p class="headline-sub">${[...parts, (s.leads ? `<a href="#/pass" data-clients-open>${Number(s.leads)} lead${s.leads > 1 ? 's' : ''}</a>` : '<a href="#/pass" data-clients-open>Clients</a>'), `<a href="#/pass" data-ideas-open>${s.ideas ? Number(s.ideas) + ' idea' + (s.ideas > 1 ? 's' : '') : 'Ideas'}</a>`, '<a href="#/pass" data-brief-open>Brief</a>'].join('<span class="sep" aria-hidden="true">·</span>')}</p>`);
  const railW = windowed(rail, S.win.rail), asideW = windowed(aside, S.win.aside);
  const platedW = S.showPlated ? windowed(plated, S.win.plated) : { shown: plated.slice(0, 3), more: 0 };
  const quiet = !needs.length && !cooking.length && !rail.length;
  const nAsk = needs.filter((j) => j.approval?.id).length;
  const secs = {
    needs: needs.length && { title: L['waiting-approval'], hot: true, list: needs, kind: 'need', after: nAsk ? `<button class="btn primary approve-all" id="approve-all">Approve all ${nAsk}</button>` : '' },
    cooking: cooking.length && { title: L.running, list: cooking, kind: 'cook' },
    rail: rail.length && { title: L.pending, list: railW.shown, count: rail.length, kind: 'rail', after: moreLine('rail', railW.shown.length, rail.length) },
    aside: aside.length && { title: cap(asideWord), list: asideW.shown, count: aside.length, kind: 'aside', after: moreLine('aside', asideW.shown.length, aside.length) + (aside.some(OLD_ASIDE) ? `<button class="btn approve-all" id="clear-aside">Clear old (${aside.filter(OLD_ASIDE).length})</button>` : '') },
    plated: { title: L.done, list: platedW.shown, count: plated.length, kind: 'done', empty: `Nothing ${low(L.done)} yet.`,
      after: (S.showPlated ? moreLine('plated', platedW.shown.length, plated.length) : '') + (plated.length > 3 ? `<button class="show-all" id="toggle-plated">${S.showPlated ? 'Show fewer' : `Show all ${plated.length} ${low(L.done)}`}${icon('chev')}</button>` : '') },
  };
  const stuck = stuckAlarm(jobs);
  const blocks = [sites && { k: 'sites', h: sites }, stuck && { k: 'stuck', h: stuck }, ...['needs', 'cooking', 'rail'].filter((k) => secs[k]).map((k) => ({ k, h: secShell(k, secs[k].title, secs[k].hot) })),
    quiet && { k: 'quiet', h: `<div class="quiet"><svg viewBox="0 0 64 64" aria-hidden="true"><use href="#i-cloche"/></svg><p>Nothing building.</p><button class="btn" data-quiet-order>New work order</button></div>` },
    ...['aside', 'plated'].filter((k) => secs[k]).map((k) => ({ k, h: secShell(k, secs[k].title, secs[k].hot) }))].filter(Boolean);
  const board = $('board'); if (!board._keyed) board.innerHTML = '';   // from the skeleton or the offline card to the board
  syncList(board, blocks, { key: (b) => b.k, html: (b) => b.h });
  for (const [k, sec] of Object.entries(secs)) {
    if (!sec) continue;
    const made = fillSec($('sec-' + k), sec);
    for (const el of made) {   // a ticket that just came in: needs flash once, a new card on the stove slides in once
      const id = el.dataset?.row; if (!id || S.firstPaint) continue;
      if (k === 'needs' && !S.seenNeeds.has(id)) el.classList.add('flash');
      if (k === 'cooking' && !S.seenCook.has(id)) el.classList.add('enter');
    }
  }
  for (const j of cooking) S.seenCook.add(j.id);
  if (moreSeen) for (const el of board.querySelectorAll('[data-more]')) moreSeen.observe(el);
  S.firstPaint = false;
}
S.firstPaint = true;
$('board').addEventListener('click', (e) => {
  if (e.target.closest('#approve-all')) approveAll(e.target.closest('#approve-all'));
  if (e.target.closest('#clear-aside')) clearAside(e.target.closest('#clear-aside'));
  const sf = e.target.closest('[data-site-filter]'); if (sf) { S.siteFilter = sf.dataset.siteFilter; store.set('siteFilter', S.siteFilter); S.win.rail = S.win.aside = S.win.plated = WINDOW_FIRST; S.sig.pass = ''; renderAll(); }
  if (e.target.closest('#toggle-plated')) { S.showPlated = !S.showPlated; S.win.plated = WINDOW_FIRST; S.sig.pass = ''; renderAll(); }
  if (e.target.closest('[data-more]')) showMore(e.target.closest('[data-more]').dataset.more);
  if (e.target.closest('[data-quiet-order]')) openOrder();
});
$('summary').addEventListener('click', (e) => { if (e.target.closest('[data-hunt]')) { e.preventDefault(); return openHunt(); } if (e.target.closest('[data-ideas-open]')) { e.preventDefault(); return openIdeas(); } if (e.target.closest('[data-clients-open]')) { e.preventDefault(); return openClients(); } if (e.target.closest('[data-brief-open]')) { e.preventDefault(); S.briefOpen = true; loadBrief(); return; } const a = e.target.closest('[data-jump]'); if (!a) return; e.preventDefault(); $('sec-' + a.dataset.jump)?.scrollIntoView({ behavior: 'smooth' }); });

// swipe left on a row to reveal its one action (a tap on the revealed action commits; the ⋯ menu has the same actions)
let sw = null;
function closeSwipes(except) { document.querySelectorAll('.row.open').forEach((r) => { if (r !== except) { r.classList.remove('open'); r.querySelector('.row-inner').style.transform = ''; } }); }
$('board').addEventListener('pointerdown', (e) => {
  const r = e.target.closest('[data-swipe]'); if (!r || e.target.closest('button')) return;
  sw = { r, x: e.clientX, y: e.clientY, dx: 0, moved: false, open: r.classList.contains('open') };
});
window.addEventListener('pointermove', (e) => {
  if (!sw) return; const dx = e.clientX - sw.x, dy = e.clientY - sw.y;
  if (!sw.moved && Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.5) { sw.moved = true; closeSwipes(sw.r); }
  if (!sw.moved) return; sw.dx = dx;
  const x = Math.max(-120, Math.min(0, (sw.open ? -96 : 0) + dx));
  const inner = sw.r.querySelector('.row-inner'); inner.style.transition = 'none'; inner.style.transform = `translateX(${x}px)`;
});
window.addEventListener('pointerup', () => {
  if (!sw) return; const { r, moved, dx, open } = sw; sw = null; const inner = r.querySelector('.row-inner'); inner.style.transition = '';
  if (!moved) return;
  const stay = (open ? -96 : 0) + dx < -56; r.classList.toggle('open', stay); inner.style.transform = stay ? 'translateX(-96px)' : '';
  r.dataset.justSwiped = '1'; setTimeout(() => delete r.dataset.justSwiped, 300);
});
window.addEventListener('pointercancel', () => { if (sw) { sw.r.querySelector('.row-inner').style.transform = sw.open ? 'translateX(-96px)' : ''; sw = null; } });
$('board').addEventListener('click', (e) => {
  const r = e.target.closest('.row'); if (!r || e.target.closest('button')) return;
  if (r.dataset.justSwiped) { e.preventDefault(); return; }
  if (r.classList.contains('open')) { e.preventDefault(); closeSwipes(); }
}, true);

// ---------- a little markdown (cooks answer in it): everything is escaped first, then a few safe forms come back ----------
function md(src) {
  const out = []; let list = null, code = null;
  const inline = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
    .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  const endList = () => { if (list) { out.push(`</${list}>`); list = null; } };
  for (const line of String(src || '').replace(/\r/g, '').split('\n')) {
    if (code !== null) { if (/^```/.test(line)) { out.push(`<pre class="md-code">${esc(code)}</pre>`); code = null; } else code += (code ? '\n' : '') + line; continue; }
    if (/^```/.test(line)) { endList(); code = ''; continue; }
    let m;
    if ((m = /^(#{1,4})\s+(.*)$/.exec(line))) { endList(); out.push(`<h4 class="md-h${m[1].length}">${inline(m[2])}</h4>`); continue; }
    if ((m = /^\s*[-*]\s+(.*)$/.exec(line))) { if (list !== 'ul') { endList(); out.push('<ul>'); list = 'ul'; } out.push(`<li>${inline(m[1])}</li>`); continue; }
    if ((m = /^\s*\d+[.)]\s+(.*)$/.exec(line))) { if (list !== 'ol') { endList(); out.push('<ol>'); list = 'ol'; } out.push(`<li>${inline(m[1])}</li>`); continue; }
    endList(); if (line.trim()) out.push(`<p>${inline(line)}</p>`);
  }
  if (code !== null) out.push(`<pre class="md-code">${esc(code)}</pre>`); endList();
  return out.join('');
}
// a code change, readable on a phone: the files, +/- counts, the tests, then the diff itself (colored, collapsible)
// (at a merge gate the Phone Diff below shows the code from git instead, and a private order never shows its code)
function changeHtml(c, gate = false) {
  if (!c) return '';
  if (gate || c.private) c = { ...c, diff: '' };
  const cls = (l) => /^\+(?!\+\+)/.test(l) ? 'd-add' : /^-(?!--)/.test(l) ? 'd-del' : /^@@/.test(l) ? 'd-hunk' : /^diff --git/.test(l) ? 'd-file' : '';
  const lines = c.diff.split('\n').map((l) => `<span class="${cls(l)}">${esc(l)}</span>`).join('\n');
  const t = c.tests ? c.tests.split('\n').filter(Boolean) : [];
  const pass = t.length && !t.some((l) => /FAIL|TIMEOUT|MEMORY/.test(l));
  return `<section class="change" aria-labelledby="chg-h"><div class="dish-head"><h3 id="chg-h">The change</h3><span class="muted"><span class="d-add">+${Number(c.add)}</span> <span class="d-del">−${Number(c.del)}</span> · ${c.files.length} file${c.files.length === 1 ? '' : 's'}</span></div>
    <ul class="chg-files">${c.files.map((f) => `<li class="mono">${esc(f)}</li>`).join('')}</ul>
    ${t.length ? `<details class="more"><summary>Tests · ${pass ? 'all pass' : '<span class="fault">something failed</span>'}</summary><pre class="prompt">${esc(t.join('\n'))}</pre></details>` : ''}
    ${c.private ? '<p class="note faint">Private work order: file names only.</p>' : c.diff ? `<details class="more"><summary>Read the code</summary><pre class="diff">${lines}</pre>${c.cut ? '<p class="note faint">Long change: the rest is in the worktree.</p>' : ''}</details>` : ''}</section>`;
}
// ---------- Proof Card: a plated order's receipt, from the kitchen's own records (server.mjs proofOf); no record says "unknown" ----------
const UNK = '<span class="unk">unknown</span>';
function proofHtml(p) {
  if (!p) return '';
  const t = p.tests; const n = (x) => Number(x);
  const tests = !t ? UNK : `${t.pass === null ? UNK : `<b class="ok">${n(t.pass)} passed</b> · <b class="${t.fail ? 'fault' : ''}">${n(t.fail)} failed</b>${t.notRun ? ` · ${n(t.notRun)} not run` : ''}`}${t.final ? `<small>${esc(t.final)}</small>` : ''}`;
  const flaky = !t || t.flaky === null ? UNK : t.flaky.length ? `<span class="fault">${esc(t.flaky.join(', '))}</span>` : 'none';
  const tk = p.taster; const ship = !tk.step ? 'no Inspector step in this spec' : tk.verdict ? `<b class="${tk.verdict === 'SHIP' ? 'ok' : 'fault'}">${esc(tk.verdict)}</b> · ${tk.by ? esc(tk.by) : `crew ${UNK}`}` : UNK;
  const l = p.landed; const via = { local: 'merged on this PC', github: 'merged on GitHub' };
  const landed = !l ? UNK : `<span class="mono">${l.diffSha ? esc(l.diffSha.slice(0, 12)) : UNK}</span>${l.via ? ` · ${via[l.via]}` : ''}${p.autoMerged ? ' · on its own' : ''}${p.undone ? ' · <span class="fault">undone</span>' : ''}<small class="mono">commit ${esc(l.commit.slice(0, 10))}</small>`;
  const rows = [['Tests', tests], ['Flaky', flaky], ['Inspector', ship], ['Landed diff', landed], ['Cost', p.usd === null ? UNK : money(p.usd)], ['Time', p.minutes === null ? UNK : `${p.minutes} min`]];
  return `<section class="proof" aria-labelledby="proof-h"><div class="dish-head"><h3 id="proof-h">Proof</h3><span class="muted">from the Yard's records</span></div>
    <dl class="proof-rows">${rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('')}</dl></section>`;
}
// ---------- Phone Diff: a merge gate's files with +/- bars; tap a file for its lines, wrapped to the screen (server.mjs phoneDiff) ----------
function phoneDiffHtml(pd) {
  const max = Math.max(1, ...pd.files.map((f) => (Number(f.add) || 0) + (Number(f.del) || 0)));
  const add = pd.files.reduce((a, f) => a + (Number(f.add) || 0), 0), del = pd.files.reduce((a, f) => a + (Number(f.del) || 0), 0);
  const li = (f) => {
    const tag = `${f.protected ? `<span class="prot-mark">${icon('lock')}protected</span>` : ''}${f.bin ? '<span class="faint">binary</span>' : ''}`;
    if (pd.private) return `<li class="pd-file${f.protected ? ' prot' : ''}"><div class="pd-row"><span class="pd-name">${esc(f.path)}</span>${tag}</div></li>`;
    const a = Number(f.add) || 0, d = Number(f.del) || 0;
    return `<li class="pd-file${f.protected ? ' prot' : ''}"><button type="button" class="pd-row" data-pdfile="${esc(f.path)}" aria-expanded="false"><span class="pd-name">${esc(f.path)}</span>${tag}
      <span class="pd-n">${f.bin ? '' : `<span class="d-add">+${a}</span> <span class="d-del">−${d}</span>`}</span><span class="pd-bar" aria-hidden="true"><i class="a" data-css="width:${(100 * a / max).toFixed(1)}%"></i><i class="d" data-css="width:${(100 * d / max).toFixed(1)}%"></i></span></button><div class="pd-body" hidden></div></li>`;
  };
  return `<section class="pdiff" data-pd="${esc(pd.id)}" data-sha="${esc(pd.sha)}" aria-label="Files in this change"><div class="dish-head"><h3>Files</h3><span class="muted">${pd.private ? `${pd.files.length} file${pd.files.length === 1 ? '' : 's'}` : `<span class="d-add">+${add}</span> <span class="d-del">−${del}</span> · ${pd.files.length} file${pd.files.length === 1 ? '' : 's'}`}</span></div>
    ${pd.files.length ? `<ul class="pd-files">${pd.files.map(li).join('')}</ul>` : '<p class="note">No files changed.</p>'}${pd.private ? '<p class="note faint">Private work order: file names only. Read it on the PC.</p>' : ''}${pd.protectKnown ? '' : '<p class="note fault">The protected-file list could not be read, so every file is marked protected.</p>'}</section>`;
}
// one file's hunks as rows built with textContent (never markup), old/new line numbers from each @@ header
function pdLines(box, text) {
  let o = 0, nn = 0; const frag = document.createDocumentFragment();
  for (const l of String(text).split('\n')) {
    const row = document.createElement('div'); const ln = document.createElement('span'); const tx = document.createElement('span'); ln.className = 'pd-ln'; tx.className = 'pd-t';
    const h = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(l);
    if (h) { o = +h[1]; nn = +h[2]; row.className = 'pd-l pd-h'; }
    else if (l[0] === '+') { row.className = 'pd-l add'; ln.textContent = nn++; }
    else if (l[0] === '-') { row.className = 'pd-l del'; ln.textContent = o++; }
    else if (l[0] === '\\') row.className = 'pd-l pd-h';
    else { row.className = 'pd-l'; ln.textContent = nn++; o++; }
    tx.textContent = h ? l : l.slice(1) || ' '; row.append(ln, tx); frag.append(row);
  }
  box.append(frag);
}
document.addEventListener('click', async (e) => {
  const b = e.target.closest('[data-pdfile]'); if (!b) return;
  const li = b.closest('.pd-file'); const box = li.querySelector('.pd-body'); const sec = b.closest('.pdiff');
  const open = b.getAttribute('aria-expanded') !== 'true'; b.setAttribute('aria-expanded', String(open)); box.hidden = !open;
  if (!open || box.dataset.loaded) return;
  box.dataset.loaded = '1'; box.textContent = 'Loading…';
  const r = await api(`/api/job/${encodeURIComponent(sec.dataset.pd)}/diff?file=${encodeURIComponent(b.dataset.pdfile)}`);
  box.textContent = '';
  const say = (t, cls = 'note') => { const p = document.createElement('p'); p.className = cls; p.textContent = t; box.append(p); };
  if (!r.ok) { delete box.dataset.loaded; return say(r.error || 'This file could not be read. Tap to try again.', 'note fault'); }
  const d = r.data;
  if (d.sha !== sec.dataset.sha) { delete box.dataset.loaded; return say('This change moved while you were reading. Close this and open it again.', 'note fault'); }
  if (d.bin) say('A binary file: no lines to show.');
  else if (!d.hunks) say('No lines to show for this file.');
  else { pdLines(box, d.hunks); if (d.cut) say('Long file: the first part is shown. The rest is on the PC.', 'note faint'); }
  li.classList.add('read');
  const c = b.closest('#confirm-text'); if (c?._onPd) c._onPd();
});
// a dish that opens with "# In plain words" shows only that part; the technical rest folds away underneath
function splitPlain(text) {
  const m = /^\s*#{1,3}\s*In plain words\s*\n([\s\S]*?)(?=\n#{1,3}\s|\s*$)/i.exec(String(text || ''));
  return m ? { plain: m[1].trim(), rest: String(text).slice(m.index + m[0].length).trim() } : null;
}
function dishHtml(d) {
  if (!d) return '';
  const sp = splitPlain(d.text);
  if (sp) return `<section class="dish" aria-labelledby="dish-h"><div class="dish-head"><h3 id="dish-h">In plain words</h3><span class="muted">${esc(d.by || '')}${d.at ? ' · ' + clock(d.at) : ''}</span>
    <button class="text-btn" data-copy-dish>Copy</button></div><div class="md plain">${md(sp.plain)}</div>${sp.rest ? `<details class="more"><summary>Technical details</summary><div class="md">${md(sp.rest)}</div></details>` : ''}</section>`;
  return `<section class="dish" aria-labelledby="dish-h"><div class="dish-head"><h3 id="dish-h">The report</h3><span class="muted">${esc(d.by || '')}${d.at ? ' · ' + clock(d.at) : ''}</span>
    <button class="text-btn" data-copy-dish>Copy</button></div><div class="md">${md(d.text)}</div>${d.cut ? '<p class="note faint">Long answer: the rest is in the log.</p>' : ''}</section>`;
}

// ---------- listen: read the brief or a ticket aloud (window.speechSynthesis, no network, no tokens) ----------
// speak:start
const stripMarkup = (s) => typeof s === 'string' ? s.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim() : '';
function briefSpeech(b, hello, nm = (x) => x.name) {
  const n = (k) => (b && Array.isArray(b[k]) ? b[k] : []);
  const many = (c, one, more) => `${c} ${c === 1 ? one : more}`;
  const list = (a, f) => a.slice(0, 3).map((x) => stripMarkup(f(x))).filter(Boolean).join(', ') + (a.length > 3 ? `, and ${a.length - 3} more` : '');
  const role = (x) => `${x.role} at ${x.company}`;
  const out = [`${stripMarkup(hello)}, Jordan.`];
  if (b && b.since && b.since.known && typeof sinceText === 'function') out.push(sinceText(b.since) + '.');
  if (n('needsYou').length) out.push(`${many(n('needsYou').length, 'work order is', 'work orders are')} waiting for your sign-off: ${list(n('needsYou'), nm)}.`);
  if (n('followUps').length) out.push(`Follow up on ${list(n('followUps'), role)}.`);
  const roles = n('newRoles').length, rc = (b && b.newRoleCount) || roles;
  if (rc) out.push(`${many(rc, 'new role', 'new roles')} from the scout${roles ? ': ' + list(n('newRoles'), role) : ''}.`);
  if (n('packs').length) out.push(`${many(n('packs').length, 'pack is', 'packs are')} ready to review.`);
  if (n('plated').length) out.push(`${many(n('plated').length, 'work order is', 'work orders are')} ${STATUS_LABEL.done.toLowerCase()}.`);
  if (n('setAside').length) out.push(`${n('setAside').length} ${STATUS_LABEL.quarantined.toLowerCase()}.`);
  if (out.length === 1) out.push('A quiet night. Nothing needs your sign-off.');
  return out.join(' ').replace(/\.\./g, '.').replace(/\s+/g, ' ');
}
function jobSpeech(j, name, sentence) {
  const head = `${stripMarkup(name)}.`;
  const say = j && j.private ? `It is ${(statusLabel(j) || STATUS_LABEL.pending).toLowerCase()}.` : stripMarkup(sentence);
  return `${head} ${say}`.replace(/\.\./g, '.').replace(/\s+/g, ' ').trim();
}
function speechOK(w = globalThis) { try { return !!(w.speechSynthesis && w.SpeechSynthesisUtterance); } catch { return false; } }
function createSpeaker(w, onChange) {
  let key = null, gen = 0;
  const halt = () => { gen++; key = null; try { w.speechSynthesis.cancel(); } catch { /* nothing playing */ } };
  return {
    get key() { return key; },
    stop() { if (key !== null) { halt(); onChange?.(); } },
    toggle(text, k) {
      if (!speechOK(w)) return false;
      const was = key; halt();
      if (was === k) { onChange?.(); return false; }
      const parts = []; let cur = '';
      for (const s of String(text).match(/[^.!?]+[.!?]*\s*/g) || []) { if (cur && cur.length + s.length > 200) { parts.push(cur); cur = ''; } cur += s; }
      if (cur.trim()) parts.push(cur);
      if (!parts.length) return false;
      key = k; const mine = gen;
      const done = () => { if (gen === mine) { key = null; onChange?.(); } };
      parts.forEach((p, i) => { const u = new w.SpeechSynthesisUtterance(p.trim()); u.onerror = done; if (i === parts.length - 1) u.onend = done; w.speechSynthesis.speak(u); });
      onChange?.(); return true;
    },
  };
}
// speak:end
// since:start
// Since You Looked and the stuck-loop alarm, as words. The counts come from the server (the event log since this phone last looked,
// pass-app/server.mjs sinceView); "unknown" when the log does not reach back that far. Ticket numbers and station names only, never
// an order's words. Pure functions (checked in node by tests/Test-PassApp.ps1); ticket() is the app's own.
const SINCE_REFRESH = new Set(['job.done', 'job.quarantined', 'approval.requested', 'approval.granted', 'step.hold', 'job.killed', 'job.closed', 'job.requeued']);
function sinceClock(iso, now = new Date()) {
  const d = new Date(iso); if (isNaN(d)) return 'unknown';
  const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(now) - day(d)) / 86400000);
  if (days <= 0) return hm;
  if (days === 1) return 'yesterday ' + hm;
  if (days < 7) return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()] + ' ' + hm;
  return `${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getMonth()]} ${d.getDate()} ${hm}`;
}
// "Since 19:40: 2 handed over, 1 failed, 1 needs sign-off" (first visit on this phone: there is no last look to count from)
function sinceText(v, now = new Date()) {
  if (v && v.first) return 'Since you last looked: unknown (first visit on this phone)';
  if (!v || !v.since) return '';
  const when = 'Since ' + sinceClock(v.since, now);
  if (!v.known) return when + ': unknown (the Yard log does not reach back that far)';
  const n = (a) => (Array.isArray(a) ? a.length : 0);
  const parts = [[n(v.plated), STATUS_LABEL.done.toLowerCase()], [n(v.setAside), STATUS_LABEL.quarantined.toLowerCase()], [n(v.needsYou), n(v.needsYou) === 1 ? 'needs sign-off' : 'need sign-off']].filter(([c]) => c).map(([c, w]) => `${c} ${w}`);
  return `${when}: ${parts.length ? parts.join(', ') : 'nothing new'}`;
}
// "WO-0193 failed the same step twice (ci-wait)"
function stuckText(id, s) {
  if (!s) return '';
  return `${ticket(id)} failed the same step ${s.times === 2 ? 'twice' : Number(s.times) + ' times'} (${s.station || 'step ' + Number(s.step)})`;
}
// the reason on a Retry button: the stuck count first, then why it last failed (the server leaves the words out for a private order)
function retryWhy(j, rs = (x) => String(x)) {
  const why = j && j.retryWhy ? rs(j.retryWhy) : '';
  const head = j && j.stuck ? `failed ${Number(j.stuck.times)}x on this step` : '';
  const t = [head, why].filter(Boolean).join(': ');
  return t.length > 90 ? t.slice(0, 89) + '…' : t;
}
// since:end
const speaker = createSpeaker(window, () => { if (S.brief) renderBrief(); syncListen(); });
function syncListen() { const b = $('job-listen'); if (b) { b.hidden = !speechOK() || !S.jobSpeech; b.setAttribute('aria-pressed', String(speaker.key === 'job:' + S.openJob)); } }
document.addEventListener('visibilitychange', () => { if (document.hidden) speaker.stop(); });
addEventListener('pagehide', () => speaker.stop());
$('job-listen').addEventListener('click', () => { if (S.jobSpeech) speaker.toggle(S.jobSpeech, 'job:' + S.openJob); });

// ---------- job detail ----------
async function openJob(id) {
  S.openJob = id; S.openSig = ''; $('job-ticket').textContent = ticket(id);
  if (!$('job-sheet').open) { $('job-body').innerHTML = '<div class="skeleton" aria-label="Loading the work order"><i></i><i></i><i></i></div>'; $('job-actions').innerHTML = ''; openSheet('job-sheet'); }
  await loadJob(id);
}
const isImprove = (j) => j.recipe === 'improve' || /^improve:/i.test(j.name || '');
function stateSentence(j) {
  if (NEEDS(j)) return ['need', j.approval?.kind === 'hold' ? 'Held for you: this step looks private and only a Cloud crew can do it.' : 'Waiting for your sign-off.'];
  if (j.status === 'running') return ['', `${statusLabel(j)}: step ${Number(j.step)} of ${j.steps.length}${j.since ? ` for <span data-words="${esc(j.since)}">${words(since(j.since))}</span>` : ''}.`];
  const rw = j.status === 'pending' ? retryWaitText(j) : '';
  if (rw) return ['', `${STATUS_LABEL.pending}. ${esc(cap(rw))}${j.retry.cls === 'wait' ? ' (it was waiting on CI, GitHub or the network)' : ''}.${j.last ? ' Last try: ' + esc(reason(j.last)) : ''}`];
  if (j.status === 'pending') return ['', j.notBefore && new Date(j.notBefore) > Date.now() ? `${STATUS_LABEL.pending}. Tries again in ${words(-since(j.notBefore))}.` : `${STATUS_LABEL.pending}. Starts when a crew is free.`];
  if (j.status === 'done') return ['', `${j.autoMerged && isImprove(j) ? 'Merged on its own · ' : ''}${STATUS_LABEL.done} at ${j.updated ? clock(j.updated) : ''}${j.costUsd ? ` · ${money(j.costUsd)}` : ''}.`];
  if (j.status === 'killed') return ['fail', `${STATUS_LABEL.killed}. Retry puts it back in the queue.`];
  return ['fail', `${esc(statusLabel(j))} after ${(j.attempt || 0) + 1} ${j.attempt ? 'tries' : 'try'}.${j.last ? ' ' + esc(reason(j.last)) : ''}`];
}
// a merge gate on the ticket: its Phone Diff is filled in after the ticket paints (git runs off the server loop, so it can take a moment)
const PD_GATE = (j) => NEEDS(j) && j.approval?.gate === 'merge';
async function fillPhoneDiff(id) {
  const r = await api(`/api/job/${id}/diff`); const slot = $('pdiff-slot'); if (!slot || S.openJob !== id) return;
  slot.innerHTML = r.ok ? phoneDiffHtml(r.data) : `<p class="note fault">${esc(r.error || 'The files could not be read.')}</p>`;
}
async function loadJob(id) {
  const r = await api('/api/job/' + id); if (S.openJob !== id) return;
  if (!r.ok) { $('job-body').innerHTML = `<p class="empty-line fault">${esc(r.error || 'Could not load this work order.')}</p>`; return; }
  const j = r.data; const [cls, sentence] = stateSentence(j);
  S.jobSpeech = jobSpeech(j, nameOf(j).text, sentence); syncListen();
  const created = j.created ? `${clock(j.created)}${isToday(j.created) ? '' : ' ' + new Date(j.created).toLocaleDateString()}` : '';
  $('job-ticket').textContent = `${ticket(j.id)}${created ? ' · ' + created : ''}`;
  const hist = j.history || [];
  const stepEnd = (i) => hist.filter((x) => x.step === i && x.outcome === 'done').pop()?.at;
  const current = j.steps.findIndex((x) => x.state !== 'done');
  const steps = j.steps.map((st, i) => {
    const node = st.state === 'done' ? 'done' : ['quarantined', 'failed', 'killed'].includes(st.state) ? 'fail' : i === current ? 'now' : '';
    let dur = '';
    if (st.state === 'running' && j.since) dur = `<span data-since="${esc(j.since)}">${mmss(since(j.since))}</span>`;
    else if (st.state === 'done') { const end = stepEnd(i); const start = i === 0 ? j.created : stepEnd(i - 1); if (end && start) dur = mmss((new Date(end) - new Date(start)) / 1000); }
    const runs = st.runs.map((x) => {
      const live = st.state === 'running' && x.attempt === j.attempt;
      const out = x.exit === undefined ? (live ? 'building' : '-') : x.exit === 0 ? 'done' : x.exit === 10 ? 'held for you' : x.exit === 11 ? 'waited for a crew' : `<span class="fault">failed (exit ${Number(x.exit)})</span>`;
      const c = x.cost ? [x.cost.supplier, x.cost.model].filter(Boolean).join(' ') + (x.cost.usd ? ' · ' + money(x.cost.usd) : '') + (x.cost.tried?.length > 1 ? ' · tried ' + x.cost.tried.map((t) => t.supplier).join(' → ') : '') : '';
      return `<div><span class="mono">try ${Number(x.attempt) + 1}</span> · ${out}${c ? ' · ' + esc(c) : ''}</div>${x.sous?.why ? `<div class="step-why sous-why">${esc(x.sous.why)}</div>` : ''}`;
    }).join('');
    const latest = st.runs[st.runs.length - 1];
    return `<li class="step"><span class="node ${node}" aria-hidden="true"></span>
      <button class="step-btn" data-step-run="${esc(latest?.run || '')}" aria-expanded="false" ${latest ? '' : 'disabled'}>
        <span class="step-line"><span class="step-name">${i + 1}. ${esc(floorStep({ station: st.station, role: st.role }))}</span><span class="step-dur">${dur}</span></span>
        ${st.summary ? `<span class="step-sum">${esc(st.summary)}</span>` : ''}
        ${st.approve ? '<span class="step-why" data-css="display:block">Waits for your sign-off before it runs.</span>' : ''}
        ${runs ? `<span class="step-runs">${runs}</span>` : ''}</button><div class="step-peek"></div></li>`;
  }).join('');
  const prompt = j.steps.find((x) => x.prompt)?.prompt;
  const pillCls = NEEDS(j) ? 'need' : j.status === 'running' ? 'now' : ['pending', 'closed'].includes(j.status) ? 'wait' : j.status === 'done' ? 'done' : 'fail';
  const pill = [pillCls, `${pillCls === 'now' ? '<i class="spin-sm" aria-hidden="true"></i>' : pillCls === 'done' ? '✓ ' : ''}${esc(statusLabel(j))}`];
  const endAt = j.status === 'running' ? new Date().toISOString() : (j.updated || null);
  const total = j.created && endAt ? words(Math.max(0, (new Date(endAt) - new Date(j.created)) / 1000)) : '';
  const cooksUsed = [...new Set(j.steps.flatMap((st) => st.runs.map((x) => x.cost?.supplier).filter(Boolean)))];
  $('job-body').innerHTML = `
    <div class="ticket job-hero ${pill[0]}"><span class="status-pill ${pill[0]}">${pill[1]}</span><h2>${nameHtml(j)}</h2><p class="state ${cls}">${sentence}</p>
      <div class="job-progress" aria-hidden="true">${j.steps.map((st, i) => `<i class="${st.state === 'done' ? 'done' : i === current ? (ASIDE(j) ? 'fail' : NEEDS(j) ? 'need' : 'now') : ''}"></i>`).join('')}</div>
      <div class="stat-chips">${total ? `<span><b>${esc(total)}</b> on the line</span>` : ''}<span><b>${Number(j.step)}/${j.steps.length}</b> steps</span><span><b>${Number(j.attempt || 0) + 1}</b> ${j.attempt ? 'tries' : 'try'}</span>${cooksUsed.length ? `<span>${cooksUsed.map((c) => `<em data-css="--cook:${COOK_COLORS[cookOf({ cook: c, station: 'agent' })] || 'var(--ink-3)'}">${esc(cookLabel(c))}</em>`).join('')}</span>` : ''}${j.costUsd ? `<span><b>${money(j.costUsd)}</b> pay-per-use</span>` : ''}</div></div>
    ${NEEDS(j) && j.approval?.text ? `<div class="ask-block"><b>Asking</b><br>${esc(askText(j))}</div>` : ''}
    ${j.why ? `<p class="why-line">${esc(j.why)}</p>` : ''}
    ${j.status === 'done' && isImprove(j) && j.autoMerged ? '<p class="why-line">Merged on its own</p>' : ''}
    ${prLink(j.pr)}
    ${ASIDE(j) && j.diagnosis ? `<a class="link-row fix-row" href="#/job/${esc(j.diagnosis)}"><span><b>Diagnosis</b> · ${ticket(j.diagnosis)}<small>Why it broke and how to fix it</small></span>${icon('chev')}</a>` : ''}
    ${proofHtml(j.proof)}
    ${changeHtml(j.change, PD_GATE(j))}
    ${PD_GATE(j) ? '<div id="pdiff-slot" class="pdiff-slot"><p class="note">Loading the files…</p></div>' : ''}
    ${dishHtml(j.dish)}
    ${j.fixGoal ? `<div class="fix-goal"><b>Suggested fix</b><p>${esc(j.fixGoal)}</p><button class="btn primary" data-fix="${esc(j.id)}">Make this fix</button><small class="faint">Builds it on its own branch, tests it, and merges only with your sign-off.</small></div>` : ''}
    ${j.waits || j.parent ? `<div class="facts">${j.waits ? `<span>waited for a crew ${Number(j.waits)}×</span>` : ''}${j.parent ? `<span>from ${ticket(j.parent)}</span>` : ''}</div>` : ''}
    <h3 class="group-label">Steps</h3><ol class="steps">${steps}</ol>
    <section class="replay-section" id="replay-slot" aria-label="Replay"></section>
    <button class="link-row" data-do="logs" data-id="${j.id}"><span>Logs</span>${icon('chev')}</button>
    ${prompt ? `<details class="more"><summary>The work order</summary><pre class="prompt">${esc(prompt)}</pre></details>` : ''}
    <details class="more"><summary>History · ${hist.length}</summary><ol class="hist">${hist.slice().reverse().map((h) => `<li><span class="mono">${h.at ? clock(h.at) : ''}</span><span>step ${Number(h.step) + 1}, try ${Number(h.attempt || 0) + 1}: ${esc(h.outcome)}${h.detail ? ' · ' + esc(h.detail) : ''}</span></li>`).join('')}</ol></details>`;
  $('job-actions').innerHTML = NEEDS(j) ? `<button class="btn" data-do="reject" data-id="${j.id}">Reject</button><button class="btn primary" data-do="approve" data-id="${j.id}">Approve</button>`
    : (j.status === 'running' || j.status === 'pending') ? `<button class="btn" data-do="stop" data-id="${j.id}">Cancel work order</button>`
    : (j.status === 'done' && isImprove(j) && !j.undone) ? `<button class="btn" data-do="undo-merge" data-id="${j.id}">Undo</button>`
    : ASIDE(j) ? `${j.diagnosis || /^diagnose:/.test(j.name) ? '' : `<button class="btn" data-do="diagnose" data-id="${j.id}">Find the fix</button>`}<button class="btn primary retry-btn" data-do="retry" data-id="${j.id}">${retryLabel(j)}</button>` : '';
  S.fixGoal = j.fixGoal || '';
  S.openSig = [j.status, j.step, j.attempt, j.last].join('|'); S.dishText = j.dish?.text || '';
  fillReplay(j); if (PD_GATE(j)) fillPhoneDiff(j.id);
}

// ---------- replay and standup recap ----------
const REPLAY_CMD = new Set(['bash', 'shell', 'powershell']);
const REPLAY_EDIT = new Set(['edit', 'write', 'multiedit', 'notebookedit']);
function replayStats(j, runs) {
  const ev = []; const cooks = new Map(); let tokens = 0, first = null, last = null;
  for (const r of runs) {
    const cook = cookOf({ cook: r.cook, station: 'agent' }); const name = r.cook || cook;
    tokens += Number(r.tokens) || 0;
    if (r.start && (!first || r.start < first)) first = r.start;
    const end = r.end || r.start; if (end && (!last || end > last)) last = end;
    const calls = cooks.get(name) || 0; cooks.set(name, calls);
    for (const a of r.activity || []) {
      if (a.kind === 'tool' && a.status === 'start') continue;
      ev.push({ ...a, cook: name, color: COOK_COLORS[cook] || COOK_COLORS.hand, private: !!r.private });
      if (a.kind === 'tool') cooks.set(name, (cooks.get(name) || 0) + 1);
    }
  }
  const tools = ev.filter((a) => a.kind === 'tool');
  const files = new Set((j.change?.files || []));
  for (const a of tools) if (REPLAY_EDIT.has(String(a.tool || '').toLowerCase()) && a.target && !a.private) files.add(String(a.target).split(/[\\/]/).slice(-3).join('/'));
  const busiest = [...cooks.entries()].sort((a, b) => b[1] - a[1])[0] || null;
  const minutes = first && last ? Math.max(0, (new Date(last) - new Date(first)) / 60000) : 0;
  const verdict = j.status === 'done' && j.autoMerged ? 'Merged on its own' : statusLabel(j);
  return { ev, cooks: [...cooks.keys()], tools: tools.length, commands: tools.filter((a) => REPLAY_CMD.has(String(a.tool || '').toLowerCase())).length,
    files: [...files], tokens, minutes, busiest: busiest ? { name: busiest[0], calls: busiest[1] } : null, verdict, first, last };
}
function recapMarkdown(j, st) {
  const n = (x) => Number(x).toLocaleString('en-US');
  return [`# Standup Recap: ${ticket(j.id)} (${title(j.name).text})`,
    `- **Verdict**: ${st.verdict}`, `- **Duration**: ${st.minutes.toFixed(1)} min`, `- **Tokens**: ${n(st.tokens)} tokens`,
    `- **Crews**: ${st.cooks.join(', ') || 'none'}`, `- **Busiest crew**: ${st.busiest ? `${st.busiest.name} (${st.busiest.calls} tool calls)` : 'none'}`,
    `- **Tool calls**: ${st.tools}`, `- **Commands**: ${st.commands}`,
    `- **Files changed**: ${st.files.length}${st.files.length ? ' (' + st.files.slice(0, 8).join(', ') + ')' : ''}`].join('\n');
}
function replayCard(e, i, n) {
  if (!e) return '<p class="faint">No tool-by-tool activity was recorded for this work order.</p>';
  const word = activityWord({ activity: [e], private: e.private }) || cap(e.kind || 'working');
  const line = e.private ? '' : String(e.target || e.out || '').slice(0, 160);
  return `<div class="replay-live-card" data-css="--cook:${esc(e.color)}"><span class="replay-dot" aria-hidden="true"></span>
    <div><b>${esc(cap(human(e.cook)))}</b> · ${esc(word)}${e.status && e.status !== 'ok' ? ` <span class="faint">(${esc(e.status)})</span>` : ''}
    ${line ? `<div class="mono replay-line">${esc(line)}</div>` : ''}</div><span class="faint mono">${i + 1}/${n}</span></div>`;
}
let replayTimer = null;
async function fillReplay(j) {
  clearInterval(replayTimer); replayTimer = null;
  const slot = $('replay-slot'); if (!slot) return;
  const r = await api('/api/job/' + j.id + '/timeline');
  if (S.openJob !== j.id || $('replay-slot') !== slot) return;
  const runs = r.ok ? (r.runs || []) : [];
  if (!runs.length) { slot.innerHTML = ''; return; }
  const st = replayStats(j, runs); S.recapMd = recapMarkdown(j, st);
  const t0 = st.first ? new Date(st.first).getTime() : 0; const span = Math.max(1, (st.last ? new Date(st.last).getTime() : t0) - t0);
  const segs = runs.map((x) => {
    const a = x.start ? new Date(x.start).getTime() : t0; const b = x.end ? new Date(x.end).getTime() : Math.max(a, st.last ? new Date(st.last).getTime() : a);
    const left = Math.min(98, (a - t0) / span * 100); const w = Math.max(2, Math.min(100 - left, (b - a) / span * 100));
    const c = COOK_COLORS[cookOf({ cook: x.cook, station: 'agent' })] || COOK_COLORS.hand;
    return `<li class="timeline-seg" data-css="left:${left.toFixed(1)}%;width:${w.toFixed(1)}%;background:${esc(c)}" title="${esc(`Step ${Number(x.step) + 1}, try ${Number(x.attempt) + 1}: ${x.cook} · ${x.outcome}`)}"><span>${Number(x.step) + 1}</span></li>`;
  }).join('');
  const who = runs.map((x) => `<li><span class="mono">${Number(x.step) + 1}.${Number(x.attempt) + 1}</span> ${esc(x.cook)} · ${esc(x.outcome)}${x.start ? ' · ' + clock(x.start) : ''}${x.end && x.start ? ' · ' + words((new Date(x.end) - new Date(x.start)) / 1000) : ''}</li>`).join('');
  const n = st.ev.length;
  slot.innerHTML = `<h3 class="group-label">Replay</h3>
    <ol class="timeline-bar" aria-label="Who worked when">${segs}</ol><ul class="timeline-who">${who}</ul>
    ${n ? `<div class="replay-scrubber"><button class="btn" data-replay-play aria-label="Play">Play</button><input type="range" class="replay-slider" min="0" max="${n - 1}" value="0" aria-label="Scrub the activity"></div>` : ''}
    <div class="replay-stage" aria-live="polite">${replayCard(st.ev[0], 0, n)}</div>
    <div class="recap-card"><div class="dish-head"><h3>Recap</h3><button class="text-btn" data-copy-recap>Copy as Markdown</button></div>
      <dl class="recap-grid"><dt>Verdict</dt><dd>${esc(st.verdict)}</dd><dt>Minutes</dt><dd>${st.minutes.toFixed(1)}</dd><dt>Crews</dt><dd>${esc(st.cooks.join(', ') || 'none')}</dd>
      <dt>Busiest crew</dt><dd>${esc(st.busiest ? `${st.busiest.name} (${Number(st.busiest.calls)})` : 'none')}</dd><dt>Tool calls</dt><dd>${Number(st.tools)}</dd><dt>Commands</dt><dd>${Number(st.commands)}</dd>
      <dt>Files changed</dt><dd>${st.files.length}</dd><dt>Tokens</dt><dd>${st.tokens.toLocaleString('en-US')}</dd></dl></div>`;
  const slider = slot.querySelector('.replay-slider'); const stage = slot.querySelector('.replay-stage'); const play = slot.querySelector('[data-replay-play]');
  if (!slider) return;
  const show = () => { const i = Number(slider.value); stage.innerHTML = replayCard(st.ev[i], i, n); };
  const stop = () => { clearInterval(replayTimer); replayTimer = null; play.textContent = 'Play'; };
  slider.addEventListener('input', () => { stop(); show(); });
  play.addEventListener('click', () => {
    if (replayTimer) return stop();
    if (Number(slider.value) >= n - 1) slider.value = 0;
    play.textContent = 'Pause';
    replayTimer = setInterval(() => { if (!slot.isConnected || Number(slider.value) >= n - 1) { stop(); return; } slider.value = Number(slider.value) + 1; show(); }, 700);
  });
}
$('job-body').addEventListener('click', async (e) => {
  if (!e.target.closest('[data-copy-recap]')) return;
  try { await navigator.clipboard.writeText(S.recapMd || ''); buzz(); toast('Copied standup report'); } catch { toast("Couldn't copy here", { bad: true }); }
});
$('job-body').addEventListener('click', async (e) => {
  const fx = e.target.closest('[data-fix]'); if (!fx || !S.fixGoal) return;
  if (!await confirmBox({ title: 'Make this fix?', html: `<div class="quote">${esc(S.fixGoal)}</div><p>The Dispatcher plans it, a crew builds it on its own branch, the tests run and the Inspector checks it. It merges only when you sign off.</p>`, yes: 'Start the fix' })) return;
  const r = await act({ op: 'cook', recipe: 'improve', vars: { goal: S.fixGoal } }, { btn: fx });
  if (r.ok && r.data?.job) toast(`${ticket(r.data.job)} is queued`, { action: { label: 'Open', fn: () => go('#/job/' + r.data.job) } });
});
$('job-body').addEventListener('click', async (e) => {
  if (!e.target.closest('[data-copy-dish]')) return;
  try { await navigator.clipboard.writeText(S.dishText); buzz(); toast('Copied'); } catch { toast("Couldn't copy here", { bad: true }); }
});
$('job-body').addEventListener('click', async (e) => {
  const full = e.target.closest('[data-log-run]'); if (full) return openLog(S.openJob, full.dataset.logRun);
  const b = e.target.closest('[data-step-run]'); if (!b || !b.dataset.stepRun) return;
  const peek = b.nextElementSibling; const open = b.getAttribute('aria-expanded') === 'true';
  b.setAttribute('aria-expanded', String(!open)); if (open) { peek.innerHTML = ''; return; }
  const r = await api(`/api/log/${S.openJob}?run=${encodeURIComponent(b.dataset.stepRun)}`);
  peek.innerHTML = `<pre class="peek-log">${esc(r.ok ? (r.lines.slice(-5).join('\n') || '(no output)') : r.error)}</pre><button class="text-btn" data-log-run="${esc(b.dataset.stepRun)}">Full log</button>`;
});

// ---------- logs ----------
let logTimer = null;
async function openLog(id, run) {
  S.log = { id, run }; $('log-title').textContent = 'Logs'; $('log-text').textContent = 'Loading…'; $('log-jump').hidden = true;
  openSheet('log-sheet'); await pullLog(true); clearInterval(logTimer);
  logTimer = setInterval(() => { if (jobOf(id).status === 'running') pullLog(false); }, 2000);
}
async function pullLog(first) {
  if (!S.log) return; const { id, run } = S.log; const pre = $('log-text');
  const atBottom = first || pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 24;
  const r = await api(`/api/log/${id}${run ? '?run=' + encodeURIComponent(run) : ''}`); if (!S.log) return;
  const text = r.ok ? (r.lines.join('\n') || '(no output yet)') : r.error; if (pre.textContent !== text) pre.textContent = text;
  $('log-title').textContent = `${r.run ? r.run.replace(/^J(\d+)-s(\d+)-a(\d+)$/, (m, a, s, t) => `${ticket('J' + a)} · step ${+s + 1} · try ${+t + 1}`) : ticket(id)} · ${r.ok ? r.lines.length : 0} lines`;
  if (atBottom) pre.scrollTop = pre.scrollHeight; else $('log-jump').hidden = false;
}
$('log-text').addEventListener('scroll', () => { const p = $('log-text'); if (p.scrollTop + p.clientHeight >= p.scrollHeight - 24) $('log-jump').hidden = true; });
$('log-jump').addEventListener('click', () => { const p = $('log-text'); p.scrollTop = p.scrollHeight; $('log-jump').hidden = true; });
$('log-wrap').addEventListener('click', (e) => { const on = $('log-text').classList.toggle('wrap'); e.currentTarget.setAttribute('aria-pressed', String(on)); });

// ---------- activity: plain sentences ----------
function sentence(e) {
  if (e.src === 'lobe') return lobeSentence(e);   // ZG-30: the lobe's lines (public/lobe.js): counts, ids and kinds only
  if (e.job === 'talk') return ['', `<b>${esc(cookLabel(e.supplier))}</b> answered in <a href="#/talk">Talk</a>${e.ok === false ? ' · it failed' : ''}`];
  const t = String(e.type || ''); const tk = e.job ? jobLink(e.job) : ''; const d = esc(e.detail || e.text || e.reason || '');
  const step = e.step != null ? ` step ${(Number(e.step) || 0) + 1}` : '';   // numbers coerced: a string field never lands in the markup
  const map = {
    'job.added': ['', `<b>New work order</b> ${tk} ${esc(title(e.name).text)}`], 'job.done': ['', `${tk} <b>${STATUS_LABEL.done.toLowerCase()}</b>`],
    'step.started': ['', `${tk} started${step}${e.attempt ? `, try ${(Number(e.attempt) || 0) + 1}` : ''}`], 'step.done': ['', `${tk} finished${step}`],
    'step.retry': ['', `${tk} failed${step}; waiting ${minWords(Number(e.inSec) || 0)} before retry`], 'job.quarantined': ['fail', `${tk} <b>${STATUS_LABEL.quarantined.toLowerCase()}</b>${(() => { const m = /^(\w+) x(\d+)$/.exec(e.reason || ''); return m ? ` after ${m[2]} ${m[2] === '1' ? 'try' : 'tries'} (${esc((FAIL_WORD[m[1]] || m[1]).toLowerCase())})` : e.reason ? ': ' + esc(e.reason) : ''; })()}`],
    'approval.requested': ['ask', `${tk} <b>needs your sign-off</b>: ${esc(e.text || '')}`], 'approval.granted': ['', `<b>You</b> approved ${tk}`],
    'approval.auto': ['', `${tk} <b>merged on its own</b>${e.why || d ? ': ' + esc(e.why || e.detail || e.text || e.reason || '') : ''}`],
    'merge.undone': [e.undoPushed === false ? 'fail' : '', `${tk} merge <b>undone</b>${d ? ': ' + d : ''}${e.undoPushed === false ? ` · <b>not on GitHub</b>${e.undoPushWhy ? ' (' + esc(e.undoPushWhy) + ')' : ''}` : ''}`],   // TD-EH-10
    'undo.pushed': ['', `${tk} undo <b>is on GitHub</b>${e.how ? ': ' + esc(e.how) : ''}`],
    'job.killed': ['', `${tk} <b>${STATUS_LABEL.killed.toLowerCase()}</b>`], 'job.closed': ['', `${tk} <b>${STATUS_LABEL.closed.toLowerCase()}</b>${e.replacedBy ? ' · ordered again as ' + jobLink(e.replacedBy) : ''}`], 'job.requeued': ['', `${tk} back in the queue`], 'step.hold': ['ask', `${tk} <b>held for you</b>: ${d}`],
    'step.wait': ['', `${tk} waiting for a free crew`], 'cost': ['', `${tk} used ${money(e.usd)} on <b>${esc(e.supplier || e.model || '')}</b>`],
    'cook': ['', `<b>${esc(e.supplier)}</b> built ${tk} (${esc(e.kind || '')}) · ${e.ok ? 'passed' : 'did not pass inspection'}`],
    'breaker.open': ['fail', `<b>Stop-work order</b>: most recent steps failed; new work waits${e.coolSec ? ' ' + minWords(Number(e.coolSec)) : ''}`],
    'breaker.reopen': ['fail', `<b>Stop-work order</b> stays on: the trial step failed; new work waits ${minWords(Number(e.coolSec) || 0)} more`],
    'breaker.probe': ['', e.job ? `<b>Stop-work order</b>: ${tk} runs as the one trial step` : '<b>Stop-work order</b>: the trial step stopped without a result; another may try'],
    'breaker.closed': ['', `<b>Stop-work order lifted</b>${e.why === 'probe' ? ': a trial step passed' : e.why === 'rate' ? ': failures fell' : ''}`],
    'budget.stop': ['fail', `<b>Daily cap reached</b>: ${money(e.spentUsd)} of ${money(e.budgetUsd)}`], 'alert': [e.level === 'HIGH' ? 'fail' : 'ask', `<b>The Yard</b>: ${d}${alertNotSent(e)}`],
    'doctor': [e.ok ? '' : 'fail', `<b>Doctor</b>: ${e.ok ? 'all fine' : esc(e.problems || '')}`], 'watchdog': ['', `<b>Watchdog</b>: ${d}`],
    'standing.cooked': ['', `<b>Standing order</b> ${esc(e.name || '')} placed`], 'supervisor.resumed': ['', `<b>Supervisor</b> back after ${Math.round((e.gapSec || 0) / 60)} min`],
    'diagnose.started': ['', `<b>Fixing what broke</b>: ${tk} gets a diagnosis (${e.detail ? jobLink(e.detail) : 'started'})`],
    'ram.low': ['fail', `<b>Low memory</b>: ${d}`],
    'autopilot.built': ['', `<b>Autopilot</b> is building idea ${esc(e.detail || '')} as ${tk}`], 'coach.filed': ['', `<b>Coach</b> filed idea ${esc(e.detail || '')} to improve the pipeline`],
    'alert.sent': e.sent === 'ok' ? ['', 'An alert reached your phone'] : ['fail', `<b>An alert did not reach your phone</b>${e.why ? ': ' + esc(e.why) : ''}`],   // TD-EH-04
    'spawn.refused': ['fail', `${tk} <b>not allowed</b> to start more work: ${esc(e.reason || '')}`],
  };
  if (map[t]) return map[t];
  if (/^step\.(fail|crash|timeout|memcap|logflood|hung|taster)$/.test(t)) {
    const [w, ...rest] = reason(t.slice(5) + (e.detail ? ': ' + e.detail : '')).split(': ');
    return ['fail', `${tk}${step}: <b>${esc(w)}</b>${rest.length ? ' · ' + esc(rest.join(': ')) : ''}`];
  }
  return ['', `<b>${esc(t)}</b> ${tk} ${d}`];
}
// TD-EH-04: an alert that did not reach the phone says so, with notify.ps1's reason (fixed words, e.g. "phone alerts are off")
function alertNotSent(e) { return ['off', 'failed', 'limited'].includes(e.sent) ? ` · <b>not sent</b>${e.why ? ' (' + esc(e.why) + ')' : ''}` : ''; }
function renderActivity() {
  const q = S.feedQuery.toLowerCase(); const f = S.feedFilter;
  // an alert that only repeats an approval request is shown once (as the request)
  const rows = S.events.filter((e) => !(e.job === 'talk' && e.type === 'cost')).filter((e) => !(e.type === 'alert' && /needs your yes|quarantined/.test(e.text || ''))).map((e) => [e, ...sentence(e)]).filter(([, c]) => f === 'all' || (f === 'act' && c === 'ask') || (f === 'fail' && c === 'fail'))
    .filter(([e, , html]) => !q || (html + ' ' + (e.job || '')).replace(/<[^>]+>/g, '').toLowerCase().includes(q)).slice(-400).reverse();
  const group = (ts) => { if (since(ts) < 900) return 'Now'; if (isToday(ts)) return 'Earlier today'; const y = new Date(); y.setDate(y.getDate() - 1); if (new Date(ts).toDateString() === y.toDateString()) return 'Yesterday'; return new Date(ts).toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' }); };
  let g = ''; const out = [];
  const tone = (e, c) => c || (/^(job\.done|approval\.granted|approval\.auto|verify\.flaky|breaker\.closed)$/.test(e.type) || (e.type === 'doctor' && e.ok) ? 'ok' : /^(step\.wait|step\.started|step\.done|cost|cook)$/.test(e.type) ? 'dim' : '');
  const seenWait = new Set();   // a waiting order shows only its newest "waiting for a free crew"
  for (const [e, c, html] of rows) { if (e.type === 'step.wait') { if (seenWait.has(e.job)) continue; seenWait.add(e.job); } const gg = group(e.ts); if (gg !== g) { g = gg; out.push(`<h2 class="day">${gg}</h2>`); } out.push(`<div class="ev ${c} t-${tone(e, c)}"><time datetime="${esc(e.ts)}">${clock(e.ts)}</time><p class="say">${html}</p></div>`); }
  const lobeEv = S.state?.lobeGlass?.events;   // ZG-30: a missing or unreadable lobe events file is unknown with its reason, never an empty feed
  if (lobeEv && !lobeEv.ok) out.unshift(`<div class="ev ask"><p class="say"><b>Lobe events</b>: unknown, ${esc(lobeEv.why || 'no reason given')}</p></div>`);
  $('feed').innerHTML = out.join('') || `<p class="empty-line">${q || f !== 'all' ? 'Nothing matches.' : 'Nothing has happened yet.'}</p>`;
  document.querySelectorAll('#feed-filter button').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.ff === f)));
}
$('feed-filter').addEventListener('click', (e) => { const b = e.target.closest('[data-ff]'); if (b) { S.feedFilter = b.dataset.ff; renderActivity(); } });
$('feed-search').addEventListener('input', (e) => { S.feedQuery = e.target.value; renderActivity(); });

// ---------- cooks ----------
const COOK_LABEL = { claude: 'Claude', antigravity: 'Claude via Google', gemini: 'Gemini', local: 'Local', hands: 'Yard hands', sous: 'Dispatcher' };
const cookLabel = (n) => COOK_LABEL[n] || cap(n);
const COOK_ROUTE = { claude: 'Claude Pro plan', antigravity: 'Google AI Pro plan (Antigravity)', gemini: 'Google AI Pro plan (Antigravity)', local: 'This PC' };
const COOK_WORD = { resting: 'Resting', busy: 'Busy', capped: 'At its cap', 'signed-out': 'Signed out', off: 'Off', unknown: 'Unknown' };
function cookWord(name, c) {
  if (c.status === 'ready') { const j = S.state?.jobs.find((x) => x.status === 'running' && String(x.cook || '').startsWith(name)); return j ? `Building ${ticket(j.id)}` : 'Idle'; }
  return COOK_WORD[c.status] || c.status;
}
// ---------- the floor: how many are cooking, waiting and waiting for you (the desks above it are live.js) ----------
function floorHtml(s) {
  const running = s.jobs.filter((j) => j.status === 'running');
  const waiting = s.jobs.filter((j) => j.status === 'pending').length, needs = s.jobs.filter(NEEDS).length;
  const sb = s.scoreboard;
  const evo = sb && sb.rate != null ? `<p class="floor-sum evo">Evolution rate <b>${esc(sb.rate)}</b> ${esc(sb.trendArrow || '→')} · Leap ${esc(sb.leap)} · ${esc(sb.leapName || '')}</p>` : '';
  return `${evo}<h2 class="group-label">On the line now</h2>
    <p class="floor-sum">${running.length ? `${running.length} building` : 'Nobody building'}${waiting ? ` · ${waiting} waiting their turn` : ''}${needs ? ` · <a href="#/pass">${needs} need${needs === 1 ? 's' : ''} sign-off</a>` : ''}</p>
    <h2 class="group-label">Plans</h2>`;
}
// ---------- Live: the call (live.js). Every step on the line is a cook at a desk; the busy one shares its screen. It keeps its own
// memory of who joined and left, ticks every second, and draws only while the Live tab is open (the voice and the quiet notice work on any tab).
const liveCall = startLive({ root: $('live-call'), getState: () => (S.stale ? null : S.state), getEvents: () => S.events, isVisible: () => S.view === 'cooks' && !!S.state && !S.stale, store,
  openSheet: () => openSheet('agent-sheet'), sheetOpen: () => $('agent-sheet').open, sheetTitle: $('agent-title'), sheetBody: $('agent-body'),
  fetchStep: async (id, step) => { const r = await api('/api/job/' + id); return r.ok ? String(r.data?.steps?.[step - 1]?.summary || '') : ''; } });
function renderCooks() {
  const s = S.state; const el = $('cooks-body'); if (!s) { el.innerHTML = offlineCard() || '<p class="empty-line">Loading…</p>'; return; }
  const cooks = Object.entries(s.cooks || {}); const jd = s.judge; const pct = Math.min(100, Math.round(100 * s.spent / Math.max(s.budget, 0.01)));
  el.innerHTML = `${floorHtml(s)}
    <ul class="rows">${cooks.map(([n, c]) => { const pu = c.planUse; const used = pu ? Math.round(100 * pu.used) : c.maxRuns ? Math.min(100, Math.round(100 * c.runs / c.maxRuns)) : 0; const model = [].concat(c.models || [])[0] || '';
      return `<li class="row cook-row"><div class="row-inner"><button class="row-link" data-cook="${esc(n)}" aria-label="${esc(n + ', ' + cookWord(n, c))}" data-css="border:0;background:none;cursor:pointer"></button>
        <div class="row-main"><div><span class="cook-name">${esc(cookLabel(n))}</span><span class="model">${esc(model)}</span></div>
          <div class="meter${used >= 90 ? ' hot' : ''}" aria-hidden="true"><i data-css="width:${used}%"></i></div><div class="meter-label">${fmtTokens(c.tokensToday || 0)} tokens today · ${fmtTokens(c.tokensWindow || 0)} in window · ${pu ? `Plan: ${Math.round(100 * pu.five)}% of 5 hours · ${Math.round(100 * pu.week)}% of the week` : `${Number(c.runs)} of ${Number(c.maxRuns)} runs in the last ${c.windowHours === 1 ? 'hour' : Number(c.windowHours) + ' hours'}`}</div></div>
        <div class="row-side"><span class="cook-state${['signed-out', 'off'].includes(c.status) ? ' off' : ''}">${esc(cookWord(n, c))}</span>${icon('chev')}</div></div></li>`; }).join('')
      || '<li class="empty-line">The crews appear after the next supervisor pass.</li>'}</ul>
    <h2 class="group-label">Today</h2>
    <dl class="kv"><div><dt>Usage</dt><dd class="mono"><b>${fmtTokens(s.tokensToday || 0)} tokens today</b><br><small class="faint">about ${money(s.spent)} pay-per-use at current prices</small></dd></div></dl>
    <div class="meter${pct >= 90 ? ' hot' : ''}" data-css="margin:8px var(--gutter) 0" aria-hidden="true"><i data-css="width:${pct}%"></i></div>
    <p class="note">Your plans bill nothing per token. This is what the work would cost pay-per-use; the cap works as a daily limit, and past 80% cheap work orders go to the Home crew.</p>
    <h2 class="group-label">Dispatcher</h2>
    <dl class="kv"><div><dt>Privacy judge</dt><dd class="mono">${esc(jd?.decider || 'patterns only')}</dd></div>
      <div><dt>Keeps it local at</dt><dd>${jd ? Math.round(jd.privateAt * 100) + '% likely personal' : '-'}</dd></div>
      <div><dt>Backup judge</dt><dd class="mono">${esc(jd?.fallback || '-')}</dd></div><div><dt>Private words</dt><dd>${jd ? jd.privateWords : '-'}</dd></div></dl>
    <p class="note">If the judge can't answer, plain-text work orders stay on this PC. A private step only a Cloud crew can do waits for your sign-off.</p>
    <p class="note faint">Updated <span data-ago="${esc(s.cooksAt || '')}">${ago(s.cooksAt)}</span> ago.</p>`;
}
$('view-cooks').addEventListener('click', (e) => { const b = e.target.closest('[data-cook]'); if (b) openCook(b.dataset.cook); });
async function openCook(name) {
  const c = S.state?.cooks?.[name]; if (!c) return; $('cook-title').textContent = cookLabel(name);
  $('cook-body').innerHTML = '<p class="empty-line">Loading…</p>'; openSheet('cook-sheet');
  const r = await api('/api/cooks'); const h = r.ok ? r.data.cooks[name] : null; const days = r.ok ? r.data.days : [];
  const vals = h ? h.days : days.map(() => 0); const max = Math.max(1, ...vals);
  const pts = vals.map((v, i) => `${(i / Math.max(1, vals.length - 1)) * 100},${38 - (v / max) * 34}`).join(' ');
  const act_ = ['resting', 'busy', 'capped'].includes(c.status) ? `<button class="btn primary block" data-cook-act="wake" data-name="${esc(name)}">Back on the line</button>`
    : c.status === 'ready' ? `<button class="btn block" data-cook-act="rest" data-name="${esc(name)}">Rest for an hour</button>` : '';
  $('cook-body').innerHTML = `
    <dl class="kv"><div><dt>Status</dt><dd class="${['signed-out', 'off'].includes(c.status) ? 'fault' : ''}">${esc(cookWord(name, c))}</dd></div>
      ${c.status !== 'ready' ? `<div><dt>Why</dt><dd>${esc(c.why)}</dd></div>` : ''}
      <div><dt>Plan</dt><dd>${c.plan === 'free' ? 'Free, on this PC' : esc(COOK_ROUTE[name] || 'Your subscription')}${c.plan === 'subscription' ? ' · never billed per token' : ''}</dd></div>
      <div><dt>Window</dt><dd class="mono">${Number(c.runs)} of ${Number(c.maxRuns)} runs · ${Number(c.windowHours)}h</dd></div>
      <div><dt>Tokens</dt><dd class="mono">${fmtTokens(c.tokensToday || 0)} tokens today · ${fmtTokens(c.tokensWindow || 0)} in window</dd></div>
      <div><dt>Models</dt><dd class="mono">${[].concat(c.models || []).map(esc).join(', ')}</dd></div></dl>
    ${planBlock(name, c.planUse)}
    <h3 class="group-label">Last 7 days</h3>
    <svg class="spark" viewBox="0 0 100 40" preserveAspectRatio="none" role="img" aria-label="Steps per day: ${esc(vals.join(', '))}"><line x1="0" y1="38" x2="100" y2="38"/><polyline points="${pts}"/></svg>
    <div class="spark-axis"><span>${days[0] ? new Date(days[0]).toLocaleDateString(undefined, { weekday: 'short' }) : ''}</span><span>${vals.reduce((a, b) => a + b, 0)} steps · ${h ? h.passed.reduce((a, b) => a + b, 0) : 0} passed</span><span>today</span></div>
    <h3 class="group-label">Track record</h3>
    <dl class="kv">${Object.entries(c.track || {}).map(([k, v]) => `<div><dt>${esc(k)}</dt><dd class="mono">${esc(v)} passed</dd></div>`).join('') || '<div><dt>No steps yet</dt><dd></dd></div>'}</dl>
    ${h?.recent?.length ? `<h3 class="group-label">Recent</h3><ul class="rows">${h.recent.slice().reverse().map((x) => `<li class="row compact"><div class="row-inner"><a class="row-link" href="#/job/${esc(x.job)}" aria-label="${esc(ticket(x.job))}"></a><span class="glyph ${x.ok ? 'g-done' : 'g-fail'}" aria-hidden="true"></span><div class="row-main"><div class="row-meta"><span class="mono">${ticket(x.job)}</span> · ${esc(x.kind || '')} · ${esc(x.model || '')} · ${x.ok ? 'passed' : 'did not pass'}</div></div><div class="row-side"><span class="pos">${clock(x.ts)}</span></div></div></li>`).join('')}</ul>` : ''}
    ${act_ ? `<div data-css="padding:24px var(--gutter) 0">${act_}</div>` : ''}`;
}
// the plan's own reading of its limits (Claude reports it with every run): two meters, reset times, and whether paid extra usage is on
function planBlock(name, pu) {
  const when = (ts) => ts ? new Date(ts).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }) : '-';
  const meter = (label, v, ts) => `<div class="plan-m"><div class="plan-l"><span>${label}</span><span class="mono">${Math.round(100 * v)}%</span></div>
    <div class="meter${v >= 0.9 ? ' hot' : ''}" aria-hidden="true"><i data-css="width:${Math.min(100, Math.round(100 * v))}%"></i></div><div class="meter-label">Resets ${esc(when(ts))}</div></div>`;
  if (!pu) return name === 'claude' ? `<h3 class="group-label">Your plan</h3><p class="note">No reading yet.</p><div data-css="padding:0 var(--gutter)"><button class="btn block" data-cook-act="usage" data-name="claude">Check my Claude usage</button></div>` : '';
  const extra = pu.usingOverage ? '<span class="fault">IN USE (stopped)</span>' : pu.overage === 'rejected' ? 'Off · nothing can be billed beyond the plan' : esc(pu.overage || '-');
  return `<h3 class="group-label">Your plan</h3>${meter('5-hour window', pu.five, pu.fiveResets)}${meter('This week', pu.week, pu.weekResets)}
    <dl class="kv"><div><dt>Extra usage</dt><dd>${extra}</dd></div><div><dt>Read</dt><dd><span data-ago="${esc(pu.at)}">${ago(pu.at)}</span> ago</dd></div></dl>
    <div data-css="padding:8px var(--gutter) 0"><button class="btn block" data-cook-act="usage" data-name="${esc(name)}">Check now</button></div>
    <p class="note faint">Anthropic's own numbers, read from each Claude run. Your chats here use the same plan. Past 75% the Yard prefers other crews; at the limit Claude waits for the reset.</p>`;
}
$('cook-body').addEventListener('click', async (e) => {
  const u = e.target.closest('[data-cook-act="usage"]');
  if (u) { e.stopImmediatePropagation(); const r = await act({ op: 'usage' }, { btn: u, ok: 'Usage checked' }); if (r.ok) setTimeout(() => openCook(u.dataset.name), 1500); return; }
}, true);
$('cook-body').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-cook-act]'); if (!b) return; const n = b.dataset.name; const a = b.dataset.cookAct;
  const r = await act({ op: a, name: n, minutes: 60 }, { btn: b, ok: a === 'wake' ? `${n} is back on the line` : `${n} rests for an hour` });
  if (r.ok) closeSheet('cook-sheet');
});
$('cook-body').addEventListener('click', (e) => { if (e.target.closest('.row-link')) closeSheet('cook-sheet'); });

// ---------- banners and chrome ----------
// no board ever arrived and the kitchen can't be reached: say so plainly instead of a skeleton that never resolves
function offlineCard() {
  if (S.unauth) return '<div class="quiet offline"><p><b>This device isn\'t signed in.</b></p><p class="faint">Open the Board from your Tailscale link.</p></div>';
  if (S.conn !== 'down') return '';
  return '<div class="quiet offline" role="status"><p><b>Can\'t reach the Yard.</b></p><p class="faint">Your phone or the PC is offline. The Board keeps trying; pull down to retry now.</p><button class="btn" data-set="reconnect">Try again</button></div>';
}
function renderBanners() {
  const s = S.stale ? null : S.state; const b = [];
  if (S.unauth) b.push(`<div class="banner">This device isn't signed in. Open the Board from your Tailscale link.</div>`);
  else if (S.conn === 'down') b.push(`<div class="banner">Can't reach the Yard. Retrying.</div>`);
  b.push(...mainStatusBanners(s?.mainStatus));   // TD-EH-03a: a Tower's main is red, said first (public/main-status.js; separate from other banners)
  b.push(...undoPushBanners(s?.undoUnpushed)); const amp = autoMergePauseBanner(s?.automergePause); if (amp) b.push(amp);   // TD-EH-10/11 (public/undo-pause.js)
  // paused on purpose (kitchen.ps1 pause) is a calm line, never the alarm; 10+ minutes without a tick means the scheduled task stopped
  if (s?.paused) b.push(`<div class="banner calm">Paused by you: nothing new starts until you resume it. Running work and the watchers are still watched.<button class="btn" data-set="kitchen-resume">Resume</button></div>`);
  else if (s && tickAge() !== null && tickAge() > 600) b.push(`<div class="banner">The Yard stopped ticking ${words(tickAge())} ago. Its scheduled task may not be starting (scripts/install-tasks.ps1 fixes it).<button class="btn" data-set="tick">Run now</button></div>`);
  else if (s && tickAge() !== null && tickAge() > 150) b.push(`<div class="banner">Supervisor quiet for ${words(tickAge())}.<button class="btn" data-set="tick">Run now</button></div>`);
  b.push(...siteStopBanners(s?.siteStops));   // TD-8: per Site (public/site-stop.js); the global pause above still wins
  // merge freeze windows (kitchen.repo.json "freeze", and a Site's "closed" windows in the Sites registry, TD-9, which name the Site):
  // a calm read-only line; the window itself is the switch, nothing to tap here
  for (const r of s?.freeze?.repos || []) for (const w of r.windows) {
    const now = Date.now(); const from = new Date(w.from).getTime(); const to = new Date(w.to).getTime(); const st = w.site ? `Site ${esc(w.site)}` : 'Site';
    if (from <= now && now < to) b.push(`<div class="banner calm">${st} closed: ${esc(r.name)} takes no merges until ${esc(w.toText)}: ${esc(w.why)}. Building, testing and pull requests go on.</div>`);
    else if (from > now && from - now < 7 * 86400000) b.push(`<div class="banner calm">${st} closing ahead for ${esc(r.name)}: no merges ${esc(w.fromText)} to ${esc(w.toText)} (${esc(w.why)}).</div>`);
  }
  b.push(...ciBudgetBanners(s?.ciBudget));   // TD-11: CI runs and minutes per Site this month; over budget = new PRs wait (public/ci-budget.js)
  for (const e of s?.freeze?.errors || []) b.push(`<div class="banner">${esc(e.name)}: ${e.source === 'kitchen.json' ? `Site ${esc(e.site)}'s closed windows in kitchen.json cannot be read` : 'its kitchen.repo.json cannot be read'}, so the site stays closed and nothing merges into it: ${esc(e.error)}</div>`);
  if (s?.breaker) b.push(`<div class="banner">Stop-work order: most recent steps failed, so new work waits${s.breakerUntil && new Date(s.breakerUntil) > Date.now() ? ` ${minWords(-since(s.breakerUntil))} more` : '; one trial step runs first'}.</div>`);
  if (s?.lead?.mode === 'away' && S.view === 'talk') b.push(`<div class="banner calm moon">Claude is resting until ${s.lead.resetsAt ? esc(dayTime(s.lead.resetsAt)) : 'the weekly reset'}. Gemini and the Home crew answer here.</div>`);
  const ao = alertsOffBanner(s); if (ao) b.push(ao);   // TD-EH-04
  if (s && !s.live && !['activity', 'talk'].includes(S.view)) b.push(`<div class="banner calm">AI crews are off: AI steps only show what they'd do.<button class="btn" data-set="live-on">Turn on</button></div>`);
  const html = b.join(''); if ($('banners').innerHTML !== html) $('banners').innerHTML = html;
}
// TD-EH-04 "Sent or not": while phone alerts are off, every view says how many alerts did not reach the phone (alerts.jsonl `sent`,
// counted by the server as alertsUnsent) and links to the alerts list (Activity). Plain .banner, no new style. Turning push on stays
// the Owner's own tap in Settings.
function alertsOffBanner(s) {
  if (!s || s.push !== false) return '';
  const n = Number(s.alertsUnsent?.n) || 0; const since = s.alertsUnsent?.since;
  const said = n && since ? `${n} ${n === 1 ? 'alert' : 'alerts'} since ${esc(dayTime(since))} ${n === 1 ? 'was' : 'were'} not sent` : 'new alerts will not reach your phone';
  return `<div class="banner">Phone alerts are off: ${said}.<a class="btn" href="#/activity">See alerts</a></div>`;
}
function renderChrome() {
  const s = S.state; const needs = s ? s.jobs.filter(NEEDS).length : 0;
  const c = $('count-needs'); c.hidden = !needs; c.textContent = needs;
  const cd = $('count-due'); cd.hidden = !s?.due; cd.textContent = s?.due || '';
  const cl = $('count-live'); const cooking = s ? s.jobs.filter((j) => j.status === 'running').length : 0; if (cl) { cl.hidden = !cooking; cl.textContent = cooking; }
  const cw = $('count-world'); const selfN = s ? selfCount(s.lobe, s.lobeOwner || null) : 0; if (cw) { cw.hidden = !selfN; cw.textContent = selfN || ''; }   // ZG-45: the Self card's count (lobe-self.js)
  document.title = needs ? `(${needs}) The Board` : 'The Board';
  if ('setAppBadge' in navigator) { try { needs ? navigator.setAppBadge(needs) : navigator.clearAppBadge(); } catch {} }
  if (s && needs !== S.lastNeeds) { if (S.lastNeeds >= 0) $('announce').textContent = needs ? `${needs} ${needs === 1 ? 'work order needs' : 'work orders need'} your sign-off` : 'Nothing needs your sign-off'; S.lastNeeds = needs; }
  renderBanners();
}

// ---------- render: only what changed ----------
function changed(key, value) { const sig = JSON.stringify(value); if (S.sig[key] === sig) return false; S.sig[key] = sig; return true; }
function renderAll() {
  // the pass redraws on a new board version (a patch or a full state); its keyed rows then touch only what changed. The signature
  // over every job is built only for the Live tab, which still uses it.
  const s = S.state; const jobsSig = () => (s ? [s.ideas, s.due].concat(s.jobs.map((j) => [j.id, j.status, j.step, j.attempt, j.cost, j.last, j.cook, j.approval?.id, j.notBefore])) : null);
  renderChrome();
  const noBoard = s ? '' : [S.conn, S.unauth];   // with no board yet, a change of connection redraws the placeholder
  if (S.view === 'pass' && changed('pass', [S.v ?? null, S.stale, S.recv, S.showPlated, S.win, noBoard, S.siteFilter])) { renderPass(); for (const j of s?.jobs.filter(NEEDS) || []) S.seenNeeds.add(j.id); }
  if (S.view === 'pass' && changed('brief', [S.brief, S.briefOpen])) renderBrief();
  if (S.view === 'pass' && changed('lead', [s?.lead, S.leadOpen, Math.floor(Date.now() / 60000)])) renderLead();
  if (S.view === 'activity' && changed('act', [S.events.length, S.feedFilter, S.feedQuery, S.state?.lobeGlass?.events])) renderActivity();
  if (S.view === 'talk' && changed('talk', [S.talk.id, S.talk.data, S.talk.sending, S.talk.privateNext, s?.cooks?.claude?.planUse, s?.live])) renderTalk();
  renderScene();
  if (S.view === 'ledger' && changed('ledger', [S.ledger.data, S.ledger.filter, S.ledger.err])) renderLedger();
  if (S.view === 'cooks' && changed('cooks', [noBoard, s?.cooks, s?.scoreboard,s?.tokensToday, s?.judge, s?.spent, s?.budget, s?.cooksAt, S.view === 'cooks' ? jobsSig() : null, s?.jobs.filter((j) => j.status === 'running').map((j) => [j.id, j.cook, (j.tail || []).slice(-1), (j.activity || []).slice(-1)[0]?.ts])])) renderCooks();
  if (S.view === 'cooks') liveCall.update();
  if (S.view === 'world' && changed('world', [noBoard, s?.lobe, s?.lobeOwner, s?.lobeGlass, Math.floor(Date.now() / 60000)])) renderWorld();
}
// ZG-09: the World view (public/lobe.js): the lobe's frame as five cards; its pixel art paints into CSS variables on <html>
// ZG-13: the Owner's taps (Charter Save and lock, taste, proposals) go to POST /api/lobe; a redraw waits while the Owner is typing
function renderWorld() { if (worldEditing()) { S.sig.world = ''; return; } $('world-body').innerHTML = S.state ? worldHtml(S.state.lobe, { now: Date.now(), owner: S.state.lobeOwner || null, glass: S.state.lobeGlass || null }) : (offlineCard() || '<p class="empty-line">Loading…</p>'); paintWorld(document.documentElement, S.state?.lobe); }
setInterval(() => {   // clocks tick in place; nothing else re-renders
  document.querySelectorAll('[data-since]').forEach((el) => { if (el.dataset.since) el.textContent = mmss(since(el.dataset.since)); });
  document.querySelectorAll('[data-words]').forEach((el) => { el.textContent = words(since(el.dataset.words)); });
  document.querySelectorAll('[data-pct]').forEach((el) => { const p = Math.min(100, since(el.dataset.pct) / Number(el.dataset.limit) * 100); el.style.width = p + '%'; el.parentElement?.classList.toggle('warn', p > 75); });
  document.querySelectorAll('[data-ago]').forEach((el) => { if (el.dataset.ago) el.textContent = ago(el.dataset.ago); });
  document.querySelectorAll('[data-until]').forEach((el) => { const w = untilWords(el.dataset.until); if (el.textContent !== w) el.textContent = w; });
  renderPulse(); renderBanners();
}, 1000);

// ---------- live stream ----------
// Liveness: the server sends a ping event every 25 s, so 60 s of silence means the stream is dead even when readyState still says
// open (a half-open socket after a Wi-Fi/cellular switch). connect() is idempotent: one EventSource, one retry timer with backoff
// up to 60 s. After any gap, the events missed are fetched by time and merged, so nothing that happened meanwhile is lost.
let es = null; S.lastMsg = 0; S.retryN = 0;
const seen = (m) => { S.lastMsg = Date.now(); S.retryN = 0; return m; };
function mergeEvents(list) {
  const have = new Set(S.events.map(lobeEventKey));   // ZG-30: a lobe line by its type and id, a Yard line by time, type and order
  const add = (list || []).filter((e) => e && !have.has(lobeEventKey(e))); if (!add.length) return;
  S.events = [...S.events, ...add].sort((a, b) => String(a.ts).localeCompare(String(b.ts))).slice(-1500);
}
async function backfill() { const r = await api('/api/events?n=400'); if (r.ok) { mergeEvents(r.data); renderAll(); } }
function connect() {
  clearTimeout(S.retryT); S.retryT = null;
  try { es?.close(); } catch {}
  const gap = S.lastMsg && Date.now() - S.lastMsg > 20000; S.connectAt = Date.now();
  const src = es = new EventSource('/api/stream');
  src.onopen = () => { if (es !== src) return; S.unauth = false; seen(); if (gap) backfill(); };
  src.addEventListener('state', (m) => { if (es === src) feed.full(JSON.parse(seen(m).data)); });
  src.addEventListener('patch', (m) => { if (es === src) feed.patch(JSON.parse(seen(m).data)); });   // base must be the v held, else one resync
  src.addEventListener('ping', () => { if (es === src) seen(); });
  src.addEventListener('event', (m) => {
    if (es !== src) return; const e = JSON.parse(seen(m).data); const k = lobeEventKey(e); if (S.events.some((x) => lobeEventKey(x) === k)) return;
    S.events.push(e); if (S.events.length > 1500) S.events.splice(0, S.events.length - 1500);
    if (e.type === 'alert' && e.level === 'HIGH') notify('Yard alert', 'alert');   // never the alert's words on the lock screen
    if (e.type === 'job.done' && S.state && Date.now() - new Date(e.ts).getTime() < 20000) celebrate(e);
    if (SINCE_REFRESH.has(e.type)) sinceSoon();
    renderAll();
  });
  src.addEventListener('talk', (m) => { if (es === src) onTalk(JSON.parse(seen(m).data)); });
  src.addEventListener('bye', () => { if (es !== src) return; seen(); S.restartAt = Date.now(); renderPulse(); });   // a planned restart: reconnect quietly
  src.onerror = () => {
    if (es !== src) return;
    // short drops (a restart, a phone waking up) only change the pulse; the banner comes after 10 s, 30 s for a planned restart
    S.conn = 'retry'; renderPulse();
    const wait = S.restartAt && Date.now() - S.restartAt < 30000 ? 30000 : 10000;
    clearTimeout(S.downT); S.downT = setTimeout(() => { if (!es || es.readyState !== 1) { S.conn = 'down'; renderBanners(); renderPulse(); renderAll(); } }, wait);
    if (src.readyState === 2) scheduleRetry();
  };
}
function scheduleRetry() {
  if (S.retryT) return;
  const ms = Math.min(60000, 3000 * 2 ** Math.min(S.retryN++, 5));
  S.retryT = setTimeout(async () => {
    S.retryT = null;
    // a closed stream could be a sign-out (401) rather than a drop: ask once before opening another stream
    const r = await fetch('/api/health', { cache: 'no-store' }).then((x) => x.ok).catch(() => false);
    if (r) { const st = await fetch('/api/state', { cache: 'no-store' }).then((x) => x.status).catch(() => 0); if (st === 401) { S.unauth = true; renderBanners(); renderPulse(); } }
    connect();
  }, ms);
}
function reconnect() { S.retryN = 0; connect(); }
setInterval(() => { if (!document.hidden && S.lastMsg && Date.now() - Math.max(S.lastMsg, S.connectAt || 0) > 60000 && !S.retryT) reconnect(); }, 5000);
const wake = () => { if (!document.hidden && (!es || es.readyState === 2 || (S.lastMsg && Date.now() - S.lastMsg > 30000))) reconnect(); };
document.addEventListener('visibilitychange', wake);
// a first load that never hears back (a connection that is up but passes nothing) shows the offline card after 8 s
setTimeout(() => { if ((!S.state || S.stale) && S.conn !== 'live') { S.conn = 'down'; renderBanners(); renderPulse(); renderAll(); } }, 8000);
addEventListener('pageshow', wake);
// ---------- seamless updates ----------
// The server tells us the app build with every state. When it changes, the new app loads by itself at a moment you won't notice:
// when Chef goes to the background, or after 5 s with no touch, no sheet open and nothing typed. Where you were comes back with it.
S.lastTouch = Date.now(); ['pointerdown', 'keydown', 'scroll'].forEach((t) => addEventListener(t, () => { S.lastTouch = Date.now(); }, { passive: true, capture: true }));
const idle = () => !document.querySelector('dialog[open]') && !['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName) && Date.now() - S.lastTouch > 5000 && !sw;
function applyUpdate() {
  const order = $('order-sheet').open ? { recipe: currentRecipe()?.name, cook: S.cook, private: $('private').checked } : null;   // typed text is already a draft
  try { sessionStorage.setItem('chef.resume', JSON.stringify({ t: Date.now(), y: scrollY, ff: S.feedFilter, fq: S.feedQuery, plated: S.showPlated, order })); } catch {}
  navigator.serviceWorker?.getRegistration().then((r) => r?.update()).catch(() => {}).finally(() => location.reload());
}
function updateCheck() { if (!S.updateReady) return; if (document.hidden || idle()) applyUpdate(); else setTimeout(updateCheck, 2000); }
document.addEventListener('visibilitychange', () => { if (document.hidden && S.updateReady) applyUpdate(); });
(function resume() {
  try {
    const r = JSON.parse(sessionStorage.getItem('chef.resume') || 'null'); sessionStorage.removeItem('chef.resume');
    if (!r || Date.now() - r.t > 60000) return;
    Object.assign(S, { feedFilter: r.ff || 'all', feedQuery: r.fq || '', showPlated: !!r.plated, resumeY: r.y || 0, resumeOrder: r.order || null });
    $('feed-search').value = S.feedQuery;
  } catch {}
})();
// seconds since the supervisor's last pass, measured on the server's clock (a phone's clock can be off)
function tickAge() {
  const s = S.state; if (!s) return null; if (!s.lastTick) return s.tickAge ?? null;
  return Math.max(0, Math.round((new Date(s.at) - new Date(s.lastTick)) / 1000 + (Date.now() - (s.recvAt || Date.now())) / 1000));
}
// the pulse under the title: is this live, and how fresh is the kitchen?
function renderPulse() {
  const s = S.state; let cls = 'live', text = 'Live';
  if (S.unauth) { cls = 'off'; text = 'Not signed in'; }
  else if (S.conn === 'down') { cls = 'off'; text = S.state ? OFFLINE_TEXT(S.savedAt) : 'Offline'; }
  else if (S.conn === 'retry' || S.conn === 'connecting') { cls = 'wait'; text = S.restartAt && Date.now() - S.restartAt < 30000 ? 'The Board is updating…' : 'Reconnecting…'; }
  else if (s?.paused) { cls = 'wait'; text = 'Paused by you'; }
  else if (tickAge() != null) { const a = tickAge(); text = a > 150 ? `Live · supervisor quiet ${words(a)}` : `Live · checked ${a < 5 ? 'just now' : words(a) + ' ago'}`; }
  if (S.updateReady && cls === 'live') text = 'Live · update ready';
  $('pulse').className = 'pulse ' + cls; if ($('pulse-text').textContent !== text) $('pulse-text').textContent = text;
}
// the board as the stream keeps it: a full state, then patches (public/patch.js); a patch that does not fit reconnects once
const feed = makeFeed({ onState: (s) => onState(s), resync: () => reconnect() });
function onState(s) {
  const first = S.first; S.state = s; S.v = s.v; S.recv = (S.recv || 0) + 1; S.first = false;
  if (S.conn !== 'live') { S.conn = 'live'; clearTimeout(S.downT); renderBanners(); }
  if (!S.build) S.build = s.build; else if (s.build && s.build !== S.build && !S.updateReady) { S.updateReady = true; updateCheck(); }
  s.recvAt = Date.now(); S.stale = false; renderPulse();
  S.savedAt = Date.now();
  if (!S.snapAt) saveSnap(s);   // the first board of this visit; after that only when Chef goes to the background (below)
  // each order alerts once, whatever view is open (only the ticket number: no ask text or order name on the lock screen)
  for (const j of s.jobs.filter(NEEDS)) { if (!first && !S.seenNeeds.has(j.id)) notify(`${ticket(j.id)} needs your sign-off`, 'need-' + j.id); S.seenNeeds.add(j.id); }
  renderAll();
  if (S.openJob && $('job-sheet').open) { const j = s.jobs.find((x) => x.id === S.openJob); const sig = j ? [j.status, j.step, j.attempt, j.last].join('|') : ''; if (sig !== S.openSig) loadJob(S.openJob); }
}
// The offline copy (localStorage) is written when Chef goes to the background or the page is left, not every 5 s: at 10x the
// orders it was 1.26 MB and 11.5 ms each time (chef.md). The first board of a visit is saved too, so a cold start always has one.
function saveSnap(s) { S.snapAt = Date.now(); store.set('lastState', SNAP(s)); store.set('lastStateAt', S.savedAt || S.snapAt); }
const snapNow = () => { if (S.state && !S.stale) saveSnap(S.state); };
document.addEventListener('visibilitychange', () => { if (document.hidden) snapNow(); });
addEventListener('pagehide', snapNow);
// Phone alerts while Chef is open in the background. Android Chrome has no `new Notification` (it throws), so this goes through the
// service worker. Callers pass a content-free title and a tag; the body is always the same generic words (Jordan's rule: alerts
// carry no content, nothing private ever shows on the lock screen).
function notify(title, tag) {
  if (!document.hidden || !('Notification' in window) || Notification.permission !== 'granted') return;
  navigator.serviceWorker?.ready.then((r) => r.showNotification(/^[\w# -]{1,20} needs your sign-off$/.test(String(title)) ? String(title) : 'The Board needs your sign-off', { body: 'Open the Board', tag: String(tag || 'chef'), icon: '/icon.svg' })).catch(() => {});
}

// ---------- new order ----------
async function openOrder() {
  openSheet('order-sheet');
  if (!S.recipes.length) { $('recipe-list').innerHTML = '<p class="empty-line">Loading specs…</p>'; const r = await api('/api/recipes'); S.recipes = r.ok ? r.data : []; }
  const recent = store.get('recent', []); const sorted = S.recipes.slice().sort((a, b) => { const ia = recent.indexOf(a.name), ib = recent.indexOf(b.name); return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.name.localeCompare(b.name); });
  const back = S.resumeOrder; S.resumeOrder = null;
  const pick = back?.recipe && sorted.some((r) => r.name === back.recipe) ? back.recipe : sorted[0]?.name;
  const GLYPH = { ask: '?', audit: '⌕', diagnose: '✚', 'hunt-night': '☾', improve: '↑', jobscout: '◎', pack: '▣', research: '⌘', review: '✓', tailor: '✂', upgrades: '⚙', atsscout: '⌖' };
  $('recipe-list').innerHTML = sorted.map((r, i) => `<label class="radio-row rtile" data-css="--h:${(i * 47) % 360}"><input type="radio" name="recipe" value="${esc(r.name)}" ${r.name === pick ? 'checked' : ''}><span class="mark" aria-hidden="true"></span><span class="rglyph" aria-hidden="true">${GLYPH[r.name] || esc(r.name.charAt(0).toUpperCase())}</span>
    <span><b>${esc(r.name)}</b><small>${esc(r.description)}</small><span class="tag">${Number(r.steps)} step${r.steps === 1 ? '' : 's'}${r.approve ? ' · waits for your sign-off' : ''}</span></span></label>`).join('') || '<p class="empty-line">No specs found.</p>';
  if (back) { $('private').checked = !!back.private; $('private').dispatchEvent(new Event('change')); if (back.cook) setCook(back.cook); }
  renderVars(); routeLine();
}
const currentRecipe = () => S.recipes.find((r) => r.name === document.querySelector('input[name=recipe]:checked')?.value);
function renderVars() {
  const r = currentRecipe(); if (!r) { $('var-fields').innerHTML = ''; return; }
  const drafts = store.get('drafts', {});
  $('var-fields').innerHTML = r.vars.map((v) => {
    const id = 'v-' + v.name; const long = v.required || v.max > 300; const val = drafts[`${r.name}.${v.name}`] ?? (v.default ?? '');
    const input = long ? `<textarea id="${id}" name="${esc(v.name)}" maxlength="${Number(v.max)}" ${v.required ? 'required' : ''} aria-describedby="${id}-h">${esc(val)}</textarea>`
      : `<input id="${id}" name="${esc(v.name)}" maxlength="${Number(v.max)}" value="${esc(val)}" aria-describedby="${id}-h">`;
    return `<div class="field"><label for="${id}">${esc(v.name)}${v.required ? '' : ' <span class="opt">optional</span>'}</label>${input}
      <div class="help" id="${id}-h"><span class="err" id="${id}-e"></span><span class="mono" id="${id}-c">${String(val).length}/${Number(v.max)}</span></div></div>`;
  }).join('');
}
$('recipe-list').addEventListener('change', () => { renderVars(); routeLine(); });
$('var-fields').addEventListener('input', (e) => {
  const t = e.target; const r = currentRecipe(); if (!r || !t.name) return;
  $(t.id + '-c').textContent = `${t.value.length}/${t.maxLength}`; $(t.id + '-e').textContent = '';
  const d = store.get('drafts', {}); d[`${r.name}.${t.name}`] = t.value; store.set('drafts', d); routeLine();
});
function setCook(c) { S.cook = c; document.querySelectorAll('#cook-pick button').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.cook === c))); }
$('cook-pick').addEventListener('click', (e) => { const b = e.target.closest('[data-cook]'); if (b && !b.disabled) { setCook(b.dataset.cook); routeLine(); } });
$('private').addEventListener('change', () => {
  const p = $('private').checked;
  document.querySelectorAll('#cook-pick [data-cook=claude], #cook-pick [data-cook=gemini]').forEach((b) => { b.disabled = p; });
  if (p && ['claude', 'gemini'].includes(S.cook)) setCook('auto'); routeLine();
});
function orderBody(show) {
  const r = currentRecipe(); if (!r) return null; const vars = {}; let bad = false;
  for (const v of r.vars) {
    const el = $('v-' + v.name); const val = el.value.trim();
    const msg = v.required && !val ? 'Needed.' : val.includes('{{') ? 'Remove the {{ }} braces.' : '';
    if (show) { $('v-' + v.name + '-e').textContent = msg; el.setAttribute('aria-invalid', String(!!msg)); if (msg && !bad) el.focus(); }
    if (msg) bad = true; if (val) vars[v.name] = val;
  }
  if (S.cook !== 'auto') vars.cook = S.cook; if ($('private').checked) vars.private = 'yes';
  return bad ? null : { recipe: r.name, vars };
}
// the routing sentence: the sous chef decides (nothing is sent) a moment after you stop typing
let routeT = null; let routeN = 0;
function routeLine() {
  clearTimeout(routeT); const body = orderBody(false);
  if (!body) { $('route').textContent = 'Fill in the work order to see where it goes.'; return; }
  $('route').innerHTML = '<span class="faint">Asking the Dispatcher…</span>';
  routeT = setTimeout(async () => {
    const n = ++routeN; const r = await api('/api/preview', { method: 'POST', body: JSON.stringify(body), timeout: 60000 }); if (n !== routeN) return;
    if (!r.ok) { $('route').textContent = `Couldn't preview: ${r.error}`; return; }
    const d = r.data; const where = [d.supplier, d.model].filter(Boolean).join(' · ');
    $('route').innerHTML = d.action === 'cook' ? `Goes to <b>${esc(where)}</b>${d.supplier === 'local' ? ' on this PC' : ''}.${d.private ? ' Private.' : ''}`
      : d.action === 'hold' ? `<span class="hold">Waits for your sign-off.</span> ${esc(d.why)}` : d.action === 'wait' ? `<span class="hold">Waits for a free crew.</span> ${esc(d.why)}`
      : esc(d.why || 'No AI step in this spec.');
  }, 900);
}
$('order-form').addEventListener('submit', async (e) => {
  e.preventDefault(); const body = orderBody(true); if (!body) return;
  const r = await act({ op: 'cook', ...body }, { btn: $('send-btn') });
  if (!r.ok) return;
  const d = store.get('drafts', {}); for (const k of Object.keys(d)) if (k.startsWith(body.recipe + '.')) delete d[k]; store.set('drafts', d);
  store.set('recent', [body.recipe, ...store.get('recent', []).filter((x) => x !== body.recipe)].slice(0, 6));
  closeSheet('order-sheet'); $('private').checked = false; $('private').dispatchEvent(new Event('change')); setCook('auto');
  const id = r.data?.job; if (id && S.talk.fromProp) { const pl = store.get('placed', {}); pl[S.talk.fromProp] = id; store.set('placed', pl); } S.talk.fromProp = null;
  if (id && body.recipe === 'tailor' && S.tailorApp) api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'update', id: S.tailorApp, change: { draft: id } }) });
  S.tailorApp = null;
  if (id) toast(`${ticket(id)} is queued${r.data.needsApproval ? ', waiting for your sign-off' : ''}`, { action: { label: 'Open', fn: () => go('#/job/' + id) } });
});
$('order-btn').addEventListener('click', openOrder);

// ---------- talk: chat with the kitchen ----------
// Each message goes through the sous chef like an order: personal things stay on this PC with the local cook (and the whole chat stays
// there from then on); the rest goes to a cook on your plans. The kitchen can only suggest an order: a card you tap. Nothing runs alone.
async function openTalk(id) {
  if (id !== S.talk.id) { S.talk.data = null; S.talk.sending = null; S.talk.privateNext = false; }
  S.talk.id = id || null; S.talk.unread = 0; renderTalkCount();
  if (id) { store.set('talkLast', id); await loadThread(); } else renderTalk();
}
async function loadThread() {
  const id = S.talk.id; if (!id) return;
  const r = await api('/api/talk/' + id); if (id !== S.talk.id) return;
  if (r.ok) { S.talk.data = r.data; if (S.talk.sending && youCount(r.data) > S.talk.sending.n) S.talk.sending = null; }
  else if (/no such chat/.test(r.error || '')) { store.set('talkLast', null); S.talk.id = null; S.talk.data = null; if (location.hash.startsWith('#/talk/')) history.replaceState(null, '', '#/talk'); }
  if (S.view === 'talk') renderTalk();
  clearTimeout(S.talk.pollT); if (S.talk.data?.busy) S.talk.pollT = setTimeout(loadThread, 5000);   // in case the live stream misses the answer
}
function onTalk(m) {
  if (m.thread === S.talk.id) { loadThread(); if (m.done && !m.ok) toast(`No answer: ${m.error}`, { bad: true }); }
  if (m.done && m.ok) {
    buzz(12);
    if (S.view !== 'talk' || document.hidden || m.thread !== S.talk.id) { S.talk.unread++; renderTalkCount(); notify('The Yard answered', 'talk'); }
    if (S.view !== 'talk') toast('The Yard answered', { action: { label: 'Read', fn: () => go('#/talk/' + m.thread) } });
  }
}
const youCount = (d) => (d?.messages || []).filter((m) => m.role === 'you').length;
function renderTalkCount() { const c = $('count-talk'); if (!c) return; c.hidden = !S.talk.unread; c.textContent = S.talk.unread; }
const secs = (ms) => ms >= 60000 ? Math.round(ms / 60000) + ' min' : Math.max(1, Math.round(ms / 1000)) + 's';
function talkMsg(m, i, priv) {
  if (m.role === 'you') return `<div class="msg you"><div class="bubble">${esc(m.text).replace(/\n/g, '<br>')}</div></div>`;
  const who = m.cook ? `${esc(cookLabel(m.cook))}${m.model ? ' · ' + esc(m.model) : ''}` : 'The Yard';
  const meta = `<div class="msg-meta">${m.private || priv ? `${icon('lock')}<span>On this PC</span> · ` : ''}${who}${m.ms ? ' · ' + secs(m.ms) : ''}${m.at ? ` · <time>${clock(m.at)}</time>` : ''}</div>`;
  return `<div class="msg kitchen${m.ok === false ? ' failed' : ''}"><div class="md">${md(m.text)}</div>${m.proposal ? propCard(m, i) : ''}${meta}</div>`;
}
function propCard(m, i) {
  const p = m.proposal; const placed = store.get('placed', {})[`${S.talk.id}|${m.at}`];
  const vars = Object.entries(p.vars || {}).map(([k, v]) => `<div><dt>${esc(human(k))}</dt><dd>${esc(String(v).length > 240 ? String(v).slice(0, 240) + '…' : v)}</dd></div>`).join('');
  const missing = (p.missing || []).length ? `<p class="prop-miss">Still needs: ${esc(p.missing.map(human).join(', '))}</p>` : '';
  const actions = placed ? `<a class="btn" href="#/job/${esc(placed)}">Placed as ${ticket(placed)}</a>`
    : `${p.missing?.length ? '' : `<button class="btn primary" data-prop="place" data-i="${i}">Place work order</button>`}<button class="btn" data-prop="edit" data-i="${i}">${p.missing?.length ? 'Fill in and send' : 'Edit first'}</button>`;
  return `<section class="prop" aria-label="Suggested work order"><div class="prop-h"><span class="kind">Work order</span><b>${esc(human(p.recipe))}</b></div>
    ${p.about ? `<p class="prop-about">${esc(p.about)}</p>` : ''}${vars ? `<dl class="kv">${vars}</dl>` : ''}${missing}
    <p class="prop-note">Nothing runs until you tap.</p><div class="prop-actions">${actions}</div></section>`;
}
function renderTalk() {
  if (S.talk.unread && !document.hidden) { S.talk.unread = 0; renderTalkCount(); }
  const d = S.talk.data; const priv = !!d?.private || S.talk.privateNext === true;
  const lock = $('talk-lock'); lock.setAttribute('aria-pressed', String(priv)); lock.disabled = !!d?.private;
  const pu = S.state?.cooks?.claude?.planUse;
  $('talk-lock-text').textContent = priv ? 'On this PC only' : S.state && !S.state.live ? 'AI off · Home crew' : pu ? `Plans · Claude ${Math.round(100 * pu.five)}% of 5h` : 'Can use your plans';
  const msgs = (d?.messages || []).slice();
  if (S.talk.sending && youCount(d) <= S.talk.sending.n) msgs.push({ role: 'you', text: S.talk.sending.text });
  const busy = d?.busy || S.talk.sending;
  const out = msgs.map((m, i) => talkMsg(m, i, priv));
  if (busy) out.push(`<div class="msg kitchen thinking" aria-label="The Yard is answering"><span class="dots" aria-hidden="true"><i></i><i></i><i></i></span><span class="faint">${priv ? 'Thinking on this PC' : 'The Dispatcher is picking a crew'} · <span data-since="${esc(d?.busy || S.talk.sending?.at || '')}">0:00</span></span></div>`);
  $('talk-log').innerHTML = out.join('') || `<div class="talk-empty">${icon('talk')}<p><b>Talk to the Yard.</b></p><p class="faint">Ask anything, think out loud, or say what you need done. Personal things stay on this PC. When a job fits a spec, you get a work order card to tap; nothing runs by itself.</p><div class="starters">${['What did the Yard finish today?', 'What needs me right now?', 'Which scout roles fit me best?', 'Plan my week around the job hunt'].map((q) => `<button type="button" class="starter" data-starter="${esc(q)}">${esc(q)}</button>`).join('')}</div></div>`;
  $('talk-send').disabled = !!busy;
  $('talk-text').value ||= store.get('talkDraft', '');
  autoGrow(); requestAnimationFrame(() => window.scrollTo({ top: document.body.scrollHeight }));
}
function autoGrow() { const t = $('talk-text'); t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 160) + 'px'; }
$('talk-text').addEventListener('input', () => { store.set('talkDraft', $('talk-text').value); autoGrow(); });
$('talk-text').addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); $('talk-form').requestSubmit(); } });
$('talk-form').addEventListener('submit', async (e) => {
  e.preventDefault(); const text = $('talk-text').value.trim(); if (!text || S.talk.sending || S.talk.data?.busy) return;
  buzz(); S.talk.sending = { text, at: new Date().toISOString(), n: youCount(S.talk.data) }; $('talk-text').value = ''; store.set('talkDraft', ''); renderTalk();
  const p = api('/api/talk', { method: 'POST', body: JSON.stringify({ thread: S.talk.id, text, private: Boolean(S.talk.privateNext || S.talk.data?.private) }) });
  S.talk.privateNext = false;
  const r = await p;
  if (!r.ok) { S.talk.sending = null; $('talk-text').value = text; store.set('talkDraft', text); renderTalk(); toast(`Not sent: ${r.error}`, { bad: true, sticky: true }); return; }
  if (r.thread !== S.talk.id) { S.talk.id = r.thread; store.set('talkLast', r.thread); history.replaceState(null, '', '#/talk/' + r.thread); }
  loadThread();
});
$('talk-new').addEventListener('click', () => { S.talk.privateNext = false; go('#/talk/new'); setTimeout(() => $('talk-text').focus(), 50); });
$('talk-lock').addEventListener('click', async () => {
  if (S.talk.data?.private) return;
  if (S.talk.id) {   // an existing chat can become private (never the other way: its earlier words would travel)
    if (!await confirmBox({ title: 'Keep this chat on this PC?', html: '<p>From now on only the Home crew answers here. This cannot be undone for this chat; start a new chat to use your plans again.</p>', yes: 'Keep it here' })) return;
    S.talk.privateNext = true; toast('Your next message makes this chat private'); renderTalk(); return;
  }
  S.talk.privateNext = !S.talk.privateNext; renderTalk();
});
$('talk-chats').addEventListener('click', async () => {
  $('chats-body').innerHTML = '<p class="empty-line">Loading…</p>'; openSheet('chats-sheet');
  const r = await api('/api/talk');
  $('chats-body').innerHTML = `<div class="set-group"><button class="set-row" data-chat="new"><span><b>New chat</b></span></button>${(r.ok ? r.data : []).map((t) => {
    const meta = [t.busy ? 'Answering…' : esc(ago(t.updated)), t.lastCook ? esc(cookLabel(t.lastCook)) : '', t.private ? 'Private' : '', t.id === S.talk.id ? 'open' : ''].filter(Boolean).join(' · ');
    return `<button class="set-row" data-chat="${esc(t.id)}"><span>${t.private ? icon('lock') : ''}${esc(t.title || 'Untitled')}<small>${meta}</small></span></button>`;
  }).join('')}</div>${r.ok ? '' : `<p class="empty-line">${esc(r.error)}</p>`}`;
});
$('chats-body').addEventListener('click', (e) => { const b = e.target.closest('[data-chat]'); if (!b) return; closeSheet('chats-sheet', false); go('#/talk/' + b.dataset.chat); });
$('talk-log').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-prop]'); if (!b) return;
  const m = (S.talk.data?.messages || [])[Number(b.dataset.i)]; const p = m?.proposal; if (!p) return;
  const priv = !!S.talk.data?.private;
  if (b.dataset.prop === 'edit') {   // into the order sheet, filled in, for a look and a change
    const d = store.get('drafts', {}); for (const [k, v] of Object.entries(p.vars || {})) d[`${p.recipe}.${k}`] = v; store.set('drafts', d);
    S.resumeOrder = { recipe: p.recipe, private: priv, cook: 'auto' }; S.talk.fromProp = `${S.talk.id}|${m.at}`; return openOrder();
  }
  if (!await confirmBox({ title: 'Place this work order?', html: `<p><b>${esc(human(p.recipe))}</b>${priv ? ' · stays on this PC' : ''}</p>${Object.entries(p.vars || {}).map(([k, v]) => `<div class="quote">${esc(human(k))}: ${esc(String(v).slice(0, 300))}</div>`).join('')}`, yes: 'Place work order' })) return;
  const r = await act({ op: 'cook', recipe: p.recipe, vars: { ...p.vars, ...(priv ? { private: 'yes' } : {}) } }, { btn: b });
  if (!r.ok) return; const id = r.data?.job;
  if (id) { const pl = store.get('placed', {}); pl[`${S.talk.id}|${m.at}`] = id; store.set('placed', pl); toast(`${ticket(id)} is queued${r.data.needsApproval ? ', waiting for your sign-off' : ''}`, { action: { label: 'Open', fn: () => go('#/job/' + id) } }); }
  renderTalk();
});
document.addEventListener('visibilitychange', () => { if (!document.hidden && S.view === 'talk' && S.talk.id) loadThread(); });

// ---------- job hunt: your applications and the scout's newest roles (all kept on the PC) ----------
const STATUS_WORD = { saved: 'Saved', applied: 'Applied', interview: 'Interviewing', offer: 'Offer', rejected: 'Not this time', closed: 'Closed' };
const STATUS_ORDER = ['offer', 'interview', 'applied', 'saved', 'rejected', 'closed'];
const ACTIVE_ST = ['saved', 'applied', 'interview', 'offer'];
const todayStr = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
const shortDate = (d) => new Date(d + 'T12:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
const FU_STEPS = { applied: [['initial', 'First follow-up'], ['final', 'Final follow-up']], interview: [['thanks', 'Thank-you note'], ['checkin', 'Status check-in']] };
function nextStep(x) {   // { label, n, of } for the next touch, or null when there is none (wrong status, or both sent)
  const steps = FU_STEPS[x.status]; if (!steps || x.stage === 'done') return null;
  const i = Math.max(0, steps.findIndex((s) => s[0] === x.stage)); return { label: steps[i][1], n: i + 1, of: steps.length };
}
function dueWord(d) { if (!d) return ''; const t = todayStr(); return d < t ? `follow-up overdue (${shortDate(d)})` : d === t ? 'follow up today' : `follow up ${shortDate(d)}`; }
S.hunt = { data: null, filter: 'active', open: null, adding: false };
async function openHunt() { openSheet('hunt-sheet'); if (!S.hunt.data) $('hunt-body').innerHTML = '<p class="empty-line">Loading…</p>'; await loadHunt(); }
async function loadHunt() {   // an unreadable tracker drops the old list too: nothing stale stays on screen to be edited and saved over
  const r = await api('/api/hunt'); S.hunt.data = r.ok ? r.data : null; S.hunt.packets = {}; renderHunt(r.ok ? '' : r.error);
}
// ---- the Apply card: review every answer that will be sent, then one tap. The packet is built on this PC (apply-prep); the tap hands it,
// with the hash of exactly what was shown, to the auto-fill on the PC. Copy buttons stay for doing it by hand.
const APPLY_WORD = { submitting: 'Sending on your PC…', filling: 'Filling in Edge on your PC…', applied: 'Applied', filled: 'Filled in Edge', 'needs-you': 'Needs you' };
const SOURCE_WORD = { resume: 'from your resume', profile: 'from profile.json', jordan: 'yours to answer' };
S.hunt.packets = {};
async function loadPacket(id) {
  S.hunt.packets[id] = S.hunt.packets[id] || { loading: true };
  const r = await api('/api/hunt/packet?id=' + encodeURIComponent(id));
  S.hunt.packets[id] = r.ok ? r.data : { error: r.error || 'Could not load the packet.' }; renderHunt();
}
const hasPacket = (x) => !!x.packet?.ready || (S.hunt.data?.packets || []).includes(x.id);
function applyCard(x) {
  const pk = S.hunt.packets[x.id];
  if (!pk || pk.loading) { if (!pk) setTimeout(() => loadPacket(x.id), 0); return '<section class="apply-card"><p class="empty-line">Loading the apply packet…</p></section>'; }
  if (pk.error) return `<section class="apply-card"><div class="check-bad">${esc(pk.error)}</div></section>`;
  const you = pk.answers.map((a, i) => ({ a, i })).filter(({ a }) => a.needsJordan);
  const ans = (a, i) => `<li class="apply-a${a.needsJordan ? ' you' : ''}"><div class="apply-q"><b>${esc(a.question)}</b>${a.required ? '<span class="hunt-q-req">Required</span>' : ''}</div>
      <div class="apply-ans">${a.answer ? `<span class="apply-text">${esc(a.answer)}</span>` : '<span class="faint">(left blank)</span>'}${a.answer ? `<button class="text-btn" data-copy-pk="${esc(x.id)}" data-pk-i="${i}" aria-label="Copy answer">Copy</button>` : ''}</div>
      <div class="faint apply-src">${esc(SOURCE_WORD[a.source] || a.source)}${a.note ? ' · ' + esc(a.note) : ''}</div></li>`;
  const st = pk.apply?.state; const running = st === 'submitting' || st === 'filling';
  const stale = (pk.stale || []).length ? `Built from an older ${pk.stale.join(' and ')}. Rebuild the packet before applying.` : '';
  const blocked = stale || (pk.missingRequired ? `${Number(pk.missingRequired)} required answer${pk.missingRequired > 1 ? 's are' : ' is'} still empty. Fill My answers, then Rebuild.` : !pk.filler ? 'Auto-fill is not installed on the PC yet.' : '');
  const applied = ['applied', 'interview', 'offer'].includes(pk.status);
  return `<section class="apply-card" aria-label="Apply">
    <div class="apply-head"><span class="kind">Apply</span><b>${esc(pk.role)}</b><span class="hunt-sub">${esc(pk.company)}</span></div>
    ${st ? `<p class="apply-state st-${esc(st)}" role="status">${esc(APPLY_WORD[st] || st)}${pk.apply.confirmation ? ' · ' + esc(pk.apply.confirmation) : ''}${pk.apply.reason ? ' · ' + esc(pk.apply.reason) : ''}</p>` : ''}
    ${you.length ? `<div class="apply-you" role="note"><h4>You answer these (${you.length})</h4><ul class="apply-list">${you.map(({ a, i }) => ans(a, i)).join('')}</ul></div>` : ''}
    <div class="pack-actions">${pk.link ? `<a class="btn" href="${esc(pk.link)}" target="_blank" rel="noopener noreferrer">Open the posting</a>` : ''}<a class="btn" href="/api/hunt/packet/pdf?id=${esc(x.id)}" download="resume.pdf">Resume PDF</a></div>
    <div class="apply-part"><div class="filters"><h4 class="group-label">Cover note</h4><button class="text-btn" data-copy-pk="${esc(x.id)}" data-pk-i="cover">Copy</button></div><pre class="log wrap">${esc(pk.cover)}</pre></div>
    <h4 class="group-label">What will be sent (${pk.answers.length} answer${pk.answers.length === 1 ? '' : 's'}, resume: ${esc(pk.resumeName)})</h4>
    <ul class="apply-list">${pk.answers.map((a, i) => a.needsJordan ? '' : ans(a, i)).join('')}</ul>
    ${applied ? '' : stale ? `<button class="btn primary block apply-go" data-apply-prep="${esc(x.id)}">Rebuild packet</button><p class="faint" role="note">${esc(stale)}</p>`
      : `<button class="btn primary block apply-go" data-apply-submit="${esc(x.id)}"${blocked || running ? ' disabled' : ''}>Apply</button>${blocked ? `<p class="faint">${esc(blocked)}</p>` : ''}${pk.missingRequired ? '<button class="btn" data-open-answers>My answers</button>' : ''}`}
    <div class="pack-actions"><button class="btn" data-apply-fill="${esc(x.id)}"${running || stale ? ' disabled' : ''}>Fill it on my PC</button>${applied ? '' : `<button class="btn" data-apply-mark="${esc(x.id)}">Mark applied</button>`}${stale && !applied ? '' : `<button class="btn" data-apply-prep="${esc(x.id)}">Rebuild packet</button>`}</div>
  </section>`;
}
async function applyClick(t) {
  const cp = t.closest('[data-copy-pk]');
  if (cp) {
    const pk = S.hunt.packets[cp.dataset.copyPk]; const text = cp.dataset.pkI === 'cover' ? pk?.cover : pk?.answers?.[Number(cp.dataset.pkI)]?.answer;
    if (!text) return true;
    try { await navigator.clipboard.writeText(text); buzz(); toast('Copied'); } catch { toast("Couldn't copy here", { bad: true }); }
    return true;
  }
  const sb = t.closest('[data-apply-submit]');
  if (sb) {
    const id = sb.dataset.applySubmit; const pk = S.hunt.packets[id]; if (!pk?.hash) return true;
    if (!await confirmBox({ title: 'Send this application?', html: `<p><b>${esc(pk.role)}</b> at <b>${esc(pk.company)}</b></p><p>Your PC fills the form with the resume, cover note and the ${pk.answers.length} answer${pk.answers.length === 1 ? '' : 's'} you just reviewed, and submits it. If anything looks off (a CAPTCHA, a new question) it stops and leaves Edge open for you.</p>`, yes: 'Apply' })) return true;
    buzz(); sb.disabled = true;
    const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'apply-submit', id, hash: pk.hash }) });
    if (r.ok) toast('Applying on your PC. The Board updates when it is done.'); else toast(`Not sent: ${r.error}`, { bad: true });
    delete S.hunt.packets[id]; await loadHunt(); return true;
  }
  const fl = t.closest('[data-apply-fill]');
  if (fl) {
    const id = fl.dataset.applyFill; buzz(); fl.disabled = true;
    const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'apply-fill', id }) });
    if (r.ok) toast('Filling it in Edge on your PC. Nothing is submitted.'); else { fl.disabled = false; toast(`Not started: ${r.error}`, { bad: true }); }
    delete S.hunt.packets[id]; renderHunt(); return true;
  }
  const mk = t.closest('[data-apply-mark]');
  if (mk) {
    const id = mk.dataset.applyMark; const x = S.hunt.data?.items?.find((i) => i.id === id); if (!x) return true;
    if (!await confirmBox({ title: 'Mark applied?', html: `<p>${esc(x.role)} at ${esc(x.company)}</p><p>Only the list changes; nothing is sent. The first follow-up is set for a week from now.</p>`, yes: 'Mark applied' })) return true;
    buzz(); await hunt({ op: 'update', id, changedAt: changedAt(id), change: { status: 'applied' } }, (y) => y.followUp ? `Applied. Follow-up set for ${shortDate(y.followUp)}` : 'Marked applied');
    delete S.hunt.packets[id]; renderHunt(); return true;
  }
  const pp = t.closest('[data-apply-prep]');
  if (pp) {
    buzz(); pp.disabled = true;
    const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'apply-prep', id: pp.dataset.applyPrep }) });
    if (r.ok && r.data?.job) toast(`${ticket(r.data.job)} is building the packet on this PC`, { action: { label: 'Open', fn: () => go('#/job/' + r.data.job) } });
    else if (r.ok) toast('Apply packet queued'); else { pp.disabled = false; toast(`Not started: ${r.error}`, { bad: true }); }
    return true;
  }
  return false;
}
const changedAt = (id) => S.hunt.data?.items?.find((x) => x.id === id)?.changedAt ?? '';   // sent back so an edit made on another phone is never overwritten
function renderHunt(err) {
  const d = S.hunt.data; if (!d) { $('hunt-body').innerHTML = err ? `<div class="check-bad" role="alert"><b>The job list can't be read right now.</b> ${esc(err)}. Nothing was changed, and the Board won't save over it. Pull down or reopen to try again.</div>` : '<p class="empty-line">Loading…</p>'; return; }
  const t = todayStr(); const due = (x) => ACTIVE_ST.includes(x.status) && x.followUp && x.followUp <= t;
  const items = d.items.filter((x) => S.hunt.filter === 'all' || ACTIVE_ST.includes(x.status))
    .sort((a, b) => (due(b) - due(a)) || STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status) || String(b.savedAt).localeCompare(String(a.savedAt)));
  const row = (x) => {
    const open = S.hunt.open === x.id; const ns = nextStep(x);
    const isPack = !!x.pack?.ready; const isPacket = hasPacket(x);
    const meta = [x.where, x.appliedAt ? 'applied ' + shortDate(x.appliedAt) : '', ACTIVE_ST.includes(x.status) ? dueWord(x.followUp) : ''].filter(Boolean);
    const packActions = isPack
      ? `<div class="pack-actions"><a class="btn" href="/api/hunt/pdf?id=${esc(x.id)}" target="_blank" rel="noopener noreferrer">View resume PDF</a><button class="btn" data-copy-answers="${esc(x.id)}">Copy answers</button></div>`
      : `<div class="pack-actions"><button class="btn" data-pack-app="${esc(x.id)}">Pack (resume + answers)</button></div>`;
    return `<li class="hunt-row${due(x) ? ' due' : ''}"><button class="hunt-main" data-app="${esc(x.id)}" aria-expanded="${open}">
      <span class="hunt-title"><b>${esc(x.role)}</b><span>${isPacket ? '<span class="hunt-st st-pack">Ready to apply</span> ' : isPack ? '<span class="hunt-st st-pack">Pack ready</span> ' : ''}<span class="hunt-st st-${esc(x.status)}">${esc(STATUS_WORD[x.status] || x.status)}</span></span></span>
      <span class="hunt-sub">${esc(x.company)}${meta.length ? ' · ' + meta.map(esc).join(' · ') : ''}</span></button>
      ${x.draftError ? `<div class="check-bad">The tailor work order for this role could not be placed: ${esc(String(x.draftError).slice(0, 200))}</div>` : ''}
      ${x.packetError && !isPacket ? `<div class="check-bad">The apply packet for this role could not be queued: ${esc(String(x.packetError).slice(0, 200))}</div>` : ''}
      ${open ? `<div class="hunt-edit">
        ${isPacket ? applyCard(x) : ''}
        <div class="seg wide hunt-seg" role="radiogroup" aria-label="Status">${['saved', 'applied', 'interview', 'offer', 'rejected', 'closed'].map((s) => `<button role="radio" aria-checked="${x.status === s}" data-st="${s}" data-id="${esc(x.id)}">${STATUS_WORD[s]}</button>`).join('')}</div>
        <label class="hunt-field">Follow up on<input type="date" data-fu="${esc(x.id)}" value="${esc(x.followUp || '')}"></label>
        ${ns ? `<p class="faint">Next: ${esc(ns.label)} (${Number(ns.n)} of ${Number(ns.of)})</p>` : ''}
        <label class="hunt-field">Notes<textarea data-notes="${esc(x.id)}" maxlength="2000" rows="3">${esc(x.notes || '')}</textarea></label>
        ${packActions}
        <div class="prop-actions">${x.link ? `<a class="btn" href="${esc(x.link)}" target="_blank" rel="noopener noreferrer">Open posting</a><button class="btn" data-inspect-app="${esc(x.id)}">Inspect</button>` : ''}${isPacket ? '' : `<button class="btn" data-apply-prep="${esc(x.id)}">Build apply packet</button>`}<button class="btn" data-tailor-app="${esc(x.id)}">Tailor my resume</button>${x.drafts?.length ? `<button class="btn" data-view-draft="${esc(x.id)}">View draft</button>` : ''}${ns ? `<button class="btn" data-log-fu="${esc(x.id)}">Log follow-up</button>` : ''}<button class="btn primary" data-save-notes="${esc(x.id)}">Save notes</button></div>
        ${x.questions && x.questions.length ? `<div class="hunt-questions"><h4 class="group-label" data-css="padding:12px 0 6px">Application questions (${x.questions.length})</h4><ul class="hunt-q-list">${x.questions.map((q) => `
          <li class="hunt-q-item">
            <div class="hunt-q-head"><span class="hunt-q-label"><b>${esc(q.label || q.name)}</b></span>${q.required ? '<span class="hunt-q-req">Required</span>' : '<span class="hunt-q-opt faint">Optional</span>'}<span class="hunt-q-type mono faint">${esc(q.type || '')}</span></div>
            ${q.options && q.options.length ? `<ul class="hunt-q-opts">${q.options.map((opt) => `<li>${esc(opt)}</li>`).join('')}</ul>` : ''}
          </li>`).join('')}</ul></div>` : ''}
        ${x.description ? `<details class="more" data-css="margin-top:8px"><summary>Job description</summary><pre class="prompt">${esc(x.description)}</pre></details>` : ''}
      </div>` : ''}</li>`;
  };
  const have = new Set(d.items.map((x) => x.link).filter(Boolean));
  const fresh = (d.openings?.items || []).filter((o) => !have.has(o.link));
  const add = S.hunt.adding ? `<form class="hunt-add" id="hunt-add-form"><label class="hunt-field">Company<input name="company" maxlength="120" required></label><label class="hunt-field">Role<input name="role" maxlength="160" required></label><label class="hunt-field">Link (optional)<input name="link" type="url" maxlength="500"></label>
    <label class="hunt-field">Status<select name="status"><option value="saved">Saved</option><option value="applied">Applied</option><option value="interview">Interviewing</option></select></label><div class="prop-actions"><button class="btn" type="button" data-add-cancel>Cancel</button><button class="btn primary" type="submit">Add</button></div></form>` : '';
  $('hunt-body').innerHTML = `${add}
    <div class="ans-entry"><button class="btn block" data-open-answers aria-haspopup="dialog">My answers<span class="faint"> · name, contact, work and EEO answers for applications</span></button></div>
    <div class="filters"><div class="seg" role="radiogroup" aria-label="Show">${[['active', 'Active'], ['all', 'All']].map(([k, l]) => `<button role="radio" aria-checked="${S.hunt.filter === k}" data-hf="${k}">${l}</button>`).join('')}</div>
      <span class="faint hunt-count">${d.items.filter((x) => x.status === 'applied').length} applied · ${d.items.filter((x) => x.status === 'interview').length} interviewing</span></div>
    ${items.length ? `<ul class="hunt-list">${items.map(row).join('')}</ul>` : `<p class="empty-line">${d.items.length ? 'Nothing active.' : 'Nothing tracked yet. Save a role from the scout below, or tap Add.'}</p>`}
    <h3 class="group-label">From the job scout${d.openings?.at ? ' · ' + esc(ago(d.openings.at)) + (ago(d.openings.at) === 'now' ? '' : ' ago') : ''}</h3>
    ${fresh.length ? `<ul class="hunt-list">${fresh.map((o, i) => `<li class="hunt-row scout"><div class="hunt-main"><span class="hunt-title"><b>${esc(o.role)}</b></span><span class="hunt-sub">${esc(o.company)}${o.where ? ' · ' + esc(o.where) : ''}</span>${o.pay ? `<span class="pay-pill">${esc(String(o.pay).split(/[.;]/)[0].slice(0, 60))}</span>` : ''}${o.fit ? `<span class="hunt-fit">${esc(o.fit)}</span>` : ''}</div>
      <div class="prop-actions">${o.link ? `<a class="btn" href="${esc(o.link)}" target="_blank" rel="noopener noreferrer">Open</a>` : ''}<button class="btn" data-tailor-scout="${i}">Tailor</button><button class="btn" data-apply-scout="${i}">Mark applied</button><button class="btn primary" data-save-scout="${i}">Save</button></div></li>`).join('')}</ul>`
      : `<p class="empty-line">${d.openings?.items?.length ? 'You saved every role from the last scout.' : 'No scout results yet. The job scout runs every day.'}</p>`}`;
  S.hunt.fresh = fresh;
}
async function hunt(body, ok) {
  const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify(body) });
  if (!r.ok) { toast(`Not saved: ${r.error}`, { bad: true }); if (/another phone/.test(r.error || '')) await loadHunt(); return r; }
  if (ok) toast(typeof ok === 'function' ? ok(r.data) : ok); await loadHunt(); return r;
}
// ---- My answers: the standing answers apply packets use (profile.json on the PC). Every field shows filled or empty; Save sends the
// whole form with the hash it was loaded at, so an edit made elsewhere is never saved over. Packets built before a save ask for Rebuild.
const DECLINE = 'Decline to self-identify';
const ANSWER_GROUPS = [
  ['Contact', [['name', 'Full name', 'text', 'autocomplete="name"', 120], ['email', 'Email', 'email', 'inputmode="email" autocomplete="email"', 200], ['phone', 'Phone', 'tel', 'inputmode="tel" autocomplete="tel"', 40],
    ['city', 'City', 'text', 'autocomplete="address-level2"', 100], ['state', 'State', 'text', 'autocomplete="address-level1"', 100], ['country', 'Country', 'text', 'autocomplete="country-name"', 100],
    ['linkedin', 'LinkedIn link', 'url', 'inputmode="url" placeholder="https://linkedin.com/in/…"', 300], ['github', 'GitHub link', 'url', 'inputmode="url" placeholder="https://github.com/…"', 300], ['website', 'Website or portfolio', 'url', 'inputmode="url" placeholder="https://…"', 300]]],
  ['Work', [['workAuthorization', 'Work authorization', 'text', 'placeholder="e.g. US citizen"', 200], ['needsSponsorship', 'Needs visa sponsorship', 'yesno'], ['salaryExpectation', 'Salary expectation', 'text', 'placeholder="e.g. 150000"', 120],
    ['earliestStart', 'Earliest start', 'text', 'placeholder="e.g. Two weeks after an offer"', 120], ['willingToRelocate', 'Willing to relocate', 'yesno'], ['remotePreference', 'Remote preference', 'text', 'placeholder="Remote, hybrid or on-site"', 120],
    ['yearsExperience', 'Years of experience', 'text', 'inputmode="numeric" pattern="[0-9]{1,2}(\\.[0-9])?\\+?" placeholder="e.g. 8"', 10], ['howDidYouHear', 'How did you hear about us', 'text', 'placeholder="e.g. Company website"', 120]]],
];
const EEO_CHOICES = {
  gender: ['Male', 'Female', 'Non-binary', DECLINE],
  race: ['American Indian or Alaska Native', 'Asian', 'Black or African American', 'Hispanic or Latino', 'Native Hawaiian or Other Pacific Islander', 'White', 'Two or More Races', DECLINE],
  veteran: ['I am not a protected veteran', 'I identify as one or more of the classifications of protected veteran', DECLINE],
  disability: ['No, I do not have a disability', 'Yes, I have a disability (or previously had a disability)', DECLINE],
};
const EEO_WORD = { gender: 'Gender', race: 'Race or ethnicity', veteran: 'Veteran status', disability: 'Disability' };
S.answers = null;
async function openAnswers() { openSheet('answers-sheet'); $('answers-body').innerHTML = '<p class="empty-line">Loading…</p>'; await loadAnswers(); }
async function loadAnswers() {   // an unreadable profile.json shows the reason and no form: nothing to save over it
  const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'profile-get' }) });
  S.answers = r.ok ? r.data : null; renderAnswers(r.ok ? '' : r.error || 'Could not load.');
}
const filledWord = (v) => String(v || '').trim() ? '<span class="ans-st on">Filled</span>' : '<span class="ans-st">Empty</span>';
function renderAnswers(err) {
  const d = S.answers;
  if (!d) { $('answers-body').innerHTML = `<div class="check-bad" role="alert"><b>Your answers can't be read right now.</b> ${esc(err)}. Nothing was changed, and the Board won't save over it.</div>`; return; }
  const sel = (id, v, opts) => `<select id="ans-${id}" name="${id}"><option value=""${v ? '' : ' selected'}>Not set</option>${(v && !opts.includes(v) ? [v, ...opts] : opts).map((o) => `<option value="${esc(o)}"${o === v ? ' selected' : ''}>${esc(o)}</option>`).join('')}</select>`;
  const field = ([k, label, type, attrs, max]) => { const v = d.fields[k] || '';
    return `<label class="hunt-field ans-field" for="ans-${k}"><span class="ans-label">${esc(label)} ${filledWord(v)}</span>${type === 'yesno' ? sel(k, v, ['Yes', 'No'])
      : `<input id="ans-${k}" name="${k}" type="${type}" maxlength="${max}" value="${esc(v)}" ${attrs}>`}</label>`; };
  const eeo = (k) => `<label class="hunt-field ans-field" for="ans-eeo-${k}"><span class="ans-label">${esc(EEO_WORD[k])} ${filledWord(d.eeo[k])}</span>${sel('eeo-' + k, d.eeo[k] || '', EEO_CHOICES[k])}</label>`;
  $('answers-body').innerHTML = `<form id="answers-form" class="answers-form" novalidate>
    <p class="faint ans-sum" role="status"><b>${Number(d.filled)} of ${Number(d.total)}</b> filled. Apply packets answer the standing questions from these, on your PC only.${d.stalePackets ? ` ${Number(d.stalePackets)} packet${d.stalePackets > 1 ? 's were' : ' was'} built before your last change: Rebuild ${d.stalePackets > 1 ? 'them' : 'it'} from its Apply card.` : ''}</p>
    ${ANSWER_GROUPS.map(([g, fs]) => `<fieldset class="ans-group"><legend class="group-label">${esc(g)}</legend>${fs.map(field).join('')}</fieldset>`).join('')}
    <fieldset class="ans-group"><legend class="group-label">Voluntary (EEO)</legend><p class="faint">Optional. Forms that ask get exactly this; "${esc(DECLINE)}" is always fine.</p>${Object.keys(EEO_CHOICES).map(eeo).join('')}</fieldset>
    <div class="ans-save"><button class="btn primary block" type="submit">Save</button></div></form>`;
}
$('answers-body').addEventListener('input', (e) => {   // the filled/empty mark follows typing
  const f = e.target.closest('.ans-field'); const st = f?.querySelector('.ans-st'); if (!st) return;
  const on = !!String(e.target.value || '').trim(); st.classList.toggle('on', on); st.textContent = on ? 'Filled' : 'Empty';
});
$('answers-body').addEventListener('submit', async (e) => {
  e.preventDefault(); const form = e.target; const d = S.answers; if (!d) return;
  const bad = [...form.querySelectorAll('input')].find((i) => !i.checkValidity()); if (bad) { bad.focus(); toast(`Check ${bad.closest('.ans-field')?.querySelector('.ans-label')?.firstChild?.textContent?.trim() || 'that field'}`, { bad: true }); return; }
  const profile = { eeo: {} };
  for (const [, fs] of ANSWER_GROUPS) for (const [k] of fs) profile[k] = form.elements[k].value.trim();
  for (const k of Object.keys(EEO_CHOICES)) profile.eeo[k] = form.elements['eeo-' + k].value;
  const btn = form.querySelector('[type=submit]'); btn.disabled = true; buzz();
  const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'profile-save', profile, hash: d.hash }) });
  btn.disabled = false;
  if (!r.ok) { toast(`Not saved: ${r.error}`, { bad: true }); if (/reload first/.test(r.error || '')) await loadAnswers(); return; }
  S.answers = r.data; renderAnswers(); S.hunt.packets = {}; if ($('hunt-sheet').open) renderHunt();
  toast(r.data.stalePackets ? `Saved. ${r.data.stalePackets} packet${r.data.stalePackets > 1 ? 's need' : ' needs'} a Rebuild.` : 'Saved');
});
function tailorFor(x) {   // the tailor order, filled in with what we know; it runs on this PC only
  const posting = `${x.role} at ${x.company}${x.where ? ' (' + x.where + ')' : ''}${x.link ? '\n' + x.link : ''}${x.fit ? '\n\n' + x.fit : ''}\n\n(Paste the full job posting here for a closer match.)`;
  const d = store.get('drafts', {}); d['tailor.posting'] = posting; store.set('drafts', d);
  S.tailorApp = /^A\d+$/.test(x.id || '') ? x.id : null;   // remembered so the order's job can be linked to this role as its draft
  S.resumeOrder = { recipe: 'tailor', private: true, cook: 'auto' }; closeSheet('hunt-sheet', false); setTimeout(openOrder, 200);
}
// the tailored draft of a tracked role: fit, bullets and cover note, each with a one-tap copy
const DRAFT_PARTS = [['check', 'Tailor check'], ['fit', 'Fit'], ['summary', 'Summary'], ['bullets', 'Targeted bullets'], ['cover', 'Cover note'], ['gaps', 'Gaps']];
async function viewDraft(id) {
  $('draft-body').innerHTML = '<p class="empty-line">Loading…</p>'; openSheet('draft-sheet');
  const r = await api('/api/hunt/draft/' + encodeURIComponent(id));
  if (!r.ok) { S.draft = null; $('draft-body').innerHTML = `<p class="empty-line">${esc(r.status === 404 || /no draft/.test(r.error || '') ? 'No draft yet. It shows here once the tailor work order has finished.' : r.error || 'Could not load.')}</p>`; return; }
  const sec = r.data.sections || {}; const parts = DRAFT_PARTS.filter(([k]) => sec[k]).map(([k, l]) => ({ k, l, text: sec[k] }));
  if (!parts.length) parts.push({ k: 'all', l: 'Draft', text: r.data.text });   // the model used other headings: show it whole
  S.draft = { parts, all: r.data.text };
  const chk = r.data.check, cov = r.data.coverage ? ` Keyword coverage ${esc(r.data.coverage)}.` : '';
  const verdict = chk === 'pass' ? `<p class="faint">Passed the tailor check.${cov}</p>`
    : `<div class="check-bad" role="alert"><b>${chk === 'fail' ? 'This draft failed the tailor check.' : 'This draft has not been checked yet.'}</b>${cov} It is not ready to send: fix it or tailor again.</div>`;
  $('draft-body').innerHTML = verdict + parts.map((p, i) => `<section class="draft-part"><div class="filters"><h3 class="group-label">${esc(p.l)}</h3><button class="text-btn" data-copy-draft="${i}">Copy</button></div><pre class="log wrap">${esc(p.text)}</pre></section>`).join('');
}
async function copyDraft(which) {
  const d = S.draft; if (!d) return;
  const text = which === 'all' ? d.all : d.parts[Number(which)]?.text; if (!text) return;
  try { await navigator.clipboard.writeText(text); buzz(); toast('Copied'); } catch { toast("Couldn't copy here", { bad: true }); }
}
$('draft-sheet').addEventListener('click', (e) => { const c = e.target.closest('[data-copy-draft]'); if (c) copyDraft(c.dataset.copyDraft); });
$('hunt-btn').addEventListener('click', openHunt);
$('hunt-add').addEventListener('click', () => { S.hunt.adding = !S.hunt.adding; renderHunt(); if (S.hunt.adding) $('hunt-body').querySelector('input')?.focus(); });
$('hunt-body').addEventListener('click', async (e) => {
  const t = e.target;
  if (t.closest('[data-open-answers]')) return openAnswers();
  if (t.closest('[data-copy-pk],[data-apply-submit],[data-apply-fill],[data-apply-mark],[data-apply-prep]')) return applyClick(t);
  const hf = t.closest('[data-hf]'); if (hf) { S.hunt.filter = hf.dataset.hf; return renderHunt(); }
  if (t.closest('[data-add-cancel]')) { S.hunt.adding = false; return renderHunt(); }
  const a = t.closest('[data-app]'); if (a) { S.hunt.open = S.hunt.open === a.dataset.app ? null : a.dataset.app; return renderHunt(); }
  const st = t.closest('[data-st]');
  if (st) {
    const x = S.hunt.data?.items?.find((i) => i.id === st.dataset.id); if (!x || x.status === st.dataset.st) return;
    if (!await confirmBox({ title: `Mark ${STATUS_WORD[st.dataset.st].toLowerCase()}?`, html: `<p>${esc(x.role)} at ${esc(x.company)}</p><p>From ${esc((STATUS_WORD[x.status] || x.status).toLowerCase())} to <b>${esc(STATUS_WORD[st.dataset.st].toLowerCase())}</b>. Follow-ups are set again for the new status.</p>`, yes: `Mark ${STATUS_WORD[st.dataset.st].toLowerCase()}`, danger: ['rejected', 'closed'].includes(st.dataset.st) })) return;
    buzz(); return hunt({ op: 'update', id: st.dataset.id, changedAt: changedAt(st.dataset.id), change: { status: st.dataset.st } }, (x) => x.status === 'applied' && x.followUp ? `Applied. Follow-up set for ${shortDate(x.followUp)}` : x.status === 'interview' && x.followUp ? `Interviewing. Thank-you note due ${shortDate(x.followUp)}` : `Marked ${STATUS_WORD[x.status].toLowerCase()}`); }
  const sn = t.closest('[data-save-notes]'); if (sn) return hunt({ op: 'update', id: sn.dataset.saveNotes, changedAt: changedAt(sn.dataset.saveNotes), change: { notes: $('hunt-body').querySelector(`[data-notes="${sn.dataset.saveNotes}"]`).value } }, 'Notes saved');
  const lf = t.closest('[data-log-fu]');
  if (lf) {   // sends the notes box too, so unsaved typing is kept
    const id = lf.dataset.logFu; buzz(); lf.disabled = true;
    const r = await hunt({ op: 'follow-up', id, changedAt: changedAt(id), notes: $('hunt-body').querySelector(`[data-notes="${id}"]`).value },
      (x) => x.followUp ? `Logged. Next follow-up ${shortDate(x.followUp)}` : 'Logged. No more follow-ups to send');
    if (!r.ok) lf.disabled = false;
    return;
  }
  const inApp = t.closest('[data-inspect-app]');
  if (inApp) {
    const id = inApp.dataset.inspectApp;
    inApp.disabled = true; inApp.classList.add('busy'); inApp.textContent = 'Inspecting…';
    const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'inspect', id }) });
    inApp.disabled = false; inApp.classList.remove('busy'); inApp.textContent = 'Inspect';
    if (!r.ok) {
      if (r.error === 'not supported') {
        toast('Not supported: only Greenhouse, Lever, and Ashby postings can be inspected.', { bad: true });
      } else {
        toast(`Inspection failed: ${r.error}`, { bad: true });
      }
      return;
    }
    const count = (r.data?.questions || []).length;
    toast(`Inspected: found ${count} question${count === 1 ? '' : 's'}`);
    await loadHunt();
    return;
  }
  const ta = t.closest('[data-tailor-app]'); if (ta) return tailorFor(S.hunt.data.items.find((x) => x.id === ta.dataset.tailorApp));
  const vd = t.closest('[data-view-draft]'); if (vd) return viewDraft(vd.dataset.viewDraft);
  const ts = t.closest('[data-tailor-scout]'); if (ts) return tailorFor(S.hunt.fresh[Number(ts.dataset.tailorScout)]);
  const ss = t.closest('[data-save-scout]'); if (ss) { const o = S.hunt.fresh[Number(ss.dataset.saveScout)]; buzz(); return hunt({ op: 'add', item: { ...o, notes: o.fit, source: 'scout' } }, `Saved ${o.company}`); }
  const ap = t.closest('[data-apply-scout]'); if (ap) { const o = S.hunt.fresh[Number(ap.dataset.applyScout)]; buzz(); ap.disabled = true; return hunt({ op: 'add', item: { ...o, notes: o.fit, source: 'scout', status: 'applied' } }, (x) => `Applied to ${o.company}. Follow-up set for ${shortDate(x.followUp)}`); }
  const pa = t.closest('[data-pack-app]');
  if (pa) {
    buzz();
    pa.disabled = true;
    const r = await api('/api/hunt', { method: 'POST', body: JSON.stringify({ op: 'pack', id: pa.dataset.packApp }) });
    if (r.ok && r.data?.job) toast(`${ticket(r.data.job)} is building on this PC`, { action: { label: 'Open', fn: () => go('#/job/' + r.data.job) } });
    else if (r.ok) toast('Application pack queued');
    else { pa.disabled = false; toast(`Not started: ${r.error}`, { bad: true }); }
    return;
  }
  const ca = t.closest('[data-copy-answers]');
  if (ca) {
    buzz();
    const r = await api(`/api/hunt/answers?id=${encodeURIComponent(ca.dataset.copyAnswers)}`);
    if (r.ok && r.data?.answers) {
      try { await navigator.clipboard.writeText(r.data.answers); toast('Answers copied'); } catch { toast("Couldn't copy here", { bad: true }); }
    } else {
      toast(r.error || 'No answers found', { bad: true });
    }
    return;
  }
});
$('hunt-body').addEventListener('change', (e) => { const fu = e.target.closest('[data-fu]'); if (fu) hunt({ op: 'update', id: fu.dataset.fu, changedAt: changedAt(fu.dataset.fu), change: { followUp: fu.value } }, fu.value ? `Follow-up set for ${shortDate(fu.value)}` : 'Follow-up cleared'); });
$('hunt-body').addEventListener('submit', async (e) => {
  e.preventDefault(); const f = new FormData(e.target); const item = Object.fromEntries(f.entries());
  const r = await hunt({ op: 'add', item }, `Added ${item.company}`); if (r.ok) { S.hunt.adding = false; renderHunt(); }
});

// ---------- ideas: how the kitchen improves itself (research teams and the coach file ideas, the autopilot builds, you merge) ----------
const IDEA_WORD = { new: 'Waiting', building: 'Building', merged: 'Merged', failed: 'Failed', dropped: 'Dropped' };
S.ideas = { data: null, adding: false, filter: 'open' };
async function openIdeas() { openSheet('ideas-sheet'); if (!S.ideas.data) $('ideas-body').innerHTML = '<p class="empty-line">Loading…</p>'; await loadIdeas(); }
async function loadIdeas() { const r = await api('/api/ideas'); if (r.ok) S.ideas.data = r.data; renderIdeas(r.ok ? '' : r.error); }
function renderIdeas(err) {
  const d = S.ideas.data; if (!d) { $('ideas-body').innerHTML = `<p class="empty-line fault">${esc(err || 'Could not load.')}</p>`; return; }
  const open = (x) => ['new', 'building', 'failed'].includes(x.status);
  const items = d.items.filter((x) => S.ideas.filter === 'all' || open(x)).sort((a, b) => (open(b) - open(a)) || ((b.status === 'building') - (a.status === 'building')) || (Number(b.score || 0) - Number(a.score || 0)));
  const add = S.ideas.adding ? `<form class="hunt-add" id="idea-form"><label class="hunt-field">Name<input name="title" maxlength="120" required placeholder="e.g. Dark mode toggle"></label>
    <label class="hunt-field">What should it do?<textarea name="goal" maxlength="1400" rows="4" required placeholder="Plain words are fine. Name the screen or file if you know it."></textarea></label>
    <label class="hunt-field">Size<select name="size"><option value="S">Small</option><option value="M" selected>Medium</option><option value="L">Large (built only when you tap Build)</option></select></label>
    <div class="prop-actions"><button class="btn" type="button" data-idea-cancel>Cancel</button><button class="btn primary" type="submit">Add idea</button></div></form>` : '';
  $('ideas-body').innerHTML = `${add}
    <div class="ap-line ap-card${d.paused ? ' paused' : ''}"><span><span class="ap-dot" aria-hidden="true"></span>${d.paused ? '<b>Autopilot paused.</b>' : `<b>Autopilot on.</b> ${Number(d.builtToday)} built today.`} It builds ideas on your Google plan; every change waits for your sign-off.<span class="ap-meter" aria-hidden="true"><i data-css="width:${Math.min(100, Math.round(100 * (d.builtToday || 0) / 40))}%"></i></span></span>
      <button class="btn" data-ap="${d.paused ? 'resume' : 'pause'}">${d.paused ? 'Resume' : 'Pause'}</button></div>
    <div class="ap-line"><span>Send a research team to look for new upgrades.</span><button class="btn" data-research>Research</button></div>
    <div class="filters"><div class="seg" role="radiogroup" aria-label="Show">${[['open', 'Open'], ['all', 'All']].map(([k, l]) => `<button role="radio" aria-checked="${S.ideas.filter === k}" data-if="${k}">${l}</button>`).join('')}</div></div>
    ${items.length ? `<ul class="hunt-list">${items.map((x) => `<li class="hunt-row"><div class="hunt-main"><span class="hunt-title"><b>${esc(cap(unslug(String(x.title || ''))))}</b><span class="hunt-st${x.status === 'building' ? ' st-interview' : ''}">${esc(IDEA_WORD[x.status] || x.status)}</span></span>
      <span class="hunt-sub">${esc(x.size === 'S' ? 'Small' : x.size === 'L' ? 'Large' : 'Medium')} · from ${esc(x.source || 'the Yard')}${x.at ? ' · ' + esc(ago(x.at)) : ''}</span>
      ${x.why ? `<span class="hunt-fit">${esc(x.why)}</span>` : ''}<details class="idea-goal"><summary>The goal</summary><p>${esc(x.goal)}</p>${x.link ? `<a href="${esc(x.link)}" target="_blank" rel="noopener noreferrer">Source</a>` : ''}</details></div>
      <div class="prop-actions">${x.job ? `<a class="btn" href="#/job/${esc(x.job)}">${ticket(x.job)}</a>` : ''}${['new', 'failed'].includes(x.status) ? `<button class="btn" data-idea-drop="${esc(x.id)}">Drop</button><button class="btn primary" data-idea-build="${esc(x.id)}">Build now</button>` : ''}</div></li>`).join('')}</ul>`
      : `<p class="empty-line">${d.items.length ? 'Nothing open.' : 'No ideas yet. The research teams file them; you can add your own.'}</p>`}`;
}
async function ideasPost(body, ok) { const r = await api('/api/ideas', { method: 'POST', body: JSON.stringify(body), timeout: 90000 }); if (!r.ok) { toast(`Not done: ${r.error}`, { bad: true }); return r; } if (ok) toast(ok); await loadIdeas(); return r; }
$('ideas-add').addEventListener('click', () => { S.ideas.adding = !S.ideas.adding; renderIdeas(); if (S.ideas.adding) $('ideas-body').querySelector('input')?.focus(); });
$('ideas-body').addEventListener('click', async (e) => {
  const t = e.target;
  const f = t.closest('[data-if]'); if (f) { S.ideas.filter = f.dataset.if; return renderIdeas(); }
  if (t.closest('[data-idea-cancel]')) { S.ideas.adding = false; return renderIdeas(); }
  const ap = t.closest('[data-ap]'); if (ap) return ideasPost({ op: ap.dataset.ap }, ap.dataset.ap === 'pause' ? 'Autopilot paused' : 'Autopilot on');
  const dr = t.closest('[data-idea-drop]'); if (dr) return ideasPost({ op: 'drop', id: dr.dataset.ideaDrop }, 'Dropped');
  const bu = t.closest('[data-idea-build]'); if (bu) {
    if (!await confirmBox({ title: 'Build this now?', html: '<p>The Dispatcher plans it, a crew builds it on its own branch, the tests run and the Inspector checks it, on your Google plan. It merges only when you sign off.</p>', yes: 'Build it' })) return;
    const r = await ideasPost({ op: 'build', id: bu.dataset.ideaBuild }); if (r.ok && r.job) toast(`${ticket(r.job)} is queued`, { action: { label: 'Open', fn: () => go('#/job/' + r.job) } });
  }
  if (t.closest('[data-research]')) {
    const focus = prompt('What should the research team look into?', 'new ideas to make the Board more useful day to day');
    if (focus && focus.trim().length >= 8) { const r = await ideasPost({ op: 'research', focus: focus.trim() }); if (r.ok && r.data?.job) toast(`${ticket(r.data.job)}: the research team is on it`); }
  }
});
$('ideas-body').addEventListener('submit', async (e) => {
  e.preventDefault(); const it = Object.fromEntries(new FormData(e.target).entries());
  const r = await ideasPost({ op: 'add', ...it }, 'Idea added. The autopilot picks yours first.'); if (r.ok) { S.ideas.adding = false; renderIdeas(); }
});

// ---------- ledger: the one true list of every idea, order and roadmap item, from proof (kitchen/ledger.ps1), and the watchers ----------
S.ledger = { data: null, filter: 'you', err: '' };
const LG_WORD = { 'waiting-on-jordan': 'Waits on you', lost: 'Lost', claimed: 'Claimed, no proof', stuck: 'Stuck', moving: 'Moving', 'not-started': 'Not started', shipped: 'Shipped', dropped: 'Dropped', replaced: 'Replaced' };
const LG_HOT = new Set(['waiting-on-jordan', 'lost', 'claimed', 'stuck']);
const LG_FILTERS = [['you', 'Needs you', (x) => x.state === 'waiting-on-jordan' || (x.jordans && !['shipped', 'dropped'].includes(x.state))],
  ['lost', 'Lost', (x) => x.state === 'lost' || x.state === 'claimed'], ['stuck', 'Stuck', (x) => x.state === 'stuck'], ['moving', 'Moving', (x) => x.state === 'moving'],
  ['waiting', 'Not started', (x) => x.state === 'not-started'], ['shipped', 'Shipped', (x) => x.state === 'shipped']];
async function loadLedger() { const r = await api('/api/ledger'); if (r.ok) { S.ledger.data = r.data; S.ledger.err = ''; } else S.ledger.err = r.error || 'Could not load.'; renderLedgerCount(); if (S.view === 'ledger') renderLedger(); }
function renderLedgerCount() {
  const c = $('count-ledger'); const d = S.ledger.data; if (!c || !d) return;
  const n = (d.alarms?.length || 0) + (d.counts?.waitingOnJordan || 0) + (d.flags || []).filter((f) => f.owner === 'Jordan' && f.rule !== 'waiting-on-you').length;
  c.hidden = !n; c.textContent = n; c.classList.toggle('bad', !!d.alarms?.length);
}
function renderLedger() {
  const d = S.ledger.data; const el = $('ledger-body');
  if (!d) { el.innerHTML = `<p class="empty-line${S.ledger.err ? ' fault' : ''}">${esc(S.ledger.err || 'Loading…')}</p>`; return; }
  const c = d.counts || {}; const f = LG_FILTERS.find((x) => x[0] === S.ledger.filter) || LG_FILTERS[0];
  const items = d.items.filter(f[2]);
  const alarm = d.alarms?.length ? `<div class="lg-alarm" role="alert"><b>Something that watches the Yard is not working</b>${d.alarms.map((a) => `<div>${esc(a)}</div>`).join('')}</div>` : '';
  const late = (d.watch || []).flatMap((w) => w.problems || []);
  const ok = `<p class="lg-ok">${d.paused ? 'Yard paused by you. ' : ''}Ledger built ${esc(d.ledgerMinutesAgo == null ? 'never' : d.ledgerMinutesAgo + ' min ago')} · tick ${esc(d.tickMinutesAgo == null ? '?' : d.tickMinutesAgo + ' min ago')} · ${(d.watch || []).length} watchers${late.length ? ` · <b>${late.length} watch finding${late.length > 1 ? 's' : ''}</b>` : ', all on time'}</p>`;
  const counts = [['you', c.waitingOnJordan + (c.yourIdeasOpen || 0), 'need you'], ['lost', (c.lost || 0) + (c.claimed || 0), 'lost or unproven'], ['stuck', c.stuck || 0, 'stuck'],
    ['moving', c.moving || 0, 'moving'], ['waiting', c.notStarted || 0, 'not started'], ['shipped', c.shipped || 0, 'shipped']]
    .map(([k, n, l]) => `<button class="lg-count${['you', 'lost', 'stuck'].includes(k) && n ? ' hot' : ''}" data-lg-f="${k}" aria-pressed="${S.ledger.filter === k}"><b>${Number(n) || 0}</b><span>${esc(l)}</span></button>`).join('');
  const progs = (d.programs || []).map((p) => `<div class="lg-prog">${esc(p.repo)}: ${Number(p.shipped)} of ${Number(p.total)} shipped${p.stuck ? `, ${Number(p.stuck)} stuck` : ''}<i><u data-css="width:${p.total ? Math.round(100 * p.shipped / p.total) : 0}%"></u></i></div>`).join('');
  const watchList = late.length ? `<details class="lg-prog"><summary>What the watchers found</summary><ul>${late.map((p) => `<li>${esc(p)}</li>`).join('')}</ul></details>` : '';
  const row = (x) => `<li class="lg-row"><div class="t"><b>${esc(cap(unslug(String(x.title || x.id))))}</b><span class="st${LG_HOT.has(x.state) ? ' hot' : ''}">${esc(LG_WORD[x.state] || x.state)}</span></div>
    <div class="why">${esc(x.id)} · ${esc(x.kind)}${x.from ? ' · from ' + esc(x.from) : ''}${x.ageDays != null ? ' · ' + esc(String(x.ageDays)) + ' d' : ''}${x.why ? ' · ' + esc(x.why) : ''}</div>
    ${x.proof ? `<div class="why">Proof: ${esc(x.proof)}</div>` : ''}
    ${x.chain?.length ? `<details><summary>History (${x.chain.length})</summary><ol>${x.chain.map((s) => `<li><a href="#/job/${esc(s.id)}">${esc(s.id)}</a> ${esc(s.status)}${s.proof ? ' · ' + esc(s.proof) : ''}${s.note ? ' · ' + esc(s.note) : ''}${s.replacedBy ? ' → ' + esc(s.replacedBy) : ''}</li>`).join('')}</ol></details>` : ''}
    ${x.kind === 'idea' && ['lost', 'claimed', 'not-started'].includes(x.state) ? `<div class="acts">${x.listed === 'new' || x.listed === 'failed' ? `<button class="btn primary" data-lg-build="${esc(x.id)}">Build again</button>` : ''}<button class="btn" data-lg-drop="${esc(x.id)}">Drop</button></div>` : ''}
    ${x.kind === 'order' && x.chain?.length ? `<div class="acts"><a class="btn" href="#/job/${esc(x.chain.at(-1).id)}">Open ${esc(x.chain.at(-1).id)}</a></div>` : ''}</li>`;
  el.innerHTML = `${alarm}${ok}<div class="lg-counts">${counts}</div><div class="lg-progs">${progs}${watchList}</div>
    ${items.length ? `<ul class="lg-list">${items.map(row).join('')}</ul>` : `<p class="empty-line">Nothing here.</p>`}`;
}
$('ledger-body').addEventListener('click', async (e) => {
  const t = e.target;
  const f = t.closest('[data-lg-f]'); if (f) { S.ledger.filter = f.dataset.lgF; return renderLedger(); }
  const dr = t.closest('[data-lg-drop]'); if (dr) { if (!await confirmBox({ title: 'Drop this idea?', html: '<p>It stays in the list as dropped by you. Nothing is deleted.</p>', yes: 'Drop it' })) return; await ideasPost({ op: 'drop', id: dr.dataset.lgDrop }, 'Dropped'); return loadLedger(); }
  const bu = t.closest('[data-lg-build]'); if (bu) {
    if (!await confirmBox({ title: 'Build this again?', html: '<p>A fresh work order is built from today\'s main, on your plans. It merges only when you say yes.</p>', yes: 'Build it' })) return;
    const r = await ideasPost({ op: 'build', id: bu.dataset.lgBuild }); if (r.ok && r.job) toast(`${ticket(r.job)} is queued`); return loadLedger();
  }
});
loadLedger(); setInterval(loadLedger, 120000);

// ---------- clients: income leads (the lead scout finds people hiring; the PC's own model drafts a pitch; you copy it and send it yourself) ----------
S.clients = { data: null, filter: 'new' };
const LEAD_WORD = { new: 'New', sent: 'Sent', skipped: 'Skipped', won: 'Won' };
async function openClients() { openSheet('clients-sheet'); if (!S.clients.data) $('clients-body').innerHTML = '<p class="empty-line">Loading…</p>'; await loadClients(); }
async function loadClients() { const r = await api('/api/clients'); if (r.ok) S.clients.data = r.data; renderClients(r.ok ? '' : r.error); }
function renderClients(err) {
  const d = S.clients.data; if (!d) { $('clients-body').innerHTML = `<p class="empty-line fault">${esc(err || 'Could not load.')}</p>`; return; }
  const f = S.clients.filter;
  const items = d.items.filter((x) => f === 'all' || (f === 'new' ? x.status === 'new' : ['sent', 'won'].includes(x.status))).slice().reverse();
  $('clients-body').innerHTML = `${err ? `<p class="empty-line fault">${esc(err)}</p>` : ''}
    <div class="ap-line"><span>${d.scouting ? '<b>Looking for leads now…</b>' : 'Every night the scout finds people hiring for AI and automation work. Your PC writes a pitch for each; you send it.'}</span><button class="btn" data-cl-scout${d.scouting ? ' disabled' : ''}>Find leads</button></div>
    ${d.offer ? '' : '<p class="empty-line">Tip: your services and prices live in projects/income/OFFER.md; the pitches follow it.</p>'}
    <div class="filters"><div class="seg" role="radiogroup" aria-label="Show">${[['new', 'New'], ['sent', 'Sent and won'], ['all', 'All']].map(([k, l]) => `<button role="radio" aria-checked="${f === k}" data-clf="${k}">${l}</button>`).join('')}</div></div>
    ${items.length ? `<ul class="hunt-list">${items.map((x) => `<li class="hunt-row"><div class="hunt-main"><span class="hunt-title"><b>${esc(x.title)}</b><span class="hunt-st${x.status === 'won' ? ' st-interview' : ''}">${esc(LEAD_WORD[x.status] || x.status)}</span></span>
      <span class="hunt-sub">${[x.source, x.budget && !/^not listed$/i.test(x.budget) ? x.budget : '', x.posted].filter(Boolean).map(esc).join(' · ')}</span>
      ${x.need ? `<span class="hunt-fit">${esc(x.need)}</span>` : ''}
      <details class="idea-goal"${x.status === 'new' ? ' open' : ''}><summary>Pitch${x.pitch ? '' : ' (being written)'}</summary>${x.pitch ? `<textarea class="cl-pitch" data-cl-text="${esc(x.id)}" rows="7" maxlength="3000">${esc(x.pitch)}</textarea>` : '<p>Your PC writes it on the next run.</p>'}</details></div>
      <div class="prop-actions">${x.pitch && x.link ? `<button class="btn primary" data-cl-go="${esc(x.id)}">Copy and open</button>` : x.link ? `<a class="btn" href="${esc(x.link)}" target="_blank" rel="noopener noreferrer">Open</a>` : ''}
        ${x.status === 'new' ? `<button class="btn" data-cl-mark="sent" data-id="${esc(x.id)}">Sent</button><button class="btn" data-cl-mark="skipped" data-id="${esc(x.id)}">Skip</button>` : ''}
        ${x.status === 'sent' ? `<button class="btn primary" data-cl-mark="won" data-id="${esc(x.id)}">Won it</button>` : ''}
        ${x.status !== 'new' ? `<button class="btn" data-cl-mark="new" data-id="${esc(x.id)}">Back to new</button>` : ''}</div></li>`).join('')}</ul>`
      : `<p class="empty-line">${d.items.length ? 'Nothing here.' : 'No leads yet. Tap Find leads, or wait for tonight’s run.'}</p>`}`;
}
async function clientsPost(body, ok) { const r = await api('/api/clients', { method: 'POST', body: JSON.stringify(body), timeout: 90000 }); if (!r.ok) { toast(`Not done: ${r.error || 'error'}`, { bad: true }); return r; } buzz(); if (ok) toast(ok); await loadClients(); return r; }
async function clientsSaveEdit(id) {   // your own edit of a draft is saved before it is copied or marked
  const ta = $('clients-body').querySelector(`[data-cl-text="${CSS.escape(id)}"]`); const x = S.clients.data?.items.find((i) => i.id === id);
  if (ta && x && ta.value.trim() !== x.pitch.trim() && ta.value.trim().length >= 10) { const r = await api('/api/clients', { method: 'POST', body: JSON.stringify({ op: 'pitch', id, text: ta.value }) }); if (r.ok) x.pitch = ta.value.trim(); else toast(`Edit not saved: ${r.error}`, { bad: true }); }
  return ta ? ta.value.trim() : (x?.pitch || '');
}
$('clients-body').addEventListener('click', async (e) => {
  const t = e.target;
  const f = t.closest('[data-clf]'); if (f) { S.clients.filter = f.dataset.clf; return renderClients(); }
  if (t.closest('[data-cl-scout]')) { const r = await clientsPost({ op: 'scout' }); if (r.ok) toast('The lead scout is on it. New leads show up here.'); return; }
  const go = t.closest('[data-cl-go]'); if (go) {
    const id = go.dataset.clGo; const x = S.clients.data?.items.find((i) => i.id === id); if (!x) return;
    const text = await clientsSaveEdit(id);
    try { await navigator.clipboard.writeText(text); buzz(); toast('Pitch copied. Paste it in your reply, then tap Sent.'); } catch { toast("Couldn't copy here", { bad: true }); }
    window.open(x.link, '_blank', 'noopener,noreferrer'); return;
  }
  const m = t.closest('[data-cl-mark]'); if (m) { if (m.dataset.clMark === 'sent') await clientsSaveEdit(m.dataset.id); return clientsPost({ op: 'mark', id: m.dataset.id, status: m.dataset.clMark }, m.dataset.clMark === 'won' ? 'Nice. Marked as won.' : ''); }
});
// ---------- the morning brief (shown on the pass in the morning; tap "Brief" any time) ----------
async function loadBrief() { const r = await api('/api/brief' + (S.sinceFrom ? '?since=' + encodeURIComponent(S.sinceFrom) : '')); if (r.ok) { S.brief = r.data; store.set('lastBrief', r.data); if (S.view === 'pass') renderBrief(); } }
// ---------- Since You Looked: this phone keeps the moment Chef last went out of sight (chef.lastSeen); the strip under the headline
// counts what moved since then from the server (/api/since). The moment is taken when Chef opens, so the strip holds still while open.
S.sinceFrom = store.get('lastSeen', null);
function markSeen() { store.set('lastSeen', new Date().toISOString()); }
document.addEventListener('visibilitychange', () => { if (document.hidden) markSeen(); else { S.sinceFrom = store.get('lastSeen', null); loadSince(); } });   // before the brief's own listener below
window.addEventListener('pagehide', markSeen);
async function loadSince() {
  if (!S.sinceFrom) { S.since = { first: true }; return renderSince(); }
  const r = await api('/api/since?t=' + encodeURIComponent(S.sinceFrom)); S.since = r.ok ? r.data : null; renderSince();
}
function sinceSoon() { clearTimeout(S.sinceT); S.sinceT = setTimeout(loadSince, 1500); }
function renderSince() {
  const el = $('since'); if (!el) return; const v = S.since; const text = sinceText(v);
  if (!text) { el.innerHTML = ''; return; }
  const groups = v && v.known ? [[STATUS_LABEL.done, v.plated], [STATUS_LABEL.quarantined, v.setAside], [STATUS_LABEL['waiting-approval'], v.needsYou]].filter(([, a]) => a?.length) : [];
  el.innerHTML = groups.length
    ? `<details class="since-strip"><summary>${esc(text)}</summary>${groups.map(([h, a]) => `<p><b>${h}:</b> ${a.map(jobLink).join(' ')}</p>`).join('')}</details>`
    : `<p class="since-strip faint">${esc(text)}</p>`;
}
// the stuck-loop alarm on the Pass, the chip on a stuck order's row, and the Retry label that says why
function stuckAlarm(jobs) {
  const st = jobs.filter((j) => j.stuck).sort((a, b) => parseInt(a.id.slice(1)) - parseInt(b.id.slice(1))); if (!st.length) return '';
  return `<div class="stuck-alarm" role="status">${st.map((j) => `<a href="#/job/${j.id}"><b>${esc(stuckText(j.id, j.stuck))}</b>${j.stuck.detail ? `<small>${esc(reason(j.stuck.kind + ': ' + j.stuck.detail))}</small>` : ''}</a>`).join('')}</div>`;
}
const stuckChip = (j) => (j.stuck ? `<span class="chip-stuck">stuck ×${Number(j.stuck.times)}</span>` : '');
function retryLabel(j) {
  const base = isOldRecipe(j) ? 'Order it again (current spec)' : 'Retry'; const why = retryWhy(j, reason);
  return why ? `${base}<small class="btn-why">${esc(why)}</small>` : base;
}
function briefSinceLines(b, lines) {
  if (b.since) lines.push(`<li><b>${esc(sinceText(b.since))}</b></li>`);
  for (const x of b.stuck || []) lines.push(`<li class="bad"><a href="#/job/${esc(x.id)}">${esc(stuckText(x.id, x.stuck))}</a></li>`);
}
function renderBrief() {
  const b = S.brief; const el = $('brief'); const h = new Date().getHours();
  const seen = store.get('briefSeen', '') === new Date().toDateString();
  if (!b || (!S.briefOpen && (seen || h < 5 || h >= 13))) { el.innerHTML = ''; return; }
  // glanceable: count chips first, then at most 3 orders per group (plain names), then "and N more"
  const item = (x, extra = '') => `<li><a class="brief-row" href="#/job/${esc(x.id)}"><span class="mono">${ticket(x.id)}</span><span class="t">${esc(nameOf(x).text)}</span></a>${extra}</li>`;
  const group = (cls, head, list, more, extra) => list.length ? `<div class="brief-group ${cls}"><h3>${head}</h3><ul>${list.slice(0, 3).map((x) => item(x, extra ? extra(x) : '')).join('')}</ul>${list.length > 3 ? `<a class="brief-more" href="#/pass" ${more}>and ${list.length - 3} more</a>` : ''}</div>` : '';
  const am = new Set((b.autoMerged || []).map((x) => x.id));
  const chips = [
    b.needsYou.length ? `<a class="chip hot" href="#/pass" data-jump="needs"><b>${b.needsYou.length}</b> need sign-off</a>` : '',
    b.plated.length ? `<a class="chip ok" href="#/pass" data-jump="plated"><b>${b.plated.length}</b> ${STATUS_LABEL.done.toLowerCase()}</a>` : '',
    am.size ? `<span class="chip"><b>${am.size}</b> on their own</span>` : '',
    b.setAside.length ? `<a class="chip bad" href="#/pass" data-jump="aside"><b>${b.setAside.length}</b> ${STATUS_LABEL.quarantined.toLowerCase()}</a>` : '',
  ].filter(Boolean).join('');
  const groups = [
    group('hot', 'Waiting for your sign-off', b.needsYou, 'data-jump="needs"'),
    group('', 'Merged on their own', b.autoMerged || [], 'data-jump="plated"', (x) => `<button class="text-btn" data-undo="${esc(x.id)}">Undo</button>`),
    group('', STATUS_LABEL.done, b.plated.filter((x) => !am.has(x.id)), 'data-jump="plated"'),
    group('bad', STATUS_LABEL.quarantined, b.setAside, 'data-jump="aside"'),
  ].join('');
  const lines = [];
  briefSinceLines(b, lines);
  if (b.packs?.length) lines.push(`<li class="hot"><b>${b.packs.length} pack${b.packs.length > 1 ? 's' : ''} ready to review:</b> ${b.packs.map((p) => `<a href="${esc(p.link || '#/hunt')}" target="_blank" rel="noopener noreferrer">${esc(p.company)} (${esc(p.role)})</a>`).join(', ')} <button class="text-btn" data-brief-hunt>Review</button></li>`);
  if (b.packsNeedLook?.length) lines.push(`<li class="bad"><b>${b.packsNeedLook.length} draft${b.packsNeedLook.length > 1 ? 's' : ''} not ready (${b.packsNeedLook.some((p) => p.check === 'fail') ? 'failed the tailor check' : 'not checked yet'}):</b> ${b.packsNeedLook.map((p) => `${esc(p.company)} (${esc(p.role)})${p.check === 'fail' ? ` · <span class="prot-mark">failed${p.coverage ? ' · ' + esc(p.coverage) : ''}</span>` : ''}`).join(', ')} <button class="text-btn" data-brief-hunt>Look</button></li>`);
  if (b.followUps.length) lines.push(`<li class="hot"><b>Follow up:</b> ${b.followUps.map((x) => `${esc(x.company)} (${esc(x.role)})${x.when ? ` · ${esc(x.when)}` : ''}`).join(', ')} <button class="text-btn" data-brief-hunt>Open</button></li>`);
  if (b.upcoming?.length) lines.push(`<li><b>Coming up:</b> ${b.upcoming.map((x) => `${esc(x.company)} (${esc(x.role)}) · ${esc(x.when)}`).join(', ')} <button class="text-btn" data-brief-hunt>Open</button></li>`);
  if (b.newRoleCount) lines.push(`<li><b>${Number(b.newRoleCount)} new role${b.newRoleCount > 1 ? 's' : ''} from the scout:</b> ${b.newRoles.slice(0, 3).map((x) => `${esc(x.role)} at ${esc(x.company)}`).join('; ')} <button class="text-btn" data-brief-hunt>See them</button></li>`);
  if (b.applied || b.interviews) lines.push(`<li>Job hunt: ${Number(b.applied)} applied${b.interviews ? `, ${Number(b.interviews)} interviewing` : ''}.</li>`);
  if (b.lobe?.skipped) { const lobeLine = briefLobeLine(b.lobe); if (lobeLine) lines.push(lobeLine); }   // ZG-13: a missing or stale frame is red, with why
  const wl = worldLine({ ...b.lobe, skips: b.lobeSkips }); if (wl) lines.push(`<li${b.lobe?.decisionsReady > 0 ? ' class="hot"' : ''}><b>World:</b> ${esc(wl.slice(7))} <a class="text-btn" href="#/world">Open</a></li>`);   // ZG-17: counts only; all zero is no line
  lines.push(`<li class="faint">${b.live ? 'AI crews on' : 'AI crews off'}${b.plan ? ` · Claude plan ${Math.round(100 * b.plan.five)}% of 5 hours, ${Math.round(100 * b.plan.week)}% of the week` : ''}</li>`);
  const hello = h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  el.innerHTML = `<section class="brief" aria-labelledby="brief-h"><div class="brief-head"><h2 id="brief-h">${hello}, Jordan</h2>${speechOK() ? `<button class="icon-btn listen-btn" data-listen="brief" aria-pressed="${speaker.key === 'brief'}" aria-label="Listen to the brief"><svg aria-hidden="true"><use href="#i-speaker"/></svg></button>` : ''}<button class="text-btn" data-brief-done>Got it</button></div>
    <p class="faint brief-sub">${chips || lines.length > 1 ? 'Since last night' : 'A quiet night.'}</p>${chips ? `<div class="brief-chips">${chips}</div>` : ''}${groups}<ul class="brief-list">${lines.join('')}</ul></section>`;
}
$('brief').addEventListener('click', (e) => {
  if (e.target.closest('[data-brief-done]')) { store.set('briefSeen', new Date().toDateString()); S.briefOpen = false; renderBrief(); }
  if (e.target.closest('[data-brief-hunt]')) openHunt();
  if (e.target.closest('[data-listen]') && S.brief) speaker.toggle(briefSpeech(S.brief, new Date().getHours() < 12 ? 'Good morning' : new Date().getHours() < 18 ? 'Good afternoon' : 'Good evening', (x) => nameOf(x).text), 'brief');
  const jump = e.target.closest('[data-jump]');
  if (jump) { e.preventDefault(); if (jump.dataset.jump === 'plated' && !S.showPlated) { S.showPlated = true; S.sig.pass = ''; renderAll(); } $('sec-' + jump.dataset.jump)?.scrollIntoView({ behavior: 'smooth' }); }
  const u = e.target.closest('[data-undo]');
  if (u) { (async () => { if (!await confirmBox({ title: `Undo ${ticket(u.dataset.undo)}?`, html: '<p>This adds a change that reverses it. Nothing is deleted; you can order it again.</p>', yes: 'Undo it' })) return; const r = await act({ op: 'undo-merge', id: u.dataset.undo }, { btn: u, ok: `Undid ${ticket(u.dataset.undo)}` }); if (r.ok) loadBrief?.(); })(); }
});
setInterval(() => { if (!document.hidden) loadBrief(); }, 600000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) loadBrief(); });

// ---------- push alerts (ntfy): set up from Settings ----------
async function pushSetup() {
  const p = await api('/api/push'); if (!p.ok) return toast(p.error, { bad: true });
  const how = (topic) => `<ol class="how"><li>Install the free <b>ntfy</b> app (Play Store).</li><li>Tap <b>+</b>, then subscribe to this topic:<div class="quote mono">${esc(topic)}</div></li><li>Leave the server as ntfy.sh.</li></ol>`;
  if (!p.data.on) {
    if (!await confirmBox({ title: 'Turn on push alerts?', html: `<p>Your phone gets an alert even when the Board is closed: a work order needs your sign-off, something failed, the Yard answered you, the morning brief is ready.</p><p>Alerts go through <b>ntfy.sh</b>, a free public service. Only short words are sent (like “J12 needs your yes”), never what a work order or a chat says. The topic is a random name only you know.</p>`, yes: 'Turn on' })) return;
    const r = await act({ op: 'push-on' }); if (!r.ok) return;
    if (await confirmBox({ title: 'Last step on your phone', html: how(r.data.topic), yes: 'Send a test' })) await act({ op: 'push-test' }, { ok: 'Test sent. It should arrive in a few seconds.' });
  } else if (await confirmBox({ title: 'Push alerts are on', html: how(p.data.topic) + '<p>Turn them off any time; the Yard keeps working the same.</p>', yes: 'Turn off', danger: true })) await act({ op: 'push-off' }, { ok: 'Push alerts are off' });
  openSettings();
}

// ---------- settings ----------
async function openSettings() {
  const s = S.state || {}; const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  $('menu-body').innerHTML = `
    <div class="set-group">
      <label class="switch-row" data-css="margin:0;border-top:0"><span><b>AI crews</b><small>${s.live ? 'On. AI steps really run on your plans.' : "Off. AI steps only show what they'd do."}</small></span><input type="checkbox" role="switch" id="live-switch" ${s.live ? 'checked' : ''}><i aria-hidden="true"></i></label>
      <button class="set-row" data-set="lead-toggle"><i class="set-ic" aria-hidden="true">☾</i><span>${s.lead?.mode === 'away' ? 'Claude is back' : 'Claude is out'}<small>${s.lead?.mode === 'away' ? 'Ends away mode now' : 'Shows the away card until the weekly reset'}${s.lead?.week ? ` · week ${Math.round(100 * s.lead.week)}% used` : ''}</small></span></button>
      <button class="set-row" data-set="tick"><i class="set-ic" aria-hidden="true">↻</i><span>Run the supervisor now<small>One pass: checks every work order and starts what's next</small></span></button>
      <button class="set-row" data-set="doctor"><i class="set-ic" aria-hidden="true">✚</i><span>Run the doctor<small>Self-check, backups, damaged files</small></span></button>
      <button class="set-row" data-set="push"><i class="set-ic" aria-hidden="true">◉</i><span>Push alerts<small>${s.push ? 'On: alerts reach your phone even when the Board is closed.' : 'Off. Get alerts even when the Board is closed (free ntfy app).'}</small></span></button>
      ${s.push ? '<button class="set-row" data-set="push-test"><span>Send a test push</span></button>' : ''}
      <button class="set-row" data-set="notify"><i class="set-ic" aria-hidden="true">◔</i><span>Phone alerts<small>${perm === 'granted' ? 'On while the Board is open in the background (only the work-order number, never the words). Push alerts reach you when the Board is closed.' : perm === 'denied' ? 'Blocked in your browser settings.' : perm === 'unsupported' ? 'Not supported here.' : 'Get an alert when a work order needs your sign-off.'}</small></span></button>
    </div>
    ${siteStopRows(s.siteStops)}
    <h3 class="set-label">Audit trail</h3><ol class="audit" id="audit"><li>Loading…</li></ol>
    <h3 class="set-label">About</h3>
    <dl class="kv"><div><dt>Signed in as</dt><dd id="whoami">…</dd></div><div><dt>The Board</dt><dd class="mono">${esc(s.version || '')} · ${esc(S.build || '')}</dd></div>
      <div><dt>Updates</dt><dd>${S.updateReady ? 'New version ready, loads when you leave the app' : 'Automatic, when you are not using it'}</dd></div>
      ${(() => { const f = frameStats(); return f ? `<div><dt>Scene frame</dt><dd class="mono">p95 ${f.p95} ms · p50 ${f.p50} ms · ${f.n} frames</dd></div>` : ''; })()}
      <div><dt>Supervisor</dt><dd>${tickAge() == null ? 'never ran' : 'last pass ' + words(tickAge()) + ' ago'}</dd></div></dl>
    <div class="set-group"><label class="switch-row" data-css="margin:0;border-top:0"><span><b>Frame meter</b><small>Frames a second and frame time over the page, to check the scene runs at your screen's rate</small></span><input type="checkbox" role="switch" id="meter-switch" ${sceneMeter() ? 'checked' : ''}><i aria-hidden="true"></i></label></div>
    <div class="set-group" data-css="margin-top:24px"><button class="set-row danger" data-set="stop-all"><i class="set-ic" aria-hidden="true">■</i><span>Stop everything<small>Every running and waiting work order stops now</small></span></button></div>`;
  openSheet('menu-sheet');
  const [a, w] = await Promise.all([api('/api/audit'), api('/api/whoami')]);
  if ($('whoami')) $('whoami').textContent = w.ok ? w.who : '-';
  if ($('audit')) $('audit').innerHTML = a.ok && a.data.length ? a.data.slice(0, 40).map((x) => `<li><span><b class="${x.ok ? '' : 'no'}">${esc(cap(String(x.op).replace(/-/g, ' ')))}</b> ${esc(/^J\d+$/.test(x.id) ? ticket(x.id) : x.id || '')}${x.ok ? '' : ' · failed'}<br><small class="faint">${x.who === 'key' ? 'from this PC' : 'from your phone'}</small></span><span class="t">${clock(x.ts)}<br>${new Date(x.ts).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}</span></li>`).join('') : '<li>No actions yet.</li>';
}
$('menu-btn').addEventListener('click', openSettings);
const confirmLive = () => confirmBox({ title: 'Turn the AI crews on?', html: '<p>AI steps will really run on your Claude and Google plans. Private work orders still stay on this PC.</p>', yes: 'Turn on' });
document.addEventListener('click', async (e) => {
  const b = e.target.closest('[data-set]'); if (!b) return; const a = b.dataset.set;
  if (a === 'stop-all') { if (await confirmBox({ title: 'Stop everything?', html: '<p>Every running and waiting work order stops now, with everything it started.</p>', yes: 'Stop everything', danger: true })) await act({ op: 'stop-all' }, { btn: b, ok: 'Everything stopped' }); }
  else if (a === 'doctor') { const r = await act({ op: 'doctor' }, { btn: b }); if (r.ok) toast(r.data?.ok === false ? 'Doctor found: ' + (r.data.problems || []).join('; ') : 'Doctor: all fine', { bad: r.data?.ok === false, sticky: r.data?.ok === false }); }
  else if (a === 'push') { closeSheet('menu-sheet', false); pushSetup(); }
  else if (a === 'push-test') await act({ op: 'push-test' }, { btn: b, ok: 'Test sent' });
  else if (a === 'reconnect') { reconnect(); return; }
  else if (a === 'tick') await act({ op: 'tick' }, { btn: b, ok: 'Supervisor pass done' });
  else if (a === 'kitchen-resume') await act({ op: 'kitchen-resume' }, { btn: b, ok: 'Yard resumed' });
  else if (a === 'site-pause') { const c = b.dataset.site; if (await confirmBox({ title: `Stop work on Site ${esc(c)}?`, html: `<p>None of ${esc(c)}'s new work starts until you resume it. Its running work, the watchers and the other Sites carry on.</p>`, yes: 'Stop this Site', danger: true })) { const r = await act({ op: 'site-pause', site: c }, { btn: b, ok: `Site ${c} stopped` }); if (r.ok) closeSheet('menu-sheet'); } }   // TD-8
  else if (a === 'site-resume') { const r = await act({ op: 'site-resume', site: b.dataset.site }, { btn: b, ok: `Site ${b.dataset.site} resumed` }); if (r.ok) closeSheet('menu-sheet', false); }
  else if (a === 'undo-push-check') { const r = await act({ op: 'undo-push-check' }, { btn: b }); if (r.ok) toast(r.data?.left?.length ? `Not on GitHub yet: ${r.data.left.map((x) => x.why).join('; ')}` : r.data?.cleared?.length ? 'The undo is on GitHub now' : 'Nothing is waiting to be pushed', { bad: !!r.data?.left?.length }); }   // TD-EH-10
  else if (a === 'lead-toggle') { const out = S.state?.lead?.mode !== 'away'; const r = await api('/api/lead', { method: 'POST', body: JSON.stringify({ op: 'away', on: out }) }); if (r.ok) { buzz(); toast(out ? 'Claude is out until the reset' : 'Welcome back, Claude'); closeSheet('menu-sheet'); } else toast(r.error || 'Could not change that', { bad: true }); }
  else if (a === 'live-on') { if (await confirmLive()) await act({ op: 'live-on' }, { btn: b, ok: 'AI crews are on' }); }
  else if (a === 'notify' && 'Notification' in window) { const p = await Notification.requestPermission(); toast(p === 'granted' ? 'Alerts are on' : 'Alerts are off'); openSettings(); }
});
$('menu-body').addEventListener('change', async (e) => {
  if (e.target.id === 'meter-switch') return void sceneMeter(e.target.checked);   // the scene's frame meter (scene.js), this phone only
  if (e.target.id !== 'live-switch') return; const on = e.target.checked;
  if (on && !await confirmLive()) { e.target.checked = false; return; }
  const r = await act({ op: on ? 'live-on' : 'live-off' }, { ok: on ? 'AI crews are on' : 'AI crews are off' }); if (!r.ok) e.target.checked = !on;
});

// ---------- screen peek ----------
let peekT = null; let peekUrl = null;
async function peek() {
  try {
    const r = await fetch('/api/screen'); if (!r.ok) throw new Error();
    const u = URL.createObjectURL(await r.blob()); $('screen').src = u; $('screen').hidden = false; $('peek-empty').hidden = true;
    if (peekUrl) URL.revokeObjectURL(peekUrl); peekUrl = u; $('peek-foot').textContent = `Desk PC · captured ${clockS(Date.now())} · view only`;
  } catch { $('peek-foot').textContent = 'Desk PC · screen not available right now'; }
}
function stopPeek() { clearInterval(peekT); peekT = null; $('peek-live').setAttribute('aria-pressed', 'false'); }
$('screen-btn').addEventListener('click', () => { openSheet('screen-sheet'); peek(); });
$('peek-area').addEventListener('click', peek);
$('peek-live').addEventListener('click', () => { if (peekT) return stopPeek(); peek(); peekT = setInterval(peek, 1500); $('peek-live').setAttribute('aria-pressed', 'true'); });
document.addEventListener('visibilitychange', () => { if (document.hidden) stopPeek(); });

// ---------- sheets ----------
const opener = {};
function openSheet(id) { const d = $(id); if (d.open) return; opener[id] = document.activeElement; d.classList.remove('closing'); d.showModal(); }
function closeSheet(id, back = true) {
  const d = $(id); if (!d.open || d.classList.contains('closing')) return;
  const finish = () => { d.classList.remove('closing'); d.close(); opener[id]?.focus?.(); };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) finish(); else { d.classList.add('closing'); setTimeout(finish, 190); }
  if (id === 'job-sheet') { if (String(speaker.key).startsWith('job:')) speaker.stop(); S.openJob = null; S.jobSpeech = ''; if (back && location.hash.startsWith('#/job/')) { if (history.length > 1) history.back(); else go('#/pass'); } }
  if (id === 'log-sheet') { clearInterval(logTimer); S.log = null; }
  if (id === 'screen-sheet') stopPeek();
}
document.querySelectorAll('dialog.sheet').forEach((d) => {
  d.addEventListener('click', (e) => { if (e.target.closest('[data-close]') || e.target === d) closeSheet(d.id); });
  d.addEventListener('cancel', (e) => { e.preventDefault(); closeSheet(d.id); });
});

// ---------- when Claude is away (lead.json on the server) ----------
// Claude's weekly plan runs out now and then, and Jordan can't talk to Claude in the desktop app until it resets. The kitchen keeps
// cooking on its other cooks. This card says when Claude is back (a live countdown), shows Claude's last note, and keeps Jordan's
// notes for Claude's return; a note can also go straight to the kitchen as an idea.
function untilWords(iso) {
  const sec = Math.max(0, (new Date(iso) - Date.now()) / 1000); const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
  return sec < 60 ? 'any minute' : d ? `${d}d ${String(h).padStart(2, '0')}h ${String(m).padStart(2, '0')}m` : h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m} min`;
}
function dayTime(iso) { return new Date(iso).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' }); }
function renderLead() {
  const el = $('lead'); const L = S.state?.lead; if (!el) return;
  if (el.contains(document.activeElement) && document.activeElement.tagName === 'TEXTAREA') { S.sig.lead = ''; return; }   // never wipe a note mid-typing
  const notes = (L?.notes || []).filter((n) => n.status === 'open' || n.status === 'kitchen');
  if (!L || (L.mode === 'here' && !notes.length && !S.leadOpen)) { el.innerHTML = ''; return; }
  const pct = Math.round(100 * (L.week || 0));
  const noteRow = (n) => `<li class="lead-note${n.status === 'kitchen' ? ' sent' : ''}"><p>${esc(n.text)}</p><div class="lead-note-foot"><span class="faint">${n.status === 'kitchen' ? `With the Yard${n.idea ? ' as ' + esc(n.idea) : ''}` : 'Saved for Claude'} · ${esc(ago(n.at))}</span>
    ${n.status === 'open' ? `<button class="text-btn" data-lead="kitchen" data-id="${esc(n.id)}">Give to the Yard</button>` : ''}<button class="text-btn" data-lead="drop" data-id="${esc(n.id)}" aria-label="Remove note">Remove</button></div></li>`;
  const composer = `<form class="lead-form" data-lead-form><label for="lead-text">${L.mode === 'away' ? 'Leave Claude a note' : 'Note for Claude'}</label>
    <textarea id="lead-text" rows="2" maxlength="1000" placeholder="Anything Claude should pick up first">${esc(S.leadDraft || '')}</textarea>
    <div class="lead-form-foot"><span class="faint">Claude reads these first when it's back.</span><button class="btn primary" type="submit">Save</button></div></form>`;
  const list = notes.length ? `<ul class="lead-notes">${notes.map(noteRow).join('')}</ul>` : '';
  const toggle = `<button class="btn" data-lead="open" aria-expanded="${!!S.leadOpen}">${S.leadOpen ? 'Hide notes' : notes.length ? `Notes for Claude (${notes.length})` : 'Leave Claude a note'}</button>`;
  const drawer = S.leadOpen ? composer + list : '';
  if (L.mode === 'away') {
    const stars = Array.from({ length: 14 }, (_, i) => `<i data-css="--x:${(i * 37) % 100}%;--y:${(i * 53) % 70}%;--d:${(i % 5) * .7}s"></i>`).join('');
    el.innerHTML = `<section class="lead away" aria-labelledby="lead-h"><div class="lead-sky" aria-hidden="true">${stars}</div>
      <div class="lead-top"><span class="lead-moon" aria-hidden="true"></span><div><p class="lead-kicker">Claude is off the line</p>
        <h2 id="lead-h">${L.resetsAt ? `Back ${esc(dayTime(L.resetsAt))}` : 'Back after the weekly reset'}</h2>
        ${L.resetsAt ? `<p class="lead-count mono" data-until="${esc(L.resetsAt)}">${untilWords(L.resetsAt)}</p>` : ''}</div></div>
      <p class="lead-line">The Yard keeps building on Gemini and the Home crew${L.doneSince ? `: <b>${Number(L.doneSince)}</b> work order${L.doneSince > 1 ? 's' : ''} done since Claude stepped out` : ''}. Merges still wait for your sign-off.</p>
      ${L.handoff ? `<blockquote class="lead-handoff"><span>Claude's last note · ${esc(ago(L.handoff.at))}</span>${esc(L.handoff.text)}</blockquote>` : ''}
      <div class="lead-actions"><a class="btn" href="#/talk">Talk to the Yard</a>${toggle}${L.manual ? '<button class="btn" data-lead="back">Claude is back</button>' : ''}</div>
      ${drawer}</section>`;
  } else {
    el.innerHTML = `<section class="lead ${L.mode}" aria-labelledby="lead-h"><div class="lead-top"><span class="lead-glass" aria-hidden="true"><i data-css="--fill:${pct}%"></i></span><div>
        <p class="lead-kicker">${L.mode === 'low' ? 'Claude is running low this week' : 'Notes for Claude'}</p>
        <h2 id="lead-h">${L.mode === 'low' ? `${pct}% of the week used` : `${notes.length} note${notes.length === 1 ? '' : 's'} waiting`}</h2>
        ${L.resetsAt ? `<p class="faint lead-sub">Resets ${esc(dayTime(L.resetsAt))} · <span data-until="${esc(L.resetsAt)}">${untilWords(L.resetsAt)}</span></p>` : ''}</div>
        ${L.mode === 'low' ? '<button class="text-btn" data-lead="out">Claude is out</button>' : ''}</div>
      ${L.mode === 'low' ? `<div class="lead-meter" aria-hidden="true"><i data-css="width:${pct}%"></i></div><p class="lead-line">The Yard already builds without Claude past 85%, so what's left is yours to talk with. If Claude goes quiet, leave notes here.</p>` : ''}
      <div class="lead-actions">${toggle}</div>${drawer}</section>`;
  }
}
$('lead')?.addEventListener('input', (e) => { if (e.target.id === 'lead-text') S.leadDraft = e.target.value; });
$('lead')?.addEventListener('submit', async (e) => {
  e.preventDefault(); const t = $('lead-text'); const text = t.value.trim(); if (!text) return t.focus();
  const btn = e.target.querySelector('button[type=submit]'); btn.classList.add('busy');
  const r = await api('/api/lead', { method: 'POST', body: JSON.stringify({ op: 'note', text }) }); btn.classList.remove('busy');
  if (!r.ok) return toast(r.error || 'Could not save', { bad: true });
  S.leadDraft = ''; t.value = ''; t.blur(); buzz(12); toast('Saved. Claude reads it first when it is back.'); S.sig.lead = '';
});
$('lead')?.addEventListener('click', async (e) => {
  const b = e.target.closest('[data-lead]'); if (!b) return; const op = b.dataset.lead, id = b.dataset.id;
  if (op === 'open') { S.leadOpen = !S.leadOpen; S.sig.lead = ''; renderLead(); if (S.leadOpen) setTimeout(() => $('lead-text')?.focus({ preventScroll: true }), 50); return; }
  if (op === 'drop' && !await confirmBox({ title: 'Remove this note?', html: '<p>Claude won\'t see it.</p>', yes: 'Remove' })) return;
  if (op === 'kitchen' && !await confirmBox({ title: 'Give this to the Yard?', html: '<p>It becomes an idea. The autopilot builds it on the Google plan, and any change still waits for your sign-off before it merges.</p>', yes: 'Give it' })) return;
  const body = op === 'out' ? { op: 'away', on: true } : op === 'back' ? { op: 'away', on: false } : { op, id };
  b.classList.add('busy'); const r = await api('/api/lead', { method: 'POST', body: JSON.stringify(body) }); b.classList.remove('busy');
  if (!r.ok) return toast(r.error || 'Could not do that', { bad: true });
  buzz(); toast(op === 'kitchen' ? `With the Yard${r.data?.idea ? ' as ' + r.data.idea : ''}` : op === 'out' ? 'Marked: Claude is out until the reset' : op === 'back' ? 'Welcome back, Claude' : 'Removed');
  S.sig.lead = '';
});
// handed over: a little burst of sparks and a buzz when a work order is handed over while you watch
function celebrate(e) {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches || document.hidden) return;
  const at = document.querySelector('.headline-text')?.getBoundingClientRect(); const x = at ? at.left + Math.min(at.width, 220) / 2 : innerWidth / 2, y = at ? at.top + at.height / 2 : 120;
  const burst = document.createElement('div'); burst.className = 'spark-burst'; burst.style.left = x + 'px'; burst.style.top = y + 'px'; burst.setAttribute('aria-hidden', 'true');
  const colors = ['#FFB04D', '#FF7A3D', '#F0452B', '#FFE08A', '#7FD8A6'];
  burst.innerHTML = Array.from({ length: 18 }, (_, i) => { const a = (i / 18) * Math.PI * 2 + Math.random() * .4, d = 50 + Math.random() * 70; return `<i data-css="--c:${colors[i % colors.length]};--dx:${Math.cos(a) * d}px;--dy:${Math.sin(a) * d - 20}px;--r:${Math.round(Math.random() * 540)}deg"></i>`; }).join('');
  document.body.appendChild(burst); setTimeout(() => burst.remove(), 1100);
  buzz([10, 40, 14]); toast(`${STATUS_LABEL.done}: ${ticket(e.job)}.`);
}
// the time of day tints the room (the glow at the top of the screen, the brief's sky)
function daypart() { const h = new Date().getHours(); document.documentElement.dataset.daypart = h < 5 ? 'night' : h < 11 ? 'morning' : h < 17 ? 'day' : h < 21 ? 'evening' : 'night'; }
daypart(); setInterval(daypart, 600000);

// ---------- start ----------
(async () => {
  route(); renderAll(); connect(); renderPulse(); loadBrief(); loadSince();
  if (S.resumeOrder) openOrder();
  if (S.resumeY) { const y = S.resumeY; const t = setInterval(() => { if (S.state) { clearInterval(t); requestAnimationFrame(() => scrollTo(0, y)); } }, 50); setTimeout(() => clearInterval(t), 4000); }
  const r = await api('/api/events?n=400');
  if (r.ok) { const have = new Set(S.events.map(lobeEventKey)); S.events = [...r.data.filter((e) => !have.has(lobeEventKey(e))), ...S.events].sort((a, b) => String(a.ts).localeCompare(String(b.ts))); renderAll(); }
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
  window.addEventListener('online', () => { if (!es || es.readyState === 2) connect(); });
})();

// ---------- the animated building site at the top of the Board and Live tabs (scene.js) ----------
import { sceneHtml, activityWord, mountScene, cookOf, COOK_COLORS, stepWord, applyCss, sceneLegend, frameStats, sceneApproved, sceneMeter } from './scene.js';
import { startLive, floorStep } from './live.js';
import { mainStatusBanners } from './main-status.js';   // TD-EH-03a main-is-red banner
import { ciBudgetBanners } from './ci-budget.js';   // TD-11 CI budget per Site
import { undoPushBanners, autoMergePauseBanner } from './undo-pause.js';   // TD-EH-10 undo not pushed, TD-EH-11 auto-merge paused
import { siteStopBanners, siteStopRows } from './site-stop.js';   // TD-8: a Site stopped by you, a Site's own Stop-work order
import { makeFeed } from './patch.js';
import { worldHtml, paintWorld } from './lobe.js';   // ZG-09 World view
import { wireWorld, worldEditing, briefLobeLine } from './lobe.js';   // ZG-13 the Owner's taps and the brief's lobe line
import { lobeSentence, lobeEventKey } from './lobe.js';   // ZG-30 the lobe's lines in the Activity feed
import { selfCount } from './lobe-self.js';   // ZG-45 the World tab's badge: shadow Pours plus post-mortems waiting for the Owner
import { worldLine } from './world-line.js';   // ZG-17 the brief's World line (counts only)
import { siteChip, withFloor, siteBar, siteFilterOf, bySite } from './sites.js';   // TD-4 the Site chip, filter and count line
wireWorld($('world-body'), { post: (b) => api('/api/lobe', { method: 'POST', body: JSON.stringify(b) }), toast: (m, o) => toast(m, o), confirm: confirmBox, after: () => { S.sig.world = ''; if (S.view === 'world') renderWorld(); } });
paintWorld(document.documentElement);   // the World tab's pixel icon, before the view is first opened
import { syncList, windowed, WINDOW_FIRST, WINDOW_STEP } from './rows.js';
function renderScene() {
  const s = S.state; const el = S.view === 'pass' ? $('scene-pass') : S.view === 'cooks' ? $('scene-live') : null; if (!el || !s) return;
  mountScene(el, s, S.events, { compact: S.view === 'pass' });
  if ($('legend-sheet').open) { $('legend-body').innerHTML = sceneLegend(el); applyCss($('legend-body')); }
}
// the room's (i) chip: "What am I looking at?", one row per thing in the room with its number in words (the text twin of the world)
document.addEventListener('scene-legend', (e) => { $('legend-body').innerHTML = sceneLegend(e.target); applyCss($('legend-body')); openSheet('legend-sheet'); });
// starter questions on an empty chat fill the box (nothing is sent until you tap send)
$('talk-log').addEventListener('click', (e) => { const b = e.target.closest('[data-starter]'); if (!b) return; const t = $('talk-text'); t.value = b.dataset.starter; t.dispatchEvent(new Event('input')); t.focus(); buzz(6); });
