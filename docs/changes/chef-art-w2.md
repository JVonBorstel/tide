# Chef art wave 2: moments and juice (plans/chef-art-2.md wave 2; Chef 2.9.1)

The kitchen now reacts to what really happens, once, briefly: a pan flip when a step finishes, a sparkle and a check over the sink
when tests pass, a grey puff and a head scratch when a step goes back, dark smoke and a plate carried to the set-aside shelf, the
pass bell bouncing when a plate needs Jordan, "ORDER UP!" with confetti when an order is done. Each event plays once, never when it
is over 2 minutes old, at most 2 at once; reduced motion gets a still "after" frame; each moment is one polite screen-reader line
(at most one per 10 s). Tapping a chef makes it wave and say what it does for 3 s, then opens the order. Approve gets an 80 ms
hit-stop and a 1 px shake of the pass, never a screen shake. Follow-ups from order J288: cooks at one station stand one body apart
(no overlap), speech bubbles never cover a WORLD prop, and the stage bytes were trimmed by 0.3 KB.
- **Files**: pass-app/public/moments.js (new), scene.js, sprites.js, frame.js (makeLoop moved in), world.js, sw.js (moments.js in the
  offline shell), app.js (one hook: `sceneApproved()` after the yes is sent), server.mjs (version), test-scene.mjs, SCENE.md.
- **Budget**: stage files 34.6 KB brotli: wave 1 + W4 +7.5 KB, wave 2 +5.5 KB; about 2 KB over the plan's +6 and +5 KB together.
- **L1 (Jordan)**: he sees what just happened without reading: a glance at the stage tells him a test passed or a plate needs him.
- **L2 (business)**: a demo of Chef shows a living kitchen driven by real events, not a looping animation.
- **L3 (MSP)**: unknown: no MSP use of the stage yet.
- **L4 (community)**: the moments are original pixel art as code, no assets or libraries; reduced motion and screen readers are served.
