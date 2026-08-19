# The shared callback set IS a behaviour (`use MPP.Method`); reach's source frontend
# can't see the macro-injected `@behaviour`, so the candidate smell false-positives.
# reach:disable-next-line behaviour_candidate
defmodule MPP.Methods.Solana do
  @moduledoc """
  Solana payment method — verifies native SOL and SPL token charge payments.

  Three credential types are supported, matching `draft-solana-charge-00`:

    * `type="transaction"` (pull, default) — the client sends signed legacy
      transaction bytes; the server optionally co-signs as fee payer, simulates,
      broadcasts, and waits for confirmation.
    * `type="signature"` (push) — the client broadcasts the transaction and
      sends the confirmed signature; the server fetches it via RPC and matches
      the transfer against the charge.
    * `type="bundle"` (confidential) — the client sends ordered proof setup,
      Token-2022 confidential transfer, and proof close transactions. The
      server confirms the encrypted amount with its recipient ElGamal key.

  ## Configuration

  Pass Solana-specific config via `:method_config` in `MPP.Plug` opts:

      plug MPP.Plug,
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MPP.Methods.Solana,
        amount: "10000000",
        currency: "sol",
        recipient: "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
        method_config: %{
          "rpc_url" => "https://api.devnet.solana.com",
          "network" => "devnet"
        }

  ## Config Keys

    * `"rpc_url"` — (required) Solana JSON-RPC endpoint URL
    * `"network"` — (optional) `"mainnet"`, `"devnet"`, or `"localnet"`;
      advertised in challenge details, defaults to `"mainnet"`
    * `"decimals"` — (required for SPL) token decimal count advertised to clients
    * `"token_program"` — (optional) base58 Token or Token-2022 program id
    * `"fee_payer"` — (optional) server fee sponsorship, defaults to `false`
    * `"fee_payer_private_key"` — (required when `fee_payer: true`) Ed25519 seed
      as hex, base58, or a Solana CLI JSON keypair
    * `"fee_payer_key"` — (optional) base58 fee-payer pubkey; derived from the
      private key when omitted
    * `"splits"` — (optional) at most 8 extra payment legs (`recipient`, `amount`,
      optional `memo`, optional `ataCreationRequired`)
    * `"store"` — (optional) replay-dedup store, **on by default** (see
      `MPP.Methods.EVM` for the same contract). Pass `store: false` to opt out
    * `"req_options"` — (optional) merged into `Cartouche.Solana.RPC` calls
      (e.g. `[plug: {Req.Test, MyMod}]`) for testing stubs
    * `"wait_for_confirmation"` — (optional) when `false`, pull mode broadcasts
      without waiting for confirmation. Default `true`
    * `"max_compute_unit_limit"` / `"max_compute_unit_price"` — (optional)
      fee-payer ceilings for compute-budget instructions
    * `"confidential"` — (optional) enables the Token-2022 confidential profile
    * `"recipient_elgamal_secret_key"` — (required for confidential) base64
      canonical scalar for the recipient confidential token account
    * `"max_bundle_transactions"` — (optional) confidential bundle bound;
      defaults to 8

  ## Credential Payload

    * `"type" => "transaction"`, `"transaction" => "<base64>"` — signed legacy
      transaction bytes (max 1232 decoded)
    * `"type" => "signature"`, `"signature" => "<base58>"` — confirmed
      transaction signature
    * `"type" => "bundle"`, `"transactions" => ["<base64>", ...]` — ordered
      confidential transaction bundle

  ## Currency

    * Native SOL: `"sol"`
    * SPL tokens: the base58 mint address

  ## Dependencies

  Uses `Cartouche.Solana` (RPC, legacy transaction codec, System/Token/ATA
  programs) already in the on-chain stack.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias Cartouche.Solana.Keys
  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.RPC
  alias Cartouche.Solana.Transaction
  alias MPP.Errors
  alias MPP.Hex
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Methods.Solana.Confidential
  alias MPP.Methods.Solana.Instructions
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  require Logger

  @required_config_keys ~w(rpc_url)
  @networks ~w(mainnet devnet localnet)
  @max_tx_bytes 1232
  @empty_signature <<0::512>>
  @store_key_prefix "mpp:solana:"
  @dedup_store_error_detail "Dedup store error"
  @solana_rpc_error_detail "Solana RPC request failed"
  @zero_amount_detail "Zero-amount challenges are not supported for Solana credentials"
  @signature_bytes 64
  @default_max_bundle_transactions 8

  api(:method_name, "Return the payment method identifier for Solana.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "solana"

  api(:credential_types, "Return the Solana charge payload types: transaction, signature, and bundle.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(transaction signature bundle)

  api(
    :validate_config!,
    "Validate Solana method_config at init time. Raises on missing `rpc_url` or invalid fee-payer / splits config.",
    params: [
      config: [kind: :value, description: "method_config map to validate"]
    ],
    returns: %{type: :atom, description: "`:ok` on success, raises `ArgumentError` on missing keys"}
  )

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    missing = Enum.filter(@required_config_keys, &is_nil(config[&1]))

    if missing != [] do
      raise ArgumentError,
            "MPP.Methods.Solana requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end

    validate_network!(config["network"])
    Confidential.validate_config!(config)
    validate_store!(config["store"])
    validate_fee_payer!(config)
    Instructions.validate_splits_config!(config["splits"])
    :ok
  end

  api(:verify, "Verify a Solana credential by checking on-chain settlement.",
    params: [
      payload: [
        kind: :value,
        description:
          ~s{Credential payload map with `"type"` (`"transaction"`, `"signature"`, or `"bundle"`) and the corresponding proof field}
      ],
      charge: [
        kind: :value,
        description: "Charge intent struct with amount, currency, recipient, and method_details (including `rpc_url`)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, error}` on failure"},
    errors: [:invalid_payload, :verification_failed]
  )

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "signature"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_zero_amount(charge),
         :ok <- reject_non_bundle_when_confidential(config),
         :ok <- reject_signature_when_fee_payer(config) do
      verify_signature_credential(payload, charge, config)
    end
  end

  def verify(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_zero_amount(charge),
         :ok <- reject_non_bundle_when_confidential(config) do
      verify_transaction_credential(payload, charge, config)
    end
  end

  def verify(%{"type" => "bundle"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_zero_amount(charge),
         :ok <- require_confidential(config) do
      verify_bundle_credential(payload, charge, config)
    end
  end

  def verify(_payload, %Charge{}) do
    {:error,
     Errors.new(
       :invalid_payload,
       ~s(Missing or invalid 'type' field — expected "transaction", "signature", or "bundle")
     )}
  end

  api(
    :challenge_method_details,
    "Return Solana-specific fields (`network`, `credentialTypes`, `feePayer`, optional decimals/tokenProgram/splits) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details containing Solana method_config keys"
      ]
    ],
    returns: %{
      type: :map,
      description: "Public challenge methodDetails; never includes rpc_url, keys, or store"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}
    fee_payer? = fee_payer_enabled?(config)
    :ok = Confidential.validate_charge!(charge, config)

    details = %{
      "network" => network(config),
      "credentialTypes" => challenge_credential_types(config),
      "feePayer" => fee_payer?
    }

    details
    |> maybe_put_decimals(charge, config)
    |> maybe_put_token_program(charge, config)
    |> maybe_put_fee_payer_key(config, fee_payer?)
    |> maybe_put_splits(config)
    |> maybe_put_confidential(config)
  end

  # --- signature (push) ---

  defp verify_signature_credential(payload, charge, config) do
    store = Store.resolve(config["store"])

    with {:ok, signature} <- extract_signature(payload),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Solana"),
         :ok <- require_recipient(charge),
         :ok <- check_signature_unused(store, signature),
         {:ok, rpc_tx} <- fetch_transaction(signature, rpc_url, config),
         :ok <- Instructions.verify_parsed(rpc_tx, charge, instruction_opts(charge, config)),
         :ok <- commit_signature_used(store, signature) do
      {:ok, Receipt.new(method: "solana", reference: signature, external_id: charge.external_id)}
    end
  end

  # --- transaction (pull) ---

  defp verify_transaction_credential(payload, charge, config) do
    store = Store.resolve(config["store"])
    wait? = config["wait_for_confirmation"] != false

    with {:ok, tx} <- extract_transaction(payload),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Solana"),
         :ok <- require_recipient(charge),
         :ok <- verify_signatures(tx, config),
         :ok <- Instructions.verify_compiled(tx, charge, instruction_opts(charge, config)),
         {:ok, tx} <- maybe_cosign_fee_payer(tx, config),
         {:ok, signature} <- transaction_signature(tx),
         :ok <- check_signature_unused(store, signature),
         :ok <- simulate_transaction(tx, rpc_url, config),
         {:ok, signature} <- broadcast_transaction(tx, rpc_url, config, wait?),
         :ok <- maybe_verify_confirmed(signature, charge, config, rpc_url, wait?),
         :ok <- commit_signature_used(store, signature) do
      {:ok, Receipt.new(method: "solana", reference: signature, external_id: charge.external_id)}
    end
  end

  # --- confidential bundle ---

  defp verify_bundle_credential(payload, charge, config) do
    store = Store.resolve(config["store"])
    max_transactions = config["max_bundle_transactions"] || @default_max_bundle_transactions

    with {:ok, transactions} <- extract_bundle(payload, max_transactions),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Solana"),
         :ok <- require_recipient(charge),
         :ok <- verify_bundle_signatures(transactions, config),
         :ok <- Confidential.verify_bundle(transactions, charge, max_transactions, instruction_opts(charge, config)),
         {:ok, transactions} <- cosign_bundle(transactions, config),
         {:ok, signature} <- transactions |> List.last() |> transaction_signature(),
         :ok <- check_signature_unused(store, signature),
         {:ok, previous} <- Confidential.fetch_snapshot(charge, rpc_opts(rpc_url, config)),
         {:ok, ^signature} <- settle_bundle(transactions, rpc_url, config),
         {:ok, confirmed} <- fetch_transaction(signature, rpc_url, config),
         :ok <- Confidential.verify_confirmed(confirmed),
         {:ok, current} <- Confidential.fetch_snapshot(charge, rpc_opts(rpc_url, config)),
         :ok <- Confidential.verify_amount(previous, current, charge.amount, config["recipient_elgamal_secret_key"]),
         :ok <- commit_signature_used(store, signature) do
      {:ok,
       Receipt.new(
         method: "solana",
         reference: signature,
         external_id: charge.external_id,
         extensions: %{"delivery" => "pending"}
       )}
    end
  end

  defp extract_bundle(%{"transactions" => transactions}, max_transactions)
       when is_list(transactions) and transactions != [] and length(transactions) <= max_transactions do
    transactions
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, decoded} ->
      case extract_transaction(%{"transaction" => encoded}) do
        {:ok, transaction} -> {:cont, {:ok, [transaction | decoded]}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, transactions} -> {:ok, Enum.reverse(transactions)}
      {:error, _error} = failure -> failure
    end
  end

  defp extract_bundle(_payload, _max_transactions) do
    {:error, Errors.new(:invalid_payload, "Missing, empty, or oversized 'transactions' field in bundle payload")}
  end

  defp verify_bundle_signatures(transactions, config) do
    Enum.reduce_while(transactions, :ok, fn transaction, :ok ->
      case verify_signatures(transaction, config) do
        :ok -> {:cont, :ok}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
  end

  defp cosign_bundle(transactions, config) do
    transactions
    |> Enum.reduce_while({:ok, []}, fn transaction, {:ok, signed} ->
      case maybe_cosign_fee_payer(transaction, config) do
        {:ok, transaction} -> {:cont, {:ok, [transaction | signed]}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, transactions} -> {:ok, Enum.reverse(transactions)}
      {:error, _error} = failure -> failure
    end
  end

  defp settle_bundle(transactions, rpc_url, config) do
    Enum.reduce_while(transactions, {:ok, nil}, fn transaction, {:ok, _last_signature} ->
      with :ok <- simulate_transaction(transaction, rpc_url, config),
           {:ok, signature} <- broadcast_transaction(transaction, rpc_url, config, true) do
        {:cont, {:ok, signature}}
      else
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
  end

  defp extract_transaction(%{"transaction" => encoded}) when is_binary(encoded) do
    with {:ok, bytes} <- decode_base64_tx(encoded),
         :ok <- check_tx_size(bytes) do
      deserialize_tx(bytes)
    end
  end

  defp extract_transaction(_payload) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'transaction' field in credential payload")}
  end

  defp decode_base64_tx(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, Errors.new(:invalid_payload, "Transaction is not valid base64")}
    end
  end

  defp check_tx_size(bytes) when byte_size(bytes) <= @max_tx_bytes, do: :ok

  defp check_tx_size(_bytes) do
    {:error, Errors.new(:invalid_payload, "Transaction exceeds the 1232-byte Solana size limit")}
  end

  defp deserialize_tx(bytes) do
    case Transaction.deserialize(bytes) do
      {:ok, tx} -> {:ok, tx}
      {:error, _reason} -> {:error, Errors.new(:invalid_payload, "Transaction could not be deserialized")}
    end
  end

  defp extract_signature(%{"signature" => signature}) when is_binary(signature) do
    case Cartouche.Base58.decode(signature) do
      {:ok, <<_::binary-size(@signature_bytes)>>} ->
        {:ok, signature}

      _other ->
        {:error, Errors.new(:invalid_payload, "Invalid transaction signature format")}
    end
  end

  defp extract_signature(_payload) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'signature' field in credential payload")}
  end

  defp verify_signatures(%Transaction{} = tx, config) do
    fee_payer? = fee_payer_enabled?(config)
    msg_bytes = Transaction.serialize_message(tx.message)
    keys = tx.message.account_keys
    required = tx.message.header.num_required_signatures

    cond do
      required < 1 or keys == [] ->
        {:error, Errors.new(:verification_failed, "Transaction is missing a fee payer")}

      length(tx.signatures) != required ->
        {:error, Errors.new(:verification_failed, "Transaction signature count does not match the message header")}

      fee_payer? and hd(keys) != fee_payer_pubkey!(config) ->
        {:error, Errors.new(:verification_failed, "Transaction fee payer does not match feePayerKey")}

      true ->
        tx.signatures
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {signature, index}, :ok ->
          check_one_signature(signature, index, keys, msg_bytes, fee_payer?)
        end)
    end
  end

  defp check_one_signature(signature, 0, _keys, _msg_bytes, true) do
    if signature == @empty_signature do
      {:cont, :ok}
    else
      {:halt, {:error, Errors.new(:verification_failed, "Fee payer signature slot must be empty before co-signing")}}
    end
  end

  defp check_one_signature(@empty_signature, _index, _keys, _msg_bytes, _fee_payer?) do
    {:halt, {:error, Errors.new(:verification_failed, "Transaction is missing a required signature")}}
  end

  defp check_one_signature(signature, index, keys, msg_bytes, _fee_payer?) do
    pubkey = Enum.at(keys, index)

    if is_binary(pubkey) and :crypto.verify(:eddsa, :none, msg_bytes, signature, [pubkey, :ed25519]) do
      {:cont, :ok}
    else
      {:halt, {:error, Errors.new(:verification_failed, "Invalid transaction signature")}}
    end
  end

  defp maybe_cosign_fee_payer(tx, config) do
    if fee_payer_enabled?(config) do
      with {:ok, seed} <- decode_fee_payer_seed(config["fee_payer_private_key"]) do
        msg_bytes = Transaction.serialize_message(tx.message)
        signature = :crypto.sign(:eddsa, :none, msg_bytes, [seed, :ed25519])
        {:ok, Transaction.add_signature(tx, 0, signature)}
      end
    else
      {:ok, tx}
    end
  end

  defp transaction_signature(%Transaction{signatures: [signature | _]}) do
    if signature == @empty_signature do
      {:error, Errors.new(:verification_failed, "Transaction is missing a required signature")}
    else
      {:ok, Cartouche.Base58.encode(signature)}
    end
  end

  defp transaction_signature(_tx) do
    {:error, Errors.new(:verification_failed, "Transaction is missing a required signature")}
  end

  defp simulate_transaction(tx, rpc_url, config) do
    case RPC.simulate_transaction(tx, rpc_opts(rpc_url, config, sig_verify: true)) do
      {:ok, %{err: nil}} ->
        :ok

      {:ok, %{err: err}} ->
        Logger.warning("MPP.Methods.Solana: simulation rejected: #{inspect(err)}")
        {:error, Errors.new(:verification_failed, "Pre-broadcast simulation rejected the transaction")}

      {:error, reason} ->
        Logger.warning("MPP.Methods.Solana: simulateTransaction failed: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, @solana_rpc_error_detail)}
    end
  end

  defp broadcast_transaction(tx, rpc_url, config, true) do
    case RPC.send_and_confirm(tx, rpc_opts(rpc_url, config, commitment: :confirmed)) do
      {:ok, signature} ->
        {:ok, signature}

      {:error, {:transaction_error, reason}} ->
        Logger.warning("MPP.Methods.Solana: transaction error: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, "Transaction failed on-chain")}

      {:error, :timeout} ->
        {:error, Errors.new(:verification_failed, "Timed out waiting for transaction confirmation")}

      {:error, reason} ->
        Logger.warning("MPP.Methods.Solana: sendTransaction failed: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, @solana_rpc_error_detail)}
    end
  end

  defp broadcast_transaction(tx, rpc_url, config, false) do
    case RPC.send_transaction(tx, rpc_opts(rpc_url, config)) do
      {:ok, signature} ->
        {:ok, signature}

      {:error, reason} ->
        Logger.warning("MPP.Methods.Solana: sendTransaction failed: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, @solana_rpc_error_detail)}
    end
  end

  defp maybe_verify_confirmed(_signature, _charge, _config, _rpc_url, false), do: :ok

  defp maybe_verify_confirmed(signature, charge, config, rpc_url, true) do
    with {:ok, rpc_tx} <- fetch_transaction(signature, rpc_url, config) do
      Instructions.verify_parsed(rpc_tx, charge, instruction_opts(charge, config))
    end
  end

  defp fetch_transaction(signature, rpc_url, config) do
    opts = rpc_opts(rpc_url, config, encoding: :json_parsed, commitment: :confirmed)

    case RPC.get_transaction(signature, opts) do
      {:ok, nil} ->
        {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}

      {:ok, rpc_tx} when is_map(rpc_tx) ->
        {:ok, rpc_tx}

      {:error, reason} ->
        Logger.warning("MPP.Methods.Solana: getTransaction failed: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, @solana_rpc_error_detail)}
    end
  end

  # --- challenge details ---

  defp maybe_put_decimals(details, %Charge{currency: currency}, config) do
    if native_sol?(currency) do
      details
    else
      case config["decimals"] do
        decimals when is_integer(decimals) and decimals >= 0 and decimals <= 9 ->
          Map.put(details, "decimals", decimals)

        _other ->
          details
      end
    end
  end

  defp maybe_put_token_program(details, %Charge{currency: currency}, config) do
    program = config["token_program"] || config["tokenProgram"]

    if native_sol?(currency) or !is_binary(program) do
      details
    else
      Map.put(details, "tokenProgram", program)
    end
  end

  defp maybe_put_fee_payer_key(details, _config, false), do: details

  defp maybe_put_fee_payer_key(details, config, true) do
    case fee_payer_key(config) do
      {:ok, key} -> Map.put(details, "feePayerKey", key)
      :error -> details
    end
  end

  defp maybe_put_splits(details, %{"splits" => splits}) when is_list(splits) do
    Map.put(details, "splits", splits)
  end

  defp maybe_put_splits(details, _config), do: details

  defp maybe_put_confidential(details, %{"confidential" => true}), do: Map.put(details, "confidential", true)

  defp maybe_put_confidential(details, _config), do: details

  # --- config / keys ---

  defp network(%{"network" => network}) when network in @networks, do: network
  defp network(_config), do: "mainnet"

  defp fee_payer_enabled?(%{"fee_payer" => true}), do: true
  defp fee_payer_enabled?(%{"feePayer" => true}), do: true
  defp fee_payer_enabled?(_config), do: false

  defp challenge_credential_types(config) do
    if Confidential.enabled?(config), do: ["bundle"], else: ~w(transaction signature)
  end

  defp reject_non_bundle_when_confidential(config) do
    if Confidential.enabled?(config) do
      {:error, Errors.new(:invalid_payload, ~s(type="bundle" is required when confidential is true))}
    else
      :ok
    end
  end

  defp require_confidential(config) do
    if Confidential.enabled?(config) do
      :ok
    else
      {:error, Errors.new(:invalid_payload, ~s(type="bundle" is allowed only when confidential is true))}
    end
  end

  defp reject_signature_when_fee_payer(config) do
    if fee_payer_enabled?(config) do
      {:error, Errors.new(:invalid_payload, ~s(type="signature" is not allowed when feePayer is true))}
    else
      :ok
    end
  end

  defp reject_zero_amount(%Charge{amount: "0"}) do
    {:error, Errors.new(:verification_failed, @zero_amount_detail)}
  end

  defp reject_zero_amount(_charge), do: :ok

  defp require_recipient(%Charge{recipient: recipient}) when is_binary(recipient), do: :ok

  defp require_recipient(_charge) do
    {:error, Errors.new(:verification_failed, "Solana method requires a recipient address")}
  end

  defp native_sol?(currency) when is_binary(currency), do: String.downcase(currency) == "sol"

  defp instruction_opts(charge, config) do
    fee_payer? = fee_payer_enabled?(config)

    %{
      fee_payer: fee_payer?,
      fee_payer_pubkey: if(fee_payer?, do: fee_payer_pubkey!(config)),
      max_compute_unit_limit: config["max_compute_unit_limit"],
      max_compute_unit_price: config["max_compute_unit_price"],
      mint: spl_mint(charge),
      token_program: token_program_key(charge, config)
    }
  end

  defp spl_mint(%Charge{currency: currency} = _charge) do
    if native_sol?(currency) do
      nil
    else
      case Cartouche.Base58.decode(currency) do
        {:ok, <<mint::binary-32>>} -> mint
        _other -> nil
      end
    end
  end

  defp token_program_key(_charge, config) do
    program = config["token_program"] || config["tokenProgram"]

    case program do
      value when is_binary(value) ->
        case Cartouche.Base58.decode(value) do
          {:ok, <<key::binary-32>>} -> key
          _other -> Programs.token_program()
        end

      _other ->
        Programs.token_program()
    end
  end

  defp fee_payer_key(config) do
    cond do
      is_binary(config["fee_payer_key"]) ->
        {:ok, config["fee_payer_key"]}

      is_binary(config["feePayerKey"]) ->
        {:ok, config["feePayerKey"]}

      is_binary(config["fee_payer_private_key"]) ->
        case decode_fee_payer_seed(config["fee_payer_private_key"]) do
          {:ok, seed} ->
            {pub, ^seed} = Keys.from_seed(seed)
            {:ok, Keys.to_address(pub)}

          {:error, _reason} ->
            :error
        end

      true ->
        :error
    end
  end

  defp fee_payer_pubkey!(config) do
    case fee_payer_key(config) do
      {:ok, address} ->
        case Cartouche.Base58.decode(address) do
          {:ok, <<key::binary-32>>} -> key
          _other -> <<0::256>>
        end

      :error ->
        <<0::256>>
    end
  end

  defp decode_fee_payer_seed(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      String.starts_with?(trimmed, "[") ->
        case Keys.from_json(trimmed) do
          {:ok, {_pub, seed}} -> {:ok, seed}
          {:error, _reason} -> {:error, Errors.new(:verification_failed, "Invalid fee_payer_private_key")}
        end

      hex_seed?(trimmed) ->
        decode_hex_seed(trimmed)

      true ->
        decode_base58_seed(trimmed)
    end
  end

  defp decode_fee_payer_seed(_key) do
    {:error, Errors.new(:verification_failed, "Missing fee_payer_private_key")}
  end

  defp hex_seed?(value) do
    hex = Hex.strip_0x(value)
    Hex.hex_string?(hex) and byte_size(hex) in [64, 128]
  end

  defp decode_hex_seed(value) do
    case Base.decode16(Hex.strip_0x(value), case: :mixed) do
      {:ok, <<seed::binary-32>>} -> {:ok, seed}
      {:ok, <<seed::binary-32, _pub::binary-32>>} -> {:ok, seed}
      _other -> {:error, Errors.new(:verification_failed, "Invalid fee_payer_private_key")}
    end
  end

  defp decode_base58_seed(value) do
    case Cartouche.Base58.decode(value) do
      {:ok, <<seed::binary-32>>} -> {:ok, seed}
      {:ok, <<seed::binary-32, _pub::binary-32>>} -> {:ok, seed}
      _other -> {:error, Errors.new(:verification_failed, "Invalid fee_payer_private_key")}
    end
  end

  defp rpc_opts(rpc_url, config, extra \\ []) do
    timeout = config["confirmation_timeout"] || 30_000
    opts = Keyword.merge([solana_node: rpc_url, commitment: :confirmed, timeout: timeout], extra)

    case config["req_options"] do
      req_options when is_list(req_options) -> Keyword.put(opts, :req_options, req_options)
      _other -> opts
    end
  end

  # --- validate_config! ---

  defp validate_network!(nil), do: :ok

  defp validate_network!(network) when network in @networks, do: :ok

  defp validate_network!(network) do
    raise ArgumentError,
          "MPP.Methods.Solana network must be one of #{Enum.join(@networks, ", ")}; got: #{inspect(network)}"
  end

  defp validate_fee_payer!(config) do
    if fee_payer_enabled?(config) do
      case decode_fee_payer_seed(config["fee_payer_private_key"]) do
        {:ok, _seed} ->
          :ok

        {:error, _reason} ->
          raise ArgumentError,
                "MPP.Methods.Solana fee_payer requires \"fee_payer_private_key\" (Ed25519 seed) in method_config"
      end
    else
      :ok
    end
  end

  # --- replay ---

  defp check_signature_unused(nil, _signature), do: :ok

  defp check_signature_unused(store, signature) do
    case Store.get(store, store_key(signature)) do
      :not_found -> :ok
      {:ok, _} -> {:error, Errors.new(:verification_failed, "Transaction signature already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  defp commit_signature_used(nil, _signature), do: :ok

  defp commit_signature_used(store, signature) do
    case Store.check_and_mark(store, store_key(signature), System.system_time(:millisecond)) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Transaction signature already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  defp store_key(signature), do: @store_key_prefix <> signature

  defp validate_store!(nil), do: :ok
  defp validate_store!(false), do: :ok

  defp validate_store!({ConCacheStore, opts}) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError,
            "MPP.Methods.Solana :store opts for {MPP.Tempo.ConCacheStore, opts} must be a keyword list; got: #{inspect(opts)}"
    end

    validate_store!(ConCacheStore)
  end

  defp validate_store!(ConCacheStore), do: :ok

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Methods.Solana :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !Store.dedup_capable?(store) do
      raise ArgumentError,
            "MPP.Methods.Solana :store must be a module implementing MPP.Tempo.Store " <>
              "(get/1, put/2, check_and_mark/2 — atomic single-use is required; use `store: false` to disable dedup)"
    end

    :ok
  end
end
