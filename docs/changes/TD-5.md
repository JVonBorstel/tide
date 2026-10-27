# TD-5: status, the Ledger and verify-all grouped by Site

Floor TD-5 of Site TD (TD Pour 2), from `projects/tide/plans/multi-site-design-2026-10-23.md` sections 2.5 and 3 and the Floor
table. Built in the private repo (PR #126), merged into the multi-site stack and ported to tide in #11 (`docs/changes/port-132.md`).
This note was written after the port, from the code and tests on the #11 branch (review #11 F8: the port carried no TD-5 note).

## What it does

- **One reader:** `kitchen/site-registry.ps1` (`Read-SiteRegistry`, `Get-SiteList`, `Find-RegistrySite`, `Group-JobsBySite`) reads
  the `name` and `towers` of each Site in kitchen.json `sites`. An order's Site for these readers: its own `vars.site`, else its
  Tower's `kitchen.repo.json` `site`, else the registry Site that lists its Tower; none = Unassigned (listed last).
- **`kitchen.ps1 status`** groups the orders by Site. One group with no Site prints exactly what it printed before Sites.
- **The Ledger** (`kitchen/ledger.ps1`) groups its programs by Site, and one Tower that cannot be read no longer stops the Ledger.
- **`scripts/verify-all.ps1`** runs the suites Site by Site when a registry exists: each registry Tower uses its entries in the
  suite list (matched by dir), a Tower with none runs `tests\Test-*.ps1`, and entries no Site lists run last under UNASSIGNED
  (never dropped). No registry = the list and the output exactly as before. An unreadable registry is exit 2, named.
- Since review #11 (F5): a registry Tower or a suite dir written as `%USERPROFILE%\...` is expanded before it is compared.

## Proof

- `tests/Test-VerifyAll.ps1` (7 TD-5 checks: golden output with no registry, no `sites` key, an empty one; grouping; a missing
  name; a malformed registry; plus the review #11 `EnvTower` checks), `tests/Test-Ledger.ps1` (8), `tests/Test-KitchenSupervisor.ps1`
  (5, status by Site).

## L1-L4

- Person (the Owner): one status screen and one verify run say which Site is green and which is not.
- Business: none directly.
- MSP: per-client grouping of work and of test results from one Yard.
- Community: none.
