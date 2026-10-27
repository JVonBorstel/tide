// Tests for the Live call (pass-app/public/live.js, pass-app/SCENE.md "The Live call"): the call's memory (join, leave, the event
// stream), the badges, the shared screen, the tree, the markup and its private redaction, the desk art budget. Pure functions and a
// recording canvas mock (no browser). Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
import fs from 'node:fs';
import { LIVE, newMemory, track, agentsOf, spotOf, pin, quietDue, voiceLine, screenOf, treeOf, callsOf, tagOf, headHtml, deskHtml, screenHtml, treeHtml, sheetHtml,
  benchOf, callHtml, tickerHtml, drawDesk, drawCam, dur, floorStep } from './public/live.js';
import { makeKit, makeLoop, COOK_COLORS } from './public/scene.js';
import { CLOCK } from './public/frame.js';
import * as P from './public/sprites.js';

const out = [];
const check = (name, pass) => out.push({ name, pass: !!pass });
const T0 = Date.parse('2026-10-22T12:00:00Z');
const iso = (sec) => new Date(T0 + sec * 1000).toISOString();
const plan = [{ station: 'worktree', role: '' }, { station: 'agent', role: 'plan' }, { station: 'agent', role: 'do' }, { station: 'tests', role: '' }, { station: 'commit', role: '' }];
const job = (id, o = {}) => ({ id, name: `improve: rebuild the thing ${id}`, status: 'running', step: 3, steps: 5, attempt: 0, station: 'agent', role: 'do', cook: 'claude sonnet', since: iso(-30), plan, activity: [], tail: [], ...o });
const tool = (sec, t, target, status, more = {}) => ({ ts: iso(sec), kind: 'tool', tool: t, target, status, ...more });
const running = (sec = -20) => [tool(-28, 'Read', 'C:\\Users\\someone\\source\\repos\\wt\\J5\\pass-app\\public\\app.js', 'start', { tokens: 1200 }), tool(-27, 'Read', 'C:\\Users\\someone\\source\\repos\\wt\\J5\\pass-app\\public\\app.js', 'ok', { ms: 800, out: 'line one\nline two', tokens: 1500 }),
  tool(sec, 'Bash', 'npm test', 'start', { tokens: 2400 })];

// ---- join and leave ----
const mem = newMemory();
const s1 = { jobs: [job('J5', { activity: running() }), job('J6', { status: 'pending', step: 1 })], tokensToday: 123456, cooks: { claude: { status: 'ready', tokensToday: 5000, models: ['sonnet'] }, gemini: { status: 'resting' } } };
check('join: no memory, no state: nothing on the call, nothing thrown', track(newMemory(), null, [], T0).joined.length === 0 && agentsOf(newMemory(), T0).length === 0);
track(mem, s1, [], T0);
let ag = agentsOf(mem, T0);
check('join: a running step is an agent on the call; a pending order is not', ag.length === 1 && ag[0].id === 'J5' && ag[0].working && ag[0].cook === 'claude' && ag[0].label === 'Claude');
check('join: the agent joined when its step started (state since)', ag[0].joined === T0 - 30000);
const r2 = track(mem, { jobs: [job('J5', { activity: running() }), job('J7', { since: iso(1), station: 'tests', role: '', cook: '' })] }, [], T0 + 2000);
check('join: a new step on a later pass is reported as joined (for the voice line); the Yard hands take script steps', r2.joined.length === 1 && r2.joined[0].id === 'J7' && agentsOf(mem, T0 + 2000).find((a) => a.id === 'J7').cook === 'hands');
const ev = [{ ts: iso(4), type: 'step.done', job: 'J5', step: 2, attempt: 0 }];
const r3 = track(mem, { jobs: [job('J7', { since: iso(1), station: 'tests', role: '', cook: '' })] }, ev, T0 + 5000);
const left = agentsOf(mem, T0 + 5000).find((a) => a.id === 'J5');
check('leave: a step that ends stays on the call, marked done, with its real duration (from the event stream)', r3.left.length === 1 && left && left.left && left.outcome === 'ok' && left.tag === '✓ done' && /34 s/.test(tickerHtml(left)));
check('leave: it fades only after 2 minutes', !agentsOf(mem, T0 + 5000 + LIVE.leaveSec * 1000 - 1000).find((a) => a.id === 'J5').leaving && agentsOf(mem, T0 + 5000 + LIVE.leaveSec * 1000 + 100).find((a) => a.id === 'J5').leaving);
check('leave: after the fade it is gone from the call and from memory', !agentsOf(mem, T0 + 5000 + LIVE.leaveSec * 1000 + LIVE.fadeMs + 100).find((a) => a.id === 'J5') && ![...mem.agents.values()].some((a) => a.id === 'J5'));
const memF = newMemory(); track(memF, { jobs: [job('J8', { activity: running() })] }, [], T0);
track(memF, { jobs: [] }, [], T0 + 1000); track(memF, { jobs: [] }, [{ ts: iso(2), type: 'step.fail', job: 'J8', step: 2, attempt: 0 }], T0 + 3000);
check('leave: a failure that arrives after the state still marks it failed (✗ failed)', agentsOf(memF, T0 + 3000)[0].outcome === 'fail' && agentsOf(memF, T0 + 3000)[0].tag === '✗ failed');
const memR = newMemory();
track(memR, { jobs: [job('J9', { status: 'pending', step: 4 })] }, [{ ts: iso(-100), type: 'step.started', job: 'J9', step: 2, attempt: 0 }, { ts: iso(-40), type: 'cook', job: 'J9', step: 2, supplier: 'gemini' }, { ts: iso(-40), type: 'step.done', job: 'J9', step: 2, attempt: 0 },
  { ts: iso(-500), type: 'step.done', job: 'J9', step: 1, attempt: 0 }], T0);
