# XRPL session

`MPP.Methods.XRPL.Session` verifies the session intent over XRP Ledger payment
channels. A client locks XRP once with `PaymentChannelCreate`, then authorises
later requests with off-ledger claims over a cumulative drop total. The server
retains the highest verified claim and redeems it with `PaymentChannelClaim`.

```elixir
plug MPP.Plug,
  secret_key: "server-secret",
  realm: "api.example.com",
  method: MPP.Methods.XRPL.Session,
  intent: "session",
  amount: "100000",
  currency: "XRP",
  recipient: "rhewi79quXUDwcqjkpj4bXuw3cuHYC9fwv",
  method_config: %{
    "rpc_url" => "https://your-xrpl-node.example",
    "network" => "mainnet",
    "min_settle_delay" => 3600,
    "closing_margin" => 3600,
    "destination_secret" => "sEd…family-seed-for-the-recipient"
  }
```

`network` is required. `min_settle_delay` and `closing_margin` default to 3600
seconds. `destination_secret` is the Destination account's family seed; it is
server-only and never copied into challenge method details. The JSON-RPC
connection must support `server_info`, `submit`, `tx`, `account_info`,
`ledger_entry` and `ledger` API v1. Session-channel state uses
`MPP.Session.Store`. The built-in `MPP.Session.ETSStore` is automatically
namespaced by network so the same PayChannel ID on two ledgers cannot share a
high-water mark. Custom `session_store` implementations receive their configured
options unchanged; use a separate store or network-scoped options for each network.

## Draft contract

