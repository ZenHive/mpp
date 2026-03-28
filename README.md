# MPP

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
    method_config: %{
      "rpc_url" => "https://rpc.tempo.xyz",
      "chain_id" => 4217,
      "recipient" => "0x...your-address",
      "fee_payer" => true,
      "fee_payer_private_key" => "0x...",
      "fee_token" => "0x...(fee token address)",
      "wait_for_confirmation" => false,
      "memo" => "0x...(optional 32-byte memo)"
    }
end
```

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
        method_config: %{"rpc_url" => "https://rpc.tempo.xyz", "recipient" => "0x..."}
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
| x402 | x402/MPP | EVM/Solana on-chain (USDC, ERC-20) | Planned |
| Lightning | MPP | Bitcoin (BOLT11) | Future |

The server can offer multiple payment methods in a single 402 response. The agent picks whichever it can pay with.

**Tempo capabilities:** Fee payer co-signing (server sponsors gas), optimistic broadcast (respond before block inclusion), memo matching for transaction tagging, and pluggable dedup stores with a built-in ETS+TTL option via ConCache.

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
| `MPP.Headers` | WWW-Authenticate, Authorization, Payment-Receipt headers |
| `MPP.Errors` | RFC 9457 Problem Detail error types |
| `MPP.Method` | Behaviour for pluggable payment methods |
| `MPP.Intents.Charge` | Charge intent request schema |
| `MPP.Methods.Stripe` | Stripe SPT payment verification |
| `MPP.Methods.Tempo` | Tempo on-chain TIP-20 transfer verification |
| `MPP.Tempo.Transaction` | 0x76 Tempo Transaction RLP deserialization and payment call matching |
| `MPP.Tempo.Store` | Behaviour for pluggable transaction dedup stores |
| `MPP.Tempo.ConCacheStore` | Built-in ETS dedup store with TTL via ConCache (optional) |

## Installation

```elixir
def deps do
  [
    {:mpp, "~> 0.2.0"}
  ]
end
```

## References

- [MPP Specification](https://github.com/tempoxyz/mpp-specs) — IETF draft, core protocol
- [x402 Documentation](https://docs.x402.org) — On-chain payment standard
- [Stripe MPP Announcement](https://stripe.com/blog/machine-payments-protocol) — Stripe's agent commerce vision
- [mpp.dev](https://mpp.dev) — Protocol overview and SDK links

## License

MIT — see [LICENSE](LICENSE) for details.
