# XRPL session

`MPP.Methods.XRPL.Session` verifies the session intent over XRP Ledger payment
channels. A client locks XRP once with `PaymentChannelCreate`, then authorises
later requests with off-ledger claims over a cumulative drop total.

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
    "closing_margin" => 3600
  }
```

`network` is required. `min_settle_delay` and `closing_margin` default to 3600
seconds. The JSON-RPC connection must support `server_info`, `submit`, `tx`,
`ledger_entry` and `ledger` API v1. Session-channel state uses
`MPP.Session.Store`, namespaced by network so the same PayChannel ID on two
ledgers cannot share a high-water mark.

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
| Receipt `channelId`, `cumulative`, open `txHash` | Receipts |

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

`MPP.Session.ETSStore` optionally namespaces keys by `:network`.
`MPP.Session.Actions` accepts `verify_signature: :already_verified` so XRPL
claim verification (not EIP-712) can run first, then the same atomic voucher
update applies: an accepted voucher must raise `cumulative_amount`, and the
balance write is a single store `update/2`.

## Claim signatures

Local verification is preferred (the draft: no round trip, no disclosure of
which channels a server is paid through). The message is HashPrefix `CLM\0`
plus the 32-byte channel ID plus drops as a big-endian uint64
([channel_verify](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/payment-channel-methods/channel_verify),
rippled `serializePayChanAuthorization`). secp256k1 signatures are SHA-512Half
then canonical low-S ECDSA; Ed25519 keys (`ED` prefix) sign the raw message.

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
