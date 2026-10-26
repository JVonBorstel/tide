# Jordan's Kitchen: one-word commands. Run `just` to list them. Works from any folder: `just -f <this repo>\justfile <cmd>`
set shell := ["pwsh", "-NoProfile", "-Command"]
set windows-shell := ["pwsh", "-NoProfile", "-Command"]

k := justfile_directory() + "/kitchen/kitchen.ps1"
kroot := env_var("LOCALAPPDATA") + "/brain-kitchen"

# list the commands
default:
    @just --list --unsorted --justfile "{{justfile()}}"

# what's cooking: jobs, failure rate, recent alerts
status:
    @& "{{k}}" status

# open the live board (reloads itself every 10 s)
board:
    @& "{{k}}" report -HtmlPath "{{kroot}}/board.html" | Out-Null; Invoke-Item "{{kroot}}/board.html"

# 60-second swarm demo: 10 misbehaving agents, all caught
demo:
    @& "{{justfile_directory()}}/kitchen/demo.ps1" -Open

# sign off on a waiting job, e.g. `just approve J3`
approve id:
    @& "{{k}}" approve -Id {{id}}

# stop one job, e.g. `just kill J3`
kill id:
    @& "{{k}}" kill -Id {{id}}

# stop everything now
stop-all:
    @& "{{k}}" kill -All

# watch the line live for N seconds
watch seconds="60":
    @& "{{k}}" watch -Seconds {{seconds}}

# self-check, backup, damaged files
doctor:
    @& "{{k}}" doctor

# queue a real research agent (read-only web tools), e.g. `just research "compare X and Y"`
research $question:
    @& "{{justfile_directory()}}/kitchen/cook.ps1" -Recipe research -Vars @{ question = $env:question }

# the recipe book
recipes:
    @& "{{justfile_directory()}}/kitchen/cook.ps1" -List

# the kitchen improves a repo (default: itself): plan, build on a branch, test, taste, then waits for your yes to merge
improve $goal:
    @& "{{justfile_directory()}}/kitchen/cook.ps1" -Recipe improve -Vars @{ goal = $env:goal }

# a taster reviews a repo and reports, changes nothing, e.g. `just review "security of the Chef app"`
review $focus:
    @& "{{justfile_directory()}}/kitchen/cook.ps1" -Recipe review -Vars @{ focus = $env:focus }
# ask the kitchen anything; the sous chef picks the cook, personal orders stay on this PC, e.g. `just ask "draft a thank-you note"`
ask $question:
    @& "{{justfile_directory()}}/kitchen/cook.ps1" -Recipe ask -Vars @{ question = $env:question }

# the cooks: who is ready, resting, signed out, usage per window, track record
cooks:
    @& "{{justfile_directory()}}/kitchen/sous-chef.ps1" board

# what would the sous chef do with this order (decides only; nothing is sent), e.g. `just sous "write my mom a birthday note"`
sous $order:
    @& "{{justfile_directory()}}/kitchen/sous-chef.ps1" pick -Prompt $env:order -Tools none

# bring a resting cook back on the line, e.g. `just wake claude`
wake name:
    @& "{{justfile_directory()}}/kitchen/sous-chef.ps1" wake -Name {{name}}

# run the model scout now (it also runs weekly by itself): what's new in AI models vs what this kitchen uses
scout:
    @& "{{justfile_directory()}}/kitchen/cook.ps1" -Recipe scout
# read a job's output, e.g. `just log J3`
log id:
    @Get-ChildItem "{{kroot}}/run" -Filter "{{id}}-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content

# live AI cooks on (spends plan usage)
live-on:
    @Set-Content "{{kroot}}/LIVE" "on since $(Get-Date -Format o)"; "live agents ON"
# live AI cooks off
live-off:
    @Remove-Item "{{kroot}}/LIVE" -ErrorAction SilentlyContinue; "live agents OFF"

# open the Pass app (your phone app) on this PC: the pass key goes on the clipboard; paste it into the sign-in form (Chef never takes it from a link)
pass:
    @Set-Clipboard (Get-Content "{{kroot}}/pass-key.txt" -Raw).Trim(); Start-Process "http://127.0.0.1:7878/login"; "pass key copied: paste it into the sign-in form"

# the Pass on your phone: Tailscale HTTPS, signs you in with your Tailscale account (no key)
pass-link:
    @$n = try { ((tailscale status --json | ConvertFrom-Json).Self.DNSName).TrimEnd('.') } catch { '' }; if (-not $n) { $n = '<this-pc>.<your-tailnet>.ts.net' }; "https://$n/   (Tailscale on, signed in as a login listed in pass-users.txt)"

# put a new Chef server live safely (trial run first; skips the restart when only app files changed)
pass-update:
    pwsh -NoProfile -File pass-app/update.ps1

# a throwaway Chef with sample orders on port 7999, for looking at changes (real kitchen untouched)
pass-demo:
    pwsh -NoProfile -File pass-app/demo.ps1

# is the 24/7 supervisor running? (task name from scripts/task-names.json)
health:
    @$n = @((Get-Content "{{justfile_directory()}}/scripts/task-names.json" -Raw | ConvertFrom-Json).supervisor); [array]::Reverse($n); @($n | ForEach-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue })[0] | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime | Format-List; & "{{justfile_directory()}}/scripts/kitchen-check.ps1"

# every test across all repos (~5 min)
verify:
    @& "{{justfile_directory()}}/scripts/verify-all.ps1"

# rebuild the boot pack for the next session
handoff:
    @& "{{justfile_directory()}}/scripts/handoff.ps1"
