// Owns the tests of the Work tab's API (pass-app/work, lane L5, WO-UPG-L5-1). Every test is named after an acceptance line of the L5 brief
// (prompts/upgrade-L5-board.md, work breakdown "api") or a rule of pass-app/work/api.mjs.
// Called by tests/Test-Work.ps1 (CI's Core step through core/ship/gates.json, verify-all) and by hand: node pass-app/test-work.mjs
// It runs the real Board server (pass-app/server.mjs) on a throwaway state folder with a synthetic event store, so a tap goes through the
// Board's own auth and Origin checks. Nothing is read from the live state folder. node:sqlite needs --experimental-sqlite on Node 22: this
// file starts itself again with the flag only when the module is missing, and starts the server the same way.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';

let hasSqlite = true; try { await import('node:sqlite'); } catch { hasSqlite = false; }
const SQLITE_ARGS = hasSqlite || process.env.WORK_SQLITE_RESPAWNED ? [] : ['--experimental-sqlite', '--disable-warning=ExperimentalWarning'];
if (!hasSqlite && !process.env.WORK_SQLITE_RESPAWNED) {
  const r = spawnSync(process.execPath, [...SQLITE_ARGS, fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit', env: { ...process.env, WORK_SQLITE_RESPAWNED: '1' } });
  process.exit(r.status ?? 1);
}
const serverArgs = process.env.WORK_SQLITE_RESPAWNED ? ['--experimental-sqlite', '--disable-warning=ExperimentalWarning'] : [];
const { openStore } = await import('../core/ledger/store.mjs');
const { validate } = await import('../core/contracts/validate.mjs');

const here = path.dirname(fileURLToPath(import.meta.url));
const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'work-test-'));
const root = path.join(tmp, 'state'); fs.mkdirSync(root, { recursive: true }); fs.mkdirSync(path.join(root, 'jobs'));
const dbFile = path.join(root, 'tide.db');
const t0 = Date.now();
const ago = (h) => new Date(t0 - h * 3600e3).toISOString();
const SHA1 = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678', SHA2 = 'b2c3d4e5f60718293a4b5c6d7e8f901234567890';

// ---- a synthetic event store: 12 open cards (D-1 merge on a PR, D-2 choose A/B/C, D-3..D-12 look), all on example orders ----
const dec = (id, wo, kind, at, extra = {}) => ({ v: '1.0', id, wo, kind, ask: `Example question ${id}?`, options: kind === 'choose' ? ['A', 'B', 'C'] : ['Yes', 'Hold', 'No'],
  recommended: kind === 'choose' ? 'A' : 'Yes', why: 'The example tests are green.', answer: null, note: null, at, answeredAt: null, via: null, ...extra });
const E = (kind, wo, data, at, actor = 'engine') => ({ at, actor, kind, wo, data, proof: null });
const seed = [
  E('wo.created', 'WO-2001', { goal: 'Example: a sunrise colour in the demo sky', stream: 'DEMO' }, ago(50)),
  E('pr.opened', 'WO-2001', { pr: 'example#41', branch: 'wo/example-41', base: 'main', head: SHA1 }, ago(49)),
  E('decision.asked', 'WO-2001', { decision: dec('D-1', 'WO-2001', 'merge', ago(40)) }, ago(40)),
  E('wo.created', 'WO-2002', { goal: 'Example: pick the demo sky look', stream: 'DEMO' }, ago(39)),
  E('decision.asked', 'WO-2002', { decision: dec('D-2', 'WO-2002', 'choose', ago(38), { variants: ['A', 'B', 'C'].map((o) => ({ option: o, title: `Look ${o}`, preview: `mockups/WO-2002/${o.toLowerCase()}.png` })) }) }, ago(38)),
];
for (let i = 3; i <= 12; i++) {
  const wo = `WO-${2000 + i}`;
  seed.push(E('wo.created', wo, { goal: `Example order ${i}`, stream: i % 2 ? 'DEMO' : 'SAMPLE' }, ago(37 - i)));
  seed.push(E('decision.asked', wo, { decision: dec(`D-${i}`, wo, 'look', ago(36 - i)) }, ago(36 - i)));
}
for (let i = 13; i <= 24; i++) seed.push(E('wo.created', `WO-${2000 + i}`, { goal: `Example moving order ${i}`, stream: 'SAMPLE', ...(i === 24 ? { private: true } : {}) }, ago(20 - i / 2)));
seed.push(E('pr.opened', 'WO-2024', { pr: 'example#77', branch: 'wo/privbranch-24', base: 'main', head: SHA2 }, ago(5)));   // a private order on a PR (review F1)
{ const s = await openStore(dbFile); s.append(seed); s.close(); }
const appendNow = async (evs) => { const s = await openStore(dbFile); try { return s.append(evs); } finally { s.close(); } };
const answered = async (id) => { const s = await openStore(dbFile, { readOnly: true }); try { return s.events().filter((e) => e.kind === 'decision.answered' && (!id || e.data.decision === id)); } finally { s.close(); } };