Authority: [mpp-specs at commit 213b098](https://github.com/tempoxyz/mpp-specs/blob/213b098/specs/methods/xrpl/draft-xrpl-session-00.md).
The local reference path is `refs/mpp-specs/specs/methods/xrpl/draft-xrpl-session-00.md`.

| Wire value / rule | Draft reference |
|---|---|
| `xrpl`, `session` | `draft-xrpl-session-00.md` Method Identifier / Intent |
| `action=open` with `transaction`, `amount`, `signature` | action = "open" |
| `action=voucher` / `close` with `channelId`, `amount`, `signature` | action = "voucher" / "close" |
| Integer drop amounts, XRP only | Encoding Conventions / Channels Are XRP-Only |
| Claim over channel ID + cumulative drops | Signature / PaymentChannelClaim |
| Destination, settle-delay floor, closing window | Channel State / Settle Delay Floor / Closing Window |
| State keyed on network + canonical channel ID | State Keys |
| Strictly increasing high-water, atomic update | Monotonicity |
| Highest retained claim, `PaymentChannelClaim`, `tfClose` | Redemption |
| Receipt `channelId`, `cumulative`, open/close `txHash` | Receipts |

`topUp` is not a session credential action in the draft. `PaymentChannelFund`
exists on the ledger; a later voucher simply claims against the larger deposit.

## Shared channel model

`MPP.Session.Channel` was Tempo-only: EVM addresses, keccak256 TIP-1034 IDs,
and an ERC-20 `token`. XRPL payment channels differ, so the shared module now
also accepts:

- classic XRPL addresses for `payer` / `recipient`
- `"XRP"` as `token`
- `compute_xrpl_id/3` — SHA-512Half of `0x0078 \|\| AccountID \|\| DestinationID \|\| Sequence`
  ([PayChannel ID format](https://xrpl.org/docs/references/protocol/ledger-data/ledger-entry-types/paychannel#paychannel-id-format))
- `to_xrpl_id/1` — 64-character uppercase hex for the wire
- `proof` — optional method-neutral settlement material. XRPL stores
  `%{amount, signature, public_key}` for the highest accepted claim. Tempo
  leaves it `nil`.

`MPP.Session.ETSStore` optionally namespaces keys by `:network`.
`MPP.Session.Actions` accepts `verify_signature: :already_verified` so XRPL
claim verification (not EIP-712) can run first, then the same atomic voucher
update applies: an accepted voucher must raise `cumulative_amount`, and the
balance write is a single store `update/2`. A later lower or equal claim does
not replace the retained proof.

## Claim signatures

Local verification is preferred (the draft: no round trip, no disclosure of
which channels a server is being paid through). The message is HashPrefix `CLM\0`
plus the 32-byte channel ID plus drops as a big-endian uint64
([channel_verify](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/payment-channel-methods/channel_verify),
rippled `serializePayChanAuthorization`). secp256k1 signatures are SHA-512Half
then canonical low-S ECDSA; Ed25519 keys (`ED` prefix) sign the raw message.

## Check order

The PublicKey is a property of the PayChannel, not of the server, so a
signature check cannot precede the channel read
(`draft-xrpl-session-00.md` §Signature, lines 414–430). A forged claim on an
unseen channel id therefore costs one `ledger_entry`. After that read the
server verifies immediately and does no further RPC on a bad signature
(§Signature lines 441–444: a caller must not generate ledger traffic on the
server's behalf). Settled order for voucher and close:

1. Local parse of the credential
2. One `ledger_entry` for the PayChannel (PublicKey, Amount, Balance, Destination)
3. `Claim.verify` against that PublicKey
4. Local node checks (destination, funder, settle-delay floor, claim bounds)
5. `ledger` closing-window and `server_info` network check — only after a
   valid signature

Open still submits `PaymentChannelCreate` first; the claim checks above run
on the created entry.

## Redemption

`draft-xrpl-session-00.md` §Redemption (lines 604–632) requires the server to
submit `PaymentChannelClaim` carrying the highest cumulative amount and matching
signature. `Balance` is that drop count. Destination SHOULD set `tfClose`
(`0x00020000` / 131072): the claim settles, the entry is deleted, and unspent
deposit returns to the funder
([PaymentChannelClaim flags](https://xrpl.org/docs/references/protocol/transactions/types/paymentchannelclaim)).
`tfRenew` (`0x00010000`) is adjacent and must not be substituted.

§The Server Bears the Settlement Risk (lines 705–716) is not optional: only a
redemption in a validated ledger settles the matter. Close therefore submits
the claim, confirms `tesSUCCESS` in a validated ledger, and checks that the
PayChannel is gone or its `Balance` has advanced. The close receipt carries the
claim `txHash`.

The store is updated first so a failed submit still leaves the claim
retrievable via `MPP.Methods.XRPL.Session.redeem/2`. A close whose submit was
rejected answers `settlement-failed` without the ledger result code,
which §Error Responses (lines 677–702) forbids surfacing raw; `redeem/2`
reports the code to the operator.

### Deferred mode

Set `"defer_redemption" => true` to record the claim on close without submitting.
`redeem/2` submits later. The draft allows deferral of timing; it does not
allow dropping the claim.

### Fee payer

The Destination (server) is `Account` on `PaymentChannelClaim` and pays the
transaction `Fee` from its own XRP, not from the channel deposit. Configure
`destination_secret` (family seed). Required unless `defer_redemption` is true.
The seed must derive to the session `recipient`.

### Sequence serialization (single-node)

`Sequence` is an account-wide nonce: a transaction is valid only when it
equals the sending account's current Sequence
([Transaction Common Fields](https://xrpl.org/docs/references/protocol/transactions/common-fields)).
`LastLedgerSequence` caps how long the claim may sit in the open ledger
([Reliable Transaction Submission](https://xrpl.org/docs/concepts/transactions/reliable-transaction-submission)).
Two `PaymentChannelClaim` submits from the same Destination that pick the
same Sequence collide; the loser fails `tefPAST_SEQ`
([tef codes](https://xrpl.org/docs/references/protocol/transactions/transaction-results/tef-codes)).
The claim itself is not applied, so no value is lost — the retained proof
can be submitted again.

`redeem/2` (and close, which calls it) takes an exclusive ETS lease keyed by
Destination address (`MPP.Methods.XRPL.RedeemLock`) before reading Sequence,
so concurrent closes of different channels that share a Destination cannot
share a Sequence. The lease is single-node: it coordinates callers on this
BEAM node and does not span a cluster. A `tefPAST_SEQ` result is retried
once with a fresh Sequence (covers submissions from another node or other
transactions from the same account outside this lease). After a validated `tesSUCCESS`,
the claim txHash is stored on the channel proof; a later `redeem/2` returns
that hash and does not submit again.

## Verification

```sh
npm install --prefix tmp/xrpl --no-audit --no-fund xrpl@4.6.0
export XRPL_TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
export XRPL_JS_PATH="$PWD/tmp/xrpl/node_modules/xrpl"
mix test.json test/mpp/methods/xrpl_session_integration_test.exs --include integration --quiet --output tmp/xrpl-session-live.json
mix ci
```

Missing setup fails loudly. Testnet wallets are generated and funded using the
public faucet; private seeds are neither committed nor sent to RPC.
