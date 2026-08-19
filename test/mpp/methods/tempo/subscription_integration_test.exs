defmodule MPP.Methods.Tempo.SubscriptionIntegrationTest do
  @moduledoc """
  Live Tempo subscription activation checks against Moderato.

  Run with:

      mix test.json --include integration test/mpp/methods/tempo/subscription_integration_test.exs
  """

  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Methods.Tempo.Subscription
  alias MPP.Receipt
  alias MPP.Subscription.ETSStore
  alias MPP.Subscription.Store
  alias MPP.Test.SubscriptionHelpers
  alias Onchain.Signer
  alias Onchain.Tempo.Faucet

  @moduletag :integration

  @default_rpc_url "https://rpc.moderato.tempo.xyz"
  @chain_id 42_431
  @path_usd "0x20c0000000000000000000000000000000000000"
  @subscription_amount "1000000"
  @subscription_days 7
  @gas_limit 8_000_000
  @max_fee_per_gas 25_000_000_000
  @recipient_private_key "0x1111111111111111111111111111111111111111111111111111111111111111"
  @moderato_blocked_recipient "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

  test "activates a root-authorized access key and settles the first period on Moderato" do
    access_key_private_key = access_key_private_key!()
    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    payer = fresh_wallet!(rpc_url)
    sponsor = fresh_wallet!(rpc_url)
    {:ok, recipient} = Signer.address_from_key(@recipient_private_key)
    {store, config} = subscription_config(access_key_private_key, rpc_url, sponsor)
    subscription = subscription(config, recipient)
    signature = signed_authorization(subscription, payer, access_key_private_key)

    assert {:ok, %Receipt{} = receipt} =
             Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

    assert receipt.method == "tempo"
    assert receipt.reference =~ ~r/^0x[0-9a-f]{64}$/
    assert is_binary(receipt.subscription_id)
    assert {:ok, record} = Store.get(store, receipt.subscription_id)
    assert record.source == String.downcase(payer.address_hex)
    assert record.reference == receipt.reference
    assert DateTime.compare(record.billing_anchor, DateTime.utc_now()) in [:lt, :eq]
  end

  test "rejects a confirmed activation whose transfer is redirected away from the recipient" do
    access_key_private_key = access_key_private_key!()
    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    payer = fresh_wallet!(rpc_url)
    sponsor = fresh_wallet!(rpc_url)
    {_store, config} = subscription_config(access_key_private_key, rpc_url, sponsor)
    subscription = subscription(config, @moderato_blocked_recipient)
    signature = signed_authorization(subscription, payer, access_key_private_key)

    payload = %{"type" => "keyAuthorization", "signature" => signature}

    assert {:error, %Errors{} = error} = Subscription.verify(payload, subscription)
    assert error.detail == "subscription transfer was not credited to the recipient"

    assert {:error, %Errors{detail: "subscription activation credential already used"}} =
             Subscription.verify(payload, subscription)
  end

  test "retries activation on Moderato after a forced reverted first-period settlement" do
    access_key_private_key = access_key_private_key!()
    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    payer = fresh_wallet!(rpc_url)
    sponsor = fresh_wallet!(rpc_url)
    {:ok, recipient} = Signer.address_from_key(@recipient_private_key)
    {_store, config} = subscription_config(access_key_private_key, rpc_url, sponsor)
    subscription = subscription(config, recipient)
    signature = signed_authorization(subscription, payer, access_key_private_key)
    payload = %{"type" => "keyAuthorization", "signature" => signature}

    forced = %{subscription | method_details: force_first_broadcast_revert(config, rpc_url)}

    assert {:error, %Errors{detail: "subscription transaction reverted"}} =
             Subscription.verify(payload, forced)

    assert {:ok, %Receipt{} = receipt} = Subscription.verify(payload, subscription)
    assert receipt.method == "tempo"
    assert receipt.reference =~ ~r/^0x[0-9a-f]{64}$/
  end

  defp access_key_private_key! do
    case System.get_env("TEMPO_SUBSCRIPTION_ACCESS_KEY_PRIVATE_KEY") do
      value when is_binary(value) and value != "" ->
        case Signer.address_from_key(value) do
          {:ok, _address} -> value
          {:error, reason} -> flunk("Invalid TEMPO_SUBSCRIPTION_ACCESS_KEY_PRIVATE_KEY: #{inspect(reason)}")
        end

      _missing ->
        flunk("""
        Missing Tempo subscription access-key credential!

        Generate a testnet-only key and export it before running this test:
          export TEMPO_SUBSCRIPTION_ACCESS_KEY_PRIVATE_KEY="$(openssl rand -hex 32)"

        Optional Moderato RPC override:
          export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"

        Tempo testnet connection details:
          https://docs.tempo.xyz/quickstart/connection-details#testnet
        """)
    end
  end

  defp fresh_wallet!(rpc_url) do
    case Faucet.fresh_funded_wallet(rpc_url: rpc_url) do
      {:ok, wallet} ->
        wallet

      {:error, reason} ->
        flunk("""
        Tempo Moderato failed to fund a fresh subscription payer.

        Error: #{reason}
        RPC URL: #{rpc_url}

        Override the endpoint with:
          export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"

        Tempo testnet connection details:
          https://docs.tempo.xyz/quickstart/connection-details#testnet
        """)
    end
  end

  defp subscription_config(access_key_private_key, rpc_url, sponsor) do
    store_name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!(ETSStore.child_spec(name: store_name))
    store = {ETSStore, [name: store_name]}

    config = %{
      "rpc_url" => rpc_url,
      "chain_id" => @chain_id,
      "subscription_access_key_private_key" => access_key_private_key,
      "subscription_gas_limit" => @gas_limit,
      "fee_token" => @path_usd,
      "fee_payer" => true,
      "fee_payer_private_key" => sponsor.private_key,
      "fee_payer_allowed_fee_tokens" => [@path_usd],
      "fee_payer_policy" => %{
        "max_gas" => @gas_limit,
        "max_total_fee" => @gas_limit * @max_fee_per_gas,
        "max_validity_window_seconds" => 20
      },
      "subscription_store" => store,
      "challenge_id" => "integration-#{System.unique_integer([:positive])}"
    }

    {store, config}
  end

  defp subscription(config, recipient) do
    SubscriptionHelpers.subscription(
      amount: @subscription_amount,
      currency: @path_usd,
      recipient: recipient,
      subscription_expires:
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.shift(day: @subscription_days)
        |> DateTime.to_iso8601(),
      method_details: config
    )
  end

  defp force_first_broadcast_revert(config, rpc_url) do
    {:ok, reverted?} = Agent.start_link(fn -> false end)

    Map.put(config, "req_options",
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        if request["method"] == "eth_sendRawTransactionSync" and Agent.get_and_update(reverted?, &{!&1, true}) do
          json_rpc(conn, request["id"], %{
            "transactionHash" => "0x" <> String.duplicate("11", 32),
            "status" => "0x0",
            "logs" => []
          })
        else
          forward_rpc(conn, request, rpc_url)
        end
      end
    )
  end

  defp forward_rpc(conn, request, rpc_url) do
    case Req.post(rpc_url, json: request) do
      {:ok, %Req.Response{status: status, body: body}} ->
        encoded = if is_binary(body), do: body, else: Jason.encode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, encoded)

      {:error, exception} ->
        flunk("Tempo Moderato RPC forward failed: #{Exception.message(exception)}")
    end
  end

  defp json_rpc(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp signed_authorization(subscription, payer, access_key_private_key) do
    {:ok, access_key_address} = Signer.address_from_key(access_key_private_key)

    {signature, _authorization, _rpc} =
      SubscriptionHelpers.signed_authorization(subscription,
        root_private_key: payer.private_key,
        access_key: access_key_address
      )

    signature
  end
end
