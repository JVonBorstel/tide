# The Board restart waits for the old run to end

**What:** `pass-app/update.ps1` starts the Board's scheduled task through `Start-BoardTask`: it waits up to 5 s for the old run to stop being "Running" (`start-hidden.vbs` waits on node, so the task stays Running until wscript notices node is gone), stops it if it has not, then starts it. Both start calls in the swap use it.

**Why:** 10-27 13:56 MT a deploy sat 45 s offline: starting a task that is still Running does nothing, so the first start was lost, and the watchdog had to restart the Board a minute later. Earlier deploys that day took 1-2 s only because wscript happened to exit first.

**Tests:** `tests/Test-BoardDeploy.ps1` 21 passed, 0 failed (new check 8: one start call, inside Start-BoardTask, which waits and stops; both swap starts use it). `Test-KitchenSupervisor` 245/0, `Test-Standards` 20/0.

**L1-L4:** person: a deploy no longer leaves the phone offline. Business, MSP, community: none.
