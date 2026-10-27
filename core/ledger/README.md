# The ledger (core/ledger)

The record of truth for the Tide upgrade (build-way 3.1, lane L1). Every change to a work order is an **event** in an append-only SQLite
file (`tide.db`). The ledger rows, Jordan's decision queue, the streams and the feature flag values are **queries over the events**, built
again from the start every time. Today's `kitchen/ledger.ps1` is untouched and stays the fallback.

Status: the `upgrade.ledger` switch is `old`. Nothing reads this yet. It runs only by hand, against a scratch copy of the state folder.

## Use it

```
node core/ledger/cli.mjs build --state <scratch copy> --db <scratch>\tide.db [--github owner/a,owner/b | --no-github]
                               [--repo tide=<checkout>] [--plans <notes>\plans] [--work <notes>\work] [--flags flags.json] [--json]
node core/ledger/cli.mjs show WO-312 --db <file>      # or J312: one row with its events
node core/ledger/cli.mjs queue --db <file>            # Jordan's cards, oldest first, and orders waiting on him with no card
node core/ledger/cli.mjs streams --db <file>          # streams, WIP, over-limit flags
node core/ledger/cli.mjs flags --db <file>            # feature flag values
node core/ledger/cli.mjs parity --db <file> --old <scratch>\ledger.json   # every old item: same, explained or unexplained
node core/ledger/cli.mjs backup --db <file> --to <file>                   # the nightly copy (VACUUM INTO)
```

- `build` writes the store, `work.json` (rows, queue, streams, flags, flag values) and `ledger.next.json` (the old `ledger.json` shape),
  all in the `--db` folder (or `--out`). It prints the top line and how many events each source added. A rerun with nothing new adds 0.
- **The live state folder is refused** while `upgrade.ledger` is `old`. Moving it to `shadow` is Jordan's card. `LEDGER_LIVE_STATE=<folder>`
  guards one more state folder the same way (ops); it never removes the guard on the Yard's own folder.
- Node 22.5 or later is needed (`node:sqlite`); below that the command says so in plain words.
- Exit codes: 0 fine, 1 the store or a source could not be read, 2 a usage error or a refused write, 3 parity found unexplained items.
- Node 22 needs `--experimental-sqlite` for `node:sqlite`; Node 24 does not. `cli.mjs` checks and adds the flag only when needed.
- `--json` on any command prints one JSON answer (`{ ok: false, code, error }` on failure).

## The parts

| File | What it does |
|---|---|
| `store.mjs` | The only file that touches `node:sqlite` (so `better-sqlite3` can be swapped in). It hands out no raw SQL. Append-only (triggers refuse UPDATE, DELETE and REPLACE; `recursive_triggers` on), WAL, STRICT tables, schema version in `PRAGMA user_version`, every event checked against `core/contracts/event.schema.json`, a `key` for one-time facts and a `family` + `value` for observations that can change back (written only when the value differs from the family's last one, so A -> B -> A keeps all three). Errors: `corrupt`, `locked`, `newer-schema`, `missing`, `bad-event`, `append-only`, `unavailable`. |
| `import-yard.mjs` | `jobs\J*.json` + `jobs\archive\index.jsonl` + `events.jsonl` -> events. J312 becomes WO-312 (alias J312). Close reasons, replacements, quarantines, the PAUSED file. |
| `import-github.mjs` | `gh pr list` (read only): open PRs of every Tower; merged PRs from the Board's G2 read (`towers-github.json`) when it is under 10 minutes old. A rate limit or offline keeps the last good read (`github-last.json` next to the store). |
| `import-local.mjs` | `git worktree list`, branches merged into main, ids named on main (a revert marks undone), plan files (`wo:` lines and slice tokens like G4), `work/<WO>/BRIEF.md` and `REPORT.md` front matter. Also the change notes on main (`docs/changes/*.md`) and idea and roadmap ids named on main. |
| `import-ideas.mjs` | `ideas.json`, manual proof links (`ledger-links.json`) and Jordan's drops in Chef (`pass-actions.jsonl`). Ideas make no rows. |
| `import-roadmap.mjs` | Roadmaps of the repos that opt in (`roadmap` in `kitchen.repo.json`; the Yard's own repos are found from its orders), and the lobe's `flags.json` (decisions ready, post-mortems due). |
| `legacy.mjs` | The old ledger's own items rebuilt with the rules of `kitchen/ledger.ps1`: ideas with their chains, roadmap items and programs, drift, the lobe's flags with the proof for each post-mortem. The export puts these first, then the rows the old file never had (counted under `work`). |
| `view.mjs` | The pure fold: rows (row contract), the stage machine, states, the queue (oldest first), streams and WIP (4 build streams, 3 cards per stream, no stacks for ART/CITY/BOARD, 2 elsewhere), attention flags, flag values, the `ledger.json` export. |
| `parity.mjs` | Old `ledger.json` against the new view, item by item, with the reason for every difference. |
| `cli.mjs`, `commands.mjs` | The command above. |

## Rules the view keeps

- **Shipped needs proof**: a merge sha (GitHub), a commit on main naming the Yard order, a finished non-code order, or a close with proof.
  A status alone is never trusted. A finished code order with no commit on main is `lost`.
- The WO id comes from the PR title prefix (`WO-312:`), else the branch (`kitchen/J312`), else the PR gets its own id (`WO-PR-TIDE-21`).
- A conflicting PR, or one with no push for 24 h, is `stale` (next: freshen-pr). A PR closed without merging is `lost`.
- A PR whose title says `Port #132` replaces open PR 132 of the one other repo that has it.
- The plan of a row is exactly one plan: its own, its brief's, the one plan whose `wo:` names it, or the one plan that names its slice
  token. Two or more is no plan, and a `no-plan` flag says which.
- Feature flags: defaults from `flags.json` (L4), then `flag.set` events; an unknown flag is off.

## Not here yet (cards)

- The export's `since` is an ISO time; the old file wrote PowerShell's local date text. The Board does not read `since`.
- Node 22.12's bundled SQLite (3.47.0) has **no FTS5** ("no such module: fts5", measured 2026-10-26), so full-text recall needs another way.

Tests: `tests/core/ledger/test-ledger.mjs` (`tests/Test-CoreLedger.ps1`).
