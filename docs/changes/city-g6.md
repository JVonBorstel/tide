# City G6: a building's own level (2026-10-26)

**What:**
- `pass-app/public/city.js`: on `#/city/<key>` the picture is that tower alone, 200 art px tall and 46 wide (`rowsOf`: its newest 22
  floors 4 px each, older ones banded; the "public from" line, the cranes, crews, pallets, stone base as in the City). Under the
  picture, the building's **cutaway** (`cutawayHtml` in `public/city-nav.js`): its open PRs on top ("building, CI green"), then one row
  per floor, newest first, the "public from" divider above the old history, a Yard merge with no PR as its work order, a taken-down
  floor marked. Windowed with `public/rows.js` like the board: 20 rows, then "Show 50 more of N floors".
- **The floor sheet** (`floorHtml`), on `#/city/<key>/f/<pr>` (and `/old` for a floor under the line, whose number the public repo may
  reuse): the PR's number and title, when it merged and by whom (the Yard, auto-merged, a Claude session, on GitHub), its Pour (how
  many floors were tested together), when it was taken down, a link to its work order (whose sheet has the Proof card), and a
  GitHub link for the public repo's floors only. An open PR shows "under construction since" and its CI. A number with no floor says so.
- `public/city-nav.js` `cameraMove`: a timer ends a move whose clock stalls (a hidden page froze the zoom at 70 ms in testing, and the
  level never drew).
- Seams (minimal, named): `public/app.css` City block (`.city-cut`, `.city-line`, `.city-nopr`, `.city-more`, `.city-sheet`; tokens
  only, rows and links 44 px). No change to `app.js`, `index.html`, `sprites.js` or `scene.js`.

**Seen in the built-in browser** (375x812, light and dark, a throwaway copy of the state folder on a spare port): Tide's own level
(127 floors, 11 cranes), its cutaway with the "public from 10-26" line, "Show 50 more" twice to every floor, the sheet of a new
floor and of an old one (`/old`, no GitHub link). Not verified: tapping a crane on the canvas for its sheet (the cutaway's rows do
it; the canvas tap at this level is left for later) and the frame time on Jordan's phone.

**Budget:** `city.js` + `city-art.js` + `city-nav.js` = 15,757 of 16,000 bytes brotli. G8 and G9 do not fit in what is left.

**Tests:** `pass-app/test-city.mjs` 107/0 (14 new: newest first, the public line, the window, the no-PR row, escaping, the floor
sheet, its work order, an old floor, an open PR, a missing number, the `/old` route, the big rows, the big level, a stalled camera);
`tests/Test-PassApp.ps1` 1 new wiring check (City_TowerLevel). PassApp counts in the PR.

**L1-L4:** person: Jordan opens a project and reads its whole history floor by floor, down to one PR and its work order.
Business: none. MSP: none. Community: none.
