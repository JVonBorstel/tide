# WO-UPG-L5-3: per-PR previews of the Board with fixture data only (2026-10-26)

**What:**
- New `pass-app/work/preview.mjs` starts one PR worktree's Board (`pass-app/server.mjs`) on a local port (7900-7999), on a new scratch
  state folder. The folder is a copy of a fixture marked `FIXTURE.txt`, or the built-in synthetic one. A Board card can then link to
  "see it running" before Jordan taps Yes.
  - Command: `node pass-app/work/preview.mjs start --worktree <PR checkout> [--fixture <folder>] [--port <n>] [--ttl-min 120] [--user <tailnet login>]`.
    It prints one JSON line and stays up until the preview ends.
- Fixture data only. The server gets a minimal environment, and its `LOCALAPPDATA`, `APPDATA`, `USERPROFILE`, `HOME` and `TEMP` point
  inside the scratch folder, so the live state folder cannot be found. A worktree inside the live folder is refused. So is a fixture that
  is, or holds, the live folder, or that does not say it is synthetic.
- Ends by itself. After 2 h the launcher ends the process tree (`taskkill /T`), frees the port and removes the scratch folder. At most 3
  previews run at once.
- It never changes Tailscale. The answer names the exact `tailscale serve --bg --https=<port> ...` command for a card, because reaching
  the port from the phone is Jordan's setting.
- `tests/Test-Work.ps1` and the `coreSuites` line are identical to tide#40 and tide#42, so all three merge in any order.

**Effects:**
- L1 (Jordan): one link per Board PR shows the change running on his phone before he taps Yes.
- L2 (business): the Vercel/Netlify preview idea, on this PC, with no new service.
- L3 (MSP): the PR's code runs as this Windows user, but never sees the live state folder or the accounts behind it. It is for this
  repo's own PRs only.
- L4 (community): the tests use only synthetic data, and a decoy live folder under TEMP.

**Proof:** `node pass-app/test-work-preview.mjs`: 20 passed, 0 failed.
- A canary order in a decoy live folder never shows in the preview, and nothing new is written there.
- After a 2.5 s limit, the port is free, the scratch folder is gone, and the preview is no longer listed.
- Mutation run by hand: handing the preview the real `LOCALAPPDATA` without `BRAIN_KITCHEN` makes the suite fail.

**Not done here (cards):**
- The card link and the Work API route (`/api/work/:id/preview`) come in the slice after tide#40 merges.
- `tailscale serve` for a preview port is Jordan's tap: it changes Tailscale's settings.
