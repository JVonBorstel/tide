# Build 2: Proof Card and Phone Diff (Tide ideas-chef SHORTLIST items 4 and 5; Chef 2.10.0)

Jordan approves merges from his phone. Before, a merge gate showed counts and a raw diff from the worktree's DIFF.patch (a file AI code
can rewrite), wrapped badly at 375 px. A plated order showed only "Plated at 21:40 · $1.25".
- **Proof Card** (plated orders): tests passed / failed / not run, the final line, flaky suites, who said SHIP (the taster verdict and
  its cook), the landed diff's sha and where it merged, cost and minutes. Every field comes from the kitchen's own records; a missing
  record says "unknown", never a guess. The Undo button stays where it was.
- **Phone Diff** (merge gates, the ticket and the Approve box): the file list from git with +/- bars, protected files in ember, and a tap
  opens that file's lines, wrapped, with line numbers. The yes carries the sha of the list Jordan saw; the server still measures the
  diff fresh and refuses a changed one. If the change moves while he reads, the file says so. Private orders: file names only.
- git still runs only on the worker thread (W4's `run`), never on the main loop. `measureChange` and the new endpoint share `gateDiff`.

Files: `pass-app/server.mjs`, `pass-app/public/app.js`, `pass-app/public/app.css`, `pass-app/README.md`, `tests/Test-PassApp.ps1`.

## Effect
- L1 (person): Jordan reads the actual change, file by file, on his phone before his yes, and sees the proof behind each merge.
- L2 (business): every plated order carries its receipt for the Demo Project demo ("proof or unknown" made visible).
- L3 (MSP): a private order's code never reaches the phone, even on its ticket.
- L4 (community): no diff library; a plain renderer that writes only with `textContent`.

## Not done
- The plated list rows do not show the card; it is on the ticket (`#/job/<id>`). A per-row card would read run logs on the live loop.
- The landed diff sha is of `git diff before after` on main. That is not always the sha Jordan approved at the gate (main can move
  between the yes and the merge). The kitchen does not store the approved sha, so that one is not shown.
