export const meta = {
  name: 'task-orchestrate',
  description: 'Work the local task store: pick ready tasks, build each to a PR in its own worktree, verify independently, merge on SHIP + green CI, gate, plan more',
  whenToUse: 'Started by /task-orchestrate (the loop) or /task-start <n> (one task). Tasks live in a local, private store read with node tools/task.mjs.',
  phases: [
    { title: 'Pick', detail: 'ask the task CLI for the next ready task(s); pause and usage stop here', model: 'haiku' },
    { title: 'Work', detail: 'a builder works each task in its own worktree, tests first, to a PR' },
    { title: 'Verify', detail: 'impacted suites + CI (haiku) and an independent reviewer (sonnet)', model: 'sonnet' },
    { title: 'Merge', detail: 'scripts/merge-pr.ps1 after SHIP and green CI; Board redeploy when pass-app changed', model: 'haiku' },
    { title: 'Gate', detail: 'privacy scan of the merged diff + suites; review notes become one tidy-up task', model: 'sonnet' },
    { title: 'Plan', detail: 'raise the tasks the next roadmap milestone can start now', model: 'sonnet' },
  ],
}

// Owns the task orchestrator's control flow (docs: README "Task orchestrator"). The task CLI (tools/task.mjs) owns the task files; this
// script never reads them itself (it has no file access): agents run the CLI and return only numbers, paths and verdicts, so private
// task text never passes through here into a public place. State lives in the task files (status, pr, branch, claimed_by), so a run
// cut off by a usage cap is continued by running it again: the first pick resumes this orchestrator's own in-flight tasks.
// args: a string like "--lanes 2 --max 10" (from the slash commands) or an object with the same keys (camelCase).
const WIP = 4 // build streams open at once (tools/task.mjs WIP_LIMIT; build-way 3.3)
const DEF = {
  lanes: 1, max: 100, gateEvery: 3, rounds: 3, planBatch: 5, planRounds: 10, task: 0, plan: true,
  repo: 'JVonBorstel/tide', checkout: '', wtRoot: '',
  privacyScan: '%USERPROFILE%\\gemini-brain\\projects\\tide\\audits\\public-tide-scan.ps1',
  gitName: 'JVonBorstel', gitEmail: '204934145+JVonBorstel@users.noreply.github.com',
}
function options(a) {
  const o = { ...DEF }
  if (a && typeof a === 'object' && !Array.isArray(a)) {
    for (const k of Object.keys(a)) { if (!(k in DEF)) throw new Error(`unknown option ${k}`); o[k] = a[k] }
  } else if (typeof a === 'string' && a.trim()) {
    const t = a.trim().split(/\s+/)
    for (let i = 0; i < t.length; i++) {
      if (t[i] === '--no-plan') { o.plan = false; continue }
      if (/^#?\d+$/.test(t[i]) && !o.task) { o.task = Number(t[i].replace('#', '')); continue }
      const m = /^--([a-z][a-z-]*)$/.exec(t[i])
      const key = m ? m[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase()) : ''
      if (!m || !(key in DEF) || key === 'plan') throw new Error(`unknown argument ${t[i]} (see README "Task orchestrator")`)
      if (i + 1 >= t.length) throw new Error(`${t[i]} needs a value`)
      o[key] = typeof DEF[key] === 'number' ? Number(t[++i]) : t[++i]
    }
  }
  for (const k of ['lanes', 'max', 'gateEvery', 'rounds', 'planBatch', 'planRounds']) {
    if (!Number.isInteger(o[k]) || o[k] < 1) throw new Error(`--${k} must be a whole number of 1 or more, not ${o[k]}`)
  }
  if (!Number.isInteger(o.task) || o.task < 0) throw new Error(`the task number must be a whole number, not ${o.task}`)
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(o.repo)) throw new Error(`--repo must be owner/name, not ${o.repo}`)
  return o
}
const O = options(args)
if (O.lanes > WIP) log(`--lanes ${O.lanes} is above the WIP limit of ${WIP} build streams; using ${WIP}`)
const LANES = Math.min(O.lanes, WIP)
const TRAILER = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
const PR_END = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'

