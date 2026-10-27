// @ts-check
// Owns when each convergence workflow runs (build-way 3.6): every 2 h for freshen, re-review, retry and the re-cook check; nightly at
// 02:00 for the agent passes (the contradiction finder) and the PICKUP archive; 07:00 for the morning card; tidy cards every 6 h.
// With Temporal these become Temporal Schedules (one per row); with the in-process engine, due() is asked on each tick.
// Times are this PC's local clock. Called by core/engine/converge/run.mjs and tests/core/engine/test-converge.mjs.

/** @typedef {{ workflow: string, everyH?: number, atHour?: number }} Schedule */
/** @type {Schedule[]} */
export const SCHEDULES = [
  { workflow: 'freshen-pr', everyH: 2 }, { workflow: 're-review', everyH: 2 }, { workflow: 'retry', everyH: 2 }, { workflow: 'recook', everyH: 2 },
  { workflow: 'worktree-tidy', everyH: 6 }, { workflow: 'close-superseded', everyH: 6 },
  { workflow: 'pickup-archive', atHour: 2 }, { workflow: 'contradictions', atHour: 2 }, { workflow: 'morning-card', atHour: 7 },
];

/**
 * Is a workflow due? everyH: at least that many hours since its last run. atHour: once a day, at or after that local hour, not yet
 * run since that hour today. Never run before = due. @param {Schedule} s @param {string|null} lastRun ISO time @param {Date} now
 */
export function due(s, lastRun, now) {
  const last = lastRun ? Date.parse(lastRun) : NaN;
  if (!Number.isFinite(last)) return true;
  if (s.everyH) return now.getTime() - last >= s.everyH * 3600000;
  if (s.atHour === undefined) return false;
  const slot = new Date(now); slot.setHours(s.atHour, 0, 0, 0);
  return now.getTime() >= slot.getTime() && last < slot.getTime();
}
