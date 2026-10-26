---
description: Hand this session off so a fresh one continues without a gap (Shift handover in PICKUP.md, a note on the Board, Toolbox talk)
---
Hand off this session now. A fresh session will start from what you write, so write only what the files prove (no guessing).

1. Do not hand off while a background workflow or command of this session is still running: its result would come back to this
   session only. Wait for it, or write its id and how to read its result (journal path, log file) in the note.
2. Write `%USERPROFILE%\gemini-brain\memory\PICKUP.md`, the Shift handover (replace it; at most 30 lines, plain words):
   - `# Shift handover (<date time> MT, by <model>)`
   - **Doing:** the task and Jordan's last words about it (quote).
   - **Done this session:** each item with its proof (commit, PR link, test count, file).
   - **Running / waiting:** PRs waiting on CI, workflows, work orders in the Yard, what waits on Jordan.
   - **Next:** numbered, exact first steps (commands, paths, branch names).
   - **Watch out:** caveats, quota (read `%LOCALAPPDATA%\brain-kitchen\plan-usage.json`), anything unproven.
3. Append one log line to the active build's progress file (`gemini-brain/projects/tide/PROGRESS.md`) and fix any line in
   `memory/NOW.md` that is no longer true.
4. Leave Jordan a short note on the Board (phone-first, warm, no paths):
   `pwsh -NoProfile -File "$env:USERPROFILE\source\repos\brain-monitor\kitchen\lead.ps1" handoff -Text "<2-4 plain sentences>"`
5. Rebuild the Toolbox talk (memory/BOOT.md): `pwsh -NoProfile -File "$env:USERPROFILE\source\repos\brain-monitor\scripts\refresh-boot.ps1"`
   and check its "Shift handover" section shows your note.
6. Commit gemini-brain (only the files you changed; never memory/evie*, memory/user/finances*, life_admin, evie_admin).
7. Tell Jordan in one or two lines: it is safe to start a new session, and the new session needs only "continue".
