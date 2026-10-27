// @ts-check
// Owns the Board's feature-flag runtime (lane L5): "is this flag on right now?" for pass-app, read from the repo's flags.json (L4 declares
// every flag, off by default) and the flag.set events in the ledger's event store (a flip is Jordan's decision, then a flag.set event).
// Called by pass-app/work/api.mjs (the Work tab is behind board.work) and pass-app/test-work.mjs.
// It never turns a flag on by itself: an unknown flag, a broken flags.json, or a store that cannot be read all mean off (core/ship/flags.mjs
// isOn keeps those rules; this file only feeds it the current values).
import { readFlags, foldFlagEvents, isOn, FLAGS_FILE } from '../../core/ship/flags.mjs';

/** The Work tab's own flag (declared in flags.json by L4). */
export const WORK_FLAG = 'board.work';

/**
 * The flag values as of these events.
 * @param {{ events?: Array<{ seq?: number, kind?: string, data?: any }>, flagsFile?: string }} [o]
 * @returns {{ ok: boolean, errors: string[], on: (name: string) => boolean, values: Array<{ flag: string, on: boolean, default: boolean, what: string }> }}
 */
export function flagsNow(o = {}) {
  const declared = readFlags(o.flagsFile || FLAGS_FILE);
  const current = foldFlagEvents(o.events || []);
  const on = (/** @type {string} */ name) => isOn(name, { declared, current });
  const values = [...declared.flags].map(([flag, d]) => ({ flag, on: on(flag), default: d.default === true, what: String(d.what || '') }));
  return { ok: declared.ok, errors: declared.errors, on, values };
}
