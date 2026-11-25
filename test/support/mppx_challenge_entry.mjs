// Entry point for esbuild: bundles mppx's Challenge module (auth-param
// escape/decode, mppx #813) into a QuickBEAM-loadable IIFE.
// Used by test/support/mppx_challenge_bundle.ex for cross-validation tests.
import {
  serialize,
  deserialize,
  from,
  credentialHeader,
  isLegacyUnicodeEscaped,
  deserializeList,
} from '../../refs/mppx/src/Challenge.ts';
import { deserialize as receiptDeserialize } from '../../refs/mppx/src/Receipt.ts';

globalThis.MppxChallenge = { serialize, deserialize, from, credentialHeader, isLegacyUnicodeEscaped, deserializeList, receiptDeserialize };
