# Station: runs the lobe (the public zeitgeistd repo) on this PC: -Cmd sweep | rem | csf | health | memory-check | memory-truth, through uv,
# with the Yard's own guards. Called by the lobe-sweep and lobe-rem Specs (kitchen/recipes/lobe-*.json) and by hand; tests/Test-LobeStation.ps1
# drives it with a fake python.
#   step: {"station":"lobe","args":{"Cmd":"sweep"},"timeoutSec":300,"retries":0,"mustMatch":"lobe: sweep done"}
# In order:
#   1. Finds the zeitgeistd checkout: env ZEITGEISTD_REPO, else kitchen.json "lobe": {"repo": "<full path>"} (the state-folder copy first,
#      then this repo's), else <user profile>\source\repos\zeitgeistd. A folder without pyproject.toml and zeitgeistd\__init__.py: exit 1.
#   2. ZEITGEISTD_HOME = <kitchen>\lobe. <kitchen>\lobe\config.json gets "heartbeat_path": "<kitchen>\watch\lobe.json", so the Watch
#      (kitchen/watch.ps1, every watch\*.json) reads the lobe's heartbeat. Other keys are kept. A config.json that is not a JSON object is
#      never overwritten (exit 1).
#   3. sweep and rem may call a model, so they pass two gates first: free RAM (kitchen/scaler.ps1 Get-ScalerFreeMB) of at least -MinFreeMB
#      (2,500), and the Ollama probe (kitchen/cooks/local.ps1 -Probe). A gate that stops the run: the reason is printed, the heartbeat records
#      the skip through `health --skip <why> --run <cmd>`, and the exit is 11 (wait; no retry used; the convention of stations/ci-wait.ps1).
#      An Ollama address that is not this PC is a refusal instead: exit 1, no module run. csf and health only read: no gates, no lock.
#      rem then asks the ZG-32 governor (`governor check --run rem`, when the checkout has it): 11 = wait (the governor wrote its own
#      heartbeat skip), 0 = go, anything else = rem is refused (exit 1; the governor's own refusal is in the heartbeat).
#   4. sweep and rem hold the GPU lock Global\brain-kitchen-gpu (the one kitchen/cooks/local.ps1 holds) while they run. Still busy after
#      -GpuWaitSec: the same skip, exit 11.
#   5. Runs `uv run --locked --quiet python -I -m zeitgeistd.<module>` in the checkout (UV_PYTHON_PREFERENCE=only-managed), with the API key
#      variables removed (the list of kitchen/cooks/claude.ps1 and cooks/agy.ps1, plus any *_API_KEY / *_AUTH_TOKEN) and KITCHEN_OLLAMA_URL
#      passed through. sweep = db init, connectors.yard, connectors.git, actions run, csf, gate sweep. The gate goes last because its
#      heartbeat carries the sweep's stop reasons and a failed sweep's error; a later csf run would overwrite them. A failed db init stops
#      the sweep; any other failed step does not stop the rest.
#      rem (ZG-42, the night) = actions run, claims run, edges run (writes tensions.json for memory-truth), trust run, decisions prepare,
#      rem (ZG-28, the core), causal run --lock-held (rem already holds the GPU lock). csf = csf (the core), then brief (FRAME.md, ZG-43).
#      The steps around a core are night steps: a failed one is named (output, sleep[], the heartbeat's error) and never stops the rest
#      or changes the exit; one not in the checkout yet is named as absent. decisions prepare and causal run call models.strong: while the
#      lobe's config.json has no "models.strong" they are named as off and not run (zeitgeistd refuses them then anyway, ZG-24 / ZG-26).
#      causal's exit 11 is "the governor said wait": named as waits, not a failure.
#   6. Prints `lobe: <cmd> done items=N dropped=N ms=N` (the Specs' mustMatch) when every core step exited 0. Otherwise it prints
#      `lobe: <cmd> FAILED (...)` and exits with the first failing core step's code (10 and 11 become 1: a failure is never read as a hold
#      or wait). items and dropped come from the module's own "zeitgeistd: <cmd> ok" line (processed= or items=, and dropped=); csf and
#      health take in nothing, so theirs are 0.
#   7. Sleep (ZG-42): the lobe-rem Spec is one night in four Steps: rem, memory-check, memory-truth, csf. `-Cmd rem` opens the night in
#      <kitchen>\lobe\sleep.json (its work order, KITCHEN_JOB); each later Step of that work order adds its entries: {step, exit, ms, state
#      ok|failed|waits|off|absent|unknown, why?}. memory-check (scripts/memory-check.ps1 -Quiet, a read-only report) and memory-truth
#      (scripts/memory-truth.ps1) each run under scripts/run-bounded.ps1 (-StepSec, 1,000 MB) and ALWAYS exit 0 with
#      `lobe: <cmd> done exit=N ms=N`: their own exit code goes into sleep[], so a failing memory Step never stops the frame Step. csf adds
#      the Site cleanup's archive and backup retention as read from the doctor's last report in <kitchen>\events.jsonl ('archive: done by
#      Site cleanup at <time>' or 'unknown'; this station never runs or moves them) and closes the night. After every run of this station
#      the night is copied into watch\lobe.json as sleep[] (with sleepNight, sleepClosed and sleepFailed), and a failed night step is added
#      to its `error` as 'sleep: <steps> failed', so the Watch names it. zeitgeistd rewrites that file on each run; this station puts sleep[]
#      back each time. Nothing here deletes anything: rem deletes only inside the lobe database (zeitgeistd ZG-28).
#   8. ZG-17: a gate or lock skip (exit 11) is counted by kind (ram, ollama, gpu) in <kitchen>\lobe\yard-counts.json, which the Board's
#      morning line reads. After a rem run that exited 0, one phone push through kitchen/notify.ps1 -Safe with the World line's counts and
#      fixed words only, at most once a day and only when the line changed. Push off: notify answers off and nothing is sent or recorded.
#   9. ZG-21, the verify bridge (-Cmd verify; also after every rem run that exited 0: after causal run, once the GPU lock is released,
#      and before the ZG-17 push). No model, no gates, no lock: the Cloud crew does the web work.
#      a. Collect: for each work order it filed whose answer is saved (<kitchen>\lobe\verify\<job>.md, the lobe-verify Spec's SaveTo), it
#         reads the VERDICT line (VERIFIED, REFUTED, GOALPOST_MOVED or UNKNOWN) and the URLs under SOURCES, and calls
#         `claims resolve <id> <verdict> --by auto --sources <urls> <answer file>`. zeitgeistd decides whether that is evidence; this Step
#         never marks a claim true. No single verdict: UNKNOWN with the file kept. A verdict zeitgeistd refuses (exit 3): UNKNOWN, file kept.
#      b. File (not with -Only collect): `claims due --public --json`; only claims whose privacy is exactly P0 become work orders (a P1 or
#         P2 claim, or one with no privacy, is dropped and never written anywhere, even if the list holds it). At most 3 a day, on Spec
#         lobe-verify (kitchen/cook.ps1). The question is the claim's statement and its two dates, nothing else.
#      The work-order list is <kitchen>\lobe\verify-orders.json (claim id, work order, state; never the statement).
# KITCHEN_LOBE_PYTHON (tests): a stand-in for `uv run --locked --quiet python`; a .ps1 runs under this pwsh. KITCHEN_FAKE_FREE_MB: see scaler.ps1.
# KITCHEN_LOBE_SCRIPTS (tests): the folder holding memory-check.ps1 and memory-truth.ps1 (default: this repo's scripts\).
param([Parameter(Mandatory)][ValidateSet('sweep', 'rem', 'csf', 'health', 'verify', 'memory-check', 'memory-truth')][string]$Cmd, [int]$MinFreeMB = 2500,
    [int]$GpuWaitSec = 60, [int]$StepSec = 240, [ValidateSet('', 'collect')][string]$Only = '')
