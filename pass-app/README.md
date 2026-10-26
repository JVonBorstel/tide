# The Board (code: `pass-app/`): Jordan's phone app for the Yard

The Board is a private phone app (installable from the browser) to watch and run the Yard (code: `kitchen`) from anywhere. Design: [DESIGN.md](DESIGN.md). Audit of the old app and what changed: [AUDIT.md](AUDIT.md).
Names: `gemini-brain/projects/tide/naming/GLOSSARY.md`. Screen names, status words and buttons below use the approved names. A few screen words have not caught up yet; they are listed in [DESIGN.md](DESIGN.md) ("Words").

| Where | What it does |
|---|---|
| Board | One list: Needs sign-off (approve / reject with the exact ask), Building (live clock; Inspection while the tests or check step runs), Queued, the bench (Failed or Stopped; retry), Handed over. Tap any work order (code: ticket) for its Steps, the Dispatcher's (code: `sous-chef.ps1`) reasons, costs, logs and history. |
| City (top of the Board) | Every project on this PC as a pixel building (`public/city.js`, drawn from `/api/towers` and the live state): a Tower per repo with merged PRs, one floor each on one shared height scale; cranes for open PRs (their CI tag), crews in their colours, pallets for queued work, a beacon for a sign-off, scaffolding for a red main, the gate (PAUSED or OPEN), the budget meter, the Office and the Yard lot. The sky is the real hour. Tap (i) for "What am I looking at?" (only the marks on screen). **Zoom by levels** (`public/city-nav.js`): tap a building (or its name) for `#/city/<key>`, swipe sideways for the next one, pinch out on a building or in to go back; Back, Esc and the breadcrumb (City › Tide) zoom out one level. The camera moves 280 ms in, 220 ms out; under reduced motion it cuts. Under reduced motion it is one still picture, redrawn each minute. Every other tab shows a 40 px **horizon strip** under the header: quiet unless something needs you; tap it for the Board. |
| Talk | Chat with the Yard. Each message goes through the Dispatcher: personal things go to the Home crew (code: the `local` cook) and the whole chat stays on this PC from then on (or tap the lock first); the rest goes to Claude or Google on your plans, moved by plan use. "AI crews" off = the Home crew still talks. The chat remembers what was said (the last ~10,000 characters go with each message). The crew has no tools and can only suggest a work order from the Specs (code: `recipes/`), shown as a card: nothing runs until you tap the card's "Place work order" button. Chats live in `<kitchen>\talk`; the audit trail notes each message, never its words. Engine: `kitchen/talk.ps1`. |
| Job hunt (briefcase, top right) | Your applications: saved, applied, interviewing, offer, not this time, closed. Marking one applied sets a follow-up in 7 days; due follow-ups show on the Board and on the briefcase. The newest job scout roles are listed under it: Save, Mark applied (adds it as applied with a 7-day follow-up), Open, or Tailor (opens the private tailor work order, filled in). Kept in `gemini-brain/projects/career/tracker.json`; never leaves the PC. |
| Brief | On the Board every morning (5am to 1pm, until you tap Got it; tap Brief any time): waiting for your sign-off, follow-ups due and coming up in the next 3 days (today / overdue / in N days), new scout roles, handed over and failed overnight, plan use. Built from the Yard's own files: no AI, free, private. |
| Since you looked | A line under the headline: "Since 19:40: 2 handed over, 1 failed, 1 needs sign-off" (tap it for the work orders). Each phone keeps the moment the Board last went out of sight (`chef.lastSeen`, on the phone only); the server counts from `events.jsonl` (`/api/since?t=`), reading only the bytes added since its last read. A work order counts once; "needs sign-off" is an ask that came in since then and is still waiting. "Unknown" on a first visit or when the log does not reach back that far. The brief carries the same line. Work order numbers only, never a work order's words. |
| Stuck-loop alarm | A work order whose current step failed (or was sent back) twice since that step last finished: a red line at the top of the Board ("WO-0193 failed the same step twice (ci-wait)"), a "stuck ×2" chip on its row and a line in the brief. Counted from the job's own history, no new data. The Retry button says why: the count and the last failure (kind only for a private work order). |
| Fix what breaks | When a work order fails, the Yard places a read-only Diagnose work order ("AI crews" on; 3 a day; never for old failures or for a diagnosis). Its answer explains the cause; if a code change would fix it, Make this fix sends that goal to Improve, which still merges only with your sign-off. Any work order on the bench also has Find the fix. A work order with private steps gets a private diagnosis. |
| Push alerts (Settings) | Off until you turn them on. Uses the free ntfy app and a random topic made on the PC. Only short words leave the PC ("J12 needs your yes", "Morning brief: 3 new roles"), never what a work order or chat says. |
| Activity | Everything that happened, in plain sentences; filter to what needs you or what failed. |
| Crews | Claude, Gemini and the Home crew: status, usage, 7-day history, track record; wake or rest a crew. The Dispatcher's privacy settings. |
| New work order | Any Spec, every field; pick the crew or let the Dispatcher; Private work order keeps it on this PC; one "Send to the Yard"; a live preview says where it will go. |
| Screen peek, Settings | View-only picture of the PC (Take control is Chrome Remote Desktop). "AI crews" on/off, run the Walkround (code: supervisor) or doctor, alerts, audit trail, stop everything. |

