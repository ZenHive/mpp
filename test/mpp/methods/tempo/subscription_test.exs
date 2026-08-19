defmodule MPP.Methods.Tempo.SubscriptionTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Methods.Tempo.Subscription
  alias MPP.Receipt
  alias MPP.Subscription.ETSStore
  alias MPP.Subscription.Record
  alias MPP.Subscription.Store
  alias MPP.Test.SubscriptionHelpers
  alias Onchain.Tempo.Transaction

  @rpc_url "https://moderato.invalid"
  @tx_hash "0x" <> String.duplicate("44", 32)
  @block_number "0x10"
  @subscription_amount 1_000_000
  @subscription_duration_days 30
  @subscription_id_encoded_bytes 24
  @activation_field_count 15
  @renewal_field_count 14
  @gas_limit 1_000_000
  @max_total_fee 30_000_000_000_000_000

  defmodule InvalidStore do
    @moduledoc false
  end

  defmodule FailingStore do
    @moduledoc false

    def get(_id), do: {:error, :unavailable}
    def put(_record), do: {:error, :unavailable}
    def update(_id, _fun), do: {:error, :unavailable}
    def delete(_id), do: {:error, :unavailable}
  end

  defmodule FailingDedupStore do
    @moduledoc false

    def check_and_mark(_key, _value), do: {:error, :unavailable}
  end

  setup do
    store_name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!(ETSStore.child_spec(name: store_name))
    {:ok, store: {ETSStore, [name: store_name]}}
  end

  describe "configuration" do
    test "requires the subscription RPC, chain, access key, and atomic store", %{store: store} do
      valid = config(store)
      assert :ok = Subscription.validate_config!(valid)

      for key <- ~w(rpc_url chain_id subscription_access_key_private_key) do
        assert_raise ArgumentError, ~r/#{key}/, fn ->
          valid |> Map.delete(key) |> Subscription.validate_config!()
        end
      end

      assert_raise ArgumentError, ~r/subscription_store must implement/, fn ->
        valid |> Map.put("subscription_store", InvalidStore) |> Subscription.validate_config!()
      end

      assert_raise ArgumentError, ~r/fee_payer_url is not supported/, fn ->
        valid |> Map.put("fee_payer_url", "https://sponsor.invalid") |> Subscription.validate_config!()
      end

      assert_raise ArgumentError, ~r/invalid subscription_access_key_private_key/, fn ->
        valid |> Map.put("subscription_access_key_private_key", "invalid") |> Subscription.validate_config!()
      end

      for {key, value, message} <- [
            {"rpc_url", "", ~r/rpc_url must be a non-empty string/},
            {"chain_id", 0, ~r/chain_id must be a positive integer/}
          ] do
        assert_raise ArgumentError, message, fn ->
          valid |> Map.put(key, value) |> Subscription.validate_config!()
        end
      end
    end

    test "advertises the exact access key and rejects non-Tempo periods", %{store: store} do
      config = config(store)
      subscription = subscription(config)

      assert %{
               "accessKey" => %{
                 "accessKeyAddress" => access_key,
                 "keyType" => "secp256k1"
               },
               "chainId" => 42_431,
               "feePayer" => false
             } = Subscription.challenge_method_details(subscription)

      assert access_key == String.downcase(SubscriptionHelpers.access_address())

      assert_raise ArgumentError, ~r/periodUnit day or week/, fn ->
        subscription
        |> Map.put(:period_unit, :month)
        |> Subscription.challenge_method_details()
      end
    end
  end

  describe "activation and recurring authorization" do
    test "activates, persists, and authorizes a current subscription", %{store: store} do
      stub_successful_chain()
      config = store |> config() |> Map.put("fee_payer", false)
      subscription = subscription(config)
      {signature, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:ok, %Receipt{} = receipt} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert receipt.method == "tempo"
      assert receipt.reference == @tx_hash
      assert is_binary(receipt.subscription_id)
      assert byte_size(receipt.subscription_id) == @subscription_id_encoded_bytes

      assert {:ok, %Record{} = record} = Store.get(store, receipt.subscription_id)
      assert record.source == authorization.source
      assert record.access_key == String.downcase(SubscriptionHelpers.access_address())
      assert record.last_charged_period == 0
      assert record.reference == @tx_hash
      assert record.subscription.method_details == %{"chain_id" => 42_431}
      refute Map.has_key?(record.subscription.method_details, "subscription_access_key_private_key")

      assert_received {:rpc, "eth_sendRawTransactionSync", [raw]}
      assert {:ok, %Transaction{fields: fields}} = Transaction.deserialize(raw)
      assert length(fields) == @activation_field_count

      assert {:ok, current} = Subscription.authorize(receipt.subscription_id, config)
      assert current.reference == receipt.reference
      refute_receive {:rpc, "eth_sendRawTransactionSync", _params}
    end

    test "renews an overdue period once and clears the atomic claim", %{store: store} do
      stub_successful_chain()
      config = config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:ok, activation} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert {:ok, _record} =
               Store.update(store, activation.subscription_id, fn record ->
                 {:ok, %{record | billing_anchor: DateTime.shift(record.billing_anchor, day: -2)}}
               end)

      assert {:ok, renewal} = Subscription.authorize(activation.subscription_id, config)
      assert renewal.subscription_id == activation.subscription_id
      assert renewal.reference == @tx_hash

      assert {:ok, renewed} = Store.get(store, activation.subscription_id)
      assert renewed.last_charged_period == 2
      assert renewed.in_flight_period == nil
      assert renewed.in_flight_reference == nil

      assert_received {:rpc, "eth_sendRawTransactionSync", [_activation_raw]}
      assert_received {:rpc, "eth_sendRawTransactionSync", [renewal_raw]}
      assert {:ok, %Transaction{fields: fields}} = Transaction.deserialize(renewal_raw)
      assert length(fields) == @renewal_field_count

      assert {:ok, current} = Subscription.renew(activation.subscription_id, config)
      assert current.reference == renewal.reference
      refute_receive {:rpc, "eth_sendRawTransactionSync", _params}
    end

    test "releases an in-flight renewal after a reverted settlement so a retry can proceed", %{store: store} do
      stub_successful_chain()
      config = config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:ok, activation} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert {:ok, _record} =
               Store.update(store, activation.subscription_id, fn record ->
                 {:ok, %{record | billing_anchor: DateTime.shift(record.billing_anchor, day: -2)}}
               end)

      stub_reverted_chain()

      assert {:error, %Errors{detail: "subscription transaction reverted"}} =
               Subscription.renew(activation.subscription_id, config)

      assert {:ok, held} = Store.get(store, activation.subscription_id)
      assert held.in_flight_period == nil
      assert held.last_charged_period == 0

      stub_successful_chain()
      assert {:ok, renewal} = Subscription.renew(activation.subscription_id, config)
      assert {:ok, renewed} = Store.get(store, activation.subscription_id)
      assert renewed.last_charged_period == 2
      assert renewed.in_flight_period == nil
      assert renewal.reference == @tx_hash
    end

    test "releases an in-flight renewal when sponsorship simulation fails", %{store: store} do
      stub_successful_chain()
      config = sponsored_config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:ok, activation} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert {:ok, _record} =
               Store.update(store, activation.subscription_id, fn record ->
                 {:ok, %{record | billing_anchor: DateTime.shift(record.billing_anchor, day: -2)}}
               end)

      stub_sponsorship_failure(:rejected)

      assert {:error, %Errors{} = error} = Subscription.renew(activation.subscription_id, config)
      assert error.detail =~ "subscription sponsorship simulation rejected"

      assert {:ok, held} = Store.get(store, activation.subscription_id)
      assert held.in_flight_period == nil
      assert held.last_charged_period == 0
    end

    test "keeps the in-flight claim when a confirmed renewal transfer misses the recipient", %{store: store} do
      stub_successful_chain()
      config = config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:ok, activation} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert {:ok, _record} =
               Store.update(store, activation.subscription_id, fn record ->
                 {:ok, %{record | billing_anchor: DateTime.shift(record.billing_anchor, day: -2)}}
               end)

      stub_success_without_transfer()

      assert {:error, %Errors{detail: "subscription transfer was not credited to the recipient"}} =
               Subscription.renew(activation.subscription_id, config)

      assert {:ok, held} = Store.get(store, activation.subscription_id)
      assert held.in_flight_period == 2
      assert held.last_charged_period == 0
    end

    test "rejects a replayed activation credential for the same challenge", %{store: store} do
      stub_successful_chain()
      challenge_id = "replay-#{System.unique_integer([:positive])}"
      config = store |> config() |> Map.put("challenge_id", challenge_id)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
      payload = %{"type" => "keyAuthorization", "signature" => signature}

      assert {:ok, %Receipt{}} = Subscription.verify(payload, subscription)

      assert {:error, %Errors{detail: "subscription activation credential already used"}} =
               Subscription.verify(payload, subscription)
    end

    test "hashes the serialized authorization when challenge_id is absent", %{store: store} do
      stub_successful_chain()
      config = store |> config() |> Map.put("challenge_id", "")
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
      payload = %{"type" => "keyAuthorization", "signature" => signature}

      assert {:ok, %Receipt{}} = Subscription.verify(payload, subscription)

      assert {:error, %Errors{detail: "subscription activation credential already used"}} =
               Subscription.verify(payload, subscription)
    end

    test "opts out of activation replay protection when store is false", %{store: store} do
      stub_successful_chain()
      challenge_id = "opt-out-#{System.unique_integer([:positive])}"
      config = store |> config() |> Map.merge(%{"store" => false, "challenge_id" => challenge_id})
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
      payload = %{"type" => "keyAuthorization", "signature" => signature}

      assert {:ok, %Receipt{}} = Subscription.verify(payload, subscription)
      assert {:ok, %Receipt{}} = Subscription.verify(payload, subscription)
    end

    test "fails closed when the activation dedup store is unavailable", %{store: store} do
      stub_successful_chain()
      config = store |> config() |> Map.put("store", __MODULE__.FailingDedupStore)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:error, %Errors{detail: "subscription activation store unavailable"}} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)
    end

    test "rejects a second renewal while the billing period is in flight", %{store: store} do
      config = config(store)
      subscription = subscription(config)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      record = record(subscription, now)

      assert :ok = Store.put(store, record)

      assert {:error, %Errors{} = error} = Subscription.renew(record.subscription_id, config)
      assert error.detail == "subscription renewal is already in flight"
    end

    test "returns explicit errors for invalid credentials and missing subscriptions", %{store: store} do
      config = config(store)
      subscription = subscription(config)

      assert {:error, %Errors{} = invalid} = Subscription.verify(%{"type" => "hash"}, subscription)
      assert invalid.detail =~ ~s(type="keyAuthorization")

      invalid_key_subscription = subscription(Map.put(config, "subscription_access_key_private_key", "invalid"))

      assert {:error, %Errors{detail: "invalid subscription_access_key_private_key"}} =
               Subscription.verify(
                 %{"type" => "keyAuthorization", "signature" => "0x01"},
                 invalid_key_subscription
               )

      assert {:error, %Errors{} = missing} = Subscription.authorize("missing", config)
      assert missing.detail == "subscription not found"

      assert {:error, %Errors{} = renewal_missing} = Subscription.renew("missing", config)
      assert renewal_missing.detail == "subscription not found"

      unavailable = Map.put(config, "subscription_store", FailingStore)
      assert {:error, %Errors{detail: "subscription store unavailable"}} = Subscription.authorize("sub", unavailable)
      assert {:error, %Errors{detail: detail}} = Subscription.renew("sub", unavailable)
      assert detail =~ "unavailable"
    end

    test "rejects an expired persisted subscription", %{store: store} do
      config = config(store)
      expired = SubscriptionHelpers.subscription(subscription_expires: "2020-01-01T00:00:00Z")
      record = record(expired, DateTime.truncate(DateTime.utc_now(), :second))
      assert :ok = Store.put(store, record)

      assert {:error, %Errors{detail: "subscription expired"}} =
               Subscription.authorize(record.subscription_id, config)
    end
  end

  describe "fee sponsorship and settlement failures" do
    test "simulates and broadcasts a locally fee-payer-signed activation", %{store: store} do
      stub_successful_chain()
      config = sponsored_config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:ok, %Receipt{reference: @tx_hash}} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert_received {:rpc, "eth_simulateV1", [_simulation]}
      assert_received {:rpc, "eth_sendRawTransactionSync", [raw]}
      assert {:ok, tx} = Transaction.deserialize(raw)
      assert [_recovery_id, _r, _s] = Enum.at(tx.fields, 11)
      refute Transaction.has_fee_payer_placeholder?(tx)
    end

    test "does not persist a reverted activation", %{store: store} do
      stub_reverted_chain()
      config = config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      assert {:error, %Errors{} = error} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      assert error.detail == "subscription transaction reverted"
    end

    test "accepts an unsupported simulation method but rejects other sponsor simulation failures", %{store: store} do
      config = sponsored_config(store)
      subscription = subscription(config)
      {signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

      stub_successful_chain(simulation: :unsupported)

      assert {:ok, %Receipt{reference: @tx_hash}} =
               Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

      for {failure, detail} <- [
            {:rejected, "subscription sponsorship simulation rejected"},
            {:malformed, "subscription sponsorship simulation failed"},
            {:transport, "subscription sponsorship simulation failed"}
          ] do
        stub_sponsorship_failure(failure)

        assert {:error, %Errors{} = error} =
                 Subscription.verify(%{"type" => "keyAuthorization", "signature" => signature}, subscription)

        assert error.detail =~ detail
      end
    end

    test "rejects unavailable and post-expiry settlement timestamps", %{store: store} do
      missing_config = config(store)
      missing_subscription = subscription(missing_config)
      {missing_signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(missing_subscription)

      stub_missing_settlement()

      assert {:error, %Errors{detail: "subscription settlement block timestamp unavailable"}} =
               Subscription.verify(
                 %{"type" => "keyAuthorization", "signature" => missing_signature},
                 missing_subscription
               )

      expiry_config = config(store)
      expiry_subscription = subscription(expiry_config)
      {expiry_signature, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(expiry_subscription)
      expiry = expiry_subscription.subscription_expires |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix()
      stub_successful_chain(block_timestamp: expiry)

      assert {:error, %Errors{detail: "subscription activation settled at or after subscriptionExpires"}} =
               Subscription.verify(
                 %{"type" => "keyAuthorization", "signature" => expiry_signature},
                 expiry_subscription
               )
    end
  end

  defp stub_successful_chain(opts \\ []) do
    test_pid = self()
    block_timestamp = Keyword.get(opts, :block_timestamp, System.os_time(:second))
    simulation = Keyword.get(opts, :simulation, :success)

    Req.Test.stub(__MODULE__, fn conn ->
      request = request(conn)
      send(test_pid, {:rpc, request["method"], request["params"]})

      case request do
        %{"method" => "eth_simulateV1"} when simulation == :unsupported ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_601, "message" => "method not found"}
          })

        _request ->
          result = chain_result(request, block_timestamp)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      end
    end)
  end

  defp chain_result(request, block_timestamp) do
    case request do
      %{"method" => "eth_simulateV1"} ->
        [%{"calls" => [%{"status" => "0x1"}]}]

      %{"method" => "eth_sendRawTransactionSync", "params" => [raw]} ->
        successful_receipt(raw)

      %{"method" => "eth_getTransactionReceipt"} ->
        %{"transactionHash" => @tx_hash, "blockNumber" => @block_number, "status" => "0x1", "logs" => []}

      %{"method" => "eth_getBlockByNumber"} ->
        %{"number" => @block_number, "timestamp" => hex_quantity(block_timestamp), "transactions" => []}
    end
  end

  defp stub_sponsorship_failure(failure) do
    Req.Test.stub(__MODULE__, fn conn ->
      request = request(conn)

      case failure do
        :rejected ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -38_013, "message" => "execution rejected"}
          })

        :malformed ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "unexpected" => true})

        :transport ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)
  end

  defp stub_missing_settlement do
    Req.Test.stub(__MODULE__, fn conn ->
      request = request(conn)

      result =
        case request do
          %{"method" => "eth_sendRawTransactionSync", "params" => [raw]} -> successful_receipt(raw)
          %{"method" => "eth_getTransactionReceipt"} -> nil
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
    end)
  end

  defp stub_reverted_chain do
    Req.Test.stub(__MODULE__, fn conn ->
      request = request(conn)

      "eth_sendRawTransactionSync" = request["method"]
      result = %{"transactionHash" => @tx_hash, "status" => "0x0", "logs" => []}
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
    end)
  end

  defp stub_success_without_transfer do
    Req.Test.stub(__MODULE__, fn conn ->
      request = request(conn)

      result =
        case request do
          %{"method" => "eth_sendRawTransactionSync"} ->
            %{
              "transactionHash" => @tx_hash,
              "blockNumber" => @block_number,
              "status" => "0x1",
              "logs" => []
            }

          %{"method" => "eth_getTransactionReceipt"} ->
            %{"transactionHash" => @tx_hash, "blockNumber" => @block_number, "status" => "0x1", "logs" => []}

          %{"method" => "eth_getBlockByNumber"} ->
            %{"number" => @block_number, "timestamp" => hex_quantity(System.os_time(:second)), "transactions" => []}
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
    end)
  end

  defp successful_receipt(raw) do
    memo = SubscriptionHelpers.memo_from_transaction(raw)

    %{
      "transactionHash" => @tx_hash,
      "blockNumber" => @block_number,
      "status" => "0x1",
      "logs" => [
        SubscriptionHelpers.transfer_log(
          SubscriptionHelpers.token(),
          SubscriptionHelpers.root_address(),
          SubscriptionHelpers.recipient(),
          @subscription_amount,
          memo
        )
      ]
    }
  end

  defp request(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp subscription(config) do
    SubscriptionHelpers.subscription(method_details: config, subscription_expires: expiry())
  end

  defp config(store) do
    %{
      "rpc_url" => @rpc_url,
      "chain_id" => SubscriptionHelpers.chain_id(),
      "subscription_access_key_private_key" => SubscriptionHelpers.access_private_key(),
      "subscription_nonce" => 0,
      "subscription_gas_limit" => @gas_limit,
      "fee_token" => SubscriptionHelpers.token(),
      "subscription_store" => store,
      "challenge_id" => "subscription_challenge_#{System.unique_integer([:positive])}",
      "req_options" => [plug: {Req.Test, __MODULE__}]
    }
  end

  defp sponsored_config(store) do
    Map.merge(config(store), %{
      "fee_payer" => true,
      "fee_payer_private_key" => SubscriptionHelpers.fee_payer_private_key(),
      "fee_token" => SubscriptionHelpers.token(),
      "fee_payer_allowed_fee_tokens" => [SubscriptionHelpers.token()],
      "fee_payer_policy" => %{
        "max_gas" => @gas_limit,
        "max_total_fee" => @max_total_fee
      }
    })
  end

  defp record(subscription, now) do
    %Record{
      subscription_id: "sub_in_flight",
      subscription: subscription,
      source: SubscriptionHelpers.root_address(),
      access_key: SubscriptionHelpers.access_address(),
      access_key_type: :secp256k1,
      key_authorization: "0x01",
      billing_anchor: DateTime.shift(now, day: -2),
      last_charged_period: 0,
      reference: @tx_hash,
      timestamp: DateTime.to_iso8601(now),
      in_flight_period: 1,
      in_flight_reference: "renewal:sub_in_flight:1"
    }
  end

  defp expiry do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.shift(day: @subscription_duration_days)
    |> DateTime.to_iso8601()
  end

  defp hex_quantity(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))
end