$ErrorActionPreference = 'Stop'
$kd = Split-Path -Parent $PSScriptRoot
. (Join-Path $kd 'scaler.ps1')
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$sw = [Diagnostics.Stopwatch]::StartNew()
# A plan entry: the module and its args, its name, and whether it is a night step around the core (add), calls models.strong (model),
# or reads exit 11 as "waits" (wait).
function P([string[]]$Mod, [switch]$Add, [switch]$Model, [switch]$Wait) {
    @{ mod = $Mod; name = ((@($Mod | Where-Object { $_ -notlike '--*' }) -join ' ') -replace '^zeitgeistd\.', ''); add = [bool]$Add; model = [bool]$Model; wait = [bool]$Wait }
}
$script:Plan = @{
    sweep  = @((P 'zeitgeistd.db', 'init'), (P 'zeitgeistd.connectors.yard'), (P 'zeitgeistd.connectors.git'), (P 'zeitgeistd.actions', 'run'),
        (P 'zeitgeistd.csf'), (P 'zeitgeistd.gate', 'sweep'))
    rem    = @((P 'zeitgeistd.actions', 'run' -Add), (P 'zeitgeistd.claims', 'run' -Add), (P 'zeitgeistd.edges', 'run' -Add),
        (P 'zeitgeistd.trust', 'run' -Add), (P 'zeitgeistd.decisions', 'prepare' -Add -Model), (P 'zeitgeistd.rem'),
        (P 'zeitgeistd.causal', 'run', '--lock-held' -Add -Model -Wait))
    csf    = @((P 'zeitgeistd.csf'), (P 'zeitgeistd.brief' -Add))
    health = @(, (P 'zeitgeistd.health'))
    verify = @(, (P 'zeitgeistd.claims'))
}
$script:ModelCmds = @('sweep', 'rem')
$script:KeyVars = @('ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX',
    'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_GENAI_USE_VERTEXAI', 'GOOGLE_CLOUD_PROJECT')
$script:WaitSec = 900   # the Yard's own default wait after an exit 11 (kitchen.ps1), written to <run>.wait so it is explicit
$script:Lines = [Collections.Generic.List[string]]::new(); $script:Code = 0
$lobeHome = Join-Path $kroot 'lobe'; $beat = Join-Path (Join-Path $kroot 'watch') 'lobe.json'; $sleepPath = Join-Path $lobeHome 'sleep.json'
$script:Night = $null

