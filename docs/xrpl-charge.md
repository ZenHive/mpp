# XRPL charge

`MPP.Methods.XRPL` verifies XRP (integer drops), issued currencies and MPTs through
XRPL JSON-RPC. It accepts signed `transaction`/`blob` credentials and submitted
`hash`/`hash` credentials. Client-side providers are not included.

```elixir
plug MPP.Plug,
  secret_key: "server-secret",
  realm: "api.example.com",
  method: MPP.Methods.XRPL,
  amount: "1000",
  currency: "XRP",
  recipient: "rhewi79quXUDwcqjkpj4bXuw3cuHYC9fwv",
  method_config: %{
    "rpc_url" => "https://your-xrpl-node.example",
    "network" => "mainnet",
    "store" => MyApp.DurablePaymentStore,
    "store_retention_ms" => 600_000
  }
```

The store implements `MPP.Tempo.Store`, including atomic `check_and_mark/2`, and
must be durable and shared by all replicas. `store_retention_ms` declares the
backend's actual retention; configure that retention on the backend too. It must
cover the remaining challenge lifetime plus the verification poll budget. Store
errors fail closed. `false` and an absent store are rejected. A configured
`MPP.Tempo.ConCacheStore` is permitted only on testnet/devnet with explicit
`"allow_process_local_store" => true`; this is a development exception to durable
storage, not a production topology.

Session intents are `MPP.Methods.XRPL.Session` — see [XRPL session](xrpl-session.md).

