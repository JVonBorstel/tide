# Tests for kitchen/id-alias.ps1 (Tide rename S2-IDALIAS): what Jordan types (WO-0207, #0207, SO-104) maps to the stored
# IDs (J207, A104) before any check; stored forms and garbage pass through unchanged. No kitchen root needed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\kitchen\id-alias.ps1')
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Is([string]$in, [string]$kind, [string]$want) {
    $got = ConvertFrom-TideId $in -Kind $kind
    Check "$kind '$in' -> '$want' (got '$got')" ($got -ceq $want)
}

# work orders
Is 'WO-207' Job 'J207'
Is 'WO-0207' Job 'J207'
Is '#0207' Job 'J207'
Is '#207' Job 'J207'
Is 'wo-0207' Job 'J207'
Is ' WO-0207 ' Job 'J207'
Is 'WO-0000' Job 'J0'
Is 'J207' Job 'J207'          # the stored form keeps working
Is 'j207' Job 'j207'          # passes through untouched (the API's own check decides, as before)

# sign-offs
Is 'SO-104' SignOff 'A104'
Is 'SO-0104' SignOff 'A104'
Is 'so-104' SignOff 'A104'
Is 'A104' SignOff 'A104'      # the stored form keeps working

# default kind is Job
Check 'default kind is Job' ((ConvertFrom-TideId 'WO-0207') -ceq 'J207')
Check 'default kind never maps SO-' ((ConvertFrom-TideId 'SO-104') -ceq 'SO-104')

# each kind maps only its own prefix
Is 'SO-104' Job 'SO-104'      # a sign-off is never read as a work order
Is 'WO-207' SignOff 'WO-207'  # a work order is never read as a sign-off
Is '#104' SignOff '#104'

# collision list: job-hunt application IDs are also A plus 1-5 digits; they must never be read as a sign-off or a work order
Is 'A104' Job 'A104'
Is 'A-1001' SignOff 'A-1001'
Is 'A-1001' Job 'A-1001'
Is 'APP-104' SignOff 'APP-104'
Check 'an application id stays an application id after both kinds' ((ConvertFrom-TideId (ConvertFrom-TideId 'A12345' -Kind Job) -Kind SignOff) -ceq 'A12345')

# garbage passes through unchanged (so the caller's same error message still fires)
foreach ($g in @('', 'x; rm', 'WO-', 'WO-207x', 'WO-20 7', 'WO--207', '#', '#x', 'SO-', 'SO-1x', 'SO-123456789', 'WO-1234567890', "WO-207`nJ1", 'J207; rm')) {
    Check "garbage '$($g -replace "`n", '\n')' unchanged (Job)" ((ConvertFrom-TideId $g -Kind Job) -ceq $g)
    Check "garbage '$($g -replace "`n", '\n')' unchanged (SignOff)" ((ConvertFrom-TideId $g -Kind SignOff) -ceq $g)
}
Check 'null passes through' ($null -eq (ConvertFrom-TideId $null) -or '' -eq (ConvertFrom-TideId $null))
Check 'unknown kind refused' ($(try { ConvertFrom-TideId 'WO-1' -Kind Application | Out-Null; $false } catch { $true }))

Write-Host "IdAlias tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
