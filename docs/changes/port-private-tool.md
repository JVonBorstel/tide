# Port tool: one script moves a private PR to tide

Cut-over plan step 1a (Team PORT), 2026-10-26. Branch `port-tool`, built on tide main `8af1796`.
Files: `scripts/port-private.ps1` (new), `tests/Test-PortPrivate.ps1` (new), `tests/fixtures/fake-port-clean.ps1` and `fake-port-scan.ps1` (new), `tests/fixtures/fake-gh.ps1` (+6 lines), this note.

## In plain words

The old private repo is on a GitHub billing hold, so its open pull requests can't merge there. They have to move to tide. Before, that meant a hand copy each time. Now one command does it, with the same cleaning and the same privacy check every time:

```
pwsh -File scripts/port-private.ps1 -Pr 133
```

It opens a tide PR whose body links the private PR. The private PR stays open. If something private would reach tide, it stops and says what and where, and nothing is pushed. It never prints the private value itself.

## What it does

1. **Reads the private PR** with gh: its branch, head commit, title and description. It fetches that branch from the `private` remote and refuses if the branch is not at the commit the PR names.
2. **Cleans two trees.** The merge-base M of the branch with `private-main` (the old private main, `d37031d`), and the branch head B. Both go through the public cleaning: rules R1-R10 plus the cleaning patch. R10 is new (2026-10-26, found by porting #132): a user path on a whole-line code comment, which is only an example, becomes `%USERPROFILE%`. Code lines still stop at R4. That cleaning has ONE implementation, `public-tide-clean.ps1`, in the brain's `projects/tide/audits` folder. It sits outside this repo because its rules name the private values. `public-tide-refresh.ps1` now calls it too, and it takes `-Ref` (any commit), not only `main`.
3. **Diffs cleaned(M) to cleaned(B)** and applies that patch with `git apply -3` on a new branch `port/<branch>` from tide `main`, in its own worktree `wt/port-<branch>`. Only the branch's own changes move, so commits made on tide since the cut-over are never reverted. Replacing the whole tree would revert them.
   - On a conflict it stops and keeps the worktree. You fix the files and `git add` them, then run again with `-Continue`.
   - `-NoCommit` stops after the apply on purpose, for a hand fix. `-Note <text>` says what was done by hand, and it goes into the PR body, the commit message and the change note.
4. **Scans** (`public-tide-scan.ps1 -Json`) every changed file, the commit message and the PR text. The same files on tide `main` are scanned too, as the baseline.
   - Any live hit refuses: a value read from this PC (`LIVE:*`), the owner's full name, or the interview project's name (`project-name`, new in the scan).
   - Any other class that is new in a changed file refuses, unless `-Allow <class>` says a person read it.
   - A hit only in the private PR's title or description leaves that text out of tide. The PR then gets a neutral title, `Port of private PR #N`.
5. **Writes a change note** `docs/changes/port-<N>.md` (the cleaned description, how it was ported, L1-L4). It commits with the owner's name (`-AuthorName`, else `git config user.name`; the name is never written into a file) and the noreply email `204934145+JVonBorstel@users.noreply.github.com`, and the message names the private PR and its full head commit.
6. **Pushes the branch** (never forced) and opens the tide PR, or reuses the open one. `-Comment` also puts the tide link on the private PR. Each port is one line in `ports.jsonl` in the kitchen state folder.

**Other refusals:**

- **A cleaning-patch hunk that applied on M but not on B.** The diff would undo that cleaning, so it refuses and names the files. `-AcceptRejects -NoCommit` applies the port and stops before the commit. A person restores the cleaning by hand, then `-Continue` scans and commits. The PR names those files. The first real case was private #132: its loop rewrite in `scripts/verify-all.ps1` undid the `ExpandEnvironmentVariables` cleaning.
- **A cleaning that needs a hand fix (R4).**
- **A closed private PR.**
- **A branch that changes nothing once cleaned.**
- **A branch or worktree that already exists.**

A scan or cleaning that fails exits 2. Nothing is ported unscanned.

**Never destroys:** no force-push, no deleted branch, worktree or PR. The only things it removes are its own temp stage folders. The state for `-Continue` is `<git dir>/port-private/pr-<N>.json`, outside every tree.

Exit: 0 PR opened or reused (or committed, with `-NoPush`); 1 refused; 2 bad input or a tool failed.

## Proof that the factored cleaning is the same cleaning

`public-tide-clean.ps1 -Ref d37031d` was run into a stage folder and read into git with a temp index. Its tree is `9286ecbf15ffa5877d8ee05e6b1bdd98ff4b6973`, the same tree as tide's first commit `8a56fad` (`git rev-parse 8a56fad^{tree}`). The cut-over published exactly this cleaning.

## Tests

`tests/Test-PortPrivate.ps1`: 40 checks, all passed locally.

- It uses two local bare repos (private and tide) over git's `ext::` transport, the fake gh (now with a per-PR bare repo, title, body and `pr comment`), and a fake cleaning and scan with the same contract. The real ones read this PC's private values. No network.
- The cases: a full port (the cleaned change, an add and a delete, tide-only commits kept, no private word, noreply author and committer, the commit message, the PR title and body, the change note, the private-PR comment, `ports.jsonl`); a second run refused and `-Continue` reusing the PR; a live value refused and never printed; a conflict refused with the worktree kept, then fixed and `-Continue`; a private title or description left out; a hand fix; a cleaning-patch reject, refused and then `-AcceptRejects -NoCommit`, a hand fix, `-Continue -NoPush` and `-Continue`; `-Note` in the PR body, the commit and the change note; a non-live class refused, then `-Allow`; `-Allow` never passing a live hit; nothing to port; a closed PR; a failed scan; a missing cleaning script; no tide branch moved.
- `tests/Test-PrFlow.ps1` with the changed fake gh: 83 passed, 0 failed.

**The tests can fail.** Each change below was put into port-private.ps1, the suite run, and the file restored:

| Change | Result |
|---|---|
| the whole cleaned tree replaces tide's (read-tree instead of `apply -3`) | 4 of 37 failed (tide-only commit reverted; no conflict seen) |
| a live hit in a changed file not refused | 4 of 37 failed |
| no noreply email on the commit | 1 of 37 failed |
| cleaning-patch rejects ignored | 2 of 37 failed |

(The mutation runs were before the change-note checks were added, at 37 checks.)

## L1-L4

- **Person:** Jordan's private work reaches the public home without a hand copy. A private value can't slip through, because the scan stops it and names where.
- **Business:** the open private PRs (#133, #103, #132) can merge again, on tide with free CI.
- **MSP:** one repeatable, logged path from private to public. It is the same for 1 PR or 50, and every port is a line in `ports.jsonl`.
- **Community:** the public repo gets the work, cleaned, with a link back to its review history.

## Unknown or not verified

- **The real gh on the private repo during the billing hold.** `gh pr view` was checked live (#133, #103, #132). `gh pr comment` there was not run by the test, only by the ports themselves.
- **Linux.** The tool was run on Windows only. The real cleaning and scan are Windows-only (they read this PC).
