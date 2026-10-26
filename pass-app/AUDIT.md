# Chef app audit (2026-10-13)

What the 1.x app (the "Pass") got wrong, and what Chef 2 does instead. Severity: H = could cause a wrong action or an outage, M = slows Jordan down or hides something important, L = polish.

## Safety and trust
| # | Sev | Finding (1.x) | Fix (2.0) |
|---|---|---|---|
| 1 | H | Sign off was one tap with no context: you approved without seeing what you were approving. | Sign-off opens a confirmation quoting the exact approval text; a privacy hold says so and explains that the yes covers one step. |
| 2 | H | One oversized request left the server waiting forever (the body reader destroyed the socket without answering). | Bodies over 16 KB get a 413 and the connection is drained. |
| 3 | H | Any error inside a request handler could stop the whole server. | Every handler is guarded (500 with the server still running), plus process-level guards; the supervisor watchdog restarts it if it ever stops. |
| 4 | M | Security headers were missing (no Permissions-Policy, COOP/CORP, HSTS, base-uri). | Added; CSP still allows only the app's own scripts. |
| 5 | M | No limit on live connections. | At most 20 live streams; extras get 503. |
| 6 | M | No record in the app of who did what. | Audit trail (from pass-actions.jsonl, with failures and errors) in the Kitchen menu. |

## Seeing what's going on
| # | Sev | Finding (1.x) | Fix (2.0) |
|---|---|---|---|
| 7 | M | No job detail: steps, past attempts, costs and the sous chef's reasons were invisible. | Job sheet: step timeline, each run with outcome (done / held / waited / failed), cook, model, cost, cooks tried, and the sous chef's reason; full prompt per step; history. |
| 8 | M | "Output" showed only the newest log of a job. | Output of any single run, with follow mode while it cooks. |
| 9 | M | Whole screen redrawn every second: scroll jumped, taps could miss, screen readers were spammed. | Each view renders only when its own data changes; clocks and progress bars update in place. |
| 10 | M | Only the first variable of a recipe could be filled (e.g. improve's repo was fixed). | Order form built from the recipe: every variable, defaults, required marks, length counters, validation, drafts kept. |
| 11 | M | No way to know where an order would go before sending it. | "Preview decision": the sous chef decides (nothing sent) and shows cook, privacy and reasons. |
| 12 | M | Set-aside jobs could only be looked at. | Requeue (chef only; bots can't), with a warning that the step runs again. |
| 13 | M | No filter or search; "Plated" capped at 10. | Jobs: search and filters with counts; Activity: filters (problems, approvals, cooks, jobs), search, pause with a count of held events, older history loaded. |
| 14 | M | A sign-off or order waited up to a minute for the next supervisor pass. | The server runs one pass right away after a sign-off, order or requeue. |
| 15 | L | Notification permission was asked on the first tap anywhere. | Asked only from the Kitchen menu; alerts when a new job needs you while Chef is in the background; app-icon badge where supported. |
| 16 | L | No deep links; the back button left the app. | Hash routes for every view and job; back closes the job sheet. |
| 17 | L | Status shown by color alone in places; small touch targets. | Status = icon + word + color; 44 px targets; tab roles, labelled dialogs, live regions, reduced motion. |
| 18 | L | Offline = browser error page. | Service worker keeps the app shell; the app opens and says it can't reach the kitchen. |

Tests: `tests/Test-PassApp.ps1` covers each server fix (51 checks).
