// Entry point for esbuild: bundles ox/tempo TxEnvelopeTempo into a QuickBEAM-loadable IIFE.
// Used by test/support/ox_tempo_bundle.ex for cross-validation tests.
import { deserialize, serialize, serializedType, feePayerMagic, from, getSignPayload } from 'ox/tempo/TxEnvelopeTempo';
import { Secp256k1 } from 'ox';

globalThis.TxET = { deserialize, serialize, serializedType, feePayerMagic, from, getSignPayload };
globalThis.OxSecp256k1 = { sign: Secp256k1.sign, recoverAddress: Secp256k1.recoverAddress };
