# Docs follow the move to the public home; check-names on a root commit (cut-over plan step 3, Team DOCS)

Tide's pull requests, CI and merges moved to this public repo on 2026-10-26. The docs that tell a session where the repo is and how
work lands now say so, and the old-names guard no longer stops on a repo's first commit.
- **Docs**: `kitchen/BUILDING.md` gets a "Building in public" section: commit and merge identity (the noreply address;
  merges only through `scripts/merge-pr.ps1`, whose merge author comes from `Get-MergeAuthorEmail`), personal values only in the
  state folder, private work only through the port tool `scripts/port-private.ps1`, and the cleaning scan. `AGENTS.md` rule 3 names
  the home repo, the two remotes and the merge command. `README.md` says this repo is the home and points to the new section.
  `kitchen/github-lib.ps1`: the header comment no longer says the checkout has no 'origin' remote (it has one now); pushes still go
  by explicit URL from `kitchen.repo.json`, whatever the remotes are. No code changed in that file.
- **check-names**: `-Base <ref>^1` (also `^`, `~`, `~1`) where `<ref>` is a root commit used to stop with exit 2 ("git cannot resolve
  -Base HEAD^1"). It now compares with the empty tree (every line of the commit counts as added) and prints a `NOTE:` line, also in
  the step summary. A shallow clone's cut-off commit shows no parent but has one: it stays exit 2, never the empty tree.
  `HEAD~2` from a root stays exit 2.
- **Tests**: `tests/Test-Names.ps1` 36 passed, 0 failed (was 31): root commit with `-Base HEAD^1` (exit 0, NOTE, 1 file and 3 lines
  checked, summary note), `HEAD~2` from a root (exit 2), a commit with a parent (no NOTE), a depth-1 shallow clone (exit 2).
  On this repo's own root commit: `check-names.ps1 -Base 8a56fad^1` -> NOTE, 36 files and 5746 added lines checked, 0 new, exit 0.
- **L1 (Jordan)**: a session that reads the docs opens and merges PRs in the right repo, with the right email, without asking him.
- **L2 (business)**: unknown: no business use of these docs yet.
- **L3 (MSP)**: unknown: no MSP use yet.
- **L4 (community)**: a reader of the public repo sees how one person keeps personal values out of a public codebase.
