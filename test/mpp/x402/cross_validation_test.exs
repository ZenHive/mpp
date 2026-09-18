defmodule MPP.X402.CrossValidationTest do
  @moduledoc """
  SDK-compatibility checks against `refs/mppx/src/x402`.

  Protocol authority remains the official x402 v2 spec and live facilitator
  traffic. These tests only pin the mppx surface Task 81 must match.
  """

  use ExUnit.Case, async: true

  @moduletag :cross_validation

  @types "refs/mppx/src/x402/Types.ts"
  @exact "refs/mppx/src/x402/client/Exact.ts"
  @transport "refs/mppx/src/client/Transport.ts"
  @x402_protocol "refs/mppx/src/client/internal/protocols/X402.ts"

  test "mppx ships scheme exact only and random-or-extension-bound nonces" do
    types = read!(@types)
    exact = read!(@exact)

    assert types =~ "export const schemes = ['exact'] as const"
    assert types =~ "export const paymentMethod = 'evm'"
    assert types =~ "export const exactIntent = 'charge'"
    assert types =~ "syntheticChallengeIdPrefix = 'x402:'"
    assert exact =~ "randomAuthorizationNonce()"
    assert exact =~ "RouteBinding.nonce("
    refute exact =~ "challengeHash"
  end

  test "mppx HTTP transport collects native Payment and x402 offers together" do
    transport = read!(@transport)
    x402 = read!(@x402_protocol)

    assert transport =~ "protocols/X402"
    assert x402 =~ "PAYMENT-REQUIRED" or x402 =~ "paymentRequiredHeader" or x402 =~ "payment-required"
  end

  defp read!(path) do
    if File.exists?(path) do
      File.read!(path)
    else
      flunk("""
      Missing #{path}. Clone wevm/mppx into refs/mppx for SDK-compatibility evidence:

        git clone --depth 1 https://github.com/wevm/mppx.git refs/mppx

      Then re-run:
        mix test test/mpp/x402/cross_validation_test.exs --include cross_validation
      """)
    end
  end
end
