# TD-9: Site-closed windows from the Sites registry

Floor TD-9 of Site TD (TD Pour 2), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 2.4 and the Floor table.
Branch `ms-td9-site-closed`, stacked on TD-7 (`ms-td7-registry`, PR #125) at `4c2fda0`, built 2026-10-24 MT. Merges after #125.

## What it does

- **Registry windows:** `kitchen.json` `sites.<CODE>.closed`, a list of `{ "from", "to", "why" }` with the same rules as a Tower's
  `freeze` (up to 50, local time or an ISO offset, `to` after `from`, a short `why`). Read like kitchen.ps1 reads its settings: the
  repo copy, then the state-folder copy, whose `sites` replaces the other (`Read-SiteRegistry`, `kitchen/freeze-lib.ps1`).
- **Combined per Tower:** a Tower's Site is its `kitchen.repo.json` `site` (TD-2). `Get-RepoFreezeState` and the freeze view use the
  Tower's own windows plus its Site's (`Get-TowerFreezeWindows`); where two cover now, the one that ends last wins, as before.
- **Named:** a Site window's reason ends "(Site TD closed)", so the merge station's wait line, `kitchen.ps1 status` and
  `freeze.json` name the Site. The Board banner reads "Site TD closed: <tower> takes no merges until ..." (`app.js`); the server
  passes the window's `site` through (`server.mjs` `freezeView`, one line).
- **Fail closed, for that Site only:** a `kitchen.json` that will not parse, a `sites` that is not an object, or a bad window for
  the Tower's Site holds that Tower's merges (exit 10) with a message naming the file and field. Another Site's bad entry does not.
- **freeze.json** keeps both kitchen.json copies' times (`registry`) and is rebuilt at once when the registry changes.

## Unchanged

- A Tower with no `site` never reads kitchen.json: its windows are exactly its own (so a damaged kitchen.json cannot touch it).
- No `sites`, no entry for the Tower's Site, or no `closed`: only the Tower's own windows; freeze.json entries gain no `site` key.
- The Demo Project freeze (Mon 10-27 00:00 to Tue 10-28 18:00 MT, in its own `kitchen.repo.json`) is tested at every edge against each
  registry shape. The Demo Project repo is not touched.

## Not in this Floor

- `scripts/merge-pr.ps1` still reads only the base branch's `kitchen.repo.json` from GitHub; it does not read the registry.
- The `_sites` note in `kitchen/kitchen.json` does not mention `closed` yet (TD-8 and TD-10 also edit that file).

## Proof

`tests/Test-Freeze.ps1`: 71 checks, all passing (the TD-9 section is the new part). Broken three ways, each caught: registry windows ignored (21 fails), a damaged
kitchen.json read as empty (1 fail), any Site's windows applied to every Tower (2 fails).
