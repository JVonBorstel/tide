// @ts-check
// Owns the convergence workflows (build-way 3.6): what the engine does on its own schedule to bring held and stale work back to done.
// Each workflow is a pure plan: a snapshot in (open PRs, rows, worktrees, PICKUP entries, the event log), a list of actions out.
// Nothing here acts; core/engine/converge/run.mjs carries the actions out, or only prints them (dry run), and turns every action that
// needs Jordan's yes into a card unless a standing yes is in the log. Inputs are plain objects (from L1's ledger once it lands; from
// files or tests until then).
// Called by core/engine/converge/run.mjs and tests/core/engine/test-converge.mjs.

/**
 * @typedef {{ workflow: string, act: string, wo: string|null, target: string, why: string, cls: 'light'|'heavy'|'bulk',
 *   yes?: { kind: string, topic: string } , args?: Record<string, string|number|boolean|null> }} Action
 * @typedef {{ pr: string, wo: string|null, branch: string, head: string, behind: number, mergeable: 'yes'|'conflicting'|'unknown',
 *   reviewedHead: string|null, private?: boolean, portedTo?: string|null, portMerged?: boolean }} OpenPr
 * @typedef {{ wo: string, state: string, lastEventAt: string, retries: number }} Row
 * @typedef {{ path: string, branch: string, merged: boolean, clean: boolean, idleH: number }} Worktree
 */

// The topics of the yeses (decision kind + the words a standing-yes card's ask must contain; build-way 3.6 and section 9).
export const YES = {
  freshen: { kind: 'resume', topic: 'update held PRs by merging main in' },
  worktree: { kind: 'close', topic: 'remove done worktrees' },
  closePr: { kind: 'close', topic: 'close private PRs already ported to tide' },
  closeSuperseded: { kind: 'close', topic: 'close a PR replaced by its re-cook' },
};
export const LIMITS = { staleH: 24, worktreeIdleH: 24, pickupKeepH: 48, maxConvergeRetries: 2 };
const hoursSince = (at, now) => (now.getTime() - Date.parse(at)) / 3600000;
const a = (o) => /** @type {Action} */ (o);

/** freshen-pr: every open PR behind main is brought up to date by merging main in (normal push, never force). @param {{ prs: OpenPr[] }} s */
export function freshenPr(s) {
  return s.prs.filter((p) => p.behind > 0 && p.mergeable !== 'conflicting' && !p.private).map((p) => a({ workflow: 'freshen-pr', act: 'freshen-pr', wo: p.wo, target: p.pr,
    why: `${p.pr} is ${p.behind} commit(s) behind main`, cls: 'light', yes: YES.freshen, args: { Pr: p.pr, Branch: p.branch } }));
}

/** re-review: a PR whose head moved since its last verdict (a freshen that changed code, a push) is reviewed again. No yes needed. @param {{ prs: OpenPr[] }} s */
export function reReview(s) {
  return s.prs.filter((p) => !p.private && p.reviewedHead && p.reviewedHead !== p.head).map((p) => a({ workflow: 're-review', act: 'review', wo: p.wo, target: p.pr,
    why: `head ${p.head} is not the reviewed ${p.reviewedHead}`, cls: 'heavy', args: { Pr: p.pr, Head: p.head } }));
}

/**
 * retry: a row that is moving but has had no event for staleH hours gets a fresh crew from its brief, at most maxConvergeRetries times
 * (counted from its x.converge.retry events); after that, one re-plan-or-drop card instead. @param {{ rows: Row[], events: any[] }} s @param {Date} now
 */
export function retry(s, now) {
  const tries = (wo) => s.events.filter((e) => e.wo === wo && e.kind === 'x.converge.retry').length;
  return s.rows.filter((r) => ['moving', 'stale'].includes(r.state) && hoursSince(r.lastEventAt, now) >= LIMITS.staleH).map((r) => (tries(r.wo) < LIMITS.maxConvergeRetries
    ? a({ workflow: 'retry', act: 'retry', wo: r.wo, target: r.wo, why: `no event for ${Math.round(hoursSince(r.lastEventAt, now))} h; fresh crew ${tries(r.wo) + 1} of ${LIMITS.maxConvergeRetries}`, cls: 'heavy', args: { Wo: r.wo } })
    : a({ workflow: 'retry', act: 'card', wo: r.wo, target: r.wo, why: `still stale after ${LIMITS.maxConvergeRetries} fresh crews`, cls: 'light',
      args: { Kind: 'question', Ask: `${r.wo} is still stale after ${LIMITS.maxConvergeRetries} fresh crews. Re-plan or drop?`, Options: 'Re-plan,Drop' } })));
}

/**
 * re-cook from intent: a conflicting PR gets two attempts at once, the conflict fix (freshen-pr) and a rebuild from its BRIEF on the
 * new main (recook, bulk: night or headroom); then a verifier picks. Closing the losing PR needs a yes. @param {{ prs: OpenPr[], picks?: Record<string, string> }} s
 */
