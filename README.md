# MPP

[![CI](https://github.com/ZenHive/mpp/actions/workflows/ci.yml/badge.svg)](https://github.com/ZenHive/mpp/actions/workflows/ci.yml)
[![Code Scanning](https://github.com/ZenHive/mpp/actions/workflows/code-scanning.yml/badge.svg)](https://github.com/ZenHive/mpp/actions/workflows/code-scanning.yml)
[![GitHub](https://img.shields.io/github/license/ZenHive/mpp)](https://github.com/ZenHive/mpp/blob/development/LICENSE)

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
      # Either use a local fee-payer key...
      "fee_payer_private_key" => "0x...",
      # ...or delegate co-signing to a hosted eth_fillTransaction endpoint.
      # "fee_payer_url" => "https://sponsor.example.com",
      "fee_token" => "0x...(fee token address)",
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

Currency is the ERC-20 token contract address (e.g., USDC above). For native ETH, use `"ETH"` or the zero address. The client broadcasts a transaction, then sends the hash as a credential.

**Replay protection is on by default.** When you don't configure a `"store"`, MPP uses the app-started `MPP.Tempo.ConCacheStore` so each transaction hash is accepted only once out of the box. For multi-node deployments, configure `method_config["store"]` with a shared `MPP.Tempo.Store` implementation (Redis, Postgres, …); a configured store must implement the atomic `check_and_mark/2`. Pass `store: false` (Plug opt) or `"store" => false` (method_config) to explicitly opt out of dedup — not recommended.

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
| Lightning | MPP | Bitcoin (BOLT11) | Future |

The server can offer multiple payment methods in a single 402 response. The agent picks whichever it can pay with.

**Tempo capabilities:** Local or hosted fee-payer co-signing (server sponsors gas), fee-token allowlists, optimistic broadcast (respond before block inclusion), memo matching for transaction tagging, zero-amount proof credentials, delegated access-key proof authorization, opt-in presenter-identity binding for hash/transaction credentials, and pluggable dedup stores with a built-in ETS+TTL option via ConCache.

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
| `MPP.Errors` | RFC 9457 Problem Detail error types (incl. session error types) |
| `MPP.Verifier` | Transport-neutral verification pipeline (HMAC, realm, expiry, request match, method.verify) |
| `MPP.JCS` | RFC 8785 JSON Canonicalization (MPP subset) for cross-SDK HMAC interop |
| `MPP.BodyDigest` | SHA-256 body digest compute/verify for request body binding |
| `MPP.Amount` | Amount/decimals helpers: `parse_units`, `with_base_units`, `parse_dollar_amount` |
| `MPP.Expires` | Expiration helpers: `seconds`, `minutes`, `hours`, `days`, `weeks`, `months`, `years`, `assert!` |
| `MPP.DID` | DID helpers for EVM credential sources |
| `MPP.Method` | Behaviour for pluggable payment methods |
| `MPP.Intents.Charge` | Charge intent request schema |
| `MPP.Methods.Stripe` | Stripe SPT payment verification |
| `MPP.Methods.Tempo` | Tempo on-chain TIP-20 transfer verification via `onchain_tempo` |
| `MPP.Methods.Tempo.FeePayerPolicy` | Fee-payer gas and fee-token sponsorship policy |
| `MPP.Methods.Tempo.HostedFeePayer` | Hosted `eth_fillTransaction` fee-payer fill support |
| `MPP.Methods.Tempo.Proof` | EIP-712 proof credentials for zero-amount Tempo flows |
| `MPP.Methods.Tempo.SessionReceipt` | Tempo session receipt wire format |
| `MPP.Methods.EVM` | Generic EVM on-chain transfer verification (any chain) via `onchain` |
| `MPP.Tempo.Store` | Behaviour for pluggable transaction dedup stores |
| `MPP.Tempo.ConCacheStore` | Built-in ETS dedup store with TTL via ConCache |
| `MPP.Telemetry` | Server-side payment telemetry events for challenges, verification, and receipts |
| `MPP.Mcp` | MCP (JSON-RPC) transport: error codes, meta keys, server/client helpers |
| `MPP.Client.PaymentProvider` | Behaviour for client-side payment providers (`supports?/3`, `pay/2`) |
| `MPP.Client.MultiProvider` | Multi-provider dispatch with first-match routing |
| `MPP.Client.Transport` | Client transport behaviour — 402 detection, challenge fetch, credential attach |
| `MPP.Client.Transport.HTTP` | HTTP transport over `Req` |
| `MPP.Client.AcceptPolicy` | Gates `Accept-Payment` header injection on outgoing requests |

## Installation

```elixir
def deps do
  [
    {:mpp, "~> 0.7.0"}
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
