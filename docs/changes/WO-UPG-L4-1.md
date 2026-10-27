# WO-UPG-L4-1: the ship path (flags, CI gates, glossary, docs step, Resurvey, Handover queue)

## In plain words
Lane L4 of the Tide upgrade builds the road finished work takes to main, next to today's merge path, all switched off.
- **Flags** (`flags.json`, `core/ship/flags.mjs`): every new behaviour is declared once, off. An unknown flag is off. Jordan's yes
  (a `decision.answered` event, then `flag.set`) turns one on; the ledger keeps the current value.
- **CI gates** (`gates` job in `ci.yml`, `scripts/check-*.mjs`): WO id in the PR title, no generated file in a PR, a decision named
  for the Board's look, the old-names guard and Vale on `docs/`. Each only reports, on the run's summary page. Each has one line at
  the top of `ci.yml` (`GATE_*: report`); changing it to `enforce` is Jordan's card.
- **Glossary** (`docs/GLOSSARY.md`): the public part of the naming source, now in the repo so CI and contributors can read it.
  `AGENTS.md` line 3 points at it. The Vale vocabulary in `.vale/` comes from it.
- **Docs step** (`core/ship/docs.mjs`): after a merge it names what is missing (change note, its L1-L4 effects, a new name not in
  the glossary, an old word the names guard found) and rebuilds `kitchen/MAP.md` on main. A PR never commits MAP.md.
- **Resurvey** (`core/ship/freshen-pr.mjs`): merges main into a held PR and pushes normally. It never forces: a push the remote
  refuses is held. Unrelated history and conflicts are held with the files named. When main changed a file the PR also changes,
  it sets the re-review mark.
- **Handover queue** (`core/ship/queue.mjs`): tests the PR merged onto the latest main in a scratch clone. It lands only with the
  upgrade switch `ship.queue` at `new` (it stays `old`), the flag on, Jordan's Yes on a merge card that names the PR, given for its exact head sha, a verifier's ship on that head by a reviewer who is not the builder, all read from files (`kitchen/kitchen.json`, `flags.json`, the event store), never from the caller, and main unmoved since the test; it commits as the owner's noreply address; then main moves
  forward to the tested commit (a fast-forward). The command line only dry-runs.

Nothing in the Yard changed. `scripts/merge-pr.ps1` and `kitchen/train.ps1` are untouched and stay the merge path while
`ship.merge-queue` is off.

## Effects
- **L1 (person, Jordan):** fewer stuck PRs and no MAP.md conflicts later; today nothing changes on his screen. His taps: the gate
  switches, the flags and the ruleset on `main`.
- **L2 (business):** work lands only after it was tested on the main it lands on, so a green PR cannot break main by arriving late.
- **L3 (MSP):** the same queue, Resurvey and gates work for any repo with a `main` and a GitHub noreply identity; the lists are config
  (`core/ship/gates.json`, `flags.json`), not code.
- **L4 (community):** contributors read the glossary in the repo, and the gates explain themselves on the summary page.

## What changed
- New: `flags.json`, `core/ship/{flags,flags.schema,git,gates,gates.json,docs,freshen-pr,queue,activity}`, `core/ship/README.md`,
  `scripts/check-wo-title.mjs`, `scripts/check-generated.mjs`, `scripts/check-decision-gate.mjs`, `docs/GLOSSARY.md`, `.vale/**`,
  `tests/Test-Ship.ps1`, `tests/core/ship/*`.
- `.github/workflows/ci.yml`: the `GATE_*` switches, the names guard reads `GATE_NAMES`, a "Ship" step and a "Core" step (`node --check` on every `core/**/*.mjs`, and the suites of lanes L1 and L2 listed in `core/ship/gates.json` `coreSuites`, each once its file exists) in `checks` (next to the
  L0 Contracts step, which stays), and a new `gates` job. Vale runs through `vale-cli/vale-action` pinned by commit sha (v3.0.0),
  with Vale 3.24.0 (MIT).
- `AGENTS.md` line 3: the naming source is `docs/GLOSSARY.md`.
- `scripts/names-allow.json` (outside the lane, one line): `docs/GLOSSARY.md` is allowlisted, the same rule the private naming
  folder already has, because the glossary names the old words on purpose.

## New names
- **Flag**
- **Handover queue**
- **Resurvey**
- **Docs step**
- **Change note**
- **Gate**
- **Decision gate**
- **Generated file**
- **Event store** (this and the 7 below: lane L1's names, from its card 6)
- **Source key**
- **Row**
- **Stream**
- **Card**
- **Parity**
- **Shadow database**
- **WO-PR-TIDE-21**

## Proof
- `node tests/core/ship/test-ship.mjs`: Ship tests 172 passed, 0 failed (6 files), on Windows (Node 22.12, pwsh 7.6).
- `node core/ship/flags.mjs check`: 4 flags declared, all off by default.
- CI on the PR: `checks`, `gates`, `quality` (counts on the run's summary page).
