# The Work tab's server side (pass-app/work, upgrade lane L5)

Jordan's only job is taps. This folder serves the Work tab from the ledger's event store (`core/ledger`, lane L1): his Needs-you queue,
the streams with their WIP, the rows, and one endpoint that records a tap as a `decision.answered` event.

Status: **off**. The tab is behind the flag `board.work` (declared in `flags.json`, off by default). Turning it on is Jordan's card: a
`decision.answered` event, then a `flag.set` event. While it is off, every route below answers `404 not-found` and reads nothing else.
The Board's look (the tab itself, `pass-app/public/work/`) comes after Jordan picks one of the mock-ups (decide before you build).

## Routes (contracts in `core/contracts/api-*.schema.json`)

All of them sit behind the Board's own checks in `server.mjs`: the Host guard, the Origin check on a POST, then the pass key, the session
cookie or a Tailscale login on `pass-users.txt`. Errors are `{ ok: false, code, error }` (`apiError`).

| Route | What it answers |
|---|---|
| `GET /api/work[?page=N]` | the top line, the queue (oldest first, at most 7, plus `queueTotal`), the streams, the attention flags and one page of rows (needs-you first, then newest). Headers: `X-Rows-Total`, `X-Rows-Page`, `X-Rows-Pages`, `X-Work-Seq`. |
| `GET /api/work/:id` | one work order (`WO-312` or `J312`): its row, events, decisions and brief. `ETag` is the head sha of its open PR (`"none"` when it has none). |
| `POST /api/decide` | one tap: `{ decision, answer, note, via, requestId }`. A card whose order has an open PR also needs `If-Match: "<the ETag the phone was shown>"`. |
| `GET /api/work/stream` | server-sent events: `hello`, then `card`, `card-gone`, `row`, `top`, `event` as the store moves, and `ping` every 25 s. Each message's `id` is the store's seq; reconnecting with `Last-Event-ID` sends only what was missed (`hello.resumed` says so). |

## A tap

- **Bound to the card and the code:** the decision id names the card. When its order has an open PR, the tap must carry the head sha the
  phone was shown. No sha: `428`. A different sha (the PR moved after he looked): `412`. Nothing is written in either case. The sha goes in
  the event's `proof` (`tide#21 head <sha>`).
- **Once:** the event's store key is `decision.answered:<card>`, so two taps that race write one event. The same `requestId` again
  answers the first event with `duplicate: true` (a retry is safe); a different one answers `409 already-answered`.
- **Never queued:** a store that cannot be written answers `503 unavailable` and says the tap was not recorded.
- **Logged:** each tap is one `work-decide` line in `pass-actions.jsonl` (the card id and ok, never the note).

## Options (environment)

| Name | Default | What |
|---|---|---|
| `TIDE_DB` | `<state>\tide.db` | the event store to read and write |
| `PASS_WORK_POLL_MS` | 1000 | how often the stream looks for new events (only while a phone is connected) |
| `PASS_WORK_PAGE` | 100 | rows a page in `GET /api/work` (10-400) |

`node:sqlite` needs Node 22.5 or later, behind `--experimental-sqlite` on Node 22 (no flag on Node 24). Without it the tab answers off,
with the reason.

## Files

| File | What it does |
|---|---|
| `api.mjs` | the routes above; `isWorkPath` and `workRoute` are the server's one seam |
| `flags.mjs` | the flag runtime: `flags.json` (lane L4) plus the `flag.set` events; an unknown flag is off |

Tests: `pass-app/test-work.mjs` (`tests/Test-Work.ps1`, run by CI's Core step).
