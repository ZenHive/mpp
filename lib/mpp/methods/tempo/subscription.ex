defmodule MPP.Methods.Tempo.Subscription do
  @moduledoc """
  Tempo recurring-subscription activation and renewal.

  Activation verifies the root-signed key authorization, provisions the
  server-held access key, and settles the first period atomically in one Tempo
  transaction. A reverted first-period transfer releases the activation
  credential so the client can retry; an ambiguous broadcast or a confirmed
  transfer that missed the recipient keeps the claim held. Later `renew/2`
  calls reuse that access key within the exact periodic token and recipient
  scope persisted at activation, with the same settlement policy: a confirmed
  revert releases the in-flight period claim, while an ambiguous broadcast or
  a confirmed transfer that missed the recipient keeps the period claimed.
  """

  alias MPP.Errors
  alias MPP.Intents.Subscription
  alias MPP.Methods.Shared
  alias MPP.Methods.Tempo.KeyAuthorization
  alias MPP.Methods.Tempo.SubscriptionTransaction
  alias MPP.Receipt
  alias MPP.Subscription.Record
  alias MPP.Subscription.Store
  alias MPP.Tempo.Store, as: TempoStore
  alias Onchain.Address
  alias Onchain.RPC
  alias Onchain.Signer
  alias Onchain.Tempo.RPC, as: TempoRPC
  alias Onchain.Tempo.Transfer

  require Logger

  @subscription_id_bytes 18
  @renewal_in_flight_error "subscription renewal is already in flight"
  @activation_already_used "subscription activation credential already used"
  @activation_store_unavailable "subscription activation store unavailable"
  @activation_store_cannot_release "subscription activation store cannot release claims; " <>
                                     "configure a Tempo store that implements update/3"

  @doc "Validate Tempo subscription-only method configuration."
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    validate_required_config!(config)
    validate_fee_payer_config!(config)
    validate_rpc_url!(config)
    validate_chain_id!(config)
    validate_store!(config)
    validate_access_key!(config)
  end

  defp validate_required_config!(config) do
    required = ~w(rpc_url chain_id subscription_access_key_private_key)
    missing = Enum.filter(required, &is_nil(config[&1]))

    if missing != [] do
      raise ArgumentError,
            "MPP.Methods.Tempo subscription requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end
  end

  defp validate_fee_payer_config!(config) do
    if is_binary(config["fee_payer_url"]) do
      raise ArgumentError,
            "MPP.Methods.Tempo subscription supports local fee sponsorship; fee_payer_url is not supported"
    end
  end

  defp validate_rpc_url!(config) do
    if !is_binary(config["rpc_url"]) or config["rpc_url"] == "" do
      raise ArgumentError, "MPP.Methods.Tempo subscription rpc_url must be a non-empty string"
    end
  end

  defp validate_chain_id!(config) do
    if !is_integer(config["chain_id"]) or config["chain_id"] <= 0 do
      raise ArgumentError, "MPP.Methods.Tempo subscription chain_id must be a positive integer"
    end
  end

  defp validate_store!(config) do
    store = store(config)

    if !Enum.all?([:get, :put, :update, :delete], &store_callback?(store, &1)) do
      raise ArgumentError,
            "MPP.Methods.Tempo subscription_store must implement MPP.Subscription.Store"
    end
  end

  defp validate_access_key!(config) do
    case access_key(config) do
      {:ok, _address} -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Return the public Tempo subscription challenge fields."
  @spec challenge_method_details(Subscription.t()) :: map()
  def challenge_method_details(%Subscription{} = subscription) do
    config = subscription.method_details || %{}
    {:ok, access_key} = access_key(config)

    case KeyAuthorization.wallet_params(subscription,
           access_key: access_key,
           key_type: :secp256k1
         ) do
      {:ok, _params} -> :ok
      {:error, reason} -> raise ArgumentError, "invalid Tempo subscription request: #{reason}"
    end

    %{
      "accessKey" => %{"accessKeyAddress" => access_key, "keyType" => "secp256k1"},
      "chainId" => config["chain_id"],
      "feePayer" => config["fee_payer"] == true
    }
  end

  @doc "Verify a subscription credential and atomically activate its first charge."
  @spec verify(map(), Subscription.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "keyAuthorization", "signature" => signature}, %Subscription{} = subscription)
      when is_binary(signature) do
    config = subscription.method_details || %{}

    result =
      with {:ok, access_key} <- access_key(config),
           {:ok, authorization} <- KeyAuthorization.deserialize(signature),
           :ok <-
             KeyAuthorization.verify(authorization, subscription,
               chain_id: config["chain_id"],
               access_key: access_key,
               key_type: :secp256k1,
               challenge_expires: config["challenge_expires"],
               source: config["credential_source"]
             ) do
        activate(subscription, authorization, signature, config)
      end

    normalize_result(result)
  end

  def verify(_payload, %Subscription{}) do
    {:error, Errors.new(:invalid_payload, ~s(expected type="keyAuthorization" with a signature))}
  end

  @doc "After application-level authentication, return the current receipt and renew an overdue period."
  @spec authorize(String.t(), map()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def authorize(subscription_id, config) when is_binary(subscription_id) and is_map(config) do
    case Store.get(store(config), subscription_id) do
      {:ok, record} -> authorize_record(record, config)
      :not_found -> {:error, Errors.new(:verification_failed, "subscription not found")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, "subscription store unavailable")}
    end
  end

  @doc "Charge the current overdue billing period for a persisted subscription."
  @spec renew(String.t(), map()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def renew(subscription_id, config) when is_binary(subscription_id) and is_map(config) do
    subscription_store = store(config)

    with {:ok, record} <- fetch_record(subscription_store, subscription_id),
         {:ok, period_index} <- due_period(record),
         {:ok, claimed} <- claim_renewal(subscription_store, record, period_index),
         {:ok, receipt} <- complete_renewal(subscription_store, claimed, period_index, config) do
      {:ok, receipt}
    else
      {:error, :already_current, record} -> {:ok, receipt(record)}
      {:error, :renewal_in_flight} -> {:error, Errors.new(:verification_failed, @renewal_in_flight_error)}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, reason} -> {:error, Errors.new(:verification_failed, error_message(reason))}
    end
  end

  defp activate(subscription, authorization, serialized_authorization, config) do
    settlement_reference = config["challenge_id"]

    with {:ok, tx, memo} <-
           SubscriptionTransaction.build(subscription, authorization, authorization.source, config, settlement_reference),
         :ok <- simulate_sponsored(tx, authorization.source, config),
         :ok <- claim_activation(config, serialized_authorization) do
      finalize_activation(
        settle_activation(subscription, authorization, serialized_authorization, config, tx, memo),
        config,
        serialized_authorization
      )
    end
  end

  defp settle_activation(subscription, authorization, serialized_authorization, config, tx, memo) do
    case broadcast(tx.raw, config) do
      {:ok, tx_hash, chain_receipt} ->
        confirm_activation(subscription, authorization, serialized_authorization, config, tx_hash, chain_receipt, memo)

      # The node may have included the tx; keep the claim to prevent double settlement.
      {:error, reason} ->
        {:error, {:held, reason}}
    end
  end

  defp confirm_activation(subscription, authorization, serialized_authorization, config, tx_hash, chain_receipt, memo) do
    with :ok <- require_success(chain_receipt),
         :ok <- require_transfer(chain_receipt, subscription, memo),
         {:ok, settled_at} <- settlement_time(tx_hash, config),
         :ok <- require_before_expiry(settled_at, subscription.subscription_expires),
         {:ok, access_key} <- access_key(config),
         record =
           record(subscription, authorization, serialized_authorization, access_key, tx_hash, settled_at),
         :ok <- Store.put(store(config), record) do
      {:ok, receipt(record)}
    else
      {:error, "subscription transaction reverted" = reason} -> {:error, {:retryable, reason}}
      {:error, reason} -> {:error, {:held, reason}}
    end
  end

  defp finalize_activation({:ok, _receipt} = ok, _config, _signature), do: ok

  defp finalize_activation({:error, {:retryable, reason}}, config, signature) do
    case release_activation(config, signature) do
      :ok -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  defp finalize_activation({:error, {:held, reason}}, _config, _signature), do: {:error, reason}

  defp authorize_record(record, config) do
    case due_period(record) do
      {:ok, _period} -> renew(record.subscription_id, config)
      {:error, :already_current, record} -> {:ok, receipt(record)}
      {:error, reason} -> {:error, Errors.new(:verification_failed, error_message(reason))}
    end
  end

  defp complete_renewal(subscription_store, claimed, period_index, config) do
    case settle_renewal(claimed, period_index, config) do
      {:ok, receipt, updated} ->
        with {:ok, _record} <- finalize_renewal(subscription_store, updated, period_index) do
          {:ok, receipt}
        end

      {:error, {:retryable, reason}} ->
        _ = release_renewal(subscription_store, claimed.subscription_id, period_index)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_renewal(record, period_index, config) do
    reference = "renewal:#{record.subscription_id}:#{period_index}"
    subscription = record.subscription
    source = record.method_state.source

    with {:ok, tx, memo} <- SubscriptionTransaction.build(subscription, nil, source, config, reference),
         :ok <- simulate_sponsored(tx, source, config) do
      case broadcast(tx.raw, config) do
        {:ok, tx_hash, chain_receipt} ->
          confirm_renewal(record, period_index, tx_hash, chain_receipt, subscription, memo, config)

        # The node may have included the tx; keep the claim to prevent double settlement.
        {:error, _reason} = error ->
          error
      end
    else
      {:error, reason} -> {:error, {:retryable, reason}}
    end
  end

  defp confirm_renewal(record, period_index, tx_hash, chain_receipt, subscription, memo, config) do
    with :ok <- require_success(chain_receipt),
         :ok <- require_transfer(chain_receipt, subscription, memo),
         {:ok, settled_at} <- settlement_time(tx_hash, config),
         :ok <- require_before_expiry(settled_at, subscription.subscription_expires) do
      timestamp = DateTime.to_iso8601(settled_at)

      updated = %{
        record
        | reference: tx_hash,
          timestamp: timestamp,
          last_charged_period: period_index,
          payments: Map.put(record.payments, period_index, payment(period_index, tx_hash, timestamp))
      }

      {:ok, receipt(updated), updated}
    else
      {:error, "subscription transaction reverted" = reason} -> {:error, {:retryable, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_renewal(subscription_store, record, period_index) do
    in_flight_reference = "renewal:#{record.subscription_id}:#{period_index}"

    subscription_store
    |> Store.update(record.subscription_id, fn
      %Record{last_charged_period: last, in_flight_period: nil} = current when last < period_index ->
        {:ok,
         %{
           current
           | in_flight_period: period_index,
             in_flight_reference: in_flight_reference
         }}

      %Record{last_charged_period: last} = current when last >= period_index ->
        {:error, {:already_current, current}}

      %Record{} ->
        {:error, :renewal_in_flight}

      :not_found ->
        {:error, :subscription_not_found}
    end)
    |> case do
      {:ok, claimed} -> {:ok, claimed}
      {:error, {:already_current, current}} -> {:error, :already_current, current}
      other -> other
    end
  end

  defp finalize_renewal(subscription_store, updated, period_index) do
    Store.update(subscription_store, updated.subscription_id, fn
      %Record{in_flight_period: ^period_index} ->
        {:ok, %{updated | in_flight_period: nil, in_flight_reference: nil}}

      %Record{} ->
        {:error, :renewal_claim_mismatch}

      :not_found ->
        {:error, :subscription_not_found}
    end)
  end

  defp release_renewal(subscription_store, subscription_id, period_index) do
    Store.update(subscription_store, subscription_id, fn
      %Record{in_flight_period: ^period_index} = current ->
        {:ok, %{current | in_flight_period: nil, in_flight_reference: nil}}

      %Record{} = current ->
        {:ok, current}

      :not_found ->
        {:error, :subscription_not_found}
    end)
  end

  defp claim_activation(config, signature) do
    case TempoStore.resolve(config["store"]) do
      nil ->
        :ok

      store ->
        key = activation_dedup_key(config, signature)

        case TempoStore.check_and_mark(store, key, System.system_time(:millisecond)) do
          :ok -> :ok
          {:error, :already_exists} -> {:error, @activation_already_used}
          {:error, _reason} -> {:error, @activation_store_unavailable}
        end
    end
  end

  defp release_activation(config, signature) do
    case TempoStore.resolve(config["store"]) do
      nil -> :ok
      store -> release_activation_store(store, config, signature)
    end
  end

  defp release_activation_store(store, config, signature) do
    if TempoStore.update_capable?(store) do
      case TempoStore.update(store, activation_dedup_key(config, signature), &release_activation_value/1) do
        {:ok, :ok} -> :ok
        {:error, _reason} -> {:error, @activation_store_unavailable}
      end
    else
      {:error, @activation_store_cannot_release}
    end
  end

  defp release_activation_value(_value), do: {:delete, :ok}

  defp activation_dedup_key(config, signature), do: "mpp:subscription:" <> activation_key(config, signature)

  defp activation_key(%{"challenge_id" => id}, _signature) when is_binary(id) and id != "", do: id

  defp activation_key(_config, signature) when is_binary(signature) do
    Base.encode16(:crypto.hash(:sha256, signature), case: :lower)
  end

  defp due_period(%Record{} = record) do
    now = DateTime.utc_now()

    with {:ok, expires, _offset} <- DateTime.from_iso8601(record.subscription.subscription_expires),
         :lt <- DateTime.compare(now, expires),
         {:ok, period_seconds} <- KeyAuthorization.period_seconds(record.subscription) do
      period = max(0, div(DateTime.diff(now, record.billing_anchor, :second), period_seconds))

      if period > record.last_charged_period,
        do: {:ok, period},
        else: {:error, :already_current, record}
    else
      _ -> {:error, :subscription_expired}
    end
  end

  defp record(subscription, authorization, serialized, access_key, tx_hash, settled_at) do
    timestamp = DateTime.to_iso8601(settled_at)

    %Record{
      subscription_id: subscription_id(),
      method: "tempo",
      subscription: %{subscription | method_details: public_method_details(subscription.method_details)},
      method_state: %{
        source: authorization.source,
        access_key: access_key,
        access_key_type: :secp256k1,
        key_authorization: serialized
      },
      billing_anchor: settled_at,
      last_charged_period: 0,
      payments: %{0 => payment(0, tx_hash, timestamp)},
      reference: tx_hash,
      timestamp: timestamp
    }
  end

  defp payment(period, reference, timestamp) do
    %{period: period, reference: reference, timestamp: timestamp, event_ids: []}
  end

  defp public_method_details(details) do
    Map.take(details || %{}, ["chainId", "chain_id", "accessKey"])
  end

  defp receipt(%Record{} = record) do
    Receipt.new(
      method: "tempo",
      reference: record.reference,
      external_id: record.subscription.external_id,
      subscription_id: record.subscription_id,
      timestamp: record.timestamp
    )
  end

  defp broadcast(raw, config) do
    with {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Tempo") do
      TempoRPC.broadcast_sync(raw, rpc_url, req_options(config))
    end
  end

  defp simulate_sponsored(_tx, _source, %{"fee_payer" => value}) when value != true, do: :ok
  defp simulate_sponsored(_tx, _source, config) when not is_map_key(config, "fee_payer"), do: :ok

  defp simulate_sponsored(tx, source, config) do
    rpc_url = config["rpc_url"]
    [call] = tx.calls
    fields = tx.fields

    request = %{
      "from" => source,
      "to" => hex(call.to),
      "value" => hex_quantity(call.value),
      "input" => hex(call.input),
      "gas" => field_quantity(fields, 3),
      "nonce" => field_quantity(fields, 7),
      "maxFeePerGas" => field_quantity(fields, 2),
      "maxPriorityFeePerGas" => field_quantity(fields, 1),
      "chainId" => field_quantity(fields, 0),
      "type" => "0x76",
      "feeToken" => hex(Enum.at(fields, 10))
    }

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "eth_simulateV1",
      "params" => [
        %{
          "blockStateCalls" => [%{"calls" => [request]}],
          "traceTransfers" => false,
          "validation" => false,
          "returnFullTransactions" => false
        }
      ]
    }

    case Req.post(rpc_url, Keyword.merge([json: payload], config["req_options"] || [])) do
      {:ok, %{body: %{"result" => [%{"calls" => [%{"status" => "0x1"} | _]} | _]}}} ->
        :ok

      {:ok, %{body: %{"error" => %{"code" => -32_601}}}} ->
        Logger.warning("Tempo node does not implement eth_simulateV1; subscription sponsorship simulation unavailable")
        :ok

      {:ok, %{body: %{"error" => error}}} ->
        {:error, "subscription sponsorship simulation rejected: #{inspect(error)}"}

      {:ok, _response} ->
        {:error, "subscription sponsorship simulation failed"}

      {:error, _reason} ->
        {:error, "subscription sponsorship simulation failed"}
    end
  end

  defp require_success(%{status: 1}), do: :ok
  defp require_success(_receipt), do: {:error, "subscription transaction reverted"}

  defp require_transfer(%{logs: logs}, subscription, memo) do
    matched? =
      logs
      |> Transfer.parse_transfer_with_memo_logs()
      |> Enum.any?(fn transfer ->
        Address.equal?(transfer.token, subscription.currency) and
          Address.equal?(transfer.to, subscription.recipient) and
          transfer.amount == String.to_integer(subscription.amount) and
          String.downcase(transfer.memo) == String.downcase(memo)
      end)

    if matched?,
      do: :ok,
      else: {:error, "subscription transfer was not credited to the recipient"}
  end

  defp settlement_time(tx_hash, config) do
    opts = [rpc_url: config["rpc_url"], req_options: config["req_options"] || []]

    with {:ok, %{block_number: block_number}} <- RPC.get_transaction_receipt(tx_hash, opts),
         {:ok, %{timestamp: timestamp}} <- RPC.get_block_by_number(block_number, opts),
         {:ok, datetime} <- DateTime.from_unix(timestamp) do
      {:ok, datetime}
    else
      _ -> {:error, "subscription settlement block timestamp unavailable"}
    end
  end

  defp require_before_expiry(settled_at, expires) do
    with {:ok, expiry, _offset} <- DateTime.from_iso8601(expires),
         :lt <- DateTime.compare(settled_at, expiry) do
      :ok
    else
      _ -> {:error, "subscription activation settled at or after subscriptionExpires"}
    end
  end

  defp fetch_record(subscription_store, id) do
    case Store.get(subscription_store, id) do
      {:ok, record} -> {:ok, record}
      :not_found -> {:error, :subscription_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp access_key(config) do
    case Signer.address_from_key(config["subscription_access_key_private_key"]) do
      {:ok, address} -> {:ok, String.downcase(address)}
      {:error, _reason} -> {:error, "invalid subscription_access_key_private_key"}
    end
  end

  defp store(config), do: config["subscription_store"] || Store.default_store()

  defp store_callback?({module, _opts}, callback), do: function_exported?(module, callback, callback_arity(callback) + 1)
  defp store_callback?(module, callback), do: function_exported?(module, callback, callback_arity(callback))
  defp callback_arity(:get), do: 1
  defp callback_arity(:put), do: 1
  defp callback_arity(:update), do: 2
  defp callback_arity(:delete), do: 1

  defp subscription_id, do: @subscription_id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp req_options(config), do: [req_options: config["req_options"] || []]
  defp field_quantity(fields, index), do: fields |> Enum.at(index) |> :binary.decode_unsigned() |> hex_quantity()
  defp hex_quantity(0), do: "0x0"
  defp hex_quantity(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))
  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)

  defp normalize_result({:ok, %Receipt{}} = result), do: result
  defp normalize_result({:error, %Errors{}} = error), do: error
  defp normalize_result({:error, reason}), do: {:error, Errors.new(:verification_failed, error_message(reason))}

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(:subscription_not_found), do: "subscription not found"
  defp error_message(:subscription_expired), do: "subscription expired"
  defp error_message(reason), do: "subscription operation failed: #{inspect(reason)}"
end
