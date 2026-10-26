# A stand-in for the public privacy scan (public-tide-scan.ps1 -Json, kept outside this repo because it reads this PC's private
# values) for tests/Test-PortPrivate.ps1. Same JSON contract: { files, live: {class: count}, hits: [ {class, file, line} ] }.
# Classes: the synthetic value LIVE-VALUE is a live hit (LIVE:test), the words "job hunt" a job-words hit. FAKE_SCAN_FAIL makes it fail.
param([Parameter(Mandatory)][string]$Root, [switch]$Json, [string]$Patterns = '', [switch]$ShowText)
$ErrorActionPreference = 'Stop'
if ($env:FAKE_SCAN_FAIL) { [Console]::Error.WriteLine('scan: could not read the live values'); exit 1 }
$hits = [Collections.Generic.List[object]]::new(); $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Root.TrimEnd('\', '/').Length + 1)
    $lines = [IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'LIVE-VALUE') { $hits.Add([ordered]@{ class = 'LIVE:test'; file = $rel; line = $i + 1 }) }
        if ($lines[$i] -match '(?i)job hunt') { $hits.Add([ordered]@{ class = 'job-words'; file = $rel; line = $i + 1 }) }
    }
}
ConvertTo-Json -InputObject ([ordered]@{ files = $files.Count; live = @{ test = 1 }; hits = @($hits) }) -Depth 5 -Compress
exit 0
