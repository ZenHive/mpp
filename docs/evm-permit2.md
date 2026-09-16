# EVM Permit2 credentials

Configure `MPP.Methods.EVM` with `"permit2" => true`, `"private_key"` (gas
sponsor), `"rpc_url"`, and `"chain_id"`. `"permit2_address"` defaults to
`0x000000000022D473030F116dDEE9F6B43aC78BA3`. Optional `"splits"` contains up to
ten ordered `recipient`/`amount` maps; their sum must be less than the charge
total. The primary recipient receives the remainder.

Permit2 is advertised before authorization/hash only when configured for the
charge. Split challenges advertise only Permit2; hash and EIP-3009 credentials
cannot fulfill them. Ordinary authorization/hash paths retain their behavior.
MCP capabilities use the EVM challenge's configured credential list.

The client calls `MPP.Methods.EVM.Permit2.sign/5` with a charge, its private
key, the server's spender address, and decimal-string nonce/deadline. The
charge's `method_details` must contain `chain_id`, `challenge_id`, `realm`,
and any `permit2_address`/`splits`; `external_id` comes from the challenge
request. Signing needs no server private key. A client importing a wire
request must map `chainId` and `permit2Address` to these configuration keys.
The payer needs an ERC-20 approval to Permit2. Use a fresh unordered uint256
nonce for every payment. The server recovers the payer, checks source and
witness binding, simulates settlement via gas estimation, submits with its
own key, and verifies all ordered Transfer events after confirmation.

## Authorities and draft discrepancies

Contract authority: Uniswap Permit2 at
[cc56ad0](https://github.com/Uniswap/permit2/tree/cc56ad0f3439c502c246fc5cfcc3db92bb8b7219/src),
particularly `SignatureTransfer.sol`, `libraries/PermitHash.sol`, and `EIP712.sol`.
Witness and charge authority: [draft-evm-charge-00 at a938bfd](https://github.com/tempoxyz/mpp-specs/blob/a938bfdd443a9683aa0fcbeae487ed4ffadfe4be/specs/methods/evm/draft-evm-charge-00.md#permit2-payload-typepermit2-permit2-payload).

* The contract exposes single and batch overloads of `permitWitnessTransferFrom`.
  The draft's `permitBatchWitnessTransferFrom` function name does not exist.
* The exact draft witness suffix contains a space after `challengeHash,`.
  This implementation retains that byte in the root type string passed to
  Permit2. The nested PaymentWitness hash uses the canonical comma-separated
  EIP-712 type. Generic wallet typed-data encoders that normalize the root
  suffix will produce a different signature; the signing helper hashes the
  contract's exact bytes.
* Permit2 signs the spender (`msg.sender`). The draft defines no discovery
  field, so the signing API requires the server's spender address explicitly.

At review (2026-09-16), upstream
[mppx `src/evm/Methods.ts`:21](https://github.com/wevm/mppx/blob/main/src/evm/Methods.ts#L21)
still defaults to `credentialTypes = ['authorization']`, and
[`Types.ts`:18,96](https://github.com/wevm/mppx/blob/main/src/evm/Types.ts#L18)
defines only the authorization credential schema. Upstream
[mpp-rs `src/evm.rs`](https://github.com/tempoxyz/mpp-rs/blob/main/src/evm.rs)
is shared address/amount helpers for Tempo, not an EVM Permit2 payment method.
Neither SDK is used as the oracle.

## Live evidence and checks

Run the live test (missing credentials fail with exact export/faucet instructions):

```sh
mix test test/mpp/methods/evm_permit2_integration_test.exs --include integration
```

Requires `ETH_SEPOLIA_RPC_URL` and `ETH_SEPOLIA_PRIVATE_KEY`, funded with Sepolia
ETH and at least four base units of Circle Sepolia USDC. The test grants an
exact four-unit Permit2 allowance and restores the prior allowance on exit.
It transfers one unit in the single case and three units in the batch case.

Observed on Sepolia, 2026-09-16:

* Single: [0x2d50314f…cc882](https://sepolia.etherscan.io/tx/0x2d50314f68b3f911ddfeec12e60eb6dd398292d2d54bcbe36112df62c2ecc882).
* Atomic batch, primary two units then split one unit:
  [0xd519eea9…a5c1f](https://sepolia.etherscan.io/tx/0xd519eea9354b5452d5cf84afe7493f8ac438590fd38576940d75561cc6ca5c1f).
* Expired permit: `eth_estimateGas` returns JSON-RPC code `3`, data
  `0xcd21db4f` followed by the ABI-encoded deadline (`SignatureExpired(uint256)`).
* Reusing a settled nonce: JSON-RPC code `3`, data `0x756688fe` (`InvalidNonce()`).
  The server also rejects it using Permit2's nonce bitmap before submission.
* Altered challengeHash, externalId, and reordered transfer legs are rejected
  before submission. The receipt retains the charge's externalId.

`test/fixtures/evm_permit2/{single,batch}.json` records the public transactions
and receipts above. Offline tests substitute the deterministic payer's log
topic and mutate responses to test local rejection paths. These recordings
are regression evidence for our code, not an oracle for external semantics;
the live test remains the contract compatibility gate.
