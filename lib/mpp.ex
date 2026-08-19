defmodule MPP do
  @moduledoc """
  Elixir implementation of the [Machine Payments Protocol](https://mpp.dev) (MPP).

  MPP enables machine-to-machine payments via HTTP 402. This library provides
  Plug middleware that adds pay-per-call billing to any Phoenix or Plug application.

  ## How it works

  1. Client requests a protected resource
  2. Server responds with `402 Payment Required` and a payment challenge
  3. Client fulfills payment (Stripe, stablecoins, or on-chain)
  4. Client retries with payment credential in `Authorization: Payment` header
  5. Server verifies payment and returns the resource with a `Payment-Receipt` header

  No user accounts. No API keys. No signup flow. Payment is authentication.

  ## Protocol

  Built on the [MPP specification](https://github.com/tempoxyz/mpp-specs) —
  an IETF draft co-developed by Stripe and Tempo Labs. Also supports
  [x402](https://docs.x402.org) for on-chain payments.

  ## Modules

    * `MPP.Plug` — Plug middleware implementing the 402 payment handshake
    * `MPP.Challenge` — HMAC-SHA256 bound challenge creation and verification
    * `MPP.Credential` — Payment credential encoding/decoding
    * `MPP.Receipt` — Proof-of-payment receipt serialization
    * `MPP.Headers` — WWW-Authenticate, Authorization, Payment-Receipt header formatting
    * `MPP.AcceptPayment` — Accept-Payment client-preference header parse/format/rank
    * `MPP.Errors` — RFC 9457 Problem Detail error types
    * `MPP.Method` — Behaviour for pluggable payment methods
    * `MPP.Methods.Stripe` — Stripe SPT payment verification
    * `MPP.Methods.Tempo` — Tempo on-chain TIP-20 payment verification
    * `MPP.Methods.EVM` — Generic EVM on-chain payment verification (any EVM chain)
    * `MPP.Methods.Solana` — Solana native SOL and SPL token charge verification
    * `MPP.Methods.NearIntents` — NEAR Intents hash-credential charge verification via 1Click + origin RPC
    * `MPP.Intents.Charge` — Charge intent request schema
    * `MPP.Intents.Session` — Session intent request schema (pay-as-you-go / metered)
    * `MPP.Intents.Subscription` — Shared recurring-subscription intent schema
    * `MPP.Session.Channel` — Session channel state, balance, and action wire mapping
    * `MPP.Session.Voucher` — EIP-712 voucher typed data and signature verification
    * `MPP.Session.Payload` — Session credential payload schema (`open` / `voucher` / `topUp` / `close`)
    * `MPP.Session.Actions` — Session credential action handlers and per-channel balance tracking
    * `MPP.Session.Method` — `use` wrapper that dispatches `verify/2` through session actions
    * `MPP.Session.Store` — Pluggable session-channel persistence
    * `MPP.Session.ETSStore` — ETS-backed default session store
    * `MPP.BodyDigest` — SHA-256 body digest computation and verification
    * `MPP.Amount` — Amount/decimals helpers (parse_units, dollar parsing)
    * `MPP.Expires` — Expiration timestamp helpers (duration offsets, assert!)
    * `MPP.DID` — DID helpers for EVM credential sources
    * `MPP.JCS` — RFC 8785 JSON Canonicalization Scheme for HMAC interop
    * `MPP.Verifier` — Transport-neutral payment credential verification
    * `MPP.Mcp` — MCP (JSON-RPC) transport constants and helpers
    * `MPP.Transports.JsonRpc` — Bare JSON-RPC transport (root-level `_meta`, Plug adapter)
    * `MPP.Client.PaymentProvider` — Behaviour for client-side payment providers
    * `MPP.Client.MultiProvider` — Multi-provider dispatch (first-match routing)
    * `MPP.Client.Providers.Tempo` — Built-in Tempo charge provider (chain-pinned, attribution-bound, machine-token route when advertised)
    * `MPP.Client.Providers.Stripe` — Built-in Stripe charge provider (Shared Payment Tokens)
    * `MPP.Client.SelectionPolicy` — Transport-neutral challenge selection/ordering
    * `MPP.Client.Req` — Payment-aware Req plugin (402 detect, pay, retry)
    * `MPP.Client.MCP` — Payment-aware MCP client (select, approve, pay, retry once)
    * `MPP.Client.AcceptPolicy` — Gate `Accept-Payment` header injection by URL
    * `MPP.Discovery.OpenApi` — OpenAPI 3.1.0 payment discovery generation
    * `MPP.Discovery.PaymentInfo` — x-payment-info parsing and normalization

  ## Discovery

  Use `MPP.describe/0-2` for progressive API discovery:

      MPP.describe()                          # Level 1: all modules
      MPP.describe(:challenge)                # Level 2: functions in Challenge
      MPP.describe(:challenge, :create)       # Level 3: full contract for create/2
  """

  use Descripex.Discoverable,
    modules: [
      MPP.Challenge,
      MPP.Credential,
      MPP.Receipt,
      MPP.Headers,
      MPP.AcceptPayment,
      MPP.Errors,
      MPP.Intents.Charge,
      MPP.Intents.Session,
      MPP.Intents.Subscription,
      MPP.Methods.Stripe,
      MPP.Methods.Tempo,
      MPP.Methods.EVM,
      MPP.Methods.Solana,
      MPP.Methods.NearIntents,
      MPP.BodyDigest,
      MPP.Amount,
      MPP.Expires,
      MPP.DID,
      MPP.JCS,
      MPP.Verifier,
      MPP.Mcp,
      MPP.Transports.JsonRpc,
      MPP.Discovery.OpenApi,
      MPP.Discovery.PaymentInfo,
      MPP.Client.PaymentProvider,
      MPP.Client.MultiProvider,
      MPP.Client.SelectionPolicy,
      MPP.Client.Req,
      MPP.Client.AcceptPolicy
    ]
end