// ---- schemas ------------------------------------------------------------------------------------------------------------------------
const str = { type: 'string' }; const int = { type: 'integer' }; const bool = { type: 'boolean' }; const strs = { type: 'array', items: str }
const PICK = { type: 'object', properties: {
  checkout: str, cli: str, store: str, wtRoot: str, mainSha: str, visibility: str, paused: bool, stop: str, reason: str, state: str, why: str,
  tasks: { type: 'array', items: { type: 'object', properties: { id: int, public_title: str, paths: strs, resume: bool, pr: int, branch: str }, required: ['id', 'paths', 'resume', 'pr', 'branch', 'public_title'] } },
}, required: ['checkout', 'cli', 'store', 'wtRoot', 'paused', 'stop', 'reason', 'state', 'why', 'tasks'] }
const WORK = { type: 'object', properties: {
  ok: bool, pr: int, branch: str, worktree: str, head: str, tests: str, outsidePaths: strs, touchesPassApp: bool, privacyScan: str, blocked: str,
}, required: ['ok', 'pr', 'branch', 'worktree', 'head', 'tests', 'outsidePaths', 'touchesPassApp', 'privacyScan', 'blocked'] }
const CHECKS = { type: 'object', properties: {
  testsPass: bool, tests: str, failing: strs, ci: { type: 'string', enum: ['green', 'red', 'pending', 'none'] }, ciFailing: strs, head: str,
}, required: ['testsPass', 'tests', 'failing', 'ci', 'ciFailing', 'head'] }
const REVIEW = { type: 'object', properties: {
  verdict: { type: 'string', enum: ['SHIP', 'SHIP AFTER FIXES', "DON'T SHIP"] }, fixes: strs, notes: strs, privacyOk: bool, why: str,
}, required: ['verdict', 'fixes', 'notes', 'privacyOk', 'why'] }
const MERGE = { type: 'object', properties: {
  merged: bool, sha: str, refusal: str, behind: bool, boardRedeploy: str, worktreeRemoved: bool,
}, required: ['merged', 'sha', 'refusal', 'behind', 'boardRedeploy', 'worktreeRemoved'] }
const GATE = { type: 'object', properties: {
  base: str, privacyRan: bool, privacyLiveHits: int, testsOk: bool, tests: str, tidyTask: int, problems: strs, paused: bool,
}, required: ['base', 'privacyRan', 'privacyLiveHits', 'testsOk', 'tests', 'tidyTask', 'problems', 'paused'] }
const PLAN = { type: 'object', properties: { milestone: int, raised: { type: 'array', items: int }, milestoneDone: bool, why: str }, required: ['milestone', 'raised', 'milestoneDone', 'why'] }
const DONE = { type: 'object', properties: { ok: bool, why: str }, required: ['ok', 'why'] }

// ---- shared prompt pieces ------------------------------------------------------------------------------------------------------------
let ctx = null // { checkout, cli, store, wtRoot } from the first pick
const cli = () => `node "${ctx.cli}"`
const PRIVATE = `The task store is PRIVATE. Never copy a task's title, body or notes into anything public: commit messages, branch names,
PR titles or bodies, PR comments, code comments, test names or docs. The only task words allowed in public are its public_title.
Describe public things by the code change itself.`
const RULES = `House rules (the repo's AGENTS.md, kitchen/CREED.md, kitchen/BUILDING.md "Building in public" and "Before you finish" apply):
- run every test suite through scripts/run-bounded.ps1 (pwsh -NoProfile -File <checkout>\\scripts\\run-bounded.ps1 -Script <suite> -TimeoutSeconds 600 -MaxMB 2000);
- never force-push, never rebase a pushed branch, never delete a branch, never merge (merging is a later step), never touch another repo;
- no installs, no new remotes, no settings changes; report counts, not adjectives (CREED 5); unknown is written "unknown".`
const wtOf = (t) => `${ctx.wtRoot}\\task-${t.id}`
const branchOf = (t) => t.branch || `task/${t.id}`
const titleOf = (t) => `WO-TASK-${t.id}: ${t.public_title || `task ${t.id}`}`

