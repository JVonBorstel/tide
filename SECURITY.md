# Security

This is a private, single-owner repository (personal infrastructure: the brain monitor, the Yard (code: `kitchen/`), and the Board app (code: `pass-app/`)). There is no public
release and no support channel; this file says how secrets are handled and what to do if one leaks.

## Secrets
- No secret ever goes in code, tests, docs, commit messages, issues, PRs or CI logs. That includes API keys, tokens, passwords, private keys and personal data.
- The Board's pass key (`pass-key.txt`) lives only in the Yard's local state folder (`%LOCALAPPDATA%\brain-kitchen`). It is never committed, never sent anywhere, and `.gitignore` also blocks `.env*`, `*.pem`, `*.pfx`, `*.key` and `data/`.
- Test fixtures use obviously fake values, built from fragments where they would look real. The few reviewed exceptions are listed in `.github/secret-scan-allow.txt`.
- CI uses no repository secrets. Workflows run with the default `GITHUB_TOKEN`, read-only except the release job (`contents: write`).
- Every change is scanned before merge: `scripts/secret-patterns.ps1` (run in the CI `checks` job via `scripts/ci-quick-checks.ps1`) and the lint station.

## If a secret leaks
1. Treat it as compromised: revoke or rotate it at its provider first. Deleting it from git is not enough.
2. Tell Jordan (the owner).
3. Remove it from the code, then decide with Jordan whether history needs rewriting. Rotation matters more than the rewrite.

## Reporting a vulnerability
Report to the owner, Jordan von Borstel (GitHub: @JVonBorstel), privately: never in a public issue. Include what you found, where, and how to reproduce it; do not include live secret values.
