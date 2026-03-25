# MPP

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

## Why MPP?

- **No user management.** No accounts, no API keys, no dashboards, no onboarding. The 402 flow handles auth and billing in one protocol.
- **Agent-native.** AI agents can't click buttons or fill out forms. They can make HTTP requests and hold wallets. MPP meets agents where they are.
- **Sticky by default.** When your API is a line of code in a deployed system, the switching cost is engineering hours — not emotional preference.
- **Payment-method agnostic.** Stripe cards, stablecoins, on-chain tokens, Lightning — all pluggable via the same `Method` behaviour.

## Payment Methods

| Method | Protocol | Settlement | Status |
|--------|----------|------------|--------|
| Stripe | MPP | Fiat (cards, wallets) | Planned |
| Tempo | MPP | Stablecoins (TIP-20) | Planned |
| x402 | x402/MPP | EVM/Solana on-chain (USDC, ERC-20) | Planned |
| Lightning | MPP | Bitcoin (BOLT11) | Future |

The server can offer multiple payment methods in a single 402 response. The agent picks whichever it can pay with.

## Installation

```elixir
def deps do
  [
    {:mpp, "~> 0.0.1"}
  ]
end
```

## Status

Early development — API surface not yet stable. Plug middleware and payment method implementations are underway.

## References

- [MPP Specification](https://github.com/tempoxyz/mpp-specs) — IETF draft, core protocol
- [x402 Documentation](https://docs.x402.org) — On-chain payment standard
- [Stripe MPP Announcement](https://stripe.com/blog/machine-payments-protocol) — Stripe's agent commerce vision
- [mpp.dev](https://mpp.dev) — Protocol overview and SDK links

## License

MIT — see [LICENSE](LICENSE) for details.
