# Tests for Chef's sign-in hardening (pass-app/server.mjs, security audit 2026-10-22): session cookie, key-in-link refusal, sign-in form, lockout, headers, strict CSP.
# Run by the kitchen tests station (globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Private kitchen root under TEMP, own port; self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('chef-sec-test-' + [guid]::NewGuid().ToString('N'))
$port = Get-Random -Minimum 20000 -Maximum 40000
$tsHost = 'chef-box.tailnet-test.example'
New-Item -ItemType Directory -Force "$root\kitchen", "$root\career", "$root\income" | Out-Null
$env:BRAIN_KITCHEN = "$root\kitchen"; $env:PASS_PORT = "$port"; $env:PASS_NO_TAILSCALE = '1'; $env:PASS_HOSTS = $tsHost; $env:PASS_NO_KICK = '1'
$env:PASS_CAREER_DIR = "$root\career"; $env:PASS_INCOME_DIR = "$root\income"; $env:BRAIN_NTFY_TOPIC = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$base = "http://127.0.0.1:$port"
$h = [Net.Http.HttpClientHandler]::new(); $h.AllowAutoRedirect = $false; $h.UseCookies = $false
$nc = [Net.Http.HttpClient]::new($h); $nc.Timeout = [TimeSpan]::FromSeconds(15)
# one request: status, Set-Cookie, a header lookup and the body text (no cookie jar, no redirects: every test says what it sends)
function Req($method, $path, $headers = @{}, $form = $null) {
    $m = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method), "$base$path")
    foreach ($k in $headers.Keys) { if ($k -eq 'Host') { $m.Headers.Host = $headers[$k] } else { [void]$m.Headers.TryAddWithoutValidation($k, $headers[$k]) } }
    if ($null -ne $form) { $m.Content = [Net.Http.StringContent]::new($form, [Text.Encoding]::UTF8, 'application/x-www-form-urlencoded') }
    try { $r = $nc.SendAsync($m).GetAwaiter().GetResult() } catch { return [pscustomobject]@{ Code = -1; Cookie = ''; Text = ''; R = $null } }
    $ck = ''; $v = $null; if ($r.Headers.TryGetValues('Set-Cookie', [ref]$v)) { $ck = $v -join ' ' }
    [pscustomobject]@{ Code = [int]$r.StatusCode; Cookie = $ck; Text = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); R = $r }
}
function Hdr($res, $name) { $v = $null; if ($res.R.Headers.TryGetValues($name, [ref]$v) -or $res.R.Content.Headers.TryGetValues($name, [ref]$v)) { $v -join ' ' } else { '' } }
function NewHex($bytes) { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes($bytes)).ToLower() }   # secret-looking values only at runtime
# a session signed the way the server signs one, so an expired one can be made without waiting 30 days
function Forge($key, $exp) {
    $nonce = NewHex 16; $hm = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($key))
    "$exp.$nonce." + [Convert]::ToHexString($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes("chef-session|$exp|$nonce"))).ToLower()
}
$srv = $null
try {
    # started through ProcessStartInfo (as Test-PassApp does; not Start-Process, which the lint forbids without -Wait); the finally block stops it
    $psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $psi.Arguments = "/c node `"$(Join-Path $repo 'pass-app\server.mjs')`" > `"$root\out.txt`" 2> `"$root\err.txt`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $srv = [Diagnostics.Process]::new(); $srv.StartInfo = $psi; [void]$srv.Start()
    for ($i = 0; $i -lt 60 -and (Req GET '/api/health').Code -ne 200; $i++) { Start-Sleep -Milliseconds 250 }
    if ((Req GET '/api/health').Code -ne 200) { throw "Chef did not start on port ${port}: $(Get-Content "$root\err.txt" -Raw -ErrorAction SilentlyContinue)" }
    $key = (Get-Content "$root\kitchen\pass-key.txt" -Raw).Trim()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $login = Req POST '/login' @{} "key=$key"
    $sess = if ($login.Cookie -match 'pass=([^;]+)') { $Matches[1] } else { '' }
    Check 'cookie: the session cookie never carries the pass key' ($login.Code -eq 303 -and $sess -match '^\d{10}\.[0-9a-f]{32}\.[0-9a-f]{64}$' -and -not $login.Cookie.Contains($key) -and $login.Cookie -match 'HttpOnly' -and $login.Cookie -match 'Secure' -and $login.Cookie -match 'SameSite=Strict' -and $login.Cookie -match 'Max-Age=2592000')
    Check 'cookie: a session cookie gets in' ((Req GET '/api/state' @{ Cookie = "pass=$sess" }).Code -eq 200)
    Check 'cookie: the raw pass key as a cookie is refused' ((Req GET '/api/state' @{ Cookie = "pass=$key" }).Code -eq 401)
    $p = $sess.Split('.'); $flip = if ($p[2][0] -eq 'a') { 'b' } else { 'a' }
    Check 'cookie: a tampered session is refused' ((Req GET '/api/state' @{ Cookie = "pass=$($p[0]).$($p[1]).$flip$($p[2].Substring(1))" }).Code -eq 401 -and (Req GET '/api/state' @{ Cookie = "pass=$([long]$p[0] + 86400).$($p[1]).$($p[2])" }).Code -eq 401)
    Check 'cookie: an expired session is refused (a fresh one made the same way gets in)' ((Req GET '/api/state' @{ Cookie = "pass=$(Forge $key ($now - 60))" }).Code -eq 401 -and (Req GET '/api/state' @{ Cookie = "pass=$(Forge $key ($now + 3600))" }).Code -eq 200)

    # GET /login?key= is gone: from the PC (127.0.0.1, localhost) and from the tailnet it only shows the form, never a cookie
    $links = @(@{}, @{ Host = "localhost:$port" }, @{ Host = $tsHost }) | ForEach-Object { Req GET "/login?key=$key" $_ }
    Check 'link: GET /login?key= no longer signs in from anywhere (form instead, no cookie)' (@($links | Where-Object { $_.Code -ne 200 -or $_.Cookie -or $_.Text -notmatch '<form method="post" action="/login">' -or $_.Text -notmatch 'never takes the key from a link' }).Count -eq 0)
    Check 'link: server.mjs never reads a key from the query string' ((Get-Content (Join-Path $repo 'pass-app\server.mjs') -Raw) -notmatch "searchParams\.get\('key'\)")
    $form = Req POST '/login' @{ Host = $tsHost; Origin = "https://$tsHost" } "key=$key"
    $fs = if ($form.Cookie -match 'pass=([^;]+)') { $Matches[1] } else { '' }
    Check 'form: the key in a POST body signs in from the tailnet' ($form.Code -eq 303 -and $fs -and (Req GET '/api/state' @{ Host = $tsHost; Cookie = "pass=$fs" }).Code -eq 200)
    # a browser posts the form with "Origin: null" when the page says Referrer-Policy no-referrer; the form page must say same-origin
    Check 'form: the sign-in page lets the browser send its real Origin (Referrer-Policy same-origin)' ((Hdr (Req GET '/login') 'Referrer-Policy') -eq 'same-origin' -and (Req POST '/login' @{ Origin = "http://127.0.0.1:$port" } "key=$key").Code -eq 303)
    Check 'form: a sign-in POST from a foreign Origin is refused' ((Req POST '/login' @{ Origin = 'https://evil.example' } "key=$key").Code -eq 403)

    $st = Req GET '/api/state' @{ Authorization = "Bearer $key" }
    Check 'headers: API answers are no-store, nosniff, referrer same-origin only, frame-ancestors none' ((Hdr $st 'Cache-Control') -eq 'no-store' -and (Hdr $st 'X-Content-Type-Options') -eq 'nosniff' -and (Hdr $st 'Referrer-Policy') -eq 'same-origin' -and (Hdr $st 'Content-Security-Policy') -match "frame-ancestors 'none'")
    $csp = Hdr (Req GET '/' @{ Authorization = "Bearer $key" }) 'Content-Security-Policy'
    Check "csp: no unsafe-inline for styles (style-src 'self' only) and none anywhere" ($csp -match "(^|; )style-src 'self';" -and $csp -notmatch 'unsafe-inline')
    $pub = Join-Path $repo 'pass-app\public'
    $noStyle = @(Get-ChildItem $pub -File | Where-Object { $_.Extension -in '.js', '.html' } | ForEach-Object Name) | Where-Object { (Get-Content (Join-Path $pub $_) -Raw) -match '(?i)\sstyle\s*=\s*["''$]' }
    Check 'csp: no script or page in public/ has style= markup strings (app.js, scene.js, live.js, index.html...); markup says data-css' (@($noStyle).Count -eq 0 -and (Get-Content (Join-Path $pub 'app.js') -Raw) -match 'data-css="')
    $scn = Get-Content (Join-Path $pub 'scene.js') -Raw; $apj = Get-Content (Join-Path $pub 'app.js') -Raw
    Check 'csp: data-css is applied through style.setProperty on every added node' ($scn -match "export function applyCss" -and $scn -match "el\.style\.setProperty\(" -and $apj.Contains('new MutationObserver((ms) => { for (const m of ms) for (const n of m.addedNodes) applyCss(n); })'))
    Check 'markup: server numbers named by the audit go in through Number()' (@(@('b.applied', 'b.interviews', 'c.add', 'c.del', 'c.windowHours', 'j.step', 'x.exit') | Where-Object { -not $apj.Contains('Number(' + $_ + ')') }).Count -eq 0)
    $wake = Invoke-RestMethod "$base/api/action" -Method Post -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body '{"op":"wake","name":"-Why"}'
    Check 'cook name: a leading dash (a pwsh parameter) is refused' (-not $wake.ok -and $wake.error -eq 'bad crew name')
    Check 'log: a failed request logs its path only, never the query' ((Get-Content (Join-Path $repo 'pass-app\server.mjs') -Raw) -match "console\.error\('request failed:', String\(req\.url\)\.split\('\?'\)\[0\]")

    $newKey = NewHex 32; Set-Content "$root\kitchen\pass-key.txt" $newKey -NoNewline
    Check 'key rotation: replacing pass-key.txt signs every session out' ((Req GET '/api/state' @{ Cookie = "pass=$sess" }).Code -eq 401 -and (Req GET '/api/state' @{ Cookie = "pass=$(Forge $newKey ($now + 3600))" }).Code -eq 200)

    $wrong = @(1..10 | ForEach-Object { (Req POST '/login' @{} "key=$(NewHex 32)").Code })
    Set-Content "$root\kitchen\pass-users.txt" 'chef@example.com'
    Check 'lockout: after 10 wrong keys sign-in pauses (429, even the right key); a Tailscale login still gets in' (@($wrong | Where-Object { $_ -ne 401 }).Count -eq 0 -and (Req POST '/login' @{} "key=$newKey").Code -eq 429 -and (Req GET '/api/state' @{ Host = $tsHost; 'Tailscale-User-Login' = 'chef@example.com' }).Code -eq 200)
} finally {
    $nc.Dispose()
    if ($srv -and -not $srv.HasExited) { & taskkill.exe /PID $srv.Id /T /F 2>&1 | Out-Null }
    foreach ($v in 'BRAIN_KITCHEN', 'PASS_PORT', 'PASS_NO_TAILSCALE', 'PASS_HOSTS', 'PASS_NO_KICK', 'PASS_CAREER_DIR', 'PASS_INCOME_DIR') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "ChefSecurity tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