// ---- PICK ---------------------------------------------------------------------------------------------------------------------------
function pickPrompt(first) {
  const find = ctx ? `Checkout: ${ctx.checkout}. CLI: ${ctx.cli}. Worktree root: ${ctx.wtRoot}.` : `First find the checkout of ${O.repo}:
${O.checkout ? `use ${O.checkout}` : 'run `git rev-parse --show-toplevel` in your starting folder'}; confirm \`git -C <checkout> remote get-url origin\` names
${O.repo} (if not, return paused=false, stop="stop", reason="not a checkout of ${O.repo}", tasks=[]). cli = <checkout>\\tools\\task.mjs.
wtRoot = ${O.wtRoot || 'the folder "wt" next to the checkout (<parent of checkout>\\wt)'}. store = the "store" field of \`node <cli> where --json\`.
visibility = \`gh repo view ${O.repo} --json visibility -q .visibility\`. If it is not PUBLIC, run nothing else and return stop="stop",
reason="${O.repo} is not public (<visibility>)", tasks=[]: this orchestrator works public repos only; private ones stay with Jordan.`
  const run = O.task
    ? `Single-task mode, task ${O.task}. Run \`node <cli> show ${O.task} --json\`. If it fails, return tasks=[] and why=its output.
If its status is "doing" or "review", return it with resume=true (do not change it). If its status is "todo" and its "waits" list is empty,
run \`node <cli> set ${O.task} status=doing claimed_by=session\` and return it with resume=false. Otherwise return tasks=[] and
why="task ${O.task} is <status>, waits on: <waits>". state = "picked" when a task is returned, else "empty".`
    : `Run exactly: \`node <cli> next --lanes ${LANES} --claim${first ? ' --resume' : ''} --json\` (exit code 3 means paused or a usage stop; that is
not an error). Copy its fields: paused, stop (missing = ""), reason (missing = ""), state, why, and tasks.`
  return `${find}
${first ? 'Also return mainSha = `git -C <checkout> rev-parse origin/main` after `git -C <checkout> fetch origin main`.' : 'mainSha = "".'}
${run}
For every task return id, public_title ("" when null), paths, resume, pr (0 when null), branch ("" when null). Do nothing else: no
other commands, no edits.`
}

