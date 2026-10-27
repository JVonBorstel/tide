// The phone speed budget runner: two throwaway Board servers on fixture Yards, N scripted sessions in headless Chrome, the median judged
// against budget.json, a JSON report and a markdown summary. Called by .github/workflows/speed.yml and by hand (pass-app/SPEED.md).
//   node pass-app/speed/run.mjs [--runs N] [--out speed-report.json] [--summary file.md] [--enforce]
// Exit 0 when report-only (the numbers never fail it), 1 when enforcing and a metric is over its hard limit, 2 when the run itself broke.
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import http from 'node:http';
import { spawn } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { makeYard } from './fixture.mjs';
import { busyRun, calmRun, profileLine } from './scenario.mjs';
import { summarize, medianOf, judge, sizeReport, markdown } from './report.mjs';

const here = path.dirname(fileURLToPath(import.meta.url)), app = path.resolve(here, '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arg = (name, dflt) => { const i = process.argv.indexOf('--' + name); return i < 0 ? dflt : process.argv[i + 1]; };

const health = (port) => new Promise((ok) => {
  const r = http.get({ host: '127.0.0.1', port, path: '/api/health', timeout: 2000 }, (res) => { res.resume(); ok(res.statusCode === 200); });
  r.on('error', () => ok(false)); r.on('timeout', () => { r.destroy(); ok(false); });
});
// a Board server on a fixture Yard: its own port, key and folders; no phone alerts, no Tailscale, no work started
async function startServer(tmp, kind) {
  const root = makeYard(tmp, kind), port = 21000 + Math.floor(Math.random() * 18000), empty = path.join(root, 'empty');
  const proc = spawn(process.execPath, [path.join(app, 'server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
    env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1',
      KITCHEN_NOTIFY_LOG: path.join(root, 'notify.txt'), PASS_INCOME_DIR: empty, PASS_CAREER_DIR: empty, PASS_HOSTS: '' } });
  let err = ''; proc.stderr.on('data', (d) => { err = (err + d).slice(-4000); });
  for (let i = 0; i < 120 && !(await health(port)); i++) { if (proc.exitCode !== null) break; await sleep(250); }
  if (!(await health(port))) { proc.kill(); throw new Error(`the ${kind} Board server did not start: ${err.trim() || 'no output'}`); }
  return { kind, port, proc, key: fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim() };
}
// Chrome: CHROME_PATH, else the usual places (the GitHub runner has Google Chrome), else Playwright's own download if present
function chromePath() {
  const c = [process.env.CHROME_PATH, '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser',
    'C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'];
  return c.find((p) => p && fs.existsSync(p));
}
// GitHub annotations: a warning per metric over target (and over the hard limit while report-only), an error per one over it when enforcing
function annotate(rows, enforce, size) {
  for (const r of rows) {
    if (r.status === 'ok' || r.status === 'n/a') continue;
    const over = r.status === 'over', lvl = over && enforce ? 'error' : 'warning';
    console.log(`::${lvl} title=Speed budget::${r.label}: ${r.value}${r.unit ? ' ' + r.unit : ''} is over the ${over ? 'hard limit ' + r.hard : 'target ' + r.target}${over && !enforce ? ' (report only)' : ''}`);
  }
  if (size.warn) console.log(`::warning title=Size report::Board scripts are ${size.scriptsBrotliKB} KB brotli, past the ${size.warnBrotliKB} KB warning line`);
}
async function measure(runs) {
  const { chromium } = await import('playwright-core');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tide-speed-')), servers = [];
  let browser = null;
  try {
    servers.push(await startServer(tmp, 'busy'), await startServer(tmp, 'calm'));
    const exe = chromePath();
    browser = await chromium.launch({ headless: true, ...(exe ? { executablePath: exe } : {}) });
    const out = [];
    for (let i = 0; i < runs; i++) {
      const busy = await busyRun(browser, servers[0]); const calm = await calmRun(browser, servers[1]);
      out.push(summarize(busy, calm)); console.log(`run ${i + 1}/${runs}: ${JSON.stringify(out.at(-1))}`);
    }
    return { runs: out, browser: browser.version() };
  } finally {
    await browser?.close().catch(() => {});
    for (const s of servers) s.proc.kill();
    await sleep(300); fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}
async function main() {
  const budget = JSON.parse(fs.readFileSync(path.join(here, 'budget.json'), 'utf8'));
  const enforce = budget.enforce === true || process.argv.includes('--enforce') || process.env.SPEED_ENFORCE === '1';
  const runs = Math.max(1, Number(arg('runs', process.env.SPEED_RUNS || budget.runs)) || 3);
  const { runs: all, browser } = await measure(runs);
  const median = medianOf(all), rows = judge(median, budget), size = sizeReport(path.join(app, 'public'), budget.size.warnBrotliKB);
  const report = { at: new Date().toISOString(), browser, profile: profileLine(), enforce, runs: all, median, rows, size };
  fs.writeFileSync(arg('out', 'speed-report.json'), JSON.stringify(report, null, 2));
  const md = markdown({ rows, median, size, enforce, runs, profile: profileLine() + ', ' + browser });
  const sum = arg('summary', process.env.GITHUB_STEP_SUMMARY || '');
  if (sum) fs.appendFileSync(sum, md + '\n'); else console.log('\n' + md);
  annotate(rows, enforce, size);
  const over = rows.filter((r) => r.status === 'over');
  console.log(`Speed budget: ${rows.filter((r) => r.status === 'ok').length} ok, ${rows.filter((r) => r.status === 'warn').length} over target, ${over.length} over the hard limit${enforce ? '' : ' (report only)'}`);
  return enforce && over.length ? 1 : 0;
}
main().then((c) => process.exit(c), (e) => { console.error('Speed budget run failed: ' + (e?.stack || e)); process.exit(2); });
