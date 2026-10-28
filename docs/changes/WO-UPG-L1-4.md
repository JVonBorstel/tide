# WO-UPG-L1-4: secrets, tailnet names and private remotes redacted by pattern; neutral words (2026-10-27)

**What:**
- `core/ledger/share.mjs` now redacts these by their shape, without needing the private words list. It runs on every ledger export:
  `work.json`, `ledger.next.json` and its pages, and every `--json` answer and error line.
  - Secrets: GitHub tokens (`ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_`, `github_pat_`), `sk-` keys (Anthropic, OpenAI and the like),
    Slack tokens (`xox?-`), JWTs, and `Bearer`/`Basic` header values.
  - Key values: anything given to a key named like a secret (`api_key=`, `password: "..."`), and any long hex or base64 value in
    key=value form. The key stays and the value becomes `<secret>`. A value without a digit and under 20 characters stays, so
    "token expired" and a required password field read as written.
  - Tailnet names (`tail1a2b3c`, `tail-1a2b3c`, with or without `.ts.net`) and addresses in the Tailscale range (100.64/10) become `<private host>`.
  - The owner/name of a git remote (`git@host:owner/repo`, `ssh://git@host/...`, `https://[user@]github.com|gitlab.com|bitbucket.org/...`,
    any https URL ending in `.git`) becomes `<private repo>`. The exception is the public repo, `VonBorstel-J/tide`.
    Ordinary web links stay.
- Public text uses neutral words: the code comment, the warning and `ledger-private-words.example.json` say "private topics".
- Not done: the live private words file in the state folder. The lane's brief keeps the live state folder read only, so creating it
  stays a card for Jordan (CARDS.md 11).
- Still switched off: `upgrade.ledger` stays `old`.

**L1-L4:**
- Person: a token or a private repo name in a goal or a Yard reason is not shown off this PC through the ledger.
- Business: none. MSP: none.
- Community: tested secret and remote patterns for anyone sharing work data.

**Tests:** `tests/core/ledger/test-ledger.mjs`: 214/0 (28 new, named `l4: ...`, adversarial: each pattern, its near misses, the public
repo and ordinary links kept). Secret-shaped test values are built at run time, so the CI secret scan stays clean.

**Follow-up (review of #38, 2026-10-26):**
- F1: a 40 or 64 hex git id given to a key that names one (`sha=`, `commit:`, `head:`, `tree:`, `merge_sha`, `headSha`, `sha256:`) is no longer `<secret>`; other hex values still are.
- F2: remotes followed by `,` `;` `>` `|` `*` or a full stop are redacted; nested `git@host:grp/sub/repo` paths; `ssh://[user@]host:port/...` (the port is no longer read as the owner); `git://`, `git+https://`.
- F3: remotes in any case (`HTTPS://GITHUB.COM`, `GIT@`); `api.github.com/repos/o/r`, `raw.githubusercontent.com/o/r`, `codeload.github.com`, `dev.azure.com/.../_git/r`; a user part other than `git@` is dropped from a remote. A bare `Owner/repo` is redacted after `gh repo clone`, `--repo`, `-R`, `repo:`, as `Owner/repo#12` or `@sha`, with the public owner (`VonBorstel-J/` anything but the public repo), or when shaped like one (Capitalized owner, repo with a dash, dot, underscore or digit). A plain lower-case `owner/repo` with no cue is not guessed (it would hit paths): the private words list covers it.
- F4: secret keys quoted in JSON (`"token": "..."`, `"apiKey":"..."`, escaped `\"token\":\"...\"`).
- F6: a tailnet name needs a digit (`tail-fade`, `tail-dead`, `tailadded` stay; `tail1a2b3c`, `tail-9f8e7d` and `*.ts.net` go).
- Tests (ledger suite now 343/0): `testRedactionHardening` in `tests/core/ledger/test-ledger.mjs` (`l4f: ...`): git ids kept, odd hex still redacted, private remote shapes, bare/cased/api/raw shapes, the public repo in many forms, near misses, JSON keys, tailnet words, idempotence, long-input timing. Placeholders only (`Example/private-repo`).
