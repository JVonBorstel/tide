# City G4: the City is drawn at the top of the Board, the strip on every other tab (2026-10-26)

**What:**
- `pass-app/public/city.js` gains the renderer: `paintCity` paints the model (G3) into one pixel buffer (one `drawImage` a frame),
  `paintStrip` the 40 px horizon strip, `legendRows` the "What am I looking at?" rows, and `mountCity` puts both in the page:
  - the canvas is `aria-hidden`; a row of names under it carries each building's sentence (its `aria-label`), and a caption says
    loading ("Reading the City…"), an error ("The City could not be read: …", or "Showing the last read: …" while the last good answer
    stays on screen), an empty City ("No projects yet") and the GitHub sign's words;
  - `/api/towers` is fetched again only when the state's `towersV` moves;
  - drawn only while seen (page shown, on screen); 10 frames a second only while a beacon blinks or a crew works, else 1; a frame
    whose picture key is unchanged is not drawn; under reduced motion one still frame (the beacon steady), redrawn each minute;
  - whole-number pixel scale, the width filling the box (no sideways scroll at 375 px).
- New `pass-app/public/city-art.js`: the City's sprites as palette strings (crew in hard hats and hi-vis, the station tools, pallets,
  a lock, the new-floors pennant, the skip, the tower skins) and the extra 3x5 glyphs its signs need. Colours come from `sprites.js`
  (`PALETTE`, `paletteFor` for the hour's sky and tint) read-only; the crane paint (2 colours) is local.
- The seams (minimal, named):
  - `public/app.js` `renderScene` (about line 2092): `city.js` is imported on its own (`import('./city.js')`, so a failure leaves the
    Board working); `renderScene` calls `S.city?.update()` and mounts the S7 scene only on the Live tab (`#scene-live`).
  - `public/index.html`: `#scene-pass` becomes `#city` (with the (i) key and the names row); `#city-strip` (a button) under the header.
  - `public/app.css`: a new block at the end, tokens only.
  - `public/sw.js`: `/city-art.js` in `SHELL`.
  - `tests/Test-PassApp.ps1`: the old "the Pass tab renders the compact scene" check becomes 4 City checks (home, loads alone, strip,
    CSS).

**Budgets (node brotli, as the server sends them):** `city.js` 10,139 + `city-art.js` 991 = **11,130 of 16,000 bytes**. Draws: 1 per
frame (the stage's cap is 120). Atlas: none (a buffer of about 228 x 136 at 375 px). The stage's own files are untouched (29,939 of
34,615).

**Light and dark:** the picture is the same in both (the sky is the real hour); the frame, names, caption, strip and legend use the theme
tokens. Screenshots at 375x812, light and dark, are in Jordan's private notes (`prototypes/skyline/board-shots/G4/`), never in this repo.

**Tests:** `pass-app/test-city.mjs` 87/0 (12 new: one buffer and the same picture for the same model, the layout, the stone base, the
beacon only with a sign-off, the CI tag and the PAUSED sign, the truth rule on an empty City, the sky is the hour, the reduced-motion
still, the strip loud and quiet, the legend only for drawn marks, the palette and glyphs of the art). PassApp counts in the PR.

**L1-L4:** person: Jordan opens the Board on his City: every project, its floors and cranes, and what needs him, at a glance; the other
tabs keep a quiet strip that calls out a beacon, a red main or PAUSED. Business: none. MSP: none. Community: none.