## Private by design
- Listens only on 127.0.0.1. Your phone reaches it over Tailscale HTTPS (`tailscale serve --bg 7878`) at https://<this-pc>.<your-tailnet>.ts.net, signed in by your Tailscale account (pass-users.txt). Never on the open LAN or internet.
- Every request needs your Tailscale login or a sign-in with the Board's pass key (`pass-key.txt`). `/api/health` alone is open and shows no data.
- **Sign-in form**: open `/login`, paste the key, tap Sign in. The key travels only in the form (POST), never in a link: a link stays in browser history, so `/login?key=...` only shows the form and never signs in, from anywhere (the PC too).
- **Signed 30-day cookie**: a good key gives the device a session cookie (HttpOnly, Secure, SameSite=Strict) that lasts 30 days (`PASS_SESSION_DAYS` changes it). It carries a signed session, never the key. Replacing `pass-key.txt` signs every device out at once.
- **10-tries lockout**: after 10 wrong keys in 15 minutes every sign-in is refused (even the right key) until the 15 minutes pass. A Tailscale login on pass-users.txt is never locked out.
- Actions go through the Yard API (code: `kitchen/kitchen-api.ps1`) on the `chef` channel, so all Yard rules still apply. Every action is logged in `pass-actions.jsonl` and shown in Settings > Audit trail.
- No outside services, no dependencies, strict CSP: scripts and styles only from the Board itself, no inline script or inline style (the app writes its few computed styles through script, `data-css` in its markup). The screen view stays between your PC and your phone.

## Updates are seamless
- **App files (`public/`)**: just save them. The server re-hashes them every 2 s and puts the new build on the live stream. Each phone loads the new version by itself at a moment you won't notice: when the Board goes to the background, or after 5 s with no touch, no sheet open and nothing being typed. It comes back on the same screen, scroll position, filter and half-written work order. Pull down on any list to update right away.
- **Server (`server.mjs`)**: run `pwsh pass-app/update.ps1` (or `just pass-update`). It checks syntax, runs the new server on a spare port against the real Yard state (read-only), and only then tells the phones a restart is coming, swaps, and confirms health. Phones show "The Board is updating…" for about 2 s, not an error. If the trial fails, the live server is never touched. It skips the restart when the server didn't change.
- **Yard scripts** (`kitchen/*.ps1`): nothing to restart; every supervisor pass (Walkround) is a fresh process.
- The title's pulse line shows the live state: Live · checked Ns ago / Reconnecting… / The Board is updating… / Offline (showing the last known board). An error banner appears only after 10 s offline.
- Look at changes safely: `pwsh pass-app/demo.ps1` serves a throwaway Yard on port 7999 (the real one and 7878 untouched); `-Stop` ends it.

## Fast on a phone

- App files go brotli (gzip for older browsers): the first load is about 140 KB instead of 438 KB. Each file is squeezed once per build and kept in memory.
- The live stream keeps one compressor per phone and flushes after each message, so a state resend that barely changed costs a few hundred bytes (10-22 copy of the Yard state: 1.32 MB per 12 s before, 24.6 KB after).
- Job files are parsed only when they change, and Windows tells the live loop when the jobs folder changes; git measures merge gates in the background, so it never stalls the loop (state build 73 ms before, 17 ms after).
- PASS_NO_COMPRESS=1 turns compression off if a proxy ever mangles it.

### Live board (Chef 2.8.0, TD Pour 4, then called Tide wave W4)
One work order's change costs one work order's work on the PC, one small patch on the wire and one row on the phone. Measured on a copy of the
Yard state (289 work orders) and a 10x copy (2,890), before -> after: the board's build after a work order edit 30 -> 8 ms (173 -> 9 ms at 10x);
after an event line 20 -> 10 ms; a stream message after the first 182 KB -> about 0.5 KB; the phone's work per change 40-69 -> 7-13 ms
(405-630 -> 13-16 ms at 10x); the server's worst loop delay with 10 merge gates over 60 s 920 -> 52 ms.
- **No git on the loop**: git and the Yard's scripts start from one worker thread (starting a process on Windows blocks the thread
  that asks). Merge gates are measured again only when `main` or their `kitchen/<id>` branch moved: one `git for-each-ref` per repo
  every 10 s (`PASS_GATE_REFRESH_MS`). Approve and Approve all still measure the diff fresh, and wait for it, before anything is granted.