// ---- the real Board server on the throwaway state folder ----
const port = 21000 + Math.floor(Math.random() * 18000);
const server = spawn(process.execPath, [...serverArgs, path.join(here, 'server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
  env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1', KITCHEN_NOTIFY_LOG: path.join(tmp, 'notify.txt'),
    PASS_INCOME_DIR: path.join(tmp, 'empty'), PASS_CAREER_DIR: path.join(tmp, 'empty'), PASS_HOSTS: '', TIDE_DB: '', PASS_WORK_POLL_MS: '150', PASS_WORK_PAGE: '10', PASS_NO_COMPRESS: '1' } });
let serverErr = ''; server.stderr.on('data', (d) => { serverErr += d; });
let KEY = '';

function req(p, o = {}) {
  const { method = 'GET', body, key = KEY, headers = {} } = o;
  return new Promise((ok, no) => {
    const data = body === undefined ? null : typeof body === 'string' ? body : JSON.stringify(body);
    const r = http.request({ host: '127.0.0.1', port, path: p, method, agent: false, headers: { ...(key ? { Authorization: 'Bearer ' + key } : {}), ...(data ? { 'Content-Type': 'application/json' } : {}), ...headers } }, (res) => {
      let t = ''; res.setEncoding('utf8'); res.on('data', (d) => { t += d; }); res.on('end', () => { let j = null; try { j = JSON.parse(t); } catch { } ok({ code: res.statusCode, json: j, headers: res.headers }); });
    });
    r.on('error', no); if (data) r.write(data); r.end();
  });
}
const tap = (decision, answer, requestId, o = {}) => req('/api/decide', { method: 'POST', body: { decision, answer, note: o.note ?? null, via: 'board', requestId }, headers: o.head ? { 'If-Match': `"${o.head}"` } : {}, key: o.key });

/** An SSE client: collects messages; .wait(pred) resolves when one matches. */
function sse(headers = {}) {
  const msgs = []; let buf = ''; const waiters = [];
  const r = http.get({ host: '127.0.0.1', port, path: '/api/work/stream', agent: false, headers: { Authorization: 'Bearer ' + KEY, Accept: 'text/event-stream', ...headers } }, (res) => {
    c.code = res.statusCode; res.setEncoding('utf8'); res.on('end', () => { c.ended = true; }); res.on('close', () => { c.ended = true; });
    res.on('data', (d) => {
      buf += d; let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0, i); buf = buf.slice(i + 2);
        const m = { id: null, event: null, data: null };
        for (const line of block.split('\n')) { if (line.startsWith('id: ')) m.id = line.slice(4); else if (line.startsWith('event: ')) m.event = line.slice(7); else if (line.startsWith('data: ')) { try { m.data = JSON.parse(line.slice(6)); } catch { m.data = 'bad json'; } } }
        if (m.event) { msgs.push(m); for (const w of [...waiters]) if (w.pred(m)) { waiters.splice(waiters.indexOf(w), 1); w.ok(m); } }
      }
    });
  });
  r.on('error', () => { });
  const c = { msgs, code: 0, ended: false, close: () => r.destroy(),
    wait: (pred, ms = 5000) => { const hit = msgs.find(pred); if (hit) return Promise.resolve(hit); return new Promise((ok) => { const w = { pred, ok }; waiters.push(w); setTimeout(() => { const k = waiters.indexOf(w); if (k >= 0) { waiters.splice(k, 1); ok(null); } }, ms); }); } };
  return c;
}

