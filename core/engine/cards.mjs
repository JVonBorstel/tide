// @ts-check
// Owns the engine's cards for Jordan: one decision record (core/contracts/decision.schema.json, v 1.0) per question, built from a
// command's plain fields, and the standing-yes lookup (build-way section 9: a standing yes covers every later case of its kind).
// Called by core/engine/driver.mjs (ask commands) and by the convergence workflows (actions that need a yes). Zero dependencies
// beyond core/contracts.
import { validate } from '../contracts/validate.mjs';

export const V = '1.0';

/**
 * A decision record for one card, valid against the contract or a thrown error naming each problem.
 * @param {{ id: string, wo: string|null, kind: string, ask: string, options: string[], recommended: string, why?: string|null, at: string, standing?: boolean }} c
 */
export function makeDecision(c) {
  const d = { v: V, id: c.id, wo: c.wo, kind: c.kind, ask: c.ask, options: c.options, recommended: c.recommended, why: c.why ?? null,
    answer: null, note: null, at: c.at, answeredAt: null, via: null, ...(c.standing ? { standing: true } : {}) };
  const r = validate('decision', d);
  if (!r.ok) throw new Error(`card ${c.id} is not a valid decision: ${r.errors.join('; ')}`);
  return d;
}

// The cards asked and answered in an event list: id -> { decision (as asked), answer, note, at }.
export function cardsIn(events) {
  const out = new Map();
  for (const e of events) {
    if (e.kind === 'decision.asked') out.set(e.data.decision.id, { decision: e.data.decision, answer: null, note: null, at: null });
    if (e.kind === 'decision.answered' && out.has(e.data.decision) && e.actor === 'jordan') {
      const c = out.get(e.data.decision);
      if (c.answer === null) out.set(e.data.decision, { ...c, answer: e.data.answer, note: e.data.note ?? null, at: e.at });
    }
  }
  return out;
}

// Is there a standing yes for this kind of action? Only a card asked with standing: true, of the same kind, whose ask names the action
// (the "topic", for example "remove done worktrees"), answered "Yes" by Jordan. A withdrawn standing yes is a later card on the same topic
// answered "No": the latest answer wins. Returns { yes, decision } so the caller can cite the card in its proof.
export function standingYes(events, kind, topic) {
  let found = { yes: false, decision: /** @type {string|null} */ (null) };
  const answered = [...cardsIn(events)].filter(([, c]) => c.answer !== null).sort((a, b) => String(a[1].at).localeCompare(String(b[1].at)));
  for (const [id, c] of answered) {
    if (!c.decision.standing || c.decision.kind !== kind || c.answer === null) continue;
    if (!String(c.decision.ask).toLowerCase().includes(String(topic).toLowerCase())) continue;
    found = { yes: c.answer === 'Yes', decision: id };
  }
  return found;
}
