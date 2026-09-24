defmodule MPP.Methods.USDC.Solana do
  @moduledoc """
  Direct USDC charge on Solana.

  v00 accepts the legacy SPL Token program and a `type="transaction"`
  credential. Broadcast, fee-payer co-signing, simulation, and signature
  replay reuse `MPP.Methods.Solana`. This module adds the USDC mint,
  token-program, freeze, and instruction limits from `draft-usdc-charge-00`.
  """

  @behaviour MPP.Methods.USDC.Profile

  use Cartouche.Base58

  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.RPC
  alias Cartouche.Solana.Transaction
  alias Cartouche.Solana.Transaction.CompiledInstruction
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Methods.Solana, as: SolanaMethod
  alias MPP.Methods.USDC.Assets
  alias MPP.Methods.USDC.Binding
  alias MPP.Methods.USDC.Replay
  alias MPP.Receipt
  alias MPP.Tempo.Store

  require Logger

  @token_program "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  @token_program_key ~B58[TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA]
  @networks ~w(mainnet devnet)
  @transfer_checked 12
  @mint_decimals_offset 44
  @token_owner_offset 32
  @token_state_offset 108
  # Bytes between the token-account owner and the state byte: amount, delegate option, delegate.
  @token_owner_gap 44
  @token_state_frozen 2
  @token_state_initialized 1
  @genesis %{
    "mainnet" => "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp",
    "devnet" => "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
  }

  @allowed_programs MapSet.new([
                      Programs.token_program(),
                      Programs.ata_program(),
                      Programs.compute_budget_program(),
                      ~B58[MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr],
                      ~B58[Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo]
                    ])

  @impl true
  @doc "Profile name `solana`."
  @spec name() :: String.t()
  def name, do: "solana"

  @impl true
  @doc "Pull-mode transaction payload accepted by this profile."
  @spec credential_type() :: String.t()
  def credential_type, do: "transaction"

  @impl true
  @doc "Require an RPC URL, a Solana network, and a fee-payer key when sponsoring."
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) when is_map(config) do
    cond do
      not Shared.valid_rpc_url?(config["rpc_url"]) ->
        raise ArgumentError, "MPP.Methods.USDC solana profile requires an https method_config rpc_url"

      config["network"] not in @networks ->
        raise ArgumentError,
              "MPP.Methods.USDC solana profile requires method_config network to be mainnet or devnet"

      config["fee_payer"] == true and not present?(config["fee_payer_private_key"]) ->
        raise ArgumentError, "MPP.Methods.USDC solana profile requires fee_payer_private_key when fee_payer is true"

      config["fee_payer"] == true and not present?(config["fee_payer_key"]) ->
        raise ArgumentError, "MPP.Methods.USDC solana profile requires fee_payer_key when fee_payer is true"

      true ->
        :ok
    end
  end

  @impl true
  @doc "Advertise network, decimals 6, the legacy token program, and any fee payer."
  @spec challenge_details(Charge.t()) :: map()
  def challenge_details(%Charge{} = charge) do
    config = charge.method_details || %{}
    network = config["network"]

    case Assets.solana_mint(network) do
      {:ok, mint} ->
        if charge.currency == mint do
          maybe_fee_payer(%{"decimals" => 6, "network" => network, "tokenProgram" => @token_program}, config)
        else
          raise ArgumentError,
                "MPP.Methods.USDC solana currency must be native USDC mint #{mint} for #{network}"
        end

      :error ->
        raise ArgumentError,
              "MPP.Methods.USDC has no Circle native USDC mint for solana network #{inspect(network)}"
    end
  end

  @impl true
  @doc "Verify a legacy SPL USDC transaction and return the USDC receipt."
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- Binding.require_recipient(charge),
         {:ok, profile} <- profile_object(config),
         :ok <- profile_fields(profile, config, charge),
         {:ok, bytes, _tx, transfer} <- transaction(payload, charge),
         rpc_opts = rpc_opts(config),
         {:ok, network_id} <- settlement_network(profile["network"], rpc_opts),
         :ok <- mint_controls(charge.currency, rpc_opts),
         :ok <- account_controls(transfer, charge, rpc_opts),
         {:ok, reference} <- broadcast(bytes, payload, charge, config, profile) do
      {:ok, Binding.receipt(charge, name(), reference, network_id)}
    end
  end

  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_value), do: false

  defp profile_object(config) do
    case config["solana"] do
      profile when is_map(profile) -> {:ok, profile}
      _profile -> {:error, Errors.new(:invalid_payload, "USDC solana profile object is missing")}
    end
  end

  defp profile_fields(profile, config, charge) do
    cond do
      profile["network"] not in @networks ->
        {:error, Errors.new(:invalid_payload, "USDC solana network must be mainnet or devnet")}

      is_binary(config["network"]) and config["network"] != profile["network"] ->
        {:error, Errors.new(:verification_failed, "USDC solana network does not match method config")}

      profile["decimals"] != 6 ->
        {:error, Errors.new(:invalid_payload, "USDC decimals must be 6")}

      profile["tokenProgram"] != @token_program ->
        {:error, Errors.new(:invalid_payload, "USDC tokenProgram must be the legacy SPL Token program")}

      not Assets.solana?(profile["network"], charge.currency) ->
        {:error, Errors.new(:verification_failed, "Currency is not native USDC for solana #{profile["network"]}")}

      true ->
        fee_payer_fields(profile, config)
    end
  end

  defp fee_payer_fields(profile, config) do
    cond do
      profile["feePayer"] == true and not present?(profile["feePayerKey"]) ->
        {:error, Errors.new(:invalid_payload, "USDC solana feePayerKey is required when feePayer is true")}

      profile["feePayer"] == true and not present?(config["fee_payer_private_key"]) ->
        {:error, Errors.new(:verification_failed, "USDC solana fee payer requires fee_payer_private_key")}

      profile["feePayer"] in [nil, false] and Map.has_key?(profile, "feePayerKey") ->
        {:error, Errors.new(:invalid_payload, "USDC solana feePayerKey must be absent unless feePayer is true")}

      profile["feePayer"] not in [nil, false, true] ->
        {:error, Errors.new(:invalid_payload, "USDC solana feePayer must be a boolean")}

      true ->
        :ok
    end
  end

  defp maybe_fee_payer(details, %{"fee_payer" => true, "fee_payer_key" => key}) when is_binary(key) do
    Map.merge(details, %{"feePayer" => true, "feePayerKey" => key})
  end

  defp maybe_fee_payer(details, _config), do: details

  defp transaction(payload, charge) do
    with {:ok, encoded} <- encoded_transaction(payload),
         {:ok, bytes} <- decode_transaction(encoded),
         {:ok, tx} <- deserialize(bytes),
         {:ok, transfer} <- allow_instructions(tx, charge) do
      {:ok, bytes, tx, transfer}
    end
  end

  defp encoded_transaction(%{"type" => "transaction", "transaction" => encoded}) when is_binary(encoded) do
    {:ok, encoded}
  end

  defp encoded_transaction(%{"type" => "transaction"}) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'transaction' field in credential payload")}
  end

  defp encoded_transaction(%{"type" => type}) when is_binary(type) do
    {:error, Errors.new(:invalid_payload, "USDC solana credentials require payload type transaction")}
  end

  defp encoded_transaction(_payload) do
    {:error, Errors.new(:invalid_payload, "USDC solana credentials require payload type transaction")}
  end

  defp decode_transaction(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, Errors.new(:invalid_payload, "Solana transaction is not valid base64")}
    end
  end

  defp deserialize(bytes) do
    case Transaction.deserialize(bytes) do
      {:ok, tx} -> {:ok, tx}
      {:error, _reason} -> {:error, Errors.new(:invalid_payload, "Solana transaction could not be deserialized")}
    end
  end

  defp allow_instructions(%Transaction{message: %{account_keys: keys, instructions: instructions}}, charge) do
    keys = keys |> Enum.with_index() |> Map.new(fn {key, index} -> {index, key} end)

    instructions
    |> Enum.reduce_while({:ok, []}, fn ix, {:ok, transfers} ->
      case classify(ix, keys, charge) do
        {:transfer, transfer} -> {:cont, {:ok, [transfer | transfers]}}
        :ok -> {:cont, {:ok, transfers}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
    |> one_transfer(charge)
  end

  defp classify(%CompiledInstruction{} = ix, keys, charge) do
    program = Map.get(keys, ix.program_id_index)
    accounts = Enum.map(ix.accounts, &Map.get(keys, &1))

    cond do
      program == nil or Enum.any?(accounts, &is_nil/1) ->
        {:error, Errors.new(:invalid_payload, "Solana transaction account index is out of range")}

      program == @token_program_key ->
        classify_transfer(accounts, ix.data, charge)

      MapSet.member?(@allowed_programs, program) ->
        :ok

      true ->
        {:error,
         Errors.new(:verification_failed, "Transaction contains an instruction outside the USDC Solana allow-list")}
    end
  end

  defp classify_transfer(
         [source, mint, destination, authority | _],
         <<@transfer_checked, amount::little-unsigned-64, decimals>>,
         charge
       ) do
    with {:ok, expected_mint} <- decode_key(charge.currency),
         {:ok, expected_amount} <- Shared.parse_charge_amount(charge.amount) do
      cond do
        decimals != 6 ->
          {:error, Errors.new(:verification_failed, "USDC decimals must be 6")}

        mint != expected_mint ->
          {:error, Errors.new(:verification_failed, "Solana transfer mint is not the advertised USDC mint")}

        amount != expected_amount ->
          {:error, Errors.new(:verification_failed, "Solana transfer amount does not match the charge")}

        true ->
          {:transfer, %{source: source, mint: mint, destination: destination, authority: authority}}
      end
    else
      :error -> {:error, Errors.new(:verification_failed, "Solana transfer mint is not the advertised USDC mint")}
      {:error, %Errors{}} = error -> error
    end
  end

  defp classify_transfer(_accounts, _data, _charge) do
    {:error, Errors.new(:verification_failed, "USDC Solana accepts only SPL Token transferChecked")}
  end

  defp one_transfer({:ok, [transfer]}, _charge), do: {:ok, transfer}

  defp one_transfer({:ok, _transfers}, _charge) do
    {:error, Errors.new(:verification_failed, "USDC Solana requires exactly one transferChecked instruction")}
  end

  defp one_transfer({:error, %Errors{}} = error, _charge), do: error

  defp settlement_network(network, rpc_opts) do
    with {:ok, hash} <- genesis_hash(rpc_opts) do
      caip = "solana:" <> String.slice(hash, 0, 32)

      expected = Map.fetch!(@genesis, network)

      if caip == expected do
        {:ok, caip}
      else
        {:error, Errors.new(:verification_failed, "Solana RPC genesis hash does not match network #{network}")}
      end
    end
  end

  defp genesis_hash(rpc_opts) do
    case RPC.send_rpc("getGenesisHash", [], rpc_opts) do
      {:ok, hash} when is_binary(hash) and byte_size(hash) >= 32 -> {:ok, hash}
      {:ok, _hash} -> {:error, Errors.new(:verification_failed, "Solana RPC request failed")}
      {:error, reason} -> solana_rpc_failure(reason)
    end
  end

  defp mint_controls(currency, rpc_opts) do
    with {:ok, account} <- fetch_account(currency, rpc_opts),
         :ok <- require_account(account, "USDC mint account was not found"),
         :ok <- legacy_owner(account, "Mint account is not owned by the legacy SPL Token program"),
         {:ok, data} <- account_data(account) do
      mint_initialized(data)
    end
  end

  defp mint_initialized(data) when byte_size(data) > @mint_decimals_offset + 1 do
    <<_prefix::binary-size(@mint_decimals_offset), decimals, initialized, _rest::binary>> = data

    cond do
      decimals != 6 ->
        {:error, Errors.new(:verification_failed, "USDC decimals must be 6")}

      initialized != 1 ->
        {:error, Errors.new(:verification_failed, "USDC mint is not initialized")}

      true ->
        :ok
    end
  end

  defp mint_initialized(_data) do
    {:error, Errors.new(:verification_failed, "USDC mint account is not a legacy SPL mint")}
  end

  defp account_controls(transfer, charge, rpc_opts) do
    with {:ok, source} <- fetch_account(transfer.source, rpc_opts),
         :ok <- require_account(source, "Source USDC token account was not found"),
         :ok <- legacy_owner(source, "Source token account is not a legacy SPL token account"),
         :ok <- token_account(source, transfer.authority, "Source token account is not owned by the transfer authority"),
         {:ok, destination} <- fetch_account(transfer.destination, rpc_opts) do
      destination_account(destination, charge)
    end
  end

  defp destination_account(nil, _charge), do: :ok

  defp destination_account(account, charge) do
    with :ok <- legacy_owner(account, "Recipient token account is not a legacy SPL token account"),
         {:ok, owner} <- recipient_key(charge) do
      token_account(account, owner, "Recipient token account is not owned by the charge recipient")
    end
  end

  defp recipient_key(charge) do
    case decode_key(charge.recipient) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, Errors.new(:verification_failed, "Invalid Solana recipient address")}
    end
  end

  defp token_account(account, owner, mismatch) do
    with {:ok, data} <- account_data(account) do
      token_state(data, owner, mismatch)
    end
  end

  defp token_state(data, owner, mismatch) when byte_size(data) > @token_state_offset do
    <<_mint::binary-size(@token_owner_offset), account_owner::binary-size(32), _middle::binary-size(@token_owner_gap),
      state, _rest::binary>> =
      data

    cond do
      state == @token_state_frozen ->
        {:error, Errors.new(:verification_failed, "USDC token account is frozen")}

      state != @token_state_initialized ->
        {:error, Errors.new(:verification_failed, "USDC token account is not initialized")}

      account_owner != owner ->
        {:error, Errors.new(:verification_failed, mismatch)}

      true ->
        :ok
    end
  end

  defp token_state(_data, _owner, _mismatch) do
    {:error, Errors.new(:verification_failed, "USDC token account is not a legacy SPL token account")}
  end

  defp fetch_account(key, rpc_opts) when is_binary(key) and byte_size(key) == 32 do
    case RPC.get_account_info(key, rpc_opts) do
      {:ok, account} -> {:ok, account}
      {:error, reason} -> solana_rpc_failure(reason)
    end
  end

  defp fetch_account(address, rpc_opts) when is_binary(address) do
    case decode_key(address) do
      {:ok, key} -> fetch_account(key, rpc_opts)
      :error -> {:error, Errors.new(:verification_failed, "Invalid Solana account address")}
    end
  end

  defp require_account(nil, detail), do: {:error, Errors.new(:verification_failed, detail)}
  defp require_account(_account, _detail), do: :ok

  defp legacy_owner(%{owner: @token_program}, _detail), do: :ok

  defp legacy_owner(_account, detail) do
    {:error, Errors.new(:verification_failed, detail)}
  end

  defp account_data(%{data: [encoded, "base64"]}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, Errors.new(:verification_failed, "Solana account data could not be decoded")}
    end
  end

  defp account_data(%{data: data}) when is_binary(data), do: {:ok, data}

  defp account_data(_account) do
    {:error, Errors.new(:verification_failed, "Solana account data could not be decoded")}
  end

  defp broadcast(bytes, payload, charge, config, profile) do
    store = Store.resolve(config["store"])
    digest = "solana:#{profile["network"]}:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    Replay.with_claims(store, replay_keys(charge, digest), fn ->
      case SolanaMethod.verify(payload, solana_charge(charge, config, profile)) do
        {:ok, %Receipt{reference: reference}} when is_binary(reference) -> {:ok, reference}
        {:error, %Errors{}} = error -> error
      end
    end)
  end

  defp replay_keys(charge, digest) do
    extra = [{digest, "Solana transaction already used"}]

    case Replay.order_key(charge) do
      {:ok, key} -> [{key, "USDC merchant order already settled"} | extra]
      :none -> extra
    end
  end

  defp solana_charge(charge, config, profile) do
    details =
      %{
        "confirmation_timeout" => config["confirmation_timeout"],
        "decimals" => 6,
        "max_compute_unit_limit" => config["max_compute_unit_limit"],
        "max_compute_unit_price" => config["max_compute_unit_price"],
        "network" => profile["network"],
        "req_options" => config["req_options"],
        "rpc_url" => config["rpc_url"],
        "allow_primary_ata" => true,
        "store" => config["store"],
        "token_program" => @token_program,
        "wait_for_confirmation" => config["wait_for_confirmation"]
      }
      |> fee_payer_config(config, profile)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{charge | method_details: details}
  end

  defp fee_payer_config(details, config, %{"feePayer" => true, "feePayerKey" => key}) do
    Map.merge(details, %{
      "fee_payer" => true,
      "fee_payer_key" => key,
      "fee_payer_private_key" => config["fee_payer_private_key"]
    })
  end

  defp fee_payer_config(details, _config, _profile), do: details

  defp rpc_opts(config) do
    opts = [solana_node: config["rpc_url"], commitment: :confirmed, timeout: config["confirmation_timeout"] || 30_000]

    case config["req_options"] do
      req_options when is_list(req_options) -> Keyword.put(opts, :req_options, req_options)
      _req_options -> opts
    end
  end

  defp decode_key(address) do
    case Cartouche.Base58.decode(address) do
      {:ok, <<key::binary-32>>} -> {:ok, key}
      _other -> :error
    end
  end

  defp solana_rpc_failure(reason) do
    Logger.warning("MPP.Methods.USDC.Solana: RPC request failed: #{inspect(reason)}")
    {:error, Errors.new(:verification_failed, "Solana RPC request failed")}
  end
end
