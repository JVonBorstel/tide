# Shared contracts of the Tide upgrade

The shapes every new piece of the upgrade agrees on, so the lanes (ledger, engine, crews, ship, Board, continuity) can be built at the
same time without touching each other's files. Each contract is a JSON Schema (draft 2020-12) with valid and invalid example files.
Code against these files only. If a contract is missing something, ask for a change to it in its own PR; never work around it.

## The contracts

| Contract | File | What it is |
|---|---|---|
| event | `event.schema.json` | One line of the append-only record: `{seq, at, actor, kind, wo, data, proof}`. 17 fixed kinds, each with its own `data` shape; `x.<source>.<name>` is an open namespace for kinds no lane depends on yet (for example `x.hook.stop`). |
| row | `row.schema.json` | One work order in the ledger view: stage, state, owner, what it waits on, what happens next, ages, the definition-of-done checklist, proof. |
| decision | `decision.schema.json` | One card for Jordan: the question, the options with the recommended one first, his answer, when and how (`board` or `/decide`). A `choose` card carries one mock-up per option. |
| brief | `brief.schema.json` | The front matter of a work order's `BRIEF.md`. |
| report | `report.schema.json` | The front matter of a work order's `REPORT.md`. |
| activity | `activity.schema.json` | The engine asks one step to run: `{wo, name, args, idempotencyKey, timeoutSec, maxMB}`. The same object works for any engine. |
| activity-result | `activity-result.schema.json` | What the step hands back: `{ok, exit, out, proof}`. Exit 124 = time limit, 125 = memory cap (`scripts/run-bounded.ps1`). |
| api-work | `api-work.schema.json` | `GET /api/work`: the top line, the Needs-you queue (oldest first), streams, rows, flags. |
| api-work-item | `api-work-item.schema.json` | `GET /api/work/:id`: one row with its events, decisions, brief path and last report. |
| api-decide | `api-decide.schema.json` | `POST /api/decide` body: one tap. The key goes in a header, never in the body or the URL. `requestId` makes a retry safe. |
| api-decide-result | `api-decide-result.schema.json` | Its answer: the `decision.answered` event written, or an error code. |
| api-work-stream | `api-work-stream.schema.json` | `GET /api/work/stream`: one server-sent message (`id: <seq>`, `event: <type>`, `data: <json>`); reconnect with `Last-Event-ID`. |
| upgrade | `upgrade.schema.json` | The `upgrade` block of `kitchen/kitchen.json`: one switch per new piece, `old`, `shadow` or `new`. |

`common.schema.json` holds the shared pieces (ids, times, actors, stages, states, the checklist, the API error shape).

Rules JSON Schema cannot say are checked in `validate.mjs`. A card's recommended answer and its answer are among its options. A `choose`
card has exactly one mock-up per option. The queue in `/api/work` holds open cards only, oldest first.

## Use it

```
node core/contracts/validate.mjs                               # every fixture: valid ones pass, invalid ones fail for their named reason
node core/contracts/validate.mjs --schema event my-event.json  # check files (.md files: the front matter, for brief and report)
node core/contracts/validate.mjs --list                        # the contract names
```

Exit codes: 0 = fine, 1 = invalid, 2 = a usage error, an unreadable file or a broken schema.

From code (Node 18 or later; no packages):

```js
import { validate } from '../contracts/validate.mjs';
const r = validate('event', obj);   // { ok, errors: ['/data/stage: enum: must be one of ...'] }
import { parseFrontMatter, formatFrontMatter } from '../contracts/frontmatter.mjs';   // BRIEF.md and REPORT.md
import { switchOf } from '../contracts/upgrade.mjs';   // switchOf(kitchenJson, 'engine.adopted') -> 'old' | 'shadow' | 'new'
```

- **The validator.** `jsonschema.mjs` checks the JSON Schema keywords these contracts use, and refuses any other keyword instead of skipping it.
- **Upgrade switches.** `switchOf` reads a missing block, a missing piece or an unknown value as `old`, which is the safe fallback. The list of pieces comes from `upgrade.schema.json`.

## Front matter (BRIEF.md and REPORT.md)

- The block sits between two `---` lines, with one `key: value` per line.
- A ` # note` at the end of a line is a comment; `plans/x.md#g4` is not, because there is no space before the `#`.
- `tests: Contracts 52/0; RepoConfig 142/0` is read as counts per suite; `none` means no runs.
- `dod: change-note yes | tests yes | glossary n/a` may also use the marks of the build-way template (check, dash, cross).
- `depth: BRAIN_AGENT_DEPTH=1` is read as `1`.
- `formatFrontMatter` writes the same format back.

## Fixtures

- **Valid examples:** `fixtures/<contract>/valid/*.json` (and `*.md` for brief and report).
  - There is one event per kind (17), one decision per kind (8) and one row per stage (8).
- **Invalid examples:** `fixtures/<contract>/invalid/*.json` are `{ "why", "expect", "doc" }`.
  - `doc` must be rejected, with an error that contains `expect`.
- All data is invented: `WO-2001`, `example#41`, `example-owner/example-repo`, dates in 2030. Never put a real person, path, address or
  host name here: the suite fails on user folders, real-looking emails, tailnet names and private IPs.

## Changing a contract

- Change a contract in its own PR, with a fixture for the new shape and an invalid fixture for what it refuses.
- Adding an optional field is safe. Renaming or removing a field, or adding a required one, breaks the lanes that read it. Name them in the PR.
- A new event kind goes into the 17 only when a lane depends on it; until then it uses `x.<source>.<name>`.
- Tests: `tests/Test-Contracts.ps1` (`tests/core/contracts/test-contracts.mjs`). CI runs both in the `checks` job.
