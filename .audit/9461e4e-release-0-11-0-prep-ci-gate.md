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

## Codex second opinion (2026-08-18)

Codex's verdict on the commit snapshot was **REQUIRES CHANGES**; two of its five
findings are already closed on `main`.

| finding | verdict |
|---|---|
| `mix ci` ran `sobelow --skip` without `--exit`, so findings returned success while the gate was described as hardened (prio 8) | **Confirmed for the snapshot, already closed** — `295f7ce` changed it to `sobelow --skip --exit low` (`mix.exs:188` at HEAD). No action. |
| `mix.exs:66` `{:ex_ast, "~> 0.12"}` admits every `0.x` through `0.99.x` although the changelog calls 0.13 semantics unmeasured (prio 6) | **Confirmed, FIXED** — tightened back to `~> 0.12.0`, matching reach's own `ex_ast` requirement in `mix.lock`. Latent, not active: reach already constrained resolution to 0.12.x. |
| Host-only checks return `:ok` when their script is absent, so GitHub Actions always skips `agents.check` while the alias comment claims AGENTS-freshness evidence (prio 6) | **Confirmed, by design, left as is.** `sync-agents-md.sh` lives in the claude-marketplace checkout, not in this repo, so a runner genuinely cannot execute it — the alternative is vendoring the script. The gate's real enforcement point is the developer host, where it does run (verified this session: `OK: ./AGENTS.md is up to date`). Flagged rather than papered over. |
| `CHANGELOG.md:96` 0.11.0 notes report the parent's dep versions, not the released ones (onchain 0.11.0 vs 0.12.0, cartouche 0.6.0 vs 0.6.1, descripex 0.11.0 vs 0.12.0, Req 0.7.1 vs 0.7.2) (prio 5) | **Confirmed, NOT fixed here.** `CHANGELOG.md` carries uncommitted changes from another session; editing it would mix work. Left for whoever owns that diff. |
| `test/mpp/descripex_test.exs:82` the documented `short_name` atom→string change is unasserted (prio 4) | **Confirmed, open.** Contract regression would go undetected. |

Codex separately verified the coverage scope was **not** reduced by this commit:
threshold still 95%, exclusions equivalent, measured 96.49%.
