# Port #103: Rename S6b: the Board's building-site icons (app icon, tab icons) + New work order on a phone

Ported on 2026-10-26 by `scripts/port-private.ps1` from JVonBorstel/brain-monitor#103 (https://github.com/JVonBorstel/brain-monitor/pull/103) at `6137f24f7cd00374f0a1b94b34e14c23b713805a`, onto tide `main` at `8af1796`. The private repo is on a GitHub billing hold, so its work lands here; the private PR stays open.

## What it does (the private PR's description, cleaned)

# In plain words
The Board's icons now match the building site. This builds on #101 (S6a, the site theme), so it is based on that branch. Merge #101 first.

- **App icon** (`/icon.svg`, same path): a pixel safety-yellow hard hat, with hazard tape beneath it on blueprint paper. It is full bleed, and the hat sits inside the round safe zone, so Android's round or squircle crop does not cut it.
- **Tab icons** (pixel, 12x12 drawn at 2x):
  - Board is the site board on its two posts.
  - Talk is a walkie-talkie.
  - Activity is the pulse (the same as before, with a ground line).
  - Live is a hard hat.
  - Ledger is the books with a coin.
  - New work order is a clipboard with a plus.
- **Motion**:
  - The tab you land on hops once.
  - While a crew is at work, the Live hard hat nods every few seconds.
  - New work order has hazard tape along its top. Its clipboard hops when you hover or focus it.
  - All motion is stepped (pixel style), and it all stops under reduced motion.
- **Fix: New work order at 375 px.** It wrapped onto 3 lines. On a phone it now stacks like the tabs: the icon, then 2 lines. I measured 2 lines at 375 and at 360 px in a browser, and all 5 tab labels fit too.
- The line icons in `index.html` (used only when the pixel sprites can't load) are now the same things. Their ids are unchanged.

## What changed
- `pass-app/public/icon.svg`: contents only. It is 32x32 pixel art at 16 px a pixel, `crispEdges`, using only sprites.js palette colours. No gradients and no text. The art group's farthest corner is 200.5 px from the centre; the safe zone ends at 204.8.
- `pass-app/public/sprites.js`: the `ICONS` strip (the six tab icons) is redrawn, and one comment is shortened. The scene and its kitchen art are untouched. The stage brotli budget still passes: sprites.js is 9,380 B with LF line endings (it was 9,420).
- `pass-app/public/index.html`: the paths inside `i-pass`, `i-talk`, `i-cooks`, `i-ledger` and `i-cloche` (the empty-state mark, now a hard hat). The ids and the `<link>` tags are unchanged.
- `pass-app/public/app.css`:
  - New: one short S6b block in the pixel skin, which takes effect only under `html.px`, and one `max-width:440px` rule for `.order-btn`.
  - Pixel tab icons are no longer scaled 1.08 on the current tab, which had blurred them.
  - The `.order-btn` focus ring is now also inset (`--on-ember`), because its `clip-path` clips the outer outline.
  - It uses tokens only and adds no new hex values.
- Tests:
  - `Test-PassApp.ps1` has 5 new checks:
    - the icon uses palette colours, has no gradients or text, and stays inside the safe zone;
    - one icon path everywhere: the manifest `any maskable`, both `<link>`s, `SHELL`, served before sign-in, and push `icon`;
    - every symbol id is still defined;
    - the hop and nod are stepped, wait for `html.px`, don't scale, and stop under reduced motion;
    - the phone rule for New work order.
  - `test-scene.mjs` has 1 new check: the tab icons are 12x12 and each is different.

## Not changed (on purpose)
- The manifest (`icons`, `id`, `scope`, `start_url`, shortcuts), `sw.js`, `server.mjs` and `app.js`. No new icon file was added, so `SHELL` and the pre-sign-in list stay as they are.
- `apple-touch-icon` still points to the SVG. Jordan's phone is Android. Whether iOS shows an SVG touch icon is still unknown (U-S6.1).
- The kitchen scene, the loading, offline and empty chefs, and the World view (#92, ZG-13).

## For Jordan
- Android may keep showing the old home-screen icon until the app updates its install. On iOS, a new icon shows only after you remove the app and add it again.
- The plan says "not before 10-28" for S6b, so **do not merge before 2026-10-28**.

## Seen in a browser
A look-only stub on port 7993 served this worktree's `pass-app/public` with made-up data. It used no keys and no cookies, and the live Board on 7878 was not touched. I checked it at 375x812 in light and dark, and measured the button at 360 px. I also looked at the tab icons (plain and lit) and the app icon (square and circle crop) at a large size.

## Contrast (WCAG 2.x; 3.0 for icon edges and focus rings)
| what | colour | on | ratio |
|---|---|---|---|
| app icon: hat yellow on blueprint | #ffd36b | #23406e | 7.28 |
| app icon: outline on hat | #2b1d1a | #ffd36b | 11.43 |
| tape yellow on tape ink | #ffd36b | #2b1d1a | 11.43 |
| tab outline on bar (light) | #2b1d1a | #fffaf0 | 15.61 |
| tab outline on bar (dark) | #e6dccb | #2b211d | 11.56 |
| plain tab accent grey (light) | #8a857c | #fffaf0 | 3.52 |
| lit tab ember on current-tab wash (light) | #c2410c | #ffeec8 | 4.52 |
| New work order focus inset (light) | #FFFAF0 | #c2410c | 4.98 |
| New work order focus inset (dark) | #1A0E06 | #f08a24 | 7.54 |

## Tests
I ran these one at a time on this commit, through `scripts/run-bounded.ps1`:

| suite | passed | failed |
|---|---|---|
| Test-PassApp | 763 | 0 |
| Test-Names | 31 | 0 |
| Test-Quality | 20 | 0 |
| Test-BrainMonitor | 61 | 0 |

Test-PassApp includes `test-scene.mjs`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

## How it was ported

The private branch's changes since its merge-base `d37031d` with the old private main, with the public cleaning (R1-R9) applied to both sides, applied with `git apply -3`. Only those changes are applied, so tide-only commits stay. The changed files, the commit message and the PR text passed the privacy scan (no live hit; any other new hit needs a person's -Allow, named in the PR).

## L1-L4

The effects are the private PR's own (its description above). The port itself only moves finished work to the public home: nothing changes for a person, the business, an MSP or the community beyond that.