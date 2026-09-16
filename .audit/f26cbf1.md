# Audit of f26cbf1

Reviewed `03a967f9edf8` (task 105) and `f26cbf1a21a3` (roadmap completion): challenge/header encoding, credential decoding, Plug configuration and extraction, HTTP client selection/attachment, regression and cross-validation tests, mutation anchors, and documentation.

Three findings; two fixed:

- Updated the README to document `requires_auth: true` and the alternate credential field; corrected indentation in the transport callback documentation.
- Hardened optional credential-field validation while preserving the existing tagged-error contract. Added boundary and normalization regression coverage.
- Filed **task 125** via `rmap new --from-stdin`: align stale Payment header cleanup with the existing credential parser's accepted casing and whitespace. Assigned to `codex` / `gpt-6-astra`. The generated roadmap changes are included under this audit's explicit discovery-filing instruction.

No leftover debug output was found in the reviewed production changes. The HMAC layout discrepancy is explicitly documented in the landed implementation and covered by reference-SDK tests; this audit did not independently rerun those cross-validation tests. No reviewer rejections were supplied, so there is no false-rejection finding. CHANGELOG remains curated release notes and was left unchanged as instructed; it does not yet mention task 105.

Validation:

- Before changing credential code, `mix test.json test/mpp/credential_test.exs --cover --quiet --output /tmp/mpp-audit-coverage.json` measured `MPP.Credential` at 97.62%, above the critical 95% threshold.
- After the fix, the focused credential suite passed all 32 tests, with 97.67% module coverage.
- `mix precommit` passed after the fixes: 2,104 tests passed, zero failed/skipped, 147 excluded by the project's integration/cross-validation policy; total coverage 96.93%. Formatting, compilation, Credo, Doctor and Sobelow passed.
- Cold witness: `mix check.dispatch` passed (exit 0), including zero Dialyzer warnings and the dependency audit. The initial `mix check.dispatch` stopped on absent dependencies. `mix deps.get` then succeeded without a lockfile change, and `mix check.dispatch` was run in this previously unwarmed tree without copying dependencies, builds or PLTs.

The merge remains settled; all changes are forward fixes. These are audit observations and executed-check evidence, not a new harness reviewer verdict.

The cold check explicitly skipped the AGENTS.md freshness and advisory-mirror freshness host scripts because they were absent/not executable in this environment; the project owns those skip conditions. Integration and SDK cross-validation were not run by this gate. Cold-check evidence: `/tmp/mpp-audit-cold-check.log`; post-fix evidence: `/tmp/mpp-audit-fix-check.log` and `/tmp/mpp-audit-credential-result.json`.