function Iso([datetime]$t) { $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# ---- sleep (ZG-42) ----
# Writes text to a file in one move (temp name not *.json): a reader never sees half a file.
function Write-Whole([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
# The night on disk, or $null. Times stay strings (ConvertFrom-Json would turn them into dates).
function Read-Night {
    if (-not (Test-Path -LiteralPath $sleepPath -PathType Leaf)) { return $null }
    try { $n = Get-Content -LiteralPath $sleepPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return $null }
    if ($n -isnot [Collections.IDictionary] -or $n.steps -isnot [Collections.IList]) { return $null }
    foreach ($k in 'night', 'closed') { if ($n[$k] -is [datetime]) { $n[$k] = Iso $n[$k] } }
    $n.steps = [Collections.Generic.List[object]]@($n.steps)
    $n
}
function Save-Night { if ($script:Night) { Write-Whole $sleepPath ($script:Night | ConvertTo-Json -Depth 6 -EscapeHandling EscapeNonAscii) } }
function Open-Night {
    $script:Night = [ordered]@{ night = Iso (Get-Date); job = [string]$env:KITCHEN_JOB; closed = $null; steps = [Collections.Generic.List[object]]::new() }
    Save-Night
}
# The night this work order opened and has not closed, else $null (a Step run by hand with no night open is not recorded).
function Find-Night {
    $n = Read-Night
    if ($n -and -not $n.closed -and [string]$n.job -eq [string]$env:KITCHEN_JOB) { return $n }
    $null
}
function Say-NoNight { if (-not $script:Night) { Write-Output "lobe: $Cmd`: no night open for this work order (lobe-rem's rem Step opens one); this run is not in sleep[]" } }
function Add-Sleep([string]$Step, $Exit, [long]$Ms, [string]$State, [string]$Why = '') {
    if (-not $script:Night) { return }
    $e = [ordered]@{ step = $Step; exit = $Exit; ms = $Ms; state = $State }
    if ($Why) { $e.why = $Why }
    $script:Night.steps.Add($e); Save-Night
}
# Copies the night into watch\lobe.json (sleep[], sleepNight, sleepClosed, sleepFailed) and names failed night steps in its error.
function Set-SleepBeat {
    $n = Read-Night
    if (-not $n) { return }
    if (-not (Test-Path -LiteralPath $beat -PathType Leaf)) { Write-Output "lobe: sleep[] not in the heartbeat: $beat does not exist yet"; return }
    try { $hb = [Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($beat)) } catch { $hb = $null }
    if ($hb -isnot [Text.Json.Nodes.JsonObject]) { Write-Output "lobe: sleep[] NOT written: $beat is not a JSON object; left as it is"; return }
    $failed = @($n.steps | Where-Object { $_.state -eq 'failed' } | ForEach-Object { if ($null -ne $_.exit) { "$($_.step) (exit $($_.exit))" } else { [string]$_.step } })
    $hb['sleep'] = [Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject @($n.steps) -Depth 6 -EscapeHandling EscapeNonAscii))
    $hb['sleepNight'] = [string]$n.night; $hb['sleepClosed'] = $(if ($n.closed) { [string]$n.closed } else { $null })
    $hb['sleepFailed'] = [Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject @($failed) -EscapeHandling EscapeNonAscii))
    $err = if ($null -ne $hb['error']) { [string]$hb['error'].ToString() } else { '' }
    $parts = @($err -split '; ' | Where-Object { $_ -and $_ -notmatch '^sleep: ' })   # last copy's words go; this night's come in
    if ($failed.Count) { $parts += "sleep: $($failed -join ', ') failed" }
    $hb['error'] = $(if ($parts.Count) { $parts -join '; ' } else { $null })
    Write-Whole $beat $hb.ToJsonString()
}
# The Site cleanup's archive and backup retention, from the doctor's last report (a 'doctor' event in <kitchen>\events.jsonl): @{ state; why }.
function Get-ArchiveNote {
    $ev = Join-Path $kroot 'events.jsonl'
    if (-not (Test-Path -LiteralPath $ev -PathType Leaf)) { return @{ state = 'unknown'; why = "archive: unknown (no Site cleanup report: $ev does not exist)" } }
    $lines = @(Get-Content -LiteralPath $ev -Tail 20000 -Encoding utf8)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"type"\s*:\s*"doctor"') { continue }
        try { $d = $lines[$i] | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { continue }
        $at = if ($lines[$i] -match '"ts"\s*:\s*"([^"]+)"') { $Matches[1] } else { 'an unknown time' }
        $probs = @(([string]$d.problems) -split '; ' | Where-Object { $_ -match '^(archive|not archived|backup retention):' })
        if ($probs.Count) { return @{ state = 'failed'; why = "archive: Site cleanup at $at reported: $($probs -join '; ')" } }
        return @{ state = 'ok'; why = "archive: done by Site cleanup at $at (archived $([int]$d.archived) work orders; backup retention reported no problem)" }
    }
    @{ state = 'unknown'; why = "archive: unknown (no Site cleanup report in the last 20,000 lines of $ev)" }
}

function Stop-Lobe([string]$Why, [int]$Code = 1) { Write-Output "lobe: $Cmd FAILED ($Why) ms=$($sw.ElapsedMilliseconds)"; Set-SleepBeat; exit $Code }

# The checkout and where its path came from: @{ path; from }. Stops on a setting that cannot be used.
function Find-LobeRepo {
    $r = if ($env:ZEITGEISTD_REPO) { @{ path = $env:ZEITGEISTD_REPO; from = 'env ZEITGEISTD_REPO' } } else { $null }
    foreach ($p in @((Join-Path $kroot 'kitchen.json'), (Join-Path $kd 'kitchen.json'))) {
        if ($r -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try { $j = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { Stop-Lobe "kitchen.json at $p is not valid JSON" }
        if ($j -is [Collections.IDictionary] -and $j.lobe -is [Collections.IDictionary] -and $j.lobe.repo) { $r = @{ path = [string]$j.lobe.repo; from = "kitchen.json lobe.repo in $p" } }
    }
    if (-not $r) { $r = @{ path = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), 'source', 'repos', 'zeitgeistd'); from = 'default' } }
    if (-not [IO.Path]::IsPathRooted($r.path)) { Stop-Lobe "the zeitgeistd checkout must be a full path, not '$($r.path)' (from $($r.from))" }
    $r.path = [IO.Path]::GetFullPath($r.path)
    $ok = (Test-Path -LiteralPath (Join-Path $r.path 'pyproject.toml') -PathType Leaf) -and (Test-Path -LiteralPath ([IO.Path]::Combine($r.path, 'zeitgeistd', '__init__.py')) -PathType Leaf)
    if (-not $ok) { Stop-Lobe "no zeitgeistd checkout at $($r.path) (from $($r.from)): pyproject.toml or zeitgeistd\__init__.py is missing" }
    $r
}

# Points config.json's heartbeat_path at the Watch's folder. Returns what it did (and the config), or @{ err } when the file must not be touched.
function Set-LobeConfig([string]$LobeHome, [string]$Beat) {
    $path = Join-Path $LobeHome 'config.json'
    $cfg = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $cfg = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return @{ err = "config.json at $path is not valid JSON; left as it is" } }
        if ($cfg -isnot [Collections.IDictionary]) { return @{ err = "config.json at $path is not a JSON object; left as it is" } }
    }
    $old = $cfg['heartbeat_path']
    if ($old -is [string] -and $old -eq $Beat) { return @{ said = ''; cfg = $cfg } }
    $cfg['heartbeat_path'] = $Beat
    $tmp = "$path.$PID.tmp"   # not *.json, and replaced in one move: a reader never sees half a file
    [IO.File]::WriteAllText($tmp, ($cfg | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    @{ said = "config.json heartbeat_path set to $Beat$(if ($null -ne $old) { " (was '$old')" })"; cfg = $cfg }
}

# The gates for a command that may call a model: @{ why; code; note }. why '' = go.
function Test-LobeGates([int]$NeedMB) {
    $note = ''
    $free = Get-ScalerFreeMB $true
    if ($null -eq $free) { $note = 'free RAM: unknown (no reading), not a stop' }
    elseif ($free -lt $NeedMB) { return @{ why = "free RAM $free MB is under $NeedMB MB"; code = 11; note = $note; kind = 'ram' } }
    else { $note = "free RAM $free MB" }
    try { $p = & (Join-Path $kd (Join-Path 'cooks' 'local.ps1')) -Probe } catch { $p = @{ ready = $false; why = "the Ollama probe failed ($($_.Exception.Message))" } }
    if ($p -isnot [hashtable]) { $p = @{ ready = $false; why = 'the Ollama probe gave no answer' } }
    if (-not $p.ready) {
        $refused = [string]$p.why -match '^refused:'
        return @{ why = "Ollama: $($p.why)"; code = $(if ($refused) { 1 } else { 11 }); note = $note; kind = 'ollama' }
    }
    @{ why = ''; code = 0; note = "$note; Ollama: $($p.why)" }
}

# Runs one module in the checkout; its output streams to this step's log. Sets $script:Lines and $script:Code.
function Invoke-LobeModule([string]$Repo, [string[]]$ModArgs, [switch]$Quiet) {
    $ErrorActionPreference = 'Continue'   # a module's stderr is part of the log, never a reason to stop here
    $script:Lines = [Collections.Generic.List[string]]::new()
    $fake = $env:KITCHEN_LOBE_PYTHON
    $exe = 'uv'; $pre = @('run', '--locked', '--quiet', 'python')
    if ($fake -and $fake -match '(?i)\.ps1$') { $exe = (Get-Process -Id $PID).Path; $pre = @('-NoProfile', '-File', $fake) }
    elseif ($fake) { $exe = $fake; $pre = @() }
    Push-Location -LiteralPath $Repo
    try {
        # -Quiet (ZG-21: the due list holds claim text): the lines are kept for the caller, not written to this Step's log
        & $exe @pre '-I' '-m' @ModArgs 2>&1 | ForEach-Object { $l = "$_"; $script:Lines.Add($l); if (-not $Quiet) { $l } }
        $script:Code = $LASTEXITCODE
    } catch { $l = "lobe: could not start $exe ($($_.Exception.Message))"; $script:Lines.Add($l); if (-not $Quiet) { $l }; $script:Code = 1 }
    finally { Pop-Location }
}

# A gate or the lock stopped the run: say why, record the skip in the heartbeat (unless the governor already did), and exit 11 (wait) or 1.
function Skip-Lobe([string]$Repo, [string]$Why, [int]$Code, [string]$Kind = '', [switch]$Beaten) {
    Write-Output "lobe: $Cmd stopped before it ran: $Why"
    if ($Code -eq 11 -and $Kind) { Add-LobeSkip $Kind }   # ZG-17: counted for the morning line (a refusal is a failure, not a skip)
    if ($Code -eq 11 -and $env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value $script:WaitSec }
    Add-Sleep $Cmd $null $sw.ElapsedMilliseconds $(if ($Code -eq 11) { 'waits' } else { 'failed' }) $Why
    if ($Beaten) { $said = 'written by the governor' }
    else {
        Invoke-LobeModule $Repo @('zeitgeistd.health', '--skip', $Why, '--run', $Cmd)
        $said = if (@($script:Lines | Where-Object { $_ -match '^zeitgeistd: heartbeat written' }).Count -gt 0) { 'written' } else { 'NOT written (see above)' }
    }
    Write-Output "lobe: $Cmd $(if ($Code -eq 11) { 'waits' } else { 'refused' }) ms=$($sw.ElapsedMilliseconds); heartbeat skip $said"
    Set-SleepBeat
    exit $Code
}

# items and dropped from the module's own ok line: processed= (else items=) and dropped= (a number, or rule:count pairs summed).
function Get-LobeCounts([string]$Word, $Lines) {
    $ok = @($Lines | Where-Object { $_ -match "^zeitgeistd: $Word ok\b" }) | Select-Object -Last 1
    $items = 0; $dropped = 0
    if ($ok -match '\bprocessed=(\d+)') { $items = [int]$Matches[1] } elseif ($ok -match '\bitems=(\d+)') { $items = [int]$Matches[1] }
    if ($ok -match '\bdropped=(\S+)') { foreach ($m in [regex]::Matches($Matches[1], '(?:^|[:,])(\d+)(?=,|$)')) { $dropped += [int]$m.Groups[1].Value } }
    @{ items = $items; dropped = $dropped }
}

# ---- ZG-17: the morning line's counts and the phone push (counts only, never content) ----
# The state is <kitchen>\lobe\yard-counts.json: {skips: [{at, cmd, kind}], push: {line, at}}. Not watch\lobe.json: the lobe's
# health.beat rewrites that file whole on every run, keeping only spotchecks (zeitgeistd health.py beat), and the Watch reads every
# watch\*.json as a heartbeat. The Board's brief reads the same file for the skip counts (pass-app/server.mjs lobeSkips).
$script:SkipKinds = [ordered]@{ ram = 'RAM'; ollama = 'Ollama'; gpu = 'graphics card' }   # the only words a skip reason becomes
$script:CountsPath = ''
# a time from the file as UTC, or $null. ConvertFrom-Json may already have made it a [datetime] (no -DateKind before pwsh 7.5).
function ConvertTo-Utc($V) {
    if ($V -is [datetime]) { return $V.ToUniversalTime() }
    $t = [datetime]::MinValue
    if ($V -is [string] -and [datetime]::TryParse($V, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { $t.ToUniversalTime() } else { $null }
}
function Read-LobeCounts {
    $j = $null
    try { if (Test-Path -LiteralPath $script:CountsPath -PathType Leaf) { $j = Get-Content -LiteralPath $script:CountsPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop } } catch { $j = $null }
    if ($j -isnot [Collections.IDictionary]) { $j = @{} }
    $skips = @(@($j['skips']) | Where-Object { $_ -is [Collections.IDictionary] -and $_['cmd'] -in 'sweep', 'rem' -and $script:SkipKinds.Contains([string]$_['kind']) -and (ConvertTo-Utc $_['at']) })
    @{ skips = $skips; push = $(if ($j['push'] -is [Collections.IDictionary]) { $j['push'] } else { @{} }) }
}
function Write-LobeCounts($St) {
    $cut = (Get-Date).ToUniversalTime().AddHours(-48)
    $keep = @($St.skips | Where-Object { (ConvertTo-Utc $_['at']) -ge $cut })
    $tmp = "$($script:CountsPath).$PID.tmp"   # replaced in one move: a reader never sees half a file
    [IO.File]::WriteAllText($tmp, ([ordered]@{ skips = $keep; push = $St.push } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:CountsPath -Force
}
function Add-LobeSkip([string]$Kind) {
    try {
        $st = Read-LobeCounts
        $st.skips = @($st.skips) + @([ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); cmd = $Cmd; kind = $Kind })
        Write-LobeCounts $st
    } catch { Write-Output "lobe: the skip was not counted for the morning line ($($_.Exception.GetType().Name))" }
}
# Skips in the last 24 h: @{ sweep; rem; ram; ollama; gpu } (numbers only)
function Get-SkipCounts($St) {
    $cut = (Get-Date).ToUniversalTime().AddHours(-24); $n = [ordered]@{ sweep = 0; rem = 0; ram = 0; ollama = 0; gpu = 0 }
    foreach ($s in $St.skips) { if ((ConvertTo-Utc $s['at']) -ge $cut) { $n[[string]$s['cmd']]++; $n[[string]$s['kind']]++ } }
    $n
}
# The frame's counts while it is fresh (240 min and state ok, the Board's rule): @{ decisions; signals }. An unreadable or stale frame gives none.
function Get-FrameCounts {
    try { $f = Get-Content -LiteralPath (Join-Path $lobeHome 'csf.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return @{} }
    if ($f -isnot [Collections.IDictionary] -or $f['meta'] -isnot [Collections.IDictionary] -or $f['meta']['counts'] -isnot [Collections.IDictionary]) { return @{} }
    $m = $f['meta']; $c = $m['counts']
    $times = @(foreach ($k in 'compiled_utc', 'last_sweep_utc') { $t = ConvertTo-Utc $m[$k]; if ($t) { $t } })
    if (-not $times.Count -or $m['state'] -ne 'ok' -or ((Get-Date).ToUniversalTime() - ($times | Measure-Object -Minimum).Minimum).TotalMinutes -gt 240) { return @{} }
    $num = { param($v) if ($v -is [int] -or $v -is [long]) { [long]$v } else { 0 } }
    @{ decisions = & $num $c['decisions_ready']; signals = & $num $c['world_signals_24h'] }
}
# The words of pass-app/public/world-line.js worldLine: "World: 2 decisions ready, 14 signals since yesterday; sweeps skipped 3x (RAM)".
# A zero count says nothing; all zero is ''. Numbers and fixed words only. (Calibration questions come with ZG-27; the frame has no count yet.)
function Format-WorldLine($F, $Sk) {
    $p = { param($v, $one, $many) if ($v -gt 0) { "$v $(if ($v -eq 1) { $one } else { $many })" } }
    $parts = @(@((& $p ([long]$F.decisions) 'decision ready' 'decisions ready'), (& $p ([long]$F.signals) 'signal since yesterday' 'signals since yesterday')) | Where-Object { $_ })
    $all = $Sk.sweep + $Sk.rem; $skip = ''
    if ($all -gt 0) {
        $i = 0; $kinds = @(@(foreach ($k in $script:SkipKinds.Keys) { if ($Sk[$k] -gt 0) { [pscustomobject]@{ w = $script:SkipKinds[$k]; v = $Sk[$k]; i = $i } }; $i++ }) |
                Sort-Object @{ e = 'v'; Descending = $true }, @{ e = 'i'; Descending = $false } | ForEach-Object w)
        $noun = if ($Sk.rem -gt 0) { if ($Sk.sweep -gt 0) { 'runs' } else { 'rem runs' } } else { 'sweeps' }
        $skip = "$noun skipped ${all}x$(if ($kinds.Count) { " ($($kinds -join ', '))" })"
    }
    if (-not $parts.Count -and -not $skip) { return '' }
    "World: $($parts -join ', ')$(if ($parts.Count -and $skip) { '; ' })$skip"
}
# After a rem run: one push through kitchen/notify.ps1 -Safe when there is something to say, the counts changed since the last push, and
# none went out today. Push off (no push-on file, no BRAIN_NTFY_TOPIC): notify answers off and sends nothing (notify.ps1 says off before it writes or sends), and the
# state stays as it was, so the first day push is on still gets its line. Never throws: a push never changes the run's result.
function Send-LobePush {
    try {
        $st = Read-LobeCounts; $line = Format-WorldLine (Get-FrameCounts) (Get-SkipCounts $st)
        if (-not $line) { Write-Output 'lobe: push not sent (every count is zero)'; return }
        # notify -Safe sends the text as given (it does not strip it), so the Step proves here it is counts and fixed words only
        if ($line -creplace '\d+x?|World:|decisions?|ready|signals?|since|yesterday|sweeps|rem|runs|skipped|RAM|Ollama|graphics|card|[ ,;()]', '') { Write-Output 'lobe: push not sent (the line had a word that is not a count)'; return }
        $day = (Get-Date).ToString('yyyy-MM-dd')
        $last = ConvertTo-Utc $st.push['at']
        if ($last -and $last.ToLocalTime().ToString('yyyy-MM-dd') -eq $day) { Write-Output 'lobe: push not sent (one already went out today)'; return }
        if ([string]$st.push['line'] -eq $line) { Write-Output 'lobe: push not sent (the counts have not changed since the last push)'; return }
        $ans = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $kd 'notify.ps1') -Level 'INFO' -Text $line -Safe 2>$null | Select-Object -Last 1
        $sent = try { [string]($ans | ConvertFrom-Json -ErrorAction Stop).sent } catch { 'no answer' }
        if ($sent -eq 'ok') { $st.push = [ordered]@{ line = $line; at = (Get-Date).ToUniversalTime().ToString('o') }; Write-LobeCounts $st }
        Write-Output "lobe: push $(if ($sent -eq 'ok') { 'sent' } else { "not sent ($sent)" })"
    } catch { Write-Output "lobe: push not sent (error: $($_.Exception.GetType().Name))" }
}

# ---- ZG-21: the verify bridge. Public (P0) claims only; the answer goes back to zeitgeistd as evidence, never as a ruling ----
$script:VerifyCap = 3          # work orders filed a day (local date)
$script:VerifyExpireDays = 7   # a work order with no saved answer after this long is let go; its claim may be filed again
$script:Verdicts = @('VERIFIED', 'REFUTED', 'GOALPOST_MOVED', 'UNKNOWN')
$script:VerifyPath = ''; $script:AnswerDir = ''
function Read-VerifyOrders {
    $j = $null
    if (Test-Path -LiteralPath $script:VerifyPath -PathType Leaf) {
        $j = Get-Content -LiteralPath $script:VerifyPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop   # unreadable: the run fails, the file is kept
    }
    , @(if ($j -is [Collections.IDictionary]) { @($j['orders']) | Where-Object { $_ -is [Collections.IDictionary] -and $_['claim'] -and $_['job'] } })
}
function Write-VerifyOrders($Orders) {
    $tmp = "$($script:VerifyPath).$PID.tmp"   # replaced in one move: a reader never sees half a file
    [IO.File]::WriteAllText($tmp, ([ordered]@{ orders = @($Orders) } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:VerifyPath -Force
}
# A saved answer: @{ status; urls; why }. One distinct VERDICT word, else UNKNOWN. URLs only from the last SOURCES section: http(s), a host,
# no user name or password, at most 9 (the answer file is the 10th source, kept as a note). zeitgeistd checks every one again.
function Read-VerifyAnswer([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $words = @([regex]::Matches($text, '(?im)^[\s>*#_-]*VERDICT[\s*_]*:[\s*_]*([A-Za-z_]+)') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Select-Object -Unique)
    $status = 'UNKNOWN'; $why = ''
    if ($words.Count -eq 1 -and $words[0] -in $script:Verdicts) { $status = $words[0] }
    elseif ($words.Count -eq 0) { $why = 'no VERDICT line' }
    elseif ($words.Count -gt 1) { $why = "$($words.Count) different VERDICT lines" }
    else { $why = 'a VERDICT that is not one of the four' }
    $heads = [regex]::Matches($text, '(?im)^[\s#*_]*SOURCES\b')
    $urls = [Collections.Generic.List[string]]::new()
    if ($heads.Count) {
        foreach ($m in [regex]::Matches($text.Substring($heads[$heads.Count - 1].Index), 'https?://[^\s<>()\[\]"''`]+')) {
            $u = $m.Value.TrimEnd('.', ',', ';', ':', '!', '?', '*'); $uri = $null
            if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https' -or -not $uri.Host -or $uri.UserInfo) { continue }
            if (-not @($urls | Where-Object { $_ -ieq $u }).Count -and $urls.Count -lt 9) { $urls.Add($u) }
        }
    }
    if ($status -ne 'UNKNOWN' -and -not $heads.Count) { $why = 'no SOURCES section' }
    @{ status = $status; urls = @($urls); why = $why }
}
# claims resolve through zeitgeistd's own path: @{ code; line }
function Invoke-ClaimResolve([string]$Repo, [string]$Id, [string]$Status, [string[]]$Sources) {
    Invoke-LobeModule $Repo (@('zeitgeistd.claims', 'resolve', $Id, $Status, '--by', 'auto', '--sources') + @($Sources)) -Quiet   # its line is said by the caller
    @{ code = [int]$script:Code; line = [string](@($script:Lines | Where-Object { $_ -match '^zeitgeistd: claims' }) | Select-Object -Last 1) }
}
# The question a work order carries: the claim's statement and its two dates, nothing else (no id, source, URL, Charter, loop or history).
function Get-VerifyQuestion($C) {
    $st = ([string]$C['statement'] -replace '\s+', ' ').Trim() -replace '\{\{', '{ {'   # cook.ps1 refuses {{ in a value
    if (-not $st) { return '' }
    $q = "Claim: $st"
    $made = ConvertTo-Utc $C['ingested']; $due = ConvertTo-Utc $C['due']
    if ($made) { $q += "`nMade: $($made.ToString('yyyy-MM-dd'))" }
    if ($due) { $q += "`nDue: $($due.ToString('yyyy-MM-dd'))" }
    $q
}
# Collect saved answers, then (unless -Only collect) file due public claims. Writes its lines, then returns @{ n (counts); failed (reasons) }
# as its last output; never throws.
function Invoke-LobeVerify([string]$Repo, [bool]$File) {
    $n = [ordered]@{ filed = 0; resolved = 0; unknown = 0; waiting = 0; expired = 0; not_public = 0; too_long = 0 }; $failed = [Collections.Generic.List[string]]::new()
    $lock = New-Object Threading.Mutex($false, 'Local\brain-lobe-verify'); $held = $false
    try {
        try { $held = $lock.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { $failed.Add('another verify run held the work-order list for 60 s'); return @{ n = $n; failed = $failed } }
        New-Item -ItemType Directory -Force -Path $script:AnswerDir | Out-Null
        $orders = [Collections.Generic.List[object]]::new(); foreach ($o in (Read-VerifyOrders)) { $orders.Add($o) }
        $now = (Get-Date).ToUniversalTime()
        # a. collect
        foreach ($o in $orders) {
            if ($o['state'] -ne 'filed') { continue }
            $ans = Join-Path $script:AnswerDir "$($o['job']).md"
            if (-not (Test-Path -LiteralPath $ans -PathType Leaf)) {
                $at = ConvertTo-Utc $o['filed']
                if ($at -and ($now - $at).TotalDays -gt $script:VerifyExpireDays) { $o['state'] = 'expired'; $o['at'] = $now.ToString('o'); $n.expired++; Write-Output "lobe: verify $($o['job']) for claim $($o['claim']): no answer after $($script:VerifyExpireDays) days, let go" }
                continue
            }
            $a = Read-VerifyAnswer $ans
            $r = Invoke-ClaimResolve $Repo ([string]$o['claim']) $a.status $(if ($a.status -eq 'UNKNOWN' -and $a.why) { @($ans) } else { @($a.urls) + @($ans) })   # unparseable: the file only
            $note = $a.why
            if ($r.code -eq 3 -and $a.status -ne 'UNKNOWN') {   # zeitgeistd did not take it as evidence: UNKNOWN, the file kept
                $note = "zeitgeistd refused $($a.status) ($(($r.line -replace '^zeitgeistd: claims refused: ', '').Trim()))"
                $r = Invoke-ClaimResolve $Repo ([string]$o['claim']) 'UNKNOWN' @($ans); $a.status = 'UNKNOWN'
            }
            $o['at'] = $now.ToString('o'); $o['answer'] = $ans
            if ($r.code -eq 0) { $o['state'] = 'resolved'; $o['status'] = $a.status; if ($note) { $o['note'] = $note }; if ($a.status -eq 'UNKNOWN') { $n.unknown++ } else { $n.resolved++ } }
            elseif ($r.code -eq 3) { $o['state'] = 'closed'; $o['note'] = "zeitgeistd refused it: $($r.line)" }   # e.g. the Owner resolved it first
            else {
                $o['tries'] = 1 + [int]$o['tries']
                if ($o['tries'] -ge 3) { $o['state'] = 'failed' }
                $failed.Add("resolve $($o['claim']) exit $($r.code)")
            }
            Write-Output "lobe: verify $($o['job']) for claim $($o['claim']): $($a.status)$(if ($note) { " ($note)" }) -> exit $($r.code)$(if ($r.line) { ": $($r.line)" })"
        }
        Write-VerifyOrders $orders
        if (-not $File) { return @{ n = $n; failed = $failed } }
        # b. file
        Invoke-LobeModule $Repo @('zeitgeistd.claims', 'due', '--public', '--json') -Quiet
        if ($script:Code -ne 0) { $failed.Add("claims due exit $($script:Code)"); return @{ n = $n; failed = $failed } }
        $due = try { @($script:Lines | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1 | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null }
        if ($due -isnot [Collections.IDictionary] -or $due['public'] -ne $true) { $failed.Add('claims due --public gave no public list'); return @{ n = $n; failed = $failed } }
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $filedToday = @($orders | Where-Object { $t = ConvertTo-Utc $_['filed']; $t -and $t.ToLocalTime().ToString('yyyy-MM-dd') -eq $today }).Count
        foreach ($c in @($due['claims'])) {
            if ($c -isnot [Collections.IDictionary]) { continue }
            if ([string]$c['privacy'] -cne 'P0') { $n.not_public++; continue }   # privacy: P1, P2 or none never leave this PC
            $id = [string]$c['id']
            if (-not $id -or $id -match '\s') { $n.not_public++; continue }
            if (@($orders | Where-Object { [string]$_['claim'] -eq $id -and $_['state'] -ne 'expired' }).Count) { continue }
            if ($filedToday -ge $script:VerifyCap) { $n.waiting++; continue }
            $q = Get-VerifyQuestion $c
            if (-not $q -or $q.Length -gt 2900) { $n.too_long++; continue }
            $res = try { (& (Join-Path $kd 'cook.ps1') -Recipe 'lobe-verify' -Vars @{ question = $q } -Json | Out-String).Trim() | ConvertFrom-Json } catch { $null }
            if (-not ($res -and $res.ok -and [string]$res.job -match '^J\d+$')) { $failed.Add("filing claim $id ($(if ($res.error) { $res.error } else { 'no answer from cook.ps1' }))"); continue }
            $orders.Add([ordered]@{ claim = $id; job = [string]$res.job; filed = (Get-Date).ToUniversalTime().ToString('o'); state = 'filed' })
            Write-VerifyOrders $orders   # at once: a crash later never files the same claim twice
            $filedToday++; $n.filed++
            Write-Output "lobe: verify filed work order $($res.job) for claim $id"
        }
    } catch { $failed.Add("verify error: $($_.Exception.Message)") }
    finally { if ($held) { $lock.ReleaseMutex() }; $lock.Dispose() }
    @{ n = $n; failed = $failed }
}
# Use-LobeVerify passes those lines on (Write-Host: the Step log takes every stream) and gives back the hashtable.
function Use-LobeVerify([string]$Repo, [bool]$File) {
    $all = @(Invoke-LobeVerify $Repo $File)
    $all | Where-Object { $_ -isnot [hashtable] } | Write-Host
    $all[-1]
}
function Write-VerifyLine($V) { Write-Output "lobe: verify $(@($V.n.Keys | ForEach-Object { "$_=$($V.n[$_])" }) -join ' ')" }

$script:CountsPath = Join-Path $lobeHome 'yard-counts.json'
$script:VerifyPath = Join-Path $lobeHome 'verify-orders.json'; $script:AnswerDir = Join-Path $lobeHome 'verify'

# ---- memory-check / memory-truth: one bounded script, its exit code into sleep[], always exit 0 (the frame Step still runs) ----
if ($Cmd -in 'memory-check', 'memory-truth') {
    $script:Night = Find-Night; Say-NoNight
    $dir = if ($env:KITCHEN_LOBE_SCRIPTS) { $env:KITCHEN_LOBE_SCRIPTS } else { Join-Path (Split-Path -Parent $kd) 'scripts' }
    $file = Join-Path $dir "$Cmd.ps1"; $sargs = @(if ($Cmd -eq 'memory-check') { '-Quiet' })
    $bounded = Join-Path (Join-Path (Split-Path -Parent $kd) 'scripts') 'run-bounded.ps1'
    $code = $null; $why = ''
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $why = "$file does not exist" }
    else {
        Write-Output "lobe: $Cmd runs $file $($sargs -join ' ') (limit $StepSec s, 1000 MB)"
        $ErrorActionPreference = 'Continue'
        $q = { param($s) "'" + ($s -replace "'", "''") + "'" }   # -ScriptArgs '-Quiet' must reach run-bounded as a value, so -Command, not -File
        $line = "& $(& $q $bounded) -Script $(& $q $file) -TimeoutSeconds $StepSec -MaxMB 1000 -ScriptArgs @($(@($sargs | ForEach-Object { & $q $_ }) -join ', ')); exit `$LASTEXITCODE"
        & (Get-Process -Id $PID).Path -NoProfile -Command $line 2>&1 | ForEach-Object { "$_" }
        $code = [int]$LASTEXITCODE; $ErrorActionPreference = 'Stop'
        $why = switch ($code) { 0 { '' } 124 { "timed out after $StepSec s" } 125 { 'went over 1000 MB' } default { if ($Cmd -eq 'memory-truth' -and $code -eq 3) { 'drift found (see watch\memory.json)' } elseif ($Cmd -eq 'memory-check' -and $code -eq 1) { 'a FAIL in the report' } else { "exit $code" } } }
    }
    $state = if ($code -eq 0) { 'ok' } else { 'failed' }
    Add-Sleep $Cmd $code $sw.ElapsedMilliseconds $state $why
    if ($state -eq 'failed') { Write-Output "lobe: $Cmd FAILED inside the night: $why (named in sleep[]; the frame Step still runs)" }
    Set-SleepBeat
    Write-Output "lobe: $Cmd done exit=$(if ($null -ne $code) { $code } else { 'none' }) ms=$($sw.ElapsedMilliseconds)"
    exit 0
}

$repo = Find-LobeRepo
foreach ($e in @($script:Plan[$Cmd] | Where-Object { -not $_.add })) {
    $rel = ($e.mod[0] -split '\.') -join [IO.Path]::DirectorySeparatorChar; $rel += '.py'
    if (-not (Test-Path -LiteralPath (Join-Path $repo.path $rel) -PathType Leaf)) { Stop-Lobe "$($e.mod[0]) is not in the checkout at $($repo.path) yet ($rel is missing)" }
}
Write-Output "lobe: $Cmd with the checkout at $($repo.path) (from $($repo.from)); ZEITGEISTD_HOME=$lobeHome"
New-Item -ItemType Directory -Force -Path $lobeHome | Out-Null
$c = Set-LobeConfig $lobeHome $beat
if ($c.err) { Stop-Lobe $c.err }
if ($c.said) { Write-Output "lobe: $($c.said)" }
$strong = $c.cfg['models.strong']; $hasStrong = $strong -is [string] -and $strong.Trim()
$env:ZEITGEISTD_HOME = $lobeHome; $env:UV_PYTHON_PREFERENCE = 'only-managed'
# MONEY and privacy: the lobe never gets a per-token key; KITCHEN_OLLAMA_URL stays (its client refuses any address off this PC)
foreach ($k in @($script:KeyVars + @(Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)_(API_KEY|AUTH_TOKEN)$' } | ForEach-Object Name))) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
if ($Cmd -eq 'rem') { Open-Night }
elseif ($Cmd -eq 'csf' -and $env:KITCHEN_JOB) { $script:Night = Find-Night; Say-NoNight }   # csf by hand (no work order) leaves the night alone

$gpu = $null; $held = $false
if ($Cmd -in $script:ModelCmds) {
    $g = Test-LobeGates $MinFreeMB
    if ($g.note) { Write-Output "lobe: $($g.note)" }
    if ($g.why) { Skip-Lobe $repo.path $g.why $g.code $g.kind }
    if ($Cmd -eq 'rem') {
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($repo.path, 'zeitgeistd', 'governor.py')) -PathType Leaf)) {
            Write-Output 'lobe: rem: the governor is not in the checkout yet (zeitgeistd\governor.py); not asked'
            Add-Sleep 'governor check' $null 0 'absent' 'zeitgeistd\governor.py is not in the checkout'
        } else {
            $gs = [Diagnostics.Stopwatch]::StartNew(); Invoke-LobeModule $repo.path @('zeitgeistd.governor', 'check', '--run', 'rem'); $gc = [int]$script:Code
            if ($gc -eq 11) { Add-Sleep 'governor check' 11 $gs.ElapsedMilliseconds 'waits'; Skip-Lobe $repo.path 'the governor said wait (governor check --run rem exit 11)' 11 -Beaten }
            if ($gc -ne 0) { Add-Sleep 'governor check' $gc $gs.ElapsedMilliseconds 'failed' 'refused or failed; its reason is in the heartbeat'; Stop-Lobe "governor check --run rem exit $gc (refused or failed: its reason is above and in the heartbeat; rem did not run)" }
            Add-Sleep 'governor check' 0 $gs.ElapsedMilliseconds 'ok'
        }
    }
    $gpu = New-Object Threading.Mutex($false, 'Global\brain-kitchen-gpu')
    try { $held = $gpu.WaitOne([math]::Max(0, $GpuWaitSec) * 1000) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { $gpu.Dispose(); Skip-Lobe $repo.path "the graphics card is busy with another local model run (waited $GpuWaitSec s)" 11 'gpu' }
}
if ($Cmd -eq 'verify') {
    $v = Use-LobeVerify $repo.path ($Only -ne 'collect'); Write-VerifyLine $v
    if ($v.failed.Count) { Stop-Lobe ($v.failed -join '; ') }
    Write-Output "lobe: verify done items=$($v.n.filed + $v.n.resolved + $v.n.unknown) dropped=$($v.n.not_public + $v.n.too_long) ms=$($sw.ElapsedMilliseconds)"
    exit 0
}
$failed = @(); $first = 0; $counts = @{ items = 0; dropped = 0 }; $nightSaid = @()
try {
    foreach ($e in $script:Plan[$Cmd]) {
        $rel = (($e.mod[0] -split '\.') -join [IO.Path]::DirectorySeparatorChar) + '.py'
        if ($e.add -and -not (Test-Path -LiteralPath (Join-Path $repo.path $rel) -PathType Leaf)) {
            Write-Output "lobe: $Cmd`: $($e.name) is not in the checkout yet ($rel); not run"
            Add-Sleep $e.name $null 0 'absent' "$rel is not in the checkout"; $nightSaid += "$($e.name) absent"; continue
        }
        if ($e.model -and -not $hasStrong) {
            Write-Output "lobe: $Cmd`: $($e.name) is off: the lobe's config.json has no models.strong (the Owner turns it on)"
            Add-Sleep $e.name $null 0 'off' 'models.strong is not set in the lobe config.json (the Owner turns it on)'; $nightSaid += "$($e.name) off"; continue
        }
        $ms = [Diagnostics.Stopwatch]::StartNew()
        Invoke-LobeModule $repo.path $e.mod
        $code = [int]$script:Code
        if ($code -eq 0) {
            Add-Sleep $e.name 0 $ms.ElapsedMilliseconds 'ok'; $nightSaid += "$($e.name) 0"
            if ($Cmd -in $script:ModelCmds -and $e.mod[0] -eq "zeitgeistd.$(if ($Cmd -eq 'sweep') { 'gate' } else { $Cmd })") { $counts = Get-LobeCounts $Cmd $script:Lines }
            continue
        }
        if ($e.wait -and $code -eq 11) {
            Write-Output "lobe: $Cmd`: $($e.name) waits (the governor said skip; its candidates stay for the next night)"
            Add-Sleep $e.name 11 $ms.ElapsedMilliseconds 'waits' 'the governor said skip'; $nightSaid += "$($e.name) waits"; continue
        }
        Add-Sleep $e.name $code $ms.ElapsedMilliseconds 'failed'; $nightSaid += "$($e.name) $code"
        if ($e.add) { Write-Output "lobe: $Cmd`: $($e.name) FAILED with exit $code (named in sleep[] and the heartbeat; the rest still run)"; continue }
        $failed += "$($e.name) exit $code"; if (-not $first) { $first = $code }
        if ($e.mod[0] -eq 'zeitgeistd.db') { break }   # nothing else works without the store
    }
} finally { if ($held) { $gpu.ReleaseMutex() }; if ($gpu) { $gpu.Dispose() } }
if ($script:Night -and $Cmd -eq 'csf') {
    $a = Get-ArchiveNote; Write-Output "lobe: $($a.why)"
    Add-Sleep 'archive' $null 0 $a.state $a.why
    $script:Night.closed = Iso (Get-Date); Save-Night
}
if ($Cmd -in 'rem', 'csf') { Write-Output "lobe: $Cmd steps: $($nightSaid -join ', ')" }
if ($failed.Count) { Stop-Lobe ($failed -join '; ') $(if ($first -in 10, 11) { 1 } else { $first }) }
if ($Cmd -eq 'rem') {
    # After the core rem (and causal run, which needs the GPU lock and comes right after rem, ZG-26), the lock is released, then:
    #   1. ZG-21 verify: no model, no lock. It runs after claims run (the night step before rem that applies the Owner's taps), so an
    #      Owner's own ruling is in before a Cloud crew answer is offered as evidence, and after rem, so the due list is the consolidated one.
    #   2. ZG-17 push last: its counts then include everything this night did.
    # Neither changes rem's exit code; verify's result is a night step in sleep[] (ok, failed or absent).
    if (Test-Path -LiteralPath ([IO.Path]::Combine($repo.path, 'zeitgeistd', 'claims.py')) -PathType Leaf) {
        $vs = [Diagnostics.Stopwatch]::StartNew(); $v = Use-LobeVerify $repo.path $true; Write-VerifyLine $v
        if ($v.failed.Count) { Write-Output "lobe: verify FAILED ($($v.failed -join '; ')); rem itself is done"; Add-Sleep 'verify' $null $vs.ElapsedMilliseconds 'failed' ($v.failed -join '; ') }
        else { Add-Sleep 'verify' $null $vs.ElapsedMilliseconds 'ok' "filed $($v.n.filed), resolved $($v.n.resolved), unknown $($v.n.unknown)" }
    } else { Write-Output 'lobe: verify not run (zeitgeistd.claims is not in the checkout yet)'; Add-Sleep 'verify' $null 0 'absent' 'zeitgeistd\claims.py is not in the checkout' }
    Send-LobePush   # ZG-17: counts only, at most once a day; never changes this run's result
}
Set-SleepBeat
Write-Output "lobe: $Cmd done items=$($counts.items) dropped=$($counts.dropped) ms=$($sw.ElapsedMilliseconds)"
exit 0
