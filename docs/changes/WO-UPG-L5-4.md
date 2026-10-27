# WO-UPG-L5-4: the Work tab's screens (look A, inline list), behind board.work (2026-10-26)

**What:**
- New `pass-app/public/work/`: `work.js` (the tab's place and the flag check), `view.js` (the screen), `queue.js` (Needs you and the
  tap), `cards.js` (A/B/C tiles and the morning card), `replay.js` (the week), `util.js`, `work.css`. Look A was chosen on the card
  `prototypes/work-tab/CARD.md`: the lead's answer, given under Jordan's standing approval of the recommended design defaults.
- What the screen shows, all from the Work API (tide#40). Nothing on it is made up.
  - The top line.
  - The morning card, before noon, until "Later": what landed overnight, how many cards wait, and one recommendation, in at most 3 taps.
  - Needs you: oldest first, at most 7. Each card has Yes/Hold/No (or A/B/C tiles), a note, and the code (head sha) it is about.
  - Streams with their WIP and the attention flags, then the work orders (needs you first, then newest, with "Show more" pages).
  - This week: a bar per day, a day slider, the day in words, and Play.
- Live: the screen follows `GET /api/work/stream`. A new card grows in and an answered one folds away, with no reload. Reconnects
  resume through Last-Event-ID.
- A tap is bound to the card and to the head sha the row shows (`If-Match`). Taps are refused while offline or while the line is down,
  and nothing is queued. A retry reuses the request id, so one tap counts once. A confirmed tap is said aloud (the Board's polite line)
  and buzzes once.
- Offline, the screen shows the last snapshot and says so. Loading, empty and error states are in words, with "Try again".
- Behind `board.work`. While it is off, nothing shows and `#/work` goes back to the Ledger. While it is on, the Ledger tab's place reads
  "Work", with its own count (the cards waiting), and both screens carry a Work | Ledger switch. The old Ledger stays one tap away
  until cutover. The bar's layout is unchanged (no 8th item at 375 px).
- `pass-app/public/app.js`: one seam line after `TITLES`, a dynamic `import('./work/work.js')`, so a failed load never stops the
  Board. No change to `index.html`.
- `pass-app/work/api.mjs` (from tide#40) gains `GET /api/work/events?days=7` (the week replay; not in the contracts yet, a card). It
  also serves `/work/*.js|css` itself, fresh on every load: the Board's static cache keys only top-level files, so an edited `work/`
  file could otherwise be answered from an old copy.
- Push alerts stay OFF (Jordan does not want them now). Nothing here turns them on.

**Effects:**
- L1 (Jordan): his job on the Board is taps. Each card is one row with the answer under his thumb, and a tap cannot land on code he
  did not see.
- L2 (business): the decisions are records (time, answer, note, sha), not chat lines.
- L3 (MSP): the same sign-in, Host and Origin checks as every Board action. Nothing new shows while the flag is off.
- L4 (community): public code; the tests run the real Board on synthetic data in headless Chrome or Edge.

**Proof:** `node pass-app/test-work-ui.mjs`: 25 passed, 0 failed (headless Edge here, Google Chrome on the CI runner, over the
DevTools protocol with Node's own WebSocket; no package).
- The tab stays hidden behind its flag.
- Real data: 7 of 8 cards, oldest first.
- Screen-reader names and descriptions are checked.
- The morning card has at most 3 taps.
- Text contrast is at least 4.5:1 in light and dark. Every text node is measured, in both themes.
- Light and dark shots at 375 px.
- One tap per card: three quick taps write one event, bound to the shown sha.
- A/B/C writes the choice and the note.
- A live card arrives without a reload.
- Offline taps are refused and never sent later.
- Reduced motion gives still day snapshots.
- The loading, empty and error states each show.

**Not done here (cards):**
- `sw.js` (not L5's file): add `/work/*.js` and `/work/work.css` to the shell list, so the Work tab opens offline with its last
  snapshot. Today the snapshot shows only once the files load.
- The speed check (`pass-app/speed`, L4/VIZ): add a Work-tab scenario (open `#/work`, tap, fold) to the 120 fps budget runs. It
  was not measured on a phone here; it is UNVERIFIED on the S26 Ultra.
- A/B/C preview images: `variants[].preview` is a path relative to an unnamed root (repo or private notes), so the tiles show the
  title and letter. A route for the images is a later slice.
- Contracts (L0): the week route, plus the earlier `head` and paging fields.

**Review fixes folded in (verifier on tide#40, #42, #45: `audits/review-tide-40-42-45-2026-10-27.md`):**
- F1 (privacy): `core/ledger/share.mjs` `shareWork` masks a private order's `branch` and `pr` (null), so `work.json`, `/api/work`,
  `/api/work/:id` and the stream no longer name its work. The coordinator asked for the fix there (an L1 file, one line). Tested.
- F2: the Work API reads `flags.json` first, so an undeclared `board.work` never opens the store. Otherwise it opens the store
  read-only to read the `flag.set` events and builds no view while the flag is off. A tap opens a write handle only for its write.
- F3: a tap body with a `__proto__`, `constructor` or `prototype` key is refused (400). The validator fix itself is L0's.
- F4: Web Push sends never follow a redirect (`redirect: 'manual'`); a redirect counts as failed, and the badge is the fallback.
- P1: a preview answers this PC's tailnet name (`PASS_HOSTS`, read from `tailscale status --json`), so the link works through
  `tailscale serve`. With no tailnet name, the answer says so.
- P2: the 2 h preview limit is a ceiling: a longer `--ttl-min` is cut to 120.
- P3: a scratch folder a hard-killed launcher left behind is removed by the next start once it is older than the limit.
  - Left: a preview's recipe list still shows the real home folder (`os.userInfo()` in `server.mjs`, not an L5 line). This is a card.
