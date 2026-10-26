# The Yard (code: `kitchen`): the supervisor for Jordan's agent crews

The Yard runs agents as bounded work orders (code: jobs), survives its own crashes, and asks Jordan before anything risky.
Names: `gemini-brain/projects/tide/naming/GLOSSARY.md`. Commands, files, task names and IDs below keep their code names.

## Use it
| You want to | Run |
|---|---|
| See it work (safe, simulated) | `pwsh -File kitchen/demo.ps1 -Open` |
| See what's running | `pwsh -File kitchen/kitchen.ps1 status` |
| Sign off a waiting work order | `pwsh -File kitchen/kitchen.ps1 approve -Id J3` |
| Stop everything | `pwsh -File kitchen/kitchen.ps1 kill -All` |
| Add a work order | `pwsh -File kitchen/kitchen.ps1 add -Name review -Script <step.ps1> [-Approve] [-Replay unsafe]` |
| Status page | `pwsh -File kitchen/kitchen.ps1 report -HtmlPath status.html` |
| Self-check and backup | `pwsh -File kitchen/kitchen.ps1 doctor` |
| Short form | `kitchen\jk.cmd status`, `jk approve -Id J3`, `jk demo` |

Other bots and front ends: see [API.md](API.md) (one JSON contract over command line, inbox folder or MCP; bots can never sign off).

24/7: the scheduled task `Kitchen-Supervisor` runs the Walkround (code: `kitchen.ps1 tick`) every minute. Each Walkround resumes from disk. A finished step touches `run\WAKE`, so the Walkround takes its next pass within a second (it waits for wakes until 45 s after its start). `Kitchen-Chores` runs Site cleanup (code: `kitchen.ps1 chores`) every 2 minutes (status board `board.html`, ledger, doctor, CI looks, ideas); until that task is installed the Walkround does the cleanup itself. Staffing (code: admission, `kitchen/scaler.ps1`): light steps start outside the slots, heavy ones up to a RAM-scaled limit (`maxConcurrentAuto`, default 6) only once their weight is measured, else up to `maxConcurrent`; Handover (code: the merge train, `kitchen/train.ps1`) is per repo. `scripts/install-tasks.ps1` (re)registers it and `Kitchen-Pass` with the update-proof pwsh alias (`-WhatIf` first; `-RunBeforeSignIn` to survive an overnight reboot). `kitchen.ps1 pause` / `resume` stops Walkrounds on purpose; the Board (code: `pass-app/`) pushes once if Walkrounds stop otherwise. `scripts/backup-state.ps1` copies the state off the C: drive each night.

## What it catches (each is tested in tests/Test-KitchenSupervisor.ps1)
| Agent behaviour | Control |
|---|---|
| Fails | retry after a real wait (`kitchen.json` `backoff`, `kitchen/backoff-lib.ps1`): 30 s, 2 min, 8 min, 30 min for the step's own failures; 5, 20, 60 min when it waited on CI, the network, GitHub or a rate limit; +-20 % jitter. Events and the Board say "waiting N min before retry". After the step's retries: Failed (status `quarantined`) and an alert (tested in Test-Backoff.ps1) |
| Cloud hiccup (503, unavailable, API timeout) | waits 1-5 min (jittered), no retry used; after 5 on a step it counts as a failure; a build step that already changed files keeps them and goes on to commit (Inspection and the Inspector (code: `tests`, `taster`) still check) (tested in Test-SousChef.ps1) |
| Crashes silently | no exit code = crash; safe steps retried, unsafe steps wait for a human |
| Eats memory | whole process tree measured; killed over the cap |
| Floods its log | killed over the log cap (lesson from the 4.9 GB log, 2026-10-09) |
| Hangs | heartbeat goes quiet; killed |
| Never finishes | time limit; killed |
| Spawns more agents | depth cap (depth 2 may not spawn), 5 children per work order, 100 work orders total; refusals logged |
| Swarm-wide failure | Stop-work order (code: circuit breaker) stops new starts: opens when 5 of the last 10 steps failed, stays on at least 5 min (longer each time it opens again soon after closing, up to 30 min), lifts only when failures fall under 30 % or one trial step passes. One HIGH alert per episode and one "lifted" note (`kitchen.json` `breaker`; tested in Test-Backoff.ps1) |
| Risky step | waits for Jordan's sign-off; the yes is hash-verified and remembered, never asked twice |
| Supervisor dies | all state on disk; next Walkround resumes; workers keep running |

Every decision lands in `events.jsonl` (append-only audit trail). Alerts go to `alerts.jsonl`, and to Jordan's phone once `BRAIN_NTFY_TOPIC` is set.

## Live agents
`agent-step.ps1` runs one AI step. The **Dispatcher** (code: `sous-chef.ps1`) picks the crew for it: Claude (Claude Code CLI on Jordan's plan), Gemini (Gemini CLI on Jordan's Google plan) or the Home crew, a local model through Ollama (free, private), and says why; personal work orders never leave the PC. Crews are adapters in `cooks/`. It is a dry run unless `KITCHEN_LIVE=1` or the `LIVE` switch file exists. See BUILDING.md.

## Other repositories
The `improve` Spec (code: `recipes/improve.json`) takes `repo`. A repo with its own layout adds `kitchen.repo.json` (tests, timeout, GitHub name, protected files); see BUILDING.md. Tests: `tests/Test-RepoConfig.ps1`.

## Job fit
`rank-fit.ps1` (Step `rankfit`, code: station) scores posting text against Jordan's core skills with no model: weighted keywords, penalties for a required clearance or on-site outside the home metro (kitchen.json `hunt.homeMetro`, set in the state-folder copy), gaps listed by category. The `jobscout` Spec runs it over the scout's saved openings; the report goes to the Yard state folder (`jobscout\<job>-fit.md`). Tests: `tests/Test-RankFit.ps1`.

## Ideas borrowed
Checkpoint and resume, replay-safe steps, and remembered approvals follow the same pattern as Earendil's Pi Durable (2026-10-01). Ours is PowerShell around Claude Code; theirs is a TypeScript library.
