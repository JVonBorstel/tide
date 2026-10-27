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
    any https URL ending in `.git`) becomes `<private repo>`. The exception is the public repo, `JVonBorstel/tide`.
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
