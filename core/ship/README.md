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
- **Resurvey** and the **Handover queue** need a GitHub noreply commit identity, a clean clone, and shared history with main. They
  hold (exit 1) and name the reason and the conflicted files otherwise. Their results are activity results
  (`core/contracts/activity-result.schema.json`) with event drafts (`pr.updated`, `x.ship.re-review`, `merged`) for the engine.
- **Landing** (`landPr({ land: true })`, from the engine only) needs `ship.merge-queue` on, a `decision.answered` "Yes" by Jordan,
  the `agent-review` status on the PR head when `ship.review-check` is on, the PR as `<repo>#<n>`, and main unmoved since the test.
  The push moves main forward to the tested merge commit; it is a fast-forward and never forced.

Tests: `tests/Test-Ship.ps1` (`node tests/core/ship/test-ship.mjs [name]`), throwaway git repos in the temp folder only.
