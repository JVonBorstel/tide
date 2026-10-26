# TD-3: every new work order knows its Site

Floor TD-3 of Site TD (TD Pour 1), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 2.1 and the Floor table.
Branch `ms-td3-order-site`, stacked on TD-2 (`ms-td2-repo-site`, PR #120) at `37c37b0`, built 2026-10-24 MT.
Merges after #118 and #120.

## What it does

- **At add** (`kitchen/kitchen.ps1`, `Set-NewJobSite`): the order's Tower (its `vars.repo`, else a step's `Repo`) is asked for its
  `kitchen.repo.json` `"site"` (read from the main checkout, TD-2). A Site found becomes `vars.site`. The Tower's Site wins over a
  `site` passed with the order.
- **No Tower, or a Tower with no `site` key:** the order is saved exactly as before TD-3. No `vars.site` is added, no `vars` is
  created, nothing is logged, and the index entry has no `si`. An order with no Tower keeps a `site` it was given.
- **A Tower whose `kitchen.repo.json` will not load:** the add is not refused. The order is added Unassigned and
  `job.site.unread` is logged with the reason (the merge station holds that Tower anyway).
- **`jobs-index.json`** (`kitchen/jobs-lib.ps1`): an entry gains `si` only when the order stores a known Site code. An entry
  with an `si` that is not a known code counts as damage and the index is rebuilt from the files, like any other bad entry.
- **Old orders:** never rewritten. `Get-KitchenJobSite` returns the stored Site, or for an order from before TD-3 derives it from
  its Tower when read (once per Tower per process). `''` = Unassigned. Archive lines written from now on carry `site`; older lines
  fall back to their `repo` the same way.
- **`kitchen/cook.ps1`:** `site` is an order option (a known code, refused otherwise). A requeue passes an order's stored vars back
  to cook.ps1, so without this every requeue of a Site-tagged order would have failed with "recipe has no 'site'".

Nothing shows the Site yet: the Board (TD-4) and status and ledger (TD-5) read `si` and `Get-KitchenJobSite`.

## Proof

- `tests/Test-JobSite.ps1`, 19 checks: add for a Tower with a Site, a Tower named only by a step, Tower beats a passed site,
  **no site key = saved exactly as before** (same keys, same vars, index entry exactly `s,t,n,p,c`, no `si` anywhere, no event),
  broken config (added, logged), old order fallback with its file byte for byte unchanged, archive lines, index round trip and
  damage, cook.ps1's `site` option.
- Same spec through the TD-2 `kitchen.ps1` (`37c37b0`) and this one, for a Tower with no `site` key (with vars and without):
  job file, index and events identical (keys compared sorted; hashtable order is random per process).
- Broke the code 4 ways, each caught by Test-JobSite: no site at add (4 checks fail), `si` always written (4), no read-time
  fallback (2), a Site invented for a Tower with no key (4).
