// @ts-check
// Owns the capacity governor: may the engine start a crew now, measured against the shared Claude plan's 5-hour window and its week?
// Reads <state>\plan-usage.json (written by the Yard's usage reader; read only here) and answers run, hold or stop with the reason.
// Rules, in order (upgrade-L2 brief "Plan usage", and Jordan's rule from the 10-26 review):
//   1. an unknown reading (no file, unreadable, no number, no weekly number, older than maxAgeMin, a status other than allowed) = hold;
//   2. the week: at or above weeklyStop of the 7-day limit, stop; at or above weeklyHold, hold. The week always applies;
//   3. the last burnMin minutes before the 5-hour window resets: use all that is left (run until 100 %), since it is lost at the reset;
//   4. otherwise bands of the 5-hour window: under 70 % run; from 70 % hold (no new heavy crew); from 85 % stop (finish, start nothing).
// Bulk work (re-cooks, batch retries) also waits for the night or for under 50 %, except in the burn window. Light steps (stations, no
// model) always run. Called by core/engine/driver.mjs before every heavy activity, core/engine/cli.mjs (governor),
// core/engine/converge/run.mjs and tests/core/engine/test-governor.mjs.
import fs from 'node:fs';

export const LIMITS = { hold: 0.70, stop: 0.85, bulkUnder: 0.50, nightFrom: 1, nightTo: 6, maxAgeMin: 30, burnMin: 60, weeklyHold: 0.85, weeklyStop: 0.95 };

/** @typedef {{ known: boolean, used: number|null, weekly: number|null, at: string|null, resetsAt: string|null, why: string }} Usage */
/** @typedef {{ go: boolean, verdict: 'run'|'hold'|'stop', why: string, retrySec: number }} Verdict */

const pct = (x) => `${Math.round(x * 100)} %`;
const num = (x) => typeof x === 'number' && Number.isFinite(x) && x >= 0;

/** @param {any} doc parsed plan-usage.json @param {Date} now @returns {Usage} */
export function usageOf(doc, now, maxAgeMin = LIMITS.maxAgeMin) {
  const c = doc && doc.claude;
  const unknown = (why) => ({ known: false, used: null, weekly: null, at: c && c.at || null, resetsAt: null, why });
  if (!c || typeof c !== 'object') return unknown('no claude block in plan-usage.json');
  const used = c.fiveHour && c.fiveHour.used;
  if (!num(used)) return unknown('no 5-hour reading');
  const weekly = c.sevenDay && c.sevenDay.used;
  if (!num(weekly)) return unknown('no weekly (7-day) reading');
  const at = Date.parse(c.at);
  if (!Number.isFinite(at)) return unknown('the reading has no time');
  const age = (now.getTime() - at) / 60000;
  if (age > maxAgeMin) return unknown(`the reading is ${Math.round(age)} min old (more than ${maxAgeMin})`);
  if (c.status && c.status !== 'allowed') return { ...unknown(`the plan says ${c.status}`), used, at: c.at };
  return { known: true, used, weekly, at: c.at, resetsAt: (c.fiveHour && c.fiveHour.resetsAt) || null, why: `5-hour window ${pct(used)} used, week ${pct(weekly)}` };
}

/** @param {string} file @param {Date} [now] @returns {Usage} */
export function readUsage(file, now = new Date()) {
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) {
    return { known: false, used: null, weekly: null, at: null, resetsAt: null, why: `cannot read ${file}: ${/** @type {Error} */ (err).message}` };
  }
  return usageOf(doc, now);
}

// Minutes until the 5-hour window resets, or null when the reading has no reset time (or it is already past).
export function minutesToReset(u, now) {
  const reset = u.resetsAt ? Date.parse(u.resetsAt) : NaN;
  if (!Number.isFinite(reset) || reset <= now.getTime()) return null;
  return (reset - now.getTime()) / 60000;
}

// How long a held step waits before the governor is asked again: until the window resets (from 15 min to 5 h), else 15 min.
function retrySec(u, now) {
  const m = minutesToReset(u, now);
  return m === null ? 900 : Math.max(900, Math.min(5 * 3600, Math.round(m * 60)));
}

/**
 * @param {'light'|'heavy'|'bulk'} kind @param {Usage} u
 * @param {{ now?: Date, hour?: number, limits?: Partial<typeof LIMITS> }} [o] hour: this PC's local hour (tests pass it)
 * @returns {Verdict}
 */
export function decide(kind, u, { now = new Date(), hour = now.getHours(), limits = {} } = {}) {
  const L = { ...LIMITS, ...limits };
  // A held step asks again when the 5-hour window resets; a week limit is looked at again every 6 h (the week resets in days).
  const v = (go, verdict, why, weekLimit = false) => ({ go, verdict, why, retrySec: go ? 0 : weekLimit ? 6 * 3600 : retrySec(u, now) });
  if (kind === 'light') return v(true, 'run', 'a light step: no model, no plan use');
  if (!u.known) return v(false, 'hold', `usage unknown (${u.why}): hold, not run`);
  const used = /** @type {number} */ (u.used); const weekly = /** @type {number} */ (u.weekly);
  if (weekly >= L.weeklyStop) return v(false, 'stop', `${u.why}: the week is at or above ${pct(L.weeklyStop)}, start nothing`, true);
  if (weekly >= L.weeklyHold) return v(false, 'hold', `${u.why}: the week is at or above ${pct(L.weeklyHold)}, no new ${kind} crew`, true);
  const m = minutesToReset(u, now);
  if (m !== null && m <= L.burnMin) {
    if (used >= 1) return v(false, 'stop', `${u.why}: the 5-hour window is used up; it resets in ${Math.round(m)} min`);
    return v(true, 'run', `${u.why}: the window resets in ${Math.round(m)} min, so use what is left`);
  }
  if (used >= L.stop) return v(false, 'stop', `${u.why}: at or above ${pct(L.stop)}, finish the current step and start nothing`);
  if (used >= L.hold) return v(false, 'hold', `${u.why}: at or above ${pct(L.hold)}, no new ${kind} crew`);
  if (kind === 'bulk') {
    const night = hour >= L.nightFrom && hour < L.nightTo;
    if (used >= L.bulkUnder && !night) return v(false, 'hold', `${u.why}: bulk work waits for the night (${L.nightFrom}:00-${L.nightTo}:00) or under ${pct(L.bulkUnder)}`);
  }
  return v(true, 'run', `${u.why}: under ${pct(L.hold)}`);
}
