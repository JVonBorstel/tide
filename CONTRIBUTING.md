# Contributing

Private repo, one owner. The path for every change:

**branch -> PR -> CI green -> Jordan's yes -> merge**

1. Branch from `main` (`feat/...`, `fix/...`, `ci/...`). Do not commit to `main` directly.
2. Open a PR and fill in the template: in plain words, what changed, why, proof, L1-L4 effect, risk, rollback. House rules for code: `kitchen/STANDARDS.md`.
3. CI must be green. The `checks` job (fast) runs on every push to main and every PR. The full Windows suite (`windows-suite.yml`) runs weekly and by hand; the Yard (code: `kitchen`) runs it locally before every PR.
4. Jordan says yes. Nothing merges without it.
5. Merge. A green `main` is tagged and released automatically (see `docs/RUNBOOK.md`).

## Tests
Run every suite through the bounded runner so a hang cannot eat the machine:

```powershell
pwsh -NoProfile -File scripts\run-bounded.ps1 -Script tests\Test-X.ps1 -TimeoutSeconds 300 -MaxMB 1500
```

Quick local version of the CI `checks` job (parse, `node --check`, JSON, secret scan): `pwsh -NoProfile -File scripts/ci-quick-checks.ps1`.

## The readiness gate
A change is ready when **both** pass:
- `scripts\verify-all.ps1` (every configured suite, bounded), and
- the sandboxed tests station on a fresh worktree (`kitchen\stations\tests.ps1 -Dir <fresh worktree>`), which is what the CI `tests` job does.

## House rules
- Read `AGENTS.md` first. No secrets, ever (see `SECURITY.md`).
- Node scripts stay dependency-free; the Rust crate stays std-only.
- Keep CI cheap: no extra full-suite runs, path filters and concurrency stay on.
