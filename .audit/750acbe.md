# Audit: 750acbe

Reviewed 28 landed commits at integrated revision
`750acbe288d165621f63ef2f74855616569154fa`, covering
`3bf67c52ca1ab1d03909957e6705a743b6456a3f..750acbe288d165621f63ef2f74855616569154fa`.
Landing remains settled; this is a fix-forward audit, not an acceptance gate.

## Review and findings

Inspected the x402 client URL-match removal, server requirements/extension binding,
critical-coverage expansion and regression tests; method-name grammar and HMAC
vector changes; documentation, release notes, SDK watch metadata, dependency and
runtime pins; focused/full-QA aliases; generated instructions, roadmap and earlier
audit evidence. No reviewer rejections were supplied to reassess. No additional
dead code or debug-output defect was found.

Six findings, two fully fixed inline:

1. **Fixed — integrated x402 test regression.** Task 135 added two calls to
   `MPP.X402.challenges_from_header/2` in `test/mpp/x402_test.exs`; Task 140 removed
   that arity. Baseline full QA confirmed UndefinedFunctionError. Replaced the
   obsolete URL-mismatch assertions with resource-preservation verification using
   the supported API. Existing HTTP tests cover differing resource/response URLs;
   Plug tests retain server binding. Updated Task 140 with repair evidence.
2. **Fixed — broken Markdown table.** Four newly added parity rows were separated
   from their table by a horizontal rule. Rejoined the rows in
   `docs/security-parity.md` without changing their technical claims.
3. **Tracked — mutation evidence mismatch.** Full QA confirmed
   `{:error, :fingerprint_mismatch}` at `test/mutation/security_campaign_test.exs:33`.
   The fingerprint includes complete mutation source/test inputs changed by this
   range. Existing Tasks 82 and 93 are done and cover campaign delivery/scheduling,
   not the current evidence repair. Filed **Task 141** to execute and review the
   real campaign and refresh evidence from observed results. No fingerprint was
   rewritten and no test was weakened. Campaign reconciliation requires normal
   implementation and independent review.
4. **Tracked — recurring freshness prerequisites.** Both host-script checks still
   skip. Updated existing **Task 136** rather than duplicating the known cause.
5. **Tracked — release-note gap.** Task 140 explicitly required documenting its
   removed public arity in CHANGELOG; that entry is absent. The existing critical
   coverage entry also omits Task 135's x402 expansion. Filed **Task 142**; left
   CHANGELOG unchanged as directed by the operational rules.
6. **Tracked — private inbox and stale public count.** Authenticated repository
   advisory queries found three reports awaiting triage and 15 published records.
   Updated only the generic pending count in the public ledger and filed
   **Task 143** for private adjudication and repair coordination. These reports
   are not adjudicated findings. Their identities and details remain private.

All newly filed tasks use the supplied catalog routing `codex` / `gpt-6-astra`.
Task 129 continues to own the previously known module-map completeness gap.
Task 135's coverage expansion now passes the integrated critical gate. The
specific discovery/repair-filing instruction authorizes the roadmap changes in
this audit; generated roadmap artifacts are included so the records persist.

## Full-project QA at the original revision

**Failed**, with additional incomplete freshness checks. Every configured step
was attempted before editing tracked files. The bootstrapped full alias stopped
at the failed suite; remaining steps were run independently at the same revision.
A later focused test repair does not change this baseline judgment.

Toolchain: Elixir 1.20.4, OTP 29 (pinned Erlang 29.1), Dialyzer 6.0.3.

