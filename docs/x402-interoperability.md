# x402 interoperability evidence (Task 81)

Status: blocked on successful live settlement evidence; no production x402
implementation is included. The contract probes are prerequisites, not SDK parity
or settlement verification. A passing funding probe does not establish settlement.

## Authority and reference audit

Protocol authority:

- [Official x402 v2 specification](https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md)
- [Live public facilitator capabilities](https://www.x402.org/facilitator/supported)

The worktree lacked `refs/mppx`. A shallow checkout of `wevm/mppx` was inspected
at commit `a0a7d5b693406b1e3e90a69d9003136769906e8f` on 2026-09-18.
These are SDK compatibility observations, not protocol authority:

- `src/x402/Types.ts`: v2, `exact`, EVM networks; schemas also describe Permit2,
  but `src/x402/client/Exact.ts` explicitly rejects signing non-EIP-3009 transfers.
- `src/x402/Header.ts`: separate PAYMENT-REQUIRED, PAYMENT-SIGNATURE and
  PAYMENT-RESPONSE codecs; discovery filters individual unsupported offers.
- `src/client/Transport.ts` and `src/client/internal/protocols/X402.ts`: collect
  native MPP and x402 offers together, retain protocol identity separately from
  method/intent, check resource URL, attach the chosen protocol's header.
- `src/x402/client/Exact.ts`: random 32-byte authorization nonce for standard
  x402; an `mppx` extension changes this to an extension-bound nonce with fresh
  client randomness. Native `MPP.Methods.EVM.Authorization.challenge_hash/2`
  remains a separate contract and must not be replaced with random nonces.
- `src/x402/internal/RouteBinding.ts`: extension-bound nonce is SHA-256 of the
  serialized accepted requirements, resource and extensions joined by `|`.
  This is an SDK extension, not a requirement of core x402.
- `src/x402/server/EvmCharge.ts`: configurable facilitator, resource/required
  binding modes and request-body digest verification. Core x402 metadata and
  this extension's stronger binding must be distinguished in the implementation.
- `src/x402/Exact.localnet.test.ts`: deployed local token, pay/retry and replay
  rejection. `src/x402/Exact.e2e.test.ts` uses a stub facilitator for its HTTP
  cases; those cases do not establish live facilitator semantics.

Excluded scope: MCP, x402 v1, non-EVM families, schemes other than `exact`, and
Permit2 client signing. None is implemented by these probes.

## Live observations

On 2026-09-18, `https://www.x402.org/facilitator/supported` advertised v2 exact
EVM support on Base Sepolia (`eip155:84532`). The available
`ETH_SEPOLIA_PRIVATE_KEY` resolves to
`0x898018E18e1Aa5819282EC4D9B784E1aE7eecAC4`. An `eth_call` to Base Sepolia USDC
`0x036CbD53842c5426634e7929541eC2318f3dCF7e` returned a zero balance.

A real EIP-712 signature for one atomic unit was submitted to the facilitator,
using Task 40's existing test signing helper with an explicit random nonce:

| Endpoint | HTTP | Observed domain result |
| --- | --- | --- |
| `/verify` | 200 | `isValid: false`, `invalidReason: invalid_exact_evm_insufficient_balance`, payer address |
| `/settle` | 200 | `success: false`, `errorReason: invalid_exact_evm_insufficient_balance`, `transaction: ""`, `network: eip155:84532`, payer address |

The integration test repeats this with `balance + 1`, so it still exercises
insufficient balance after funding. Requests disable automatic retries.
No successful settlement was observed. No replay rejection or official-vector
round trip is claimed. Production changes must wait for the successful live
observation required by Task 81.

## Reproduction and unblock

```sh
export X402_PRIVATE_KEY="0x<your-funded-testnet-private-key>"
export X402_RPC_URL="https://sepolia.base.org"
export X402_FACILITATOR_URL="https://www.x402.org/facilitator"
mix test test/mpp/x402/facilitator_integration_test.exs --include integration
```

`ETH_SEPOLIA_PRIVATE_KEY` is accepted as a key fallback, but Ethereum Sepolia
funding is not Base Sepolia funding. Fund the payer with Base Sepolia USDC via
[Circle's testnet faucet](https://faucet.circle.com/). Missing keys or funding
fail loudly. After funding, observe a positive-amount verify/settle, confirm its
on-chain effects, and pin that success plus replay behavior in the integration
test before implementing the HTTP/client/server vertical boundary.