try {
  for (let i = 0; i < 100; i++) { try { if ((await req('/api/health', { key: '' })).code === 200) break; } catch { } await sleep(150); }
  KEY = fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim();

  // ---- the flag ----
  const off = await req('/api/work');
  check('the Work tab is off by default: GET /api/work answers 404 not-found until board.work is on', off.code === 404 && off.json?.code === 'not-found' && /board\.work/.test(off.json?.error || ''), `${off.code} ${JSON.stringify(off.json)}`);
  check('off answers are the contract\'s apiError', validate('api-work', off.json).ok);
  const offTap = await tap('D-3', 'Yes', 'req-off-0001');
  check('a tap while the tab is off writes nothing', offTap.code === 404 && (await answered()).length === 0, `${offTap.code}`);
  await appendNow([{ at: new Date().toISOString(), actor: 'jordan', kind: 'flag.set', wo: null, data: { flag: 'board.work', on: true, decision: 'D-900' }, proof: null }]);

  // ---- auth refused without the key ----
  const noKey = await req('/api/work', { key: '' });
  const badKey = await req('/api/work', { key: 'f'.repeat(64) });
  const noKeyTap = await tap('D-3', 'Yes', 'req-nokey-01', { key: '' });
  const noKeyItem = await req('/api/work/WO-2001', { key: '' });
  const noKeyStream = await req('/api/work/stream', { key: '' });
  check('auth refused without the key: GET /api/work, /api/work/:id and the stream answer 401 without the pass key', noKey.code === 401 && noKeyItem.code === 401 && noKeyStream.code === 401, `${noKey.code} ${noKeyItem.code} ${noKeyStream.code}`);
  check('auth refused without the key: a wrong key is refused too', badKey.code === 401, `${badKey.code}`);
  check('auth refused without the key: POST /api/decide without the key answers 401 and writes no event', noKeyTap.code === 401 && (await answered()).length === 0, `${noKeyTap.code}`);
  const foreign = await req('/api/decide', { method: 'POST', body: { decision: 'D-3', answer: 'Yes', note: null, via: 'board', requestId: 'req-origin-1' }, headers: { Origin: 'https://evil.example' } });
  check('a tap from another site (foreign Origin) is refused 403 before the Work API, as every Board action', foreign.code === 403 && (await answered()).length === 0, `${foreign.code}`);

  // ---- GET /api/work ----
  const w = await req('/api/work');
  const vw = validate('api-work', w.json);
  const allRows = [...(await req('/api/work?page=1')).json.rows, ...(await req('/api/work?page=2')).json.rows, ...(await req('/api/work?page=3')).json.rows];
  const privRow = allRows.find((r) => r.id === 'WO-2024'); const privItem = await req('/api/work/WO-2024');
  check('a private order shows no branch and no PR name (review F1): rows and the item', privRow && privRow.branch === null && privRow.pr === null && privItem.json?.row?.branch === null && !JSON.stringify(allRows).includes('privbranch') && !JSON.stringify(privItem.json).includes('privbranch'), JSON.stringify(privRow));
  check('GET /api/work answers the api-work contract', w.code === 200 && vw.ok, `${w.code} ${vw.errors?.slice(0, 3).join('; ')}`);
  const q = w.json?.queue || [];
  check('the Needs-you queue shows at most 7 cards, oldest first, and counts them all', q.length === 7 && w.json.queueTotal === 12 && q.every((c, i) => i === 0 || q[i - 1].decision.at <= c.decision.at) && q[0].decision.id === 'D-1', `${q.length} / ${w.json?.queueTotal} ${q.map((c) => c.decision.id).join(',')}`);
  const rowsTotal = Number(w.headers['x-rows-total']);
  check('rows are paged (PASS_WORK_PAGE 10): needs-you first, then newest', w.json?.rows.length === 10 && rowsTotal === 24 && w.headers['x-rows-pages'] === '3' && w.json.rows[0].state === 'waiting-on-jordan', `${w.json?.rows.length} of ${rowsTotal}, pages ${w.headers['x-rows-pages']}`);
  const p3 = await req('/api/work?page=3');
  check('page 3 holds the rest and the newest moving orders come last of all pages', p3.code === 200 && p3.json.rows.length === 4 && validate('api-work', p3.json).ok, `${p3.json?.rows?.length}`);
  check('the streams show WIP (open orders, cards per stream, over the 3-card limit)', (w.json?.streams || []).some((s) => s.stream === 'DEMO' && s.cards >= 3 && s.overLimit === true), JSON.stringify(w.json?.streams));

  // ---- GET /api/work/:id ----
  const it = await req('/api/work/WO-2001');
  const vi = validate('api-work-item', it.json);
  check('GET /api/work/:id answers the api-work-item contract, with its events and decisions', it.code === 200 && vi.ok && it.json.events.length === 3 && it.json.decisions[0]?.id === 'D-1', `${it.code} ${vi.errors?.slice(0, 3).join('; ')}`);
  check('GET /api/work/:id names the PR head it shows (ETag)', it.headers.etag === `"${SHA1}"`, String(it.headers.etag));
  const nf = await req('/api/work/WO-9999');
  check('an unknown work order answers 404 not-found', nf.code === 404 && nf.json?.code === 'not-found' && validate('api-work-item', nf.json).ok, `${nf.code}`);
  const bad = await req('/api/work/%E0%A4%A');
  check('a malformed id answers 400 bad-request, not a crash', bad.code === 400 && bad.json?.code === 'bad-request', `${bad.code}`);

  // ---- a tap is bound to the exact card and PR head ----
  const noHead = await tap('D-1', 'Yes', 'req-nohead-1');
  check('a tap on a PR card without the head it was shown is refused (428) and writes nothing', noHead.code === 428 && (await answered('D-1')).length === 0, `${noHead.code} ${noHead.json?.error}`);
  await appendNow([E('pr.updated', 'WO-2001', { pr: 'example#41', head: SHA2, why: 'push' }, new Date().toISOString(), 'github')]);
  const moved = await tap('D-1', 'Yes', 'req-moved-01', { head: SHA1 });
  check('a tap on a PR that moved after the phone looked is refused (412) and writes nothing', moved.code === 412 && /moved/.test(moved.json?.error || '') && (await answered('D-1')).length === 0, `${moved.code} ${moved.json?.error}`);
  const it2 = await req('/api/work/WO-2001');
  check('looking again shows the new head', it2.headers.etag === `"${SHA2}"`, String(it2.headers.etag));

  // ---- decide writes exactly one decision.answered event; replays are idempotent ----
  const yes = await tap('D-1', 'Yes', 'req-yes-0001', { head: SHA2, note: 'Ship it.' });
  const vy = validate('api-decide-result', yes.json);
  const evs1 = await answered('D-1');
  check('decide writes exactly one decision.answered event', yes.code === 200 && vy.ok && yes.json.duplicate === false && evs1.length === 1 && evs1[0].actor === 'jordan' && evs1[0].data.answer === 'Yes' && evs1[0].data.via === 'board', `${yes.code} ${vy.errors?.slice(0, 2).join('; ')} events ${evs1.length}`);
  check('the event carries the PR head the tap was bound to (proof)', evs1[0]?.proof === `example#41 head ${SHA2}`, String(evs1[0]?.proof));
  check('the decide answer is the stored event (same seq, same requestId)', yes.json?.event?.seq === evs1[0]?.seq && yes.json.event.data.requestId === 'req-yes-0001', JSON.stringify(yes.json?.event)?.slice(0, 160));
  const again = await tap('D-1', 'Yes', 'req-yes-0001', { head: SHA2, note: 'Ship it.' });
  check('replays are idempotent: the same requestId answers the first event (duplicate true) and writes nothing', again.code === 200 && again.json?.duplicate === true && again.json.event.seq === yes.json.event.seq && (await answered('D-1')).length === 1, `${again.code} ${JSON.stringify(again.json)?.slice(0, 160)}`);
  const second = await tap('D-1', 'No', 'req-other-002', { head: SHA2 });
  check('a second, different tap on an answered card answers 409 already-answered and writes nothing', second.code === 409 && second.json?.code === 'already-answered' && validate('api-decide-result', second.json).ok && (await answered('D-1')).length === 1, `${second.code}`);
  const race = await Promise.all([tap('D-2', 'B', 'req-race-0001', { note: 'B reads best.' }), tap('D-2', 'C', 'req-race-0002')]);
  const raceEvs = await answered('D-2');
  check('two taps racing on one card write exactly one event (one 200, one 409)', raceEvs.length === 1 && race.map((r) => r.code).sort().join() === '200,409', race.map((r) => r.code).join());
  check('A/B/C writes the choice and the note', raceEvs[0]?.data.answer === 'B' ? raceEvs[0].data.note === 'B reads best.' : raceEvs[0]?.data.answer === 'C', JSON.stringify(raceEvs[0]?.data));
  const wrong = await tap('D-3', 'Maybe', 'req-wrong-001');
  check('an answer that is not one of the card\'s options answers 400 bad-answer', wrong.code === 400 && wrong.json?.code === 'bad-answer', `${wrong.code}`);
  const unknown = await tap('D-777', 'Yes', 'req-unknown-1');
  check('a tap on a card that does not exist answers 404 unknown-card', unknown.code === 404 && unknown.json?.code === 'unknown-card', `${unknown.code}`);
  const proto = await req('/api/decide', { method: 'POST', body: '{"decision":"D-3","answer":"Yes","via":"board","requestId":"req-proto-001","__proto__":{"x":1}}' });
  const ctor = await req('/api/decide', { method: 'POST', body: { decision: 'D-3', answer: 'Yes', via: 'board', requestId: 'req-ctor-0001', constructor: 'x' } });
  check('a body with __proto__ or constructor keys is refused 400 and writes nothing (review F3)', proto.code === 400 && ctor.code === 400 && (await answered('D-3')).length === 0, `${proto.code} ${ctor.code}`);
  const keyInBody = await req('/api/decide', { method: 'POST', body: { decision: 'D-3', answer: 'Yes', via: 'board', requestId: 'req-key-0001', key: KEY } });
  check('a body that carries anything else (a key) is refused 400 bad-request', keyInBody.code === 400 && keyInBody.json?.code === 'bad-request' && (await answered('D-3')).length === 0, `${keyInBody.code}`);
  const notJson = await req('/api/decide', { method: 'POST', body: 'decision=D-3', headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
  check('a tap that is not JSON is refused (415)', notJson.code === 415, `${notJson.code}`);
  const getDecide = await req('/api/decide');
  check('GET /api/decide is refused (405): a tap is a POST', getDecide.code === 405, `${getDecide.code}`);

  // ---- SSE reconnects ----
  const s1 = sse();
  const hello1 = await s1.wait((m) => m.event === 'hello');
  check('the stream starts with hello (queueTotal, not resumed)', hello1?.data?.type === 'hello' && hello1.data.data.resumed === false && hello1.data.data.queueTotal === 10 && validate('api-work-stream', hello1.data).ok, JSON.stringify(hello1?.data));
  await tap('D-3', 'Yes', 'req-sse-00003');
  const gone3 = await s1.wait((m) => m.event === 'card-gone' && m.data?.data?.decision === 'D-3');
  const ev3 = await s1.wait((m) => m.event === 'event' && m.data?.data?.kind === 'decision.answered' && m.data.data.data.decision === 'D-3');
  const row3 = await s1.wait((m) => m.event === 'row' && m.data?.data?.id === 'WO-2003');
  check('a tap reaches an open stream: card-gone, the event and the row', !!gone3 && gone3.data.data.answer === 'Yes' && !!ev3 && !!row3, `${!!gone3} ${!!ev3} ${!!row3}`);
  check('every stream message answers the api-work-stream contract and carries id = its seq', s1.msgs.every((m) => validate('api-work-stream', m.data).ok && String(m.data.seq) === m.id), s1.msgs.filter((m) => !validate('api-work-stream', m.data).ok).map((m) => m.event + ' ' + validate('api-work-stream', m.data).errors[0]).join('; '));
  const lastId = s1.msgs[s1.msgs.length - 1].id;
  s1.close(); await sleep(300);
  await tap('D-4', 'Hold', 'req-sse-00004');   // while the phone is away
  await appendNow([E('decision.asked', 'WO-2013', { decision: dec('D-13', 'WO-2013', 'look', new Date().toISOString()) }, new Date().toISOString())]);
  const s2 = sse({ 'Last-Event-ID': lastId });
  const hello2 = await s2.wait((m) => m.event === 'hello');
  const gone4 = await s2.wait((m) => m.event === 'card-gone' && m.data?.data?.decision === 'D-4');
  const new13 = await s2.wait((m) => m.event === 'card' && m.data?.data?.decision?.id === 'D-13');
  await sleep(400);
  check('SSE reconnects: Last-Event-ID resumes (hello resumed true) with exactly what was missed', hello2?.data?.data?.resumed === true && !!gone4 && gone4.data.data.answer === 'Hold' && !!new13, `${JSON.stringify(hello2?.data?.data)} ${!!gone4} ${!!new13}`);
  check('SSE reconnects: nothing seen before the gap is sent again', !s2.msgs.some((m) => m.event === 'card-gone' && m.data?.data?.decision === 'D-3') && !s2.msgs.some((m) => m.event === 'event' && Number(m.data?.data?.seq) <= Number(lastId)), s2.msgs.map((m) => m.event).join(','));
  check('SSE reconnects: every resumed message answers the contract', s2.msgs.every((m) => validate('api-work-stream', m.data).ok));
  s2.close();
  const s3 = sse({ 'Last-Event-ID': '999999' });
  const hello3 = await s3.wait((m) => m.event === 'hello');
  check('SSE reconnects: an id this store never had is not resumed (the phone reloads /api/work)', hello3?.data?.data?.resumed === false, JSON.stringify(hello3?.data?.data));
  s3.close();
  const s4 = sse(); await s4.wait((m) => m.event === 'hello');
  await appendNow([{ at: new Date().toISOString(), actor: 'jordan', kind: 'flag.set', wo: null, data: { flag: 'board.work', on: false, decision: null }, proof: null }]);
  await sleep(800);
  const offAgain = await req('/api/work');
  check('turning board.work off again closes the tab: 404, and open streams end', offAgain.code === 404 && s4.ended === true, `${offAgain.code} ended ${s4.ended}`);
  s4.close();

  // ---- the flag is read before the store (review F2) ----
  {
    const { WorkApi } = await import('./work/api.mjs');
    const ff = path.join(tmp, 'flags-none.json'); fs.writeFileSync(ff, JSON.stringify({ version: 1, flags: {} }));
    const db2 = path.join(tmp, 'never', 'tide.db');
    const api = new WorkApi({ root: tmp, db: db2, flagsFile: ff }); let why = '';
    try { await api.ready(); } catch (e) { why = e.message; }
    const api2 = new WorkApi({ root: root, db: dbFile }); await api2.sync(); const offSnap = api2.snap; api2.close();
    check('the flag is read first: an undeclared board.work answers off without opening the store, and while off no view is built', /not declared/.test(why) && !fs.existsSync(path.dirname(db2)) && offSnap?.off === true && !offSnap.view, why + ' ' + JSON.stringify(offSnap && Object.keys(offSnap)));
  }
  // ---- what the Board logs ----
  const audit = fs.readFileSync(path.join(root, 'pass-actions.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((l) => l.op === 'work-decide');
  check('every tap is one line in the Board\'s action log, and the note is never written there', audit.length >= 8 && audit.some((l) => l.ok && l.id === 'D-1') && !fs.readFileSync(path.join(root, 'pass-actions.jsonl'), 'utf8').includes('Ship it'), `${audit.length} lines`);
  check('the server wrote no error line', !/work api:|uncaught|unhandled/.test(serverErr), serverErr.slice(0, 300));
} catch (e) { check('the Work tests ran to the end without a crash', false, e.stack || e.message); }
finally {
  try { server.kill(); } catch { }
  await sleep(300); try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { }
}

const failed = results.filter((r) => !r.pass);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}: ${r.name}`);
console.log(`Work tests: ${results.length - failed.length} passed, ${failed.length} failed (${Math.round((Date.now() - t0) / 1000)} s)`);
process.exit(failed.length ? 1 : 0);
