# City G2: the City reads GitHub (2026-10-26)

**What:**
- `pass-app/towers.mjs` reads GitHub with `gh`, read-only, every 5 minutes, off the main thread (the server's runner), 15 s per call:
  - every merged PR of each Tower (in full once, then only those merged since a day before the newest kept): a floor with its title,
    merge commit and, from a `kitchen/J123` branch, its work order. A PR also in `merges.jsonl` or a work order's merge record stays one
    floor, credited to the strongest record (auto, then the Yard, then a session, then GitHub alone).
  - every open PR with its checks: a crane for each, hand PRs and Dependabot's included. CI: any failed check is red, anything unfinished
    is pending, all passed is green, no checks is unknown (`null`, no tag).
  - an old history repo (`city.history`, Jordan's own Board): merged PRs only, once a day, under the "public from" line.
- The last good read is kept in `<state>\towers-github.json`. A failed read sets `githubError` in plain words (not signed in, not
  installed, rate limit, over 15 s, not on GitHub; never gh's raw output), keeps `githubAt` at the last good read, and drops no floor
  and invents no crane. A restart starts from that file.
- `githubAt` is also a state field (`server.mjs`, one line beside `towersV`), so the phone's "GitHub read N min ago" sign stays true
  without fetching `/api/towers` again. `towersV` leaves out `gitAt` and `githubAt`: a read that found nothing new costs the phone nothing.
- Privacy: a floor or crane of a private work order carries no title, and neither does one whose work order file cannot be found
  (unknown counts as private).
- Config keys (`city.names`, `city.history`) are found by Tower key, else GitHub name, else folder name, so they keep working when a
  repo gains a Site code.
- `PASS_GH` (a `.mjs` runs under node: the tests' fake), `PASS_GITHUB_MS`, `PASS_GITHUB=off`.

**Measured on this PC (2026-10-26, real `gh`, a copy of the state folder, read-only):**
- first read (2 Towers + the old history repo: 5 lists): 4,833 ms; GraphQL points left 4,981 of 5,000.
- the next read (incremental; the old repo skipped: 4 lists): 3,872 ms; 4,978 left. At one read every 5 minutes that is about 48 lists an
  hour, far under GitHub's 5,000-point hour.
- the answer: 34 KB of JSON with every title (5 buildings, 162 floors, 6 cranes).

**Tests:**
- `pass-app/test-city.mjs`: 45/0 (16 new: merged floors and who made them, cranes and CI, the old history repo, full then incremental,
  a read that found nothing keeps `towersV`, read time and points left, a failure keeps the last good read, the cache after a restart,
  off, the rollup rules, the targets, plain error words, private titles, config by GitHub name).
- `tests/Test-PassApp.ps1`: a fake `gh` (node, an answers file) for this suite's server; W4's servers run with `PASS_GITHUB=off`.
  3 new route checks (a GitHub floor and crane, the cache file, a failure). Counts in the PR.

**L1-L4:** person: none yet (drawn in G4); the City will count every PR, not only the Yard's (brain-monitor had 116 merged on GitHub
against 77 in the Board's records). Business: none. MSP: none. Community: none.
