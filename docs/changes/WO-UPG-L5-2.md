# WO-UPG-L5-2: Web Push for new cards (VAPID on node:crypto), off by default (2026-10-26)

**What:**
- New `pass-app/work/push.mjs`: the VAPID key pair (made once, kept in `<state>\work-push-vapid.json`), the phones' subscriptions
  (`<state>\work-push-subs.json`, at most 5), the message encryption (RFC 8291, aes128gcm), the VAPID header (RFC 8292, ES256) and
  `pushCards`, which tells each phone how many cards wait. It uses only node:crypto, with no `web-push` package (build-way 10.2 item 3).
- Off by default. It sends only when the Board's alerts setting is on (`<state>\push-on`, the same switch as the ntfy alerts), the Work
  tab is on (`board.work`), and a phone has subscribed.
- A message is `{ n, text: "3 cards wait" }` and nothing else.
- A failure never throws. It is written to `<state>\work-push-last.json` with `fallback: "badge"`, and the Board's own card count
  stays the way Jordan learns of a card. A phone the push service calls gone (404/410) is forgotten.
- Only the browsers' push services are ever called (https; FCM, Mozilla, Apple, Windows), so a stored subscription cannot point this PC
  at another host.
- `tests/Test-Work.ps1` and the `coreSuites` line are the same as in WO-UPG-L5-1 (tide#40), so the two PRs merge in either order.
- Not wired yet. The routes (`/api/work/push/key`, `subscribe`, `unsubscribe`), the watcher that pushes when a card arrives, and the
  service worker's `push` handler come in the slice after tide#40 merges (no stacks). ntfy stays the fallback until a card records
  "Web Push seen on the phone" (build-way 10.2 item 4).

**Effects:**
- L1 (Jordan): one quiet line on the phone when a new card waits, and only after he turns alerts on. No text from his work leaves the
  PC: the push service sees an encrypted count.
- L2 (business): free browser push replaces a third-party topic for card alerts. There is no new paid service.
- L3 (MSP): the keys and subscriptions stay in the state folder. The outbound calls go only to the fixed list of push services.
- L4 (community): the code is public; the tests use a fake push service on 127.0.0.1 and the RFC's own example.

**Proof:** `node pass-app/test-work-push.mjs`: 25 passed, 0 failed. The encryption matches RFC 8291 appendix A byte for byte, and the
VAPID token verifies with the key it names.

**Not done here (cards):**
- iOS needs the Home Screen web app (16.4+), HTTPS (`tailscale serve`) and a tap to subscribe. Buttons inside a notification are
  UNVERIFIED on iOS, so tapping the notification opens the card.
- The VAPID `sub` claim defaults to the public repo URL. `PASS_PUSH_SUBJECT` can name a contact; a personal address never goes in
  the repo.
