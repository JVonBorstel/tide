# WO-UPG-L5-1: the Work tab's API and flag runtime, switched off (2026-10-26)

**What:**
- New `pass-app/work/api.mjs` serves the Work tab from the ledger's event store: `GET /api/work`, `GET /api/work/:id`,
  `POST /api/decide` and the `GET /api/work/stream` server-sent events, all to the contracts in `core/contracts/api-*.schema.json`.
- New `pass-app/work/flags.mjs` answers "is this flag on now?" from `flags.json` and the `flag.set` events.
- A tap writes exactly one `decision.answered` event. It is bound to the card and, when the card's order has an open PR, to the head sha
  the phone was shown (`If-Match`; 412 when the PR moved). A retry with the same request id is safe; a second answer is refused.
- `pass-app/server.mjs`: two lines (the L5 seam), the import and the route after the Board's own auth. Nothing else in pass-app changed.
- `core/ship/gates.json`: `tests/Test-Work.ps1` added to `coreSuites`, as that file asks ("add a lane's suite here"), so CI runs it.
- Still switched off: `board.work` stays off; `upgrade.ledger` stays `old`. No look change: the tab's screens wait for Jordan's A/B/C.

**Effects:**
- L1 (Jordan): one tap per card, and the tap is proof. A yes can no longer land on code he did not see: a PR that moved refuses it.
- L2 (business): a decision is a record with time, answer, note and the exact sha, not a chat message.
- L3 (MSP): the same auth, Host and Origin checks as every Board action; nothing new is exposed while the flag is off.
- L4 (community): public code, synthetic test data only; the event store and the private words stay on this PC.

**Proof:** `node pass-app/test-work.mjs`: 41 passed, 0 failed on Node 22.12 and on Node 24.22. With the head check, the store key and
the replay check removed, 6 tests fail (mutation run by hand).

**Not done here (cards):**
- Contract: `api-decide` has no field for the PR head and `api-work` has no paging fields, so the head travels in `If-Match`/`ETag` and
  the pages in `X-Rows-*` headers. A contract PR (L0) can add `head` and `paging` as optional fields (a 1.x minor).
- Contract: there is no `stale` error code; a moved PR answers `412` with code `bad-request` and plain words.
- Privacy: the Work tab shares through `core/ledger/share.mjs`, so a private order's card shows "a private question" even on Jordan's
  own phone. Question for Jordan: show private words to a Tailscale-login session only? Recommended: yes, in a later slice.
- A private order's events are not sent by `GET /api/work/:id` (their data is dropped, which their contract shapes do not allow).
- `report` in `GET /api/work/:id` is `null`: REPORT.md lives in the private notes folder; reading its front matter is a later slice.
- Glossary card (L4 owns `docs/GLOSSARY.md`): add **Work tab** (the Board tab with the Needs-you queue, streams and rows; `pass-app/work`)
  and **Tap** (one answer to a card, a `decision.answered` event). Collision: the City's **Replay** (floors in 14 s) is not the Work
  tab's replay timeline (the event log scrubbed by day); name the second one **Rewind** or similar.
- Cutover card: before `shadow`, the Work tab's queue must equal `node core/ledger/cli.mjs queue --json` card for card on the shadow
  store; before `new`, every open Yard approval the Ledger tab shows must appear as a card or a `no-decision` flag.