// ---- WORK ---------------------------------------------------------------------------------------------------------------------------
function workPrompt(t, fix) {
  const wt = wtOf(t); const br = branchOf(t)
  const start = fix ? `FIX ROUND ${fix.round} of at most ${O.rounds} for task ${t.id}. The worktree ${wt} (branch ${br}, PR #${fix.pr}) exists.
Fix exactly these findings (from the independent reviewer, the suites and CI), nothing else:
${fix.items.map((x, i) => `${i + 1}. ${x}`).join('\n')}
If a finding is wrong, do not "fix" it: say why in "blocked" only if you cannot continue; otherwise list it in "tests" as disputed.`
    : `Work task ${t.id} to a pull request.
1. Read the task: \`${cli()} show ${t.id}\` (front matter + body: the goal, acceptance and limits). Its paths: ${t.paths.join(', ') || '(none declared: keep the change small and name every file)'}.
2. The worktree: ${wt} on branch ${br}. ${t.resume || t.pr ? `This task is being RESUMED (PR #${t.pr || 'none yet'}): reuse the worktree if it exists (\`git -C ${wt} status\`);
   if only the branch exists, \`git -C ${ctx.checkout} worktree add ${wt} ${br}\`; then continue from where it stopped. If the PR is
   open and the work is complete and pushed, change nothing and return its details.`
   : `\`git -C ${ctx.checkout} fetch origin main\` then \`git -C ${ctx.checkout} worktree add ${wt} -b ${br} origin/main\` (if the branch already exists, add the worktree on it instead).`}
3. Build it there, tests first: every acceptance line gets a test named after it. Touch only the task's paths (CREED 4); anything else
   must be minimal and listed in outsidePaths with the reason. Add docs/changes/task-${t.id}.md (what, why, tests with counts, L1-L4 effect)
   in public words only. Keep README/docs true where a neighbour option is documented.`
  return `${start}
${RULES}
${PRIVATE}
Before every push, in this order:
a. Run the suites the change touches (and their counts go in "tests").
b. Privacy: copy the files changed against origin/main (\`git -C ${wt} diff --name-only origin/main...HEAD\` plus uncommitted ones) into a
   fresh temp folder with their relative paths, run \`pwsh -NoProfile -File "${O.privacyScan}" -Root <temp> -Json -Patterns ${wt}\\scripts\\secret-patterns.ps1\`
   (expand %USERPROFILE%), delete the temp folder. Any live hit: do not push; set blocked="privacy scan: <classes and files, never the values>".
   If the scan script is missing: do not push; blocked="privacy scan not found at <path>". Put the counts line in privacyScan.
   Also read your own commit messages and PR text against the task file: no task text beyond the public title.
c. Commit: \`git -C ${wt} -c user.name=${O.gitName} -c user.email=${O.gitEmail} commit\` with a plain message about the code, ending with a
   blank line and \`${TRAILER}\`. Push normally: \`git -C ${wt} push -u origin ${br}\` (never --force).
${fix ? '' : `d. Open the PR if there is none: \`gh pr create -R ${O.repo} --base main --head ${br} --title "${titleOf(t)}" --body-file <temp file>\`; the
   body says in plain public words what changed and the proof (suite counts), then the L1-L4 line, and ends with a blank line and then
   exactly: ${PR_END}
   Then record it: \`${cli()} set ${t.id} status=review pr=<number> branch=${br}\`.`}
Stop and report instead of guessing when: the task is unclear, it needs Jordan (a decision, an install, a setting, money, a delete), the
change must leave its paths widely, or a suite you did not touch fails on main too. Return ok=false with the reason in "blocked".
Return: ok, pr (the PR number, 0 if none), branch, worktree, head (the pushed commit), tests (suite counts), outsidePaths,
touchesPassApp (any changed file under pass-app/), privacyScan, blocked ("" when fine).`
}

// ---- VERIFY -------------------------------------------------------------------------------------------------------------------------
function checksPrompt(t, b, ciOnly) {
  return `Checks for PR #${b.pr} (task ${t.id}, worktree ${b.worktree}, branch ${b.branch}). Read-only: never edit, commit, push, comment or merge.
${ciOnly ? 'Suites already ran: return testsPass=true, tests="(not rerun)", failing=[].' : `1. The suites this change touches: list the changed files with \`git -C ${b.worktree} diff --name-only origin/main...HEAD\`, then run
   \`pwsh -NoProfile -File ${ctx.checkout}\\kitchen\\stations\\tests.ps1 -Dir ${b.worktree} -Impacted -ChangedFiles <the files>\` (it bounds every
   suite itself). testsPass = its last line says PASS (PARTIAL PASS counts); tests = that line; failing = the failing suite names.`}
2. CI: \`gh pr checks ${b.pr} -R ${O.repo}\` every 60 s until no check is pending, for at most 25 minutes. ci = green (every check passed or
   skipped), red (any failed; ciFailing = their names), pending (still running after 25 min) or none (no checks at all).
head = \`gh pr view ${b.pr} -R ${O.repo} --json headRefOid -q .headRefOid\`.`
}
function reviewPrompt(t, b, round) {
  return `You are the INDEPENDENT REVIEWER of PR #${b.pr} in ${O.repo} (task ${t.id}). You did not build it (CREED 6): assume the builder cut
corners and look for the missing state, the untested acceptance line, the unverified claim, the file outside the task's paths.
Read-only: never edit, commit, push, comment on GitHub, approve or merge.
Read: the task (\`${cli()} show ${t.id}\`; private, for you only), the diff (\`gh pr diff ${b.pr} -R ${O.repo}\`), the PR title and body and
every commit message (\`gh pr view ${b.pr} -R ${O.repo} --json title,body,commits\`). The worktree is ${b.worktree} if you need to run something.
${round ? `This is review round ${round + 1}; earlier rounds asked for fixes, so check those were really made.` : ''}
Verdict: SHIP (ready as is), SHIP AFTER FIXES (small, listed fixes) or DON'T SHIP (wrong approach or unsafe; say why).
fixes = the blocking items, each one concrete (file, what is wrong, what done looks like). notes = non-blocking slips worth a later
tidy-up (they become one tidy-up task). privacyOk = false if the title, body, a commit message, a branch name or the diff carries task
text beyond the public title "${t.public_title || `task ${t.id}`}", a personal value (user folder, private names, emails other than the
noreply one) or a secret-shaped string. why = 2-4 plain sentences.`
}

