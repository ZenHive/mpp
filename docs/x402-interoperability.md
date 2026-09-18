# x402 interoperability evidence (Task 81)

x402 v2 exact (EVM EIP-3009) HTTP interoperability is implemented in `lib/mpp/x402/`.
Native Payment-auth remains a separate contract. MCP, x402 v1, non-EVM families,
schemes other than `exact`, and Permit2 client signing are out of scope.

## Authority

- Official x402 v2 specification: https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
- Live public facilitator: https://www.x402.org/facilitator
- SDK compatibility target: `refs/mppx/src/x402` and `refs/mppx/src/client/Transport.ts`
  (inspected at `wevm/mppx` `a0a7d5b693406b1e3e90a69d9003136769906e8f`, 2026-09-18)

## Nonce boundary

- Native Payment-auth EIP-3009: `MPP.Methods.EVM.Authorization.challenge_hash/2`
  (`keccak256(id <> realm)`). `Authorization.settle/2` enforces this.
- x402 exact: random 32-byte nonce, or mppx extension-bound SHA-256 of
  `serialize(accepted)|serialize(resource)|serialize(extensions)` when
  `extensions.mppx` is present (`refs/mppx/src/x402/client/Exact.ts`).
- Shared primitive: `Authorization.sign_transfer/2` signs a caller-supplied nonce
  and does not enforce either contract.

## Live facilitator (2026-09-18)

`https://www.x402.org/facilitator/supported` advertised v2 exact EVM on Base Sepolia
(`eip155:84532`). Payer `0x898018E18e1Aa5819282EC4D9B784E1aE7eecAC4` had zero
Base Sepolia USDC. A real EIP-712 signature for `balance + 1` observed:

| Endpoint | HTTP | Domain result |
| --- | --- | --- |
| `/verify` | 200 | `isValid: false`, `invalidReason: invalid_exact_evm_insufficient_balance` |
| `/settle` | 200 | `success: false`, `errorReason: invalid_exact_evm_insufficient_balance`, `transaction: ""` |

A successful live settlement remains unobserved until that payer is funded with
Base Sepolia USDC. Integration tests pin the rejection and flunk loudly when
funding is missing. Localnet pay/retry/replay does not replace that observation.

```sh
export X402_PRIVATE_KEY="0x<your-funded-testnet-private-key>"
export X402_RPC_URL="https://sepolia.base.org"
export X402_FACILITATOR_URL="https://www.x402.org/facilitator"
mix test test/mpp/x402/facilitator_integration_test.exs --include integration
```

Fund via https://faucet.circle.com/. Ethereum Sepolia USDC is not Base Sepolia USDC.
