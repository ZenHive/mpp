// Entry point for esbuild: bundles ox/tempo TxEnvelopeTempo into a QuickBEAM-loadable IIFE.
// Used by test/support/ox_tempo_bundle.ex for cross-validation tests.
import { deserialize, serialize, serializedType, feePayerMagic, from, getSignPayload } from 'ox/tempo/TxEnvelopeTempo';
import * as KeyAuthorization from 'ox/tempo/KeyAuthorization';
import * as SignatureEnvelope from 'ox/tempo/SignatureEnvelope';
import { Address, P256, Secp256k1 } from 'ox';

globalThis.TxET = { deserialize, serialize, serializedType, feePayerMagic, from, getSignPayload };
globalThis.OxSecp256k1 = { sign: Secp256k1.sign, recoverAddress: Secp256k1.recoverAddress };
globalThis.OxKeyAuthorization = {
  from: KeyAuthorization.from,
  hash: KeyAuthorization.hash,
  getSignPayload: KeyAuthorization.getSignPayload,
  serialize: KeyAuthorization.serialize,
  deserialize: KeyAuthorization.deserialize
};
globalThis.OxP256 = { sign: P256.sign, getPublicKey: P256.getPublicKey };
globalThis.OxAddress = { fromPublicKey: Address.fromPublicKey };
globalThis.OxSignatureEnvelope = { from: SignatureEnvelope.from, verify: SignatureEnvelope.verify };
