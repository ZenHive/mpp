defmodule MPP.Methods.Solana.Instructions do
  @moduledoc """
  Parse and match Solana payment instructions for `MPP.Methods.Solana`.

  Two input shapes are supported:

    * compiled legacy transactions (`Cartouche.Solana.Transaction`) for pull-mode
      pre-broadcast checks (instruction allow-list + payment legs)
    * `jsonParsed` `getTransaction` results for push-mode and post-confirm
      payment matching

  Observed `jsonParsed` transfer shapes were captured from Solana devnet
  (`getTransaction` / `getBlock` on 2026-08-19) and are the authority for
  field names used here.
  """

  use Cartouche.Base58

  alias Cartouche.Solana.ATA
  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.Transaction
  alias Cartouche.Solana.Transaction.CompiledInstruction
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared

  @max_splits 8
  @memo_program ~B58[MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr]
  @memo_v1_program ~B58[Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo]
  @system_transfer_ix 2
  @spl_transfer_checked_ix 12
  @ata_create_ix 0
  @ata_create_idempotent_ix 1
  @cu_set_limit_ix 2
  @cu_set_price_ix 3
  @default_max_compute_unit_limit 400_000
  @default_max_compute_unit_price 1_000_000

  @type classified ::
          {:sol_transfer, map()}
          | {:spl_transfer, map()}
          | {:ata_create, map()}
          | {:memo, binary()}
          | {:compute_budget, term()}
          | {:unknown, binary()}

  @doc """
  Classify compiled instructions on a legacy transaction.

  Returns `{:ok, [classified]}` or `{:error, reason}` when an account index
  is out of range.
  """
  @spec classify_compiled(Transaction.t()) :: {:ok, [classified()]} | {:error, String.t()}
  def classify_compiled(%Transaction{message: message}) do
    keys = message.account_keys

    message.instructions
    |> Enum.reduce_while({:ok, []}, fn ix, {:ok, acc} ->
      case classify_compiled_ix(ix, keys) do
        {:ok, classified} -> {:cont, {:ok, [classified | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, classified} -> {:ok, Enum.reverse(classified)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classify top-level `jsonParsed` instructions from a `getTransaction` result.
  """
  @spec classify_parsed(map()) :: {:ok, [classified()]} | {:error, String.t()}
  def classify_parsed(rpc_tx) when is_map(rpc_tx) do
    case parsed_instructions(rpc_tx) do
      {:ok, instructions} ->
        {:ok, Enum.map(instructions, &classify_parsed_ix/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enforce the pull-mode instruction allow-list, ATA policy, and compute-budget
  ceilings, then match payment legs against the challenge.
  """
  @spec verify_compiled(Transaction.t(), Charge.t(), map()) :: :ok | {:error, Errors.t()}
  def verify_compiled(%Transaction{} = tx, %Charge{} = charge, opts) do
    with {:ok, classified} <- map_classify_error(classify_compiled(tx)),
         :ok <- reject_unknown(classified),
         :ok <- reject_non_idempotent_ata(classified),
         :ok <- check_compute_budget(classified, opts),
         :ok <- check_ata_policy(classified, charge, opts),
         :ok <- reject_fee_payer_source(classified, opts) do
      match_payment_legs(classified, charge, opts)
    end
  end

  @doc """
  Match payment legs in a confirmed `jsonParsed` transaction against the charge.
  """
  @spec verify_parsed(map(), Charge.t(), map()) :: :ok | {:error, Errors.t()}
  def verify_parsed(rpc_tx, %Charge{} = charge, opts) do
    with :ok <- check_meta_ok(rpc_tx),
         {:ok, classified} <- map_classify_error(classify_parsed(rpc_tx)) do
      match_payment_legs(classified, charge, opts)
    end
  end

  @doc """
  Return the payment legs implied by a charge (primary remainder + splits).
  """
  @spec payment_legs(Charge.t()) :: {:ok, [map()]} | {:error, Errors.t()}
  def payment_legs(%Charge{} = charge) do
    with {:ok, total} <- Shared.parse_charge_amount(charge.amount),
         {:ok, splits} <- normalize_splits(charge),
         :ok <- validate_split_sum(total, splits),
         {:ok, recipient} <- require_recipient(charge) do
      split_amount = Enum.reduce(splits, 0, &(&1.amount + &2))
      primary_amount = total - split_amount

      primary = %{
        recipient: recipient,
        amount: primary_amount,
        ata_creation_required?: false
      }

      {:ok, [primary | splits]}
    end
  end

  @doc false
  @spec max_splits() :: pos_integer()
  def max_splits, do: @max_splits

  @doc """
  Validate split entries in method_config (shape only; amount vs charge is
  checked when the charge is available).
  """
  @spec validate_splits_config!([map()] | nil) :: :ok
  def validate_splits_config!(nil), do: :ok

  def validate_splits_config!(splits) when is_list(splits) do
    if length(splits) > @max_splits do
      raise ArgumentError, "MPP.Methods.Solana splits must contain at most #{@max_splits} entries"
    end

    Enum.each(splits, &validate_split_entry!/1)
    :ok
  end

  def validate_splits_config!(_splits) do
    raise ArgumentError, "MPP.Methods.Solana splits must be a list of maps"
  end

  # --- compiled classification ---

  defp classify_compiled_ix(%CompiledInstruction{} = ix, keys) do
    with {:ok, program} <- at_index(keys, ix.program_id_index),
         {:ok, accounts} <- resolve_accounts(ix.accounts, keys) do
      {:ok, classify_program(program, accounts, ix.data)}
    end
  end

  defp classify_program(program, accounts, data) when program == <<0::256>> do
    case {data, accounts} do
      {<<@system_transfer_ix::little-unsigned-32, lamports::little-unsigned-64>>, [source, destination | _]} ->
        sol_transfer(source, destination, lamports)

      _other ->
        {:unknown, program}
    end
  end

  defp classify_program(program, accounts, data) do
    cond do
      token_program?(program) ->
        classify_token_ix(program, accounts, data)

      program == Programs.ata_program() ->
        classify_ata_ix(accounts, data)

      program == Programs.compute_budget_program() ->
        {:compute_budget, classify_compute_budget(data)}

      program in [@memo_program, @memo_v1_program] ->
        {:memo, data}

      true ->
        {:unknown, program}
    end
  end

  defp classify_token_ix(
         program,
         accounts,
         <<@spl_transfer_checked_ix, amount::little-unsigned-64, decimals::unsigned-8>>
       ) do
    case accounts do
      [source, mint, destination, authority | _] ->
        {:spl_transfer,
         %{
           source: source,
           mint: mint,
           destination: destination,
           authority: authority,
           amount: amount,
           decimals: decimals,
           program: program
         }}

      _other ->
        {:unknown, program}
    end
  end

  defp classify_token_ix(program, _accounts, _data), do: {:unknown, program}

  defp classify_ata_ix([payer, ata, owner, mint, _system, token_program | _], <<ix>>)
       when ix in [@ata_create_ix, @ata_create_idempotent_ix] do
    {:ata_create,
     %{
       payer: payer,
       ata: ata,
       owner: owner,
       mint: mint,
       token_program: token_program,
       idempotent?: ix == @ata_create_idempotent_ix
     }}
  end

  defp classify_ata_ix(_accounts, _data), do: {:unknown, Programs.ata_program()}

  defp classify_compute_budget(<<@cu_set_limit_ix, limit::little-unsigned-32>>), do: {:set_limit, limit}
  defp classify_compute_budget(<<@cu_set_price_ix, price::little-unsigned-64>>), do: {:set_price, price}
  defp classify_compute_budget(<<disc, _rest::binary>>), do: {:other, disc}
  defp classify_compute_budget(_data), do: {:other, nil}

  # --- jsonParsed classification ---

  defp classify_parsed_ix(ix) when is_map(ix) do
    program_id = ix["programId"]

    case ix do
      %{"program" => "system", "parsed" => %{"type" => "transfer", "info" => info}} ->
        parsed_sol_transfer(info)

      %{"parsed" => %{"type" => "transfer", "info" => info}, "programId" => "11111111111111111111111111111111"} ->
        parsed_sol_transfer(info)

      %{"parsed" => %{"type" => "transferChecked", "info" => info}} ->
        token_amount = info["tokenAmount"] || %{}

        {:spl_transfer,
         %{
           source: decode_key(info["source"]),
           mint: decode_key(info["mint"]),
           destination: decode_key(info["destination"]),
           authority: decode_key(info["authority"]),
           amount: parse_integer(token_amount["amount"]),
           decimals: parse_integer(token_amount["decimals"]),
           program: decode_key(program_id)
         }}

      %{"parsed" => %{"type" => type, "info" => info}}
      when type in ["createIdempotent", "create"] ->
        {:ata_create,
         %{
           payer: decode_key(info["source"] || info["payer"]),
           ata: decode_key(info["account"]),
           owner: decode_key(info["wallet"]),
           mint: decode_key(info["mint"]),
           token_program: decode_key(info["tokenProgram"]),
           idempotent?: type == "createIdempotent"
         }}

      %{"programId" => id} ->
        classify_parsed_program(id, ix)

      _other ->
        {:unknown, <<>>}
    end
  end

  defp classify_parsed_ix(_ix), do: {:unknown, <<>>}

  defp classify_parsed_program(id, ix) do
    program = decode_key(id)

    cond do
      program == Programs.compute_budget_program() ->
        {:compute_budget, {:other, ix["data"]}}

      program in [@memo_program, @memo_v1_program] ->
        {:memo, ix["parsed"] || ix["data"] || <<>>}

      true ->
        {:unknown, program}
    end
  end

  defp parsed_instructions(rpc_tx) do
    case get_in(rpc_tx, ["transaction", "message", "instructions"]) do
      instructions when is_list(instructions) -> {:ok, instructions}
      _other -> {:error, "Transaction is missing parsed instructions"}
    end
  end

  # --- policy ---

  defp reject_unknown(classified) do
    if Enum.any?(classified, &match?({:unknown, _}, &1)) do
      {:error, Errors.new(:verification_failed, "Transaction contains unexpected instructions")}
    else
      :ok
    end
  end

  defp reject_non_idempotent_ata(classified) do
    if Enum.any?(classified, &match?({:ata_create, %{idempotent?: false}}, &1)) do
      {:error, Errors.new(:verification_failed, "ATA creation must use the idempotent instruction")}
    else
      :ok
    end
  end

  defp check_compute_budget(classified, opts) do
    if opts[:fee_payer] do
      max_limit = opts[:max_compute_unit_limit] || @default_max_compute_unit_limit
      max_price = opts[:max_compute_unit_price] || @default_max_compute_unit_price

      Enum.reduce_while(classified, :ok, fn
        {:compute_budget, {:set_limit, limit}}, :ok when limit > max_limit ->
          {:halt, {:error, Errors.new(:verification_failed, "Compute unit limit exceeds fee-payer ceiling")}}

        {:compute_budget, {:set_price, price}}, :ok when price > max_price ->
          {:halt, {:error, Errors.new(:verification_failed, "Compute unit price exceeds fee-payer ceiling")}}

        _other, :ok ->
          {:cont, :ok}
      end)
    else
      :ok
    end
  end

  defp check_ata_policy(classified, charge, opts) do
    classified
    |> Enum.flat_map(fn
      {:ata_create, ata} -> [ata]
      _other -> []
    end)
    |> check_ata_list(charge, opts)
  end

  defp check_ata_list([], _charge, _opts), do: :ok

  defp check_ata_list(atas, charge, opts) do
    with :ok <- reject_ata_for_native_sol(charge),
         {:ok, mint} <- decode_mint(charge.currency),
         {:ok, legs} <- payment_legs(charge),
         {:ok, token_program} <- resolve_token_program(charge, atas) do
      allowed_owners = ata_allowed_owners(legs, opts)
      Enum.reduce_while(atas, :ok, fn ata, :ok -> check_one_ata(ata, mint, token_program, allowed_owners, opts) end)
    end
  end

  defp reject_ata_for_native_sol(charge) do
    if native_sol?(charge.currency) do
      {:error, Errors.new(:verification_failed, "ATA creation is not allowed for native SOL payments")}
    else
      :ok
    end
  end

  defp check_one_ata(ata, mint, token_program, allowed_owners, opts) do
    {expected_ata, _bump} = ATA.find_address(ata.owner, mint, token_program: token_program)
    fee_payer = opts[:fee_payer_pubkey]

    cond do
      ata.mint != mint ->
        {:halt, {:error, Errors.new(:verification_failed, "ATA creation mint does not match charge currency")}}

      ata.token_program != token_program ->
        {:halt, {:error, Errors.new(:verification_failed, "ATA creation token program does not match charge")}}

      ata.ata != expected_ata ->
        {:halt, {:error, Errors.new(:verification_failed, "ATA address is not the canonical associated token account")}}

      fee_payer && ata.payer != fee_payer ->
        {:halt, {:error, Errors.new(:verification_failed, "ATA creation payer must be the transaction fee payer")}}

      ata.owner not in allowed_owners ->
        {:halt,
         {:error, Errors.new(:verification_failed, "ATA creation is only allowed for authorized split recipients")}}

      true ->
        {:cont, :ok}
    end
  end

  defp ata_allowed_owners(legs, opts) do
    legs
    |> Enum.filter(fn leg ->
      if opts[:fee_payer], do: leg.ata_creation_required?, else: true
    end)
    |> MapSet.new(& &1.recipient)
  end

  defp reject_fee_payer_source(_classified, %{fee_payer: false}), do: :ok
  defp reject_fee_payer_source(_classified, %{fee_payer_pubkey: nil}), do: :ok

  defp reject_fee_payer_source(classified, %{fee_payer: true, fee_payer_pubkey: fee_payer}) do
    sourced =
      Enum.any?(classified, fn
        {:sol_transfer, %{source: ^fee_payer}} -> true
        _other -> false
      end)

    if sourced do
      {:error, Errors.new(:verification_failed, "Fee payer must not be the source of a SOL transfer")}
    else
      :ok
    end
  end

  defp reject_fee_payer_source(_classified, _opts), do: :ok

  # --- payment matching ---

  defp match_payment_legs(classified, charge, opts) do
    native? = native_sol?(charge.currency)

    with {:ok, legs} <- payment_legs(charge) do
      classified
      |> payment_transfers(native?)
      |> then(&consume_legs(legs, &1, charge, opts, native?))
      |> finish_payment_match()
    end
  end

  defp payment_transfers(classified, true) do
    for {:sol_transfer, transfer} <- classified, do: transfer
  end

  defp payment_transfers(classified, false) do
    for {:spl_transfer, transfer} <- classified, do: transfer
  end

  defp finish_payment_match({:ok, []}), do: :ok

  defp finish_payment_match({:ok, _unused}) do
    {:error, Errors.new(:verification_failed, "Transaction contains unexpected transfer instructions")}
  end

  defp finish_payment_match({:error, %Errors{}} = error), do: error

  defp consume_legs([], remaining, _charge, _opts, _native?), do: {:ok, remaining}

  defp consume_legs([leg | rest], remaining, charge, opts, native?) do
    {expected_dest, mint} = expected_destination(leg, charge, opts, native?)

    case take_matching(remaining, expected_dest, leg.amount, mint, native?) do
      {:ok, remaining} ->
        consume_legs(rest, remaining, charge, opts, native?)

      :error ->
        {:error, Errors.new(:verification_failed, "No matching transfer instruction found")}
    end
  end

  defp expected_destination(leg, _charge, _opts, true), do: {leg.recipient, nil}

  defp expected_destination(leg, charge, opts, false) do
    mint = spl_mint_key(opts[:mint], charge.currency)
    token_program = opts[:token_program] || Programs.token_program()
    {ata, _bump} = ATA.find_address(leg.recipient, mint, token_program: token_program)
    {ata, mint}
  end

  defp spl_mint_key(<<mint::binary-32>>, _currency), do: mint

  defp spl_mint_key(_mint, currency) do
    case decode_pubkey(currency) do
      {:ok, <<mint::binary-32>>} -> mint
      _other -> <<0::256>>
    end
  end

  defp take_matching(transfers, dest, amount, mint, native?) do
    {before, match_and_after} =
      Enum.split_while(transfers, fn transfer ->
        not transfer_matches?(transfer, dest, amount, mint, native?)
      end)

    case match_and_after do
      [_match | after_match] -> {:ok, before ++ after_match}
      [] -> :error
    end
  end

  defp transfer_matches?(transfer, dest, amount, _mint, true) do
    transfer.destination == dest and transfer.lamports == amount
  end

  defp transfer_matches?(transfer, dest, amount, mint, false) do
    transfer.destination == dest and transfer.amount == amount and transfer.mint == mint
  end

  # --- splits / charge ---

  defp normalize_splits(%Charge{method_details: details}) do
    details
    |> splits_from_details()
    |> Enum.reduce_while({:ok, []}, &accumulate_split/2)
    |> reverse_splits()
  end

  defp accumulate_split(entry, {:ok, acc}) do
    case normalize_split(entry) do
      {:ok, split} -> {:cont, {:ok, [split | acc]}}
      {:error, %Errors{}} = error -> {:halt, error}
    end
  end

  defp reverse_splits({:ok, splits}), do: {:ok, Enum.reverse(splits)}
  defp reverse_splits({:error, %Errors{}} = error), do: error

  defp splits_from_details(%{"splits" => splits}) when is_list(splits), do: splits
  defp splits_from_details(_details), do: []

  defp normalize_split(entry) when is_map(entry) do
    recipient = entry["recipient"]
    amount = entry["amount"]
    ata? = entry["ataCreationRequired"] || false

    with {:ok, recipient_key} <- decode_pubkey(recipient),
         {:ok, amount_int} <- Shared.parse_charge_amount(to_string(amount)) do
      if amount_int > 0 do
        {:ok, %{recipient: recipient_key, amount: amount_int, ata_creation_required?: ata? == true}}
      else
        {:error, Errors.new(:verification_failed, "Split amount must be a positive integer")}
      end
    end
  end

  defp normalize_split(_entry), do: {:error, Errors.new(:verification_failed, "Invalid split entry")}

  defp validate_split_sum(total, splits) do
    split_amount = Enum.reduce(splits, 0, &(&1.amount + &2))

    cond do
      length(splits) > @max_splits ->
        {:error, Errors.new(:verification_failed, "Too many payment splits")}

      split_amount >= total ->
        {:error,
         Errors.new(:verification_failed, "Split amounts must leave a positive remainder for the primary recipient")}

      true ->
        :ok
    end
  end

  defp validate_split_entry!(entry) when is_map(entry) do
    recipient = entry["recipient"]
    amount = entry["amount"]

    if !is_binary(recipient) do
      raise ArgumentError, "MPP.Methods.Solana split recipient must be a base58 public key"
    end

    if !is_binary(amount) and !is_integer(amount) do
      raise ArgumentError, "MPP.Methods.Solana split amount must be an integer string"
    end

    :ok
  end

  defp validate_split_entry!(_entry) do
    raise ArgumentError, "MPP.Methods.Solana splits must be a list of maps"
  end

  defp require_recipient(%Charge{recipient: recipient}) when is_binary(recipient) do
    decode_pubkey(recipient)
  end

  defp require_recipient(_charge) do
    {:error, Errors.new(:verification_failed, "Solana method requires a recipient address")}
  end

  defp resolve_token_program(charge, atas) do
    case token_program_from_details(charge.method_details) do
      {:ok, program} ->
        {:ok, program}

      _other ->
        case atas do
          [%{token_program: program} | _] when is_binary(program) and program != <<>> ->
            {:ok, program}

          _other_atas ->
            {:ok, Programs.token_program()}
        end
    end
  end

  defp token_program_from_details(%{"tokenProgram" => program}) when is_binary(program), do: decode_pubkey(program)
  defp token_program_from_details(%{"token_program" => program}) when is_binary(program), do: decode_pubkey(program)
  defp token_program_from_details(_details), do: :error

  defp decode_mint(currency) when is_binary(currency), do: decode_pubkey(currency)

  # --- primitives ---

  defp parsed_sol_transfer(info) when is_map(info) do
    sol_transfer(decode_key(info["source"]), decode_key(info["destination"]), parse_integer(info["lamports"]))
  end

  defp sol_transfer(source, destination, lamports) do
    {:sol_transfer, %{source: source, destination: destination, lamports: lamports}}
  end

  defp native_sol?(currency) when is_binary(currency), do: String.downcase(currency) == "sol"

  defp token_program?(program) do
    program == Programs.token_program() or program == Programs.token_2022_program()
  end

  defp at_index(list, index) when is_integer(index) and index >= 0 do
    case Enum.at(list, index) do
      nil -> {:error, "Instruction account index out of range"}
      value -> {:ok, value}
    end
  end

  defp at_index(_list, _index), do: {:error, "Instruction account index out of range"}

  defp resolve_accounts(indexes, keys) do
    indexes
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      case at_index(keys, index) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, accounts} -> {:ok, Enum.reverse(accounts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_pubkey(value) when is_binary(value) do
    if byte_size(value) == 32 do
      {:ok, value}
    else
      case Cartouche.Base58.decode(value) do
        {:ok, <<key::binary-32>>} -> {:ok, key}
        _other -> {:error, Errors.new(:verification_failed, "Invalid Solana public key")}
      end
    end
  end

  defp decode_pubkey(_value), do: {:error, Errors.new(:verification_failed, "Invalid Solana public key")}

  defp decode_key(value) when is_binary(value) do
    case decode_pubkey(value) do
      {:ok, key} -> key
      {:error, _reason} -> <<>>
    end
  end

  defp decode_key(_value), do: <<>>

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> -1
    end
  end

  defp parse_integer(_value), do: -1

  defp map_classify_error({:ok, classified}), do: {:ok, classified}

  defp map_classify_error({:error, reason}) do
    {:error, Errors.new(:verification_failed, reason)}
  end

  defp check_meta_ok(%{"meta" => %{"err" => nil}}), do: :ok

  defp check_meta_ok(%{"meta" => %{"err" => _err}}) do
    {:error, Errors.new(:verification_failed, "Transaction failed on-chain")}
  end

  defp check_meta_ok(_rpc_tx) do
    {:error, Errors.new(:verification_failed, "Transaction metadata is missing")}
  end
end
