# Audit bf3c3df

Reviewed the supplied landed range `3b7e43a^..bf3c3df`: XRPL charge and session
methods, codec/claim/wallet/RPC helpers, shared channel actions and network-keyed
ETS state, Plug challenge TTL propagation, Tempo reserve canonicalization,
associated tests and fixtures, discovery registration, release notes, module maps,
and security/mutation documentation. This was a post-merge hygiene review, not a
new live-provider conformance evaluation.

Four documentation findings, all fixed:

1. README session overview omitted redemption on close. Added retained-claim
   redemption and a link to signing/deferred-redemption configuration.
2. Unreleased notes omitted transaction-age verification and session redemption.
   Added both, including `destination_secret`, `defer_redemption`, and `redeem/2`.
3. Session setup implied all stores were automatically namespaced. Clarified that
   the built-in ETS store receives network options automatically; custom stores
   retain their configured options and must be isolated per network.
4. Hex package description omitted the implemented XRPL method. Added XRPL.

No runtime behavior changed. No leftover debug output or additional actionable
dead-code/naming findings were identified in the inspected changes. The task 116
commit title mentions optional pull InvoiceID, but the landed code and guide both
explicitly require it; the guide was correctly left unchanged. No follow-up tasks
were needed or filed. No reviewer rejections were supplied for this range.

Validation: `git diff --check` passed. The initial `mix check.dispatch` stopped on
missing dependencies in the intentionally unwarmed worktree. After
`HEX_HOME="$PWD/.audit-build/hex" mix deps.get`, the command
`HEX_HOME="$PWD/.audit-build/hex" mix check.dispatch` completed with exit status 0.
Formatting, warnings-as-errors compilation, strict Credo, Doctor, Sobelow,
duplication, architecture, smell checks, Dialyzer (zero warnings), and dependency
audit passed. ExUnit reported 2,016 passed, zero failed/skipped, 139 excluded, and
96.87% coverage against the 95% gate. Integration/cross-validation exclusions are
part of the project's check command; live XRPL tests were not run by this audit.

The command explicitly skipped AGENTS.md freshness and advisory-mirror freshness
because their developer-host scripts were absent. Those checks are not claimed
as verified. Dependencies and build artifacts were fetched/built in this worktree;
dependency tooling did reuse its host NIF cache. Build logs are retained locally
under `tmp/audit-bf3c3df/`. The cold-check result records this audit's observed
command result, not an independent reviewer verdict.
