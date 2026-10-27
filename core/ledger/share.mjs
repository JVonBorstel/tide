// @ts-check
// Before any ledger record leaves this PC (an API answer, a cloud task, a PR body, a public file), it goes through here.
//   - publicEvent: an x.* event's data is local by nature (worktree and repo paths, idea titles, Yard facts) and is not marked in the
//     contract, so it is dropped whole; then core/contracts/public.mjs toPublic strips local paths from the x-local-only fields (proof).
//   - publicRow: toPublic('row') (the row's proof).
// Nothing sends ledger records anywhere today; tide.db, work.json and ledger.next.json stay in the state or scratch folder.
import { toPublic } from '../contracts/public.mjs';
import { CONTRACT_V } from './store.mjs';

/** @param {any} e an event @returns {{ doc: any, stripped: string[] }} */
export function publicEvent(e) {
  const local = /^x\./.test(String(e?.kind || ''));
  const base = local ? { ...e, data: {} } : e;
  const r = toPublic('event', { v: CONTRACT_V, ...base });
  return { doc: r.doc, stripped: local ? ['/data', ...r.stripped] : r.stripped };
}

/** @param {any} row @returns {{ doc: any, stripped: string[] }} */
export function publicRow(row) { return toPublic('row', row); }
