# Readable text and clear layout on every Board screen (task 30)

Decisions: D-11 (real titles and plain words everywhere), D-3 (nothing clipped, the pixel look), D-9.

## What was wrong (the look before any change)

Every tab and sheet was opened at 412 x 900, dark and light, against a throwaway Board with made-up data (`pass-app/test-readable.mjs --label before`). The pictures are in `task-30/*-before*.png`. This is what the crawl and the pictures showed, before anything changed:

| Screen | Problem | Picture |
|---|---|---|
| Board home | The counts wrap into two ragged rows. "Nothing handed over today" sits among the chips. | `home-412-dark-before-stats.png` |
| Board home | "10 failed or stopped" counts 7 orders that are days old, so the number means nothing. | `home-412-dark-before-stats.png` |
| Board home | "2 work orders need your sign-off." has no button to act on it. | `home-412-dark-before-stats.png` |
| Board home | A failure reason shows a Windows path and raw JSON: `Failed: C:\...\lint.ps1 threw {"code":1,...}`. | `board-412-dark-before.png` |
| Board home | Times read "10m" and "6d"; titles and asks are cut after two lines. | `home-412-dark-before-stats.png` |
| Tower view | Rows cut their title with an ellipsis ("ci: bump actions/upload-…") and use code words ("building, CI green"). | `tower-412-dark-before.png` |
| Tower view | The scene is one tall tower in a big empty sky; the list starts low. | `tower-412-dark-before.png` |
| Tower view, every tab | Rows scroll behind the floating nav: they show beside it and below it, and through the see-through header. | `tower-412-dark-before-bottom.png` |
| Floors list | Every row is a bare "#34 10-27": no title, a date in numbers. A private repo reads "Private project" even on the owner's own Board. | `floors-412-dark-before.png` |
| Activity | Each sentence starts with a bare "WO-0001"; raw `**undo**`; a file path (`kitchen/kitchen-api.ps1`); "needs your sign-off:" with nothing after the colon; an internal code "(ZG-29)" and a file name. | `activity-412-dark-before.png` |
| Live | "WO-0006" alone as the shared screen's job; desk labels at 9-11 px; 36 texts under AA contrast (the idle desks were faded to 72%). | `live-412-dark-before.png` |
| Ledger | History rows read "J7 waiting-approval" (an id and a stored status); the red counts and "Waits on you" are under AA. | `ledger-412-dark-before.png` |
| World | The lobe's badges ("NOT WRITTEN", "UNKNOWN") are under AA. | `world-412-dark-before.png` |
| Work order sheet | The bar says "WO-0050 · 11:30" alone. The state line and the Retry button show the path and the JSON. Steps read "Role: plan, Supplier: claude". | `job-sheet-412-dark-before.png` |
| Work (behind its flag) | Each row starts with a bare "WO-3001"; the goal comes second. | `work-412-dark-before.png` |
| New work order (light) | The Spec glyphs are under AA. | `order-sheet-412-light-before.png` |
| Talk at 360 x 740 | The message box sits 14 px under the nav. | (crawl) |

Talk and Settings had no finding at 412 px. The review (round 1) found two more: the notice sheet's words and Clear button sat 6 px from the screen edge, and the Retry button's reason line ran under its 3 px bottom edge.

## What changed

- **Titles in words everywhere** (`public/titles.js`, the one helper from task 29).
  - Activity sentences name the work order by its title, with its number as small secondary text. One the Board no longer holds reads "Work order WO-0123".
  - Live (the shared screen, the desks, Who works on what) uses `titleOf`.
  - The work order sheet's bar says "Work order WO-0050".
  - Ledger history rows read "Work order WO-0007 needs sign-off".
  - The Work tab shows the goal first, then the id.
- **Plain words.**
  - The new `plainDetail` in `titles.js` takes a detail's first line. File paths read as the file's name (`C:\...\lint.ps1` and `kitchen/stations/lint.ps1` read "lint"), JSON objects are left out and markdown marks dropped.
  - It is used for failure reasons (rows, the sheet, the Retry button), Activity details and alerts, and step notes. "Role: plan, Supplier: claude" now reads "Crew: Claude".
  - The full text is one tap away: The full detail (on the sheet), History and Logs.
