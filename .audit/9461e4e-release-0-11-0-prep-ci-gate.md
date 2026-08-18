# audit 9461e4e — release: 0.11.0 prep — harden the CI gate, adopt descripex 0.12 / styler 1.12 / req 0.7.2

verdict: clean
scope: `mix.exs` (gate aliases), `.github/workflows/ci.yml`, `.mix_audit_ignore`, `.reach.exs`,
       `lib/mpp/expires.ex`, `lib/mpp/plug.ex`, tests, CLAUDE.md/AGENTS.md
reviewers: Claude only — Codex second-opinion not dispatched (session policy)

## Categories 1-6

- **Cat 1 — `DateTime.add/3` → `DateTime.shift/2` (2 sites).** `MPP.Expires.offset_iso8601/1` and
  `MPP.Plug.compute_expires/1` both start from `DateTime.utc_now/0`. `shift/2` is calendar-aware
  and `add/3` is arithmetic, so the two diverge only across a zone offset change — impossible on
  UTC. Equivalent here. `shift/2` needs Elixir ≥ 1.17 and `mix.exs:11` pins `~> 1.17`. No finding.
- **Cat 1 — `.mix_audit_ignore`.** Advisory IDs only, and the gate itself (`deps.audit.gated`)
  fails if `cowboy` enters `mix.lock` while `GHSA-w4f7-4cxr-rv3c` is still ignored, so the ignore
  can't silently outlive its scope. No finding.
- Cat 2-5: no findings. The mix.exs growth is alias definitions, not logic.
- **Cat 6:** CHANGELOG carries the release section; CLAUDE.md's "Toolchain & check commands"
  section and AGENTS.md were regenerated in the same commit. `sync-agents-md.sh --check` passes on
  the current tree.

## Verified rather than assumed

`.reach.exs` gating with `--path lib` is load-bearing (reach otherwise auto-discovers gitignored
sibling checkouts that don't exist on a runner) — the CI workflow passes `--path lib`. ✓
