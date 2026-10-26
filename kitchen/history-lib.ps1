# Shared history between an order's branch and main (functions only: Get-HistoryRelation, Get-UnrelatedHistoryHold).
# The freshen and pr stations call it so an order built on a main that was later replaced by an unrelated history stops with one plain
# hold line, instead of a late "refusing to merge unrelated histories" failure (freshen) or a push of the old history to the new home
# (pr). The case it was written for: on 2026-10-26 brain-monitor's code moved to the public repo tide with a fresh history; orders queued
# before that were built on the old private history. Tests: tests/Test-KitchenFreshen.ps1, tests/Test-PrFlow.ps1.

# 'shared' (git finds a merge base), 'unrelated' (git says there is none: exit 1, no output) or 'unknown' (git could not tell: a missing
# commit, a broken repo). Only 'unrelated' stops a station; 'unknown' goes on and the station's own checks speak, as before.
function Get-HistoryRelation([string]$Dir, [string]$A, [string]$B) {
    $o = "$(@(& git -C $Dir merge-base $A $B 2>$null) -join '')".Trim(); $c = $LASTEXITCODE
    if ($c -eq 0 -and $o) { return 'shared' }
    if ($c -eq 1 -and -not $o) { return 'unrelated' }
    'unknown'
}

# The hold line both stations print (the supervisor shows the last line of a hold as its reason, so this is one line). $What says what
# the station did not do. The way out names the re-cook tool (dry run until -Apply) and the port tool; nothing is deleted either way.
function Get-UnrelatedHistoryHold([string]$Station, [string]$Job, [string]$Branch, [string]$MainName, [string]$MainShort, [string]$What) {
    "${Station}: HOLD: $Branch and $MainName@$MainShort share no history: $Job was built on a main that has since been replaced by an unrelated history (as in the 2026-10-26 cut-over of brain-monitor to tide). $What. The way out: re-cook $Job on the new main (scripts/rebase-orders.ps1 -Ids $Job, a dry run until -Apply; its old branch is kept as pre-tide/$Branch and its folder as worktrees\pre-tide-$Job), or port its commits with scripts/port-private.ps1. A yes on this hold only runs the check again."
}
