# Payment-security mutation evidence refresh

Observed on 2026-10-02 against integrated revision
`6e4d196b24b75fbff7554b50f9f82324cdfd54d0`, with the refresh-runner changes
in this delivery. No production source or mutation definition changed in this
refresh. Elixir 1.20.4 / Erlang OTP 29; seed 0.

## Reproduction and input drift

`mix test test/mutation/security_campaign_test.exs --seed 0` reproduced
`{:error, :fingerprint_mismatch}`: six passed, one failed. Dependencies required
`mix deps.get` before execution; `mix.lock` was unchanged.

The previous ledger update was `123d07cea8ef78d6461fe1156d5bbedf143c2374`.
Comparing that revision with the integrated revision identifies these changed
fingerprint inputs (mutation definitions are unchanged):

- `lib/mpp/challenge.ex`
- `lib/mpp/methods/evm.ex`
- `lib/mpp/methods/evm/transaction.ex`
- `lib/mpp/methods/tempo.ex`
- `lib/mpp/replay.ex`
- `lib/mpp/verifier.ex`
- `test/mpp/methods/evm/transaction_test.exs`
- `test/mpp/methods/evm_test.exs`
- `test/mpp/methods/tempo_test.exs`
- `test/mpp/replay_test.exs`
- `test/mpp/verifier_pinned_conformance_test.exs`
- `test/mpp/verifier_pinned_property_test.exs`
- `test/mpp/verifier_test.exs`

These changes cover challenge validation, internal payment errors, shared hash
extraction, Tempo memo attribution and currency routing, and corresponding tests.
The fingerprint covers whole files, including documentation and unrelated clauses.
The previous fingerprint was
`8dd439ff7cff11f9c75f14881eec12c964f64fe5be3f8c5d8933dd57d611b4ee`;
the observed campaign fingerprint is
`7f92f8e98570c35e46d3450293ae281ab5d8d9e470413bdfa0d9465bf6900adb`.

## Executed campaign

Command: `MIX_ENV=test mix mutation.security --refresh`.

The unmodified baseline passed 536 checks (2 doctests, 12 properties, 522 tests).
All 18 replacements applied exactly once and compiled with warnings treated as
errors. All 18 were killed, including all five canaries; zero survivors or invalid
replacements required repairs. Each mutant ran its declared tests with seed 0 and
`--max-failures 1`. The ledger's `campaign.observation` retains the command,
revision, runtime versions, timestamp, baseline summary and individual failure
output tails. Older authority/tool/live-provider entries remain historical;
this campaign does not renew their evidence.

Inspection of all outcomes found:

- JCS and both HMAC mutants failed their ordering/golden-vector assertions.
- Request pinning and expiry mutants returned success instead of rejection.
- Chain pinning was killed by the expected chain-specific error detail changing
  to the aggregate request mismatch; the aggregate request pin still rejected it.
- Replay precheck returned `:ok` for an already claimed credential.
- EVM recipient, amount and signer-binding mutants returned success; authorization
  dispatch instead returned the hash-route invalid-payload error.
- EVM transaction opt-in reached RPC/broadcast handling for an unoffered credential,
  causing a function-clause error on the stub's nil hash. This is an unexpected
  execution-path kill, not an observed successful unauthorized settlement.
- Tempo amount and unknown-dispatch mutants returned success. The chain mutant
  reached simulation without a registered RPC stub instead of rejecting the chain.
- Both fee-payer policy mutants returned `:ok` instead of the required error.
- The canonical reserve mutant broadcast bytes differing from the canonical form.

## Refresh safeguards and focused verification

Normal `mix mutation.security` still rejects a stale fingerprint. Explicit
`--refresh` permits only that validation failure, runs the baseline and every
mutant, validates the complete ordered result set, then writes observed evidence.
Invalid ledgers, compilation failures and survivors cannot authorize a refresh.
Regression tests cover stale fingerprints, incomplete/duplicate/unknown results,
and rejection of an invalid ledger without overwriting it.

Commands after refresh (all exited successfully; focused suite: 9 passed):

- `MIX_ENV=test mix format test/mutation/security_campaign.exs test/mutation/security_mutations.exs test/mutation/security_campaign_test.exs`
- `MIX_ENV=test mix compile --warnings-as-errors`
- `mix test test/mutation/security_campaign_test.exs --seed 0`

Independent acceptance remains the harness reviewer's responsibility. Full QA
and live-provider integration tests were not rerun for this evidence-only change.