// ---- MERGE (one at a time across lanes) ---------------------------------------------------------------------------------------------
let mergeChain = Promise.resolve()
function oneAtATime(fn) { const p = mergeChain.then(fn, fn); mergeChain = p.catch(() => null); return p }
function mergePrompt(t, b) {
  return `Merge PR #${b.pr} of ${O.repo} (task ${t.id}). An independent reviewer said SHIP and CI is green; Jordan's standing approval covers
this merge ONLY through the repo's merge script. Never \`gh pr merge\`, never the web button, never force anything, never delete a branch.
1. \`pwsh -NoProfile -File ${ctx.checkout}\\scripts\\merge-pr.ps1 -Repo ${O.repo} -Pr ${b.pr} -Why "task-orchestrate: independent review SHIP, CI green"\`.
   If it refuses: merged=false, refusal = its reason in one line; behind=true only when the reason is that the branch is out of date or
   conflicts with main (the builder can bring main in); stop there.
2. Merged: sha = the merge commit. \`${cli()} set ${t.id} status=done merged=${'<sha>'}\`.
3. Update the main checkout only if it is on main with no local changes: \`git -C ${ctx.checkout} pull --ff-only origin main\`.
4. ${b.touchesPassApp ? `This PR changed pass-app/: redeploy the live Board with \`pwsh -NoProfile -File ${ctx.checkout}\\pass-app\\update.ps1\` (after step 3; if step 3 was skipped, do not
   redeploy and say so). boardRedeploy = its last line.` : 'boardRedeploy = "not needed".'}
5. \`git -C ${ctx.checkout} worktree remove ${b.worktree}\` (the branch stays). worktreeRemoved = whether it worked.`
}

// ---- small bookkeeping agents -------------------------------------------------------------------------------------------------------
async function escalate(t, why, pause) {
  log(`task ${t.id}: needs Jordan (${pause ? 'privacy; orchestrator paused' : 'see the task note'})`)
  await agent(`Run these and nothing else, then return ok and the output in why:
\`${cli()} set ${t.id} status=todo depends+=jordan\`
\`${cli()} note ${t.id} --text "needs Jordan: ${why.replace(/"/g, "'").replace(/\s+/g, ' ').slice(0, 900)}"\`${pause ? `
\`${cli()} pause --reason "privacy problem on task ${t.id}; Jordan checks it"\`` : ''}`, { label: `escalate ${t.id}`, phase: 'Verify', model: 'haiku', effort: 'low', schema: DONE })
  return { id: t.id, outcome: 'jordan', why, privacy: !!pause }
}
async function hold(t, why) {
  await agent(`Run this and nothing else, then return ok and the output in why:
\`${cli()} note ${t.id} --text "merge held: ${why.replace(/"/g, "'").replace(/\s+/g, ' ').slice(0, 600)}"\``, { label: `hold ${t.id}`, phase: 'Merge', model: 'haiku', effort: 'low', schema: DONE })
  return { id: t.id, outcome: 'held', why }
}

