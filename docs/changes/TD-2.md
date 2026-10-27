# TD-2: kitchen.repo.json names its Site

Floor TD-2 of Site TD (TD Pour 1), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 1.2 and the Floor table.
Branch `ms-td2-repo-site`, stacked on TD-1 (`ms-td1-site-ids`, PR #118) at `f638484`, built 2026-10-24 22:54 UTC.
Merges after #118.

## What it does

- `kitchen/repo-config.ps1` reads an optional `"site"` key in `kitchen.repo.json`. The config result gains `Site` (`''` when the
  key is absent).
- Known codes: `GW` (Demo Project), `JH` (Job hunt), `TD` (Tide), from the Glossary, and `ZG` (zeitgeistd, the Owner's yes to Q7). Exact
  capitals only. The list sits in `$script:RepoSiteCodes` until the Sites registry (`kitchen.json` `sites`, TD-7) replaces it.
- Anything else is refused, fail closed like every other key, with a reason that names the file:
  `kitchen.repo.json (<path>): 'site' 'XX' is not a known Site code; it must be one of GW, JH, TD, ZG, exact capitals (a new Site
  is added to the registry first)`. A number, a list, an object, an empty string, `td` and `" TD"` are all refused.
- No `site` key = Unassigned and works exactly as today. A test reads one config with every key, with and without `site`, and
  checks that only `Site` differs.
- tide's own `kitchen.repo.json` now says `"site": "TD"` (a test checks it). Since review #11 (F3) this key alone only tags tide's
  orders (the Board chip, status groups): fair share, per-Site Stop-work and the CI count all need a Sites registry too.

Nothing reads `Site` yet. TD-3 uses it to set `vars.site` when an order is added.

## Two bugs found on the way (fixed here)

- **Every "bad config" case in Test-RepoConfig proved nothing.** The loop variable was `$b`, and `Throws` has its own parameter
  `$b`. So inside `Throws { Cfg $b.Value }`, `$b.Value` was `$null`, every case wrote an empty file, and every case "failed closed"
  for the wrong reason. Renamed the loop variable to `$bc`, and the check now also requires that the message is not the empty-file one.
- **A `kitchen.repo.json` whose root is a list (`[1]`) was accepted.** `-isnot [pscustomobject]` doesn't work on pipeline output,
  because PowerShell wraps it in a PSObject. Now checked against `[Management.Automation.PSCustomObject]`. The fixed loop exposed it.

## Demo Project: the Owner's step, not done here

Demo Project's repo (`%USERPROFILE%\demo-project`) was not touched. Demo Project is paused, and its `kitchen.repo.json` is protected
and frozen for edits until 2026-10-28 18:00 local time. On the evening of 10-28, after 18:00 local time, the Owner adds this line to the top-level
object of `%USERPROFILE%\demo-project\kitchen.repo.json`:

```
  "site": "GW",
```

Until then the Demo Project Tower is Unassigned, and nothing is refused for that.

## Test results (real runs, 2026-10-24, this PC, each through scripts/run-bounded.ps1, one at a time)

| Suite | Result |
|---|---|
| Test-RepoConfig | 122 passed, 0 failed |
| Test-Roadmap | 140 passed, 0 failed |
| Test-Standards | 20 passed, 0 failed |
| Test-Names | 31 passed, 0 failed |
| Test-Quality | 20 passed, 0 failed |
| Test-BrainMonitor | 61 passed, 0 failed, 0 skipped |
| scripts/check-standards.ps1 -Root (worktree) | 0 new (24 baselined) |

## Broken on purpose (each one caught, then restored)

| Break | Caught by |
|---|---|
| Unknown codes accepted (`if ($false)`) | 5 checks: the named-file message check and the XX, td, " TD" and "" cases |
| Case-insensitive match (`-notin` for `-cnotin`) | the `td` case |
| A config with no key gets `Site = 'TD'` | "absent file has no Site", and "only Site differs" |
| The old root check (`[pscustomobject]`) | the `[1]` root case |