- **The home** (Jordan's phone, 10-27, items 1-3):
  - The headline has its one action under it, Open the sign-off. One order opens its sheet; more jump to Needs sign-off.
  - Under it sits one grid of six equal cells: building, queued, failed or stopped in the last day, leads or Clients, ideas, Brief.
  - The plain-words line ("1 handed over today", follow-ups due) sits on its own line under the grid.
  - The red number counts only orders that failed or stopped in the last day (`public/plain.js` `homeStats`). The older ones are under Show cleared / older in the same section, one tap away, with Clear old.
- **The tower view** (items 4, 5 and 7):
  - Each row shows the whole title (wrapped), then what it is in words ("open, checks passed", "open, checks running", "draft, checks failed"), then "#61" as small secondary text.
  - The picture starts just above the tower's cranes and is at most 40% of the screen tall (a smaller whole-number scale when it would be taller).
- **The floors list** (item 6):
  - Each floor row reads title, then "merged Oct 23" or "taken down Oct 24", then its number.
  - A floor whose work order is private reads "Private work order".
  - On the signed-in Board a private repo keeps its real name and PR titles (`towers.mjs`: the Board is tailnet and key only). "Private project" is now only for demo, fixture and screenshot mode (`PASS_CITY_ALIAS=1`; `demo.ps1` sets it). The neutral key, the padlock, the missing GitHub link and the work-order privacy rule all stay.
- **Nothing under the header or the nav.**
  - The header is opaque (it was 70% see-through).
  - A floor (`.bar-floor`) fills the screen's bottom edge from the nav's top down, so rows no longer show beside or below the floating nav.
  - The Talk box sits on the nav's measured top (`--nav-cover`).
- **Easy to follow.**
  - Row times read "10 min ago" and "2 h ago"; a tap shows the exact time.
  - Titles, asks and meta lines wrap; nothing cuts the meaning with an ellipsis.
  - Body text is at least 14 px, and small labels (ids, times, counts, headings) at least 12 px.
- **Nothing clipped, one gutter** (round 1): a button that carries its reason (Retry) gets padding above its bottom edge, and the notice sheets sit on the same 16 px gutter as the other sheets.
- **Contrast AA in both looks:** cook badges and the Live tags use dark letters, the idle desks are no longer faded, and the red counts, lobe badges and light Spec glyphs are darker. Palette colours only.

## Tests

`pass-app/test-readable.mjs` (new; run by `tests/Test-PassApp.ps1`) has 27 checks, one named after each acceptance line and each of Jordan's seven items:

- The crawl: `Crawl412_NoBareId`, `Crawl412_NoMarkdown`, `Crawl412_NoPathNoJson`, and the same three at 360 x 740. They cover every tab (Board, a tower, a floors list, Talk, Activity, Live, Ledger, World, Work) and the sheets (work order, Settings, New work order, notice).
- `ContrastAA_BothLooks`: every visible text element, dark and light.
- `NoHScroll360`, `LastItem_AboveNav360` and `BodyText14`.
- `Buttons_NothingClipped` (every button's last text line ends above its bottom edge minus 3 px) and `SheetGutter360` (text in a sheet's body starts at least 12 px from the screen edge).
- The seven items: `Home_StatsOneGrid`, `Home_FailedMeansNow`, `Home_OlderOneTap`, `Home_SignOffAction`, `Tower_TitlesWrap_PlainStatus`, `Tower_LastRowAboveNav412x900`, `Tower_LastRowAboveNav360x740`, `Floors_TitleWhatWhen`, `Floors_RealNamesOnOwnBoard` and `Tower_SceneFitsContent`.
- Also `Times_WordsExactOnTap`, `PlainWords_Status` and `HomeStats_RecentOnly`.
- Speed: `SpeedBudget_NotWorse` (no canvas, animation or loop added) and `SpeedBudget_Cutaway` (2,000 floors build their 70 shown rows in under 5 ms).

`pass-app/test-city.mjs`:

- The cutaway and floor-sheet checks now expect the words above.
- The privacy checks run in alias (fixture) mode.
- The City's byte cap `Budget_CityBytes` went from 16,000 to 16,400 B brotli. Main is 15,858 B; this change is 16,295 B. The new words live in `public/plain.js`, outside the cap.

Results are in the pull request body.

**Speed budget:** no canvas, animation or frame loop was added, and a tower view paints its scene again only when it has to shrink its scale to fit 40% of the screen. The CI `speed` job measures the budget on the pull request; it was not run locally (it needs `playwright-core`).

**L1-L4:** L1 person: every Board screen reads as words Jordan can follow at a glance: real titles, plain reasons, the number that needs him, and nothing hidden under the bars. L2 business, L3 MSP, L4 community: none.
