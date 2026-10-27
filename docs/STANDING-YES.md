# Standing yeses (CREED 7)

Jordan's taps are his (kitchen/CREED.md rule 7). These are the only standing yeses he has given in writing. Each is limited to exactly its scope; anything not listed still needs his tap.

| Since | Standing yes | Scope and conditions |
|---|---|---|
| 2026-10-26 | Merge reviewed pull requests on this repo | Only through `scripts/merge-pr.ps1` (noreply identity, merge commit, never a force-push), only after a reviewer who is not the builder says SHIP (or SHIP after fixes, re-checked) and every CI check is green. |
| 2026-10-26 | Remove finished worktrees | Only worktrees that are merged, clean and idle; branches are always kept. |
| 2026-10-26 | Update held pull requests | Merge the base branch into a waiting PR with a normal merge, never a force-push. |
| 2026-10-26 | Redeploy the Board after merges | Only through `pass-app/update.ps1` (trial server first, live server swapped only after the trial passes). |

Still his tap, every time: installing software, changing account or repository settings, publishing anything new, deleting branches or history, spending money, and anything in a private project during its freeze.
