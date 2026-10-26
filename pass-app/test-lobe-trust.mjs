// Tests for the Board's Trust card (ZG-40: pass-app/public/lobe.js trustCard and server.mjs trustView / signoffAct): synthetic files only, never the
// live lobe. Run by tests/Test-PassApp.ps1 beside test-lobe.mjs (split from it at the 600-line standard; shared helpers in test-lobe-kit.mjs).
// Pure checks on empty, partial and full trust state, then throwaway servers on temp kitchens, then static checks on server.mjs. Prints [{name, pass}].
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os';
import { worldHtml, trustCard, trendOf } from './public/lobe.js';
import { here, NOW, at, pause, checker, ok, frame, cards, oldNames, get, post, servers } from './test-lobe-kit.mjs';

const { results, check } = checker();

// ---- ZG-40: the Trust card (pure, synthetic state.lobeOwner.trust in server.mjs trustView's shape): empty, partial and full ----
{
  const none = (why) => ({ ok: false, why });
  const EMPTY = { file: none('no trust.json yet: the lobe writes it on its trust run (zeitgeistd trust run, ZG-39)'), board: none('no scoreboard.jsonl yet: the Yard writes it each morning (scoreboard.ps1 -Record)'),
    watch: none('no watch\\memory.json yet: memory-truth writes it every hour'), signoffs: { ...none('no signoffs.jsonl yet: the lobe writes one when ...'), pending: [] } };
  const fam = (status, brier = null, n = 0, x = {}) => ({ status, brier, n, ...x });
  const PARTIAL = { file: { ok: true, compiledUtc: at(30), foreman: fam('no resolved claims', null, 0, { claims: 10, pending: 10 }), world: fam('no resolved claims', null, 0, { sourcesScored: 0, sourcesMeanTrust: null, sources: null }),
      crews: fam('unset', null, 0, { members: [] }), builders: fam('no brier in the scoreboard', null, 0, { members: [] }) },
    board: { ok: true, at: at(60), firstAt: at(60 * 24 * 2), weekAgo: null, now: { value: 0.44, claims: 9, pending: 1, inspector: { value: 0.5, claims: 6 }, builder: { value: 0.33, claims: 3 }, missing: null, models: [{ id: 'claude/sonnet', value: 0, claims: 3 }, { id: 'local/qwen3.5:9b', value: 0.33, claims: 3 }] } },
    watch: { ok: true, unproven: 7, field: 'warn', lastRun: at(90) }, signoffs: { ok: true, pending: [] } };
  const old = { at: at(60 * 24 * 8), value: 0.6, claims: 5, pending: 0, inspector: { value: 0.6, claims: 5 }, builder: { value: null, claims: 0 }, missing: null, models: [{ id: 'claude/sonnet', value: 0.1, claims: 2 }, { id: 'local/qwen3.5:9b', value: 0.33, claims: 2 }] };
  const so = (id, x = {}) => ({ id, privacy: 'P0', source: 'rss.hn', sourceName: 'Hacker <b>News</b>', status: 'REFUTED', from: 0.8, to: 0.62, delta: -0.18, created: at(120), answered: null, ...x });
  const FULL = { file: { ok: true, compiledUtc: at(30), foreman: fam('ok', 0.0833, 3, { claims: 5, pending: 2 }), world: fam('ok', 0.5, 2, { sourcesScored: 6, sourcesMeanTrust: 0.6,
      sources: [['rss.hn', 0.1, 9], ['rss.lobsters', 0.2, 7], ['arxiv', 0.3, 5], ['gov.feed', 0.4, 4], ['blog.x', 0.5, 3]].map(([id, brier, n]) => ({ id, brier, n })) }),
      crews: fam('unset', null, 0, { members: [] }), builders: fam('ok', 0.25, 4, { members: [{ id: 'explore', brier: 0.25, n: 4 }] }) },
    board: { ...PARTIAL.board, weekAgo: old }, watch: { ok: true, unproven: 5, field: 'unproven', lastRun: at(90) },
    signoffs: { ok: true, pending: [so('B-0123456789abcdef'), so('B-fedcba9876543210', { privacy: 'P2', source: null, sourceName: null, status: 'VERIFIED', from: 0.3, to: 0.5, delta: 0.2 }), so('B-1111111111111111', { answered: { choice: 'drop', at: at(5) } })] } };
  const own = (t) => ({ charter: { state: 'none' }, proposals: [], taste: [], decide: { ok: true, updated: at(5), ready: [], due: [] }, trust: t });
  const rowOf = (h, k) => (h.split(`data-trust="${k}"`)[1] || '').split(/<li class="lobe-dec"|<\/ul>/)[0];
  const e = trustCard(EMPTY, NOW), p = trustCard(PARTIAL, NOW), f = trustCard(FULL, NOW);
  check('ZG40-1 the Trust card sits on the World view after Decisions, with the Owner part, also with no frame', cards(worldHtml(ok(frame()), { now: NOW, owner: own(FULL) })).join() === 'charter,loops,signals,taste,decide,trust,self,health'
    && cards(worldHtml({ ok: false, why: 'no frame yet' }, { now: NOW, owner: own(EMPTY) })).join() === 'charter,taste,decide,trust,self' && !cards(worldHtml(ok(frame()), { now: NOW })).includes('trust'));
  check('ZG40-3 empty: no trust.json is UNKNOWN with the reason; every row says unknown (why), never a number', e.includes('lobe-badge example">UNKNOWN') && e.includes('trust.json unknown: no trust.json yet')
    && rowOf(e, 'foreman').includes('Brier</span><b>unknown (no trust.json yet') && rowOf(e, 'foreman').includes('unproven bullets unknown (no watch\\memory.json yet') && rowOf(e, 'crews').includes('unknown (no scoreboard.jsonl yet')
    && rowOf(e, 'builders').includes('unknown (no trust.json yet') && rowOf(e, 'world').includes('unknown (no trust.json yet') && !/lobe-hp/.test(e) && e.includes('Sign-offs unknown: no signoffs.jsonl yet') && !e.includes('data-signoff='));
  check('ZG40-3 partial: the Foreman unknown with how many resolved (0 of 10), unproven 7 from the Watch\'s warn count, trend unknown (no history)', rowOf(p, 'foreman').includes('Brier</span><b>unknown (0 of 10 claims resolved so far)')
    && rowOf(p, 'foreman').includes('7 unproven bullets in memory (memory-truth&#39;s warn count)') && rowOf(p, 'foreman').includes('7-day trend unknown (trust.json keeps no history yet)'));
  check('ZG40-1 partial: crews from the scoreboard (one row per model, most claims first), Brier gauge, claims counted; trend unknown with no line 7 days before', rowOf(p, 'crews').includes('<b>0.44</b>') && rowOf(p, 'crews').includes('9 claims counted')
    && rowOf(p, 'crew:claude/sonnet').includes('<b>0.00</b>') && rowOf(p, 'crew:local/qwen3.5:9b').includes('3 claims counted') && rowOf(p, 'crews').includes('7-day trend unknown (no scoreboard line from 7 days before; the first with Brier is from 2026-10-21)')
    && p.includes('Inspector said ship: 0.50 over 6 · build crews said the tests pass: 0.33 over 3 · 1 kept merge is still inside its 7 days'));
  check('ZG40-1 partial: subcontractors unknown with trust.json\'s status, world claims unknown, top 5 sources unknown (trust.json has only their mean)', rowOf(p, 'builders').includes('nothing scores them yet: trust.json&#39;s builders family says &quot;no brier in the scoreboard&quot;')
    && rowOf(p, 'world').includes('unknown (the lobe says &quot;no resolved claims&quot;)') && rowOf(p, 'sources').includes('Top 5 sources unknown (trust.json carries no per-source scores yet, only their mean)') && !/lobe-badge/.test(p.split('lobe-name')[1].split('</div>')[0]));
  check('ZG40-1 full: the Foreman 0.08 over 3 of 5, 5 unproven (the Watch\'s unproven count)', rowOf(f, 'foreman').includes('<b>0.08</b>') && rowOf(f, 'foreman').includes('3 claims counted') && rowOf(f, 'foreman').includes('5 unproven bullets in memory (memory-truth&#39;s unproven count)'));
  check('ZG40-1 full: 7-day trend arrows against the line 8 days old: all crews better, one model worse... flat, a falling Brier is better', rowOf(f, 'crews').includes('data-trend="better"') && rowOf(f, 'crews').includes('7-day trend ↓ better (0.60 → 0.44)')
    && rowOf(f, 'crew:claude/sonnet').includes('7-day trend ↓ better (0.10 → 0.00)') && rowOf(f, 'crew:local/qwen3.5:9b').includes('7-day trend → flat (0.33 both)'));
  check('ZG40 trendOf: lower Brier is better, higher worse, the same flat, a missing side null', trendOf(0.2, 0.3).dir === 'better' && trendOf(0.31, 0.3).dir === 'worse' && trendOf(0.301, 0.3).dir === 'flat' && trendOf(null, 0.3) === null && trendOf(0.2, undefined) === null);
  check('ZG40-1 full: subcontractor rows from trust.json, world claims 0.50 over 2 with the mean source trust, the top 5 sources each with Brier and claims', rowOf(f, 'sub:explore').includes('<b>0.25</b>') && rowOf(f, 'world').includes('mean trust 0.60 over 6 scored sources')
    && ['rss.hn', 'rss.lobsters', 'arxiv', 'gov.feed', 'blog.x'].every((s) => f.includes(`data-trust="source:${s}"`)) && rowOf(f, 'source:rss.hn').includes('9 claims counted'));
  const s1 = (f.split('data-signoff-node="B-0123456789abcdef"')[1] || '').split('</li>')[0], s2 = (f.split('data-signoff-node="B-fedcba9876543210"')[1] || '').split('</li>')[0], s3 = (f.split('data-signoff-node="B-1111111111111111"')[1] || '').split('</li>')[0];
  check('ZG40-2 Sign-offs: Apply / Drop per pending Brier change, the move and its status; the name escaped; a P2 source unnamed', s1.includes('data-signoff="B-0123456789abcdef" data-choice="apply"') && s1.includes('data-signoff="B-0123456789abcdef" data-choice="drop"')
    && s1.includes('Hacker &lt;b&gt;News&lt;/b&gt;: trust 0.80 → 0.62 (-0.18)') && s1.includes('>REFUTED<') && s2.includes('a P2 source (its name stays in the lobe): trust 0.30 → 0.50 (+0.20)') && !f.includes('<b>News</b>'));
  check('ZG40-2 an answered Sign-off shows the choice and no tap; the badge counts the 2 still waiting', s3.includes('You chose Drop 5 min ago. The lobe applies it on its next run.') && !s3.includes('data-signoff=') && /lobe-badge count">2</.test(f));
  const names = oldNames();
  const shown = [e, p, f].join(' ').replace(/<[^>]*>/g, ' ');
  check('ZG40 the Glossary\'s words (Foreman, crews, Subcontractors, Sign-offs); no old name, no "builder" label', names.every((rx) => !rx.test(shown)) && !/\bbuilders?\b(?! family)/i.test(shown) && /Subcontractors/.test(shown), names.filter((rx) => rx.test(shown)).join(' '));
  check('ZG40 no style attribute (strict CSP; the card uses the World view\'s classes only)', !/\sstyle=/.test(e + p + f) && [...(e + p + f).matchAll(/class="([^"]+)"/g)].every((m) => m[1].split(' ').every((c) => /^(lobe-[a-z]+|btn|primary|mono|on|good|mid|bad|example|count|locked|s)$/.test(c))));
}

// ---- the server, on throwaway kitchens ----
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'board-trust-'));
const { boot, run } = servers(tmp);
await run(check, async () => {
  // ---- ZG-40: trust.json, scoreboard.jsonl's brier, watch\memory.json and signoffs.jsonl on a throwaway kitchen (each in its writer's exact shape) ----
  const homeF = path.join(tmp, 'f-lobe'); fs.mkdirSync(homeF, { recursive: true });
  const [F, C] = await Promise.all([boot('f', homeF), boot('c', path.join(tmp, 'evie', 'lobe'))]);   // C: a lobe home inside a protected path
  const actsF = path.join(F.root, 'pass-actions.jsonl');
  const linesF = () => { try { return fs.readFileSync(actsF, 'utf8').split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
  const trustOf = async () => { const r = await get(F, '/api/state'); return { t: r.json?.lobeOwner?.trust, body: JSON.stringify(r.json?.lobeOwner?.trust ?? null) }; };   // body: the trust part only (the state's older scoreboard field carries its own line)
  const t0 = (await trustOf()).t;
  check('ZG40-3 empty: no file at all, each part is ok:false with the reason in fixed words', t0?.file?.ok === false && /^no trust\.json yet/.test(t0.file.why) && t0.board?.ok === false && /^no scoreboard\.jsonl yet/.test(t0.board.why)
    && t0.watch?.ok === false && /^no watch\\memory\.json yet/.test(t0.watch.why) && t0.signoffs?.ok === false && t0.signoffs.pending.length === 0 && /trust\.json unknown/.test(trustCard(t0, Date.now())), JSON.stringify(t0));
  const isoF = (msAgo) => new Date(Date.now() - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
  // trust.json as zeitgeistd trust.py run() writes it (json.dumps indent=1, sort_keys): partial first (nothing resolved, crews unset)
  const famPy = (status, x = {}) => ({ brier: null, n: 0, status, trust: null, ...x });
  const trustDoc = (fams) => JSON.stringify({ compiled_utc: isoF(60000), families: fams, line: 'foreman brier unknown (0 of 10 claims resolved); 6 unproven bullets SECRET-LINE', run: { capped: 0, refuted: 0, resolved: 0, verified: 0 }, settle_hours: 24, version: 1,
    watch: { findings: 0, last_run: isoF(3600000), state: 'ok', unproven: 7 } }, null, 1);
  fs.writeFileSync(path.join(homeF, 'trust.json'), trustDoc({ builders: famPy('unset'), crews: famPy('unset'), foreman: famPy('no resolved claims', { claims: 10, pending: 10, unproven: 6 }),
    world: famPy('no resolved claims', { sources_mean_trust: null, sources_scored: 0 }) }));
  fs.mkdirSync(path.join(F.root, 'watch'), { recursive: true });
  fs.writeFileSync(path.join(F.root, 'watch', 'memory.json'), JSON.stringify({ name: 'memory-truth', lastRun: isoF(3600000), checked: 112, found: 0, everyMin: 60, memoryDir: 'C:\\Users\\x\\SECRET-DIR', findings: [], warn: 7, warnings: ['SECRET-WARNING bullet text'] }));
  await pause(60);
  const t1 = await trustOf();
  check('ZG40-3 partial trust.json: statuses and counts read, nothing scored; the Watch\'s warn count (no unproven field yet)', t1.t?.file?.ok === true && t1.t.file.foreman.status === 'no resolved claims' && t1.t.file.foreman.claims === 10 && t1.t.file.foreman.brier === null
    && t1.t.file.crews.status === 'unset' && t1.t.file.world.sources === null && t1.t.watch?.ok === true && t1.t.watch.unproven === 7 && t1.t.watch.field === 'warn', JSON.stringify(t1.t?.file));
  check('rule: counts only: trust.json\'s line, the Watch\'s folder and warning text never reach the phone', !t1.body.includes('SECRET') && !(await get(F, '/api/state')).body.includes('SECRET'));
  // scoreboard.jsonl as kitchen/scoreboard.ps1 -Record writes it: a line from before ZG-22 (no brier), one 8 days ago, a torn line, today's
  const sb = (msAgo, brier) => JSON.stringify({ at: new Date(Date.now() - msAgo).toISOString(), days: 7, orders: 4, firstTryPct: 50, jobs: [{ id: 'J9', title: 'SECRET-JOB-TITLE' }], ...(brier ? { brier } : {}) });
  const bz = (value, claims, models) => ({ value, claims, pending: 1, inspector: { value, claims }, builder: { value: null, claims: 0 }, models, kinds: [{ kind: 'code', model: 'local/qwen3.5:9b', value, claims }], missing: '' });
  fs.writeFileSync(path.join(F.root, 'scoreboard.jsonl'), [sb(10 * 86400000), sb(8 * 86400000, bz(0.6, 5, { 'claude/sonnet': { value: 0.1, claims: 2 } })), '{"torn":', sb(3600000, bz(0.44, 9, { 'claude/sonnet': { value: 0, claims: 3 }, 'local/qwen3.5:9b': { value: 0.33, claims: 3 }, 'bad key <x>': { value: 1, claims: 1 } }))].join('\n') + '\n');
  await pause(60);
  const t2 = await trustOf(), bd = t2.t?.board;
  check('ZG40-1 scoreboard.jsonl: today\'s brier per crew model and the line 7+ days older for the trend; lines without brier, torn lines and bad keys skipped', bd?.ok === true && bd.now.value === 0.44 && bd.now.claims === 9 && bd.now.models.map((m) => m.id).join() === 'claude/sonnet,local/qwen3.5:9b'
    && bd.weekAgo?.value === 0.6 && bd.weekAgo.models[0].value === 0.1 && !t2.body.includes('SECRET-JOB-TITLE'), JSON.stringify(bd));
  check('ZG40-1 the card from the served state: crews 0.44 better than 0.60 a week ago', /7-day trend ↓ better \(0\.60 → 0\.44\)/.test(trustCard(t2.t, Date.now())));
  // full trust.json, the Watch's unproven count (ZG-38), and signoffs.jsonl as claims.py write_signoffs() writes it
  fs.writeFileSync(path.join(homeF, 'trust.json'), trustDoc({ builders: famPy('ok', { brier: 0.25, n: 4, trust: 0.75, members: { explore: { brier: 0.25, n: 4 }, '<img src=x>': { brier: 0.5, n: 1 } } }), crews: famPy('no brier in the scoreboard'),
    foreman: famPy('ok', { brier: 0.0833, n: 3, trust: 0.9167, claims: 5, pending: 2, unproven: 2 }), world: famPy('ok', { brier: 0.5, n: 2, trust: 0.5, sources_mean_trust: 0.6, sources_scored: 2 }) }));
  fs.writeFileSync(path.join(F.root, 'watch', 'memory.json'), JSON.stringify({ lastRun: isoF(60000), warn: 7, unproven: 5, warnings: ['SECRET-WARNING'] }));
  const sLine = (id, x = {}) => JSON.stringify({ claim: 'C-1', created: isoF(7200000), delta: -0.18, from: 0.8, id, kind: 'brier', outcome: 0, privacy: 'P0', source: 'rss.hn', source_name: 'Hacker News', state: 'pending', statement: 'SECRET-STATEMENT of the claim', status: 'REFUTED', to: 0.62, weight: 0.25, why: '|delta| 0.1800 > 0.15', ...x });
  const soP = path.join(homeF, 'signoffs.jsonl');
  fs.writeFileSync(soP, [sLine('B-0123456789abcdef'), sLine('B-fedcba9876543210', { privacy: 'P2', source: 'mail.private', source_name: 'SECRET-PRIVATE-SOURCE', statement: null, status: 'VERIFIED', from: 0.3, to: 0.5, delta: 0.2 }),
    sLine('B-2222222222222222', { state: 'applied' }), sLine('not-an-id'), 'not json'].join('\n') + '\n');
  await pause(60);
  const t3 = await trustOf();
  check('ZG40-3 full trust.json: the Foreman 0.0833 over 3 of 5, world 0.5 over 2 with the mean source trust, subcontractor members (a bad name dropped)', t3.t?.file?.foreman?.brier === 0.0833 && t3.t.file.foreman.n === 3 && t3.t.file.foreman.claims === 5
    && t3.t.file.world.brier === 0.5 && t3.t.file.world.sourcesMeanTrust === 0.6 && t3.t.file.builders.members.map((m) => m.id).join() === 'explore' && t3.t.watch.unproven === 5 && t3.t.watch.field === 'unproven', JSON.stringify(t3.t?.file));
  check('ZG40-2 signoffs.jsonl: the pending Brier Sign-offs only (applied, bad id and torn lines skipped); a P2 source has no name or id; no statement leaves', t3.t?.signoffs?.ok === true && t3.t.signoffs.pending.map((s) => s.id).join() === 'B-0123456789abcdef,B-fedcba9876543210'
    && t3.t.signoffs.pending[0].sourceName === 'Hacker News' && t3.t.signoffs.pending[1].sourceName === null && t3.t.signoffs.pending[1].source === null && !t3.body.includes('SECRET'), JSON.stringify(t3.t?.signoffs));
  const postF = (body) => post(F, body);
  const badF = [await postF({ op: 'decision', signoff: 'B-0123456789abcdef', choice: 'maybe' }), await postF({ op: 'decision', signoff: 'B-2222222222222222', choice: 'apply' }), await postF({ op: 'decision', signoff: 'B-9999999999999999', choice: 'drop' })];
  check('ZG40-2 refused: a choice that is not Apply or Drop, an applied or unknown Sign-off (no tap written)', badF.every((r) => r.json?.ok === false) && linesF().every((l) => l.ok === false), badF.map((r) => r.json?.error).join(' | '));
  const ap = await postF({ op: 'decision', signoff: 'B-0123456789abcdef', choice: 'apply' }), laF = linesF().pop();
  check('ZG40-2 Apply is one `decision` line {signoff, choice} in tap_line\'s shape (claims.py reads it)', ap.json?.ok === true && Object.keys(laF).join() === 'ts,op,ok,who,signoff,choice' && laF.op === 'decision' && laF.signoff === 'B-0123456789abcdef' && laF.choice === 'apply' && laF.who === 'key');
  await pause(60);
  const t4 = (await trustOf()).t, againF = await postF({ op: 'decision', signoff: 'B-0123456789abcdef', choice: 'drop' });
  check('ZG40-2 the Sign-off shows the answer; a second answer before the lobe\'s run is refused', t4?.signoffs?.pending[0].answered?.choice === 'apply' && againF.json?.ok === false && /already answered/.test(againF.json.error) && linesF().filter((l) => l.ok && l.signoff === 'B-0123456789abcdef').length === 1);
  check('ZG40-2 Drop works the same', (await postF({ op: 'decision', signoff: 'B-fedcba9876543210', choice: 'drop' })).json?.ok === true && linesF().pop().choice === 'drop');
  await pause(40);
  fs.writeFileSync(soP, sLine('B-0123456789abcdef') + '\n');   // the lobe ran after the tap and it is still pending: it refused the tap
  await pause(60);
  check('ZG40-2 after the lobe\'s run a Sign-off still pending can be tapped again', (await trustOf()).t?.signoffs?.pending[0].answered === null && (await postF({ op: 'decision', signoff: 'B-0123456789abcdef', choice: 'drop' })).json?.ok === true);
  fs.writeFileSync(path.join(homeF, 'trust.json'), '{"families": SECRET-BROKEN'); await pause(60);
  const t5 = await trustOf();
  check('ZG40-3 a broken trust.json is unknown in fixed words; its text never leaves', t5.t?.file?.ok === false && /not the lobe's/.test(t5.t.file.why) && !t5.body.includes('SECRET'));
  const tC = (await get(C, '/api/state')).json?.lobeOwner?.trust;
  check('ZG40 a lobe home inside a protected path: trust.json and signoffs.jsonl are not read', /inside a protected path/.test(tC?.file?.why || '') && /inside a protected path/.test(tC?.signoffs?.why || ''));
});

// ---- ZG-40: the trust readers read files only, and the Sign-off tap writer is reached only from lobeAct ----
{
  const src = fs.readFileSync(path.join(here, 'server.mjs'), 'utf8');
  const body = src.slice(src.indexOf('// ---- ZG-40: the Trust card'), src.indexOf('// a push (counts only, with push on)'));
  check('ZG40-3 no database on the event loop: the trust readers use fs only (no child process, no worker, no sqlite, no database file, no fetch)', body.length > 3000 && /fs\.readFileSync/.test(body) && /tailLines\(/.test(body)
    && !/child_process|execFile|execSync|(?<!\.)\bexec\(|spawn|Worker|sqlite|memory\.db|\.db\b|fetch\(|require\(/.test(body));
  const calls = (name) => (src.match(new RegExp(`\\b${name}\\(`, 'g')) || []).length;
  check('ZG40-2 signoffAct is called only from lobeAct (behind POST /api/lobe) and writes one tap through tapAppend', calls('signoffAct') === 2 && /if \(op === 'decision' && body\.signoff !== undefined\) return signoffAct\(who, body\)/.test(src.slice(src.indexOf('function lobeAct(req, body)'), src.indexOf('// ---- ZG-25')))
    && (body.match(/tapAppend\(/g) || []).length === 1);
  check('ZG40-1 the board state carries the trust view inside the Owner part, keyed on the four files (a change is a patch)', /trust: trustView\(\)/.test(src) && /sigOf\(lobeFile\(\)\), trustSigs\(\)/.test(src));
}
console.log(JSON.stringify(results));
process.exit(results.every((r) => r.pass) ? 0 : 1);
