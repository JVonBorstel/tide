# Yard API (code: `kitchen`): how any bot or front end talks to the Yard

Every front end uses the same JSON contract, so this chat, another orchestration bot, an MCP client and a future phone bridge all behave the same way.
Names: `gemini-brain/projects/tide/naming/GLOSSARY.md`. Channel names, ops, fields, folders and IDs below are code names and stay as they are.

## The ways in (channels)
| Channel (code name) | Who uses it | How |
|---|---|---|
| **`chef`** | Jordan, and Claude in this chat on Jordan's behalf. The only channel that signs off. | `pwsh -File kitchen/kitchen-api.ps1 -RequestJson '{"op":"status"}'` (or the short `kitchen/jk.cmd status`) |
| **rail** | Any bot that can write a file drops a request (code: ticket) here | Drop `<name>.json` into `%LOCALAPPDATA%\brain-kitchen\rail\`. The answer comes out the `window\<name>.json` within a minute (next Walkround, code: tick); the request file moves to `spiked\`. |
| **pass** | Claude Code, Codex, Gemini CLI, any MCP client sends work orders in | `pwsh -NoProfile -File kitchen/kitchen-mcp.ps1` over stdio. Tools: kitchen_status, kitchen_add, kitchen_kill, kitchen_report, kitchen_doctor. |
| **expo** | Jordan's phone (reserved; alerts go out here once the phone channel is set) | not built yet |

## Request and response
```json
{"id": "my-123", "op": "add", "args": {"name": "nightly review", "script": "agent-step.ps1", "args": {"Prompt": "Review open PRs"}, "timeoutSec": 900}}
{"id": "my-123", "ok": true, "op": "add", "channel": "rail", "data": {"job": "J12", "needsApproval": true}, "error": ""}
```
| op | args | Channels |
|---|---|---|
| status | none | all |
| add | name, script, args (flat strings/numbers), timeoutSec, maxMB, retries, hungSec, maxLogMB, replay (safe/unsafe), approve | all |
| kill | id ("J3") or all: true | all |
| report | none (returns the status page path) | all |
| doctor | none (self-check, backup) | all |
| approve | id | **`chef` only** |
| tick | none | `chef` only |

## Rules every bot gets, whatever it says
- **Bots never sign off.** Only the `chef` channel (Jordan) can give a sign-off. A config file cannot change that.
- **Bot work waits for Jordan** unless the script is on the autoApprove list (default: the demo worker only).
- **Scripts are confined** to the allowed folders (default: this `kitchen/` folder). Paths that climb out are refused.
- **Requests are data, never code.** Arguments must be flat strings or numbers; limits have ranges; requests over 64 KB are refused; at most 20 requests off the rail per Walkround.
- **Every action is logged** in `events.jsonl`.

Settings live in `%LOCALAPPDATA%\brain-kitchen\channels.json` (optional):
```json
{"channels": {"rail": ["status", "add"]}, "allowedRoots": ["C:\\Users\\<you>\\source\\repos\\brain-monitor\\kitchen"], "autoApprove": ["demo-worker.ps1"]}
```
A damaged or missing settings file falls back to the safe defaults.

## Redundancy
| Failure | What happens |
|---|---|
| Supervisor process dies | State is on disk; the next Walkround (every minute) resumes |
| A work order file (code: job file) gets damaged | It is moved to `corrupt\`, Jordan is alerted, the rest keeps running, ids are never reused |
| A work order claims to be running with no worker | `doctor` resets it to `pending` |
| Lost state | `doctor` keeps a daily backup of the live work orders, the archive's index, the approvals and the supervisor state (7 days, by the date in the name) in `backups\daily\`; hand-made backups go in `backups\manual\` (14 days). Finished work orders older than 3 days move to `jobs\archive\yyyy-MM\` (one line each in `jobs\archive\index.jsonl`; move a file back to `jobs\` to restore it) |
| Audit log grows | Rotated at 20 MB; old logs are kept |
| Disk fills up | `doctor` alerts below 5 GB free |
| Settings file broken | Safe defaults |
| Phone channel down or off | Alerts still land in `alerts.jsonl` and the status page; each line says whether it reached the phone (`sent`: ok, off, failed with the HTTP status, limited, or held until the Walkround lets go of its lock, then an `alert.sent` event). While phone alerts are off the Board shows "Phone alerts are off: N alerts since <time> were not sent" and the Toolbox talk has the same line |

## Work order options
Every `cook` request may add these values to `vars`: `cook` (auto, claude, gemini, local: which crew the Spec's (code: `recipe`) AI steps use; auto lets the Dispatcher (code: `sous-chef.ps1`) pick), `private` (yes: the work order never leaves this PC; a step only a Cloud crew could do waits for Jordan), `size` (S, M or L; L lets the Dispatcher use the strong tier for the plan and build) and `night` (yes: night shift; the work order waits until the next 22:00 local time, or starts right away when ordered between 22:00 and 06:00; default no).
