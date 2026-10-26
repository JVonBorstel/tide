# Tide glossary

This is the one place Tide's names are defined. When something new gets a name, add it here first, in the same pull request.
New names are what Jordan (the Owner) reads. The code keeps its old names: stored values, file names, ID formats, environment variables,
event types, task names and paths stay the same (see "Code names").
Private notes about names (other projects, people) stay in the Office, never here. CI reads this file: the old-names guard
(`scripts/check-names.ps1`) and the Vale vocabulary (`.vale/`).

Theme: Tide is a construction company. Each project is a site.

## The company
| Old | New | What it is |
|---|---|---|
| Tide | **Tide** | the whole system, the company |
| Jordan | **Owner** | signs off on work |
| Claude session | **Foreman** | runs the sites day to day |
| Chef, pass-app, "pass" tab | **The Board** | the phone app: every site at a glance |
| gemini-brain | **The Office** | plans, records, memory |

## A site, biggest to smallest
| Old | New | ID |
|---|---|---|
| project | **Site** | TD = Tide itself |
| repo | **Tower** | |
| roadmap | **Blueprint** | |
| roadmap item (B-42) | **Floor** | TD-42 |
| wave (W1-W5) | **Pour** | TD Pour 2 (always with the site code) |
| order, job, ticket, dish (J207, #0207) | **Work order** | WO-0207 |
| recipe | **Spec** | |
| station (step script) | **Step** | |

## The people doing the work
| Old | New |
|---|---|
| kitchen (the engine) | **The Yard** |
| sous chef, head-chef planner | **Dispatcher** |
| cooks | **Crews**: Cloud crew, Home crew (private data, this PC only) |
| builders (session subagents) | **Subcontractors** |
| scaler | **Staffing** |
| merge train | **Handover** |

## Quality and safety
| Old | New |
|---|---|
| tests, taster | **Inspection**, the **Inspector** |
| canaries | **Spot checks** |
| breaker | **Stop-work order** |
| owns | **Permit** |
| approval hold, A-code (A104) | **Sign-off**, SO-104 |
| merge freeze | **Site closed** |
| freshen / BASE | **Resurvey** / **Benchmark** |
| tailor check | **Fit check** |

## Daily routine
| Old | New |
|---|---|
| tick | **Walkround** (every 2 min) |
| chores | **Site cleanup** |
| boot pack | **Toolbox talk** |
| PICKUP.md | **Shift handover** |
| Ledger, Watch | no change |

## Status words (the same everywhere)
Queued, Building, Inspection, Needs sign-off, Handed over, Failed, On hold.
These replace: pending, on the rail, cooking, attention, set aside, quarantined, plated, done.

| Stored | Shown |
|---|---|
| `pending` | Queued |
| `running` | Building, or Inspection while the step is `tests` / `verify` / the taster review |
| `waiting-approval`, `needs-human` | Needs sign-off |
| `done` | Handed over |
| `quarantined`, `failed` | Failed |
| `killed` | Stopped |
| `closed` | Closed out |
| any other value | the raw value |

## Other display words
- "Order" (button) is **New work order**; "Send to the pass" is **Send to the Yard**; "Private order" is **Private work order**.
- "Kitchen hands" are **Yard hands**. The shelf for failed and stopped work is **The bench**. "PC check" is **Site check**.
- A work-order number shows as **WO-0207** (four digits). Typing WO-207, WO-0207 or J207 all work.
- Scheduled tasks, when renamed with the Owner's tap: Kitchen-Supervisor becomes **Tide-Yard**, Kitchen-Chores **Tide-Cleanup**,
  Kitchen-Pass **Tide-Board**.

## Code names (still used)
| New | Code name (still used) |
|---|---|
| Step | `kitchen/stations/*.ps1` |
| Spec | `kitchen/recipes/*.json`. Recipe *names* (`improve`, `roadmap-item` ...) are stored values and stay. |
| Work order WO-0207 | stored `J207` |
| Sign-off SO-104 | stored approval `A104` |
| The Yard | `kitchen/` and the state folder `%LOCALAPPDATA%\brain-kitchen` |
| The Board | `pass-app/` and task `Kitchen-Pass` |
| Walkround | task `Kitchen-Supervisor` |
| Site cleanup | task `Kitchen-Chores` |
| Toolbox talk | `memory/BOOT.md` |
| Shift handover | `memory/PICKUP.md` |
| Stop-work order | `breaker` |
| Benchmark | `.kitchen/BASE` |
| Site closed | the `freeze` key in `kitchen.repo.json` |

## The Board's scene: a building site
The pixel scene on the Board is a building site. Only art and words changed; the sprite keys stay as code names.
| Kitchen (old) | Site (new) | What it shows | Code name (still used) |
|---|---|---|---|
| cutting board station | **Survey table** | a crew planning | station `board` |
| stove station | **Workbench** | a crew building code | station `stove` |
| tasting counter | **Inspection desk** | a crew reviewing | station `taste` |
| sink station | **Test rig** | a crew testing | station `sink` |
| plating counter | **Handover bay** | a crew handing over | station `plate` |
| chef in a toque | **Crew member** in a **hard hat in the crew's own colour** | a running work order | sprites `chef-*` |
| waiter carrying a cloche | **Runner** carrying a clipboard | a work order waiting for sign-off | sprites `waiter-*`, `cloche` |
| ticket rail, tickets | **Job board**, **Work-order cards** | queued and running work orders | sprites `rail`, `ticket` |
| the pass, heat lamp | **Sign-off window**, its light | where sign-offs wait | sprites `pass`, `pass-glow` |
| heat lamps over plates | **Sign-off lights** (warm, amber at 1 h, red at 4 h) | how long a sign-off has waited | sprite `heat` |
| door sign OPEN / CLOSED | **Gate sign** OPEN / **PAUSED**, never CLOSED | the Yard paused or not | sprite `sign` |
| wall clock | **Site clock** | stops when the walkrounds stop | sprite `clock` |
| sous chef on a stool | the **Dispatcher** | walkrounds are running | sprites `stool`, `chef-sit` |
| fuse box | **Power board** (STOP tag when tripped) | a stop-work order | sprite `fuse` |
| coin jar | **Budget meter** | today's spend against the cap | sprites `coin-jar`, `jar-lock` |
| set-aside shelf with plates | **The bench** with parked crates | failed or stopped work orders | sprites `aside-shelf`, `plate-aside` |
| chalkboard specials | **Whiteboard** | new leads | sprites `chalk`, `tally` |
| recipe-card box | **Idea box** | new ideas | sprite `recipes` |
| toques on hooks | **Hard hats on hooks** | crews resting or off | sprites `hooks`, `hat` |
| "ORDER UP!" | **HANDED OVER** | a work order handed over | sprite `banner` |

## The City (the Board's home)
| New | What it is | Code name |
|---|---|---|
| **City** | every Site at a glance: towers, lots, the Office and the Yard lot under the real sky | `#/city`, `public/city.js` |
| **Tower** (in the City) | a project with a GitHub home or merged work: one skyscraper | `towers.mjs`, `kind: 'tower'` |
| **Floor** | in the City, each merged PR (or each Yard merge with no PR) is one floor | `floors` |
| **Lot** | a repo with commits but no merged PR yet | `kind: 'lot'` |
| **The Office** (building) | the plans-and-memory folder, a low site office at the edge of the City | `kind: 'office'` |
| **Yard lot** | the workshop by the gate for work orders with no Tower: counts only, a lock for private ones | `#/city/yard` |
| **Stone base** | the commits under a tower from before its records began | `plinth` |
| **"Public from" line** | the dashed line on Tide above its earlier floors: the public repo's first merged PR | `publicFrom` |
| **Crane** | one open PR on a Tower; its tag is the CI colour | `open` |
| **Beacon** | the light on a roof: a work order on that Tower waiting for sign-off | `beacon` |
| **Act sheet** | long-press anything (or tap Act) for the actions the Board already has | `city-nav.js` |
| **Horizon strip** | the 40 px skyline under the header on every other tab | `.city-strip` |
| **Replay** | the week's floors going up in 14 s | `replay` |
| **Watch mode** | the full-screen night City for an idle screen | `#/city?watch` |

## The ship path (upgrade lane L4)
How finished work lands on main. Code: `core/ship/`, `flags.json`, `scripts/check-*.mjs`, the `gates` job in `.github/workflows/ci.yml`.
| New | What it is | Code name |
|---|---|---|
| **Flag** | a switch for one slice of work: declared in `flags.json`, off by default; the Owner's yes turns it on | `flags.json`, `core/ship/flags.mjs` |
| **Handover queue** | lands one PR at a time: tests it merged onto the latest main, then moves main forward to that tested commit. Never forced | `core/ship/queue.mjs` (merge queue) |
| **Resurvey** (of a PR) | brings a held PR up to date: merges main in, pushes normally, marks it for re-review when main changed the PR's own files | `core/ship/freshen-pr.mjs` (freshen-pr) |
| **Docs step** | after a merge: checks the change note, the glossary and the names, and rebuilds MAP.md on main | `core/ship/docs.mjs` (docs station) |
| **Change note** | `docs/changes/<work order>.md`: what changed and its effect on the person, the business, the MSP and the community | `docs/changes/` |
| **Gate** | one CI check on a PR. **Report only** writes its verdict on the summary page and never blocks; **enforce** blocks | `GATE_*` lines in `ci.yml` |
| **Decision gate** | the gate for the Board's look: a PR that changes it names the Owner's answered decision (D-7) | `scripts/check-decision-gate.mjs` |
| **Generated file** | a file a tool writes (MAP.md). A PR never changes it; the Docs step does after the merge | `core/ship/gates.json` `generated` |

## Collision list (same word, different thing)
- "Spec" (recipe) is not `specs/B-##.md`.
- `W-TOOL-07`, `W1-E2`, `A-1001`, `C-##` are not Pours or Sign-offs. `D-7` is a decision (a card for the Owner), not a Sign-off.
- `%LOCALAPPDATA%\brain-kitchen\board.html` keeps its kitchen words. It is not The Board.
- "Handover" (the merge train) and the **Handover queue** are the same idea; the queue is its new code. **Handed over** is the status word.
- Always write a Pour with its site code (TD Pour 2).

## History rule (proposed; waits on the Owner's yes)
Logs keep their old words. Old words inside logs, audits, archives and change notes are history, not mistakes.

## Still to name
- The MCP channel, also called "pass".
- The pass key.
- The "lead" desk.
- tide-pulse.
- just watch.
