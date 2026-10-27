// Owns how a ship-path step answers the engine: an activity result {v, ok, exit, out, proof} (core/contracts activity-result) and event drafts.
// Called by core/ship/freshen-pr.mjs, core/ship/queue.mjs and tests/core/ship/*. The engine (lane L2) gives each draft its seq, time and actor.
// @ts-check

/**
 * The activity result for a step's report. ok only with exit 0 (the contract's rule); out is the report as JSON, capped.
 * @param {{ ok: boolean, exit?: number, proof?: string | null }} report
 */
export function toActivityResult(report) {
  const exit = report.ok ? 0 : (report.exit && report.exit !== 0 ? report.exit : 1);
  const out = JSON.stringify(report).slice(0, 65536);
  const proof = report.proof ? String(report.proof).slice(0, 500) : null;
  return { v: '1.0', ok: report.ok, exit, out, proof };
}

/**
 * An event draft: everything but seq, at and actor, which the one writer adds.
 * @param {string} kind @param {string | null} wo @param {Record<string, unknown>} data @param {string | null} [proof]
 */
export const eventDraft = (kind, wo, data, proof = null) => ({ kind, wo, data, proof });
