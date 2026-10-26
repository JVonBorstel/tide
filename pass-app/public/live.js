// The Live call (pass-app/SCENE.md "The Live call"; the idea of a team call comes from Agent Standup, the code and art are Chef's own).
// Every step on the line is an agent on the call: its cook sits at a desk (the pixel art of sprites.js, the cook's colours), with an
// activity tag (Reading app.js, Running tests), a ticker (the current tool with a spinner and a live timer, then a check or cross and
// the real duration), its tokens and failures. The busy one gets the spotlight and shares its screen: a terminal with the commands and
// the first lines of their output (errors red), or the file it reads or edits. A tile pulses amber when a tool runs over a minute (stuck)
// and sleeps when a cook that reports tool by tool has said nothing for 3 minutes (quiet). An agent joins when its step starts and
// leaves with a fade 2 minutes after it ends. Under the desks, a tree: order -> steps -> cook. Tap a desk for its prompt summary, the
// tools it used, its recent calls and its last report. Opt-in: a notice and a chime when the team goes quiet, spoken join/leave lines.
// Data: state.jobs[].activity (the server's last 25 activity lines per running step), state.jobs[].plan and the event stream
// (step.started / step.done / step.fail..., cook). Private orders show no targets, output, prompt or report anywhere: the server
// already keeps only ts, kind, tool and status for them, and this file keeps the same whitelist again (it never trusts its input).
// Motion: the desk canvases draw at 8 frames a second at most, stop while the page is hidden or the call is off screen, and hold
// one still frame under prefers-reduced-motion. Pure parts (track, agentsOf, screenOf, treeOf, the markup) are tested in node by
// pass-app/test-live.mjs; startLive is the page glue.
import { COOK_COLORS, cookOf, lookOf, hashId, applyCss, makeKit, makeLoop } from './scene.js';