// ---- one task: work -> verify (fix rounds) -> merge -----------------------------------------------------------------------------------
const notes = [] // reviewer slips since the last gate
async function runTask(t) {
  let b = await agent(workPrompt(t, null), { label: `work ${t.id}`, phase: 'Work', schema: WORK })
  if (!b) return { id: t.id, outcome: 'died', why: 'the builder stopped (usage cap or error); a rerun resumes it' }
  if (!b.ok) return escalate(t, `builder stopped: ${b.blocked}`, /privacy/i.test(b.blocked))
  for (let round = 0; ; round++) {
    const both = await parallel([
      () => agent(checksPrompt(t, b, false), { label: `checks ${t.id}`, phase: 'Verify', model: 'haiku', schema: CHECKS }),
      () => agent(reviewPrompt(t, b, round), { label: `review ${t.id}`, phase: 'Verify', model: 'sonnet', schema: REVIEW }),
    ])
    let c = both[0]; const r = both[1]
    if (!c || !r) return { id: t.id, outcome: 'died', why: 'a verify agent stopped (usage cap or error); a rerun resumes it' }
    for (let w = 0; c.ci === 'pending' && w < 2; w++) {
      c = await agent(checksPrompt(t, b, true), { label: `ci ${t.id}`, phase: 'Verify', model: 'haiku', schema: CHECKS })
      if (!c) return { id: t.id, outcome: 'died', why: 'the CI check agent stopped; a rerun resumes it' }
    }
    notes.push(...r.notes.map((n) => `task ${t.id} (PR #${b.pr}): ${n}`))
    if (!r.privacyOk) return escalate(t, `reviewer found private text or a personal value in public: ${r.why}`, true)
    log(`task ${t.id}: review ${r.verdict}, suites ${c.testsPass ? 'pass' : 'FAIL'}, CI ${c.ci} (round ${round + 1})`)
    let items = []
    if (r.verdict === 'SHIP' && c.testsPass && c.ci === 'green') {
      const m = await oneAtATime(() => agent(mergePrompt(t, b), { label: `merge ${t.id}`, phase: 'Merge', model: 'haiku', schema: MERGE }))
      if (!m) return { id: t.id, outcome: 'died', why: 'the merge agent stopped; check the PR by hand, then rerun' }
      if (m.merged) return { id: t.id, outcome: 'merged', pr: b.pr, sha: m.sha, board: m.boardRedeploy }
      if (!m.behind) return hold(t, m.refusal)
      items = ['merge-pr.ps1 refused because the branch is behind or conflicts with main: bring origin/main in with a normal merge (never rebase, never force-push), resolve, rerun the suites, push.']
    } else {
      if (c.ci === 'pending' || c.ci === 'none') return hold(t, `CI is ${c.ci} after waiting; review said ${r.verdict}`)
      items = [...r.fixes, ...(c.testsPass ? [] : [`failing suites: ${c.failing.join(', ') || c.tests}`]), ...(c.ci === 'red' ? [`CI red: ${c.ciFailing.join(', ')}`] : [])]
      if (!items.length) items = [`the reviewer said ${r.verdict} without a fix list: ${r.why}`]
    }
    if (round + 1 >= O.rounds) return escalate(t, `${O.rounds} fix rounds used; still open: ${items.join(' | ')}`, false)
    const nb = await agent(workPrompt(t, { round: round + 1, pr: b.pr, items }), { label: `fix ${t.id}.${round + 1}`, phase: 'Work', schema: WORK })
    if (!nb) return { id: t.id, outcome: 'died', why: 'the builder stopped during a fix round; a rerun resumes it' }
    if (!nb.ok) return escalate(t, `builder stopped in fix round ${round + 1}: ${nb.blocked}`, /privacy/i.test(nb.blocked))
    b = { ...b, ...nb, pr: nb.pr || b.pr, worktree: nb.worktree || b.worktree, branch: nb.branch || b.branch, touchesPassApp: b.touchesPassApp || nb.touchesPassApp }
  }
}