| Command / step | Outcome |
| --- | --- |
| `mix precommit.full` (cold) | Exit 1: dependencies unavailable. |
| `mix deps.get` | Exit 0; lock unchanged. Existing adjudicated cowlib/gun notices; adjudication not reopened. |
| `mix precommit.full` (bootstrapped) | Exit 1 after the nested test runner exited 2. |
| `mix format --check-formatted` | Passed within the alias. |
| `mix compile --warnings-as-errors` | Passed within the alias; cold dependency compilation emitted dependency warnings. |
| `mix credo --strict --ignore TagTODO,TagFIXME` | 262 files, 4,807 modules/functions, no issues. |
| `mix doctor --raise` | 122 passed modules, 0 failed; doc/moduledoc/spec coverage each 100%. |
| `MIX_ENV=test mix test.json --quiet --cover --cover-threshold 95 --exclude integration --exclude cross_validation --output _build/test/cover.json` | 2,336 passed, 2 failed, 166 excluded, 0 invalid/skipped; 2,504 total; seed 519963. Both failures confirmed by one automatic retry, 0 flaky. |
| Aggregate coverage | 8,024 / 8,217 lines = 97.65%; 95% threshold met despite failed tests. |
| `mix mpp.cover.critical` | Exit 0: all configured money-critical modules meet the floor. This check grades coverage, not suite success. |
| `mix sobelow --skip --exit low` | Exit 0, SCAN COMPLETE; no-router warning for this Plug library. |
| `mix ex_dna --max-clones 0` | Exit 0; 116 files, no duplication, clone budget 0/0. |
| `mix reach.check --arch --smells --path lib` | Exit 0; 116 files, architecture OK, no smell issues. |
| `mix dialyzer.json --quiet` | Exit 0; warnings [], total 0, skipped 0. |
| `mix agents.check` | Exit 0 but SKIPPED; missing executable script. |
| `mix deps.audit.gated` | Exit 0; scope and populated-mirror guards completed, audit reported no vulnerabilities; freshness SKIPPED. |
| `gh api repos/ZenHive/mpp/security-advisories` (filtered read-only queries) | Exit 0; counts recorded above; private detail excluded from artifacts. |
| `git diff --check 3bf67c5..750acbe` | Passed. |

Baseline suite failures:

- `MPP.X402Test`, mixed offers test, call at line 32: undefined
  `MPP.X402.challenges_from_header/2`.
- `MPP.Test.SecurityMutationCampaignTest`, ledger test at line 33:
  expected `:ok`, received `{:error, :fingerprint_mismatch}`.

Baseline x402 coverage:

| Module | Percent |
| --- | ---: |
| MPP.X402 | 95.00 |
| MPP.X402.Exact | 100.00 |
| MPP.X402.Facilitator | 100.00 |
| MPP.X402.Headers | 99.15 |
| MPP.X402.Nonce | 100.00 |
| MPP.X402.Plug | 97.22 |
| MPP.X402.Replay | 100.00 |

Exact missing-prerequisite output:

```text
[skip] AGENTS.md freshness check: /home/harness/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh not executable (developer-host script, absent in CI).
[skip] advisory-mirror freshness check: /home/harness/_DATA/code/onchain-stack/bin/advisory-freshness.sh not executable (developer-host script, absent in CI).
```

The XRPL ledger-confirmation log was not a separate test failure; suite JSON names
only the two failures above. Integration and cross-validation are excluded by the
configured full command; this audit claims no fresh live-provider verification.
No operator database/server, deployment, restart or landing control was used.

Logs were captured as `/tmp/mpp-750acbe-qa-cold.log`,
`/tmp/mpp-750acbe-deps.log`, `/tmp/mpp-750acbe-qa.log`, and
`/tmp/mpp-750acbe-check-0.log` through `-6.log` (independent commands in the order
listed above, starting with the critical gate). Outcomes and relevant evidence
are preserved here so cleanup of temporary logs does not erase the QA result.

## Repair validation

After editing, `mix format test/mpp/x402_test.exs` and
`mix compile --warnings-as-errors` completed successfully. Ran:

```sh
MIX_ENV=test mix test.json test/mpp/x402_test.exs test/mpp/client/transport/http_test.exs test/mpp/x402/plug_test.exs --quiet --no-retry --output /tmp/mpp-750acbe-focused.json
```

Exit 0: **52 passed**, 0 failed/excluded/skipped/invalid, seed 570907. These focused
checks exercise the repaired parser test, client URL compatibility and server
binding. No runtime source was changed. Full QA was not repeated; the unresolved
mutation evidence and freshness findings remain explicit repair tasks.

`rmap validate --check-render` and `git diff --check` passed. Reviewed the joined
Markdown rows and generic private-inbox count. `.harness/audit.json` records the
original revision and remains uncommitted.
