# The shared callback set IS a behaviour (`use MPP.Method`); reach's source frontend
# can't see the macro-injected `@behaviour`, so the candidate smell false-positives.
# reach:disable-next-line behaviour_candidate
defmodule MPP.Methods.Stellar do
  @moduledoc """
  Stellar charge verification for SEP-41 token transfers.

  Implements `draft-stellar-charge-00`. Pull credentials carry
  `type: "transaction"` with a base64 TransactionEnvelope XDR; push credentials
  carry `type: "hash"` with a 64-character hex transaction hash. Pull covers
  both unsponsored (client-signed, submitted as-is) and sponsored (`feePayer`)
  flows. SEP-41 `transfer` events are checked via Soroban RPC `simulateTransaction`
  (pull) and `getTransaction` (push).

  Configure `rpc_url` (HTTPS Soroban RPC), `network` (`stellar:pubnet` or
  `stellar:testnet`), and optionally `fee_payer` with `fee_payer_secret`. Replay
  protection uses `MPP.Tempo.Store` and is on by default.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Methods.Stellar.Envelope
  alias MPP.Methods.Stellar.RPC
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  @public_fields ~w(network feePayer)
  @store_key_prefix "mpp:stellar:"
  @ledger_close_seconds 5
  @default_challenge_expiry 300
  @dedup_store_error_detail "Dedup store error"

  api(:method_name, "Return the Stellar payment method identifier.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "stellar"

  api(:credential_types, "Return the draft's two charge credential types.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(transaction hash)

  api(:validate_config!, "Validate RPC, network and optional fee-payer configuration.")

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    if !RPC.valid_url?(config["rpc_url"]) do
      raise ArgumentError, "MPP.Methods.Stellar requires an HTTPS rpc_url in method_config"
    end

    if !is_binary(RPC.passphrase(network(config))) do
      raise ArgumentError, "MPP.Methods.Stellar requires network stellar:pubnet or stellar:testnet"
    end

    if fee_payer?(config) and not secret?(config["fee_payer_secret"]) do
      raise ArgumentError, "MPP.Methods.Stellar fee_payer requires fee_payer_secret"
    end

    validate_store!(config["store"])
    :ok
  end

  api(:challenge_method_details, "Expose network, feePayer and credential types.")

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    config
    |> Map.take(@public_fields)
    |> Map.merge(%{
      "network" => network(config),
      "feePayer" => fee_payer?(config),
      "credentialTypes" => credential_types()
    })
  end

  api(:verify, "Verify a Stellar SEP-41 charge credential in pull or push mode.")

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "hash"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_hash_when_fee_payer(config),
         {:ok, hash} <- extract_hash(payload) do
      verify_hash(hash, charge, config)
    end
  end

  def verify(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}
    verify_transaction(payload, charge, config)
  end

  def verify(_payload, %Charge{}) do
    {:error, Errors.new(:invalid_payload, ~s(Missing or invalid 'type' field — expected "transaction" or "hash"))}
  end

  defp verify_hash(hash, charge, config) do
    store = Store.resolve(config["store"])

    with {:ok, _url} <- Shared.require_config(config, "rpc_url", "Stellar"),
         :ok <- require_recipient(charge),
         {:ok, amount} <- parse_amount(charge.amount),
         :ok <- require_contract(charge.currency),
         :ok <- unused(store, hash_key(hash)),
         :ok <- unused_challenge(store, config),
         {:ok, result} <- RPC.await_existing(hash, config),
         :ok <- success_status(result),
         {:ok, inspected} <- envelope_xdr(result),
         :ok <- match_transfer(inspected, charge, amount),
         :ok <- mark(store, hash_key(hash)),
         :ok <- mark_challenge(store, config) do
      receipt(hash, charge)
    end
  end

  defp verify_transaction(payload, charge, config) do
    store = Store.resolve(config["store"])
    sponsored? = fee_payer?(config)

    with {:ok, xdr} <- extract_transaction(payload),
         {:ok, _url} <- Shared.require_config(config, "rpc_url", "Stellar"),
         :ok <- require_recipient(charge),
         {:ok, amount} <- parse_amount(charge.amount),
         :ok <- require_contract(charge.currency),
         {:ok, inspected} <- Envelope.decode(xdr),
         :ok <- match_transfer(inspected, charge, amount),
         :ok <- match_source(inspected, sponsored?),
         :ok <- match_expiry(inspected, charge, config, sponsored?),
         :ok <- match_auth(inspected, config, sponsored?),
         :ok <- match_signatures(inspected, config, sponsored?),
         :ok <- unused_challenge(store, config),
         {:ok, simulated} <- RPC.simulate(xdr, config),
         :ok <- match_simulation(simulated, inspected.transfer),
         {:ok, submitted} <- settle_pull(inspected, xdr, simulated, config, sponsored?),
         {:ok, result} <- RPC.await_transaction(submitted, config),
         :ok <- settled(result),
         :ok <- mark(store, hash_key(submitted)),
         :ok <- mark_challenge(store, config) do
      receipt(submitted, charge)
    end
  end

  defp settle_pull(_inspected, xdr, _simulated, config, false) do
    with {:ok, result} <- RPC.send_transaction(xdr, config),
         hash when is_binary(hash) <- result["hash"] do
      {:ok, String.downcase(hash)}
    else
      {:error, %Errors{}} = error -> error
      _ -> {:error, Errors.new(:settlement_failed, "Stellar sendTransaction did not return a hash")}
    end
  end

  defp settle_pull(inspected, _xdr, _simulated, config, true) do
    with {:ok, secret} <- require_secret(config),
         {:ok, payer} <- public_from_secret(secret),
         :ok <- reject_server_in_transfer(inspected, payer),
         {:ok, passphrase} <- network_passphrase(config),
         {:ok, sequence} <- RPC.account_sequence(payer, config),
         {:ok, rebuilt} <- Envelope.rebuild(inspected, payer, sequence + 1, nil, nil),
         {:ok, unsigned} <- Envelope.sign(rebuilt, secret, passphrase),
         {:ok, simulated} <- RPC.simulate(unsigned, config),
         :ok <- match_simulation(simulated, inspected.transfer),
         {:ok, prepared} <-
           Envelope.rebuild(inspected, payer, sequence + 1, simulated["transactionData"], resource_fee(simulated)),
         {:ok, signed} <- Envelope.sign(prepared, secret, passphrase),
         {:ok, result} <- RPC.send_transaction(signed, config),
         hash when is_binary(hash) <- result["hash"] do
      {:ok, String.downcase(hash)}
    else
      {:error, %Errors{}} = error -> error
      _ -> {:error, Errors.new(:settlement_failed, "Stellar sponsored settlement did not return a hash")}
    end
  end

  defp extract_hash(%{"hash" => hash}) when is_binary(hash) do
    normalized = String.downcase(hash)

    if byte_size(normalized) == 64 and MPP.Hex.hex_string?(normalized) do
      {:ok, normalized}
    else
      {:error, Errors.new(:invalid_payload, "Missing or invalid 'hash' field in credential payload")}
    end
  end

  defp extract_hash(_),
    do: {:error, Errors.new(:invalid_payload, "Missing or invalid 'hash' field in credential payload")}

  defp extract_transaction(%{"transaction" => xdr}) when is_binary(xdr) and xdr != "" do
    case Base.decode64(xdr) do
      {:ok, _} -> {:ok, xdr}
      :error -> {:error, Errors.new(:invalid_payload, "Transaction is not valid base64")}
    end
  end

  defp extract_transaction(_),
    do: {:error, Errors.new(:invalid_payload, "Missing or invalid 'transaction' field in credential payload")}

  defp match_transfer(%{transfer: transfer}, charge, amount) do
    cond do
      transfer.contract != charge.currency ->
        {:error, Errors.new(:verification_failed, "SEP-41 contract does not match currency")}

      transfer.to != charge.recipient ->
        {:error, Errors.new(:verification_failed, "SEP-41 transfer recipient does not match charge")}

      transfer.amount != amount ->
        {:error, Errors.new(:verification_failed, "SEP-41 transfer amount does not match charge")}

      true ->
        :ok
    end
  end

  defp match_source(%{source: source}, true) do
    if source == Envelope.zero_account() do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Sponsored Stellar transaction source must be the all-zeros account")}
    end
  end

  defp match_source(_inspected, false), do: :ok

  defp match_expiry(%{time_bounds_max: max}, _charge, config, false) do
    with {:ok, expires} <- expires_unix(config) do
      if is_integer(max) and max > 0 and max <= expires do
        :ok
      else
        {:error, Errors.new(:verification_failed, "Stellar timeBounds.maxTime exceeds challenge expiry")}
      end
    end
  end

  defp match_expiry(_inspected, _charge, _config, true), do: :ok

  defp match_signatures(_inspected, _config, true), do: :ok

  defp match_signatures(inspected, config, false) do
    with {:ok, passphrase} <- network_passphrase(config) do
      if Envelope.signed_by_source?(inspected, passphrase) do
        :ok
      else
        {:error, Errors.new(:verification_failed, "Stellar transaction is not signed for the configured network")}
      end
    end
  end

  defp match_auth(_inspected, _config, false), do: :ok

  defp match_auth(%{auth: auth, transfer: transfer}, config, true) do
    with {:ok, secret} <- require_secret(config),
         {:ok, payer} <- public_from_secret(secret),
         {:ok, latest} <- RPC.get_latest_ledger(config),
         {:ok, expires} <- expires_unix(config) do
      remaining = max(expires - System.os_time(:second), 0)
      max_expiration = latest + div(remaining + @ledger_close_seconds - 1, @ledger_close_seconds)

      cond do
        auth == [] or Enum.any?(auth, &(&1.type != :address)) ->
          {:error, Errors.new(:verification_failed, "Sponsored Stellar auth must use sorobanCredentialsAddress")}

        Enum.any?(auth, &(&1.sub_invocations > 0)) ->
          {:error, Errors.new(:verification_failed, "Stellar authorization tree must not contain subInvocations")}

        Enum.any?(auth, &(is_integer(&1.expiration) and &1.expiration > max_expiration)) ->
          {:error, Errors.new(:verification_failed, "Stellar authorization expiration exceeds challenge expiry")}

        transfer.from == payer or Enum.any?(auth, &(&1.address == payer)) ->
          {:error, Errors.new(:verification_failed, "Stellar fee payer must not appear in transfer or auth")}

        true ->
          :ok
      end
    end
  end

  defp match_simulation(result, transfer) do
    events =
      result
      |> Map.get("events", [])
      |> Envelope.contract_events()

    if Envelope.expected_transfer?(events, transfer) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Simulation events do not match the SEP-41 transfer")}
    end
  end

  defp envelope_xdr(%{"envelopeXdr" => xdr}) when is_binary(xdr), do: Envelope.decode(xdr)

  defp envelope_xdr(_),
    do: {:error, Errors.new(:verification_failed, "Stellar getTransaction did not include envelopeXdr")}

  defp success_status(%{"status" => "SUCCESS"}), do: :ok

  defp success_status(%{"status" => "FAILED"}),
    do: {:error, Errors.new(:verification_failed, "Stellar transaction status is not SUCCESS")}

  defp success_status(_), do: {:error, Errors.new(:verification_failed, "Stellar transaction status is not SUCCESS")}

  defp settled(%{"status" => "SUCCESS"}), do: :ok

  defp settled(%{"status" => "FAILED"}),
    do: {:error, Errors.new(:settlement_failed, "Stellar transaction failed on-chain")}

  defp settled(_), do: {:error, Errors.new(:settlement_failed, "Stellar transaction failed on-chain")}

  defp reject_hash_when_fee_payer(config) do
    if fee_payer?(config) do
      {:error, Errors.new(:verification_failed, "Push mode must not be used when feePayer is true")}
    else
      :ok
    end
  end

  defp reject_server_in_transfer(%{transfer: transfer, auth: auth}, payer) do
    if transfer.from == payer or Enum.any?(auth, &(&1.address == payer)) do
      {:error, Errors.new(:verification_failed, "Stellar fee payer must not appear in transfer or auth")}
    else
      :ok
    end
  end

  defp require_recipient(%Charge{recipient: recipient}) when is_binary(recipient) and recipient != "" do
    case StellarBase.StrKey.decode(recipient, :ed25519_public_key) do
      {:ok, _} -> :ok
      _ -> {:error, Errors.new(:verification_failed, "Invalid Stellar recipient")}
    end
  end

  defp require_recipient(_), do: {:error, Errors.new(:verification_failed, "Stellar charge requires a recipient")}

  defp require_contract(currency) when is_binary(currency) do
    case StellarBase.StrKey.decode(currency, :contract) do
      {:ok, _} -> :ok
      _ -> {:error, Errors.new(:verification_failed, "Stellar currency must be a SEP-41 contract address")}
    end
  end

  defp require_contract(_),
    do: {:error, Errors.new(:verification_failed, "Stellar currency must be a SEP-41 contract address")}

  defp parse_amount(amount) do
    case Shared.parse_charge_amount(amount) do
      {:ok, int} when int > 0 -> {:ok, int}
      {:ok, _} -> {:error, Errors.new(:verification_failed, "Stellar charge amount must be a positive integer")}
      error -> error
    end
  end

  defp require_secret(config) do
    case config["fee_payer_secret"] do
      secret when is_binary(secret) -> {:ok, secret}
      _ -> {:error, Errors.new(:verification_failed, "Stellar method missing required config: fee_payer_secret")}
    end
  end

  defp public_from_secret(secret) do
    case StellarBase.StrKey.decode(secret, :ed25519_secret_seed) do
      {:ok, raw} -> {:ok, raw |> Ed25519.derive_public_key() |> StellarBase.StrKey.encode!(:ed25519_public_key)}
      _ -> {:error, Errors.new(:verification_failed, "Invalid Stellar fee-payer secret")}
    end
  end

  defp expires_unix(config) do
    case config["challenge_expires"] do
      expires when is_binary(expires) ->
        case DateTime.from_iso8601(expires) do
          {:ok, datetime, _} -> {:ok, DateTime.to_unix(datetime)}
          _ -> {:error, Errors.new(:invalid_challenge, "Stellar challenge expiry is invalid")}
        end

      _ ->
        {:ok, System.os_time(:second) + @default_challenge_expiry}
    end
  end

  defp unused(nil, _key), do: :ok

  defp unused(store, key) do
    case Store.get(store, key) do
      :not_found -> :ok
      {:ok, _} -> {:error, Errors.new(:invalid_challenge, "Stellar credential has already been used")}
      {:error, _} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  defp unused_challenge(nil, _config), do: :ok

  defp unused_challenge(store, %{"challenge_id" => id}) when is_binary(id) and id != "" do
    unused(store, @store_key_prefix <> "challenge:" <> id)
  end

  defp unused_challenge(_store, _config) do
    {:error, Errors.new(:verification_failed, "Stellar method missing required config: challenge_id")}
  end

  defp mark(nil, _key), do: :ok

  defp mark(store, key) do
    case Store.check_and_mark(store, key, System.system_time(:millisecond)) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, Errors.new(:invalid_challenge, "Stellar credential has already been used")}
      {:error, _} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  defp mark_challenge(nil, _config), do: :ok

  defp mark_challenge(store, %{"challenge_id" => id}) when is_binary(id) and id != "" do
    mark(store, @store_key_prefix <> "challenge:" <> id)
  end

  defp mark_challenge(_store, _config) do
    {:error, Errors.new(:verification_failed, "Stellar method missing required config: challenge_id")}
  end

  defp hash_key(hash), do: @store_key_prefix <> "tx:" <> hash

  defp receipt(hash, charge) do
    {:ok, Receipt.new(method: "stellar", reference: hash, external_id: charge.external_id)}
  end

  defp resource_fee(%{"minResourceFee" => fee}) when is_binary(fee) do
    case Integer.parse(fee) do
      {int, ""} -> int + 100
      _ -> 100
    end
  end

  defp resource_fee(%{"minResourceFee" => fee}) when is_integer(fee), do: fee + 100
  defp resource_fee(_), do: 100

  defp fee_payer?(config) do
    config["feePayer"] == true or config["fee_payer"] == true
  end

  defp network(config), do: config["network"] || "stellar:testnet"

  defp network_passphrase(config) do
    case RPC.passphrase(network(config)) do
      passphrase when is_binary(passphrase) -> {:ok, passphrase}
      _ -> {:error, Errors.new(:verification_failed, "Stellar network must be stellar:pubnet or stellar:testnet")}
    end
  end

  defp secret?(secret) when is_binary(secret) do
    match?({:ok, _}, StellarBase.StrKey.decode(secret, :ed25519_secret_seed))
  end

  defp secret?(_), do: false

  defp validate_store!(nil), do: :ok
  defp validate_store!(false), do: :ok

  defp validate_store!({ConCacheStore, opts}) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError,
            "MPP.Methods.Stellar :store opts for {MPP.Tempo.ConCacheStore, opts} must be a keyword list; got: #{inspect(opts)}"
    end

    validate_store!(ConCacheStore)
  end

  defp validate_store!(ConCacheStore), do: :ok

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Methods.Stellar :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !Store.dedup_capable?(store) do
      raise ArgumentError,
            "MPP.Methods.Stellar :store must be a module implementing MPP.Tempo.Store " <>
              "(get/1, put/2, check_and_mark/2 — atomic single-use is required; use `store: false` to disable dedup)"
    end

    :ok
  end
end
