# WO-UPG-L1-2: the ledger's missing importers (ideas, links, drops, roadmaps, the lobe) (2026-10-26)

**What:**
- `core/ledger/import-ideas.mjs`: `ideas.json`, manual proof links (`ledger-links.json`) and Jordan's drops in Chef (`pass-actions.jsonl`), read only.
- `core/ledger/import-roadmap.mjs`: the roadmaps of repos that opt in (`kitchen.repo.json` `roadmap`), and the lobe's `flags.json`
  (decisions ready, post-mortems due). The Yard's own repos are found from its orders (`vars.repo`), as `kitchen/ledger.ps1` does.
- `core/ledger/legacy.mjs`: the old ledger's items rebuilt from the events with its own rules (idea chains, claimed, dropped by Jordan or
  not, roadmap states and programs, drift, the lobe's flags with each post-mortem's proof). `ledger.next.json` now carries them, with the
  old counts' meaning; rows the old file never had come after them and are counted under `work`.
- `import-yard` also keeps each order's name, its roadmap item and repo, and `merge.undone`; `import-local` also reads the change notes on
  main and idea/roadmap ids named on main; `parity` compares ideas and roadmap items item for item.
- Fix: a PR that names no work order and matches no branch rule was its own stream (`PR-TIDE`); it is now `OTHER`, which is not a build
  stream for the WIP limit.
- Still switched off: `upgrade.ledger` stays `old`; `kitchen/ledger.ps1` is untouched.

**Measured on this PC (2026-10-26, a scratch copy of the state folder):**
- No GitHub: parity 312 old items, **312 same**, 0 explained, 0 unexplained. `ledger.next.json` against the old `ledger.json`: counts equal,
  flags equal (199), drift equal (109), programs equal; every item's title, state, owner, why and proof equal. Only `since` differs in
  format (ISO time vs PowerShell's local date text).
- With a read-only GitHub read: 307 same, 5 explained (merge proof from GitHub the old ledger does not read), 0 unexplained.

**L1-L4:**
- Person: none yet (switched off). When it serves, the Board's Ledger tab keeps every idea, roadmap item and post-mortem it shows today.
- Business: none. MSP: none.
- Community: the old ledger's rules now live in plain, tested Node next to the new event store.

**Tests:** `tests/core/ledger/test-ledger.mjs`: 150/0 (with the #31 review fixes merged in) (26 new, named `l2: ...`; ideas, roadmap and lobe snapshots are observations, so A -> B -> A is kept).
