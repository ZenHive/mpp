# Audit: a397303 — Update release docs for 0.8.0 (install pin, supported versions, hardening delta)

- **Date:** 2026-07-08
- **Classification:** tiny (fast-path) — doc-only, 3 files, +4/−3 lines
- **Reviewers:** Claude (fast-path; no Codex dispatch per tiny-commit rule)

## Scope

Release-doc alignment for 0.8.0: README install pin `~> 0.7.0` → `~> 0.8.0`, SECURITY.md supported-versions table 0.7.x → 0.8.x, and a new row in `docs/tempo-hardening-delta.md` documenting the presenter-identity-binding hardening (Task 75).

## Findings

None.

- Version bumps are consistent with the 0.8.0 release commit (22c1cf9) and `mix.exs` at the time.
- The hardening-delta row accurately describes the shipped feature (opt-in `"require_presenter_binding"`, EIP-712 proof envelope, `presenterBinding` 402 advertisement) and correctly attributes it as a ZenHive extension beyond both reference SDKs, referencing only the published GHSA-34g7-vx6g-82mq — disclosure policy respected (no unpatched-vuln detail).
- README pin was superseded same-day by 0.9.0 (fde6788); expected for sequential releases.

## Verdict

Clean. No fixes applied.
