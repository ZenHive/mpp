defmodule MPP.Methods.NearIntentsIntegrationTest do
  @moduledoc """
  Live NEAR Intents integration tests against 1Click and Ethereum origin RPC.

  NEAR's provider documentation states that NEAR Intents has no testnet. These
  tests therefore use the production API without moving funds: one executable
  quote plus provider-observed historical `SUCCESS` and `REFUNDED` deposits.

  Run with:

      mix test.json test/mpp/methods/near_intents_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.NearIntents
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore

  @moduletag :integration

  @origin_network "eip155:1"
  @origin_token "0xdac17f958d2ee523a2206206994597c13d831ec7"
  @origin_asset @origin_network <> "/erc20:" <> @origin_token
  @destination_network "tron:mainnet"
  @destination_asset @destination_network <> "/trc20:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @destination_recipient "TJ4FU4NFMqFDtcLYxFnJvfv3rWfLN9vCB7"
  @refund_to "0x2cBEaF069aF231E1FAAB15D0aFEFD6aeaf06448A"

  # Provider-observed SUCCESS settlement, independently verified on Ethereum.
  @success_deposit "0x990F6413D7c397A66988adDaAc429eB8e7A6B5CC"
  @success_hash "0xdeb759ce1f8186ea526910797debbf1bdb7271f887c1e17550af3631c31ae015"
  @success_amount "24499630000"
  @success_destination_hash "00efc9710dc8b821fae6e7873cce8ab9f01637084714475bff40a3eded48adfd"

  # Provider-observed refund with AMOUNT_LESS_THAN_MIN_AMOUNT_OUT.
  @bitcoin_network "bip122:000000000019d6689c085ae165831e93"
  @refund_deposit "bc1q3r9mlre9qam8r2rywjwhnw2rr04ws8fmenupqx"
  @refund_hash "b914252483264a367d1df3a80ff05844f15ffb2b5b542cbad473c2dc76e9261e"
  @refund_store :near_intents_live_refund_store

  setup_all do
    rpc_url = System.get_env("ETHEREUM_API_URL")

    if is_nil(rpc_url) or rpc_url == "" do
      flunk("""
      Missing NEAR Intents origin RPC configuration!

      Set the archive-node endpoint:
        export ETHEREUM_API_URL="http://localhost:8545"

      Ensure the blockwatch-one RPC tunnel is running, then run:
        mix test.json test/mpp/methods/near_intents_integration_test.exs --include integration

      The 1Click status and quote endpoints require no credential. For a
      fee-free partner quote, optionally set:
        export NEAR_INTENTS_ONE_CLICK_JWT="<JWT from NEAR Intents>"

      Obtain partner access at: https://partners.near-intents.org
      """)
    end

    {:ok, rpc_url: rpc_url}
  end

  test "requests a real executable EXACT_OUTPUT quote" do
    deadline = DateTime.utc_now() |> DateTime.shift(day: 3) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    parameters = %{
      "origin_asset" => @origin_asset,
      "origin_asset_id" => "nep141:eth-0xdac17f958d2ee523a2206206994597c13d831ec7.omft.near",
      "destination_asset" => @destination_asset,
      "destination_asset_id" => "nep141:tron-d28a265909efecdcee7c5028585214ea0b96f015.omft.near",
      "destination_recipient" => @destination_recipient,
      "amount_out" => "1000000",
      "refund_to" => @refund_to,
      "deadline" => deadline,
      "referral" => "mpp-integration",
      "one_click_jwt" => System.get_env("NEAR_INTENTS_ONE_CLICK_JWT")
    }

    case NearIntents.quote(parameters) do
      {:ok, quote} ->
        assert positive_integer_string?(quote.amount)
        assert positive_integer_string?(quote.method_config["min_amount_in"])
        assert quote.recipient != ""
        assert {:ok, expires_at, 0} = DateTime.from_iso8601(quote.expires_at)
        assert DateTime.after?(expires_at, DateTime.utc_now())
        assert quote.method_config["quote_deadline"] == quote.expires_at
        assert quote.method_config["refund_to"] == @refund_to

      {:error, {:rejected, 401, _body}} ->
        flunk("""
        The live 1Click quote endpoint requires partner authorization.

        Set:
          export NEAR_INTENTS_ONE_CLICK_JWT="<JWT from NEAR Intents>"

        Obtain partner access at: https://partners.near-intents.org
        """)

      {:error, reason} ->
        flunk("Live 1Click quote failed: #{inspect(reason)}")
    end
  end

  test "verifies a real successful settlement through 1Click and origin RPC", %{rpc_url: rpc_url} do
    charge = success_charge(rpc_url)

    assert {:ok, %Receipt{} = receipt} = verify(charge, @success_hash)
    assert receipt.method == "nearintents"
    assert receipt.reference == @success_destination_hash
    assert receipt.extensions["originTxHash"] == @success_hash
    assert receipt.extensions["destinationNetwork"] == @destination_network
  end

  test "rejects a hash not observed for the successful deposit without consuming the quote" do
    charge = success_charge(nil)
    unrelated_hash = "0x" <> String.duplicate("ab", 32)

    assert {:error, %Errors{} = error} = verify(charge, unrelated_hash)
    assert String.ends_with?(error.type, "verification-failed")
    assert error.detail =~ "not observed"

    assert {:ok, %Receipt{}} = verify(charge, @success_hash)
  end

  test "pins live REFUNDED recovery: terminal hash is consumed and quote retired" do
    start_supervised!(ConCacheStore.child_spec(name: @refund_store))
    charge = refunded_charge()

    assert {:error, %Errors{} = refunded} = verify(charge, @refund_hash)
    assert String.ends_with?(refunded.type, "settlement-failed")
    assert refunded.detail =~ "AMOUNT_LESS_THAN_MIN_AMOUNT_OUT"
    assert refunded.detail =~ "refunded to refundTo"

    assert {:error, %Errors{} = replay} = verify(charge, @refund_hash)
    assert String.ends_with?(replay.type, "invalid-challenge")
    assert replay.detail =~ "already been settled"

    fresh_quote = %{charge | recipient: "bc1q8szwz5hyfcw7y6klw5wz8q2ezlq9qy6d9jke92"}
    assert {:error, %Errors{} = consumed} = verify(fresh_quote, @refund_hash)
    assert String.ends_with?(consumed.type, "verification-failed")
    assert consumed.detail =~ "already been consumed"

    fresh_hash = String.duplicate("cd", 32)
    assert {:error, %Errors{} = retired} = verify(charge, fresh_hash)
    assert String.ends_with?(retired.type, "invalid-challenge")
    assert retired.detail =~ "already been settled"
  end

  defp success_charge(rpc_url) do
    config =
      %{
        "origin_network" => @origin_network,
        "destination_network" => @destination_network,
        "destination_asset" => @destination_asset,
        "destination_recipient" => @destination_recipient,
        "amount_out" => "24452693201",
        "min_amount_in" => @success_amount,
        "refund_to" => @refund_to,
        "store" => false
      }
      |> base_config()
      |> maybe_put("origin_rpc_url", rpc_url)

    {:ok, charge} =
      Charge.new(
        amount: @success_amount,
        currency: @origin_asset,
        recipient: @success_deposit,
        external_id: "near-intents-live-success"
      )

    %{charge | method_details: config}
  end

  defp refunded_charge do
    solana_network = "solana:4sGjMW1sUnHzSxGspuhpqLDx6wiyjNtZ"

    config =
      base_config(%{
        "origin_network" => @bitcoin_network,
        "destination_network" => solana_network,
        "destination_asset" => solana_network <> "/slip44:501",
        "destination_recipient" => "Cw2tJQ9uJ5uub2Jps8M64wwXPApYqzWJ8MGx4Pp9eHXd",
        "amount_out" => "1",
        "min_amount_in" => "1",
        "refund_to" => "bc1q9gh3r2kcyn46wuk3mpx74l76lckkd0m25py9vl",
        "store" => {ConCacheStore, name: @refund_store}
      })

    {:ok, charge} =
      Charge.new(
        amount: "150347",
        currency: @bitcoin_network <> "/slip44:0",
        recipient: @refund_deposit,
        external_id: "near-intents-live-refund"
      )

    %{charge | method_details: config}
  end

  defp base_config(specific) do
    Map.merge(
      %{
        "challenge_id" => "near-intents-live-79",
        "quote_deadline" => "2099-01-01T00:00:00Z",
        "poll_timeout_ms" => 15_000,
        "poll_interval_ms" => 250,
        "one_click_jwt" => System.get_env("NEAR_INTENTS_ONE_CLICK_JWT")
      },
      specific
    )
  end

  defp verify(charge, hash) do
    NearIntents.verify(%{"type" => "hash", "hash" => hash}, charge)
  end

  defp positive_integer_string?(value) do
    case Integer.parse(value || "") do
      {integer, ""} when integer > 0 -> true
      _ -> false
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
