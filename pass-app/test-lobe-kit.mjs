// Shared helpers for the World view's node tests (test-lobe.mjs, test-lobe-trust.mjs): the clock, a csf.json frame in zeitgeistd csf.py's
// exact shape, and throwaway Board servers on temp kitchens (their own keys, no Tailscale, no kicks, no pushes). Runs nothing on import.
import fs from 'node:fs'; import path from 'node:path'; import http from 'node:http';
import { spawn } from 'node:child_process'; import { fileURLToPath } from 'node:url';

export const here = path.dirname(fileURLToPath(import.meta.url));
export const NOW = Date.parse('2026-10-23T18:00:00Z');
export const at = (minAgo, from = NOW) => new Date(from - minAgo * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
export const PRIVATE = ['Yard: WO-0451 handed over (tailor): SECRET-CLIENT-ACME offer', 'Ledger: waiting-on-you [owner] J452: PRIVATE-PACKET-NAME'];
export const pause = (ms) => new Promise((r) => setTimeout(r, ms));
// a results list and its check(): [{name, pass}], printed as JSON by each test file
export function checker() {
  const results = [];
  return { results, check: (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass }) };
}
// a frame in zeitgeistd csf.py's exact shape (TOP_KEYS, META_KEYS, SECTION_KEYS order)
export function frame({ meta = {}, s1 = {}, s2 = {}, s3 = {}, s5 = {}, from = NOW } = {}) {
  return {
    meta: { version: '1.0', state: 'ok', charter: 'EXAMPLE', compiled_utc: at(10, from), last_sweep_utc: at(12, from), csf_age_min: 2, ttc_median_hours: null, loop_state: 'NEAR_THE_LOOP', trust: null,
      counts: { items_24h: 30, world_signals_24h: 4, open_loops: 7, decisions_ready: 1, post_mortems_due: 1 }, trimmed: 2, chars: 2290, tokens_est: 573, ...meta },
    '1_normative_charter': { north_star_objectives: ['WORK: ship the demo', 'HEALTH: sleep <b>7 h</b>'], hard_guardrails: ['WORK: no weekend crunch'], ...s1 },
    '2_endogenous_self_state': { somatic_bandwidth: null, cognitive_mode: null, active_open_loops: ['Is the demo booked?', 'Which CI is free?'], action_backed_focus: [], shadow_blindspots: [], yard_signals: [...PRIVATE], ...s2 },
    '3_exogenous_world_deltas': { actionable_signal: [{ event: 'Model <script>alert(1)</script> beats benchmark', band: 3, scores: { signal: 86, fact: 72, hype: 90, surprise: 68 }, source_brier_trust: 0.71, incentive_note: 'sells inference' },
      { event: 'Privacy law passes', band: 4, scores: { signal: 78, fact: 90, hype: 12, surprise: 61 }, source_brier_trust: null, incentive_note: null }], macro_facts_orientation: [], quarantined_hype_waves: ['AGI next month'], ...s3 },
    '4_epistemic_tensions': { unresolved_dialectics: [] },
    '5_decision_ready_nodes': { unlocked_choices: ['D-0007: A rebook the demo | B send a recording'], pending_post_mortems: ['D-0003: post-mortem due 2026-10-20T09:00:00Z'], ...s5 },
  };
}
export const ok = (f) => ({ ok: true, csf: f, health: { file: 'csf.json' } });
export const cards = (html) => [...html.matchAll(/<section class="lobe-card" data-card="(\w+)"/g)].map((m) => m[1]);
// the Glossary's old names (scripts/names-allow.json) as word regexes
export const oldNames = () => JSON.parse(fs.readFileSync(path.join(here, '..', 'scripts', 'names-allow.json'), 'utf8')).words.map((w) => new RegExp(`\\b(?:${w.pattern})\\b`, 'i'));

export function get(S, p, auth = true) {
  return new Promise((done, fail) => {
    const rq = http.get({ host: '127.0.0.1', port: S.port, path: p, agent: false, headers: auth && S.key ? { Authorization: 'Bearer ' + S.key } : {} }, (res) => {
      const parts = []; res.on('data', (d) => parts.push(d)); res.on('end', () => { const body = Buffer.concat(parts).toString('utf8'); let json = null; try { json = JSON.parse(body); } catch {} done({ code: res.statusCode, body, json }); });
    });
    rq.on('error', fail);
  });
}
// POST /api/lobe with the server's key (or none), optionally from a foreign Origin
export function post(S, body, { auth = true, origin = null } = {}) {
  return new Promise((done, fail) => {
    const data = JSON.stringify(body);
    const rq = http.request({ host: '127.0.0.1', port: S.port, path: '/api/lobe', method: 'POST', agent: false, headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), ...(auth ? { Authorization: 'Bearer ' + S.key } : {}), ...(origin ? { Origin: origin } : {}) } }, (res) => {
      const parts = []; res.on('data', (d) => parts.push(d)); res.on('end', () => { let json = null; try { json = JSON.parse(Buffer.concat(parts).toString('utf8')); } catch {} done({ code: res.statusCode, json }); });
    });
    rq.on('error', fail); rq.end(data);
  });
}
// throwaway servers under tmp: boot(name, lobe home, extra env) -> { root, port, key }; procs to kill at the end
export function servers(tmp) {
  const procs = [];
  async function boot(name, home, extra = {}) {
    const root = path.join(tmp, name); fs.mkdirSync(path.join(root, 'jobs'), { recursive: true }); fs.mkdirSync(root + '-none', { recursive: true });
    const port = 22000 + Math.floor(Math.random() * 17000);
    procs.push(spawn(process.execPath, [path.join(here, 'server.mjs')], { stdio: 'ignore', windowsHide: true, env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', PASS_HOSTS: '',
      BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1', KITCHEN_NOTIFY_LOG: root + '-notify.txt', PASS_INCOME_DIR: root + '-none', PASS_CAREER_DIR: root + '-none', ZEITGEISTD_HOME: home, ZEITGEISTD_CHARTER: path.join(root + '-office', 'CHARTER.md'), ...extra } }));
    const S = { root, port, key: '' };
    for (let i = 0; i < 100 && !S.key; i++) { await pause(150); try { if ((await get(S, '/api/health')).code === 200) S.key = fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim(); } catch {} }
    return S;
  }
  // stop every server and remove tmp; run(): the server checks as one step, a crash is one failed check, then stop
  async function stop() {
    for (const p of procs) { try { p.kill(); } catch {} }
    await pause(300);
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
  }
  const crashed = (check, e) => check('server checks ran without a crash', false, e.message);
  async function run(check, fn) { try { await fn(); } catch (e) { crashed(check, e); } finally { await stop(); } }
  return { procs, boot, run, stop, crashed };
}
