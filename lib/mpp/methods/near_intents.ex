defmodule MPP.Methods.NearIntents do
  @moduledoc """
  NEAR Intents charge method backed by the 1Click Swap API.

  The method accepts only `type="hash"` credentials. It verifies an origin
  deposit, waits for 1Click to reach a terminal settlement state, and returns
  a receipt only after the merchant's destination delivery reaches `SUCCESS`.

  `quote/1` requests the executable `EXACT_OUTPUT` quote whose single-use
  deposit address becomes the charge recipient. Its result contains the
  `amount`, `currency`, `recipient`, and `method_config` values needed by
  `MPP.Plug`, plus the provider quote deadline that bounds challenge expiry.

  Direct origin-RPC verification is enabled for EVM origins by setting
  `"origin_rpc_url"`. Other origins use the specification's 1Click status
  observation mode: the presented hash must be one of the backend-observed
  origin transactions for the deposit address.

  ## Configuration

    * `"origin_network"` — source CAIP-2 network
    * `"destination_network"` — merchant CAIP-2 network
    * `"destination_asset"` — merchant CAIP-19 asset
    * `"destination_recipient"` — merchant destination address
    * `"amount_out"` — exact destination amount in base units
    * `"min_amount_in"` — minimum accepted origin deposit in base units
    * `"refund_to"` — origin-chain refund address bound into the challenge
    * `"quote_deadline"` — executable quote deadline returned by 1Click
    * `"one_click_url"` — optional API base URL
    * `"one_click_jwt"` — optional partner JWT; never exposed in challenges
    * `"origin_rpc_url"` — optional EVM origin RPC URL
    * `"store"` — optional atomic store; defaults to `MPP.Tempo.ConCacheStore`
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.NearIntents.OneClick
  alias MPP.Methods.NearIntents.Origin
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  @claim_lease_buffer_ms to_timeout(minute: 1)
  @default_slippage_bps 100
  @default_poll_interval_ms to_timeout(second: 2)
  @default_referral "mpp"
  @milliseconds_per_second to_timeout(second: 1)
  @settlement_margin_ms to_timeout(minute: 2)
  @terminal_statuses ~w(SUCCESS FAILED REFUNDED INCOMPLETE_DEPOSIT)
  @required_config_keys ~w(
    origin_network
    destination_network
    destination_asset
    destination_recipient
    amount_out
    min_amount_in
    refund_to
    quote_deadline
  )
  @required_quote_keys ~w(
    origin_asset
    origin_asset_id
    destination_asset
    destination_asset_id
    destination_recipient
    amount_out
    refund_to
    deadline
  )

  @type quote_result :: %{
          amount: String.t(),
          currency: String.t(),
          recipient: String.t(),
          expires_at: String.t(),
          method_config: map()
        }

  api(:method_name, "Return the NEAR Intents payment method identifier.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "nearintents"

  api(:credential_types, "Return the only accepted NEAR Intents credential type: hash.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(hash)

  api(:validate_config!, "Validate required NEAR Intents route and store configuration.")

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    missing = Enum.filter(@required_config_keys, &blank?(config[&1]))

    if missing != [] do
      raise ArgumentError,
            "MPP.Methods.NearIntents requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end

    validate_amount!(config["min_amount_in"], "min_amount_in")
    validate_deadline!(config["quote_deadline"])
    validate_store!(config["store"])
    :ok
  end

  api(:challenge_method_details, "Return the public NEAR Intents settlement fields for the 402 challenge.")

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    %{
      "originNetwork" => config["origin_network"],
      "destinationNetwork" => config["destination_network"],
      "destinationAsset" => config["destination_asset"],
      "destinationRecipient" => config["destination_recipient"],
      "amountOut" => config["amount_out"],
      "minAmountIn" => config["min_amount_in"],
      "depositMemo" => config["deposit_memo"],
      "refundTo" => config["refund_to"],
      "settlementBackend" => "near-intents",
      "credentialTypes" => credential_types()
    }
    |> maybe_put("slippageTolerance", config["slippage_tolerance"])
    |> maybe_put("timeEstimate", config["time_estimate"])
  end

  api(:quote, "Request a wet EXACT_OUTPUT 1Click quote and return MPP method options.")

  @doc """
  Requests an executable 1Click quote.

  The input uses CAIP identifiers for the MPP challenge and explicit 1Click
  asset IDs at the provider boundary. The returned map can be passed into a
  dynamically built `MPP.Plug` configuration.
  """
  @spec quote(map()) :: {:ok, quote_result()} | {:error, term()}
  def quote(parameters) when is_map(parameters) do
    with :ok <- require_quote_parameters(parameters),
         {:ok, response} <- OneClick.quote(parameters, quote_body(parameters)),
         {:ok, quote} <- parse_quote(response) do
      {:ok, quote_result(parameters, quote)}
    end
  end

  api(:verify, "Verify an origin deposit and await terminal NEAR Intents settlement.")

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = Map.put(charge.method_details || %{}, "deposit_address", charge.recipient)

    with {:ok, hash} <- parse_hash(payload),
         :ok <- require_runtime_fields(charge, config),
         :ok <- check_quote_deadline(config),
         :ok <- check_available_state(hash, charge.recipient, config),
         :ok <- Origin.verify(hash, charge, config),
         {:ok, claim} <- claim_settlement(hash, charge.recipient, config) do
      hash
      |> settle(charge, config)
      |> finalize_claim(claim)
    end
  end

  defp quote_body(parameters) do
    %{
      "dry" => false,
      "swapType" => "EXACT_OUTPUT",
      "depositType" => "ORIGIN_CHAIN",
      "recipientType" => "DESTINATION_CHAIN",
      "refundType" => "ORIGIN_CHAIN",
      "amount" => parameters["amount_out"],
      "originAsset" => parameters["origin_asset_id"],
      "destinationAsset" => parameters["destination_asset_id"],
      "recipient" => parameters["destination_recipient"],
      "refundTo" => parameters["refund_to"],
      "slippageTolerance" => parameters["slippage_tolerance"] || @default_slippage_bps,
      "deadline" => parameters["deadline"],
      "referral" => parameters["referral"] || @default_referral
    }
  end

  defp parse_quote(%{"quote" => quote}) when is_map(quote) do
    required = ~w(depositAddress amountIn minAmountIn amountOut deadline)

    if Enum.all?(required, &(is_binary(quote[&1]) and quote[&1] != "")) do
      {:ok, quote}
    else
      {:error, :invalid_quote_response}
    end
  end

  defp parse_quote(_response), do: {:error, :invalid_quote_response}

  defp quote_result(parameters, quote) do
    method_config =
      parameters
      |> Map.take(
        ~w(one_click_url one_click_jwt one_click_req_options origin_rpc_url origin_req_options store poll_timeout_ms poll_interval_ms)
      )
      |> Map.merge(%{
        "origin_network" => chain_of(parameters["origin_asset"]),
        "destination_network" => chain_of(parameters["destination_asset"]),
        "destination_asset" => parameters["destination_asset"],
        "destination_recipient" => parameters["destination_recipient"],
        "amount_out" => parameters["amount_out"],
        "min_amount_in" => quote["minAmountIn"],
        "deposit_memo" => quote["depositMemo"],
        "slippage_tolerance" => parameters["slippage_tolerance"] || @default_slippage_bps,
        "time_estimate" => quote["timeEstimate"],
        "refund_to" => parameters["refund_to"],
        "quote_deadline" => quote["deadline"]
      })

    %{
      amount: quote["amountIn"],
      currency: parameters["origin_asset"],
      recipient: quote["depositAddress"],
      expires_at: quote["deadline"],
      method_config: method_config
    }
  end

  defp chain_of(asset) do
    case String.split(asset, "/", parts: 2) do
      [network, _asset] -> network
      _ -> nil
    end
  end

  defp require_quote_parameters(parameters) do
    missing = Enum.filter(@required_quote_keys, &blank?(parameters[&1]))

    cond do
      missing != [] -> {:error, {:missing_quote_parameters, missing}}
      is_nil(chain_of(parameters["origin_asset"])) -> {:error, :invalid_origin_asset}
      is_nil(chain_of(parameters["destination_asset"])) -> {:error, :invalid_destination_asset}
      true -> :ok
    end
  end

  defp parse_hash(payload) do
    case Credential.parse_hash_payload(payload) do
      {:ok, hash} -> {:ok, hash}
      {:error, _reason} -> {:error, Errors.new(:invalid_payload, "hash credential requires a non-empty hash")}
    end
  end

  defp require_runtime_fields(%Charge{recipient: recipient, currency: currency}, config) do
    cond do
      blank?(recipient) ->
        {:error, Errors.new(:verification_failed, "Near Intents method requires a deposit address")}

      blank?(config["challenge_id"]) ->
        {:error, Errors.new(:verification_failed, "Missing challenge identifier")}

      chain_of(currency) != config["origin_network"] ->
        {:error, Errors.new(:verification_failed, "Origin asset does not match origin network")}

      chain_of(config["destination_asset"]) != config["destination_network"] ->
        {:error, Errors.new(:verification_failed, "Destination asset does not match destination network")}

      true ->
        :ok
    end
  end

  defp check_quote_deadline(config) do
    case DateTime.from_iso8601(config["quote_deadline"] || "") do
      {:ok, deadline, _offset} ->
        if DateTime.before?(DateTime.utc_now(), deadline) do
          :ok
        else
          {:error, Errors.new(:payment_expired, "NEAR Intents quote has expired")}
        end

      _ ->
        {:error, Errors.new(:verification_failed, "Invalid NEAR Intents quote deadline")}
    end
  end

  defp check_available_state(_hash, _deposit_address, %{"store" => false}), do: :ok

  defp check_available_state(hash, deposit_address, config) do
    store = Store.resolve(config["store"])

    with :ok <- check_available_key(store, deposit_key(deposit_address), :deposit) do
      check_available_key(store, hash_key(hash, config), :hash)
    end
  end

  defp check_available_key(store, key, kind) do
    now = System.system_time(:millisecond)

    case Store.get(store, key) do
      :not_found -> :ok
      {:ok, %{state: :active}} -> :ok
      {:ok, %{state: :inflight, lease_until: lease_until}} when lease_until <= now -> :ok
      {:ok, %{state: :inflight}} -> {:error, Errors.new(:verification_failed, inflight_detail(kind))}
      {:ok, _consumed} -> {:error, Errors.new(consumed_error(kind), consumed_detail(kind))}
      {:error, _reason} -> {:error, Errors.new(:settlement_unavailable, "Settlement state store is unavailable")}
    end
  end

  defp claim_settlement(_hash, _deposit_address, %{"store" => false}), do: {:ok, nil}

  defp claim_settlement(hash, deposit_address, config) do
    store = Store.resolve(config["store"])
    owner = System.unique_integer([:positive, :monotonic])
    lease_ms = poll_timeout_ms(config) + @claim_lease_buffer_ms
    lease_until = System.system_time(:millisecond) + lease_ms
    value = %{state: :inflight, owner: owner, lease_until: lease_until}

    with :ok <- claim_key(store, hash_key(hash, config), value, lease_ms, :hash),
         :ok <- claim_key(store, deposit_key(deposit_address), value, lease_ms, :deposit) do
      {:ok,
       %{
         store: store,
         owner: owner,
         hash_key: hash_key(hash, config),
         deposit_key: deposit_key(deposit_address),
         terminal_ttl_ms: quote_remaining_ms(config)
       }}
    else
      {:error, %Errors{} = error} ->
        release_key(store, hash_key(hash, config), owner)
        {:error, error}
    end
  end

  defp claim_key(store, key, value, lease_ms, kind) do
    now = System.system_time(:millisecond)

    result =
      Store.update(
        store,
        key,
        fn
          :not_found -> {:put, value, :claimed}
          %{state: :active} -> {:put, value, :claimed}
          %{state: :inflight, lease_until: lease_until} when lease_until <= now -> {:put, value, :claimed}
          %{state: :inflight} -> {:noop, :inflight}
          %{state: :consumed} -> {:noop, :consumed}
          _other -> {:noop, :consumed}
        end,
        ttl_ms: lease_ms
      )

    case result do
      {:ok, :claimed} -> :ok
      {:ok, :inflight} -> {:error, Errors.new(:verification_failed, inflight_detail(kind))}
      {:ok, :consumed} -> {:error, Errors.new(consumed_error(kind), consumed_detail(kind))}
      {:error, _reason} -> {:error, Errors.new(:settlement_unavailable, "Settlement state store is unavailable")}
    end
  end

  defp settle(hash, charge, config) do
    _ = OneClick.submit_deposit(config, hash, charge.recipient, config["deposit_memo"])

    with {:ok, status} <- poll_status(charge.recipient, config),
         :ok <- match_origin_hash(status, hash, config) do
      {:terminal, terminal_result(status, hash, charge, config)}
    else
      {:error, %Errors{} = error} -> {:release, {:error, error}}
    end
  end

  defp poll_status(deposit_address, config) do
    deadline = poll_deadline(config)
    do_poll_status(deposit_address, config, deadline)
  end

  defp poll_deadline(config) do
    now = System.monotonic_time(:millisecond)
    timeout_deadline = now + poll_timeout_ms(config)
    min(timeout_deadline, now + quote_remaining_ms(config))
  end

  defp do_poll_status(deposit_address, config, deadline) do
    case OneClick.status(config, deposit_address, config["deposit_memo"]) do
      {:ok, %{"status" => status} = result} when status in @terminal_statuses ->
        {:ok, result}

      {:ok, %{"status" => status}} when is_binary(status) ->
        poll_again(deposit_address, config, deadline)

      {:ok, _response} ->
        {:error, Errors.new(:settlement_unavailable, "1Click returned an invalid status response")}

      {:error, :unavailable} ->
        if System.monotonic_time(:millisecond) < deadline do
          poll_again(deposit_address, config, deadline)
        else
          {:error, Errors.new(:settlement_unavailable, "1Click status endpoint is unavailable")}
        end

      {:error, {:rejected, status, _body}} ->
        {:error, Errors.new(:verification_failed, "1Click rejected the deposit status request (HTTP #{status})")}
    end
  end

  defp poll_again(deposit_address, config, deadline) do
    interval = poll_interval_ms(config)

    if System.monotonic_time(:millisecond) + interval > deadline do
      {:error, Errors.new(:settlement_timeout, "Settlement did not reach a terminal state before the timeout")}
    else
      receive do
      after
        interval -> do_poll_status(deposit_address, config, deadline)
      end
    end
  end

  defp match_origin_hash(status, hash, config) do
    if Origin.observed_hash?(status, hash, config["origin_network"]) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Presented hash was not observed for this deposit address")}
    end
  end

  defp terminal_result(%{"status" => "SUCCESS"} = status, hash, charge, config) do
    with :ok <- check_deposited_amount(status, config),
         {:ok, reference} <- settlement_reference(status) do
      receipt =
        Receipt.new(
          method: method_name(),
          reference: reference,
          timestamp: status["updatedAt"],
          external_id: charge.external_id,
          extensions: %{
            "challengeId" => config["challenge_id"],
            "originTxHash" => hash,
            "destinationNetwork" => config["destination_network"]
          }
        )

      {:ok, receipt}
    end
  end

  defp terminal_result(%{"status" => "INCOMPLETE_DEPOSIT"} = status, _hash, _charge, _config) do
    deposited = get_in(status, ["swapDetails", "depositedAmount"])
    detail = if deposited, do: "Deposit of #{deposited} is below minAmountIn", else: "Deposit is below minAmountIn"
    {:error, Errors.new(:payment_insufficient, detail)}
  end

  defp terminal_result(%{"status" => status} = result, _hash, _charge, _config) when status in ~w(FAILED REFUNDED) do
    reason = get_in(result, ["swapDetails", "refundReason"]) || "1Click terminal status #{status}"
    {:error, Errors.new(:settlement_failed, "Settlement failed: #{reason}; deposit is refunded to refundTo")}
  end

  defp check_deposited_amount(status, config) do
    deposited = get_in(status, ["swapDetails", "depositedAmount"])

    with {actual, ""} <- Integer.parse(deposited || ""),
         {minimum, ""} <- Integer.parse(config["min_amount_in"] || ""),
         true <- actual >= minimum do
      :ok
    else
      _ -> {:error, Errors.new(:payment_insufficient, "Observed deposit is below minAmountIn")}
    end
  end

  defp settlement_reference(status) do
    destination = get_in(status, ["swapDetails", "destinationChainTxHashes", Access.at(0), "hash"])
    near = get_in(status, ["swapDetails", "nearTxHashes", Access.at(0)])

    case destination || near do
      reference when is_binary(reference) and reference != "" -> {:ok, reference}
      _ -> {:error, Errors.new(:settlement_unavailable, "Successful settlement has no destination reference")}
    end
  end

  defp finalize_claim({:terminal, result}, claim) do
    case consume_claim(claim) do
      :ok -> result
      {:error, %Errors{} = error} -> {:error, error}
    end
  end

  defp finalize_claim({:release, result}, claim) do
    case release_claim(claim) do
      :ok -> result
      {:error, %Errors{} = error} -> {:error, error}
    end
  end

  defp consume_claim(nil), do: :ok

  defp consume_claim(claim) do
    with :ok <- consume_key(claim.store, claim.deposit_key, claim.owner, claim.terminal_ttl_ms) do
      consume_key(claim.store, claim.hash_key, claim.owner, claim.terminal_ttl_ms)
    end
  end

  defp consume_key(store, key, owner, ttl_ms) do
    case Store.update(
           store,
           key,
           fn
             %{state: :inflight, owner: ^owner} -> {:put, %{state: :consumed}, :ok}
             %{state: :consumed} -> {:noop, :ok}
             _other -> {:noop, :lost}
           end,
           ttl_ms: ttl_ms
         ) do
      {:ok, :ok} -> :ok
      _other -> {:error, Errors.new(:settlement_unavailable, "Settlement state store is unavailable")}
    end
  end

  defp release_claim(nil), do: :ok

  defp release_claim(claim) do
    with :ok <- release_key(claim.store, claim.deposit_key, claim.owner) do
      release_key(claim.store, claim.hash_key, claim.owner)
    end
  end

  defp release_key(store, key, owner) do
    case Store.update(store, key, fn
           %{state: :inflight, owner: ^owner} -> {:delete, :ok}
           _other -> {:noop, :ok}
         end) do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, Errors.new(:settlement_unavailable, "Settlement state store is unavailable")}
    end
  end

  defp hash_key(hash, config) do
    "mpp:nearintents:hash:" <> Origin.canonical_hash(hash, config["origin_network"])
  end

  defp deposit_key(address), do: "mpp:nearintents:deposit:" <> address

  defp poll_timeout_ms(config) do
    config["poll_timeout_ms"] ||
      (config["time_estimate"] || 0) * @milliseconds_per_second + @settlement_margin_ms
  end

  defp poll_interval_ms(config), do: config["poll_interval_ms"] || @default_poll_interval_ms

  defp quote_remaining_ms(config) do
    {:ok, quote_deadline, _offset} = DateTime.from_iso8601(config["quote_deadline"])
    max(DateTime.diff(quote_deadline, DateTime.utc_now(), :millisecond), 1)
  end

  defp consumed_error(:hash), do: :verification_failed
  defp consumed_error(:deposit), do: :invalid_challenge
  defp consumed_detail(:hash), do: "Transaction hash has already been consumed"
  defp consumed_detail(:deposit), do: "NEAR Intents quote has already been settled"
  defp inflight_detail(:hash), do: "Settlement for this transaction hash is already in progress"
  defp inflight_detail(:deposit), do: "Settlement for this deposit address is already in progress"

  defp validate_store!(nil), do: :ok
  defp validate_store!(false), do: :ok

  defp validate_store!({ConCacheStore, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      raise ArgumentError, "MPP.Methods.NearIntents ConCacheStore opts must be a keyword list"
    end
  end

  defp validate_store!(store) do
    if !Store.dedup_capable?(store) or !Store.update_capable?(store) do
      raise ArgumentError,
            "MPP.Methods.NearIntents :store must implement the MPP.Tempo.Store dedup callbacks and atomic update/3"
    end

    :ok
  end

  defp validate_amount!(amount, key) do
    case Integer.parse(amount || "") do
      {value, ""} when value >= 0 -> :ok
      _ -> raise ArgumentError, "MPP.Methods.NearIntents #{key} must be a non-negative integer string"
    end
  end

  defp validate_deadline!(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, _datetime, _offset} -> :ok
      _ -> raise ArgumentError, "MPP.Methods.NearIntents quote_deadline must be an RFC 3339 timestamp"
    end
  end

  defp blank?(value), do: !is_binary(value) or value == ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