- **Change-driven state**: the live loop stats and parses only the job files Windows named; a sweep stats them all every 60 s without
  blocking. Spend and tokens come from the event index, which reads only the bytes appended since. Small files (supervisor, board,
  ideas, alerts, scoreboard, freeze, lead) are read again only when they change.
- **Patches**: a new stream gets one full `state` with a version `v`; after that each change is `event: patch` `{ v, base, top, upsert,
  remove }`. The phone (`public/patch.js`) applies a patch only when `base` is the `v` it holds; a gap reconnects once for a fresh state.
  The first full state may go past the 1 MB stream cap (it is 1.3-1.5 MB at 10x); later messages may not.
- **Keyed rows** (`public/rows.js`): each row is kept and made again only when its own markup changed (a crew card's ticking clock does
  not count). Queued, the bench and Show all handed over show 20 rows and 50 more as "Showing N of M" scrolls into view (or is tapped).
- The offline copy is saved when the Board goes to the background or is closed (and once per visit), not every 5 s.
- `/api/health` (open, numbers only) adds `loop` (how late the event loop ran: this window, the last one, the worst of 5; windows of
  `PASS_LOOP_WINDOW_MS`, default 60 s, the first 5 s; live passes over 100 ms) and `work` (files stat-ed and parsed, full sweeps,
  event-log bytes read, ref scans, gate measures). `PASS_LIVE_MS` sets the live loop's beat (default 1000; tests use 100).
### Proof Card and Phone Diff (Chef 2.10.0, Tide Build 2 "An informed yes")
- **Proof Card**: a handed-over work order's page shows its receipt, read only from the Yard's own records (`proofOf` in `server.mjs`,
  in `GET /api/job/<id>` as `proof`). Tests: suites passed, failed and not run (one `tests: PASS|FAIL|-` line each in the tests step's
  newest log), the final line and flaky suites (`results/<id>.tests.json`). Inspector (code: `taster`): the check step's last `VERDICT: SHIP|REWORK` line and
  the crew that ran it. Landed diff: sha256 of `git diff <before> <after>` from `results/<id>.merge.json`, and where it merged. Cost and
  minutes from the work order. Any field with no record is `null` and the phone says "unknown"; a Spec with no check step says so.
