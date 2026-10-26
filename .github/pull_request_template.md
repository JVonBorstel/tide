# In plain words
<!-- 3-6 short sentences for Jordan, who reads on their phone and does not read code: what changes for them, what they will see, any risk. -->

## What changed
<!-- One or two sentences. Link the Yard work order (code: kitchen job, stored ID J123) or issue if there is one. -->

## Why
<!-- The problem this solves or the goal it serves. -->

## Proof
<!-- Suites run, with their result lines (counts, not adjectives). Run suites with scripts/run-bounded.ps1. Readiness gate: verify-all AND the sandboxed tests Step (code: station) on a fresh worktree. -->
- [ ] `scripts/verify-all.ps1`
- [ ] sandboxed tests Step on a fresh worktree (`kitchen/stations/tests.ps1`)
- [ ] CI is green

## Effect (L1-L4)
<!-- One line each; "none" where there is none. L1 the person, L2 the business, L3 the MSP, L4 the community. -->

## Risk
<!-- What could break, who or what is affected (the live Yard (code: kitchen), the Board (code: Chef, pass-app/), the Office (code: gemini-brain)), and how you would notice. Low / medium / high and why. -->

## Rollback
<!-- How to undo it: `git revert -m 1 <merge sha>`, `kitchen/undo-merge.ps1` for a Yard work order, `pass-app/update.ps1` after reverting Board changes. See docs/RUNBOOK.md. -->

## Checklist
- [ ] No secret, key, token or personal data in the diff
- [ ] Code map re-made (`scripts/make-map.ps1`) if code files were added, removed or renamed
- [ ] Jordan has signed off on the merge
