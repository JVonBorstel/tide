# Building out the Yard (code: `kitchen`)

Most growth is one file plus one test. Pick the piece you need.

| You want to... | Add | Test it with |
|---|---|---|
| a new kind of work (a script, a tool, an agent with a twist) | a **Step** (code: station): `kitchen/stations/<name>.ps1` | a scripted job in a `Test-*.ps1` |
| a repeatable multi-step job | a **Spec**: `kitchen/recipes/<name>.json` | `tests/Test-KitchenRecipes.ps1` pattern (scratch repo + scripted cook) |
| a new way in (bot, chat app, phone bridge) | an **adapter** that sends JSON to `kitchen-api.ps1` (see API.md) | `tests/Test-KitchenApi.ps1` pattern |
| a new screen or button in the Board | `pass-app/public/app.js` + an action in `pass-app/server.mjs` | `tests/Test-PassApp.ps1` |
| a setting | a key in `kitchen/kitchen.json` (state-folder copy overrides; command line overrides both) | |
| a new AI supplier (a new model service, e.g. a new lab's CLI or API) | a **cook adapter**: `kitchen/cooks/<name>.ps1` + `suppliers.<name>` and menu entries in `kitchen.json` | a fake CLI in `tests/Test-SousChef.ps1` |
| a different model for a role, or a new local model | `suppliers.<name>.tiers` in `kitchen.json` (local: `ollama pull <tag>` first) | `just cooks`, `just sous "..."` |
| a new kind of order or a new routing preference | `menu` in `kitchen.json` (kind -> cooks, best first) | `tests/Test-SousChef.ps1` |
| something the Yard does on a schedule | `standing` in `kitchen.json` (`recipe` + `everyHours`) | |
| words that must never leave the PC | `sous.privateWords` in the **state-folder** `kitchen.json` only | `just sous "..."` |

## A Step (code: `station`)
A Step is any PowerShell script. The supervisor runs it in its own process with limits (time, memory of the whole process tree,
log size, optional heartbeat), and judges it by its exit code: 0 = done, anything else = failed (retried, then Failed, code: `quarantined`).
It gets these environment values: `KITCHEN_JOB` (J12), `KITCHEN_RUN` (this attempt's file prefix), `KITCHEN_HEARTBEAT` (touch it to
show you're alive; a step with no heartbeat, log line or cook activity for its `hungSec`, 900 s unless the Spec sets one, is killed as hung;
write `<time> quiet=<sec>` before a bounded silent wait such as a test suite), `BRAIN_AGENT_DEPTH`, and `BRAIN_KITCHEN` (the state folder). This job's branch folder, if any, is
`$BRAIN_KITCHEN\worktrees\$KITCHEN_JOB`.
```powershell
# Station: <one line on what it does>. Safe to re-run? <yes/no and why>.
#   step: {"station":"<name>","args":{"Thing":"..."}}
param([Parameter(Mandatory)][string]$Thing)
$ErrorActionPreference = 'Stop'
if ($env:KITCHEN_HEARTBEAT) { for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::WriteAllText($env:KITCHEN_HEARTBEAT, (Get-Date -Format o)); break } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } } }
Write-Output "<name>: working on $Thing"     # everything printed lands in the step log (the taster reads it)
exit 0
```
Rules: print what you did; exit non-zero on failure; if re-running could do damage, mark the step `"replay":"unsafe"` in the Spec;
anything irreversible gets `"approve":true` so it waits for Jordan.

## A Spec (code: `recipe`)
```json
{
  "description": "One sentence Jordan sees in the recipe book.",
  "vars": { "goal": { "required": true, "max": 1500 }, "repo": { "default": "C:\\path" } },
  "steps": [
    { "station": "agent", "args": { "Role": "research", "Prompt": "... {{goal}} ...", "Tools": "WebSearch,WebFetch" },
      "timeoutSec": 1500, "retries": 0, "mustMatch": "SOURCES" },
    { "station": "merge", "args": { "Repo": "{{repo}}" }, "approve": true, "replay": "unsafe" }
  ]
}
```
- `{{var}}` is filled when a work order is made from the Spec; `{{job}}` and `{{worktree}}` are filled at run time.
- Step limits: `timeoutSec`, `maxMB`, `maxLogMB`, `hungSec` (default 900; -1 = off), `retries`. Gates: `approve`, `replay`.
- The Inspector (code: `taster`): `mustMatch` (the output must prove it worked) and `mustNotMatch` (red flags such as `\bskipped\b`).
- Agent steps don't name a model: the **Dispatcher** (code: `sous-chef.ps1`) picks the crew (see below). A step may still force one with `Supplier` / `Model`. Each run has `MaxBudgetUsd` and `MaxTurns`; `Context` attaches files (so the local cook can work on them); `Order` is what was asked (cook.ps1 fills it in).
- Every Spec also takes two work-order options: `cook` (auto | claude | gemini | local) and `private` (yes = never leaves this PC).
- Run it: `just improve "..."`, `kitchen/cook.ps1 -Recipe <name> -Vars @{...}`, the Board's New work order sheet, or `{"op":"cook"}` over the API.

## The self-improvement line (Spec `improve`)
worktree (own branch) → the Dispatcher plans → a crew edits → commit + diff → **Resurvey (code: `freshen`; merge in the latest code)** → every test suite → the Inspector reviews → **pull request on GitHub** (`pr`) → **GitHub's CI** (`ci-wait`) → **waits for Jordan** → merge → verify → deploy (the Board, only if `pass-app/` changed).
Nothing reaches the real checkout without passing the tests, passing the Inspector, and Jordan's yes. A failed step stops the line
before Jordan is asked. A change merged *while this one waits for Jordan* can still conflict; the merge station then aborts cleanly. Merges into the same repo run one at a time (a named lock; a queued merge waits up to 5 minutes, then refuses with nothing changed). Bot orders also wait for Jordan before the first step.

## Other repositories (`kitchen.repo.json`)
The line builds in any git repo: `kitchen/cook.ps1 -Recipe improve -Vars @{ goal = '...'; repo = 'C:\path\to\repo' }`. A repo that does not keep its suites at
`tests\Test-*.ps1` says so in `kitchen.repo.json` at its root (no file = this repo's own layout, nothing changes):
```json
{ "tests": ["tests/phase0/Test-Phase0.ps1"], "testTimeoutSec": 900, "github": "owner/name", "protected": [".claude/**", "scripts/**"] }
```
- `tests`: relative paths or globs (`*`, `**`, `?`), each ending in `.ps1`; `testTimeoutSec`: per-suite limit, 1-3600; `protected`: globs auto-merge never takes without Jordan's yes (the file itself is always protected). Unknown keys are ignored; a wrong type, an absolute path or a `..` is an error and the station stops (exit 2), it never falls back to the defaults.
- **Read from the repo's main checkout, never from the job's worktree** (`kitchen/repo-config.ps1`): a cook edits the worktree, and could otherwise empty the test list. The suites themselves are found in the worktree, so a test the cook adds runs, and a configured suite the cook deletes fails the run.
- Used by the tests, mutate, map, verify and merge stations. freshen, verify and undo-merge treat the repo's default branch (origin/HEAD, else main, else master) as "main".
- `roadmap`: a relative path to the repo's roadmap .json (opts the repo into Spec `roadmap-item`; see "Map, roadmap, build" below).
- `freeze`: merge freeze windows, `[{"from": "2026-10-27T00:00", "to": "2026-10-28T18:00", "why": "release demo"}]` (this PC's local time; an ISO offset such as `-06:00` or `Z` is honoured). Inside a window the `merge` station merges nothing into the repo, on GitHub or locally: it waits (exit 11, "frozen until 10-28 18:00: release demo") and resumes when the window ends; building, testing and opening PRs go on. `scripts/merge-pr.ps1` (Claude sessions) refuses too, reading the file from the PR's base branch on GitHub. A malformed window holds the merge for Jordan (exit 10) naming the field (`'freeze[0].to'`). `kitchen.ps1 status` prints a `FREEZE` line and the Board shows a calm banner (from `<kitchen>\freeze.json`, rewritten by the tick every 2 minutes). Code: `kitchen/freeze-lib.ps1`. Tests: `tests/Test-Freeze.ps1`.
- **Claude sessions merge through `scripts/merge-pr.ps1 -Repo owner/name -Pr N [-Why text] [-DryRun] [-FixesRed]`**, never a bare `gh pr merge`: it merges only when the PR is open, at least one check exists on its head and every check is completed with success, skipped or neutral, no freeze window covers now, and the Tower's main status is not red or unreadable (Site closed when red, TD-EH-03c: `-FixesRed` merges the PR that is the fix anyway, logged with `fixesRed: true`, `mainWas`, `mainStatus`); pinned with `--match-head-commit`, subject "(Claude session)", one line `{pr, repo, sha, actor: 'claude-session', why, at, ok[, error]}` in `<kitchen>\merges.jsonl`. Tests: `tests/Test-MergePr.ps1`.
- **Site closed when red (TD-EH-03c):** while a Tower's main status (`<kitchen>\main-status\<sha12>.json`, written by the verify Step, `kitchen/main-status.ps1`) is red, or its file cannot be read (unknown is not green), the `merge` Step merges nothing: it waits (exit 11, back in 15 minutes) naming the suites and why. A PR the Owner already merged on GitHub still comes home. No status recorded yet does not close a Tower. Tests: `tests/Test-KitchenMerge.ps1`, `tests/Test-PrFlow.ps1`, `tests/Test-MergePr.ps1`.
- **Recheck main now (TD-EH-03d):** the verify Step only checks main after a Yard merge, so a fix merged with `merge-pr.ps1 -FixesRed` would leave main marked red for good. The Foreman runs `pwsh -File scripts/recheck-main.ps1 -Repo <the Tower's checkout> [-All] [-Local]`: it reruns the suites the main status names as failing (every suite with `-All`) on the Tower's current main (this PC's main, or GitHub's main when that is ahead; split apart or GitHub unreachable checks nothing, `-Local` checks this PC's only) in a throwaway worktree under TEMP, through the same tests Step and bounded runner, removes the worktree however the run ends, and records the main status green or red. The live checkout's working tree is never touched. The `merge-pr.ps1` refusal names it. Exit 0 green, 1 red, 2 nothing recorded (says why). Tests: `tests/Test-RecheckMain.ps1`.
- **Night inspection (TD-EH-03b):** the standing order "night inspection" (kitchen.json, off until the Owner's kitchen.json says `"standingOn": ["night inspection"]`) runs `scripts/night-inspection.ps1` at 02:00 on this PC: `recheck-main.ps1 -All -SkipUnchanged` inside run-bounded (90 min), so main's status is written green or red every night with no GitHub minutes; main unchanged since its last green full run is skipped with the reason (exit 3). One line a night in `<kitchen>\night-inspection.jsonl`. It is a **watcher order** (`"watcher": "<script>"` in place of `"recipe"`): started detached, needs no LIVE, and also starts while the Yard is paused (the paused Walkround calls `Invoke-ChoreStanding -WatchersOnly`; TD-EH-26: paused = start no work, still watch). Tests: `tests/Test-RecheckMain.ps1`, `tests/Test-KitchenSupervisor.ps1`, `tests/Test-KitchenRecipes.ps1`. Note: `docs/changes/TD-EH-03b.md`.
- A suite that cannot run at Low integrity (it needs Git's `sh.exe`, or writes inside its own repo folder) goes in `kitchen.json` `sandboxMedium` with the files that put a job back to Low (an entry ending in `/` is a whole folder). Demo Project's `Test-Phase0` is there. Suite names are global to the Yard.
- Test: `tests/Test-RepoConfig.ps1`.

**Which suites run (`tests.ps1 -Impacted`).** Repair's loop runs pass `-Impacted`: only the suites the changed files (diff against `.kitchen/BASE`) map to. Every other caller (the Spec's tests Step, verify, CI) runs all suites.
- Map: a changed `tests/Test-X.ps1` runs itself; `pass-app/**` runs `Test-PassApp`; `scripts/memory-check.ps1` runs `Test-BrainMonitor`; `kitchen/*.ps1`, `kitchen/stations/*.ps1`, `kitchen/recipes/**` and `kitchen/cooks/**` run `Test-KitchenSupervisor` plus a same-name suite (`Test-<Name>`, `Test-Kitchen<Name>`, `Test-<Name>Station`). Any suite that names a changed file by its full path runs too, and so does any suite that failed in the last `TESTS.txt`.
- All suites run, with the reason printed, when the change list is empty or unknown, a shared file changed (`run-bounded.ps1`, `secret-patterns.ps1`, `repo-config.ps1`, `github-lib`/`tracker-lib`/`roadmap-lib`/`suite-times-lib`, `kitchen.json`, `kitchen.repo.json`, `stations/tests.ps1`, `stations/lint.ps1`, `lint.ps1`, `rust/kitchen-sandbox/`, `.github/`, a helper under `tests/`), a file maps to nothing (docs included), or the map finds no suite.
- A narrowed run ends `PARTIAL PASS: N of M suites` (skipped suites are listed as `not run (not impacted)`), never `ALL PASS`, and writes no `results\<job>.tests.json` unless it failed. Repair then runs all suites once; only that run can say `ALL PASS`. The map is a fixed table in `tests.ps1`; a per-repo map is not built yet.
- Test: `tests/Test-TestImpact.ps1`.

**How suites run (several at once, `tests.ps1` + `kitchen/suite-times-lib.ps1`).** Every suite run adds a line to `<kitchen>\suite-times.jsonl`
(`{repo, suite, sec, cpuSec, procs, peakMB, sampled, ok, code, parallel, sha, at}`, written by `scripts/run-bounded.ps1 -TimesFile` from its job's own counters;
a sandboxed suite is sampled every 0.5 s, `sampled: true`). The station reads the last 20 lines per suite of this repo and:
- runs up to min(4, cores / 2) suites at once (`-Parallel N` to set it), **one at a time while the repo has no history yet**;
- starts a suite only while the recorded peaks of the running suites + its own peak + **1,024 MB reserve** stay under free RAM (a suite with no record counts as
  1,200 MB, the largest peak measured); a suite alone always starts, as before;
- starts the longest first (median seconds; suites with no record first), and keeps TESTS.txt and the `FAILED:` list in the suites' own order;
- never runs a suite with a `# runAlone` line in its header (its leading `#` lines) next to another one: it starts when the pool is empty and nothing
  starts while it runs (they go first). Derived from the file, no list. `Test-PassApp` has it (failed twice in a 4-at-once run, 653/653 alone);
- gives each suite clamp(3 x p90 of its last 20 passing runs, 60 s, `testTimeoutSec`) instead of one fixed limit (no passing run yet: `testTimeoutSec`).
Measured basis: gemini-brain `projects/tide/arch-10-22/tests-ci.md` (57 suites 2,644 s one at a time, 818 s three at a time). Tests: `tests/Test-TestsStation.ps1`.

**Repair runs the failed suites first.** After each cook round `repair.ps1` re-runs only the suites that failed (`tests.ps1 -Only`); still red ends the round
there (no full run), green goes on to `-Impacted` and then one full run, the only one that can say `ALL PASS`. `-Only` never writes a pass to
`results\<job>.tests.json`. Test: `tests/Test-Repair.ps1`.

**GitHub.** `pr` pushes `kitchen/<job>` (by URL: `https://github.com/<github>.git`) and opens or reuses a PR against main (body: the plan's
summary, the test line, the job id; secret-looking lines left out). `ci-wait` waits (exit 11) until every check on the PR is green for
the tested commit; a failed check, a closed PR or a push by someone else fails it. Jordan says yes with his tap in the Board **or by pressing
Merge on the PR** (he authors the PR, so GitHub's approve is not his; the supervisor sees the merge and records his yes, kind `github`).
`merge` then merges with `gh pr merge --merge --match-head-commit <tested sha>` (or finds it merged) and fast-forwards the real checkout's
main to GitHub's; a dirty checkout or a local main GitHub lacks is held for Jordan. Auto-merge of a PR order also needs every CI check
SUCCESS. Spec var `github` = `owner/name`, `none`, or empty (derived: `JVonBorstel/<repo folder>`, skipped when GitHub has no such
repo). Private orders never leave the PC: no push, no PR, local merge. Records live in `<kitchen>\results\<job>.pr.json` / `.ci.json` /
`.merge.json` (and `.kitchen\PR.json` in the worktree). Tests: `tests/Test-PrFlow.ps1` (a fake `gh` over a local bare repo; `KITCHEN_GH`,
`KITCHEN_GITHUB_REMOTE` and `KITCHEN_CHEF_UPDATE_SCRIPT` point the stations at fakes).

## Map, roadmap, build (Spec `roadmap-item`)
The method that built Demo Project, for any repo: **map first, then a roadmap, then one PR per item.**
1. **Map** (docs before code): what exists, what the work is, the controls and standards it must meet (Demo Project: `map/inventory.json`,
   `map/controls.json`, `docs/STANDARDS.md`). No code is written while mapping.
2. **Roadmap** (`map/roadmap.json`, machine-readable): Pours (code: `waves`) of items. Each item says what it is and what it may touch:
   ```json
   { "waves": [ { "id": "W1", "goal": "...", "items": [
     { "id": "B-01", "title": "...", "why": "...", "depends_on": [], "owns": ["core/levers/registry.py", "tests/py/levers/"],
       "acceptance": ["B01-1: ..."], "controls": [], "inventory_ids": [], "standards": ["STD-PY"], "size": "M", "owner_only": false } ] } ] }
   ```
   Required: per Pour `id`, `goal`, `items`; item `id` (like B-01), `title`, `why`, `depends_on` (known ids, no cycles), `owns` (1+ paths,
   folders ending in `/`, or globs), `acceptance` (1+). Anything wrong stops the order with a message naming the item (fail closed).
3. **Build**: each item is one order and one PR, in dependency order. Station `roadmap-item` writes the order (`.kitchen\ITEM.md`: title,
   why, owns, acceptance, standards, "follow docs/STANDARDS.md and the DOD in docs/ROADMAP.md") and refuses an `owner_only` item (Jordan's),
   one already merged, or one whose `depends_on` are not all merged. The rest is the improve line. **Owns are enforced**: `commit` refuses
   (exit 1, nothing committed) any change outside the item's owns, except `docs/changes/<item>.md` and `specs/<item>.md`; it takes the owns
   from the main checkout's roadmap, also when `repair` commits. The PR title starts with the item id, so the merge commit names it.
4. **Pours** (code: `waves`): `kitchen/roadmap.ps1 status -Repo <path>` (`merged` / `cooking Jnn` / `set-aside Jnn` / `owner-only` / `blocked-by B-xx` /
   `not-started`), `next -Wave W1` (ready: every depends_on merged, not owner_only, not `cooking`), and `cook -Wave W1 [-Max 3] [-WhatIf]`
   (queues work orders for the ready ones; at most `-Max` of the roadmap's items building at once; never two whose owns overlap; approves nothing).
   An item counts as merged only when its change note `docs/changes/<id>.md` is on the default branch (also what unblocks its
   dependants); a merge text or commit that names the id, or a done job, is not proof. A revert that drops the note un-merges it, so
   keep the notes in `docs/changes/` when a Pour is closed. A failed item is
   `set-aside` until Jordan closes or recooks its job. Close a Pour by hand (fold the change fragments, update the map) before the next.

**Opt a repo in**: add `"roadmap": "map/roadmap.json"` (a relative path to a .json file) to its `kitchen.repo.json`, merged to main like
any change to that file (it is protected). Then `kitchen/roadmap.ps1 status -Repo <path>`. One item by hand:
`kitchen/cook.ps1 -Recipe roadmap-item -Vars @{ repo = '<path>'; item = 'B-01' }`. Tests: `tests/Test-Roadmap.ps1`.
A hand-made PR for an item counts as merged the same way: it must add `docs/changes/<id>.md`.

## The Watch (no silent endings; nothing watches itself)
The plan is gemini-brain `projects/tide/` (02-the-watch.md). What the Yard runs, all scripts, no AI:
- **`kitchen/ledger.ps1`** (every 5 minutes from the tick): one list of every idea, order and roadmap item with its state from PROOF only
  (a commit on main naming it, `docs/changes/<id>.md`, a finished non-code order, or `ledger.ps1 link -Id -Proof -Why`). States:
  shipped, waiting-on-jordan, moving, stuck, lost, claimed (closed "done another way" with no proof), not-started, dropped. Flags carry
  an owner and a plain sentence. Writes `ledger.json` and `watch\ledger.json`. The Board shows it in the Ledger tab.
- **No silent endings:** `kitchen.ps1 close` needs `-ReplacedBy J12`, `-Proof <commit|PR url|file>` or `-Why "dropped: ..."`. A close
  with only a reason is refused. Build work outside the Yard? Name the idea or item in the PR title, or `ledger.ps1 link` it.
- **`kitchen/watch.ps1`** (hourly from the doctor): heartbeats in `watch\*.json` on time, the tick fresh, `Kitchen-*`/`Rig-*` task
  results, `gh auth status`, both backups fresh, the mode (LIVE, PAUSED, push-on) stated. **`scripts/memory-truth.ps1`** (hourly):
  memory index vs files, frontmatter, named paths exist, mode claims true, NOW/BOOT/active-build ages. **`scripts/restore-drill.ps1`**
  (weekly): last night's off-drive backup restored into TEMP and every file parsed. The doctor alerts only when the findings change.
- **Every watcher writes a heartbeat** (`name`, `lastRun`, `everyMin`, `checked`, `found`). The Board's server, a separate process, raises an
  alarm when the tick or any heartbeat is late, so a dead tick is still seen. Tests: `Test-Ledger`, `Test-Watch`, `Test-PassApp`.
- **The new ledger (upgrade lane L1, switched off):** `node core/ledger/cli.mjs build|show|queue|streams|flags|parity|backup` builds an
  append-only event store (`tide.db`) from the Yard, GitHub, worktrees and plans, on a scratch copy only while `upgrade.ledger` is `old`.
  `parity` checks it against `ledger.ps1`. See `core/ledger/README.md`. Tests: `Test-CoreLedger`.

## The Dispatcher (code: `sous-chef.ps1`)
Every AI step asks it which crew (code: cook) to use, and it answers with one choice and its reasons (shown in the step log, the Board app and the status board):
1. **Privacy first**: patterns (emails, phones, card/ID numbers, secrets, health and money words, `privateWords`) and a local decision
   model (`tev1:0.8b` through Ollama's `/v1/systemone`: P(personal) >= `privateAt`) keep personal orders on this PC. A private order
   only a cloud cook could do is **held** for Jordan (exit 10); his yes covers that one step. If the judge can't answer, plain-text orders stay local.
2. **Kind** (plan, code, research, check, review, write, quick, big) from role, tools and size; the judge sorts unclear text.
3. **Menu**, then skip cooks that are off, signed out, resting after a usage limit, at their run cap, or can't do the job.
4. **Pressure and learning**: near its cap a cook goes last; past 80% of the day's budget cheap orders go local; a cook that keeps
   failing the Inspector for a kind moves down; a retry never repeats the cook that failed and steps up a tier.
5. **Nothing free?** The step **waits** (exit 11) without using a retry; a cook that hits its limit mid-step hands over to the next one.
Try it: `just sous "..."` (decides only), `just cooks` (the cooks' state), `just wake <cook>`.
The **model scout** (Spec `scout`) runs weekly as a standing order and reports what's new in AI models vs what we run.

## Building in public
Tide's home is https://github.com/JVonBorstel/tide, a **public** repo (since 2026-10-26): every commit, branch name, PR text and CI log
can be read by anyone. The history before 2026-10-24 stays in a private repo and is never pushed here.
- **Commit and merge identity: the noreply address.** Commit as `Jordan VonBorstel <204934145+JVonBorstel@users.noreply.github.com>`
  (`git -c user.name="Jordan VonBorstel" -c user.email=204934145+JVonBorstel@users.noreply.github.com commit ...`, or that `user.email`
  in the checkout). Claude sessions merge only with `pwsh -File scripts/merge-pr.ps1 -Repo JVonBorstel/tide -Pr N`: the merge commit
  is authored with the signed-in account's noreply address (`Get-MergeAuthorEmail` in `kitchen/github-lib.ps1`), never the account's
  primary email. No web-button merge and no bare `gh pr merge` from a session (2026-10-26: a web merge put a private address on main).
- **Personal values live only in the state folder** (`%LOCALAPPDATA%\brain-kitchen`): this PC's repo list and suite list
  (`verify-all.json`), job-search and career settings, private words, the push topic, the Board's key. The repo keeps generic
  defaults and reads the state-folder copy over them (as `kitchen.json` does). A new personal value goes there, never in a tracked
  file, a test fixture or a PR text. Paths in docs are `%USERPROFILE%\...`, never a real user folder.
- **Private work comes over only through the port tool.** Work done in the private repo reaches this repo only by
  `scripts/port-private.ps1`: a private branch becomes a cleaned tree (the same cleaning rules every time), then a branch on tide's
  main and a PR. No hand copies, no cherry-picks across the two histories (they are unrelated, so `freshen` cannot merge them either).
- **The cleaning scan.** Before anything from the private side is pushed, a privacy scan runs on the cleaned tree and must report 0
  live hits: secret-shaped values (`scripts/secret-patterns.ps1`), this PC's user name and paths, private network and device names,
  personal and employer emails and names, and private project names. The scan compares against values read live from this PC, so it
  lives in the private notes, not here. A session also greps its own diff for those words before every push and stops on a hit.

## Before you finish any change
1. The relevant `tests/Test-*.ps1` passes (run through `scripts/run-bounded.ps1`).
2. `just verify` is green.
3. README / API.md / this file still tell the truth.

## Fresh Claude sessions without a gap
- `/handoff` (source: `claude/commands/handoff.md`, installed to `~/.claude/commands`) writes `gemini-brain/memory/PICKUP.md`, a note on the Board (`lead.ps1 handoff`), a progress line, and rebuilds the toolbox talk (code: `memory/BOOT.md`).
- `scripts/handoff.ps1` puts the shift handover (code: `PICKUP.md`) near the top of the toolbox talk (`## Pick up here`, 30 lines, flagged OLD after 48 h). The SessionStart hook injects it, so a new session needs only `continue`.
- The context guard tells Claude to hand off at a clean stopping point once context passes 50%: cost grows with context on every turn (tide/05).