export function recook(s) {
  const out = [];
  for (const p of s.prs.filter((x) => x.mergeable === 'conflicting' && !x.private)) {
    const pick = s.picks && s.picks[p.pr];
    if (pick === 'recook') { out.push(a({ workflow: 'recook', act: 'pr-close', wo: p.wo, target: p.pr, why: `the verifier picked the re-cook of ${p.pr}`, cls: 'light', yes: YES.closeSuperseded, args: { Pr: p.pr } })); continue; }
    if (pick) continue; // the conflict fix won: freshen-pr already updated this PR
    out.push(a({ workflow: 'recook', act: 'freshen-pr', wo: p.wo, target: p.pr, why: `${p.pr} conflicts with main: fix the conflict`, cls: 'light', yes: YES.freshen, args: { Pr: p.pr, Branch: p.branch } }));
    out.push(a({ workflow: 'recook', act: 'recook', wo: p.wo, target: p.pr, why: `${p.pr} conflicts with main: rebuild from its BRIEF on the new main, in parallel`, cls: 'bulk', args: { Pr: p.pr, Wo: p.wo } }));
    out.push(a({ workflow: 'recook', act: 'pick', wo: p.wo, target: p.pr, why: 'a verifier compares the conflict fix and the re-cook and picks one', cls: 'heavy', args: { Pr: p.pr } }));
  }
  return out;
}

/** PICKUP archive: entries older than pickupKeepH move to the archive (moved, never deleted). No yes needed. @param {{ pickup: { line: number, date: string }[] }} s @param {Date} now */
export function pickupArchive(s, now) {
  const old = s.pickup.filter((x) => hoursSince(x.date, now) > LIMITS.pickupKeepH);
  return old.length ? [a({ workflow: 'pickup-archive', act: 'pickup-archive', wo: null, target: `${old.length} entr${old.length === 1 ? 'y' : 'ies'}`,
    why: `older than ${LIMITS.pickupKeepH} h (lines ${old.map((x) => x.line).join(', ')})`, cls: 'light', args: { Lines: old.map((x) => String(x.line)).join(',') } })] : [];
}

/** worktree tidy: merged, clean and idle worktrees are removed (branches always kept). Needs a yes or the standing yes. @param {{ worktrees: Worktree[] }} s */
export function worktreeTidy(s) {
  return s.worktrees.filter((w) => w.merged && w.clean && w.idleH >= LIMITS.worktreeIdleH).map((w) => a({ workflow: 'worktree-tidy', act: 'worktree-remove', wo: null, target: w.path,
    why: `${w.branch} is merged, the worktree is clean and idle ${Math.round(w.idleH)} h; the branch is kept`, cls: 'light', yes: YES.worktree, args: { Path: w.path, Branch: w.branch } }));
}

/** close superseded: a private PR whose tide port is merged can be closed. Jordan said no standing yes (section 9): a card each. @param {{ prs: OpenPr[] }} s */
export function closeSuperseded(s) {
  return s.prs.filter((p) => p.private && p.portedTo && p.portMerged).map((p) => a({ workflow: 'close-superseded', act: 'pr-close', wo: p.wo, target: p.pr,
    why: `ported to ${p.portedTo}, which is merged`, cls: 'light', yes: YES.closePr, args: { Pr: p.pr } }));
}

/** The contradiction finder: one nightly agent pass comparing plans, ledger, code, glossary, NOW and memory; it writes cards itself. */
export function contradictions() {
  return [a({ workflow: 'contradictions', act: 'contradiction-finder', wo: null, target: 'plans, ledger, code, glossary, NOW, memory', why: 'nightly pass (build-way 2.2)', cls: 'bulk', args: {} })];
}

/**
 * The morning card: one card, at most 3 taps: what landed since the last morning, what waits on Jordan, one recommendation.
 * @param {{ events: any[], since: string }} s
 */
export function morningCard(s) {
  const since = Date.parse(s.since);
  const landed = s.events.filter((e) => e.kind === 'merged' && Date.parse(e.at) >= since).map((e) => e.data.pr);
  const asked = new Map(s.events.filter((e) => e.kind === 'decision.asked').map((e) => [e.data.decision.id, e]));
  for (const e of s.events) if (e.kind === 'decision.answered') asked.delete(e.data.decision);
  const open = [...asked.values()].sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
  const first = open[0];
  const rec = first ? `Answer ${first.data.decision.id}: ${first.data.decision.ask}` : 'Nothing waits on you.';
  const options = first ? [`Answer ${first.data.decision.id}`, 'Open queue', 'Later'] : ['Seen', 'Later'];
  const ask = `Overnight: ${landed.length} landed${landed.length ? ` (${landed.slice(0, 4).join(', ')}${landed.length > 4 ? ', ...' : ''})` : ''}; ${open.length} wait on you. ${rec}`.slice(0, 300);
  return [a({ workflow: 'morning-card', act: 'card', wo: null, target: 'morning', why: `${landed.length} landed, ${open.length} open cards`, cls: 'light',
    args: { Kind: 'question', Ask: ask, Options: options.join(','), Recommended: options[0] } })];
}

// Every workflow by name, with the snapshot keys it reads (run.mjs checks they are present: a missing input is said, never guessed).
export const WORKFLOWS = {
  'freshen-pr': { plan: freshenPr, needs: ['prs'] },
  're-review': { plan: reReview, needs: ['prs'] },
  retry: { plan: retry, needs: ['rows', 'events'] },
  recook: { plan: recook, needs: ['prs'] },
  'pickup-archive': { plan: pickupArchive, needs: ['pickup'] },
  'worktree-tidy': { plan: worktreeTidy, needs: ['worktrees'] },
  'close-superseded': { plan: closeSuperseded, needs: ['prs'] },
  contradictions: { plan: contradictions, needs: [] },
  'morning-card': { plan: morningCard, needs: ['events', 'since'] },
};
