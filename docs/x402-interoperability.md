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

## Live facilitator (2026-09-18 rejection, 2026-09-22 settlement)

`https://www.x402.org/facilitator/supported` advertised v2 exact EVM on Base Sepolia
(`eip155:84532`). Payer `0x898018E18e1Aa5819282EC4D9B784E1aE7eecAC4`, while it
held zero Base Sepolia USDC, signed a real EIP-712 authorization for `balance + 1`:

| Endpoint | HTTP | Domain result |
| --- | --- | --- |
| `/verify` | 200 | `isValid: false`, `invalidReason: invalid_exact_evm_insufficient_balance` |
| `/settle` | 200 | `success: false`, `errorReason: invalid_exact_evm_insufficient_balance`, `transaction: ""` |

After funding the payer with 20 USDC (2026-09-22), the same integration test
settled a 1-unit authorization through `/verify` (`isValid: true`) and `/settle`
(`success: true`, `transaction` set). On-chain evidence, Base Sepolia:

| Field | Value |
| --- | --- |
| Transaction | `0x408cdc77632380f56ad3e94aeb1faf5f523c69dff46be586f785c3ac97ea5a8e` (block 47132497) |
| Relayer (`tx.from`) | `0xd407e409e34e0b9afb99ecceb609bdbcd5e7f1bf` |
| Call | `transferWithAuthorization` (`0xe3ee160e`, v/r/s variant) |
| USDC `Transfer` | payer → `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`, value 1 |
| Payer balance | 20000000 → 19999999 |

Integration tests pin both the rejection and the settlement and flunk loudly when
funding is missing. Localnet pay/retry/replay does not replace that observation.

```sh
export X402_PRIVATE_KEY="0x<your-funded-testnet-private-key>"
export X402_RPC_URL="https://sepolia.base.org"
export X402_FACILITATOR_URL="https://www.x402.org/facilitator"
mix test test/mpp/x402/facilitator_integration_test.exs --include integration
```

Fund via https://faucet.circle.com/. Ethereum Sepolia USDC is not Base Sepolia USDC.
