# City G5: zooming through the City (2026-10-26)

**What:**
- New `pass-app/public/city-nav.js`: the City's levels as hash routes (`#/pass` or `#/city` = the City, `#/city/<key>` = one building,
  `#/city/<key>/f/<pr>` = a floor, drawn in G6), so Android's Back, the browser's Back and Esc zoom out one level; the breadcrumb
  (City › Tide › PR #121); the gestures (tap = in one level, never the gate; sideways swipe on a building = the next one, wrapping;
  pinch out = in on the building under the fingers; pinch in = out; long-press is handed to the Act sheet in G8, with a 12 ms buzz);
  and the camera move (280 ms in, 220 ms out, ease-out, toward the building; an instant cut under reduced motion).
- `pass-app/public/city.js` `mountCity`: follows the route on every update; marks the building it is on at once (dotted guides and an
  underline, so a tap feels instant); the names row is now real links (`#/city/<key>`, 44 px, each with its sentence), with the
  building's sentence and the breadcrumb above them; a sideways move replaces the route (Back still zooms out, not sideways).
- Seams (minimal, named): `public/app.js` passes `buzz` to `mountCity` (one word on the existing line); `public/app.css` City block
  (names as links, the breadcrumb, `overflow:hidden` so the camera stays inside the frame); `public/sw.js` `/city-nav.js` in `SHELL`.
  No change to the app's router: `#/city/...` already shows the Board tab, and `mountCity` reads the hash itself.

**Seen in the built-in browser** (375x812, a throwaway copy of the state folder on a spare port): tap Tide -> `#/city/tide` with its
breadcrumb, sentence and marked name; a sideways swipe -> `#/city/my-apps` (history length unchanged); Esc -> `#/pass`. Not verified:
a real two-finger pinch (no touch input in the test browser) and the camera's frame time on Jordan's phone.

**Budget:** `city.js` + `city-art.js` + `city-nav.js` = 14,042 of 16,000 bytes brotli.

**Tests:** `pass-app/test-city.mjs` 93/0 (6 new: routes, Back, the swipe ring, the gesture meanings, the breadcrumb, the camera times
and the reduced-motion cut); `tests/Test-PassApp.ps1` 1 new wiring check (City_Nav). PassApp counts in the PR.

**L1-L4:** person: Jordan taps a building to look closer, swipes between projects and goes back with Back, like zooming in and out.
Business: none. MSP: none. Community: none.
