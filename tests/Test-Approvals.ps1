# Tests for scripts/approvals.ps1. Self-cleaning temp folder; secret-looking values are assembled from fragments.
$ErrorActionPreference = 'Stop'
$ap = Join-Path $PSScriptRoot '..\scripts\approvals.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('apt-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function A { param([string]$File) $o = & pwsh -NoProfile -File $ap -ApprovalsPath $File @args 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
function Sha12($t) { $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t)); (($h | % { $_.ToString('x2') }) -join '').Substring(0, 12) }
function Status($f, $id) { $l = Get-Content $f | ? { $_ -match "^$id \|" }; if ($l -match 'status:(\w+)$') { $Matches[1] } else { $null } }
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $f = Join-Path $root 'inbox\approvals.md'   # parent dir does not exist yet

    # add: creates file, format, ids auto-increment, sha is first 12 of sha256
    $r = A $f add -Level LOW -Text 'Run the unit tests'
    Check 'add exit 0' ($r.Code -eq 0); Check 'add creates file+dir' (Test-Path $f)
    $null = A $f add -Level HIGH -Text 'Wire the guard into user settings'
    $null = A $f add -Level med -Text 'Create a branch'
    $lines = @(Get-Content $f)
    Check 'three lines' ($lines.Count -eq 3)
    Check 'line1 format' ($lines[0] -eq "A1 | LOW | Run the unit tests | sha:$(Sha12 'Run the unit tests') | status:pending")
    Check 'ids increment' ($lines[1] -match '^A2 \| HIGH \|' -and $lines[2] -match '^A3 \| MED \|')
    # rejects
    foreach ($bad in @('x | y', "a`nb", '', '   ')) { $r = A $f add -Level LOW -Text $bad; Check "reject bad text '$($bad -replace "`n",'\n')'" ($r.Code -eq 2) }
    $r = A $f add -Level BOGUS -Text 'ok text'; Check 'reject bad level' ($r.Code -eq 2)
    $key = 'AKIA' + ('Q' * 16)
    $r = A $f add -Level LOW -Text "use key $key now"; Check 'secret rejected exit 2' ($r.Code -eq 2); Check 'secret value not echoed' ($r.Out -notmatch $key)
    Check 'secret not written' ((Get-Content $f -Raw) -notmatch 'AKIA')
    Check 'still 3 lines after rejects' (@(Get-Content $f).Count -eq 3)

    # list: pending = denied-by-default
    $r = A $f list
    Check 'list exit 0' ($r.Code -eq 0); Check 'list denied-by-default' ($r.Out -match 'denied-by-default'); Check 'list shows all ids' ($r.Out -match 'A1' -and $r.Out -match 'A2' -and $r.Out -match 'A3')

    # verify before answering: denied
    $r = A $f verify -Id A1 -Text 'Run the unit tests'; Check 'verify pending denied' ($r.Code -eq 1)

    # answer: batch parse
    $r = A $f answer -Reply 'A1 yes, A3 no'
    Check 'answer exit 0' ($r.Code -eq 0); Check 'A1 yes' ((Status $f 'A1') -eq 'yes'); Check 'A3 no' ((Status $f 'A3') -eq 'no'); Check 'A2 untouched' ((Status $f 'A2') -eq 'pending')
    # unknown id = error, nothing applied (atomic)
    $r = A $f answer -Reply 'A2 yes, A99 yes'
    Check 'unknown id exit 2' ($r.Code -eq 2); Check 'unknown id mentioned' ($r.Out -match 'A99'); Check 'atomic: A2 still pending' ((Status $f 'A2') -eq 'pending')
    # malformed token = error
    $r = A $f answer -Reply 'A2 maybe'; Check 'malformed answer exit 2' ($r.Code -eq 2)
    $r = A $f answer -Reply 'sure go ahead'; Check 'free text exit 2' ($r.Code -eq 2); Check 'free text applied nothing' ((Status $f 'A2') -eq 'pending')

    # yes all: LOW/MED only; HIGH refused
    $null = A $f add -Level LOW -Text 'Read the docs'      # A4
    $null = A $f add -Level MED -Text 'Edit a test file'   # A5
    $r = A $f answer -Reply 'yes all'
    Check 'yes all refuses HIGH exit 2' ($r.Code -eq 2); Check 'yes all says refused' ($r.Out -match '(?i)refus')
    Check 'yes all approved LOW' ((Status $f 'A4') -eq 'yes'); Check 'yes all approved MED' ((Status $f 'A5') -eq 'yes')
    Check 'yes all left HIGH pending' ((Status $f 'A2') -eq 'pending')
    Check 'yes all did not flip earlier no' ((Status $f 'A3') -eq 'no')
    # yes all with no HIGH pending: clean exit 0
    $f2 = Join-Path $root 'a2.md'; $null = A $f2 add -Level LOW -Text 'one'; $null = A $f2 add -Level MED -Text 'two'
    $r = A $f2 answer -Reply 'yes all'; Check 'yes all no HIGH exit 0' ($r.Code -eq 0 -and (Status $f2 'A1') -eq 'yes' -and (Status $f2 'A2') -eq 'yes')
    # HIGH needs a named id
    $r = A $f answer -Reply 'A2 yes'; Check 'named HIGH yes ok' ($r.Code -eq 0 -and (Status $f 'A2') -eq 'yes')
    $r = A $f answer -Reply 'A2 later'; Check 'later ok' ((Status $f 'A2') -eq 'later')

    # verify: execute-by-hash
    $r = A $f verify -Id A1 -Text 'Run the unit tests'; Check 'verify yes+match exit 0' ($r.Code -eq 0)
    $r = A $f verify -Id A1 -Text 'Run the unit tests -rf'; Check 'verify changed text denied' ($r.Code -eq 1)
    $r = A $f verify -Id A3 -Text 'Create a branch'; Check 'verify no denied' ($r.Code -eq 1)
    $r = A $f verify -Id A2 -Text 'Wire the guard into user settings'; Check 'verify later denied' ($r.Code -eq 1)
    $r = A $f verify -Id A77 -Text 'whatever'; Check 'verify unknown id exit 2' ($r.Code -eq 2)
    # tamper: text edited in the file while status+sha stay -> denied
    (Get-Content $f -Raw) -replace 'Run the unit tests \|', 'Delete everything |' | Set-Content $f -NoNewline
    $r = A $f verify -Id A1 -Text 'Delete everything'; Check 'tampered line denied' ($r.Code -eq 1)
    $r = A $f verify -Id A1 -Text 'Run the unit tests'; Check 'tampered line denied (old text)' ($r.Code -eq 1)

    # file is untrusted data: injected lines are never executed, malformed lines ignored but counted
    $f3 = Join-Path $root 'a3.md'
    $marker = Join-Path $root 'pwned.txt'
    Set-Content $f3 @("A1 | LOW | `$(Set-Content '$marker' x) | sha:000000000000 | status:yes", "garbage; Set-Content '$marker' x", ('A2 | LOW | fine | sha:' + (Sha12 'fine') + ' | status:yes'))
    $null = A $f3 list; $null = A $f3 verify -Id A2 -Text 'fine'; $null = A $f3 verify -Id A1 -Text '$(x)'
    Check 'content never executed' (-not (Test-Path $marker))
    $r = A $f3 list; Check 'list reports malformed' ($r.Out -match '(?i)malformed')
    $r = A $f3 add -Level LOW -Text 'next'; $l = Get-Content $f3 | ? { $_ -match '^A3 ' }; Check 'next id after odd lines' ($null -ne $l)

    # concurrency: parallel adds get unique ids
    $f4 = Join-Path $root 'a4.md'
    $jobs = 1..6 | % { $n = $_; Start-Job { pwsh -NoProfile -File $using:ap -ApprovalsPath $using:f4 add -Level LOW -Text "job $using:n" | Out-Null } }
    $jobs | Wait-Job -Timeout 120 | Out-Null; $jobs | Remove-Job -Force
    $ids = @(Get-Content $f4 | % { if ($_ -match '^A(\d+) ') { [int]$Matches[1] } })
    Check 'parallel adds: 6 lines' ($ids.Count -eq 6); Check 'parallel adds: unique ids' (@($ids | Sort-Object -Unique).Count -eq 6)

    # list on missing file: loud but harmless
    $r = A (Join-Path $root 'none.md') list; Check 'list missing file exit 0 and says none' ($r.Code -eq 0 -and $r.Out -match '(?i)no approvals')
    # script never executes content: no dangerous cmdlets in the script
    Check 'no Invoke-Expression / Start-Process in script' (-not (Select-String -Path $ap -Pattern 'Invoke-Expression|\biex\b|Start-Process' -Quiet))
    # FROZEN per ORG.md: header and README say so (no new features)
    Check 'FROZEN note in approvals.ps1 header' (@(Get-Content (Join-Path $PSScriptRoot '..\scripts\approvals.ps1') -TotalCount 12) -cmatch 'FROZEN')
    Check 'FROZEN note in README row for approvals.ps1' ((Get-Content (Join-Path $PSScriptRoot '..\README.md') -Raw) -match '(?m)^\|[^\n]*approvals\.ps1[^\n]*FROZEN')
} finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
Write-Host "Approvals tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