// ---- GATE ---------------------------------------------------------------------------------------------------------------------------
async function gate(base, merged, final) {
  const slips = notes.splice(0)
  const g = await agent(`Workspace gate${final ? ' (end of run)' : ''} for ${O.repo}. Checkout ${ctx.checkout}. Merged since the last gate: ${merged.map((m) => `#${m.pr}`).join(', ') || 'none'}.
1. \`git -C ${ctx.checkout} fetch origin main\`; base = ${base || 'origin/main~' + Math.max(1, merged.length)}; head = origin/main. Return base = the head sha (the next gate starts there).
2. Privacy: export the files changed in base..head (\`git -C ${ctx.checkout} diff --name-only <base> origin/main\`, as they are at origin/main via
   \`git show origin/main:<path>\`) into a fresh temp folder, run \`pwsh -NoProfile -File "${O.privacyScan}" -Root <temp> -Json -Patterns <temp-or-checkout>\\scripts\\secret-patterns.ps1\`
   (expand %USERPROFILE%; use the checkout's patterns file), delete the temp folder. privacyLiveHits = the sum of "live" counts. If it is not 0:
   run \`${cli()} pause --reason "privacy scan: live hits after merges ${merged.map((m) => `#${m.pr}`).join(' ')}"\` and set paused=true. Never print a hit's text.
3. Suites: ${final ? `run the repo's whole suite through verify-all with a one-repo config: write a temp JSON {"suites":[{"name":"tide","dir":"<checkout>","glob":"tests\\\\Test-*.ps1","timeoutSeconds":600,"maxMB":2000}]}
   and run \`pwsh -NoProfile -File ${ctx.checkout}\\scripts\\verify-all.ps1 -ConfigPath <temp json>\`; delete the temp file.` : `in a fresh worktree of origin/main (\`git -C ${ctx.checkout} worktree add --detach <temp folder> origin/main\`) run
   \`pwsh -NoProfile -File ${ctx.checkout}\\kitchen\\stations\\tests.ps1 -Dir <that worktree> -Impacted -ChangedFiles <the changed files>\`, then remove that worktree.`}
   testsOk and tests = the result line with counts.
4. Slips become ONE tidy-up task (only if there is at least one problem from steps 2-3 or one note below): write them to a temp file and run
   \`${cli()} new --title "Tidy-up after ${merged.map((m) => `task ${m.id}`).join(', ') || 'recent tasks'}" --public-title "Tidy-up: review notes from recent tasks" --priority 4 --body-file <temp>\`
   (add --paths with the files the notes name, comma-separated), then delete the temp file. tidyTask = its number, else 0.
   Notes from the reviewers (private; they go only into that task file):
${slips.length ? slips.map((s) => `   - ${s}`).join('\n') : '   (none)'}
problems = steps that could not run or failed, in plain words. Never edit code, commit, push or merge here.`, { label: final ? 'gate (final)' : 'gate', phase: 'Gate', model: 'sonnet', schema: GATE })
  return g
}

// ---- PLAN ---------------------------------------------------------------------------------------------------------------------------
function planPrompt() {
  return `Plan step for the task store (private; ${ctx.store}). Nothing is ready to work.
1. \`${cli()} roadmap --next --json\`. If "next" is null: return milestone=0, raised=[], milestoneDone=false, why = the waiting list in plain words.
2. Read that milestone (\`${cli()} show <id>\`) and what its body points to (plan files, sections), the tasks it already has
   (\`${cli()} list --json\`, those with that milestone), the repo as it is now (\`git -C ${ctx.checkout} log --oneline -15 origin/main\`, \`gh pr list -R ${O.repo}\`).
3. If everything the milestone asks for is done or merged: \`${cli()} set <id> status=done\`, milestoneDone=true, raised=[].
4. Otherwise raise at most ${O.planBatch} tasks that can START NOW (their dependencies done or in this batch), no duplicates of existing ones:
   for each, write a body file (## Goal, ## Why (L1-L4), ## Done means (each line becomes a named test), ## Do not touch, ## Stop and ask when)
   and run \`${cli()} new --title "<private title>" --public-title "<neutral public title, no private names>" --milestone <id> --paths <narrow comma list of files or globs> [--depends <numbers>] [--priority 1-9] --body-file <file>\`,
   then delete the body file. Paths must be narrow and honest: lanes run tasks in parallel only when their paths do not clash.
   Work that needs Jordan (a decision, an install, a setting, money, a publish) becomes a task with --depends jordan, saying exactly what he must decide.
   Set the milestone to doing: \`${cli()} set <id> status=doing\`.
Never edit code, commit, push or merge. Return milestone, raised (the new numbers), milestoneDone, why (2-3 plain sentences).`
}

