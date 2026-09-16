defmodule MPP.ChallengeHeaderCrossValidationTest do
  @moduledoc """
  Cross-validates the optional `header` HMAC slot against both reference SDKs.

  Layout is the SDK insert-before-opaque (mppx `idBindingInput`, mpp-rs
  `compute_challenge_id_with_header`), a deliberate interoperability exception
  from draft-httpauth-payment-01 which still appends `header` after `opaque`
  (tempoxyz/mpp-specs#357).

  Requires the gitignored JS toolchain (QuickBEAM + node + `zod`/`ox`) and a
  Rust toolchain able to compile `refs/mpp-rs` with `default-features = false`.
  Excluded from the default gate; run with `--include cross_validation`.
  """

  use ExUnit.Case, async: false

  alias MPP.Challenge
  alias MPP.Headers
  alias MPP.Test.MppRsHmacOracle
  alias MPP.Test.MppxChallengeBundle

  @moduletag :cross_validation

  @secret "test-vector-secret"
  @realm "api.example.com"
  @method "tempo"
  @intent "charge"
  @request_json ~S({"amount":"1000000"})
  @legacy_id "X6v1eo7fJ76gAxqY0xN9Jd__4lUyDDYmriryOM-5FO4"
  @header_id "S91xi-OFGZPMs-j7GsX0FDpIkmCcZT1P9XyV58WNy_U"

  defp request_b64, do: Base.url_encode64(@request_json, padding: false)

  defp elixir_challenge(header) do
    params = [realm: @realm, method: @method, intent: @intent, request: request_b64()]
    params = if header, do: Keyword.put(params, :header, header), else: params
    Challenge.create(params, @secret)
  end

  defp rust_id(header) do
    MppRsHmacOracle.compute_id!(
      secret: @secret,
      realm: @realm,
      method: @method,
      intent: @intent,
      request: request_b64(),
      header: header || ""
    )
  end

  describe "challenge id vs mppx and mpp-rs" do
    setup do
      if !Code.ensure_loaded?(QuickBEAM) do
        flunk("QuickBEAM not available. This test requires the dev/test dependency stack.")
      end

      {:ok, rt} = QuickBEAM.start(apis: :browser)
      MppxChallengeBundle.load!(rt)
      on_exit(fn -> if Process.alive?(rt), do: QuickBEAM.stop(rt) end)
      %{rt: rt}
    end

    test "header-less id matches the 0.16.0 golden and both SDKs", %{rt: rt} do
      elixir = elixir_challenge(nil)
      assert elixir.id == @legacy_id
      assert rust_id(nil) == elixir.id
      assert mppx_id(rt, nil) == elixir.id
    end

    test "Payment-Authorization id matches both SDKs (insert before opaque)", %{rt: rt} do
      elixir = elixir_challenge("Payment-Authorization")
      assert elixir.id == @header_id
      assert elixir.header == "Payment-Authorization"
      assert rust_id("Payment-Authorization") == elixir.id
      assert mppx_id(rt, "Payment-Authorization") == elixir.id

      header = Headers.format_challenge(elixir)
      {:ok, mppx_parsed} = QuickBEAM.call(rt, "mppxDeserialize", [header])
      assert mppx_parsed["header"] == "Payment-Authorization"
      assert mppx_parsed["id"] == elixir.id
    end
  end

  defp mppx_id(rt, header) do
    params = %{
      "secretKey" => @secret,
      "realm" => @realm,
      "method" => @method,
      "intent" => @intent,
      "request" => %{"amount" => "1000000"}
    }

    params = if header, do: Map.put(params, "header", header), else: params

    case QuickBEAM.call(rt, "mppxFrom", [params]) do
      {:ok, %{"id" => id}} when is_binary(id) ->
        id

      {:ok, other} ->
        flunk("mppx Challenge.from returned unexpected shape: #{inspect(other)}")

      {:error, reason} ->
        flunk("mppx Challenge.from failed: #{inspect(reason)}")
    end
  end
end
