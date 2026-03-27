# TODO(onchain_tempo): Extract to onchain_tempo package as OnchainTempo.Transaction
# (merge with test/support/tempo_tx_builder.ex for full deserialize + build + sign)
defmodule MPP.Tempo.Transaction do
  @moduledoc """
  Deserializes and inspects Tempo Transactions (EIP-2718 type 0x76).

  A Tempo Transaction is an RLP-encoded envelope prefixed with `0x76`:

      0x76 || rlp([chain_id, max_priority_fee_per_gas, max_fee_per_gas, gas_limit,
                    calls, access_list, nonce_key, nonce, valid_before, valid_after,
                    fee_token, fee_payer_signature, aa_authorization_list,
                    key_authorization?, sender_signature])

  Each `call` is `rlp([to, value, input])`.

  This module extracts only the fields needed for payment verification:
  `chain_id` and `calls`. The full serialized hex is preserved as `raw`
  for broadcast passthrough.

  ## Dependencies

  Uses `ExRLP` (available transitively via `signet` → `onchain`) for RLP
  decoding. No additional dependencies required.
  """

  @enforce_keys [:chain_id, :calls, :raw]
  defstruct [:chain_id, :calls, :raw]

  @typedoc "A parsed Tempo Transaction with only verification-relevant fields."
  @type t :: %__MODULE__{
          chain_id: non_neg_integer(),
          calls: [call()],
          raw: String.t()
        }

  @typedoc "A single call within the transaction's batch."
  @type call :: %{to: binary(), value: non_neg_integer(), input: binary()}

  # EIP-2718 type byte for Tempo Transactions.
  @tempo_tx_type 0x76

  # RLP field index for `calls` in the 0x76 envelope (see spec).
  @calls_index 4

  # TIP-20 function selectors (keccak256 of function signature, first 4 bytes).
  # transfer(address,uint256)
  @transfer_selector <<0xA9, 0x05, 0x9C, 0xBB>>
  # transferWithMemo(address,uint256,bytes32)
  @transfer_with_memo_selector <<0x95, 0x77, 0x7D, 0x59>>

  # Calldata sizes used in pattern match guards (4-byte selector + ABI-encoded args).
  # transfer: 4 + 32 (address) + 32 (uint256) = 68 → 64 bytes after selector
  # transferWithMemo: 4 + 32 + 32 + 32 (bytes32) = 100 → 96 bytes after selector

  @doc """
  Deserialize a hex-encoded Tempo Transaction (0x76 prefix).

  Returns `{:ok, %Transaction{}}` with `chain_id`, parsed `calls`, and the
  original hex string as `raw` (for broadcast). Returns `{:error, reason}`
  on invalid input.

  ## Examples

      iex> MPP.Tempo.Transaction.deserialize("0x76" <> valid_rlp_hex)
      {:ok, %MPP.Tempo.Transaction{chain_id: 42431, calls: [...], raw: "0x76..."}}

      iex> MPP.Tempo.Transaction.deserialize("0x02" <> rlp_hex)
      {:error, "Not a Tempo transaction: expected 0x76 type prefix"}
  """
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, String.t()}
  def deserialize(hex) when is_binary(hex) do
    with {:ok, binary} <- decode_hex(hex),
         {:ok, rlp_body} <- strip_type_prefix(binary),
         {:ok, fields} <- rlp_decode(rlp_body),
         {:ok, chain_id} <- extract_chain_id(fields),
         {:ok, calls} <- extract_calls(fields) do
      {:ok, %__MODULE__{chain_id: chain_id, calls: calls, raw: hex}}
    end
  end

  def deserialize(_), do: {:error, "Invalid input: expected a hex string"}

  @doc """
  Find a matching payment call (transfer or transferWithMemo) in the transaction.

  Searches `tx.calls` for one targeting `currency` with the correct selector,
  then ABI-decodes and verifies recipient, amount, and optional memo.

  ## Options

    * `:amount` — (required) expected amount as string
    * `:recipient` — (required) expected recipient as hex address
    * `:memo` — (optional) bytes32 hex memo; when set, MUST match transferWithMemo

  ## Examples

      iex> MPP.Tempo.Transaction.find_payment_call(tx, "0x20c0...000",
      ...>   amount: "1000000", recipient: "0x742d...fE00")
      {:ok, %{to: ..., amount: 1000000, recipient: "0x742d...fE00"}}
  """
  @spec find_payment_call(t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def find_payment_call(%__MODULE__{calls: calls}, currency, opts) do
    expected_amount = Keyword.fetch!(opts, :amount)
    expected_recipient = Keyword.fetch!(opts, :recipient)
    memo = Keyword.get(opts, :memo)

    currency_bytes = normalize_address(currency)
    recipient_bytes = normalize_address(expected_recipient)

    with {:ok, amount_int} <- parse_amount(expected_amount) do
      result =
        Enum.find_value(calls, fn call ->
          match_call(call, currency_bytes, recipient_bytes, amount_int, memo)
        end)

      case result do
        nil when is_binary(memo) ->
          {:error, "No matching transferWithMemo call found in transaction"}

        nil ->
          {:error, "No matching transfer call found in transaction"}

        match ->
          {:ok, match}
      end
    end
  end

  # --- Private: hex decoding ---

  defp decode_hex("0x" <> hex), do: decode_hex_string(hex)
  defp decode_hex(hex), do: decode_hex_string(hex)

  defp decode_hex_string(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, "Invalid hex encoding"}
    end
  end

  # --- Private: type prefix ---

  defp strip_type_prefix(<<@tempo_tx_type, rlp_body::binary>>), do: {:ok, rlp_body}

  defp strip_type_prefix(<<prefix, _::binary>>) do
    {:error, "Not a Tempo transaction: expected 0x76 type prefix, got 0x#{Integer.to_string(prefix, 16)}"}
  end

  defp strip_type_prefix(<<>>), do: {:error, "Empty transaction data"}

  # --- Private: RLP decoding ---

  # ExRLP is a transitive dep (signet → onchain). Dialyzer can't resolve its
  # default-arg arity — suppress the false positive.
  @dialyzer {:nowarn_function, rlp_decode: 1}
  defp rlp_decode(binary) do
    {:ok, ExRLP.decode(binary)}
  rescue
    _ -> {:error, "Failed to RLP-decode transaction"}
  end

  # --- Private: field extraction ---

  # chain_id is at index 0 in the RLP list.
  defp extract_chain_id([chain_id_bin | _]) when is_binary(chain_id_bin) do
    {:ok, decode_unsigned(chain_id_bin)}
  end

  defp extract_chain_id(_), do: {:error, "Missing or invalid chain_id field"}

  # calls is at index 4 in the RLP list.
  defp extract_calls(fields) when is_list(fields) and length(fields) > @calls_index do
    raw_calls = Enum.at(fields, @calls_index)

    if is_list(raw_calls) do
      parse_all_calls(raw_calls, [], 0)
    else
      {:error, "Invalid calls field: expected a list"}
    end
  end

  defp extract_calls(_), do: {:error, "Transaction too short: missing calls field"}

  defp parse_all_calls([], acc, _idx), do: {:ok, Enum.reverse(acc)}

  defp parse_all_calls([raw | rest], acc, idx) do
    case parse_call(raw) do
      {:ok, call} -> parse_all_calls(rest, [call | acc], idx + 1)
      :error -> {:error, "Malformed call at index #{idx}: expected [to, value, input]"}
    end
  end

  # Each call is [to, value, input].
  defp parse_call([to, value, input]) when is_binary(to) and is_binary(value) and is_binary(input) do
    {:ok, %{to: to, value: decode_unsigned(value), input: input}}
  end

  defp parse_call([to, value]) when is_binary(to) and is_binary(value) do
    {:ok, %{to: to, value: decode_unsigned(value), input: <<>>}}
  end

  defp parse_call(_), do: :error

  # --- Private: call matching ---

  # Attempts to match a call against expected payment parameters.
  # Returns a match map or nil.
  defp match_call(%{to: to, input: input}, currency_bytes, recipient_bytes, amount_int, memo) do
    if addresses_equal?(to, currency_bytes) do
      match_input(input, recipient_bytes, amount_int, memo)
    end
  end

  # When memo is configured, MUST match transferWithMemo with matching memo.
  defp match_input(<<@transfer_with_memo_selector, calldata::binary-size(96)>>, recipient_bytes, amount_int, memo)
       when byte_size(calldata) == 96 do
    <<_pad::binary-size(12), to::binary-size(20)>> = binary_part(calldata, 0, 32)
    <<amount::unsigned-big-size(256)>> = binary_part(calldata, 32, 32)
    <<memo_bytes::binary-size(32)>> = binary_part(calldata, 64, 32)

    cond do
      !addresses_equal?(to, recipient_bytes) -> nil
      amount != amount_int -> nil
      is_binary(memo) and !memo_matches?(memo_bytes, memo) -> nil
      true -> build_match(to, amount, memo_bytes)
    end
  end

  # transfer(address,uint256) — accepted when no memo required.
  defp match_input(<<@transfer_selector, calldata::binary-size(64)>>, recipient_bytes, amount_int, memo)
       when byte_size(calldata) == 64 do
    # When memo is required, transfer (without memo) doesn't match.
    if is_binary(memo) do
      nil
    else
      <<_pad::binary-size(12), to::binary-size(20), amount::unsigned-big-size(256)>> = calldata

      if addresses_equal?(to, recipient_bytes) and amount == amount_int do
        build_match(to, amount, nil)
      end
    end
  end

  defp match_input(_, _, _, _), do: nil

  defp build_match(to, amount, memo_bytes) do
    base = %{recipient: "0x" <> Base.encode16(to, case: :lower), amount: amount}

    if is_binary(memo_bytes) do
      Map.put(base, :memo, "0x" <> Base.encode16(memo_bytes, case: :lower))
    else
      base
    end
  end

  # --- Private: address utilities ---

  # Normalizes a hex address string to a raw 20-byte binary.
  defp normalize_address("0x" <> hex), do: normalize_hex_address(hex)
  defp normalize_address(hex) when byte_size(hex) == 40, do: normalize_hex_address(hex)
  defp normalize_address(bin) when byte_size(bin) == 20, do: bin
  defp normalize_address(_), do: <<>>

  defp normalize_hex_address(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<addr::binary-size(20)>>} -> addr
      _ -> <<>>
    end
  end

  # Constant-time address comparison (both must be 20 bytes).
  defp addresses_equal?(a, b) when byte_size(a) == 20 and byte_size(b) == 20 do
    :crypto.hash_equals(a, b)
  end

  defp addresses_equal?(_, _), do: false

  # --- Private: memo comparison ---

  defp memo_matches?(memo_bytes, expected_memo) when is_binary(memo_bytes) and byte_size(memo_bytes) == 32 do
    expected_hex = expected_memo |> strip_0x() |> String.downcase()
    actual_hex = Base.encode16(memo_bytes, case: :lower)
    expected_hex == actual_hex
  end

  defp memo_matches?(_, _), do: false

  # --- Private: numeric utilities ---

  # Decodes a big-endian unsigned binary to integer. Empty binary = 0.
  defp decode_unsigned(<<>>), do: 0
  defp decode_unsigned(bin) when is_binary(bin), do: :binary.decode_unsigned(bin)

  defp parse_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid amount: not a valid integer"}
    end
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(hex), do: hex
end
