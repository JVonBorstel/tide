# Merge station and batch-run follow the public home (2026-10-26)

**What:**
- `kitchen/stations/merge.ps1` no longer asks GitHub to merge an order's PR. It brings main up to GitHub's main, merges the exact tested commit here as the account's noreply address (`Get-MergeAuthorEmail`), and pushes a fast-forward of GitHub's main. GitHub marks the PR merged.
- A refused push puts main back at GitHub's main, then exits 11 (try later).
- `scripts/batch-run.ps1`: with no `-RemoteUrl`, it uses `https://github.com/<kitchen.repo.json github>.git` of `-Repo`, instead of a hard-coded old repo.

**Why:**
- GitHub stamps a merge it makes with the account's primary email. On 2026-10-26 a work address reached the public main.
- GitHub refuses the noreply address as `--author-email` while "Keep my email addresses private" is off.
- The repo's home moved to tide.

**Tests:**
- PrFlow 87/0: the merge commit's parents are main and the tested commit; author and committer are noreply; GitHub is never asked to merge.
- BatchRun 35/0: two new checks for the remote default.
- KitchenSupervisor 222/0, AutoMerge 140/0.
- Kitchen 68/2: the 2 are main's old task-name checks, fixed by the headless-tasks port.

**L1-L4:** person: no private email in public history from the Yard's merges. Business and MSP: the Yard can merge again once resumed. Community: none.