export const LIVE = { stuckSec: 60, quietSec: 180, leaveSec: 120, fadeMs: 1400, pinSec: 25, teamQuietSec: 60, fps: 8, maxDraws: 8, recent: 30, lines: 14 };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ticket = (id) => 'WO-' + String(id || '').replace(/^J/, '').replace(/[^\w.-]/g, '').slice(0, 24).padStart(4, '0');
const tsOf = (x) => { const t = Date.parse(x); return Number.isFinite(t) ? t : 0; };
const cap = (s) => { s = String(s || ''); return s.charAt(0).toUpperCase() + s.slice(1); };
export const fmtTokens = (n) => { n = Number(n) || 0; if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M'; if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k'; return String(Math.round(n)); };
export function mmss(sec) { sec = Math.max(0, Math.floor(sec)); const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60; return (h ? h + ':' + String(m).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(s).padStart(2, '0'); }
// a real duration in plain words: 0.4 s, 12 s, 3 min 5 s, 1 h 2 min
export function dur(ms) {
  ms = Math.max(0, Number(ms) || 0); if (ms < 10000) return (ms / 1000).toFixed(1).replace(/\.0$/, '') + ' s';
  const s = Math.round(ms / 1000); if (s < 60) return s + ' s'; if (s < 3600) return Math.floor(s / 60) + ' min' + (s % 60 ? ' ' + (s % 60) + ' s' : '');
  return Math.floor(s / 3600) + ' h' + (Math.floor(s / 60) % 60 ? ' ' + (Math.floor(s / 60) % 60) + ' min' : '');
}

// ---- who is who ----
export const COOK_LABEL = { claude: 'Claude', antigravity: 'Claude via Google', gemini: 'Gemini', local: 'Local', hands: 'Yard hands', sous: 'Dispatcher' };
export const cookLabel = (n) => COOK_LABEL[n] || cap(n);
export const cookName = (j) => { const c = cookOf(j); return c === 'hand' ? 'hands' : c; };
const colorOf = (n) => COOK_COLORS[n === 'hands' ? 'hand' : n] || COOK_COLORS.sous;
// a step in plain words (also the job sheet's step list in app.js)
export const STEP_TAG = { plan: 'Planning', build: 'Building', do: 'Building', review: 'Reviewing the change', map: 'Mapping the code', repair: 'Fixing failing tests', mutate: 'Testing the tests',
  lint: 'Checking house rules', verify: 'Checking main after the merge', edit: 'Building', check: 'Inspection', research: 'Researching', talk: 'Answering you', diagnose: 'Finding the fix',
  tests: 'Running the tests', commit: 'Saving the change', freshen: 'Pulling in the latest code', merge: 'Handing it over', worktree: 'Setting up a safe copy', ideas: 'Filing ideas' };
const human = (s) => String(s || '').replace(/[-_]+/g, ' ');
export function floorStep(j) { const k = j?.station === 'agent' ? String(j.role || '').toLowerCase() : String(j?.station || ''); return STEP_TAG[k] || cap(human(j?.station)) || 'Working'; }

// ---- tool calls: start and finish lines paired into calls { tool, target, out, start, ms, ok, open, tokens } ----
export function callsOf(j) {
  const calls = []; const act = (j?.activity || []).filter((a) => a && a.kind === 'tool');
  for (const a of act) {
    const prev = calls[calls.length - 1];
    if (a.status === 'start' || !prev || prev.tool !== a.tool || prev.target !== (a.target || '') || !prev.open) calls.push({ tool: String(a.tool || ''), target: String(a.target || ''), start: a.ts, open: a.status === 'start', tokens: a.tokens });
    const c = calls[calls.length - 1];
    if (a.status !== 'start') { c.open = false; c.ok = a.status !== 'error' && a.status !== 'fail'; c.ms = a.ms; c.out = String(a.out || ''); c.tokens = a.tokens || c.tokens; }
  }
  return calls;
}
export function shortTarget(t) {
  t = String(t || '').replace(/\\/g, '/'); const m = /\/(?:worktrees|wt)\/[^/]+\/(.*)$/.exec(t); if (m) t = m[1];
  return t.replace(/^[A-Z]:\/Users\/[^/]+\//i, '~/');
}
const SHELL = new Set(['Bash', 'PowerShell', 'Suite']); const FILEY = new Set(['Read', 'Edit', 'MultiEdit', 'Write', 'NotebookEdit']);
const TAG_WORD = { Read: 'Reading', Edit: 'Editing', MultiEdit: 'Editing', NotebookEdit: 'Editing', Write: 'Writing', Grep: 'Searching', Glob: 'Listing', Bash: 'Running', PowerShell: 'Running',
  Suite: 'Running', Repair: 'Repairing', WebFetch: 'Fetching', WebSearch: 'Searching the web', TodoWrite: 'Updating the plan', Task: 'Asking a helper', Agent: 'Asking a helper',
  ExitPlanMode: 'Finishing the plan', ToolSearch: 'Finding a tool' };
export const toolWord = (tool) => TAG_WORD[tool] || (tool ? 'Using ' + tool : 'Working');
// the activity tag: what the cook is doing right now, from its newest call; a private order gives the kind of tool only
export function tagOf(call, priv, fallback = 'Working') {
  if (!call) return fallback;
  const w = toolWord(call.tool); if (priv) return w;
  const t = shortTarget(call.target), base = t.split('/').pop();
  let s = w;
  if (call.tool === 'Suite') s = 'Running ' + t;
  else if (SHELL.has(call.tool)) s = /\b(tests?|pester|jest|pytest|vitest)\b|Test-/i.test(t) ? 'Running tests' : 'Running ' + t.replace(/\s+/g, ' ');
  else if (call.tool === 'Grep' || call.tool === 'WebSearch') s = t ? `${w} “${t}”` : w;
  else if (call.tool === 'WebFetch') s = w + ' ' + (/^https?:\/\/([^/]+)/.exec(t)?.[1] || '');
  else if (base) s = w + ' ' + base;
  return s.length > 34 ? s.slice(0, 33) + '…' : s;
}

// ---- the call's memory: who joined, who left and how (in memory only; nothing is stored) ----
export function newMemory() { return { agents: new Map(), stepCook: new Map(), gone: new Set(), first: true, pin: '', pinAt: 0, team: { armed: false, since: 0 } }; }
const FINISH = /^step\.(done|fail|crash|timeout|memcap|logflood|hung|taster|rework)$/;
const keyOf = (id, step, attempt) => `${id}:${step}:${Number(attempt) || 0}`;
// what the call keeps of a job: private orders keep the server's whitelist again (ts, kind, tool, status) and no log tail
function snapOf(j, prev) {
  const priv = !!j.private || !!prev?.private;
  const act = (Array.isArray(j.activity) ? j.activity : []).filter((a) => a && typeof a === 'object');
  return { id: j.id, name: String(j.name || ''), label: j.label || '', private: priv, cook: cookName(j), model: String(j.cook || '').split(' ').slice(1).join(' '),
    station: j.station, role: j.role, step: Number(j.step) || 1, steps: Number(j.steps) || 1, plan: Array.isArray(j.plan) ? j.plan : prev?.plan || [], since: j.since,
    activity: priv ? act.map((a) => ({ ts: a.ts, kind: a.kind, tool: a.tool, status: a.status })) : act, tail: priv ? [] : (Array.isArray(j.tail) ? j.tail : []) };
}
function finishOf(events, id, step0, after) {
  let hit = null;
  for (const e of events) if (e && e.job === id && e.step === step0 && FINISH.test(String(e.type)) && tsOf(e.ts) >= after - 5000) hit = e;
  return hit;
}
// one pass over the newest state and events; returns who joined and who left since the last pass (for the voice lines)
export function track(mem, s, events = [], now = Date.now()) {
  const out = { joined: [], left: [] }; if (!s || !Array.isArray(s.jobs)) return out; const jobs = (s?.jobs || []).filter((j) => j && typeof j.id === 'string'); const ev = (events || []).slice(-600);
  for (const e of ev) if (e && e.type === 'cook' && e.job && Number.isInteger(e.step) && e.supplier) mem.stepCook.set(`${e.job}:${e.step + 1}`, cookName({ cook: String(e.supplier), station: 'agent' }));
  const seen = new Set();
  for (const j of jobs.filter((x) => x.status === 'running')) {
    const key = keyOf(j.id, j.step, j.attempt); seen.add(key); let a = mem.agents.get(key);
    if (!a || a.left) { if (!a) { a = { key, id: j.id, step: Number(j.step) || 1, attempt: Number(j.attempt) || 0, joined: tsOf(j.since) || now }; mem.agents.set(key, a); } a.left = 0; a.outcome = ''; a.ended = 0; if (!mem.first) out.joined.push(a); }
    a.snap = snapOf(j, a.snap);
    mem.stepCook.set(`${j.id}:${a.step}`, a.snap.cook);
  }
  // a page opened mid-shift still shows who finished in the last two minutes (from the event stream: real start, end and outcome);
  // the events can arrive after the first state, so every pass looks, and a step that already left the call never comes back
  {
    for (const e of ev) {
      if (!e || !FINISH.test(String(e.type)) || !Number.isInteger(e.step) || now - tsOf(e.ts) > LIVE.leaveSec * 1000) continue;
      const step = e.step + 1, key = keyOf(e.job, step, e.attempt); if (seen.has(key) || mem.agents.has(key) || mem.gone.has(key)) continue;
      const j = jobs.find((x) => x.id === e.job); let start = null;
      for (const x of ev) if (x && x.type === 'step.started' && x.job === e.job && x.step === e.step && tsOf(x.ts) <= tsOf(e.ts)) start = x;
      mem.agents.set(key, { key, id: e.job, step, attempt: Number(e.attempt) || 0, joined: start ? tsOf(start.ts) : 0, left: tsOf(e.ts), ended: tsOf(e.ts), outcome: e.type === 'step.done' ? 'ok' : 'fail',
        snap: { id: e.job, name: String(j?.name || ''), label: j?.label || '', private: !!j?.private, cook: mem.stepCook.get(`${e.job}:${step}`) || 'hands', model: '', step, steps: Number(j?.steps) || step, plan: j?.plan || [], activity: [], tail: [] } });
    }
  }
  for (const a of mem.agents.values()) {
    if (seen.has(a.key)) continue;
    if (!a.left) { a.left = now; a.outcome = ''; a.ended = now; out.left.push(a); }
    if (!a.outcome) { const e = finishOf(ev, a.id, a.step - 1, a.joined); if (e) { a.outcome = e.type === 'step.done' ? 'ok' : 'fail'; a.ended = Math.min(now, tsOf(e.ts) || now); } }
  }
  mem.first = false;
  return out;
}
// the agents on the call right now, oldest first; agents gone longer than the leave time plus the fade are dropped from memory
export function agentsOf(mem, now = Date.now()) {
  const out = [];
  for (const a of [...mem.agents.values()]) {
    if (a.left && now - a.left > LIVE.leaveSec * 1000 + LIVE.fadeMs) { mem.agents.delete(a.key); mem.gone.add(a.key); continue; }
    out.push(viewOf(a, now));
  }
  return out.sort((x, y) => x.joined - y.joined || x.key.localeCompare(y.key));
}
function viewOf(a, now) {
  const s = a.snap || {}; const calls = callsOf(s); const k = calls[calls.length - 1] || null; const acts = s.activity || [];
  const lastTs = Math.max(acts.length ? tsOf(acts[acts.length - 1].ts) : 0, a.joined || 0);
  const tokens = acts.reduce((m, x) => Math.max(m, Number(x.tokens) || 0), 0);
  const working = !a.left;
  const stuck = working && !!k?.open && now - tsOf(k.start) > LIVE.stuckSec * 1000;
  const quiet = working && !stuck && acts.length > 0 && now - lastTs > LIVE.quietSec * 1000;   // cooks that never report tool by tool are never called quiet: we can't know
  const word = floorStep(s);
  return { key: a.key, id: a.id, step: a.step, steps: s.steps || a.step, name: s.label ? cap(String(s.label).replace(/-/g, ' ')) : String(s.name || '').replace(/^[a-z][\w-]{1,15}:\s+/i, ''),
    private: !!s.private, cook: s.cook || 'hands', model: s.model || '', label: cookLabel(s.cook || 'hands'), color: colorOf(s.cook), look: lookOf(a.id), hair: hashId(a.id) % 4,
    calls, call: k, tokens, fails: calls.filter((c) => c.ok === false).length, working, left: !!a.left, outcome: a.outcome || '', stuck, quiet,
    leaving: !!a.left && now - a.left > LIVE.leaveSec * 1000, joined: a.joined || 0, ended: a.ended || 0, lastTs, word,
    tag: a.left ? (a.outcome === 'ok' ? '✓ done' : a.outcome === 'fail' ? '✗ failed' : 'Stepped out') : tagOf(k, s.private, word), plan: s.plan || [], tail: s.tail || [], activity: acts };
}
// the spotlight: a desk Jordan tapped keeps it 25 s, else the working agent with the newest activity, else the latest to leave
export function spotOf(agents, mem, now = Date.now()) {
  if (mem.pin && now - mem.pinAt < LIVE.pinSec * 1000) { const p = agents.find((a) => a.key === mem.pin && !a.leaving); if (p) return p; }
  const live = agents.filter((a) => a.working);
  const pool = live.length ? live : agents.filter((a) => !a.leaving);
  return pool.reduce((best, a) => (!best || Math.max(a.lastTs, a.call?.open ? tsOf(a.call.start) : 0) >= Math.max(best.lastTs, best.call?.open ? tsOf(best.call.start) : 0) ? a : best), null);
}
export function pin(mem, key, now = Date.now()) { mem.pin = key; mem.pinAt = now; }
// "the team went quiet": someone was working, and for a minute nobody has been (gone, between steps, or quiet for 3 minutes). Once per lull.
export function quietDue(mem, agents, now = Date.now()) {
  const t = mem.team; const busy = agents.some((a) => a.working && !a.quiet);
  if (busy) { t.armed = true; t.since = 0; return false; }
  if (!t.armed) return false;
  if (!t.since) t.since = now;
  if (now - t.since < LIVE.teamQuietSec * 1000) return false;
  t.armed = false; t.since = 0; return true;
}
// spoken lines (opt-in): a private order is "a private order", never its name or what it touches
export function voiceLine(kind, a) {
  const what = a.private ? 'a private work order' : `${ticket(a.id)}, ${a.word.toLowerCase()}`;
  if (kind === 'join') return `${a.label} joins: ${what}.`;
  return a.outcome === 'fail' ? `${a.label} hit a problem on ${a.private ? 'a private work order' : ticket(a.id)}.` : `${a.label} is done with ${a.private ? 'a private work order' : ticket(a.id)}.`;
}

// ---- the shared screen: { kind: terminal | editor | log | private, lines: [{ cls, text, ln }], foot } ----
const BAD = /\b(error|errors|failed|failure|fail|exception|denied|not found|FAIL)\b|✗/;
const lineCls = (l, failed) => (failed || (BAD.test(l) && !/\b0 (failed|errors?)\b/i.test(l)) ? 'bad' : /\b(PASS|ALL PASS|passed|ok)\b|✓/.test(l) ? 'good' : '');
const outLines = (out) => String(out || '').split(/\r?\n/).map((l) => l.replace(/\s+$/, '')).filter((l) => l.trim());
export function screenOf(a) {
  if (!a) return { kind: 'off', lines: [] };
  if (a.private) return { kind: 'private', lines: [{ cls: 'faint', text: 'Private work order: working on this PC. Nothing to show.' }], foot: a.call ? { open: a.call.open, ok: a.call.ok, tool: a.call.tool, start: a.call.start, ms: a.call.ms } : null };
  const k = a.call;
  if (!k) {   // cooks that do not report tool by tool (Gemini, Antigravity, local): their own log, as it is written
    const lines = (a.tail || []).map((x) => String(x).replace(/\(file:\/\/\/[^)]*\)/g, '').replace(/[*`#>]/g, '').trim()).filter((x) => x.length > 1).slice(-10);
    return { kind: 'log', title: a.word, lines: lines.length ? lines.map((l) => ({ cls: lineCls(l), text: l.slice(0, 220) })) : [{ cls: 'faint', text: `${a.label} is thinking…` }], foot: null };
  }
  const foot = { open: k.open, ok: k.ok, tool: k.tool, start: k.start, ms: k.ms };
  if (FILEY.has(k.tool)) {
    const t = shortTarget(k.target), file = t.split('/').pop() || k.tool, ls = outLines(k.out);
    const lines = ls.slice(0, LIVE.lines).map((l, i) => ({ cls: k.ok === false ? 'bad' : k.tool === 'Read' ? '' : 'add', text: l.slice(0, 160), ln: i + 1 }));
    if (ls.length > LIVE.lines) lines.push({ cls: 'faint', text: `… +${ls.length - LIVE.lines} lines` });
    if (!lines.length) lines.push({ cls: 'faint', text: k.open ? 'opening…' : '(no output)', ln: 1 });
    return { kind: 'editor', file, dir: t.slice(0, t.length - file.length), word: toolWord(k.tool), lines, foot };
  }
  // the terminal: the last few calls, each its command (or tool) and the first lines of what came back
  const lines = []; const hist = a.calls.slice(-4);
  for (const [i, c] of hist.entries()) {
    const last = i === hist.length - 1, t = shortTarget(c.target);
    lines.push(SHELL.has(c.tool) ? { cls: 'cmd', text: t.slice(0, 300) } : { cls: 'tool', text: `● ${c.tool}(${(FILEY.has(c.tool) ? t.split('/').pop() : t).slice(0, 80)})` });
    const ls = outLines(c.out), n = last ? 8 : 3;
    for (const l of ls.slice(0, n)) lines.push({ cls: lineCls(l, c.ok === false), text: l.slice(0, 200) });
    if (ls.length > n) lines.push({ cls: 'faint', text: `… +${ls.length - n} lines` });
    if (c.ok === false && !ls.length) lines.push({ cls: 'bad', text: '✗ failed' });
    if (c.open) lines.push({ cls: 'run', text: 'running' });
  }
  return { kind: 'terminal', lines: lines.slice(-26), foot };
}

// ---- the tree: order -> steps -> cook ----
export function treeOf(agents, mem) {
  const orders = new Map();
  for (const a of agents) { if (a.leaving) continue; const o = orders.get(a.id) || { id: a.id, name: a.name, private: a.private, agents: [], plan: a.plan, steps: a.steps }; o.agents.push(a); if (a.plan.length) o.plan = a.plan; orders.set(a.id, o); }
  return [...orders.values()].map((o) => {
    const at = new Map(o.agents.map((a) => [a.step, a])); const cur = Math.max(...o.agents.map((a) => a.step));
    const plan = o.plan.length ? o.plan : Array.from({ length: o.steps }, () => null);
    const steps = plan.map((p, i) => {
      const n = i + 1, a = at.get(n), agentStep = p ? p.station === 'agent' : !!a && a.cook !== 'hands';
      const cook = a ? a.cook : agentStep ? (mem.stepCook.get(`${o.id}:${n}`) || '') : 'hands';
      const state = a ? (a.working ? 'now' : a.outcome === 'fail' ? 'fail' : a.outcome === 'ok' ? 'done' : 'wait') : n < cur ? 'done' : 'wait';
      return { n, word: p ? floorStep(p) : a ? a.word : '', state, cook, who: cook ? cookLabel(cook) : agentStep && state === 'wait' ? 'the Dispatcher picks' : '', key: a?.key || '' };
    }).filter((x) => x.word || x.key);
    return { id: o.id, name: o.name, private: o.private, steps };
  });
}

// ---- markup (escaped; styles only as data-css) ----
export function headHtml(agents, s, prefs = {}) {
  const on = agents.filter((a) => a.working), calls = agents.reduce((n, a) => n + a.calls.length, 0), fails = agents.reduce((n, a) => n + a.fails, 0);
  const tokens = agents.reduce((n, a) => n + a.tokens, 0), stuck = on.filter((a) => a.stuck).length, quiet = on.filter((a) => a.quiet).length;
  const stats = on.length ? `<b>${on.length}</b> on the call${calls ? ` · <b>${calls}</b> calls` : ''}${fails ? ` · <b class="bad">✗${fails}</b>` : ''}${stuck ? ` · <b class="warn">⏳${stuck}</b>` : ''}${quiet ? ` · 💤${quiet}` : ''}`
    : 'No crew is working right now';
  return `<div class="lv-head"><span class="lv-live${on.length ? '' : ' off'}">${on.length ? 'Live' : 'Off air'}</span><span class="lv-stats">${stats}</span>
    <span class="lv-tok mono" title="Tokens: on the call now, and the whole Yard today">⚡${fmtTokens(tokens)}${s?.tokensToday ? ` <span class="faint">· ${fmtTokens(s.tokensToday)} today</span>` : ''}</span>
    <span class="lv-tools"><button class="lv-btn" data-lv="quiet" aria-pressed="${!!prefs.quiet}" aria-label="Notify me when the team goes quiet" title="Notify me when the team goes quiet">🔔</button>${prefs.voiceOk ? `<button class="lv-btn" data-lv="voice" aria-pressed="${!!prefs.voice}" aria-label="Speak when crews join and leave" title="Voice lines">🗣</button>` : ''}</span></div>`;
}
export function tickerHtml(a) {
  const k = a.call;
  if (a.left) return `<span class="lv-tick ${a.outcome === 'fail' ? 'bad' : a.outcome === 'ok' ? 'good' : ''}">${a.outcome === 'fail' ? '✗ failed' : a.outcome === 'ok' ? '✓ done' : 'stepped out'}${a.joined && a.ended ? `<span class="t mono">${dur(a.ended - a.joined)}</span>` : ''}</span>`;
  if (!k) return `<span class="lv-tick"><i class="lv-spin" aria-hidden="true"></i>${esc(a.word)}<span class="t mono" data-since="${esc(a.joined ? new Date(a.joined).toISOString() : '')}">${mmss((Date.now() - a.joined) / 1000)}</span></span>`;
  const what = `${esc(k.tool)}${a.private ? '' : ` <span class="mono">${esc(shortTarget(k.target).split('/').pop().slice(0, 28))}</span>`}`;
  return k.open ? `<span class="lv-tick"><i class="lv-spin" aria-hidden="true"></i>${what}<span class="t mono" data-since="${esc(k.start)}">${mmss((Date.now() - tsOf(k.start)) / 1000)}</span></span>`
    : `<span class="lv-tick ${k.ok === false ? 'bad' : 'good'}">${k.ok === false ? '✗' : '✓'} ${what}${k.ms != null ? `<span class="t mono">${dur(k.ms)}</span>` : ''}</span>`;
}
export function flagsHtml(a) {
  return `${a.stuck ? '<span class="warn" title="A tool has run over a minute">⏳</span>' : ''}${a.quiet ? '<span title="Quiet for 3 minutes">💤</span>' : ''}${a.fails ? `<span class="bad" title="Failed tool calls">✗${a.fails}</span>` : ''}${a.tokens ? `<span title="Tokens this step">⚡${fmtTokens(a.tokens)}</span>` : ''}`;
}
export function deskClass(a, spotKey) { return `lv-desk${a.key === spotKey ? ' lv-on' : ''}${a.stuck ? ' lv-stuck' : ''}${a.quiet ? ' lv-quiet' : ''}${a.left ? ' lv-left' : ''}${a.leaving ? ' lv-leaving' : ''}${a.outcome === 'fail' ? ' lv-fail' : ''}${a.idle ? ' lv-idle' : ''}`; }   // prefixed: app.css already styles a plain .quiet (the empty state card)
export function deskBodyHtml(a) {
  if (a.idle) return `<span class="lv-tag">${esc(a.tag)}</span><div class="lv-who"><b>${esc(a.label)}</b><span class="mono faint">${esc(a.model || 'not on the call')}</span></div><span class="lv-flags">${a.tokens ? `<span title="Tokens today">⚡${fmtTokens(a.tokens)}</span>` : ''}</span>`;
  return `<span class="lv-tag">${esc(a.tag)}</span><div class="lv-who"><b>${esc(a.label)}</b><span class="mono faint">${ticket(a.id)} · step ${a.step}/${a.steps}</span></div><span class="lv-flags">${flagsHtml(a)}</span>
    <p class="lv-job">${esc(a.name)}</p>${tickerHtml(a)}`;
}
export function deskHtml(a, spotKey) {
  const say = a.idle ? `${a.label}, ${a.tag}` : `${a.label} on ${ticket(a.id)}, ${a.tag}${a.stuck ? ', a tool has run over a minute' : ''}${a.quiet ? ', quiet for 3 minutes' : ''}. Show details`;
  return `<li class="${deskClass(a, spotKey)}" data-key="${esc(a.key)}" data-css="--cook:${esc(a.color)}">${a.idle ? '' : `<button class="lv-desk-btn" data-agent="${esc(a.key)}" aria-label="${esc(say)}"></button>`}
    <div class="lv-cam" aria-hidden="true"><canvas class="lv-cv" width="48" height="32"></canvas><span class="lv-av">${esc(a.label.charAt(0))}</span></div><div class="lv-body"${a.idle ? ` aria-label="${esc(say)}"` : ''}>${deskBodyHtml(a)}</div></li>`;
}
export function footHtml(f) {
  if (!f) return '';
  return f.open ? `<div class="lv-foot"><i class="lv-spin" aria-hidden="true"></i>${esc(f.tool)} · running <span class="mono" data-since="${esc(f.start)}">${mmss((Date.now() - tsOf(f.start)) / 1000)}</span></div>`
    : `<div class="lv-foot ${f.ok === false ? 'bad' : 'good'}">${f.ok === false ? '✗' : '✓'} ${esc(f.tool)}${f.ms != null ? ' · ' + dur(f.ms) : ''}</div>`;
}
export function screenHtml(a) {
  if (!a) return `<div class="lv-screen off"><div class="lv-scr"><p class="lv-l faint">The screen is dark. A crew shares theirs as soon as they start a step.</p></div></div>`;
  const sc = screenOf(a);
  const top = `<div class="lv-scr-top"><span class="lv-cam-sm" aria-hidden="true"><canvas class="lv-pc" width="16" height="14"></canvas></span><span class="lv-share">● Sharing</span><b>${esc(a.label)}</b><a class="lv-scr-job mono" href="#/job/${esc(a.id)}">${ticket(a.id)}</a></div>`;
  let body;
  if (sc.kind === 'editor') body = `<div class="lv-tab"><span class="lv-file">${esc(sc.file)}</span><span class="faint">${esc(sc.dir)}</span><em>${esc(sc.word)}</em></div>`
    + sc.lines.map((l) => `<p class="lv-code ${l.cls}">${l.ln ? `<span class="ln">${l.ln}</span>` : ''}${esc(l.text)}</p>`).join('');
  else body = (sc.kind === 'log' ? `<div class="lv-tab"><span class="lv-file">${esc(a.label)}</span><em>${esc(sc.title)}</em></div>` : '')
    + sc.lines.map((l) => l.cls === 'cmd' ? `<p class="lv-l cmd"><b>❯</b> ${esc(l.text)}</p>` : l.cls === 'run' ? '<p class="lv-l run"><i class="lv-spin" aria-hidden="true"></i>running</p>' : `<p class="lv-l ${l.cls}">${esc(l.text)}</p>`).join('');
  return `<div class="lv-screen ${sc.kind}" data-css="--cook:${esc(a.color)}" aria-label="${esc(a.label)}'s screen">${top}<div class="lv-scr">${body}</div>${footHtml(sc.foot)}</div>`;
}
export function treeHtml(tree) {
  if (!tree.length) return '';
  const st = { now: '◐', done: '✓', fail: '✗', wait: '·' };
  return `<details class="lv-tree" open><summary>Who works on what</summary><ul>${tree.map((o) => `<li><a class="lv-order" href="#/job/${esc(o.id)}"><span class="mono">${ticket(o.id)}</span> ${esc(o.name)}</a>
    <ul>${o.steps.map((x) => `<li class="lv-st ${x.state}"><span class="mk" aria-hidden="true">${st[x.state]}</span><span>${x.n}. ${esc(x.word)}</span>${x.who ? `<span class="who" data-css="--cook:${esc(colorOf(x.cook))}">${esc(x.who)}</span>` : ''}</li>`).join('')}</ul></li>`).join('')}</ul></details>`;
}
// the desk sheet: prompt summary (fetched by the caller, never for a private order), tools used, recent calls, last report
export function sheetHtml(a, detail = null) {
  if (!a) return '<p class="empty-line">This crew has left the call.</p>';
  const counts = {}; for (const c of a.calls) counts[c.tool] = (counts[c.tool] || 0) + 1;
  const tools = Object.entries(counts).sort((x, y) => y[1] - x[1]).map(([t, n]) => `<span class="lv-chip">${esc(t)} <b>${n}</b></span>`).join('');
  const report = a.private ? '' : [...a.activity].reverse().find((x) => (x.kind === 'result' || x.kind === 'text') && x.out)?.out || '';
  const ask = a.private ? '<p class="note">Private work order: its words stay on this PC.</p>' : detail === null ? '<p class="note faint">Loading…</p>' : detail ? `<pre class="lv-ask">${esc(String(detail).slice(0, 1200))}</pre>` : '<p class="note faint">No prompt summary for this step.</p>';
  const recent = a.calls.slice(-LIVE.recent).reverse().map((c) => {
    const t = a.private ? '' : shortTarget(c.target), out = a.private ? '' : String(c.out || '');
    const head = `<span class="${c.open ? '' : c.ok === false ? 'bad' : 'good'}">${c.open ? '◐' : c.ok === false ? '✗' : '✓'}</span><b>${esc(c.tool)}</b><span class="mono">${esc(t.split('/').pop().slice(0, 40))}</span><span class="mono faint">${c.ms != null ? dur(c.ms) : c.open ? 'running' : ''}</span>`;
    return !a.private && (t || out) ? `<li><details><summary>${head}</summary><pre class="lv-out">${esc(t)}${out ? '\n' + esc(out.slice(0, 1200)) : ''}</pre></details></li>` : `<li><div class="lv-rc">${head}</div></li>`;
  }).join('');
  return `<dl class="kv"><div><dt>Work order</dt><dd><a href="#/job/${esc(a.id)}">${ticket(a.id)}</a> ${esc(a.name)}</dd></div><div><dt>Step</dt><dd>${a.step} of ${a.steps} · ${esc(a.word)}</dd></div>
      <div><dt>Status</dt><dd>${esc(a.tag)}${a.stuck ? ' · ⏳ a tool has run over a minute' : ''}${a.quiet ? ' · 💤 quiet for 3 minutes' : ''}</dd></div><div><dt>Tokens</dt><dd class="mono">${fmtTokens(a.tokens)}</dd></div></dl>
    <h3 class="group-label">Asked to</h3>${ask}
    <h3 class="group-label">Tools used</h3>${tools ? `<div class="lv-chips">${tools}</div>` : '<p class="note faint">No tool calls reported (this crew does not report tool by tool, or has not started).</p>'}
    ${recent ? `<h3 class="group-label">Recent activity</h3><ul class="lv-recent">${recent}</ul>` : ''}
    ${a.private ? '' : `<h3 class="group-label">Last report</h3>${report ? `<pre class="lv-ask">${esc(String(report).slice(0, 1500))}</pre>` : '<p class="note faint">No report yet.</p>'}`}`;
}
// every cook and the kitchen hands keep a desk even when they are not on the call (dimmed, with their status word)
const IDLE_WORD = { ready: 'Idle', resting: 'Resting', busy: 'Busy', capped: 'At its cap', 'signed-out': 'Signed out', off: 'Off' };
export function benchOf(s, agents) {
  const on = new Set(agents.filter((a) => a.working).map((a) => a.cook));
  const names = [...new Set([...Object.keys(s?.cooks || {}), 'hands'])].filter((n) => !on.has(n) && n !== 'sous');
  return names.map((n) => { const c = s?.cooks?.[n]; return { key: 'cook:' + n, idle: true, cook: n, label: cookLabel(n), color: colorOf(n), look: lookOf('cook:' + n), hair: hashId(n) % 4,
    tag: n === 'hands' ? 'Idle' : IDLE_WORD[c?.status] || 'Idle', sleep: !!c && c.status !== 'ready', model: [].concat(c?.models || [])[0] || (n === 'hands' ? 'tests, saves, merges' : ''), tokens: Number(c?.tokensToday) || 0 }; });
}
// the whole call as one string (first paint, tests)
export function callHtml(agents, mem, s, prefs = {}, now = Date.now()) {
  const spot = spotOf(agents, mem, now); const bench = benchOf(s, agents);
  return `<section class="lv" aria-label="Live call">${headHtml(agents, s, prefs)}${screenHtml(spot)}<ul class="lv-desks">${[...agents, ...bench].map((a) => deskHtml(a, spot?.key)).join('')}</ul>${treeHtml(treeOf(agents, mem))}</section>`;
}

// ---- the desk art: one canvas per desk, sprites.js art in the cook's palette ----
// returns the number of draw calls (the budget test holds it to LIVE.maxDraws)
export function drawDesk(ctx, kit, a, t = 0) {
  let n = 0; const o = { skin: a.look?.skin, cook: a.color, hair: a.hair || 0, sky: 'day' };
  const d = (name, f, x, y, pal = o) => { const s = kit.get(name, pal); ctx.drawImage(s.img, (f % s.n) * s.w, 0, s.w, s.h, x, y, s.w, s.h); n++; };
  const at = (k, ms) => Math.floor((t + (a.look?.delay || 0) * 1000) / ms) % k;
  d('desk-wall', 0, 0, 0);
  const asleep = a.quiet || a.sleep, typing = a.working && !a.stuck && !a.quiet;
  d(asleep ? 'chef-sleep' : 'chef-idle', at(2, asleep ? 900 : 450), 16, asleep ? 6 : 4);
  if (a.look?.stache && !asleep) d('stache', 0, 22, 14 + at(2, 450));
  d('desk', 0, 0, 21);
  if (a.working) d('laptop', typing ? at(4, 120) : 0, 17, 18); else d('laptop-shut', 0, 17, 19);
  if (typing) d('work-type', at(4, 120), 16, 20);
  if (asleep) d('zz', 0, 33, 2 + at(3, 900));
  return n;
}
// the presenter's camera in the corner of the shared screen: the spotlight cook's head and shoulders
export function drawCam(ctx, kit, a, t = 0) {
  const o = { skin: a.look?.skin, cook: a.color, hair: a.hair || 0, sky: 'day' };
  const w = kit.get('desk-wall', o); ctx.drawImage(w.img, 0, 0, 16, 14, 0, 0, 16, 14);
  const s = kit.get('chef-idle', o); const f = Math.floor(t / 450) % 2; ctx.drawImage(s.img, f * s.w, 0, s.w, 14, 0, 1, s.w, 14);
  return 2;
}

// ---- in the page ----
const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
export function startLive(o) {
  // o: { root, getState, getEvents, isVisible, store, openSheet, sheetTitle, sheetBody, sheetOpen, fetchStep(id, step) -> Promise<string|''>, win }
  const win = o.win || globalThis; const mem = newMemory(); let KIT = null, t = 0, spotKey = '', sheetKey = '', model = { agents: [], bench: [] }; const sig = {};
  const prefs = () => ({ quiet: !!o.store.get('liveQuiet', false), voice: !!o.store.get('liveVoice', false), voiceOk: !!(win.speechSynthesis && win.SpeechSynthesisUtterance) });
  const root = o.root;
  root.innerHTML = '<section class="lv" aria-label="Live call"><div class="lv-h"></div><div class="lv-s"></div><ul class="lv-desks"></ul><div class="lv-t"></div></section>';
  const H = root.querySelector('.lv-h'), SC = root.querySelector('.lv-s'), D = root.querySelector('.lv-desks'), T = root.querySelector('.lv-t'), LV = root.querySelector('.lv');
  // the clocks (data-since) tick in place (app.js), so a change of their text alone never rebuilds anything (a spinner never restarts)
  const still = (html) => html.replace(/(data-since="[^"]*">)[^<]*/g, '$1');
  const set = (el, k, html) => { const v = still(html); if (sig[k] !== v) { sig[k] = v; el.innerHTML = html; applyCss(el); } };
  const all = () => [...model.agents, ...model.bench];
  function drawAll() {
    if (!KIT) return;
    for (const li of D.children) { const a = all().find((x) => x.key === li.dataset.key); const cv = li._cv; if (a && cv) { cv.ctx.clearRect(0, 0, 48, 32); drawDesk(cv.ctx, KIT, a, t); } }
    const pc = SC.querySelector('.lv-pc'); const sp = model.agents.find((a) => a.key === spotKey);
    if (pc && sp) { const c = pc.getContext('2d'); c.imageSmoothingEnabled = false; drawCam(c, KIT, sp, t); }
  }
  const loop = makeLoop({ raf: (f) => win.requestAnimationFrame(f), fps: LIVE.fps, ok: () => !win.document.hidden && !reduced() && LV.isConnected && !!LV.offsetParent, frame: (dt) => { t += dt; drawAll(); } });
  function render(now) {
    const s = o.getState(); const p = prefs();
    const spot = spotOf(model.agents, mem, now); spotKey = spot?.key || '';
    set(H, 'h', headHtml(model.agents, s, p)); set(SC, 's', screenHtml(spot)); set(T, 't', treeHtml(treeOf(model.agents, mem)));
    const want = all(); const have = new Map([...D.children].map((li) => [li.dataset.key, li]));
    let prev = null;
    for (const a of want) {
      let li = have.get(a.key); have.delete(a.key);
      if (!li) { const tmp = win.document.createElement('ul'); tmp.innerHTML = deskHtml(a, spotKey); li = tmp.firstElementChild; applyCss(li); const cv = li.querySelector('canvas'); li._cv = { ctx: cv.getContext?.('2d') }; if (li._cv.ctx) li._cv.ctx.imageSmoothingEnabled = false; else li._cv = null; }
      const cls = deskClass(a, spotKey); if (li.className !== cls) li.className = cls;
      const body = li.querySelector('.lv-body'); const bh = deskBodyHtml(a); if (body._h !== still(bh)) { body._h = still(bh); body.innerHTML = bh; }
      const btn = li.querySelector('.lv-desk-btn'); if (btn) btn.setAttribute('aria-label', `${a.label} on ${ticket(a.id)}, ${a.tag}${a.stuck ? ', a tool has run over a minute' : ''}${a.quiet ? ', quiet for 3 minutes' : ''}. Show details`);
      if ((prev ? prev.nextElementSibling : D.firstElementChild) !== li) D.insertBefore(li, prev ? prev.nextElementSibling : D.firstElementChild);
      prev = li;
    }
    for (const li of have.values()) li.remove();
    LV.classList.toggle('paused', !!win.document.hidden);
    drawAll();
    if (sheetKey && o.sheetOpen()) { const a = model.agents.find((x) => x.key === sheetKey); const h = sheetHtml(a, sheetDetail); if (o.sheetBody._h !== h) { o.sheetBody._h = h; const open = [...o.sheetBody.querySelectorAll('details[open]')].map((x) => x.querySelector('summary')?.textContent); o.sheetBody.innerHTML = h; for (const x of o.sheetBody.querySelectorAll('details')) if (open.includes(x.querySelector('summary')?.textContent)) x.open = true; } }
  }
  let sheetDetail = null;
  function speak(line) {
    try { const ss = win.speechSynthesis; if (!ss || !prefs().voice) return; if (ss.pending) ss.cancel(); const u = new win.SpeechSynthesisUtterance(line); u.rate = 1.05; ss.speak(u); } catch { /* no voice: the words are on screen anyway */ }
  }
  let ac = null;
  function chime() {
    try { const AC = win.AudioContext || win.webkitAudioContext; if (!AC) return; ac ||= new AC(); ac.resume?.(); const t0 = ac.currentTime;
      for (const [f, d] of [[659, 0], [988, 0.16]]) { const osc = ac.createOscillator(), g = ac.createGain(); osc.type = 'triangle'; osc.frequency.value = f; g.gain.setValueAtTime(0.0001, t0 + d); g.gain.exponentialRampToValueAtTime(0.14, t0 + d + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t0 + d + 0.5); osc.connect(g).connect(ac.destination); osc.start(t0 + d); osc.stop(t0 + d + 0.55); }
    } catch { /* no audio: the notice still shows */ }
  }
  // the notice carries no content (Jordan's rule for anything on the lock screen): a fixed title, "Open Chef"
  function notifyQuiet() {
    chime();
    try {
      if (!('Notification' in win) || win.Notification.permission !== 'granted') return;
      const opts = { body: 'Open the Board', tag: 'chef-quiet', icon: '/icon.svg' };
      try { new win.Notification('The Yard went quiet', opts); } catch { win.navigator.serviceWorker?.ready.then((r) => r.showNotification('The Yard went quiet', opts)).catch(() => {}); }
    } catch { /* notices blocked: the chime played */ }
  }
  function update() {
    const now = Date.now(); const r = track(mem, o.getState(), o.getEvents(), now);
    model.agents = agentsOf(mem, now); model.bench = benchOf(o.getState(), model.agents);
    for (const a of r.joined) { const v = model.agents.find((x) => x.key === a.key); if (v) speak(voiceLine('join', v)); }
    for (const a of r.left) { const v = model.agents.find((x) => x.key === a.key); if (v) speak(voiceLine('leave', v)); }
    if (quietDue(mem, model.agents, now) && prefs().quiet) notifyQuiet();
    if (o.isVisible()) { render(now); loop.start(); }
  }
  root.addEventListener('click', (e) => {
    const b = e.target.closest('[data-lv]');
    if (b) {
      const k = b.dataset.lv === 'quiet' ? 'liveQuiet' : 'liveVoice'; const on = !o.store.get(k, false); o.store.set(k, on);
      if (k === 'liveQuiet' && on) { chime(); try { if ('Notification' in win && win.Notification.permission === 'default') win.Notification.requestPermission().catch?.(() => {}); } catch {} }
      if (k === 'liveVoice' && on) speak('Voice lines on.');
      sig.h = ''; update(); return;
    }
    const d = e.target.closest('[data-agent]'); if (!d) return;
    const key = d.dataset.agent; const a = model.agents.find((x) => x.key === key); if (!a) return;
    pin(mem, key); sheetKey = key; sheetDetail = a.private ? '' : null; o.sheetBody._h = '';
    o.sheetTitle.textContent = `${a.label} · ${ticket(a.id)}`; o.sheetBody.innerHTML = sheetHtml(a, sheetDetail); o.openSheet();
    if (!a.private) o.fetchStep(a.id, a.step).then((txt) => { if (sheetKey === key) { sheetDetail = txt || ''; o.sheetBody._h = ''; update(); } }).catch(() => { sheetDetail = ''; });
    update();
  });
  win.setInterval(update, 1000);   // timers, stuck and quiet badges and the 2-minute leave all move with the clock
  win.document.addEventListener('visibilitychange', () => { LV.classList.toggle('paused', !!win.document.hidden); if (!win.document.hidden) loop.start(); });
  import('./sprites.js').then((P) => { KIT = makeKit(P, (w, h) => { const c = win.document.createElement('canvas'); c.width = w; c.height = h; return c; }); win.document.documentElement.classList.add('lv-px'); drawAll(); }).catch(() => { /* no sprites: the letter avatars stay */ });
  return { update, mem };
}