const rec = agentsOf(memR, T0);
check('join: a page opened mid-shift shows who finished in the last 2 minutes, with the cook and duration the events give (older news is not replayed)', rec.length === 1 && rec[0].step === 3 && rec[0].cook === 'gemini' && rec[0].ended - rec[0].joined === 60000);
check('join: events that arrive after the first state still bring the recent leaver; once faded it never comes back', (() => {
  const m = newMemory(); const evs = [{ ts: iso(-40), type: 'step.done', job: 'J12', step: 0, attempt: 0 }];
  track(m, { jobs: [] }, [], T0); track(m, { jobs: [] }, evs, T0 + 1000); const got = agentsOf(m, T0 + 1000).length === 1;
  agentsOf(m, T0 + (LIVE.leaveSec + 10) * 1000); track(m, { jobs: [] }, evs, T0 + 100000); return got && agentsOf(m, T0 + 100000).length === 0; })());
check('join: a step comes back on the call if it starts again', (() => { const m = newMemory(); track(m, { jobs: [job('J10')] }, [], T0); track(m, { jobs: [] }, [], T0 + 1000); const r = track(m, { jobs: [job('J10')] }, [], T0 + 2000); return r.joined.length === 1 && agentsOf(m, T0 + 2000)[0].working; })());

// ---- badges ----
const one = (acts, now) => { const m = newMemory(); track(m, { jobs: [job('J11', { activity: acts })] }, [], T0); return agentsOf(m, now)[0]; };
check('stuck: a tool running over 60 s pulses amber (⏳); 59 s is not stuck', one([tool(0, 'Bash', 'npm test', 'start')], T0 + 61000).stuck && !one([tool(0, 'Bash', 'npm test', 'start')], T0 + 59000).stuck);
check('stuck: the desk and the header carry it', /lv-desk[^"]* lv-stuck/.test(deskHtml(one([tool(0, 'Bash', 'x', 'start')], T0 + 61000), '')) && /⏳/.test(deskHtml(one([tool(0, 'Bash', 'x', 'start')], T0 + 61000), '')) && /⏳1/.test(headHtml([one([tool(0, 'Bash', 'x', 'start')], T0 + 61000)], {})));
check('quiet: no activity for 3 minutes (a finished call) shows 💤; 2 minutes does not', one([tool(0, 'Read', 'a.js', 'ok', { ms: 5 })], T0 + 181000).quiet && !one([tool(0, 'Read', 'a.js', 'ok', { ms: 5 })], T0 + 120000).quiet);
check('quiet: the desk carries it (💤, class quiet)', /lv-desk[^"]* lv-quiet/.test(deskHtml(one([tool(0, 'Read', 'a.js', 'ok')], T0 + 181000), '')) && /💤/.test(deskHtml(one([tool(0, 'Read', 'a.js', 'ok')], T0 + 181000), '')));
check('quiet: a cook that never reports tool by tool is never called quiet (unknown is not quiet)', !one([], T0 + 600000).quiet);
check('quiet: a long-running tool is stuck, not quiet', (() => { const a = one([tool(0, 'Bash', 'x', 'start')], T0 + 400000); return a.stuck && !a.quiet; })());
const busyA = one([tool(-5, 'Edit', 'src/app.js', 'error', { ms: 300, out: 'String not found' }), tool(-3, 'Bash', 'npm test', 'start', { tokens: 42000 })], T0);
check('tokens and failures: per agent (⚡, ✗) and summed in the header with today\'s total', busyA.tokens === 42000 && busyA.fails === 1 && /⚡42k/.test(deskHtml(busyA, '')) && /✗1/.test(deskHtml(busyA, '')) && /⚡42k/.test(headHtml([busyA], { tokensToday: 2500000 })) && /2\.5M today/.test(headHtml([busyA], { tokensToday: 2500000 })));

// ---- tags and ticker ----
check('tag: Reading <file>, Editing <file>, Running tests, Running <cmd>, Searching “x”', tagOf({ tool: 'Read', target: 'C:\\x\\app.js' }) === 'Reading app.js' && tagOf({ tool: 'Edit', target: '/a/b.ts' }) === 'Editing b.ts'
  && tagOf({ tool: 'Bash', target: 'npm test' }) === 'Running tests' && tagOf({ tool: 'Bash', target: 'git status' }) === 'Running git status' && tagOf({ tool: 'Grep', target: 'liveHtml' }) === 'Searching “liveHtml”' && tagOf({ tool: 'Suite', target: 'Test-PassApp' }) === 'Running Test-PassApp');
check('tag: with no tool call it says the step in words', tagOf(null, false, floorStep({ station: 'agent', role: 'plan' })) === 'Planning' && floorStep({ station: 'tests' }) === 'Running the tests');
const runT = tickerHtml(one(running(-4), T0));
check('ticker: a running tool has a spinner and a live timer', /lv-spin/.test(runT) && /data-since="2026-10-22T11:59:56/.test(runT) && /Bash/.test(runT));
const doneT = tickerHtml(one([tool(-9, 'Read', 'a.js', 'start'), tool(-8, 'Read', 'a.js', 'ok', { ms: 1234 })], T0));
check('ticker: a finished tool shows ✓ and its real duration; a failed one ✗', /✓/.test(doneT) && /1\.2 s/.test(doneT) && /✗/.test(tickerHtml(busyA.calls.length ? { ...busyA, call: busyA.calls[0] } : busyA)));
check('durations read plainly', dur(400) === '0.4 s' && dur(12000) === '12 s' && dur(185000) === '3 min 5 s' && dur(3720000) === '1 h 2 min');

// ---- spotlight and the shared screen ----
const mS = newMemory();
track(mS, { jobs: [job('J20', { activity: [tool(-50, 'Read', 'a.js', 'ok', { ms: 3 })] }), job('J21', { activity: [tool(-2, 'Bash', 'npm run build', 'start')] })] }, [], T0);
const agS = agentsOf(mS, T0);
check('spotlight: the busy one (newest activity) gets the spotlight', spotOf(agS, mS, T0).id === 'J21');
pin(mS, agS.find((a) => a.id === 'J20').key, T0);
check('spotlight: a tapped desk keeps it for 25 s, then the busy one takes it back', spotOf(agS, mS, T0 + 10000).id === 'J20' && spotOf(agS, mS, T0 + 26000).id === 'J21');
check('spotlight: the spotlit desk is marked (class on)', /lv-desk lv-on/.test(callHtml(agS, mS, {}, {}, T0 + 26000)));
const term = screenOf(one([tool(-9, 'Bash', 'npm test', 'start'), tool(-8, 'Bash', 'npm test', 'error', { ms: 900, out: 'ok 1 parses\nFAIL 2 renders\n3 failed\n' + Array.from({ length: 12 }, (_, i) => 'more ' + i).join('\n') }), tool(-1, 'Grep', 'liveHtml', 'start')], T0));
check('screen: a terminal with the command, the first lines of its output, errors red, "… +N lines", and what still runs', term.kind === 'terminal' && term.lines[0].cls === 'cmd' && term.lines[0].text === 'npm test' && term.lines.some((l) => l.cls === 'bad' && /FAIL 2/.test(l.text)) && term.lines.some((l) => /… \+\d+ lines/.test(l.text)) && term.lines.some((l) => l.cls === 'tool' && /Grep\(liveHtml\)/.test(l.text)) && term.lines[term.lines.length - 1].cls === 'run');
check('screen: the footer says ⠋ running with a live timer, or ✓/✗ and the real duration', /running/.test(screenHtml(one([tool(-3, 'Bash', 'x', 'start')], T0))) && /data-since/.test(screenHtml(one([tool(-3, 'Bash', 'x', 'start')], T0))) && /✓ Read · 0\.8 s/.test(screenHtml(one([tool(-3, 'Read', 'a.js', 'start'), tool(-2, 'Read', 'a.js', 'ok', { ms: 800, out: 'x' })], T0))));
const ed = screenOf(one([tool(-3, 'Read', 'C:\\Users\\someone\\source\\repos\\wt\\J5\\pass-app\\public\\app.js', 'ok', { ms: 9, out: Array.from({ length: 20 }, (_, i) => 'const a' + i + ' = 1;').join('\n') })], T0));
check('screen: an editor for a file it reads: file name, folder, line numbers, "… +N lines"', ed.kind === 'editor' && ed.file === 'app.js' && ed.dir === 'pass-app/public/' && ed.lines[0].ln === 1 && ed.lines[0].text === 'const a0 = 1;' && /\+6 lines/.test(ed.lines[ed.lines.length - 1].text));
check('screen: a cook that does not report tool by tool shows its own log lines', (() => { const m = newMemory(); track(m, { jobs: [job('J22', { cook: 'gemini x', tail: ['reading the plan', '**FAIL** step 2'] })] }, [], T0); const sc = screenOf(agentsOf(m, T0)[0]); return sc.kind === 'log' && sc.lines.length === 2 && sc.lines[1].cls === 'bad'; })());
check('screen: nobody on the call, a dark screen that says so', /dark/.test(screenHtml(null)));

// ---- the tree ----
const mT = newMemory();
track(mT, { jobs: [job('J30', { step: 3, activity: [] })] }, [{ ts: iso(-60), type: 'cook', job: 'J30', step: 1, supplier: 'gemini' }], T0);
const tr = treeOf(agentsOf(mT, T0), mT);
check('tree: order -> steps -> cook: earlier steps done with the cook that did them, the current one now, script steps the Yard hands, the rest waiting', tr.length === 1 && tr[0].steps.length === 5 && tr[0].steps[0].state === 'done' && tr[0].steps[0].who === 'Yard hands'
  && tr[0].steps[1].state === 'done' && tr[0].steps[1].who === 'Gemini' && tr[0].steps[2].state === 'now' && tr[0].steps[2].who === 'Claude' && tr[0].steps[3].state === 'wait' && tr[0].steps[3].who === 'Yard hands');
check('tree: markup links the order and lists its steps', /href="#\/job\/J30"/.test(treeHtml(tr)) && (treeHtml(tr).match(/class="lv-st /g) || []).length === 5 && treeHtml([]) === '');

// ---- the bench: every cook and the kitchen hands keep a desk ----
const bench = benchOf(s1, []);
check('bench: cooks not on the call keep a dimmed desk with their status (and the Yard hands always have one)', bench.some((b) => b.cook === 'gemini' && b.tag === 'Resting' && b.sleep) && bench.some((b) => b.cook === 'hands') && bench.every((b) => b.idle));
check('bench: a cook on the call has no idle desk too', !benchOf(s1, [{ cook: 'claude', working: true }]).some((b) => b.cook === 'claude'));

// ---- private orders: no targets, output, prompt or report anywhere ----
const SECRET = ['SECRET-T', 'SECRET-O', 'SECRET-TAIL', 'SECRET-REPORT'];
const mP = newMemory();
const leaky = job('J40', { private: true, tail: ['SECRET-TAIL line'], activity: [tool(-9, 'Edit', 'C:\\x\\SECRET-T\\resume.md', 'ok', { ms: 4, out: 'SECRET-O body' }), tool(-2, 'Bash', 'type SECRET-T.txt', 'start'), { ts: iso(-1), kind: 'result', status: 'ok', out: 'SECRET-REPORT the answer' }] });
track(mP, { jobs: [leaky] }, [], T0); const pa = agentsOf(mP, T0)[0];
const allHtml = [callHtml([pa], mP, {}, {}, T0), screenHtml(pa), sheetHtml(pa, 'SECRET-T prompt'), treeHtml(treeOf([pa], mP)), voiceLine('join', pa), voiceLine('leave', pa), JSON.stringify(screenOf(pa)), pa.tag].join('\n');
check('private: even if the server leaked them, no target, output, log tail, prompt or report reaches the markup or the voice', SECRET.every((x) => !allHtml.includes(x)));
check('private: the desk says only the kind of tool, the screen says it is private, the sheet says the words stay on this PC', pa.tag === 'Running' && screenOf(pa).kind === 'private' && /stay on this PC/.test(sheetHtml(pa, 'x')) && !/Last report/.test(sheetHtml(pa, 'x')));
check('private: the call keeps only ts, kind, tool and status of each line', pa.activity.every((a) => Object.keys(a).sort().join() === 'kind,status,tool,ts'));
check('private: the voice line says "a private work order", never the ticket\'s words', voiceLine('join', pa) === 'Claude joins: a private work order.' && !/rebuild/.test(voiceLine('join', pa)));
check('private: an order private at one step stays private on the call', (() => { const m = newMemory(); track(m, { jobs: [{ ...leaky }] }, [], T0); track(m, { jobs: [{ ...leaky, private: undefined }] }, [], T0 + 1000); return agentsOf(m, T0 + 1000)[0].private; })());

// ---- the desk sheet ----
const pub = one([tool(-9, 'Read', 'a.js', 'ok', { ms: 3, out: 'x' }), tool(-8, 'Read', 'b.js', 'ok', { ms: 3 }), tool(-7, 'Bash', 'npm test', 'error', { ms: 5, out: 'boom' }), { ts: iso(-6), kind: 'result', status: 'ok', out: 'All done: 3 files changed.' }], T0);
const sh = sheetHtml(pub, 'Order: rebuild the Live tab');
check('sheet: prompt summary, tools used with counts, recent calls with status and duration, last report', /rebuild the Live tab/.test(sh) && /Read <b>2<\/b>/.test(sh) && /Bash <b>1<\/b>/.test(sh) && (sh.match(/<li>/g) || []).length === 3 && /✗/.test(sh) && /All done: 3 files changed/.test(sh));
check('sheet: loading and empty states say so', /Loading/.test(sheetHtml(pub, null)) && /No prompt summary/.test(sheetHtml(pub, '')) && /left the call/.test(sheetHtml(null)) && /No tool calls reported/.test(sheetHtml(one([], T0), '')));

// ---- markup safety and structure ----
const hostile = one([tool(-2, 'Read', 'C:\\x\\<img src=x onerror=alert(1)>.js', 'ok', { out: '<script>alert(1)</script>' })], T0);
hostile.name = '<b>pie</b>';
const hostileHtml = callHtml([hostile], newMemory(), {}, {}, T0) + sheetHtml(hostile, '<i>x</i>');
check('markup: everything from the kitchen is escaped', !/<img|<script|<b>pie|<i>x/.test(hostileHtml));
check('markup: no style attribute anywhere (strict CSP); colours go through data-css', !/\sstyle\s*=/.test(hostileHtml + callHtml(agS, mS, s1, { voiceOk: true }, T0)) && /data-css="--cook:/.test(hostileHtml));
const full = callHtml(agS, mS, s1, { quiet: true, voiceOk: true }, T0);
check('structure: header (live tag, counts, tokens, notify and voice toggles), shared screen, one desk per agent plus the bench, tree', /class="lv-head"/.test(full) && /lv-live/.test(full) && /data-lv="quiet" aria-pressed="true"/.test(full) && /data-lv="voice" aria-pressed="false"/.test(full)
  && /class="lv-screen /.test(full) && (full.match(/class="lv-desk[ "]/g) || []).length === agS.length + benchOf(s1, agS).length && /lv-tree/.test(full) && (full.match(/data-agent=/g) || []).length === agS.length);
check('structure: desks are buttons with a spoken label; the desk canvas is hidden from screen readers', /<button class="lv-desk-btn" data-agent="[^"]+" aria-label="Claude on WO-0021[^"]*Show details"/.test(full) && /class="lv-cam" aria-hidden="true"/.test(full));
check('structure: the voice toggle only appears where the browser can speak', !/data-lv="voice"/.test(headHtml([], {}, { voiceOk: false })));

// ---- the team goes quiet (notice + chime, opt-in) ----
const q = newMemory(); const qa = [{ working: true, quiet: false }];
check('quiet notice: never before anyone worked', !quietDue(newMemory(), [], T0));
quietDue(q, qa, T0);
check('quiet notice: fires once a minute after the last busy cook stops, not before, and only once per lull', !quietDue(q, [], T0 + 1000) && !quietDue(q, [], T0 + 50000) && quietDue(q, [], T0 + 62000) && !quietDue(q, [], T0 + 200000));
check('quiet notice: a step change (busy again within the minute) does not fire it', (() => { const m = newMemory(); quietDue(m, qa, T0); quietDue(m, [], T0 + 1000); quietDue(m, qa, T0 + 5000); return !quietDue(m, [], T0 + 40000); })());
check('quiet notice: cooks all quiet for 3 minutes count as a quiet team', (() => { const m = newMemory(); quietDue(m, qa, T0); quietDue(m, [{ working: true, quiet: true }], T0 + 1000); return quietDue(m, [{ working: true, quiet: true }], T0 + 70000); })());
check('voice: plain join and leave lines', voiceLine('join', { ...busyA, private: false }) === 'Claude joins: WO-0011, building.' && /is done with WO-0005/.test(voiceLine('leave', left)) && /hit a problem/.test(voiceLine('leave', { ...left, outcome: 'fail' })));

// ---- the page code: files, motion and the desk art budget ----
const src = fs.readFileSync(new URL('./public/live.js', import.meta.url), 'utf8');
check('page: the voice is speechSynthesis and off by default; the quiet notice is off by default', /speechSynthesis/.test(src) && /store\.get\('liveVoice', false\)/.test(src) && /store\.get\('liveQuiet', false\)/.test(src));
check('page: the notice carries no content (a fixed title, "Open the Board") and the chime is synthesised (no file, no network)', /'The Yard went quiet', opts/.test(src) && /body: 'Open the Board'/.test(src) && /createOscillator/.test(src) && !/fetch\(|new Audio\(|https?:\/\//.test(src));
check('page: the desk loop asks for no frame while hidden, off screen or under reduced motion', /ok: \(\) => !win\.document\.hidden && !reduced\(\) && LV\.isConnected && !!LV\.offsetParent/.test(src) && LIVE.fps <= 8);
const frames = []; const loop = makeLoop({ raf: (f) => { frames.push(f); return frames.length; }, fps: LIVE.fps, ok: () => false, frame: () => {} }); loop.start();
check('page: a loop that may not run never asks for a frame', frames.length === 0);
const errors = [];
function mk(w, h) {
  const c = { width: w, height: h };
  c.getContext = () => ({ imageSmoothingEnabled: true, clearRect() {}, createImageData: (ww, hh) => ({ width: ww, height: hh, data: new Uint8ClampedArray(ww * hh * 4) }), putImageData() {},
    drawImage: (img, sx0, sy0, sw, sh, dx, dy) => { if (!img?.getContext) errors.push('nothing'); if (![sx0, sy0, sw, sh, dx, dy].every(Number.isInteger)) errors.push('off grid'); if (dx < 0 || dy < 0 || dx + sw > 48 || dy + sh > 32) errors.push(`outside the desk ${dx},${dy},${sw},${sh}`); if (sx0 + sw > img.width || sy0 + sh > img.height) errors.push('source outside'); } });
  return c;
}
const kit = makeKit(P, mk); let worst = 0;
for (const a of [busyA, one([tool(0, 'Bash', 'x', 'start')], T0 + 61000), one([tool(0, 'Read', 'a', 'ok')], T0 + 181000), left, ...benchOf(s1, [])]) for (let t = 0; t < 2000; t += 125) worst = Math.max(worst, drawDesk(mk(48, 32).getContext(), kit, a, t));
check(`desk art: every state draws inside its 48x32 desk on whole pixels, at most ${LIVE.maxDraws} draws (${worst})${errors.length ? ' ' + errors[0] : ''}`, errors.length === 0 && worst > 3 && worst <= LIVE.maxDraws);
check('desk art: the desk, laptop, typing hands and wall are sprites.js sprites in the cook palette', ['desk', 'laptop', 'laptop-shut', 'work-type', 'desk-wall'].every((n) => P.SPRITES[n]) && P.framesOf('laptop').length === 4 && P.framesOf('work-type').length === 4);
check('desk art: the presenter camera draws the spotlight cook', drawCam(mk(16, 14).getContext(), kit, busyA, 0) === 2);
// the desk loop draws only for a new picture: each desk notes its next animation step on the frame clock; the loop sleeps until then
CLOCK.next = Infinity; drawDesk(mk(48, 32).getContext(), kit, busyA, 1000); const typingNext = CLOCK.next; CLOCK.next = Infinity; drawDesk(mk(48, 32).getContext(), kit, left, 1000);
check(`desk loop: a desk notes when its next step is due (typing: in ${Math.round(typingNext - 1000)} ms, at most 120), and the loop sleeps until then, redrawing only a changed desk`,
  typingNext > 1000 && typingNext <= 1120 && CLOCK.next > 1000 && CLOCK.next < Infinity && src.includes('frame: (dt) => { t += dt; if (t >= next) drawAll(); return Math.max(0, next - t); }') && src.includes('if (ds !== deskSig)') && !src.includes('frame: (dt) => { t += dt; drawAll(); }'));
const css = fs.readFileSync(new URL('./public/app.css', import.meta.url), 'utf8'); const lv = css.slice(css.indexOf('/* ---- Live: the call (live.js)'), css.indexOf('/* ---- the order page'));
const inPal = new Set([...Object.values(P.PALETTE), ...Object.values(P.SKIES).flat()].map((h) => h.toLowerCase()));
const hexes = [...new Set((lv.match(/#[0-9a-fA-F]{6}\b/g) || []).map((h) => h.toLowerCase()))];
check(`css: the call wears the pixel kitchen's palette only (${hexes.length} colours), light and dark`, lv.length > 2000 && hexes.length > 10 && hexes.every((h) => inPal.has(h)) && /@media \(prefers-color-scheme:dark\)\{\.lv\{/.test(lv));
check('css: stuck pulses amber, quiet dims, leaving fades; reduced motion stills them all', /\.lv-desk\.lv-stuck\{animation:lv-amber/.test(lv) && /\.lv-desk\.lv-leaving\{animation:lv-leave/.test(lv) && /\.lv-desk\.lv-quiet/.test(lv) && /@media \(prefers-reduced-motion:reduce\)\{[^\n]*\.lv-spin,\.lv-desk\.lv-stuck/.test(lv) && /\.lv\.paused \*\{animation-play-state:paused/.test(lv));
check('css: crisp pixels (image-rendering pixelated) and 44 px touch targets on the toggles', /\.lv-cv\{[^}]*image-rendering:pixelated/.test(lv) && /\.lv-btn\{[^}]*width:44px;height:44px/.test(lv));
check('desk art: every cook colour keeps its own badge on the laptop', new Set(Object.values(COOK_COLORS).map((c) => P.paletteFor({ cook: c })[5])).size === Object.keys(COOK_COLORS).length);
console.log(JSON.stringify(out));
