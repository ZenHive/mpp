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

  ## Status

  Early development. Payment method implementations coming soon.
  """
end
