# Tests for the github var normalizer (kitchen/github-lib.ps1 ConvertTo-GithubSlug, called at the top of kitchen/stations/pr.ps1):
# any form Jordan pastes (URL, ssh, .git, plain) gives gh owner/name; garbage fails loudly with the value named (J193, J269).
# Pure string work: no git, no gh, no network. The pr station itself with a URL is covered in Test-PrFlow.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\kitchen\github-lib.ps1')
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$want = 'VonBorstel-J/demo-project'
function Slug([string]$v) { (ConvertTo-GithubSlug $v).slug }

Check 'URL: https://github.com/owner/repo gives owner/repo (the J193 value)' ((Slug "https://github.com/$want") -eq $want)
Check 'URL: trailing slash and http/www forms give owner/repo' ((Slug "https://github.com/$want/") -eq $want -and (Slug "http://www.github.com/$want") -eq $want -and (Slug "  https://GitHub.com/$want  ") -eq $want)
Check 'ssh: git@github.com:owner/repo.git gives owner/repo' ((Slug "git@github.com:$want.git") -eq $want -and (Slug "ssh://git@github.com/$want.git") -eq $want)
Check '.git: https URL and plain name ending in .git give owner/repo' ((Slug "https://github.com/$want.git") -eq $want -and (Slug "$want.git") -eq $want -and (Slug "https://github.com/$want.git/") -eq $want)
Check 'plain: owner/repo stays owner/repo' ((Slug $want) -eq $want -and -not (ConvertTo-GithubSlug $want).bad)
Check 'empty keeps today''s behaviour (derived later): empty slug, no error' ((Slug '') -eq '' -and -not (ConvertTo-GithubSlug '').bad -and (Slug '   ') -eq '')
Check 'none/off are kept for "no GitHub home"' ((Slug 'none') -eq 'none' -and (Slug 'off') -eq 'off' -and (Resolve-GithubSlug '.' (Slug 'none')).none)
foreach ($junk in 'not a repo', 'https://gitlab.com/VonBorstel-J/x', 'https://github.com/VonBorstel-J', 'owner/repo/extra', '../etc', 'a/..') {
    $r = ConvertTo-GithubSlug $junk
    Check "garbage fails with the value named: '$junk'" (-not $r.slug -and $r.bad -match [regex]::Escape("'$junk'"))
}
# the pr station runs it first: a bad value stops it with exit 2 before anything else (no job, no git, no gh needed)
$pw = (Get-Process -Id $PID).Path
$out = (& $pw -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '..\kitchen\stations\pr.ps1') -Repo $PSScriptRoot -GitHub 'not a repo' 2>&1 | Out-String)
Check 'pr station: garbage github stops it loudly (exit 2, value named)' ($LASTEXITCODE -eq 2 -and $out -match "'not a repo'")

Write-Host "GitHubSlug tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
