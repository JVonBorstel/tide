# Board notices: one line and clearable (task 31), with readable list titles (task 29)

**What (task 31, decisions D-12 and D-1):**
- **One row.** The status line (`#status-line`) never wraps. When chips do not fit, they scroll sideways inside the line, and the page itself never scrolls sideways. The line is at most 32 px tall and each chip is 28 px.
- **Clearable.** There are three ways to clear a chip:
  - the new **Clear** button (with an x) in the chip's sheet;
  - a **swipe up** on the chip. Sideways swipes still scroll the line (`touch-action: pan-x`);
  - **Clear all**, pinned at the right end of the line.
- **A cleared notice stays hidden until it changes.**
  - Each clear is kept under a key: the notice's id plus a hash of its words and state (`public/notices.js`).
  - A clock that ticks on its own is not a change. "Supervisor quiet for 3 min" and "for 4 min" share a key, but a new reason or a new tone makes a new key.
  - The keys are remembered on the phone through the app's `store` (localStorage behind try/catch, at most 60 keys). With storage blocked, a clear lasts for the visit and nothing throws.
- **Nothing left: no line.** Once every chip is cleared, the line takes 0 px. A bell with a count appears next to the header icons, showing how many current notices are cleared. One tap opens the **Notices** sheet (`#notices-sheet`). It lists every current notice (cleared ones, showing ones and red bars) with its own actions (Run now, Resume, Turn on), Restore for each cleared one, and Restore all.
- **Red bars are never hidden (truth rule).**
  - A full red bar gets a ^ button that makes it **thin**: one line, 24 px (at most 28 px). Tapping the thin line opens the full text and the action in the sheet.
  - A red bar has no Clear button, and Clear all leaves it alone.
  - A thin bar is kept under the same kind of key, so a new or changed breakage shows at full size again.
- **No layout jump (D-6).** A cleared chip folds sideways, and the last chip (or Clear all) folds the whole line's height over 220 ms, so the City moves up smoothly. A line that comes back grows in. Under reduced motion it cuts. The line is not redrawn while it folds.

**What (task 29, folded in; decisions D-11, D-3 and D-9):**
- **One title helper.** `public/titles.js` `titleOf(job)` is the one place a work order's title comes from. It uses:
  1. the idea's short title, if the order has one;
  2. else the name's first heading or line, in plain words.

  Markdown is stripped (bullets, `**`, `#`, quotes, links, code ticks). A name the Yard already cut loses its open bracket or its half word, so "... at Example Co (Remote, ..." reads "Example Co".
- **Never an id alone.** An id alone reads as words by its Spec: "diagnose: J357" is "Why WO-0357 failed", "roadmap-item: B-48" is "Blueprint floor B-48", "apply-prep: A16" is "Application prep A16". Anything else reads "Work order <id>".
- **Where the helper is used.** In `app.js`, `nameOf` (every Board list, the brief, the cook cards and the job sheet) and the confirm boxes. The activity feed and the idea and Ledger rows use the same helper's `cleanTitle`. `cleanTitle`, `firstLine` and `splitName` are exported, so task 30 can roll the helper out to every tab without changing it.
- **Stuck notes as rows.** The brief's repeated-failure notes ("WO-0027 failed the same step twice (agent)") are now rows in its Failed list, in the same row style (number, then "Failed the same step twice"). They are no longer a loose bullet list.
- **Nothing under the nav.** The page's bottom room is `--nav-cover`, measured from the nav element (`innerHeight - nav.top`: its height, its offset from the bottom and the safe-area inset). It is measured again when the nav or the window changes. `main` pads by that plus 16 px. The old `--barh` plus a fixed 24 px is only the fallback before the script runs.

**Measured at 412 x 900, dark, with three notices** (`--shots`; pictures in `task-31/`):

| | before | after |
|---|---|---|
| status line | 2 rows (wrapped) | 1 row, 32 px |
| City top | 181 px | 111 px |
| City top, all notices cleared | (not possible) | about 80 px (line 0 px; read off `home-412-dark-after-cleared.png`, not measured) |

**Why:** after #53 the chips wrapped to two rows at 412 px (about a tenth of the screen) and could not be cleared. Jordan said "We lose so much screen with them" (D-12). The home lists showed bare ids ("J357", "B-48") and raw markdown, and the brief's stuck notes were a loose bullet list (D-11).

**Tests:**
- **`pass-app/test-status-line.mjs`** (run by `tests/Test-PassApp.ps1`): 42 checks, 42 passed. New checks, one per acceptance line:
  - `OneRow412x900_ThreeNotices`, `OneRow360x740_ThreeNotices`;
  - `ClearOne_SurvivesReload`, `TickingClock_StaysCleared`, `ChangedNotice_Reappears`, `SwipeUp_ClearsChip`;
  - `ClearAll_LineGone_BadgeCount`. `Clear_Animates_NoJump` samples every frame: the height folds over several frames, and the City only moves up;
  - `BadgeSheet_ListsAndRestores`, `BrokenBar_NotClearable_ShrinksTo28`, `NewBreakage_FullSize`, `StorageBlocked_StillWorks`;
  - three node checks of `notices.js` (`NoticeKey_*`);
  - `Home412_ChipsAreSmall` now asks for 24-28 px chips (it asked for 44-48 px).
- **`pass-app/test-board-rows.mjs`** (new, run by `tests/Test-PassApp.ps1`): 10 checks, 10 passed:
  - `RowTitles_NoBareIdNoMarkdown`: no row text matches `^[A-Z]\d+$`, contains `**` or starts with "- ";
  - `StuckNotes_AreRows`;
  - `LastRow_AboveNav412x900`, `LastRow_AboveNav360x740`;
  - `TitleHelper_Markdown`, `TitleHelper_Empty`, `TitleHelper_VeryLong`, `TitleHelper_CutNames`, `TitleHelper_NeverBareId`;
  - `SpeedBudget_NotWorse`: titles for 2,890 orders take under 40 ms in node.
- On this fixture, main's last row at 412 px was already above the nav (see `rows-412-dark-before-bottom.png`). The LastRow checks show that the room is now measured from the nav. The fixture does not reproduce the overlap the lead saw.
- The Board-page setup that both screen tests use (server, signed cookie, synthetic `/api/towers`, phone sizes, shots) moved into `pass-app/test-browser-kit.mjs` `boardPage`. Its `open()` now waits for the live pulse rather than any pulse other than "Connecting", so a page that boots from its offline copy is never measured.
- **Speed budget:** the status-line `SpeedBudget_NotWorse` check still holds: one City canvas, no animation at rest, at most 14 nodes in the line. The only motion runs during a clear. The CI `speed` job measures the budget on the pull request. It was not run locally, because it needs `playwright-core` installed.
- Suite results are in the pull request body.

**L1-L4:** person: the Board home gives Jordan his screen back. Notices take one line or none, and broken things stay visible but small. Every row reads as words. Business, MSP, community: none.
