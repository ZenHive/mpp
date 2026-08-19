# MPP

[![CI](https://github.com/ZenHive/mpp/actions/workflows/ci.yml/badge.svg)](https://github.com/ZenHive/mpp/actions/workflows/ci.yml)
[![Code Scanning](https://github.com/ZenHive/mpp/actions/workflows/code-scanning.yml/badge.svg)](https://github.com/ZenHive/mpp/actions/workflows/code-scanning.yml)
[![GitHub](https://img.shields.io/github/license/ZenHive/mpp)](https://github.com/ZenHive/mpp/blob/main/LICENSE)

Elixir implementation of the [Machine Payments Protocol](https://mpp.dev) (MPP) — HTTP 402 payment middleware for AI agents and machine-to-machine commerce.

## What is MPP?

MPP is an open standard for machine-to-machine payments via HTTP 402, co-developed by [Stripe](https://stripe.com/blog/machine-payments-protocol) and [Tempo Labs](https://tempo.xyz). It enables any API to charge per-request without user accounts, API keys, or signup flows.

**Payment is authentication.** An agent hits your endpoint, gets a 402 challenge, pays, and receives the response — all in a single HTTP roundtrip.

## How It Works

```
Client                                    Server
  │                                         │
  │─── GET /api/data ──────────────────────►│
  │                                         │
  │◄── 402 Payment Required ───────────────│
  │    WWW-Authenticate: Payment            │
  │    (challenge with price + method)      │
  │                                         │
  │    [Client fulfills payment]            │
  │                                         │
  │─── GET /api/data ──────────────────────►│
  │    Authorization: Payment <credential>  │
  │                                         │
  │◄── 200 OK + Payment-Receipt ───────────│
  │    (resource + proof of payment)        │
  │                                         │
```

## Quick Start

Mount `MPP.Plug` in your Phoenix router to gate any endpoint behind payment:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :paid do
    plug MPP.Plug,
      secret_key: "your-hmac-secret",
      realm: "api.example.com",
      method: MPP.Methods.Stripe,
      amount: "5000",
      currency: "usd",
      method_config: %{
        "stripe_secret_key" => "sk_test_...",
        "network_id" => "profile_1Mqx...",
        "payment_method_types" => ["card"]
      }
  end

  scope "/premium", MyAppWeb do
    pipe_through [:api, :paid]
    get "/data", DataController, :show
  end
end
```

### Tempo (Stablecoins)

```elixir
pipeline :paid_tempo do
  plug MPP.Plug,
    secret_key: "your-hmac-secret",
    realm: "api.example.com",
    method: MPP.Methods.Tempo,
    amount: "1000000",
    currency: "0x...(pathUSD token address)",
    recipient: "0x...your-address",
    method_config: %{
      "rpc_url" => "https://rpc.tempo.xyz",
      "chain_id" => 4217,
      "fee_payer" => true,
      # Sponsorship requires an explicitly selected atomic store.
      # ConCache is single-node; use one shared backend across nodes that sponsor
      # the same wallet.
      "store" => MPP.Tempo.ConCacheStore,
      # Either use a local fee-payer key...
      "fee_payer_private_key" => "0x...",
      # ...or delegate co-signing to a hosted eth_fillTransaction endpoint.
      # "fee_payer_url" => "https://sponsor.example.com",
      # "sponsor_budget_id" => "0x...hosted-sponsor-wallet",
      "fee_token" => "0x...(fee token address)",
      "fee_payer_policy" => %{
        "max_in_flight_total_fee" => 500_000_000_000_000_000,
        "max_in_flight_reservations" => 100
      },
      "wait_for_confirmation" => false,
      "memo" => "0x...(optional 32-byte memo)"
    }
end
```

### EVM (Ethereum, Base, Polygon, etc.)

```elixir
pipeline :paid_evm do
  plug MPP.Plug,
    secret_key: "your-hmac-secret",
    realm: "api.example.com",
    method: MPP.Methods.EVM,
    amount: "1000000",
    currency: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    recipient: "0x...your-address",
    method_config: %{
      "rpc_url" => "https://mainnet.infura.io/v3/YOUR_KEY",
      "chain_id" => 1
    }
end
```

Currency is the ERC-20 token contract address (e.g., USDC above). For native ETH, use `"ETH"` or the zero address. `"chain_id"` is required — the EIP-155 chain ID of the target network (e.g. `1` for Ethereum mainnet). Hash credentials: the client broadcasts a transaction, then sends the hash. For Circle USDC/EURC, set `"private_key"` (server-only settlement key) to advertise `type="authorization"` and settle EIP-3009 `transferWithAuthorization` with `challengeHash` as the nonce.

### Solana (SOL and SPL tokens)

```elixir
pipeline :paid_solana do
  plug MPP.Plug,
    secret_key: "your-hmac-secret",
    realm: "api.example.com",
    method: MPP.Methods.Solana,
    amount: "10000000",
    currency: "sol",
    recipient: "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
    method_config: %{
      "rpc_url" => "https://api.mainnet-beta.solana.com",
      "network" => "mainnet"
    }
end
```

Currency is `"sol"` for native SOL (amount in lamports) or a base58 mint address for SPL tokens. Pull mode (`type="transaction"`) sends signed transaction bytes for the server to broadcast; push mode (`type="signature"`) sends a confirmed signature. Set `"fee_payer" => true` with `"fee_payer_private_key"` to co-sign as fee payer. Optional `"splits"` (at most 8) add extra payment legs.

### NEAR Intents (1Click)

Hash-only charges. Call `MPP.Methods.NearIntents.quote/1` to mint a wet `EXACT_OUTPUT` 1Click quote, then mount the returned amount, origin asset, deposit address, and `method_config` on `MPP.Plug`. The client deposits on the origin chain and retries with `type="hash"`. Verification waits for 1Click `SUCCESS` (and can check EVM origin RPC when `"origin_rpc_url"` is set). A configured `"store"` must implement atomic `MPP.Tempo.Store.update/3`. There is no Intents testnet — live tests use production 1Click plus historical deposits. Optional partner JWT: `"one_click_jwt"` / `NEAR_INTENTS_ONE_CLICK_JWT`.

```elixir
{:ok, quote} =
  MPP.Methods.NearIntents.quote(%{
    "origin_asset" => "eip155:1/erc20:0xdac17f958d2ee523a2206206994597c13d831ec7",
    "origin_asset_id" => "nep141:eth-usdt.omft.near",
    "destination_asset" => "tron:mainnet/trc20:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    "destination_asset_id" => "nep141:tron-usdt.omft.near",
    "destination_recipient" => "TJ4FU4NFMqFDtcLYxFnJvfv3rWfLN9vCB7",
    "amount_out" => "1000000",
    "refund_to" => "0x...",
    "deadline" => deadline
  })

plug MPP.Plug,
  secret_key: "your-hmac-secret",
  realm: "api.example.com",
  method: MPP.Methods.NearIntents,
  amount: quote.amount,
  currency: quote.currency,
  recipient: quote.recipient,
  method_config: quote.method_config
```

**Replay protection is on by default.** When you don't configure a `"store"`, MPP uses the app-started `MPP.Tempo.ConCacheStore` so each transaction hash is accepted only once out of the box. For multi-node deployments, configure `method_config["store"]` with a shared `MPP.Tempo.Store` implementation (Redis, Postgres, …); a configured store must implement the atomic `check_and_mark/2`. When multiple endpoints share one `ConCacheStore`, add `key_prefix: "tenant:"` in the store opts to namespace dedup keys. Pass `store: false` (Plug opt) or `"store" => false` (method_config) to explicitly opt out of dedup — not recommended.

### Multi-Method (Stripe + Tempo)

Offer multiple payment options in a single 402 response — the agent picks whichever it can pay with:

```elixir
pipeline :paid_multi do
  plug MPP.Plug,
    secret_key: "your-hmac-secret",
    realm: "api.example.com",
    methods: [
      [
        method: MPP.Methods.Stripe,
        amount: "5000",
        currency: "usd",
        method_config: %{"stripe_secret_key" => "sk_test_..."}
      ],
      [
        method: MPP.Methods.Tempo,
        amount: "5000000",
        currency: "0x...(pathUSD)",
        recipient: "0x...",
        method_config: %{"rpc_url" => "https://rpc.tempo.xyz"}
      ]
    ]
end
```

Requests without payment get a `402 Payment Required` with a challenge. Requests with a valid `Authorization: Payment` credential pass through with a `Payment-Receipt` header and the receipt in `conn.assigns[:mpp_receipt]`.

Each route can have its own pricing — just mount `MPP.Plug` with different `amount`/`currency` per pipeline or scope.

### Recurring subscriptions

Set `intent: "subscription"` with `period_unit` and `period_count` to use the
shared `MPP.Intents.Subscription` schema. `MPP.Methods.Stripe` activates a
constrained fixed-price Stripe subscription and verifies its paid first invoice.
`MPP.Methods.Tempo` activates a scoped access key, settles the first period, and
exposes `MPP.Methods.Tempo.Subscription.authorize/2` for later renewals. Tempo
subscriptions use `MPP.Subscription.ETSStore` by default; configure a shared
`MPP.Subscription.Store` backend when renewals must coordinate across nodes or
survive restarts.

## What This Means for Your API

Today, monetizing an API means building a billing system: user accounts, API key provisioning, usage tracking, rate limiting, a pricing page, a dashboard. That's months of work before you earn a cent.

With MPP, you add one Plug to your router and your API charges per-request. No accounts. No API keys. No billing infrastructure. The payment *is* the authentication.

**Use cases:**

- Charge $0.01 per AI inference call
- Charge $0.50 per premium data query
- Charge $5.00 per document generation
- Different prices per route — one Plug per endpoint

**For AI agents:** Your API becomes callable by any agent with a wallet. No onboarding flow, no API key provisioning, no approval process. The agent discovers the price from the 402 response, pays, and gets the resource. That's it — your API just acquired a customer in one HTTP roundtrip.

## Why MPP?

- **No user management.** No accounts, no API keys, no dashboards, no onboarding. The 402 flow handles auth and billing in one protocol.
- **Agent-native.** AI agents can't click buttons or fill out forms. They can make HTTP requests and hold wallets. MPP meets agents where they are.
- **Sticky by default.** When your API is a line of code in a deployed system, the switching cost is engineering hours — not emotional preference.
- **Payment-method agnostic.** Stripe cards, stablecoins, on-chain tokens, Lightning — all pluggable via the same `Method` behaviour.

## Payment Methods

| Method | Protocol | Settlement | Status |
|--------|----------|------------|--------|
| Stripe | MPP | Fiat (cards, wallets) | v0.1.0 |
| Tempo | MPP | Stablecoins (TIP-20) | v0.2.0 |
| EVM | MPP | Any EVM chain (ETH, USDC, ERC-20) | v0.3.0 |
| Solana | MPP | Native SOL and SPL tokens | Unreleased |
| Lightning | MPP | Bitcoin (BOLT11) | Future |

The server can offer multiple payment methods in a single 402 response. The agent picks whichever it can pay with.

**Tempo capabilities:** Local or hosted fee-payer co-signing (server sponsors gas), fee-token allowlists, optimistic broadcast (respond before block inclusion), memo matching for transaction tagging, zero-amount proof credentials, delegated access-key proof authorization, opt-in presenter-identity binding for hash/transaction credentials, first-party machine-token (MPP Credits / machineUSD) charge payments via `"machine_token_enabled"`, and pluggable dedup stores with a built-in ETS+TTL option via ConCache, including per-store key prefixes for shared-cache tenancy.

**Tempo security note:** Challenges expire by default. On routes without a configured static memo, Tempo payments must use challenge-bound attribution metadata; plain transfers are rejected by the hardened verifier. Sponsored transactions are bounded by fee-payer gas policy and returned hosted fee tokens are checked against the sponsor allowlist before broadcast. Setting `"require_presenter_binding" => true` in the Tempo `method_config` additionally requires hash/transaction credential presenters to prove control of the transfer sender's wallet with a `"presenterSignature"` (the proof path's EIP-712 envelope, signed by the sender wallet or an authorized access key; the client signs `MPP.Methods.Tempo.Proof.hash/1` typed data) — closing the front-running residual documented in GHSA-34g7-vx6g-82mq. The requirement is advertised as `"presenterBinding": true` in the 402 method details. Opt-in because neither reference SDK binds the presenter on the hash path.

**Tempo networks:** [Mainnet](https://docs.tempo.xyz/quickstart/connection-details#mainnet) (chain ID `4217`, `rpc.tempo.xyz`) | [Testnet (Moderato)](https://docs.tempo.xyz/quickstart/connection-details#testnet) (chain ID `42431`, `rpc.moderato.tempo.xyz`)

## Modules

| Module | Purpose |
|--------|---------|
| `MPP.Plug` | Plug middleware — the main integration point |
| `MPP.Plug.Config` | Validated endpoint config (shared settings + method entries) |
| `MPP.Plug.MethodEntry` | Per-method config within a multi-method endpoint |
| `MPP.Challenge` | HMAC-SHA256 bound challenge creation/verification |
| `MPP.Credential` | Payment credential encoding/decoding |
| `MPP.Receipt` | Proof-of-payment receipt serialization |
| `MPP.Headers` | WWW-Authenticate (incl. multi-challenge), Authorization, Payment-Receipt headers |
| `MPP.AcceptPayment` | Accept-Payment client-preference header: parse, format, rank, apply_header |
| `MPP.Errors` | RFC 9457 Problem Detail error types (incl. session error types) |
| `MPP.Verifier` | Transport-neutral verification pipeline (HMAC, realm, expiry, request match, method.verify) |
| `MPP.JCS` | RFC 8785 JSON Canonicalization (MPP subset) for cross-SDK HMAC interop |
| `MPP.BodyDigest` | SHA-256 body digest compute/verify for request body binding |
| `MPP.Amount` | Amount/decimals helpers: `parse_units`, `with_base_units`, `parse_dollar_amount` |
| `MPP.Expires` | Expiration helpers: `seconds`, `minutes`, `hours`, `days`, `weeks`, `months`, `years`, `assert!` |
| `MPP.DID` | DID helpers for EVM credential sources |
| `MPP.Method` | Behaviour for pluggable payment methods |
| `MPP.Intents.Charge` | Charge intent request schema |
| `MPP.Intents.Session` | Session intent request schema (pay-as-you-go) |
| `MPP.Intents.Subscription` | Shared recurring-subscription intent schema |
| `MPP.Session.Channel` | Session channel state, balance, and action wire mapping |
| `MPP.Session.Voucher` | EIP-712 voucher typed data and signature verification |
| `MPP.Session.Payload` | Session credential payload schema (`open` / `voucher` / `topUp` / `close`) |
| `MPP.Session.Actions` | Session credential action handlers and per-channel balance tracking |
| `MPP.Session.Method` | `use` wrapper that dispatches `verify/2` through session actions |
| `MPP.Session.Store` | Pluggable session-channel persistence |
| `MPP.Session.ETSStore` | ETS-backed default session store |
| `MPP.Subscription.Store` | Pluggable recurring-subscription persistence |
| `MPP.Subscription.ETSStore` | Application-started single-node subscription store |
| `MPP.Methods.Stripe` | Stripe SPT payment verification |
| `MPP.Methods.Stripe.Subscription` | Stripe fixed-price subscription activation and first-invoice verification |
| `MPP.Methods.Tempo` | Tempo on-chain TIP-20 transfer verification via `onchain_tempo` |
| `MPP.Methods.Tempo.Subscription` | Tempo access-key subscription activation, authorization, and renewal |
| `MPP.Methods.Tempo.FeePayerPolicy` | Fee-payer gas and fee-token sponsorship policy |
| `MPP.Methods.Tempo.HostedFeePayer` | Hosted `eth_fillTransaction` fee-payer fill support |
| `MPP.Methods.Tempo.MachineToken` | Canonical first-party machine-token (MPP Credits) charge-route construction and match |
| `MPP.Methods.Tempo.Proof` | EIP-712 proof credentials for zero-amount Tempo flows |
| `MPP.Methods.Tempo.SessionReceipt` | Tempo session receipt wire format |
| `MPP.Methods.EVM` | Generic EVM on-chain transfer verification (any chain) via `onchain` |
| `MPP.Methods.Solana` | Solana native SOL and SPL token charge verification via `cartouche` |
| `MPP.Methods.NearIntents` | NEAR Intents hash-credential charges via 1Click Swap + origin RPC |
| `MPP.Tempo.Store` | Behaviour for pluggable transaction dedup stores |
| `MPP.Tempo.ConCacheStore` | Built-in ETS dedup store with TTL via ConCache |
| `MPP.Telemetry` | Server-side payment telemetry events for challenges, verification, and receipts |
| `MPP.Mcp` | MCP (JSON-RPC) transport: server adapter (`init/1` + `call/3`), error codes, meta keys, client helpers |
| `MPP.Transports.JsonRpc` | Bare JSON-RPC transport: root-level `_meta` credential/receipt, `-32042` challenges |
| `MPP.Transports.JsonRpc.Plug` | Plug adapter for JSON-RPC-over-HTTP payment verification |
| `MPP.Transports.WebSocket` | WebSocket adapter: handshake `challenge`, `credential`/`receipt` frames, JSON-RPC `message` frames |
| `MPP.Client.PaymentProvider` | Behaviour for client-side payment providers (`supports?/3`, `pay/2`) |
| `MPP.Client.MultiProvider` | Multi-provider dispatch with first-match routing |
| `MPP.Client.Providers.Tempo` | Built-in Tempo charge provider — chain-pinned, attribution-bound TIP-20 payments, including machine-token `[approve, swapTo]` when advertised |
| `MPP.Client.Providers.Stripe` | Built-in Stripe charge provider — Shared Payment Token creation |
| `MPP.Client.SelectionPolicy` | Transport-neutral challenge selection/ordering (default: server offer order) |
| `MPP.Client.Req` | Payment-aware Req plugin — 402 detect, pay, retry (`attach/2`) |
| `MPP.Client.Transport` | Client transport behaviour — 402 detection, challenge fetch, credential attach |
| `MPP.Client.Transport.HTTP` | HTTP transport over `Req` |
| `MPP.Client.Transport.MCP` | MCP/JSON-RPC transport: `-32042` detection, challenge extract, `_meta` credential attach |
| `MPP.Client.Transport.JsonRpc` | Bare JSON-RPC transport: `-32042` detection, root-level `_meta` credential attach |
| `MPP.Client.Transport.WebSocket` | WebSocket transport: `challenge` frames, `Payment` credential frames, retry/backoff |
| `MPP.Client.MCP` | Payment-aware MCP client — select, approve, pay, retry the tool call once |
| `MPP.Client.AcceptPolicy` | Gates `Accept-Payment` header injection on outgoing requests |

## Client

```elixir
provider =
  MPP.Client.MultiProvider.new([
    {MPP.Client.Providers.Tempo,
     %{
       private_key: tempo_private_key,
       rpc_url: "https://rpc.tempo.xyz",
       expected_chain_id: 4217,
       client_id: "my-agent"
     }},
    {MPP.Client.Providers.Stripe,
     %{
       secret_key: stripe_secret_key,
       payment_method: "pm_..."
     }}
  ])

Req.new()
|> MPP.Client.Req.attach(provider: provider)
|> Req.get(url: "https://api.example.com/resource")
```

`MPP.Client.Req` intercepts HTTP 402, pays, and retries with `Authorization: Payment`.
Provider credentials and endpoints are passed explicitly; the providers do not read
application configuration or environment variables. The Tempo provider verifies that
the RPC serves the challenge's advertised chain before signing and automatically creates
the challenge-bound attribution memo required by routes without a static memo.
A payment credential must never be created or attached after a redirect changed the
request origin — `Req` follows redirects by default. `MPP.Client.Req.attach/2` refuses
that path (`:cross_origin_redirect`, mpp-rs #379). Callers that drive
`MPP.Client.Transport.HTTP` themselves must apply the same rule: do not call
`set_credential/2` on a request whose origin (scheme/host/port) differs from the
URL the caller asked for.

```elixir
client = MPP.Client.MCP.new(provider: my_provider)
MPP.Client.MCP.call(client, request, &MyTransport.send/1)
```

`MPP.Client.MCP` does the same pay-and-retry over JSON-RPC: it detects `-32042`,
selects a challenge, asks `on_payment_required` for approval, pays, and retries
once with the credential at `params._meta["org.paymentauth/credential"]`.

Generic (non-MCP) JSON-RPC uses root-level `_meta` so `params` can be an array.
`MPP.Transports.JsonRpc.Plug` mounts on a Plug route; `MPP.Client.Transport.JsonRpc`
attaches the credential at `_meta["org.paymentauth/credential"]` on the request
envelope.

WebSocket endpoints use typed MPP frames (mpp-rs / `alloy-transport-mpp`).
`MPP.Transports.WebSocket` is library-agnostic: `open/1` emits the handshake
`challenge`, `handle_text/2` verifies a `credential` frame and then dispatches
JSON-RPC carried in `message` frames. `MPP.Client.Transport.WebSocket` detects
`challenge` frames and attaches `Payment <base64url>` credential frames.
`MPP.Client.Transport.WebSocket.Retry` matches upstream reconnect posture:
capped exponential backoff, fatal latch on protocol errors, and no second
payment after a drop that left a credential unacknowledged.

## Installation

```elixir
def deps do
  [
    {:mpp, "~> 0.13.0"}
  ]
end
```

`onchain`, `onchain_tempo`, and `con_cache` are pulled in automatically — no extra setup for EVM, Tempo, or the built-in `MPP.Tempo.ConCacheStore` dedup store.

## Live Example

[Strip0x](https://strip0x.com) — blockchain tools API using MPP with Tempo payments. $0.0001 per paid request (100 base units USDC.e on Tempo mainnet).

```bash
# Free endpoint (no payment needed)
curl "https://strip0x.com/api/hex/encode?value=hello"

# See the 402 challenge on a paid endpoint
curl -i "https://strip0x.com/api/address/validate?address=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

# Pay and get the response (~2s round-trip including on-chain settlement)
tempo request -t -X GET "https://strip0x.com/api/address/validate?address=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

# Machine-readable discovery (OpenAPI 3.1 with x-payment-info extensions)
curl https://strip0x.com/openapi.json
```

**Observed latency:** ~2s end-to-end for a paid request (402 challenge + Tempo on-chain TIP-20 transfer + credential retry). Free endpoints respond in ~70ms (network only — business logic is sub-10μs on the BEAM).

Try it and [open an issue](https://github.com/ZenHive/mpp/issues) if anything breaks.

## Continuous Integration

Two GitHub Actions workflows gate the repo (Elixir/OTP pinned via `.tool-versions`,
so CI never drifts from local `mix format`):

- **CI** (`.github/workflows/ci.yml`) — runs on every push/PR to `development` and
  `main`: format check, `--warnings-as-errors` compile, Credo strict, Doctor,
  Sobelow, tests with a 95% coverage gate, and Dialyzer. Mirrors `mix precommit.full`.
- **Integration** (`.github/workflows/integration.yml`) — runs the credential-gated
  `:integration` suite nightly (and on PR / manual dispatch). These live round-trips
  catch the bug class unit tests are blind to (wrong gas limit, wrong request shape,
  on-chain accounting drift). It requires the following repo secrets — when any are
  absent the suite **flunks loudly** rather than reporting a green 0-test run:

  | Secret | Purpose |
  |--------|---------|
  | `TEMPO_RPC_URL` | Moderato testnet RPC (`https://rpc.moderato.tempo.xyz`) |
  | `STRIPE_SECRET_KEY` | Stripe **test-mode** secret key (`sk_test_…`) |
  | `ETH_SEPOLIA_RPC_URL` / `ETH_SEPOLIA_PRIVATE_KEY` | Sepolia RPC + funded key |
  | `EVM_RPC_URL` / `EVM_PRIVATE_KEY` | Generic EVM RPC + funded key (falls back to Sepolia) |

A third workflow, **Code Scanning** (`.github/workflows/code-scanning.yml`), uploads
Sobelow findings to the Security → Code scanning tab (CodeQL has no Elixir support).
Security vulnerabilities should be reported privately — see [SECURITY.md](SECURITY.md).

## References

- [MPP Specification](https://github.com/tempoxyz/mpp-specs) — IETF draft, core protocol
- [x402 Documentation](https://docs.x402.org) — On-chain payment standard
- [Stripe MPP Announcement](https://stripe.com/blog/machine-payments-protocol) — Stripe's agent commerce vision
- [mpp.dev](https://mpp.dev) — Protocol overview and SDK links

## License

MIT — see [LICENSE](LICENSE) for details.
