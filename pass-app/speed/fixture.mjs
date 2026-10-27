// The speed budget's fixture Yard: writes a throwaway state folder (work orders, events, crews board) the Board's server reads.
// Called by pass-app/speed/run.mjs. Made-up orders only (no names, paths or data from any real Yard), so CI never sees private data.
import fs from 'node:fs'; import path from 'node:path';

const iso = (ms) => new Date(ms).toISOString();
// a step: the script's base name is the station (forward slashes, so the same fixture reads the same on Linux and Windows)
const step = (role, supplier = 'claude') => ({ script: 'k/agent-step.ps1', args: { Role: role, Supplier: supplier } });
const station = (name) => ({ script: `k/stations/${name}.ps1`, args: {} });
const PLAN = [step('plan'), step('do'), step('review'), station('tests'), station('merge')];

// ids are J<n>: the server reads only jobs/J<n>.json (JOB_FILE in server.mjs)
function order(id, now, o = {}) {
  return { id, name: `improve: speed fixture order ${id}`, status: 'pending', cursor: 0, attempt: 0, created: iso(now - 3600e3), costUsd: 0.1,
    steps: PLAN, history: [{ at: iso(now - 600e3), step: 0, outcome: 'done' }], ...o };
}
// a running order: its run files say which crew holds it (the sous pick) and give the Live call a short log
function running(root, id, now, cursor, supplier) {
  const base = path.join(root, 'run', `${id}-s${cursor + 1}-a0`);
  fs.writeFileSync(base + '.sous.json', JSON.stringify({ supplier, model: supplier === 'local' ? 'small' : 'default', private: false, why: 'fixture' }));
  fs.writeFileSync(base + '.log', ['reading the plan', 'editing one file', 'running the checks'].join('\n') + '\n');
  fs.writeFileSync(base + '.activity.jsonl', [{ ts: iso(now - 20e3), kind: 'tool', tool: 'Read', status: 'done' }, { ts: iso(now - 5e3), kind: 'tool', tool: 'Edit', status: 'running' }]
    .map((x) => JSON.stringify(x)).join('\n') + '\n');
  return order(id, now, { status: 'running', cursor, run: { startedAt: iso(now - 90e3), base } });
}
// busy: six crews at five stations, two sign-offs waiting, six cards on the job board, one handed over, one set aside
function busyOrders(root, now) {
  const crews = [[0, 'claude'], [1, 'claude'], [1, 'gemini'], [2, 'claude'], [3, 'local'], [4, 'claude']];
  const out = crews.map(([cursor, sup], i) => running(root, 'J' + (i + 1), now, cursor, sup));
  for (const id of ['J7', 'J8']) out.push(order(id, now, { status: 'waiting-approval', cursor: 1, approval: { id: 'A-' + id, text: 'Sign off the next step', kind: 'gate' } }));
  for (let i = 9; i <= 14; i++) out.push(order('J' + i, now));
  out.push(order('J15', now, { status: 'done', cursor: 4, history: [{ at: iso(now - 60e3), step: 4, outcome: 'done' }] }));
  out.push(order('J16', now, { status: 'quarantined', cursor: 1, history: [{ at: iso(now - 45e3), step: 1, outcome: 'fail', detail: 'fixture failure' }] }));
  return out;
}
// calm: nothing building, nothing waiting; finished orders from earlier in the day
const calmOrders = (now) => Array.from({ length: 6 }, (_, i) => order('J' + (i + 1), now, { status: 'done', cursor: 4, history: [{ at: iso(now - (2 + i) * 3600e3), step: 4, outcome: 'done' }] }));

function events(kind, now) {
  const at = (s) => iso(now - s * 1000);
  if (kind === 'calm') return [{ ts: at(7200), type: 'job.done', job: 'J1' }];
  return [{ ts: at(300), type: 'approval.requested', job: 'J7' }, { ts: at(200), type: 'approval.requested', job: 'J8' }, { ts: at(120), type: 'step.done', job: 'J2' },
    { ts: at(60), type: 'job.done', job: 'J15' }, { ts: at(45), type: 'job.quarantined', job: 'J16' }, { ts: at(30), type: 'step.started', job: 'J1' }];
}
const CREWS = { at: null, dailyBudgetUsd: 20, suppliers: {
  claude: { status: 'ready', why: 'ready', plan: 'subscription', runs: 9, maxRuns: 40, windowHours: 5, models: ['default'], track: {} },
  gemini: { status: 'ready', why: 'ready', plan: 'subscription', runs: 4, maxRuns: 150, windowHours: 24, models: ['default'], track: {} },
  local: { status: 'ready', why: 'ready', plan: 'free', runs: 7, maxRuns: 1000, windowHours: 1, models: ['small'], track: {} } } };

// Writes the folder and returns its path; kind is 'busy' or 'calm'
export function makeYard(dir, kind, now = Date.now()) {
  const root = path.join(dir, kind);
  for (const d of ['jobs', 'run', 'empty']) fs.mkdirSync(path.join(root, d), { recursive: true });
  for (const j of kind === 'busy' ? busyOrders(root, now) : calmOrders(now)) fs.writeFileSync(path.join(root, 'jobs', j.id + '.json'), JSON.stringify(j));
  fs.writeFileSync(path.join(root, 'events.jsonl'), events(kind, now).map((e) => JSON.stringify(e)).join('\n') + '\n');
  fs.writeFileSync(path.join(root, 'supervisor.json'), JSON.stringify({ lastTick: iso(now - 20e3) }));
  fs.writeFileSync(path.join(root, 'suppliers-board.json'), JSON.stringify({ ...CREWS, at: iso(now) }));
  return root;
}
