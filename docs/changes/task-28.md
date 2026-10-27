# Board home: status line instead of banner cards

**What:**
- `pass-app/public/app.js` `renderBanners` still builds the one notice list; the new `renderNotices` turns it into two things.
  - **Red bar** (full width, fault colour, no card): only a broken thing. That is the Yard unreachable, the Walkround stopped (no pass for 10 min), a red or unreadable main, an undo not pushed, a Stop-work order, or a registry that cannot be read. Any alarm banner added later is a red bar unless it is marked as a limit, so nothing broken can turn quiet by accident.
  - **Chip** (decision D-1): every other notice, shown as a shape plus 2-4 words in a wrapping line under the header (`#status-line`). Examples: Auto-merge paused, Site closed, Supervisor quiet, Site GW stopped, CI budget over, CI this month, AI crews off. One tap opens a sheet (`#notice-sheet`) with the full text and the notice's own action: Run now, Resume, Turn on. A limit that holds work (a quiet Walkround, a Site over its CI budget) gets an amber edge and a triangle; the rest get a grey dot.
- **Phone alerts are off** (decision D-10): no banner or chip on any tab while push alerts are off, because off is the Owner's choice. The Settings push row now says how many alerts did not reach the phone (`alertsOffLine`, the same count as before).
- **The City gets the space back** (`app.css`):
  - it runs edge to edge; `city.js` already picks the biggest whole-number scale for the box;
  - the building names wrap instead of being cut with an ellipsis;
  - the frame follows the City's own sky (`#city[data-sky]`). By day the pixels are as drawn (Look A). At dusk and night the picture gets more contrast and colour, so lit windows, beacons and signs stand out (B's lighting, decision D-3).
- **Can't reach the Yard:** the red bar now really appears after 10 s. The live stream's own retries (an error every few seconds while the server is down) used to restart the 10 s timer each time, so the bar never came. Now one timer runs per drop.
- Until `city.js` draws its picture, the City holds half the width as room (`#city:not([data-drawn])`, about a six-building City), so the Board below jumps less on a cold open. `renderNotices` returns at once when no notice changed.
- New screen tests: `pass-app/test-status-line.mjs`. They drive the real Board server on a throwaway state folder (made-up work orders) in headless Chrome or Edge. The City's `/api/towers` answer is replaced by a synthetic one with long made-up names.
- The browser start-up and DevTools connection that `pass-app/test-work-ui.mjs` had inline now live in `pass-app/test-browser-kit.mjs`. Both screen tests use it, so the code-quality ratchet finds no duplicate.

Measured at 412 x 900, dark, with four notices at once: auto-merge paused, the Walkround quiet, a closed site, alerts off (`--shots`; pictures in `task-28/`):

| | before | after |
|---|---|---|
| banner cards | 4 | 0 (3 chips) |
| City top | 439 px | 181 px |
| City picture | 379 x 155 px | 411 x 207 px |
| names cut with an ellipsis | 5 of 6 | 0 of 6 |

**Not in this change:** B's real per-light bloom (a soft halo drawn around each lit window and beacon) has to be drawn by the City's painter (`public/city.js`). This change lights the picture as a whole with a CSS filter. The per-light glow is a follow-up for `city.js`.

**Why:** before this change, at 412 px the home drew one card per notice above the City, so with four notices the City started at 439 px and 5 of its 6 names were cut with an ellipsis (table above). D-1 makes notices a status line where only broken things keep a red bar. D-10 keeps push alerts off by choice, so they are not a notice.

**Tests:**
- `pass-app/test-status-line.mjs`: 27 checks, run by `tests/Test-PassApp.ps1`. One check per acceptance line:
  - `Home412_NoBannerCards`, plus `Home412_ChipsAreSmall` and `Home412_ChipWords`;
  - `Chip_FullTextOneTap` (4 chips), `Chip_ActionWorks`, `Chip_EveryNotice`, `Chip_Tone`;
  - `BrokenSupervisor_OneRedBar`, `BrokenSupervisor_RedTone`, `BrokenMain_OneRedBar`, `Unreachable_RedBar`;
  - `PushOff_NothingOnHome`, `PushOff_NothingOnAnyTab`, `PushOff_InSettings`;
  - `TowerLabels360_NoEllipsis`, `TowerLabels412_NoEllipsis`;
  - `NoHScroll360`, `NoHScroll360_ManyChips`, `NoHScroll412`;
  - `City_FullWidth`, `City_Higher`, `City_Taller`, `City_LookAByDay_BAtNight`;
  - `SpeedBudget_NotWorse`: no canvas, animation or frame loop added. The budget itself is measured by CI's `speed` job on the pull request.
- CI `speed` job (report only, phone profile), this change against the last three main runs:
  - layout shift 0.766 against 0.936 on all three main runs (better);
  - frame work, pinch, view change, paint, heap and idle numbers: inside the range of the main runs;
  - INP (slowest tap): 9 runs each; the median is 176 ms here against 152 ms on main (ranges 120-232 and 88-352). Whether that 24 ms is real or runner noise is unknown. A full-width City is about 17% more pixels to redraw when the Board tab comes back.
  - Hard limits in `budget.json` are unchanged.
- `tests/Test-PassApp.ps1`: 1298 passed, 0 failed (the 27 above included). The "Phone alerts are off" checks now test the Settings line and check that no banner says it.
- `tests/Test-Work.ps1` (its screen test now uses the shared kit, which waits up to 30 s for the browser: a cold CI runner once took over 10 s): 118 passed, 0 failed.
- Code-quality ratchet (`scripts/quality/metrics.ps1 -ChangedSince origin/main`): 0 new violations.

**L1-L4:** person: the Board home shows the City and what needs Jordan at a glance on the phone; only real breakage is loud. Business, MSP, community: none.
