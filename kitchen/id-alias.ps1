# Tide input aliases for kitchen IDs (rename plan S2-IDALIAS). Dot-source it: . (Join-Path $PSScriptRoot 'id-alias.ps1')
# The Board shows a work order as WO-0207 and a sign-off as SO-104, but the stored IDs stay J207 and A104 forever.
# ConvertFrom-TideId maps what a person types back to the stored form before any check runs:
#   -Kind Job     : WO-207, WO-0207, #0207, #207  -> J207
#   -Kind SignOff : SO-104, SO-0104               -> A104
# Anything else (J207, A104, garbage) comes back unchanged, so the caller's own check and error message still decide.
# Each kind maps only its own prefix: SO- is never turned into a job ID, WO- is never turned into a sign-off.
# Job-hunt application IDs are also A plus digits (collision list in projects/tide/naming/GLOSSARY.md); they have no
# prefix to map, so this never rewrites them, and only a sign-off slot ever accepts SO-.
function ConvertFrom-TideId {
    param([AllowNull()][AllowEmptyString()][string]$Id, [ValidateSet('Job', 'SignOff')][string]$Kind = 'Job')
    if ([string]::IsNullOrEmpty($Id)) { return $Id }
    $pattern = if ($Kind -eq 'Job') { '^\s*(?:WO-|#)(\d{1,9})\s*$' } else { '^\s*SO-(\d{1,8})\s*$' }
    $m = [regex]::Match($Id, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $Id }
    $n = $m.Groups[1].Value.TrimStart('0'); if (-not $n) { $n = '0' }
    $(if ($Kind -eq 'Job') { 'J' } else { 'A' }) + $n
}
