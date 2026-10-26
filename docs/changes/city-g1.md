# City G1: the City's data from the Yard's own records (2026-10-26)

**What:**
- New `pass-app/towers.mjs` and `GET /api/towers`: one row per repo on this PC (a Tower, a Lot or the Office), with its floors (merged
  work), cranes (open PRs) and stone base. This is slice G1 of the City ("God mode") design; the phone does not draw it yet (G4).
  - Floors come from `merges.jsonl` (session merges, with the Pour from "batch-run integrate-<name>") and `results\J*.merge.json`
    (work orders, `by: 'yard'` or `'auto'`, `undone` after a take-down). One floor per merge commit: the same PR in both is one floor.
  - Cranes come from active work orders with a `J*.pr.json` and no merge yet, with their CI colour from `J*.ci.json` (an error look is
    unknown, `null`).
  - git (off the main thread, every 10 min): commit counts, the last commit, the stone base (first-parent commits before the first
    floor). Before the first read nothing is guessed: no stone base is sent.
  - Lots (commits, no floors), the Office (gemini-brain by default), the Blueprint outline numbers from `ledger.json`.
  - Tide's older history (Jordan's own Board only): the state-folder `kitchen.json` `city.history` names the old repo and branch; its
    floors carry `past: true`, `publicFrom` is the public repo's first merged PR, and the stone base is that branch's first-parent
    commits. The repo holds no private name: the list of repos and their shown names come from the state folder only.
- `server.mjs` (named lines): the import; one `makeTowers(...)` line after `repoOf`; `tower` on each work order view (`jobView`);
  `towersV` in the state's top fields; the `/api/towers` route.

**Why:** the City draws every project as a skyscraper and every merged PR as a floor. The phone needs that data from real records only
(the CREED truth rule): a missing field draws nothing.

**States:**
- Loading: before the first git read `gitAt` is `null` and no counts or stone bases are sent (unknown, never 0).
- Empty: no state `kitchen.json` (or no `bootRepos`) shows this repo alone; a repo with no merged work is a lot.
- Error: an unreadable state `kitchen.json` and a `bootRepos` folder that is not on this PC are named in `errors[]` (folder name only);
  git failing leaves the counts out; anything that throws gives `{ ok: false, error }`, never a crash.
- Privacy: no folder path from this PC is sent; a floor or crane of a private work order carries no title.

**Tests:**
- `pass-app/test-city.mjs` (new, run by `tests/Test-PassApp.ps1` like `test-scene.mjs`): 29/0, one check per acceptance line (fake git,
  throwaway state folders).
- `tests/Test-PassApp.ps1`: a new City block (the node checks, the route needs the key, its shape, no local paths, `towersV` equals the
  route's `v` and moves on a merge, `jobView.tower`). Counts in the PR.

**L1-L4:** person: none yet (nothing is drawn until G4); the data is ready and private. Business: none. MSP: none. Community: none (the
public repo gains a generic, read-only data module with no personal values).
