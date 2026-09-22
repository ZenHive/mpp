# Audit: 9e73dbe

Reviewed integrated revision `9e73dbe623a19a30dd1fc4849e523631ba261892`, range
`3bf67c52ca1ab1d03909957e6705a743b6456a3f..9e73dbe623a19a30dd1fc4849e523631ba261892`
(12 commits). Landing remains settled.

## Review

Inspected the x402 Plug requirements/extension changes, their tests and callers,
settlement documentation and changelog; Mint lock update; toolchain pins;
dispatch/full-QA aliases and regression tests; generated instructions; roadmap
transitions/model pins; and the preceding audit. No leftover debug additions,
dead-code additions, naming regressions or missing release notes were found.
The x402 documentation distinguishes its settlement assignment from native MPP
receipts. Live settlement evidence is historical documentation, not a live test
result from this audit. No reviewer rejections were supplied to reassess.

The module map omits x402; pending Task 129 already owns map completeness, so
no duplicate task was filed. Task 134 owns the custom EIP-3009 callback work.
The repository advisory query returned only published advisories, no draft or
triage items. Existing cowlib/gun warnings remain under the supplied adjudication;
this audit did not reopen them.

## Findings and repairs

Three actionable findings; one fixed inline, two filed for normal implementation
and independent review:

1. The critical coverage task's output assertion failed under the configured
   `test.json --quiet` command: expected `money-critical modules at or above 95%`,
   captured an empty string at test/mix/tasks/mpp.cover.critical_test.exs:177.
   The runner classified it as flaky after its one automatic retry passed.
   `test.json` sets the global Mix shell to Quiet. Fixed the test by selecting
   Mix.Shell.IO for run/1 tests, restoring the prior shell on exit, and making
   this module synchronous so its shell changes cannot race other tests.
   No assertions, thresholds or retry settings were weakened.
2. **Task 135**, filed with `rmap new --from-stdin`: add x402 to the critical
   coverage tier and cover its missing behavior. The gate currently excludes
   lib/mpp/x402/ and lib/mpp/x402.ex despite payment/signing responsibilities.
   Measurements below establish the gap. This needs substantive tests and review,
   not a threshold adjustment in an audit.
3. **Task 136**, filed with `rmap new --from-stdin`: make AGENTS and advisory-mirror
   freshness proofs executable in isolated worktrees. Both configured checks
   skipped for absent developer-host scripts. Existing pending tasks do not own
   this cause; completed Task 133 only separates dispatch from full QA. The
   preceding audit recorded identical skips as passed; this audit judges them
   incomplete under the explicit all-checks-completed requirement.

The audit-specific task-filing instruction takes precedence over the generic
roadmap prohibition: Tasks 135/136 and their generated roadmap views are included
in this audit commit so the filings survive cleanup.

## Original-revision full QA

**Incomplete**, even though the final alias exited 0. Every configured step was
attempted before source edits; two freshness proofs did not execute. No server,
operator database, deployment or service restart was used.

Toolchain: Erlang/OTP 29.1 (ERTS 17.1), Elixir 1.20.4 compiled for OTP 29.

| Command / step | Observed result |
| --- | --- |
| `mix precommit.full` (cold attempt) | Exit 1: dependencies absent; no checks completed. |
| `mix deps.get` | Exit 0; locked dependencies fetched, lock unchanged. Hex reported existing adjudicated cowlib/gun warnings. |
| `mix precommit.full` (after bootstrap, same revision) | Exit 0; outcomes below, judged incomplete. |
| `mix format --check-formatted` | Passed; alias proceeded. |
| `mix compile --warnings-as-errors` | Passed. Dependency compilation emitted dependency warnings; project compile passed. |
| `mix credo --strict --ignore TagTODO,TagFIXME` | 259 source files, 4,797 modules/functions, no issues. |
| `mix doctor --raise` | 122 passed modules, 0 failed; docs/moduledocs/specs all 100%. |
| `MIX_ENV=test mix test.json --quiet --cover --cover-threshold 95 --exclude integration --exclude cross_validation --output _build/test/cover.json` | 2,307 passed, 0 final failures, 166 excluded, 0 skipped, 1 initial failure healed on automatic retry. 2,474 total entries include the flaky record. |
| Coverage | 7,921 / 8,220 lines = 96.36%; aggregate threshold met. |
| `mix mpp.cover.critical` | Passed for the configured tier, which excludes x402. |
| `mix sobelow --skip --exit low` | SCAN COMPLETE; no router warning is expected for this Plug library. |
| `mix ex_dna --max-clones 0` | 116 files, no duplication, clone budget 0/0. |
| `mix reach.check --arch --smells --path lib` | 116 files, architecture OK, no smells. |
| `mix dialyzer.json --quiet` | Dialyzer 6.0.3; warnings [], total 0, skipped 0. |
| `mix agents.check` | SKIPPED: /home/harness/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh not executable. |
| `mix deps.audit.gated` | Scope/mirror-population checks completed; audit reported No vulnerabilities found. Freshness SKIPPED: /home/harness/_DATA/code/onchain-stack/bin/advisory-freshness.sh not executable. |
| `gh api repos/ZenHive/mpp/security-advisories` (id/state projection only) | 15 published records; no open draft/triage records. |
| `git diff --check 3bf67c5..HEAD` | Passed. |

Integration and cross-validation tests were excluded by the configured command;
no claim of fresh external-provider verification is made. The logged XRPL ledger
confirmation error did not produce a final failed test. The JSON, rather than
log severity or the alias exit code, supplied the suite result.

Measured x402 coverage:

| Module | Percent |
| --- | ---: |
| MPP.X402 | 67.44 |
| MPP.X402.Exact | 72.84 |
| MPP.X402.Facilitator | 31.58 |
| MPP.X402.Headers | 69.23 |
| MPP.X402.Nonce | 91.67 |
| MPP.X402.Plug | 77.78 |
| MPP.X402.Replay | 83.33 |
| MPP.Client.Providers.X402Exact | 66.67 |

## Fix verification

`mix format test/mix/tasks/mpp.cover.critical_test.exs` completed, followed by
`MIX_ENV=test mix test.json test/mix/tasks/mpp.cover.critical_test.exs --quiet --no-retry --output /tmp/mpp-audit-9e73dbe-focused.json`:
**18 passed, 0 failed, 0 excluded, 0 skipped** (exit 0). This specifically exercises
the previously failing assertion with the original quiet mode and retries disabled.
No production code changed. The full suite was not rerun after this isolated test
fixture repair. `git diff --check` passed; rmap validated both task insertions.
