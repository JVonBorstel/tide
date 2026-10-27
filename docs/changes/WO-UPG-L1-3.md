# WO-UPG-L1-3: everything the ledger shares is redacted; needs-you first, then newest; pages, never a silent cut (2026-10-26)

**What:**
- `core/ledger/share.mjs` now guards every output written for readers: `work.json`, `ledger.next.json` and its pages, and every `--json`
  answer of `cli.mjs` (`build`, `show`, `queue`, `streams`, `flags`, `parity`).
  - Free text (goals, titles, why, proof, notes, flag sentences) loses this PC's paths, email addresses, private host names (tailnet,
    `.local`, `.lan`, `.internal`) and private addresses (10/8, 172.16/12, 192.168/16, 100.64/10). It also loses the private words in
    `<state>\ledger-private-words.json`: a JSON list of private repo names and job-hunt companies, kept only in the state folder.
    Each value becomes a fixed marker (`<local path>`, `<email>`, `<private host>`, `<private>`).
  - A private order shows only "a private work order". The Yard marks one with `vars.private` yes/true or a step run with `-Private`.
    The ledger used to miss `yes`, which is the Yard's own word. Its repo names count as private words.
  - `show --json` drops `x.*` event data (`publicEvent`). `tide.db` keeps the raw facts; it never leaves the PC.
- Order: `work.json` rows and `ledger.next.json` items list what waits on Jordan first, then newest first. A reader that shows only the
  first N (the Board shows 400) no longer sees only the oldest N.
- Pages: `ledger.next.json` is page 1 (400 items), with `paging: { page, pages, pageSize, itemsTotal }`; `ledger.next.page-<n>.json`
  holds the rest.
- Still switched off: `upgrade.ledger` stays `old`; `kitchen/ledger.ps1` is untouched.

**Measured on this PC (2026-10-26, a scratch copy of the state folder, no GitHub):** 16 private orders found (0 before this fix); 434
items in 2 pages; page 1 starts with the order waiting on Jordan. No user path in `ledger.next.json`. Parity against
`kitchen/ledger.ps1`: 312 same, 0 explained, 0 unexplained.

**Not done here:** the Board's own display of the pages and the needs-you section is lane L5's. A ledger built before this change keeps
its `wo.created` events without the private mark: build a fresh shadow store.

**L1-L4:**
- Person: when the ledger serves, nothing private is shown off this PC through it, and the first screen is what needs Jordan.
- Business: none. MSP: none.
- Community: a reusable redaction step for event-sourced work data.

**Tests:** `tests/core/ledger/test-ledger.mjs`: 170/0 (14 new, named `l3: ...`).
