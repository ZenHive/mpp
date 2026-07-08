# Tempo + session hardening delta — Task 46

Audit date: **2026-06-30**. Reference clones: `refs/mppx` (head `8305a05`), `refs/mpp-rs` (head `9830c2b`), `refs/mpp-specs`. Compared against our Elixir implementation in this worktree.

**Legend:** ✓ parity · ◐ partial · ✗ missing · N/A not applicable (no Elixir client / sessions server yet)

---

## Charge-path Tempo hardening

| Upstream fix | Ref | Status | Our equivalent |
|---|---|---|---|
| Challenge-bound memo on pull / broadcast txs | mppx #562, mpp-rs | ✓ | `verify_memo_binding/3` — shipped pre-Task 46 |
| Raw `opaque` byte-exact echo | mpp-rs #284 | ✓ | `MPP.Verifier` opaque match — shipped |
| Expired-challenge rejection (server) | GHSA bundle | ✓ | `MPP.Verifier` expiry gate |
| Fee-payer gas economics + expiring nonce | GHSA + #497 | ✓ | `MPP.Methods.Tempo.FeePayerPolicy` |
| **Non-canonical fee-payer tx rejection** (padded calldata / nonzero call value) | mppx #602 | ✓ **new** | `FeePayerPolicy.check_canonical_calls/1` + `check_call_values/1` — byte-exact-canonical TIP-20/DEX calldata + zero per-call value before co-sign (0.9.0; mpp-rs has no equivalent — different inline-envelope architecture) |
| Pre-broadcast sponsored-tx simulation | mppx #534, mpp-rs #293 | ✓ | `eth_simulateV1` in `tempo.ex` (Task 59) |
| `hash` + `feePayer` MUST reject | mpp-specs #204 | ✓ | `tempo.ex` rejects hash when `fee_payer: true` |
| Hash-credential `source` DID validation | mpp-rs `384c4fe` | ✓ | `MPP.DID.parse_evm_did/1` + chain match in hash path |
| Atomic replay store (`put_if_absent` / CAS) | mpp-rs #280 | ✓ | `MPP.Tempo.ConCacheStore.check_and_mark/2` — **required + on by default** (0.7.0; was optional in 0.6.1) |
| **Fee-payer token allowlist** | mpp-rs #286 | ✓ **new** | `FeePayerPolicy.fee_token_allowed?/3`, `default_allowed_fee_tokens/1`; enforced before co-sign |
| **EIP-712 proof v3 wallet binding** | mppx #532, #253 | ✓ **new** | `MPP.Methods.Tempo.Proof` + `type="proof"` verify path; conformance vector pinned |
| Proof replay via store | mpp-rs #285 | ✓ | `mpp:proof:<challenge_id>` via `check_and_mark/2` (store on by default, 0.7.0) |
| Zero-amount requires proof (not hash/tx) | mppx proof flow | ✓ **new** | `reject_non_proof_for_zero_amount/2` |
| Hosted fee-payer fills (`fillHostedFeePayerTransaction`) | mppx #536, #538, #584 | ✓ | `MPP.Methods.Tempo.HostedFeePayer` + `fee_payer_url` config |
| Proof access-key / on-chain keychain fallback | mppx `resolveAccount` #579 | ✓ **new** | `recover_authorized_proof_signer` + `AccessKey.active?/3` via AccountKeychain `getKey` — `proof.ex`, `access_key.ex`, `tempo.ex` (Task 69) |
| **Presenter-identity binding on hash/transaction paths** | — ZenHive extension beyond both SDKs (residual of published `GHSA-34g7-vx6g-82mq`; mpp-rs `verify_hash` / mppx `Charge.ts` default sender to `receipt.from`, no tighten knob) | ✓ **new** | Opt-in `"require_presenter_binding"`: presenter signs the proof EIP-712 envelope (MPP v3 `{account, challengeId, realm}`) with the transfer sender's wallet or an authorized access key; advertised as `presenterBinding` in 402 details — `tempo.ex` (Task 75, 0.8.0) |
| Client-side Tempo chain pinning | mpp-rs `8880cf7` | N/A | Built-in Tempo provider — tracked in Task 33e |

---

## Session-channel hardening

| Upstream fix | Ref | Status | Notes |
|---|---|---|---|
| `SessionReceipt` / PaymentWitness `externalId` | mpp-specs #266 | ✓ **new** | Optional `external_id` / wire `externalId` on `MPP.Methods.Tempo.SessionReceipt` |
| Voucher replay rejection | mpp-rs #247 | N/A | Task 50 — no session server |
| Channel scoped to active challenge | mpp-rs #246 | N/A | Task 50 |
| Post-channel-close charge rejection | GHSA bundle | N/A | Task 50 |
| Close-voucher `<=` boundary (CVE-2026-34209) | mppx `9408824` | N/A | Task 50 acceptance criterion |
| Channel locking during close | mppx session | N/A | Task 50 |
| Fresh-deposit state preservation | mppx session | N/A | Task 50 |
| Legacy client close at `max(spent, acceptedCumulative)` | mppx #577 | N/A | No Elixir `SessionManager` client |
| SSE voucher posts consuming charges | mppx #561 | N/A | Server session path unbuilt |
| Session open funding precheck | mppx #583 | N/A | Task 50 |

---

## Stripe / cross-method (Task 46 scope)

| Upstream fix | Ref | Status | Our equivalent |
|---|---|---|---|
| **Charge `externalId` binding** — require credential `externalId` to match route request and ignore payload-only IDs | mppx #537 | ✓ **new** | `Stripe.check_external_id_binding/2`; receipt uses server-bound `Charge.external_id` |

---

## Proof conformance vector (acceptance criterion)

Pinned in `test/mpp/methods/tempo/proof_test.exs` from `refs/mppx/src/tempo/Proof.conformance.test.ts`:

- account `0x1a642f0E3c3aF545E7AcBD38b07251B3990914F1`
- chainId `42431`, realm `api.example.com`, challengeId `kM9xPqWvT2nJrHsY4aDfEb`
- digest `0x3860a700a55e02ad3c2dc047e92489feceecbdb0a801d948e1d9f0b61ea9bc3f`
- signature recovers to the account above

---

## New integration coverage (Moderato)

| Case | File |
|---|---|
| `type="proof"` zero-amount verify end-to-end | `test/mpp/methods/tempo_integration_test.exs` |
| Fee-payer co-sign rejected when `fee_token` not on allowlist | same |

---

## Follow-up (not Task 46)

- **Task 68:** hosted fee-payer fills — shipped via `fee_payer_url` + `MPP.Methods.Tempo.HostedFeePayer`.
- **Session server** — Task 50 closes the N/A rows above.
- **Client chain pinning** — Task 33e.
