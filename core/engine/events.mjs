// @ts-check
// Owns the engine's event sink: where the engine appends contract events (core/contracts/event.schema.json, v 1.0) and reads a WO's
// events back. Two sinks with one shape: memorySink (tests, the Temporal workflow's test double) and fileSink (an append-only JSONL file
// in the engine's own folder, <state>\engine\events.jsonl, which is all the engine writes in shadow). Every append is validated against
// the contract first; seq and decision ids are given out by the sink, the one writer, under a lock file so two engine processes on the
// same folder never hand out the same number. When lane L1's tide.db lands, a third sink with this shape writes there (a card, not here).
// Called by core/engine/driver.mjs, core/engine/fake.mjs, core/engine/temporal/activities.mjs, core/engine/cli.mjs and the tests.
import fs from 'node:fs'; import path from 'node:path';
import { validate } from '../contracts/validate.mjs';

export const V = '1.0';

/** @typedef {{ v: string, seq: number, at: string, actor: string, kind: string, wo: string|null, data: any, proof: string|null }} Event */
/**
 * @typedef {{ append: (e: Omit<Event, 'v'|'seq'> & { v?: string }) => Event, appendAll: (list: (Omit<Event, 'v'|'seq'> & { v?: string })[]) => Event[],
 *   all: () => Event[], forWo: (wo: string) => Event[],
 *   nextDecisionId: () => string, where: string }} Sink
 */

// Throws with every contract error named, so a bad event never reaches the log.
function checked(e) {
  const r = validate('event', e);
  if (!r.ok) throw new Error(`event ${e.kind} for ${e.wo} is not valid: ${r.errors.join('; ')}`);
  return e;
}
const maxDecision = (events) => events.reduce((m, e) => {
  const id = e.kind === 'decision.asked' ? e.data.decision.id : null;
  return id ? Math.max(m, Number(id.slice(2))) : m;
}, 0);

/** @returns {Sink} */
export function memorySink(seed = []) {
  const log = seed.map((e) => ({ ...e }));
  let issued = maxDecision(log);
  return {
    where: 'memory',
    append(e) { const ev = checked({ v: V, ...e, seq: log.length + 1 }); log.push(ev); return ev; },
    appendAll(list) { const evs = list.map((e, i) => checked({ v: V, ...e, seq: log.length + 1 + i })); log.push(...evs); return evs; },
    all: () => log.slice(),
    forWo: (wo) => log.filter((e) => e.wo === wo),
    nextDecisionId() { issued = Math.max(issued, maxDecision(log)) + 1; return `D-${issued}`; },
  };
}

// A short exclusive lock: create <file>.lock with wx, retry for up to waitMs, then fail with the holder's age (never steal it silently).
function withLock(file, fn, waitMs = 5000) {
  const lock = `${file}.lock`; const until = Date.now() + waitMs;
  for (;;) {
    try { fs.writeFileSync(lock, String(process.pid), { flag: 'wx' }); break; } catch (err) {
      if (/** @type {any} */ (err).code !== 'EEXIST') throw err;
      if (Date.now() > until) {
        const age = Math.round((Date.now() - fs.statSync(lock).mtimeMs) / 1000);
        throw new Error(`event log is locked by ${lock} (held ${age}s); if no engine is running, that file is left from a crash: remove it by hand`);
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    }
  }
  try { return fn(); } finally { fs.rmSync(lock, { force: true }); }
}

function readLines(file) {
  if (!fs.existsSync(file)) return [];
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split('\n');
  // A half-written last line (the process died mid-append) is skipped, never parsed as truth; every whole line must parse.
  if (lines.length && !text.endsWith('\n')) lines.pop();
  return lines.filter((l) => l.trim()).map((l, i) => { try { return JSON.parse(l); } catch { throw new Error(`${file} line ${i + 1} is not JSON`); } });
}

/** @param {string} file the JSONL log, created with its folder on first append @returns {Sink} */
export function fileSink(file) {
  const decisionsFile = `${file}.decisions`;
  return {
    where: file,
    append(e) { return this.appendAll([e])[0]; },
    // Several events as one write under one lock: every one is checked first, so either all go on or none does.
    appendAll(list) {
      return withLock(file, () => {
        const log = readLines(file);
        const first = (log.length ? log[log.length - 1].seq : 0) + 1;
        const evs = list.map((e, i) => checked({ v: V, ...e, seq: first + i }));
        fs.mkdirSync(path.dirname(file), { recursive: true });
        // A half-written tail from a crash was never acknowledged: cut it off before the next whole line goes on.
        const raw = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
        if (raw && !raw.endsWith('\n')) fs.truncateSync(file, Buffer.byteLength(raw.slice(0, raw.lastIndexOf('\n') + 1)));
        fs.appendFileSync(file, evs.map((ev) => JSON.stringify(ev) + '\n').join(''));
        return evs;
      });
    },
    all: () => readLines(file),
    forWo: (wo) => readLines(file).filter((e) => e.wo === wo),
    nextDecisionId() {
      return withLock(file, () => {
        const last = fs.existsSync(decisionsFile) ? Number(fs.readFileSync(decisionsFile, 'utf8')) || 0 : 0;
        const n = Math.max(last, maxDecision(readLines(file))) + 1;
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(decisionsFile, String(n));
        return `D-${n}`;
      });
    },
  };
}