- **Phone Diff**: `GET /api/job/<id>/diff` lists a merge gate's files from git (merge base to `kitchen/<id>`, the same diff the yes is
  checked against) with +/- counts, protected marks (automerge.ps1's list) and the diff's sha. `?file=<path>` gives that file's hunks,
  at most 1,500 lines / 96 KB (`cut: true` past that), with the sha of the whole diff they came from. The phone draws +/- bars, protected
  files in ember, and the lines with `textContent`, wrapped (no sideways scroll at 375 px). The yes carries the listed sha, and the server
  still measures the diff fresh before granting. A private work order lists file names only: no counts, no lines (`?file=` is 403), and its
  work order page no longer carries the worktree diff. Not at a merge gate: 409; git failed: 503.
### The City (G1-G3)
- **`GET /api/towers`** (`towers.mjs`, signed in like every `/api/*`): `{ ok, at, gitAt, githubAt, githubError, v, towers, errors }`. One row per repo on
  this PC, left to right: Towers by their first floor (a Tower never moves), then Lots, then the Office.
  - `folder`: the repo folder's name (never its path), so main-status, freeze and undo records, which name a folder, find their Tower.
  - `kind`: `tower` (it has a floor or a crane), `lot` (commits only: a stone base of `plinth.commits`) or `office` (the repo named
    `city.office`, default gemini-brain: `commits`, `lastCommit`, never floors).
  - `floors[]` `{pr?, sha?, at, by, job?, pour?, title?, undone?, past?}`, oldest first, one per merge commit: every merged PR on GitHub
    (`by: 'github'`, its title, its work order from a `kitchen/J123` branch), every ok line of `merges.jsonl`
    (`by: 'session'`; `pour` from "batch-run integrate-<name>") and every `results\J*.merge.json` (`by: 'yard'`, or `'auto'` when
    `automerged.jsonl` lists it; `undone` when it was taken down). The same PR in several records is one floor, by the strongest record.
  - `open[]` `{pr, title?, draft, ci, job?, createdAt}`: every open PR on GitHub once read (hand PRs and Dependabot's too); before the
    first read, an active work order with a `J*.pr.json` and no merge yet. `ci` from the PR's checks (any failure red, anything
    unfinished pending, else green), else the work order's `J*.ci.json`, else `null` (unknown).
  - A floor or crane of a private work order carries no `title`, nor does one whose work order file cannot be found (unknown counts as
    private).
  - `plinth {commits, before}`: a Tower's first-parent commits before its first floor; `blueprint {total, shipped}` from `ledger.json`.
  - A field with no record is left out (the phone draws nothing for it); before the first git read `gitAt` is `null` and no stone base
    is sent. No folder path from this PC is sent. `errors[]` names an unreadable state `kitchen.json` or a `bootRepos` folder that is
    not on this PC (folder name only).
- **`towersV`** in the state: the version of that answer. It moves only when the answer would (a merge, a git count); the phone fetches
  `/api/towers` again then. The inputs are looked at at most every 3 s; git runs every 10 min off the main thread
  (`PASS_TOWERS_GIT_MS`).
- **GitHub** (G2): `gh` (or `PASS_GH`; a `.mjs` runs under node) lists each repo's merged PRs (in full once, then only those merged
  since a day before the newest kept, `--limit 200`) and open PRs with their checks, every 5 min (`PASS_GITHUB_MS`), off the main
  thread, 15 s per call; an old history repo once a day, merged only. Read-only; the token stays on this PC. `PASS_GITHUB=off` turns it
  off. The last good read is kept in `<state>	owers-github.json`, so a failed read (`githubError`, in plain words: not signed in, not
  installed, rate limit, over 15 s, not on GitHub) drops no floor and invents no crane, and a restart starts from it. `githubAt` (also a
  state field, so the phone's "GitHub read N min ago" sign stays true without a refetch) is the last read that fully worked. Each read
  logs one line: lists read, milliseconds, GraphQL points left. `towersV` leaves out `gitAt` and `githubAt`: a read that found nothing
  new does not make the phone fetch again.
- **The model** (`public/city.js` `cityOf(towers, state, events, now, { lastSeen })`, pure, tested in node): what each building
  shows, one field per mark (plans/city-god-mode section 4.1): one shared height scale (`k` floors per 2 px row, the smallest of 1, 2,
  5 ... that keeps the tallest within 80 art px; a Tower level draws its newest 22 floors whole and older ones in bands), lit windows for
  floors merged in the last 24 h, new floors since the phone's last look, cranes (3 shown: a sign-off first, then a crew on it, then red
  CI, then the newest; then "+N"), crews (the crew's colour, its station's tool, its height = step/steps; 3 then "+N"; a lock for a
  private order), pallets (queued: 5 then "+N"), the beacon (warm, amber at 1 h, red at 4 h, from `approval.requested`), scaffolding
  (red main; "?" when unreadable), barrier tape (a freeze now) or a "closes" sign, the skip (a floor taken down in the last 24 h; "?"
  until the undo is on GitHub), the "manual handover" tag, the gate (PAUSED, never CLOSED; OPEN lit; STOP; the clock), the budget meter
  (8 segments, a padlock after a cap stop today), the GitHub sign (over 10 min old, or failed), the real hour's sky, the Office's
  windows, and the Yard lot (orders with no Tower: counts only). `needsYou` drives the horizon strip; `sentence` is each building's text
  twin (numbers only); `momentsDue` lists the moments real changes and events under 2 minutes old call for.
- **`tower`** on each work order in the state: the key of the Tower its merge step's `Repo` is, or `null` (research, career, scouts:
  the Yard lot).
- **Which repos, and their names** come from the state folder's `kitchen.json` only (personal values never sit in this repo):
  `bootRepos` (folders under the profile, or absolute; with none, this repo alone) and an optional `city` key:
  `names { <key>: 'Shown name' }`, `office '<folder>'`, and `history { <key>: { github: 'owner/name', ref: '<branch>' } }`, an older
  repo whose merged PRs sit under the "public from" line (`past: true`, `publicFrom` = the public repo's first merged PR) on a stone base
  of that branch's first-parent commits. A key is the repo's Site code in lower case (`kitchen.repo.json` `site`), else its GitHub name,
  else its folder name; `names` and `history` are found by key, else GitHub name, else folder name (so they hold when a Site code
  arrives).

## Run
- Starts at sign-in (scheduled task `Kitchen-Pass`, hidden via `start-hidden.vbs`); the Walkround's (code: supervisor's) watchdog restarts it if it stops. Manual: `node pass-app/server.mjs`.
- On this PC: `just pass` (copies the key and opens the sign-in form; paste it once). On your phone: Tailscale on, open https://<this-pc>.<your-tailnet>.ts.net, Add to Home Screen.

Tests: `tests/Test-PassApp.ps1`.

Font: `public/jetbrains-mono.woff2` is JetBrains Mono (variable, Latin), SIL Open Font License 1.1, from @fontsource-variable/jetbrains-mono 5.0.21 (sha256 D8188600…5D82). Served from this PC; no font service is contacted.
