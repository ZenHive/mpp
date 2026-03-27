defmodule MPP.Methods.TempoTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20c0000000000000000000000000000000000000"

  setup do
    {:ok, charge} =
      Charge.new(
        amount: "1000000",
        currency: @token_address,
        recipient: "0x1234567890abcdef1234567890abcdef12345678"
      )

    # Simulate what Plug does: merge method_config into charge.method_details
    charge = %{
      charge
      | method_details: %{
          "rpc_url" => @rpc_url,
          "chain_id" => 42_431
        }
    }

    {:ok, charge: charge}
  end

  describe "method_name/0" do
    test "returns \"tempo\"" do
      assert Tempo.method_name() == "tempo"
    end
  end

  describe "validate_config!/1" do
    test "returns :ok with valid config" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url})
    end

    test "raises on missing rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Tempo.validate_config!(%{})
      end
    end

    test "raises on nil rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Tempo.validate_config!(%{"rpc_url" => nil})
      end
    end
  end

  describe "challenge_method_details/1" do
    test "returns chainId and feePayer with defaults", %{charge: charge} do
      # Reset method_details to only rpc_url (no chain_id override)
      charge = %{charge | method_details: %{"rpc_url" => @rpc_url}}
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 42_431
      assert details["feePayer"] == false
      refute Map.has_key?(details, "memo")
    end

    test "uses configured chain_id", %{charge: charge} do
      charge = %{charge | method_details: %{"chain_id" => 4217}}
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 4217
    end

    test "includes feePayer when configured", %{charge: charge} do
      charge = %{charge | method_details: %{"fee_payer" => true}}
      details = Tempo.challenge_method_details(charge)

      assert details["feePayer"] == true
    end

    test "includes memo when configured", %{charge: charge} do
      memo = "0x" <> String.duplicate("ab", 32)
      charge = %{charge | method_details: %{"memo" => memo}}
      details = Tempo.challenge_method_details(charge)

      assert details["memo"] == memo
    end

    test "omits memo when not configured", %{charge: charge} do
      details = Tempo.challenge_method_details(charge)

      refute Map.has_key?(details, "memo")
    end

    test "handles nil method_details" do
      {:ok, charge} = Charge.new(amount: "1000", currency: @token_address)
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 42_431
      assert details["feePayer"] == false
    end
  end

  describe "verify/2" do
    test "returns not-implemented error (skeleton)", %{charge: charge} do
      payload = %{"type" => "hash", "hash" => "0xabc123"}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "not yet implemented"
    end
  end
end
