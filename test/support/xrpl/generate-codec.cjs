// Serialization regression vectors, not proof of ledger-valid payments.
// Run: npm install --prefix tmp/xrpl --no-audit --no-fund xrpl@4.6.0
//      node test/support/xrpl/generate-codec.cjs
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const sdkRequire = createRequire(require.resolve(process.env.XRPL_JS_PATH || '../../../tmp/xrpl/node_modules/xrpl'));
const { encode, decode } = sdkRequire('ripple-binary-codec');
const payment = JSON.parse(fs.readFileSync(path.join(__dirname, '../../fixtures/xrpl/payment.json'))).ledger;
const base = Object.fromEntries([
  'TransactionType', 'SigningPubKey', 'TxnSignature', 'Account', 'Destination',
].map(key => [key, payment[key]]));
Object.assign(base, { Sequence: 1, LastLedgerSequence: 100, Amount: '1000', Fee: '12' });
const usd = value => ({ value, currency: 'USD', issuer: base.Account });
const inputs = [
  base,
  { ...base, Amount: usd('1.25'), SendMax: usd('2'), DeliverMin: usd('0') },
  { ...base, Amount: { ...usd('-1.23'), currency: '0158415500000000C1F76FF6ECB0BAC600000000' } },
  { ...base, Amount: { value: '100', mpt_issuance_id: '0000012FFD9EE5DA93AC614B4DB94D7E0FCE415CA51BED47' } },
  { ...base, NetworkID: 1, Flags: 2147483648, SourceTag: 4294967295,
    DestinationTag: 0, TicketSequence: 1, AccountTxnID: payment.hash, InvoiceID: payment.InvoiceID },
  { ...base, Memos: [{ Memo: { MemoType: '74657874', MemoData: '41'.repeat(200), MemoFormat: '746578742F706C61696E' } }] },
  { ...base, SigningPubKey: '', TxnSignature: undefined,
    Signers: [{ Signer: { Account: base.Account, SigningPubKey: base.SigningPubKey, TxnSignature: base.TxnSignature } }] },
  { ...base, Paths: [[{ account: base.Account, issuer: base.Destination, currency: 'USD' }], [{ currency: 'USD' }]] },
];
const vectors = inputs.map(input => {
  const blob = encode(JSON.parse(JSON.stringify(input)));
  return { blob, decoded: decode(blob) };
});
fs.writeFileSync(path.join(__dirname, '../../fixtures/xrpl/codec.json'), JSON.stringify(vectors, null, 2) + '\n');
