// @ts-check
// Owns the capacity governor: may the engine start a crew now, measured against the shared Claude plan's 5-hour window?
// Reads <state>\plan-usage.json (written by the Yard's usage reader; read only here) and answers run, hold or stop with the reason.
// Rules (upgrade-L2 brief, "Plan usage"): start no new heavy crew at or above 70 % of the 5-hour window; at 85 % stop starting work;
// an unknown reading (no file, unreadable, no number, older than maxAgeMin, a status other than allowed) is hold, never run.
// Bulk work (re-cooks, batch retries) runs only under 50 %, or at night under 70 %. Light steps (stations, no model) always run.
// Called by core/engine/driver.mjs before every heavy activity, core/engine/cli.mjs (governor), and tests/core/engine/test-governor.mjs.
import fs from 'node:fs';

export const LIMITS = { hold: 0.70, stop: 0.85, bulkUnder: 0.50, nightFrom: 1, nightTo: 6, maxAgeMin: 30 };

/** @typedef {{ known: boolean, used: number|null, weekly: number|null, at: string|null, resetsAt: string|null, why: string }} Usage */
/** @typedef {{ go: boolean, verdict: 'run'|'hold'|'stop', why: string, retrySec: number }} Verdict */

const pct = (x) => `${Math.round(x * 100)} %`;

/** @param {any} doc parsed plan-usage.json @param {Date} now @returns {Usage} */
export function usageOf(doc, now, maxAgeMin = LIMITS.maxAgeMin) {
  const c = doc && doc.claude;
  const unknown = (why) => ({ known: false, used: null, weekly: null, at: c && c.at || null, resetsAt: null, why });
  if (!c || typeof c !== 'object') return unknown('no claude block in plan-usage.json');
  const used = c.fiveHour && c.fiveHour.used;
  if (typeof used !== 'number' || !Number.isFinite(used) || used < 0) return unknown('no 5-hour reading');
  const at = Date.parse(c.at);
  if (!Number.isFinite(at)) return unknown('the reading has no time');
  const age = (now.getTime() - at) / 60000;
  if (age > maxAgeMin) return unknown(`the reading is ${Math.round(age)} min old (more than ${maxAgeMin})`);
  if (c.status && c.status !== 'allowed') return { ...unknown(`the plan says ${c.status}`), used, at: c.at };
  const weekly = c.sevenDay && typeof c.sevenDay.used === 'number' ? c.sevenDay.used : null;
  return { known: true, used, weekly, at: c.at, resetsAt: (c.fiveHour && c.fiveHour.resetsAt) || null, why: `5-hour window ${pct(used)} used` };
}

/** @param {string} file @param {Date} [now] @returns {Usage} */
export function readUsage(file, now = new Date()) {
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) {
    return { known: false, used: null, weekly: null, at: null, resetsAt: null, why: `cannot read ${file}: ${/** @type {Error} */ (err).message}` };
  }
  return usageOf(doc, now);
}

// How long a held step waits before the governor is asked again: until the window resets (from 15 min to 5 h), else 15 min.
function retrySec(u, now) {
  const reset = u.resetsAt ? Date.parse(u.resetsAt) : NaN;
  if (!Number.isFinite(reset)) return 900;
  return Math.max(900, Math.min(5 * 3600, Math.round((reset - now.getTime()) / 1000)));
}

/**
 * @param {'light'|'heavy'|'bulk'} kind @param {Usage} u
 * @param {{ now?: Date, hour?: number, limits?: Partial<typeof LIMITS> }} [o] hour: this PC's local hour (tests pass it)
 * @returns {Verdict}
 */
export function decide(kind, u, { now = new Date(), hour = now.getHours(), limits = {} } = {}) {
  const L = { ...LIMITS, ...limits };
  const v = (go, verdict, why) => ({ go, verdict, why, retrySec: go ? 0 : retrySec(u, now) });
  if (kind === 'light') return v(true, 'run', 'a light step: no model, no plan use');
  if (!u.known) return v(false, 'hold', `usage unknown (${u.why}): hold, not run`);
  const used = /** @type {number} */ (u.used);
  if (used >= L.stop) return v(false, 'stop', `${u.why}: at or above ${pct(L.stop)}, finish the current step and start nothing`);
  if (used >= L.hold) return v(false, 'hold', `${u.why}: at or above ${pct(L.hold)}, no new ${kind} crew`);
  if (kind === 'bulk') {
    const night = hour >= L.nightFrom && hour < L.nightTo;
    if (used >= L.bulkUnder && !night) return v(false, 'hold', `${u.why}: bulk work waits for the night (${L.nightFrom}:00-${L.nightTo}:00) or under ${pct(L.bulkUnder)}`);
  }
  return v(true, 'run', `${u.why}: under ${pct(L.hold)}`);
}
