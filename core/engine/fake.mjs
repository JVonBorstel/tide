// @ts-check
// Owns the in-process engine: the EngineAdapter (engine.mjs) with no server, used by the tests and as a stand-in until Temporal is
// installed (Jordan's tap). Durable on its own folder: the event log is the step journal (events.mjs), activity results are kept per
// idempotency key (activity.mjs fileStore), and timers live in timers.json, so a process killed at any point resumes from the files:
// a finished step is not run again, a timer that came due while it was down fires, and a signal (Jordan's tap) wakes a waiting order.
// It is not the production engine (build-way 10.2: Temporal is); it has no worker pool and drives one order at a time.
// Called by core/engine/engine.mjs (openEngine kind 'fake'), core/engine/cli.mjs and tests/core/engine/*.
import fs from 'node:fs'; import path from 'node:path';
import { reduce, next } from './wo.mjs';
import { execute } from './driver.mjs';
import { fileSink, memorySink } from './events.mjs';
import { fileStore, memoryStore } from './activity.mjs';

/** @typedef {import('./engine.mjs').EngineAdapter} EngineAdapter */ /** @typedef {import('./engine.mjs').DriveResult} DriveResult */

function timerTable(dir) {
  const file = dir ? path.join(dir, 'timers.json') : '';
  let mem = {};
  const load = () => { if (!file) return mem; try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return {}; } };
  const save = (t) => {
    if (!file) { mem = t; return; }
    fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(`${file}.tmp`, JSON.stringify(t, null, 1)); fs.renameSync(`${file}.tmp`, file);
  };
  return {
    get: (key) => load()[key] || null,
    set: (key, v) => { const t = load(); t[key] = v; save(t); },
    drop: (key) => { const t = load(); delete t[key]; save(t); },
    all: () => load(),
  };
}

/**
 * @param {{ dir?: string, sink?: import('./events.mjs').Sink, store?: import('./activity.mjs').Store, impls?: Record<string, any>,
 *   usage?: () => any, clock?: () => Date, hour?: () => number, hooks?: any, maxSteps?: number }} o
 *   dir: the engine's own folder (<state>\engine); without it everything is in memory (lost on exit).
 * @returns {EngineAdapter & { drive: (wo: string) => Promise<DriveResult>, tick: () => Promise<Record<string, DriveResult>>, timers: () => any }}
 */
export function createFakeEngine(o = {}) {
  const sink = o.sink || (o.dir ? fileSink(path.join(o.dir, 'events.jsonl')) : memorySink());
  const store = o.store || (o.dir ? fileStore(path.join(o.dir, 'activities')) : memoryStore());
  const clock = o.clock || (() => new Date());
  const timers = timerTable(o.dir || '');
  const ports = { sink, store, impls: o.impls || {}, usage: o.usage || (() => ({ known: false, why: 'no usage reader given' })), clock, hour: o.hour, hooks: o.hooks };
  const maxSteps = o.maxSteps || 200;
  const due = (t) => clock().getTime() >= Date.parse(t.due);
  const later = (sec) => new Date(clock().getTime() + sec * 1000).toISOString();

  // Run the order until it has to wait (a timer, Jordan, a crew, the governor) or is finished. Never loops forever: maxSteps says why.
  async function drive(wo) {
    for (let i = 0; i < maxSteps; i++) {
      const s = reduce(sink.forWo(wo), wo);
      const cmd = next(s);
      const held = timers.get(`${wo}:governor`);
      if (cmd.do === 'none' || cmd.do === 'await') return { status: cmd.do === 'none' ? 'done' : 'waiting', why: cmd.why, state: s };
      if (cmd.do === 'wait') {
        const t = timers.get(`${wo}:wait`) || (timers.set(`${wo}:wait`, { due: later(cmd.sec), why: cmd.why, seq: s.lastSeq }), timers.get(`${wo}:wait`));
        if (!due(t)) return { status: 'timer', why: `${cmd.why} (until ${t.due})`, due: t.due, state: s };
        sink.append({ at: clock().toISOString(), actor: 'engine', kind: 'x.engine.timer', wo, data: { sec: cmd.sec, why: cmd.why }, proof: null });
        timers.drop(`${wo}:wait`);
        continue;
      }
      if (held && !due(held)) return { status: 'held', why: held.why, due: held.due, state: s };
      if (held) timers.drop(`${wo}:governor`);
      const r = await execute(wo, cmd, ports);
      if (r.hold) {
        timers.set(`${wo}:governor`, { due: later(r.hold.retrySec), why: r.hold.why });
        return { status: 'held', why: r.hold.why, due: later(r.hold.retrySec), state: reduce(sink.forWo(wo), wo) };
      }
    }
    return { status: 'stopped', why: `more than ${maxSteps} steps in one drive: a loop in the lifecycle? (last: ${reduce(sink.forWo(wo), wo).why})`, state: reduce(sink.forWo(wo), wo) };
  }

  const wos = () => [...new Set(sink.all().map((e) => e.wo).filter(Boolean))];
  return {
    kind: 'fake',
    drive,
    timers: () => timers.all(),
    async start(wo, created) {
      if (!sink.forWo(wo).some((e) => e.kind === 'wo.created')) sink.append({ at: clock().toISOString(), actor: 'engine', kind: 'wo.created', wo, data: created, proof: null });
      return drive(wo);
    },
    async signal(wo, event) {
      sink.append({ at: clock().toISOString(), proof: null, ...event, wo });
      return drive(wo);
    },
    async query(wo) { return reduce(sink.forWo(wo), wo); },
    // Every order that is not finished gets one drive (the minute tick of a stand-alone run; Temporal needs no tick).
    async tick() {
      const out = {};
      for (const wo of wos()) { const s = reduce(sink.forWo(wo), wo); if (!['shipped', 'dropped', 'replaced'].includes(s.state)) out[wo] = await drive(wo); }
      return out;
    },
    async close() { /* nothing held open: every write is already on disk */ },
  };
}
