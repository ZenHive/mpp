# Tempo proof key types

Zero-amount charge proofs accept P-256 access-key signatures, including keychain
V1 (`0x03`) and V2 (`0x04`) envelopes. Verification enforces low-s signatures,
verifies the embedded public key, and supports both digest signing and Tempo's
SHA-256 prehash flag. The recovered address must identify an active key whose
`getKey.signatureType` matches the signature. Existing secp256k1 proof verification
and its tests are retained.

WebAuthn proof envelopes return `unsupported proof signature type: WebAuthn`,
including malformed and keychain-wrapped envelopes. A Tempo Wallet-issued
WebAuthn access key was not available in the harness environment. WebAuthn proof
verification is therefore unsupported; a synthetic authenticator is not used as
evidence of wallet interoperability. Exactly 65 bytes remains the protocol's
unprefixed secp256k1 encoding regardless of its leading byte.

Subscription activation records the verified authorization's key type. Renewal
reads the active key's type from the keychain, and sponsorship simulation includes
`keyType` and `keyId`. Subscription challenge generation and authorization matching
remain secp256k1-only: the configured server signing key uses that curve, and the
key has not yet been registered when the challenge is issued. Non-secp256k1
subscription signing remains unsupported and is explicitly rejected on renewal.

The locked `onchain_tempo` 0.10.0 transaction decoder still accepts only 65-byte
sender signatures. Proof verification does not use that decoder; this change
does not extend transaction signing or decoding, or change the dependency.

## Authority and compatibility

- [Tempo signature-verification precompile specification](https://github.com/tempoxyz/tempo/blob/main/tips/tip-1020.md)
- [Tempo primitive signature implementation](https://github.com/tempoxyz/tempo/blob/main/crates/primitives/src/transaction/tt_signature.rs)
- [Tempo AccountKeychain implementation](https://github.com/tempoxyz/tempo/blob/main/crates/precompiles/src/account_keychain/mod.rs)
- Compatibility reference: [mpp-rs proof verification](https://github.com/tempoxyz/mpp-rs/blob/main/src/protocol/methods/tempo/proof.rs)

## Live verification

```sh
npm install --no-save --package-lock=false viem@2.55.18
mix test.json test/mpp/methods/tempo/p256_proof_integration_test.exs --include integration
mix test.json test/mpp/methods/tempo/subscription_integration_test.exs --include integration
mix ci
MIX_ENV=test mix mutation.security
```

The P-256 tests fund fresh Moderato accounts, authorize real P-256 access keys,
read their keychain metadata, and compare valid/tampered primitive signatures
against Tempo's verification precompile. Each test rejects a tampered proof and
an unrelated signing key before accepting the valid proof and checking its
receipt. Cleanup revokes the key and checks that it is inactive. Tests print
authorization transaction hashes for the harness log and fail on RPC or setup
errors. `TEMPO_RPC_URL` can override the Moderato endpoint.
