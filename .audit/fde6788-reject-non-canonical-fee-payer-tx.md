# Audit: fde6788 — Reject non-canonical fee-payer transactions (port mppx #602, 0.9.0)

- **Date:** 2026-07-08
- **Classification:** full (security-critical wire-format change in money-handling code)
- **Reviewers:** Claude + Codex (dual-reviewer, converged)

## Scope

Ports mppx #602 (`fix-fee-payer-intrinsic-gas`) into `MPP.Methods.Tempo.FeePayerPolicy`: before the sponsor co-signs a client-signed `0x76` envelope, reject (1) any call carrying nonzero native `value` and (2) non-canonical calldata (trailing padding / dirty high-order bytes) for the four recognized TIP-20/DEX selectors — both inflate the sponsor's *intrinsic* gas (16 gas/byte) without changing the decoded payment intent, and pre-broadcast `eth_simulateV1` cannot catch them. Sibling of published GHSA-vv77-66rf-pm86 / GHSA-vj8p-hp9x-gh47 / GHSA-qpxh-ff8m-c62v. Release 0.9.0 with CHANGELOG, security-parity ledger row, hardening-delta row, version bumps, and `.sdk-watch.json` watermark advance.

## Wire-format verification (mandatory per CLAUDE.md)

Verified against `refs/mppx/src/tempo/internal/fee-payer.ts` (`assertCanonicalSponsoredTransaction`, lines 322–388) and `onchain_tempo` `TIP20` constants:

- **Selectors** — single source of truth is `Onchain.Tempo.TIP20`: `transfer` `0xa9059cbb`, `approve` `0x095ea7b3`, `transferWithMemo` `0x95777d59`, `swapExactAmountOut` `0xf0122b75` — same four-member set as mppx `sponsoredCallSelectors` (fee-payer.ts:323–328).
- **Word layout** — bitstring patterns enforce exact static-ABI canonical form: address = 12 zero-pad + 20 bytes; uint128 = 16 zero-pad + 16 bytes; uint256/bytes32 = full 32-byte word. Total lengths: transfer/approve 68, transferWithMemo 100, swapExactAmountOut 132 bytes. Equivalent to mppx's decode→re-encode-and-compare (fee-payer.ts:330–347, 382–386) since all four functions take only static args.
- **swapExactAmountOut signature** — `(address,address,uint128,uint128)` per onchain_tempo `tip20.ex:40–41`, matching mppx's `Abis.stablecoinDex`-derived selector.
- **Zero-value check** — matches mppx fee-payer.ts:369–374.
- **Unknown selectors pass** the canonicality check, matching mppx returning `undefined` for unrecognized selectors (fee-payer.ts:335); in the production pipeline they are unreachable anyway — `Transaction.validate_call_scope/1` (exact selector-sequence allowlist, onchain_tempo `transaction.ex:164–173`) runs before the policy (`tempo.ex:283–284`).
- **Empty/short calldata** fails closed via the `canonical_call?(_call) → false` fallback; mppx likewise rejects missing calldata (fee-payer.ts:376–380).
- **Empty calls array** — mppx rejects it inside `assertCanonicalSponsoredTransaction`; our equivalent rejection happens upstream in `validate_call_scope` (`[]` matches no `@call_scopes` entry). Net behavior identical.

## Findings (3-reasoner merge)

None actionable.

- **Codex:** clean, severity 1 — no findings; explicitly confirmed pattern-vs-reference equivalence with `refs/…` line citations.
- **Claude:** two sub-threshold notes, dropped at rating 2:
  1. Error-message drift — mppx distinguishes "calldata is invalid" (decode failure) from "not canonical"; we report "not canonical" for both. No security or interop impact (messages are not wire format).
  2. Empty-input call has no dedicated test, but the fail-closed fallback clause is already exercised by the five padded/dirty-padding tests, and call-scope rejects such txs before the policy runs.

## Checks

- `mix test.json test/mpp/methods/tempo/fee_payer_policy_test.exs` — 45/45 passed (9 new canonicality tests + 2 call-value tests included).
- Test-helper fix noted and approved: `swap_calldata/0` corrected from 100-byte (4+96) to canonical 132-byte (4+128) form — the old helper itself encoded a non-canonical length.
- Disclosure policy respected: all referenced advisories are published; CHANGELOG/parity-ledger text describes a *closed* gap.

## Verdict

Approved. 0 fixes applied.
