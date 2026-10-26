# freshen-guard: orders built on the old history stop plainly, and a tool re-cooks them

Team ORDERS, step 2 of the cut-over plan (gemini-brain `projects/tide/plans/cutover-build-plan-2026-10-26.md`). Branch `freshen-guard`,
built 2026-10-26 on tide main `8af1796`. The audit behind it: gemini-brain `projects/tide/audits/orders-after-cutover-2026-10-26.md`.

## In plain words

On 2026-10-26 the Yard's code moved from the private repo brain-monitor to the public repo tide, with a fresh history. The live checkout
now tracks tide. Orders queued before that were built on the old private history, and no merge can bring them up to date.

- **The Resurvey Step (code: `freshen`) now stops in one plain line** when the order's branch and main share no history. It says what
  happened (the cut-over), that nothing changed, and the way out. It holds for you (exit 10, like the other holds) instead of failing
  late with git's "refusing to merge unrelated histories" and being retried until it is set aside.
- **The pull-request Step (code: `pr`) never pushes such a branch.** Before this change it would have pushed the whole old private
  history to the public tide (the test below proves it did). It holds the same way: nothing pushed, no pull request.
- **A new tool, `scripts/rebase-orders.ps1`, puts chosen orders back in the queue to start fresh from tide main.** It is a dry run
  unless `-Apply` is given, and `-Apply` runs only while the Yard is paused. It deletes nothing: the old branch gets a `pre-tide/` label,
  the old folder is moved where the doctor does not remove it, and the job file is copied first.

## What it does

**`kitchen/history-lib.ps1` (new, functions only).**
- `Get-HistoryRelation <dir> <a> <b>` says `shared`, `unrelated` (git found no merge base: exit 1, no output) or `unknown` (git
  could not tell, for example a missing commit). Only `unrelated` stops a Step.
- `Get-UnrelatedHistoryHold` is the one hold line both Steps print. The supervisor shows the last line of a hold as its reason, so it
  is one line. It names the re-cook tool for this order, the `pre-tide/kitchen/<id>` label and the port tool (`scripts/port-private.ps1`,
  Team PORT).

**`kitchen/stations/freshen.ps1`.** After the checks that main is clean and checked out, and before `BASE.next` is written: an unrelated
main prints the hold and exits 10. HEAD, `.kitchen\BASE` and `DIFF.patch` are untouched, so the memory note
`kitchen-worktree-hands-off` (freshen moves BASE and DIFF.patch together) still holds. The exit codes stay the Step's: 0 done,
1 failed, 2 no job or worktree, 10 held for Jordan, 11 wait.

**`kitchen/stations/pr.ps1` (outside the ORDERS lane, minimal, named here).** The same check runs right after the branch tip is found,
before any GitHub call. Reason: the freshen guard alone does not protect the public repo. In the improve recipe, freshen (step 6)
runs before tests, repair, mutate and review, and pr (step 11) pushes after them. So the 20 pending brain-monitor orders already past freshen (25 with the
set-aside ones) would reach pr without passing freshen again, and pr would push their private history to tide.
A private order is skipped earlier, as before (it never pushes).

**`scripts/rebase-orders.ps1` (new).** It works out the affected orders itself, from the jobs folder and git, not from a hand list:
live orders of the repo whose branch shares no history with main, or with no branch yet and created before main's first commit.
You choose which to re-cook with `-Ids`. Each chosen order gets these steps:

1. A copy of `jobs\<id>.json` goes to `<kitchen>\pre-tide\jobs\`. A second run never overwrites it. This is outside `backups\`, which the
   doctor prunes after 14 days.
2. The branch gets the label `pre-tide/kitchen/<id>`.
3. `worktrees\<id>` moves to `worktrees\pre-tide-<id>` (`git worktree move`). After the Yard resumes, the doctor removes the folders of
   closed and killed orders by their `J<n>` name.
4. `kitchen/cook.ps1` runs with the order's recipe and vars. These are the commands `kitchen.ps1 requeue` uses when it re-cooks. Requeue
   itself re-cooks only orders before their commit step and resumes the rest on their old branch, which cannot work here. If the cook
   fails, the folder moves back and the tool stops.
5. `kitchen.ps1 kill` (only if the order is pending or waiting on you), then `kitchen.ps1 close -ReplacedBy <new id>`.

Every applied step adds a line to `<kitchen>\pre-tide\rebase-orders.jsonl`. Exit codes: 0 ok, 1 a step failed (it says which and what is
left), 2 refused.

## Effects (L1-L4)

- **L1, the person (Jordan):** a held order says why in words, and so does the Board's Sign-off text. He is not asked to retry an
  order that can never succeed. Re-cooking is one reviewed command, a dry run first.
- **L2, the business:** no cook time is spent on retries that cannot pass. The old work stays labelled, so nothing paid for is lost.
- **L3, the MSP (the Yard as a service):** a repo whose history is replaced is a case the system now handles, for any repo, not just
  this one move.
- **L4, the community (the public tide):** the old private history cannot reach the public repo through a kitchen pull request.

## Tests

- `tests/Test-KitchenFreshen.ps1`: 85 checks (75 before), all pass. New: section 5 (unrelated main) and three checks for the library.
  The Step holds with exit 10. Its last line names the branch, main, the cut-over, the re-cook tool, the label and the port tool. HEAD,
  BASE and DIFF.patch are unchanged, there is no `BASE.next` and no `MERGE_HEAD`, the real checkout is untouched, and a re-run holds again.
- `tests/Test-PrFlow.ps1`: 85 checks (83 before), all pass. New: section 2b. An orphan branch is held with exit 10, nothing reaches the fake GitHub,
  and no PR or record is made.
- `tests/Test-RebaseOrders.ps1` (new): 25 checks, all pass. They cover:
  - the affected list: old-history branch, queued before main began, and the cases that are not affected;
  - the dry run changes nothing;
  - the refusals: not affected, running, a bad id, `-Apply` while the Yard is not paused;
  - `-Apply`: a byte-for-byte copy, the label, the folder moved and still a worktree, the recipe and vars, kill then close, the log;
  - a set-aside order is closed without a kill, and a second copy never overwrites the first;
  - a failed cook moves the folder back and leaves the order alone, and a refused close names the command to finish by hand.

**The tests can fail.** Each Step was put back to tide main's version and its suite run again:

| Change | Result |
|---|---|
| `freshen.ps1` without the guard | 5 of 85 failed (exit 1 "git merge failed", not a hold) |
| `pr.ps1` without the guard | 7 of 85 failed: the orphan branch was pushed and PR #2 opened on the fake GitHub, which moved every later check |

## Not done here, and unknown

- **The tool was not applied.** Applying it is for the coordinator and Jordan. Its dry run on the live state is in the audit.
- **The merge station (`kitchen/stations/merge.ps1`) is not guarded.** It is the coordinator's file. A local merge of unrelated
  histories fails in git on its own: it refuses unless `--allow-unrelated-histories` is given, and the station never gives it.
- **Seen in the live Yard: no.** The Yard is paused, and no live order ran through the new hold.
