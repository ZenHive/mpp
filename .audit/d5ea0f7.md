# Audit: d5ea0f7

## Scope and judgment

Reviewed integrated revision `d5ea0f7fffdf545c6bc4b3e4c266c0ef0c76ab8c`, covering
`3bf67c52ca1ab1d03909957e6705a743b6456a3f..d5ea0f7fffdf545c6bc4b3e4c266c0ef0c76ab8c`
(131 commits, 189 changed files). Landing remains settled.

Reviewed the range inventory and prior audit reports, the integrated header,
receipt, verifier, currency-offer, session persistence and settlement changes,
Solana, Stripe, USDC and x402 surfaces, and their documentation. Inspected Task
137's Tempo removal and regressions in detail: startup rejection, omitted memo
advertisement, client attribution, receipt matching, machine-token calls and
pre-cosign checks. The transport-neutral verifier still injects challenge ID and
realm before method verification. Prior audit repairs remain present. This is a
best-effort hygiene review, not a new exhaustive protocol/security certification.
No reviewer rejections were supplied to reassess.

**Four findings, one fixed.** Full QA is **failed**: 2,581 tests passed and one
existing mutation-ledger mismatch was confirmed by automatic retry. Aggregate
coverage is 97.59%; every critical-module floor passes. Configured analyzers
passed. Advisory freshness remains incomplete. No independent reviewer approval
of this documentation repair is claimed.

## Findings and fixes

1. **Fixed: stale parity documentation references.** In
   `docs/security-parity.md`, replaced the removed `escape_non_latin1/1` reference
   with `escape_non_ascii/1` and described the encoder's expanded escaping.
   Updated `prepare_sponsored_transaction/5` to `/4` and
   `check_matched_memo_binding/3` to `/2`, matching the landed Tempo simplification.
   These are documentation-only changes; no verification behavior changed.
2. **Unresolved, already owned: mutation evidence.** The executable ledger test
   reports `fingerprint_mismatch`. Existing Task 141 owns running the campaign
   and refreshing evidence from observed results. The ledger, assertions and
   thresholds were not changed. This repeats `.audit/d304932.md` rather than
   establishing a new defect requiring another task.
3. **Unchanged by instruction: release-note gaps.** Unreleased notes omit Task
   137's breaking static Tempo memo removal and Task 149's ordered currency
   offers/funding-currency receipts. README and API docs describe these features.
   CHANGELOG is protected for this run and remains untouched.
4. **Incomplete prerequisite: advisory freshness.** The populated advisory
   mirror produced no findings, but its host-only freshness script is absent.
   Exit zero does not prove that the advisory data is current.

## Full-project QA at the original integrated revision

All configured checks ran before editing tracked files. No operator server or
database was used, and no server, deployment, restart, revert or landing action
was performed. `mix.lock` remained unchanged after dependency bootstrap.

- Cold `mix precommit.full` could not start because Hex dependencies were absent:
  `** (Mix) Can't continue due to errors on dependencies`.
- `mix deps.get` completed successfully (exit 0).
- Bootstrapped `mix precommit.full` exited 1 after its nested test command exited
  2. Remaining checks were executed independently to collect every outcome.

| Command | Outcome |
| --- | --- |
| `mix format --check-formatted` | Passed inside the full alias |
| `mix compile --warnings-as-errors` | Passed inside the full alias |
| `mix credo --strict --ignore TagTODO,TagFIXME` | Passed; 277 source files, 5,439 modules/functions, no issues |
| `mix doctor --raise` | Passed; 129 modules, zero failed, documentation/moduledoc/spec coverage each 100% |
| `env MIX_ENV=test mix test.json --quiet --cover --cover-threshold 95 --exclude integration --exclude cross_validation --output _build/test/cover.json` | Failed: 2,581 passed, 1 failed, 180 excluded; 97.59% coverage |
| `mix mpp.cover.critical` | Passed; all money-critical modules meet their configured floor |
| `mix ex_dna --max-clones 0` | Passed; 123 files, no clones, budget 0/0 |
| `mix reach.check --arch --smells --path lib` | Passed; architecture OK, no smells across 123 files |
| `mix dialyzer.json --quiet` | Passed; zero warnings, zero skipped warnings |
| `mix sobelow --skip --exit low` | Passed; scan completed without findings |
| `mix agents.check` | Passed: `OK: ./AGENTS.md is up to date` |
| `mix deps.audit.gated` | Exit 0, no vulnerabilities found; freshness incomplete |

Suite evidence: seed `163713`, 2,762 total tests, zero skipped/invalid/flaky;
one retried and one confirmed failure. Coverage is 9,066/9,290 lines, exceeding
the configured aggregate 95% threshold. The sole failed test is:

```text
test/mutation/security_campaign_test.exs:30 (assertion line 33)
test ledger matches the executable campaign and has no unclassified survivors
assert :ok = SecurityMutations.validate_ledger(ledger, File.cwd!())
actual: {:error, :fingerprint_mismatch}
```

Independent check output:

```text
[mpp.cover.critical] 2581 passed, 1 failed, 180 excluded · aggregate 97.59%
[mpp.cover.critical] money-critical modules at or above 95% (exempt: at most 10 relevant lines)
No code duplication detected (123 files)
Clone budget: 0/0
Cross-Function Smell Detection: (no issues)
Dialyzer summary: total 0, skipped 0, warnings []
... SCAN COMPLETE ...
OK: ./AGENTS.md is up to date
[skip] advisory-mirror freshness check:
/home/harness/_DATA/code/onchain-stack/bin/advisory-freshness.sh
not executable (developer-host script, absent in CI).
No vulnerabilities found.
```

Dependency compilation and Sobelow lockfile parsing emitted warnings. The XRPL
ledger-confirmation error log came from an exercised error-path test; it was not
another failed test. The configured suite excludes integration and cross-validation;
no live-provider or cross-language verification is claimed for this audit.

## Repair validation

Checked the three corrected helper names/arities against their definitions and
call sites in `lib/mpp/headers.ex` and `lib/mpp/methods/tempo.ex`. Confirmed the
obsolete references are absent from the updated parity document.
`git diff --check` passes. No code was edited, so the completed code checks were
not repeated. Roadmap and CHANGELOG files remain unchanged.

The outcomes and material output above are durable evidence; temporary logs under
`/tmp/mpp-d5ea0f7-*` are not needed to interpret this report. QA retains the
original integrated revision and remains failed despite the documentation repair.
The machine summary in `.harness/audit.json` is deliberately uncommitted.

## Proposed tasks

None. Task 141 already owns the substantial mutation-evidence repair. No duplicate,
documentation, coverage, lint or freshness task is proposed.