`MPP.Verifier` supplies the authenticated challenge ID, expiry and source DID.
The source must be `did:pkh:xrpl:0:<address>` on mainnet, `:1:` on testnet or `:2:`
on devnet ([CAIP XRPL namespace](https://namespaces.chainagnostic.org/xrpl/caip10)).
Direct `verify/2` callers must supply authenticated `challenge_id`,
`challenge_expires`, and `credential_source` in `method_details` themselves.

Both credential paths require an InvoiceID binding. By default it is the uppercase
SHA-512Half of the challenge ID. An explicit `invoiceId` must be generated for one
challenge; never configure a reusable invoice ID for a route. Destination/source
tags are additional constraints, not substitutes for binding. Transactions and
challenges are consumed separately using atomic store operations. Hash casing
cannot produce a new dedup key. A receipt is returned only after validated
`tesSUCCESS` settlement, exact delivered-asset/amount verification and both claims.
Concurrent credentials can obtain at most one successful receipt.

Pull mode decodes the blob and verifies payment fields before any submission,
then checks them again against the ledger. The decoder accepts the common Payment
fields, native/issued/MPT amounts, memos, signer arrays, and payment paths. Unknown
fields, noncanonical field order, duplicates, malformed lengths and excessive
nesting fail closed. It requires a signed transaction and `LastLedgerSequence`.
The returned submission hash must equal SHA-512Half of `TXN\0` plus the blob.

## Draft contract

Authority: [mpp-specs at commit 213b098](https://github.com/tempoxyz/mpp-specs/blob/213b098/specs/methods/xrpl/draft-xrpl-charge-00.md).
The local reference path for the following line citations is
`refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md`.

| Wire value / rule | Draft reference |
|---|---|
| `xrpl`, `charge` | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:236`, `:248` |
| `amount`, `currency`, `recipient`, positive decimal amounts, `XRP` | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:256`, `:289` |
| Issued `currency`/`issuer`, MPT `mpt_issuance_id` | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:297` |
| `network`: `mainnet`, `testnet`, `devnet`; `reference`, `invoiceId`, `destinationTag`, `sourceTag`, `memos` | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:306` |
| `type: transaction`, `blob` (hex) | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:363` |
| `type: hash`, `hash` (64 hex) | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:375` |
| Canonical uppercase invoice/hash, case-insensitive input and store keys | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:264` |
| Mandatory expiry and atomic single use | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:391`, `:400`, `:584` |
| Payment type, destination, delivered amount, asset/issuer, no partial-payment flag, source DID account, tags | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:413` |
| Challenge-bound `InvoiceID`, SHA-512Half | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:442` |
| Validated ledger and two verification passes | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:461`, `:481` |
| `txHash`, `ledgerIndex`, receipt `reference` | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:535` |
| Existing `malformed-credential`, `invalid-challenge`, `verification-failed`; no new problem types | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:552`, `:721` |
| Examples used for cross-checking fields | `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:737`, `:747`, `:771`, `:790` |

Two draft ambiguities are explicit implementation choices: the issued-asset prose
calls currency an object but the shared schema and example carry JSON in a string;
this implementation follows the shared schema and example. The `memos` row says
UTF-8 entries without defining their structure. Here entries are maps with `data`,
optional `type` and `format`; each becomes a hex-encoded `MemoData`, `MemoType` and
`MemoFormat` in an XRPL `Memo` envelope. All configured entries must match in order.
Older pull clients omitting InvoiceID are rejected; the draft permits this stricter
binding policy. No new `MPP.Errors` types are introduced. The surrounding generic
MPP verifier retains its existing core-envelope errors before method dispatch.

## Ledger authority and RPC choice

A small Req wrapper uses `server_info`, `submit`, and `tx` with API version 1.
The only XRPL Hex package found was [`xrpl` 1.0.0](https://hex.pm/packages/xrpl),
released 2024-03-24; its [repository](https://github.com/lucca65/xrpl) also last
received a push on that date. It uses global Tesla configuration and has no
binary codec. Req is already a runtime dependency and allows per-method endpoints.
No dependency or lockfile change is required. Node and xrpl.js are test-only.

The following XRPL-owned sources govern ledger semantics and codec constants:

- [Payment](https://xrpl.org/docs/references/protocol/transactions/types/payment),
  [partial payments](https://xrpl.org/docs/concepts/payment-types/partial-payments),
  [currency formats](https://xrpl.org/docs/references/protocol/data-types/currency-formats).
- [submit](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/transaction-methods/submit),
  [tx](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/transaction-methods/tx),
  [finality](https://xrpl.org/docs/concepts/transactions/finality-of-results).
- [Binary format](https://xrpl.org/docs/references/protocol/binary-format) and its
  linked [field definitions](https://github.com/XRPLF/xrpl.js/blob/main/packages/ripple-binary-codec/src/enums/definitions.json).
  Amount layouts were checked against both xrpl.js `types/amount.ts` and
  [rippled STAmount.cpp](https://github.com/XRPLF/rippled/blob/develop/src/libxrpl/protocol/STAmount.cpp).
  Hash prefix: [HashPrefix.h](https://github.com/XRPLF/rippled/blob/develop/include/xrpl/protocol/HashPrefix.h).
- [Base58 alphabet/address encoding](https://xrpl.org/docs/references/protocol/data-types/base58-encodings).
- [MPT issuance](https://xrpl.org/docs/references/protocol/transactions/types/mptokenissuancecreate)
  and [holder authorization](https://xrpl.org/docs/references/protocol/transactions/types/mptokenauthorize).

## Verification

```sh
npm install --prefix tmp/xrpl --no-audit --no-fund xrpl@4.6.0
export XRPL_TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
export XRPL_JS_PATH="$PWD/tmp/xrpl/node_modules/xrpl"
mix test.json test/mpp/methods/xrpl_integration_test.exs --include integration --quiet --output tmp/xrpl-live.json
mix ci
```

Missing setup fails loudly. Testnet wallets are generated and funded using the
public faucet; private seeds are neither committed nor sent to RPC. Issued-token
and MPT tests create prerequisites, redeem the received tokens, then remove the
trustline/MPT holder and destroy the MPT issuance. Faucet-funded accounts are
disposable. The tests wait for validated account creation and transaction results,
with bounded polling and explicit failures.

Both credential types exercise real XRP and issued-currency settlement, real
wrong-destination/issuer rejection, tags, memos, challenge binding, validated
metadata and replay. MPT coverage exercises both modes and wrong-amount rejection.
Local tests cover malformed credentials and binary encodings, decimal precision,
partial payments, unavailable RPC/store, bounded unknown-hash polling, finality,
casing, and concurrent claims. The captured Payment in `test/fixtures/xrpl/payment.json`
is a parser regression fixture, not an external-semantics oracle. Its transaction
hash and ledger index can be queried on testnet; testnet resets may remove history.
`codec.json` contains serialization vectors generated by the XRPL-owned codec
installed with xrpl.js 4.6.0.

Local implementation checks on 2026-09-11: all 7 live tests passed; `mix ci`
exited 0 with 1,963 passing non-integration tests. XRPL coverage was 97.59% and
Codec coverage 96.92%. Dialyzer reported no warnings. CI reported its existing
host-script skips for AGENTS freshness and advisory-mirror freshness; the scripts
were absent in this environment. The dependency audit itself ran successfully.
Harness reviewer approval remains the independent acceptance gate.

Live XRP evidence from that run:

| Credential | Validated ledger | Transaction hash |
|---|---|---|
| transaction | 20667481 | `D414DE45CCC32E92F090105BBDD4468E9E23D3444883E6F0E0A44F3763A71CF7` |
| hash | 20667501 | `BD93F81FC7EA94B91CA12A23662AA7C3A4360CF569D3A1DAB17B44CD8B8BD63D` |