// ---- the loop -----------------------------------------------------------------------------------------------------------------------
const merged = []; const outcomes = []; let sinceGate = []; let gateBase = ''; let stopped = ''; let worked = 0; let plans = 0; let dryPlans = 0
const gates = []
for (let first = true; ; first = false) {
  if (worked >= O.max) { stopped = `reached --max ${O.max}`; break }
  phase('Pick')
  const p = await agent(pickPrompt(first), { label: first ? 'pick (resume)' : 'pick', phase: 'Pick', model: 'haiku', effort: 'low', schema: PICK })
  if (!p) { stopped = 'the pick agent stopped (usage cap or error); run again after the reset'; break }
  if (!ctx) {
    if (p.visibility !== 'PUBLIC') { stopped = p.reason || `${O.repo} is not public (${p.visibility || 'unknown'}); this orchestrator works public repos only`; break }
    ctx = { checkout: p.checkout, cli: p.cli, store: p.store, wtRoot: p.wtRoot }; gateBase = p.mainSha || ''; log(`task store: ${p.store}`)
  }
  if (p.paused) { stopped = `paused: ${p.reason || 'no reason given'}`; break }
  if (p.stop) { stopped = `${p.stop}: ${p.reason}`; break }
  if (!p.tasks.length) {
    if (O.task) { stopped = p.why; break }
    if (p.state !== 'empty' || !O.plan) { stopped = p.why; break }
    if (plans >= O.planRounds) { stopped = `planned ${plans} times this run (--plan-rounds ${O.planRounds})`; break }
    phase('Plan')
    const pl = await agent(planPrompt(), { label: 'plan', phase: 'Plan', model: 'sonnet', schema: PLAN })
    plans++
    if (!pl) { stopped = 'the plan agent stopped (usage cap or error)'; break }
    log(`plan: milestone ${pl.milestone || 'none'}: raised ${pl.raised.length}${pl.milestoneDone ? ', milestone done' : ''}`)
    if (pl.raised.length) { dryPlans = 0; continue }
    if (pl.milestoneDone && dryPlans < 3) { dryPlans++; continue }
    stopped = `nothing to work: ${pl.why}`; break
  }
  phase('Work')
  log(`working ${p.tasks.map((t) => `${t.resume ? 'resume ' : ''}${t.id}`).join(', ')}`)
  const res = (await parallel(p.tasks.map((t) => () => runTask(t)))).map((r, i) => r || { id: p.tasks[i].id, outcome: 'died', why: 'stopped' })
  worked += p.tasks.length
  outcomes.push(...res)
  const now = res.filter((r) => r.outcome === 'merged')
  merged.push(...now); sinceGate.push(...now)
  if (res.some((r) => r.outcome === 'jordan' && r.privacy)) { stopped = 'privacy problem: the orchestrator paused itself for Jordan'; break }
  if (res.some((r) => r.outcome === 'died')) { stopped = 'an agent stopped mid-task (usage cap or error); run again to resume'; break }
  if (O.task) break
  if (sinceGate.length >= O.gateEvery) {
    phase('Gate')
    const g = await gate(gateBase, sinceGate, false)
    if (g) { gates.push(g); gateBase = g.base || gateBase; sinceGate = [] }
    if (!g) { stopped = 'the gate agent stopped (usage cap or error)'; break }
    if (g.paused || g.privacyLiveHits > 0) { stopped = 'gate: privacy scan hit; paused for Jordan'; break }
  }
}
if (ctx && (sinceGate.length || (merged.length && !gates.length) || notes.length)) {
  phase('Gate')
  const g = await gate(gateBase, sinceGate, true)
  if (g) gates.push(g)
}
const tally = (o) => outcomes.filter((r) => r.outcome === o)
log(`done: ${tally('merged').length} merged, ${tally('jordan').length} need Jordan, ${tally('held').length} held. Stopped: ${stopped || 'single task finished'}`)
return {
  stopped: stopped || 'single task finished',
  merged: tally('merged').map((r) => ({ task: r.id, pr: r.pr, sha: r.sha, board: r.board })),
  needJordan: tally('jordan').map((r) => ({ task: r.id, why: r.why })),
  held: tally('held').map((r) => ({ task: r.id, why: r.why })),
  died: tally('died').map((r) => ({ task: r.id, why: r.why })),
  gates: gates.map((g) => ({ privacyLiveHits: g.privacyLiveHits, privacyRan: g.privacyRan, testsOk: g.testsOk, tests: g.tests, tidyTask: g.tidyTask, problems: g.problems })),
  plans,
}
