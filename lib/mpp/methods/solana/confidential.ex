defmodule MPP.Methods.Solana.Confidential do
  @moduledoc false

  use Cartouche.Base58

  import Bitwise

  alias Cartouche.Solana.ATA
  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.RPC
  alias Cartouche.Solana.Transaction
  alias Cartouche.Solana.Transaction.CompiledInstruction
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Methods.Solana.Instructions
  alias MPP.Methods.Solana.Ristretto255

  @token_2022_address "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
  @zk_proof_program ~B58[ZkE1Gama1Proof11111111111111111111111111111]
  @record_program ~B58[recr1L3PCGKLbckBqMNcJhuuyU1zgo8nBhfLVsJNwr5]
  @memo_program ~B58[MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr]
  @memo_v1_program ~B58[Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo]
  @instructions_sysvar ~B58[Sysvar1nstructions1111111111111111111111111]
  @system_program <<0::256>>
  @token_2022_program ~B58[TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb]
  @compute_budget_program ~B58[ComputeBudget111111111111111111111111111111]

  @token_account_length 165
  @account_type_length 1
  @confidential_account_extension 5
  @confidential_account_min_length 161
  @pending_low_bits 16
  @maximum_amount (1 <<< 48) - 1
  @confidential_transfer_prefix 27
  @transfer_instruction 7
  @transfer_with_fee_instruction 13
  @close_context_instruction 0
  @record_close_instruction 3
  @system_create_account_instruction 0

  @type snapshot :: %{
          elgamal_pubkey: binary(),
          pending_low: Ristretto255.ciphertext(),
          pending_high: Ristretto255.ciphertext()
        }

  @doc false
  @spec enabled?(map()) :: boolean()
  def enabled?(%{"confidential" => true}), do: true
  def enabled?(_config), do: false

  @doc false
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    if enabled?(config) do
      validate_confidential_config!(config)
    else
      :ok
    end
  end

  @doc false
  @spec validate_charge!(Charge.t(), map()) :: :ok
  def validate_charge!(%Charge{} = charge, config) do
    if enabled?(config) do
      validate_confidential_charge!(charge, config)
    else
      :ok
    end
  end

  @doc false
  @spec verify_bundle([Transaction.t()], Charge.t(), pos_integer()) :: :ok | {:error, Errors.t()}
  def verify_bundle(transactions, %Charge{} = charge, max_transactions) do
    verify_bundle(transactions, charge, max_transactions, %{})
  end

  @doc false
  @spec verify_bundle([Transaction.t()], Charge.t(), pos_integer(), map()) :: :ok | {:error, Errors.t()}
  def verify_bundle(transactions, %Charge{} = charge, max_transactions, opts)
      when is_list(transactions) and is_integer(max_transactions) do
    with :ok <- validate_bundle_length(transactions, max_transactions),
         :ok <- validate_compute_budgets(transactions, opts),
         {:ok, mint, destination} <- payment_accounts(charge),
         {:ok, state} <- inspect_transactions(transactions, mint, destination) do
      validate_bundle_state(state, length(transactions))
    end
  end

  @doc false
  @spec fetch_snapshot(Charge.t(), keyword()) :: {:ok, snapshot()} | {:error, Errors.t()}
  def fetch_snapshot(%Charge{} = charge, rpc_opts) when is_list(rpc_opts) do
    with {:ok, _mint, destination} <- payment_accounts(charge) do
      case RPC.get_account_info(destination, Keyword.put(rpc_opts, :encoding, :base64)) do
        {:ok, nil} ->
          error("Recipient confidential token account was not found")

        {:ok, account} ->
          parse_snapshot(account)

        {:error, _reason} ->
          error("Solana RPC request failed")
      end
    end
  end

  @doc false
  @spec parse_snapshot(map()) :: {:ok, snapshot()} | {:error, Errors.t()}
  def parse_snapshot(%{owner: @token_2022_address, data: [encoded, "base64"]}) when is_binary(encoded) do
    with {:ok, data} <- Base.decode64(encoded),
         {:ok, extension} <- find_confidential_extension(data),
         {:ok, snapshot} <- decode_confidential_extension(extension) do
      {:ok, snapshot}
    else
      _error -> error("Invalid recipient confidential token account")
    end
  end

  def parse_snapshot(_account), do: error("Recipient account is not a Token-2022 confidential token account")

  @doc false
  @spec verify_confirmed(map()) :: :ok | {:error, Errors.t()}
  def verify_confirmed(%{"meta" => %{"err" => nil}}), do: :ok
  def verify_confirmed(%{meta: %{err: nil}}), do: :ok
  def verify_confirmed(_transaction), do: error("Final confidential transfer failed on-chain")

  @doc false
  @spec verify_amount(snapshot(), snapshot(), String.t(), String.t()) :: :ok | {:error, Errors.t()}
  def verify_amount(previous, current, amount, encoded_secret) do
    with {:ok, amount} <- parse_confidential_amount(amount),
         {:ok, secret} <- decode_secret(encoded_secret),
         true <- previous.elgamal_pubkey == current.elgamal_pubkey,
         true <- Ristretto255.delta_matches?(previous.pending_low, current.pending_low, amount &&& 0xFFFF, secret),
         true <-
           Ristretto255.delta_matches?(
             previous.pending_high,
             current.pending_high,
             amount >>> @pending_low_bits,
             secret
           ) do
      :ok
    else
      _error -> error("Confidential transfer amount did not match the recipient account balance delta")
    end
  end

  defp validate_confidential_config!(config) do
    program = config["token_program"] || config["tokenProgram"]

    cond do
      Map.has_key?(config, "splits") ->
        raise ArgumentError, "MPP.Methods.Solana confidential transfers do not allow splits"

      program != @token_2022_address ->
        raise ArgumentError,
              "MPP.Methods.Solana confidential transfers require token_program #{@token_2022_address}"

      !valid_secret?(config["recipient_elgamal_secret_key"]) ->
        raise ArgumentError,
              "MPP.Methods.Solana confidential transfers require a base64 recipient_elgamal_secret_key"

      !valid_max_transactions?(config["max_bundle_transactions"]) ->
        raise ArgumentError, "MPP.Methods.Solana max_bundle_transactions must be a positive integer"

      true ->
        :ok
    end
  end

  defp validate_confidential_charge!(%Charge{currency: currency}, _config)
       when is_binary(currency) and currency in ["sol", "SOL"] do
    raise ArgumentError, "MPP.Methods.Solana confidential transfers require a Token-2022 mint, not SOL"
  end

  defp validate_confidential_charge!(%Charge{currency: currency, recipient: recipient}, config) do
    with {:ok, <<_::binary-32>>} <- Cartouche.Base58.decode(currency),
         {:ok, <<_::binary-32>>} <- Cartouche.Base58.decode(recipient),
         decimals when is_integer(decimals) and decimals in 0..9 <- config["decimals"] do
      :ok
    else
      _error ->
        raise ArgumentError,
              "MPP.Methods.Solana confidential transfers require a base58 mint, recipient, and decimals from 0 to 9"
    end
  end

  defp valid_secret?(encoded) do
    match?({:ok, _scalar}, decode_secret(encoded))
  end

  defp decode_secret(encoded) when is_binary(encoded) do
    with {:ok, bytes} <- Base.decode64(encoded), do: Ristretto255.decode_scalar(bytes)
  end

  defp decode_secret(_encoded), do: :error

  defp valid_max_transactions?(nil), do: true
  defp valid_max_transactions?(value), do: is_integer(value) and value > 0

  defp validate_bundle_length([], _max), do: error("Confidential bundle must contain at least one transaction")

  defp validate_bundle_length(transactions, max) when max > 0 and length(transactions) <= max, do: :ok

  defp validate_bundle_length(_transactions, _max), do: error("Confidential bundle exceeds max_bundle_transactions")

  defp validate_compute_budgets(transactions, opts) do
    Enum.reduce_while(transactions, :ok, fn transaction, :ok ->
      with {:ok, classified} <- Instructions.classify_compiled(transaction),
           :ok <- Instructions.verify_compute_budget(classified, opts) do
        {:cont, :ok}
      else
        {:error, %Errors{} = failure} -> {:halt, {:error, failure}}
        {:error, _reason} -> {:halt, error("Confidential bundle contains an invalid account index")}
      end
    end)
  end

  defp payment_accounts(%Charge{currency: currency, recipient: recipient}) do
    with {:ok, <<mint::binary-32>>} <- Cartouche.Base58.decode(currency),
         {:ok, <<owner::binary-32>>} <- Cartouche.Base58.decode(recipient) do
      {destination, _bump} = ATA.find_address(owner, mint, token_program: Programs.token_2022_program())
      {:ok, mint, destination}
    else
      _error -> error("Invalid confidential mint or recipient address")
    end
  end

  defp inspect_transactions(transactions, mint, destination) do
    initial = %{
      payer: nil,
      contexts: MapSet.new(),
      verified_contexts: MapSet.new(),
      closed_contexts: MapSet.new(),
      records: MapSet.new(),
      closed_records: MapSet.new(),
      transfer_count: 0,
      transfer_transaction: nil
    }

    transactions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, initial}, fn {transaction, transaction_index}, {:ok, state} ->
      case inspect_transaction(transaction, transaction_index, state, mint, destination) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
  end

  defp inspect_transaction(%Transaction{message: message}, transaction_index, state, mint, destination) do
    with [payer | _keys] <- message.account_keys,
         :ok <- same_payer(state.payer, payer),
         state = %{state | payer: payer},
         {:ok, state} <-
           inspect_instructions(
             message.instructions,
             message.account_keys,
             transaction_index,
             state,
             mint,
             destination
           ) do
      {:ok, state}
    else
      [] -> error("Confidential bundle transaction is missing a fee payer")
      {:error, _error} = failure -> failure
    end
  end

  defp inspect_instructions(instructions, keys, transaction_index, state, mint, destination) do
    Enum.reduce_while(instructions, {:ok, state}, fn instruction, {:ok, current} ->
      case inspect_instruction(instruction, keys, transaction_index, current, mint, destination) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
  end

  defp inspect_instruction(%CompiledInstruction{} = instruction, keys, transaction_index, state, mint, destination) do
    with {:ok, program} <- at_index(keys, instruction.program_id_index),
         {:ok, accounts} <- resolve_accounts(keys, instruction.accounts) do
      classify_instruction(program, accounts, instruction.data, transaction_index, state, mint, destination)
    else
      _error -> error("Confidential bundle contains an invalid account index")
    end
  end

  defp classify_instruction(program, _accounts, _data, _index, state, _mint, _destination)
       when program in [@memo_program, @memo_v1_program], do: {:ok, state}

  defp classify_instruction(program, _accounts, _data, _index, state, _mint, _destination)
       when program == @compute_budget_program, do: {:ok, state}

  defp classify_instruction(program, accounts, data, _index, state, _mint, _destination) when program == @system_program,
    do: inspect_system_create(accounts, data, state)

  defp classify_instruction(@zk_proof_program, accounts, data, _index, state, _mint, _destination),
    do: inspect_proof(accounts, data, state)

  defp classify_instruction(@record_program, accounts, data, _index, state, _mint, _destination),
    do: inspect_record(accounts, data, state)

  defp classify_instruction(program, accounts, data, index, state, mint, destination) when program == @token_2022_program,
    do: inspect_transfer(accounts, data, index, state, mint, destination)

  defp classify_instruction(_program, _accounts, _data, _index, _state, _mint, _destination),
    do: error("Confidential bundle contains a disallowed instruction")

  defp inspect_system_create(
         [payer, account | _accounts],
         <<@system_create_account_instruction::little-32, _lamports::little-64, _space::little-64, owner::binary-32>>,
         state
       ) do
    cond do
      state.transfer_count > 0 ->
        error("Confidential proof accounts must be created before the transfer")

      payer != state.payer and !is_nil(state.payer) ->
        error("Confidential proof account funder must be the bundle fee payer")

      owner == @zk_proof_program ->
        {:ok, %{state | contexts: MapSet.put(state.contexts, account)}}

      owner == @record_program ->
        {:ok, %{state | records: MapSet.put(state.records, account)}}

      true ->
        error("Confidential bundle may create only proof context or proof record accounts")
    end
  end

  defp inspect_system_create(_accounts, _data, _state),
    do: error("Confidential bundle contains a disallowed System Program instruction")

  defp inspect_proof([context, destination, authority | _accounts], <<@close_context_instruction>>, state) do
    cond do
      state.transfer_count == 0 ->
        error("Confidential proof contexts cannot close before the transfer")

      destination != state.payer or authority != state.payer ->
        error("Confidential proof context rent must return to its owner")

      !MapSet.member?(state.contexts, context) ->
        error("Confidential bundle closes an unknown proof context")

      true ->
        {:ok, %{state | closed_contexts: MapSet.put(state.closed_contexts, context)}}
    end
  end

  defp inspect_proof(accounts, <<proof_instruction, _rest::binary>>, state) when proof_instruction > 0 do
    with :ok <- reject_after_transfer(state),
         {:ok, context} <- proof_context(accounts, state),
         :ok <- proof_owner_matches(accounts, context, state.payer) do
      {:ok, %{state | verified_contexts: MapSet.put(state.verified_contexts, context)}}
    end
  end

  defp inspect_proof(_accounts, _data, _state), do: error("Confidential bundle contains an invalid ZK proof instruction")

  defp proof_context(accounts, state) do
    accounts
    |> Enum.filter(&MapSet.member?(state.contexts, &1))
    |> case do
      [context] -> {:ok, context}
      _other -> error("ZK proof instruction must initialize exactly one proof context")
    end
  end

  defp proof_owner_matches(accounts, context, payer) do
    context_index = Enum.find_index(accounts, &(&1 == context))

    if Enum.at(accounts, context_index + 1) == payer,
      do: :ok,
      else: error("ZK proof context owner must be the bundle fee payer")
  end

  defp inspect_record([record, authority | _accounts], <<tag, _rest::binary>>, state) when tag in [0, 1, 4] do
    with :ok <- reject_after_transfer(state),
         true <- MapSet.member?(state.records, record),
         true <- authority == state.payer do
      {:ok, state}
    else
      _error -> error("Proof record must be owned by the bundle fee payer")
    end
  end

  defp inspect_record([record, authority, receiver | _accounts], <<@record_close_instruction>>, state) do
    cond do
      !MapSet.member?(state.records, record) -> error("Confidential bundle closes an unknown proof record")
      authority != state.payer or receiver != state.payer -> error("Proof record rent must return to its owner")
      true -> {:ok, %{state | closed_records: MapSet.put(state.closed_records, record)}}
    end
  end

  defp inspect_record(_accounts, _data, _state),
    do: error("Confidential bundle contains an invalid proof record instruction")

  defp inspect_transfer(
         accounts,
         <<@confidential_transfer_prefix, instruction, _rest::binary>>,
         transaction_index,
         state,
         mint,
         destination
       )
       when instruction in [@transfer_instruction, @transfer_with_fee_instruction] do
    required_contexts = if instruction == @transfer_instruction, do: 3, else: 5

    with [source, ^mint, ^destination | remaining] <- accounts,
         true <- source != destination,
         true <- state.transfer_count == 0,
         true <- context_count(remaining, state.verified_contexts) == required_contexts do
      {:ok, %{state | transfer_count: 1, transfer_transaction: transaction_index}}
    else
      _error -> error("Confidential transfer does not match the challenged mint, recipient, or proof contexts")
    end
  end

  defp inspect_transfer(_accounts, _data, _index, _state, _mint, _destination),
    do: error("Confidential bundle contains a disallowed Token-2022 instruction")

  defp context_count(accounts, contexts) do
    accounts
    |> Enum.reject(&(&1 == @instructions_sysvar))
    |> Enum.count(&MapSet.member?(contexts, &1))
  end

  defp validate_bundle_state(state, transaction_count) do
    cond do
      state.transfer_count != 1 ->
        error("Confidential bundle must contain exactly one transfer")

      state.transfer_transaction != transaction_count - 1 ->
        error("Confidential transfer must be in the final bundle transaction")

      state.contexts != state.verified_contexts ->
        error("Every proof context must be initialized by a ZK proof")

      state.contexts != state.closed_contexts ->
        error("Every proof context must close after the transfer")

      state.records != state.closed_records ->
        error("Every proof record account must be closed")

      true ->
        :ok
    end
  end

  defp same_payer(nil, _payer), do: :ok
  defp same_payer(payer, payer), do: :ok
  defp same_payer(_expected, _actual), do: error("Every confidential bundle transaction must use the same fee payer")

  defp reject_after_transfer(%{transfer_count: 0}), do: :ok
  defp reject_after_transfer(_state), do: error("Confidential proof setup must precede the transfer")

  defp at_index(items, index) when is_integer(index), do: Enum.fetch(items, index)

  defp resolve_accounts(keys, indices) do
    indices
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, accounts} ->
      case at_index(keys, index) do
        {:ok, account} -> {:cont, {:ok, [account | accounts]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, accounts} -> {:ok, Enum.reverse(accounts)}
      :error -> :error
    end
  end

  defp find_confidential_extension(data) when byte_size(data) > @token_account_length + @account_type_length do
    tlv =
      binary_part(
        data,
        @token_account_length + @account_type_length,
        byte_size(data) - @token_account_length - @account_type_length
      )

    find_tlv(tlv)
  end

  defp find_confidential_extension(_data), do: :error

  defp find_tlv(<<@confidential_account_extension::little-16, length::little-16, rest::binary>>)
       when byte_size(rest) >= length, do: {:ok, binary_part(rest, 0, length)}

  defp find_tlv(<<0::little-16, _rest::binary>>), do: :error

  defp find_tlv(<<_type::little-16, length::little-16, rest::binary>>) when byte_size(rest) >= length do
    next_offset = length
    find_tlv(binary_part(rest, next_offset, byte_size(rest) - next_offset))
  end

  defp find_tlv(_data), do: :error

  defp decode_confidential_extension(
         <<1, elgamal_pubkey::binary-32, low::binary-64, high::binary-64, _rest::binary>> = extension
       )
       when byte_size(extension) >= @confidential_account_min_length do
    {:ok,
     %{
       elgamal_pubkey: elgamal_pubkey,
       pending_low: split_ciphertext(low),
       pending_high: split_ciphertext(high)
     }}
  end

  defp decode_confidential_extension(_extension), do: :error

  defp split_ciphertext(<<commitment::binary-32, handle::binary-32>>), do: {commitment, handle}

  defp parse_confidential_amount(amount) do
    with {:ok, parsed} <- Shared.parse_charge_amount(amount),
         true <- parsed > 0 and parsed <= @maximum_amount do
      {:ok, parsed}
    else
      _error -> :error
    end
  end

  defp error(detail), do: {:error, Errors.new(:verification_failed, detail)}
end
