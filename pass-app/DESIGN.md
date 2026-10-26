# The Board: design

The Board (code: `pass-app/`, first called Chef) is the phone app.
Brief: "the pass at 9pm on a good night". A calm, exact station: ink on warm paper, one ember that appears only when Jordan is
needed or is committing an action. This brief, its colors and the art stay until S6, when the Board gets its building-site look (Tide RENAME-PLAN.md, S6).
Research and sources: gemini-brain/projects/kitchen/research/mobile-ui-2026-10.md.

Words: this brief uses the approved names (gemini-brain projects/tide/naming/GLOSSARY.md). S1-BOARD-APP (PR #71) changed the status words, WO- numbers and the two buttons "New work order" and "Send to the Yard". Where a screen still differs from this brief, the app has not caught up yet. Today (main 9228e6f) the app still shows: "Nothing on the stove." on the empty Board, "Failed or stopped" as the title of the bench section, "Private" on the work-order switch, and `Kitchen frame` in Settings > About (shown only with `?fps`).

## Rules
- **Color:** only two colors carry meaning: ember (needs Jordan, the primary action) and fault (failed). No teal, no gradients, no glass. The only tinted background is the ember wash behind "Needs sign-off". Tokens live in `public/app.css` (`:root`, light and dark).
- **Status = shape + word:** ● Building (pulses; Inspection while the tests, verify or check step runs), ○ Queued, ✓ Handed over, ✕ Failed or Stopped (on the bench), ◆ Needs sign-off. Never color alone. The words come from one label table in `app.js` (`STATUS_LABEL`); the stored statuses (`running`, `pending`, `done`, `quarantined`, `killed`, `waiting-approval`) do not change.
- **Type:** system sans; mono only for work-order numbers (WO-0142; the stored ID is `J142`), clocks, model ids and logs; tabular numerals on anything that ticks. Screen title 28/32 bold, detail title 22/28, section 15/20 semibold sentence case, body 16/22, meta 14/20, mono 13/18. No uppercase micro-labels, nothing under 12 px, inputs 16 px.
- **Shape:** full-bleed rows with hairlines inset 16 px; no cards, no left color bars, no row shadows. Radii: 10 controls, 20 sheet tops, 14 screen image.
- **Motion:** ease-out cubic-bezier(.23,1,.32,1); press 100 ms; sheets in 280 / out 200 ms; tab switches cross-fade 160 ms (View Transitions). Only two loops: the Building dot and the slow breathing live dot. Reduced motion: 120 ms fades, no loops.
- **Touch:** 44 px minimum, 48-52 px primary buttons; every swipe has a tap alternative (the ⋯ menu); approve is never a swipe. Pull down to refresh (the browser's own pull-to-reload is turned off, so a pull never drops the live feed). A short vibration confirms approve and refresh.
- **Words, not codes:** "improve: split kitchen.ps1" shows as a quiet kind label ("Improve") over the title ("Split kitchen.ps1"); sign-off text drops the repeated work-order name; failures read "Failed: something is broken (exit 1)", never "fail: exit 1: fail: …"; counts read "3 of 40 runs in the last 5 hours". Mono stays for work-order numbers, clocks, model ids and logs only.
- **Never surprise:** the app updates itself only when Jordan can't notice (backgrounded, or idle with no sheet open and nothing typed) and returns to the same place. A server restart reads "The Board is updating…", not an error. Errors appear after 10 s, not on the first blip.

## Screens
- **Board** (route `#/pass`): one list: Needs sign-off (Approve / Reject inline) → Building (clock + progress hairline) → Queued (queue position) → The bench (Failed or Stopped work orders; reason; swipe or ⋯ to Retry) → Handed over (last 3, show all). Empty sections are left out. Above it, a headline says the Yard's state in one sentence ("1 work order needs your sign-off." in ember, "2 work orders building.", "All quiet.") with the rest counted under it; when nothing is going on, a calm cloche and "New work order". Under every screen title, the pulse: Live · checked 12s ago.
- **Work order (job detail):** mono work-order line, title, one state sentence, the ask, the Dispatcher's reason, a Step timeline (tap a Step for its last 5 log lines), Logs, the work order's text, history; one sticky action bar.
- **Activity:** plain sentences grouped Now / Earlier today / Yesterday; All / To act on / Failures; search.
- **Live:** the Yard stage (today's art, kept until S6), then the call (SCENE.md "The Live call"): a crew at a desk per running Step, the busy one's shared screen, stuck and quiet badges, the tree of work order -> Steps -> crew; under it the crews.
- **Crews:** one row per crew (model, usage meter, status word); a sheet with 7-day sparkline, track record, recent work orders, wake / rest.
- **New work order:** Spec radio rows (recent first; code: `recipes/`), fields, crew (Auto/Claude/Gemini/Local; Private work order greys out the Cloud crews), a live sentence saying where it will go, one ember "Send to the Yard".
- **Settings:** AI crews switch, the Walkround (code: supervisor), doctor, alerts, audit trail, about; Stop everything last, in fault red.
- **Screen peek:** black, full-bleed, view only, tap to refresh, mono footer with the capture time.
