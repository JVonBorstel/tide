# City G3: the City's model (2026-10-26)

**What:**
- New `pass-app/public/city.js`: `cityOf(towers, state, events, now, { lastSeen })`, a pure function that says what every building in the
  City shows, one data field per mark (the design's section 4.1). Nothing is drawn yet (G4 draws it); the phone does not load the file yet.
  - One shared height scale for every tower (`k` floors per 2 px row, so heights compare) and the Tower level's bands.
  - Floors, lit windows (merged in the last 24 h), new floors since the phone's last look, the stone base, the "public from" line, the
    Blueprint outline.
  - Cranes ranked as the prototype does (a sign-off first, then a crew on it, then red CI, then the newest; 3, then "+N"), their CI tag,
    drafts; crews (crew colour, the station's tool, height = step/steps, a lock when private; 3, then "+N"); pallets (5, then "+N").
  - The beacon (warm, amber at 1 h, red at 4 h, from the order's `approval.requested`), scaffolding (red main, "?" when unreadable,
    matched by folder or GitHub name), barrier tape and the "closes" sign, the skip for a taken-down floor, the "manual handover" tag.
  - The gate (PAUSED, never CLOSED; OPEN lit; STOP; the stopped clock), the budget meter, the GitHub sign, the real hour's sky, the
    Office's windows, the Yard lot (orders with no Tower, counts only).
  - `needsYou` (the horizon strip is quiet unless a beacon, a red main or PAUSED), `sentence` (the text twin, numbers only, no titles),
    `momentsDue` (a new floor or Pour, a new crane, scaffolding up or down, and event moments under 2 minutes old).
- `pass-app/public/sw.js`: `/city.js` joins the offline shell list (the suite holds every app script there).
- `pass-app/towers.mjs`: each row also carries `folder` (the folder's name, never its path), so main-status, freeze and undo records
  find their Tower.

**States:** loading (no `/api/towers` answer yet) and error (`{ ok: false }`) are flags the view says in words; it never draws an empty
City for them. A tower with no state and no records draws no crane, crew, pallet, beacon, scaffold, tape, skip, stone base or line.

**Tests:** `pass-app/test-city.mjs` 75/0 (30 new: one per row of section 4.1, the truth rule, the states, the strip, the text twin, the
moments; plus the S7 seams: every `sprites.js` and `scene.js` export the City reads is still there, or the check names the one that
moved; and the byte budget: `city.js` is 3,814 bytes brotli of the 16,000 for the three City files). PassApp counts in the PR.

**Reduced motion, light and dark:** nothing is drawn in this slice; the model has no animation and no colours of its own.

**L1-L4:** person: none yet (drawn in G4). Business: none. MSP: none. Community: none.
