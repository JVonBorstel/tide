// Owns the tests of the capacity governor (core/engine/governor.mjs): it reads usage, holds heavy crews at and above the threshold,
// and reads "unknown" usage as hold, not run. Synthetic plan-usage.json files in a scratch folder; the live state folder is never read.
// Called by tests/core/engine/test-engine.mjs.
import fs from 'node:fs'; import path from 'node:path';
import { readUsage, usageOf, decide, LIMITS } from '../../../core/engine/governor.mjs';
import { check, tmp } from './lib.mjs';

const NOW = new Date('2030-01-07T09:00:00Z');
const doc = (used, extra = {}) => ({ claude: { at: '2030-01-07T08:55:00Z', status: 'allowed', window: 'five_hour', fiveHour: { used, resetsAt: '2030-01-07T11:00:00Z' }, sevenDay: { used: 0.3 }, ...extra } });

export async function run() {
  await runCli();
  const dir = tmp('gov');
  try {
    const file = path.join(dir, 'plan-usage.json');
    fs.writeFileSync(file, JSON.stringify(doc(0.42)));
    const u = readUsage(file, NOW);
    check('governor reads usage: the 5-hour share, the weekly share and the reset time from plan-usage.json', u.known && u.used === 0.42 && u.weekly === 0.3 && u.resetsAt === '2030-01-07T11:00:00Z', JSON.stringify(u));
    check('governor: under 70 % a heavy crew runs', decide('heavy', u, { now: NOW }).verdict === 'run');
    const at70 = decide('heavy', usageOf(doc(LIMITS.hold), NOW), { now: NOW });
    const at84 = decide('heavy', usageOf(doc(0.84), NOW), { now: NOW });
    check('governor holds heavy crews above the threshold: at 70 % and 84 % no new heavy crew, with the reason', !at70.go && at70.verdict === 'hold' && !at84.go && /70 %/.test(at84.why), `${at70.verdict} ${at84.why}`);
    const at85 = decide('heavy', usageOf(doc(0.85), NOW), { now: NOW });
    check('governor: at 85 % it says stop (finish the current step, start nothing)', !at85.go && at85.verdict === 'stop', at85.why);
    check('governor: a held step waits until the window resets (2 h here), at least 15 min', at70.retrySec === 7200 && decide('heavy', usageOf(doc(0.9, { fiveHour: { used: 0.9, resetsAt: '2030-01-07T08:59:00Z' } }), NOW), { now: NOW }).retrySec === 900);
    const unknowns = {
      'no file': readUsage(path.join(dir, 'missing.json'), NOW),
      'not JSON': (fs.writeFileSync(path.join(dir, 'bad.json'), '{oops'), readUsage(path.join(dir, 'bad.json'), NOW)),
      'no claude block': usageOf({}, NOW),
      'no number': usageOf(doc('high'), NOW),
      'no time': usageOf({ claude: { fiveHour: { used: 0.1 } } }, NOW),
      'older than 30 min': usageOf({ claude: { ...doc(0.1).claude, at: '2030-01-07T08:00:00Z' } }, NOW),
      'status not allowed': usageOf(doc(0.1, { status: 'rejected' }), NOW),
      'no weekly reading': usageOf(doc(0.1, { sevenDay: undefined }), NOW),
      'stale, even right before a reset': usageOf({ claude: { ...doc(0.1, { fiveHour: { used: 0.1, resetsAt: '2030-01-07T09:20:00Z' } }).claude, at: '2030-01-07T08:00:00Z' } }, NOW),
    };
    const bad = Object.entries(unknowns).filter(([, x]) => x.known || decide('heavy', x, { now: NOW }).go || decide('heavy', x, { now: NOW }).verdict !== 'hold');
    check(`governor: "unknown" usage = hold, not run (${Object.keys(unknowns).length} ways to be unknown)`, bad.length === 0, bad.map(([k, x]) => `${k}: ${JSON.stringify(x)}`).join('; '));
    check('governor: every unknown reading says why', Object.values(unknowns).every((x) => typeof x.why === 'string' && x.why.length > 5));
    check('governor: light steps (no model) run even when usage is unknown or high', decide('light', unknowns['no file'], { now: NOW }).go && decide('light', usageOf(doc(0.99), NOW), { now: NOW }).go);
    const mid = usageOf(doc(0.6), NOW);
    check('governor: bulk work at 60 % waits for the night, runs at 03:00, and runs by day under 50 %',
      !decide('bulk', mid, { now: NOW, hour: 14 }).go && decide('bulk', mid, { now: NOW, hour: 3 }).go && decide('bulk', usageOf(doc(0.4), NOW), { now: NOW, hour: 14 }).go);
    testBurnAndWeek();
    check('governor: bulk work is still held at 70 % at night', !decide('bulk', usageOf(doc(0.75), NOW), { now: NOW, hour: 3 }).go);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// The read-only command line (core/engine/cli.mjs) over a scratch state folder.
export async function runCli() {
  const { main } = await import('../../../core/engine/cli.mjs');
  const dir = tmp('cli');
  try {
    const lines = []; const say = (l) => lines.push(l);
    fs.writeFileSync(path.join(dir, 'plan-usage.json'), JSON.stringify({ claude: { at: new Date().toISOString(), status: 'allowed', fiveHour: { used: 0.9 }, sevenDay: { used: 0.2 } } }));
    const g = await main(['governor', '--state', dir], say);
    check('cli governor: says stop at 90 % and exits 1', g === 1 && /heavy stop/.test(lines[0] || ''), lines.join(' | '));
    lines.length = 0;
    const s = await main(['show', 'WO-2101', '--state', dir], say);
    check('cli show: an order with no engine events says so (exit 0, nothing written)', s === 0 && /no engine events/.test(lines[0] || '') && !fs.existsSync(path.join(dir, 'engine')), lines.join(' | '));
    check('cli: a bad command or WO id is exit 2 with the usage', (await main(['show', 'J312', '--state', dir], say)) === 2 && (await main(['nope', '--state', dir], say)) === 2);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// Jordan's rule: within 60 min of the 5-hour reset, use all that is left (it is lost at the reset); the week always applies.
function testBurnAndWeek() {
  const soon = (used, weekly = 0.3, resetsAt = '2030-01-07T09:30:00Z') => usageOf(doc(used, { fiveHour: { used, resetsAt }, sevenDay: { used: weekly } }), NOW);
  const v90 = decide('heavy', soon(0.9), { now: NOW });
  check('governor burn window: 90 % used 30 min before the reset runs (not stop), with the reason', v90.go && v90.verdict === 'run' && /resets in 30 min/.test(v90.why), v90.why);
  check('governor burn window: 75 % used 30 min before the reset runs (not hold); bulk runs by day too', decide('heavy', soon(0.75), { now: NOW }).go && decide('bulk', soon(0.75), { now: NOW, hour: 14 }).go);
  check('governor burn window: 100 % used is stop even right before the reset', decide('heavy', soon(1), { now: NOW }).verdict === 'stop');
  const far = decide('heavy', soon(0.9, 0.3, '2030-01-07T10:01:00Z'), { now: NOW });
  check('governor bands: 90 % used 61 min before the reset is stop (outside the burn window)', far.verdict === 'stop', far.why);
  check('governor burn window: the week still applies (week 96 % = stop, 90 % = hold, 30 min before the reset)',
    decide('heavy', soon(0.5, 0.96), { now: NOW }).verdict === 'stop' && decide('heavy', soon(0.5, 0.9), { now: NOW }).verdict === 'hold');
  const wk = (weekly) => decide('heavy', usageOf(doc(0.1, { sevenDay: { used: weekly } }), NOW), { now: NOW });
  check(`governor enforces the weekly limit: 5-hour at 10 % with the week at 99 % is stop, at 88 % hold, at 50 % run (limits ${LIMITS.weeklyHold}/${LIMITS.weeklyStop})`,
    wk(0.99).verdict === 'stop' && wk(0.88).verdict === 'hold' && wk(0.5).verdict === 'run' && /week/.test(wk(0.99).why), `${wk(0.99).verdict} ${wk(0.88).verdict} ${wk(0.5).verdict}`);
  check('governor: a week-limit hold asks again in 6 h, not at the 5-hour reset', wk(0.9).retrySec === 6 * 3600);
}
