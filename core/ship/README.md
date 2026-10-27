# The ship path (core/ship)

How finished work lands on main, built next to today's merge path (`scripts/merge-pr.ps1`, `kitchen/train.ps1`), which stays the
fallback. Everything here is switched off until Jordan says yes. Names: `docs/GLOSSARY.md` ("The ship path").
Zero packages; Node 18 or later; `.mjs` with JSDoc and `// @ts-check`. git runs with an argument list, never a shell, and
`git.mjs` refuses every force push, delete or mirror push before it starts.

| Piece | File | Command |
|---|---|---|
| Flags | `flags.json`, `flags.mjs`, `flags.schema.json` | `node core/ship/flags.mjs check` / `list` / `get <name> [--events <file.jsonl>]` |
| CI gates | `gates.mjs`, `gates.json`, `scripts/check-*.mjs` | `node scripts/check-wo-title.mjs --title "WO-1: x"`; `check-generated.mjs` and `check-decision-gate.mjs --base origin/main --title ... [--body ...]`; `--mode enforce` to block |
| Docs step | `docs.mjs` | `node core/ship/docs.mjs check --wo WO-1 [--base <ref>]`; `node core/ship/docs.mjs map` |
| Resurvey (freshen-pr) | `freshen-pr.mjs` | `node core/ship/freshen-pr.mjs --dir <clone> --branch <pr branch> [--pr tide#30] [--no-push]` |
| Handover queue | `queue.mjs` | `node core/ship/queue.mjs --dir <scratch clone> --branch <pr branch> [--test '["node","x.mjs"]']` (dry run only) |

- **Flags** are declared in `flags.json`, always off by default. An unknown flag is off; a broken `flags.json` turns all of them off.
  A flag turns on only through a `flag.set` event that names a decision (Jordan's yes); `foldFlagEvents` is the fold the ledger keeps.
- **Gates** report on the run's summary page and exit 0. The `GATE_*` lines at the top of `ci.yml` switch one to `enforce`
  (Jordan's card). A gate that cannot run says so; it blocks only in enforce mode.
- **Docs step** failures are named: `change-note-missing`, `change-note-no-effects`, `new-names-unlisted`, `glossary-missing`,
  `names-hit`, `names-check-error`. A change note lists its new names under `## New names` (or `- none`). MAP.md is rebuilt on main
  after the merge, in a `ship/docs-*` branch, which the generated-files gate allows; a PR never commits it.
- **Resurvey** and the **Handover queue** commit as the owner's noreply address (`OWNER_NOREPLY` in `git.mjs`; another address,
  noreply or not, is held), in a clean clone that shares history with main. They hold (exit 1) and name the reason and the
  conflicted files otherwise. Their results are activity results (`core/contracts/activity-result.schema.json`) with event drafts
  (`pr.updated`, `x.ship.re-review`, `merged`) for the engine.
- **Landing** (`await landPr({ land: true, wo, pr })`, from the engine only) takes no permission from its caller. It reads them from files:
  - the upgrade switch `ship.queue` = `new` in this repo's `kitchen/kitchen.json` (old and shadow only dry-run);
  - flag `ship.merge-queue` on: declared in `flags.json`, turned on by a `flag.set` event in `<state>\tide.db` (the ledger's event store,
    read only; state = `BRAIN_KITCHEN`, else `%LOCALAPPDATA%\brain-kitchen`);
  - in the same store: a merge card (`decision.asked`, kind merge) for the work order whose ask names the PR (`<repo>#<n>`), and Jordan's
    latest answer to it is Yes with the PR's **exact head sha as its proof** (a new push needs a new yes);
  - a `review.verdict` "ship" on that head that names its builder, by a reviewer who is not the builder (CREED 6).

  Then main and the PR must be unmoved since the test, and the push moves main forward to the tested merge commit: a fast-forward,
  never forced. An event store that cannot be read gives no permission.
- `ruleset-main-phase1.json`: the ruleset for main that blocks force-push and deletion (Jordan's tap:
  `gh api -X POST repos/JVonBorstel/tide/rulesets --input core/ship/ruleset-main-phase1.json`).

Tests: `tests/Test-Ship.ps1` (`node tests/core/ship/test-ship.mjs [name]`), throwaway git repos in the temp folder only.
