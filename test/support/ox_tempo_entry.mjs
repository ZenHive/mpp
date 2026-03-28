// Entry point for esbuild: bundles ox/tempo TxEnvelopeTempo into a QuickBEAM-loadable IIFE.
// Used by test/support/ox_tempo_bundle.ex for cross-validation tests.
import { deserialize, serialize, serializedType, feePayerMagic } from 'ox/tempo/TxEnvelopeTempo';

globalThis.TxET = { deserialize, serialize, serializedType, feePayerMagic };
