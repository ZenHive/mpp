# TODO(onchain_tempo): Extract to onchain_tempo package as OnchainTempo.Transaction
defmodule MPP.Test.TempoTxBuilder do
  @moduledoc """
  Builds and signs Tempo Transactions (EIP-2718 type 0x76) for integration tests.

  Constructs a 13-field unsigned RLP envelope (key_authorization omitted when
  absent), signs with secp256k1 (domain 0x76), and appends the sender_signature
  as the 14th field.

  ## 0x76 Field Layout

      0x76 || rlp([
        chain_id, max_priority_fee_per_gas, max_fee_per_gas, gas_limit,
        calls, access_list, nonce_key, nonce,
        valid_before, valid_after, fee_token, fee_payer_signature,
        aa_authorization_list, sender_signature
      ])

  `key_authorization?` is optional — omitted entirely when absent. The Tempo
  node discriminates by peeking at the next byte (`>= 0xc0` = list = present).

  ## Dependencies

  Uses `Signet.Signer.Curvy` for signing (keccak + secp256k1), `Signet.Recover`
  for recovery bit, `ExRLP` for RLP encoding, and `Onchain.RPC` for nonce
  fetching. All available transitively via `onchain`.
  """

  alias Signet.Signer.Curvy

  # EIP-2718 type byte for Tempo Transactions.
  @tempo_tx_type 0x76

  # TIP-20 transfer(address,uint256) function selector.
  @transfer_selector <<0xA9, 0x05, 0x9C, 0xBB>>

  # Default gas parameters for testnet transfers.
  # Moderato base fee is 20 gwei minimum — use 25 gwei for headroom.
  @default_gas_limit 200_000
  @default_max_fee_per_gas 25_000_000_000
  @default_max_priority_fee_per_gas 1_000_000_000

  @dialyzer {:nowarn_function, [build_signed_transfer: 1, rlp_encode: 1]}

  @doc """
  Build and sign a TIP-20 transfer transaction (0x76).

  ## Options (required)

    * `:private_key` — hex-encoded secp256k1 private key (with or without 0x prefix)
    * `:token` — TIP-20 token address (hex)
    * `:recipient` — transfer recipient address (hex)
    * `:amount` — transfer amount in base units (integer)
    * `:chain_id` — Tempo chain ID (integer)
    * `:rpc_url` — RPC endpoint for nonce fetching

  ## Options (optional)

    * `:fee_token` — token address for fee payment (hex); defaults to `:token` value
    * `:nonce_key` — 2D nonce lane (integer, default 0)
    * `:nonce` — explicit nonce (skips RPC fetch if provided)
    * `:gas_limit` — gas limit (default #{@default_gas_limit})
    * `:valid_before` — Unix timestamp (default 0 = no expiry)
    * `:valid_after` — Unix timestamp (default 0)

  ## Returns

    * `{:ok, hex_string}` — `"0x76..."` hex-encoded signed transaction
    * `{:error, reason}` — on signing or RPC failure
  """
  @spec build_signed_transfer(keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_signed_transfer(opts) do
    with {:ok, private_key} <- require_opt(opts, :private_key, &decode_key/1),
         {:ok, token} <- require_opt(opts, :token, &decode_address(:token, &1)),
         {:ok, recipient} <- require_opt(opts, :recipient, &decode_address(:recipient, &1)),
         {:ok, amount} <- require_opt(opts, :amount, &validate_uint(:amount, &1)),
         {:ok, chain_id} <- require_opt(opts, :chain_id, &validate_uint(:chain_id, &1)),
         {:ok, rpc_url} <- require_opt(opts, :rpc_url, &validate_non_empty_binary(:rpc_url, &1)),
         {:ok, fee_token} <- optional_opt(opts, :fee_token, token, &decode_address(:fee_token, &1)),
         {:ok, nonce_key} <- optional_opt(opts, :nonce_key, 0, &validate_uint(:nonce_key, &1)),
         {:ok, gas_limit} <- optional_opt(opts, :gas_limit, @default_gas_limit, &validate_uint(:gas_limit, &1)),
         {:ok, valid_before} <- optional_opt(opts, :valid_before, 0, &validate_uint(:valid_before, &1)),
         {:ok, valid_after} <- optional_opt(opts, :valid_after, 0, &validate_uint(:valid_after, &1)),
         {:ok, sender_address} <- Curvy.get_address(private_key),
         {:ok, nonce} <- resolve_nonce(opts, sender_address, rpc_url) do
      calldata = encode_transfer_calldata(recipient, amount)
      call = [token, <<>>, calldata]

      # Signing preimage excludes sender_signature (like EIP-1559 excludes y_parity/r/s).
      # key_authorization omitted when absent per Tempo spec.
      # fee_payer_signature = <<>> (RLP 0x80 = absent) when client pays fees.
      base_fields = [
        encode_uint(chain_id),
        encode_uint(@default_max_priority_fee_per_gas),
        encode_uint(@default_max_fee_per_gas),
        encode_uint(gas_limit),
        [call],
        [],
        encode_uint(nonce_key),
        encode_uint(nonce),
        encode_uint(valid_before),
        encode_uint(valid_after),
        fee_token,
        <<>>,
        []
      ]

      sign_and_encode(base_fields, private_key, sender_address)
    end
  end

  @doc """
  Build and sign a TIP-20 transfer transaction with fee payer placeholder.

  Same as `build_signed_transfer/1` but sets `fee_payer_signature` to `<<0x00>>`
  (placeholder) and `fee_token` to `<<>>` (empty), signaling the server should
  co-sign as fee payer.

  Accepts the same options as `build_signed_transfer/1`. The `:fee_token` option
  is ignored (always empty for fee payer mode).
  """
  @spec build_fee_payer_transfer(keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_fee_payer_transfer(opts) do
    with {:ok, private_key} <- require_opt(opts, :private_key, &decode_key/1),
         {:ok, token} <- require_opt(opts, :token, &decode_address(:token, &1)),
         {:ok, recipient} <- require_opt(opts, :recipient, &decode_address(:recipient, &1)),
         {:ok, amount} <- require_opt(opts, :amount, &validate_uint(:amount, &1)),
         {:ok, chain_id} <- require_opt(opts, :chain_id, &validate_uint(:chain_id, &1)),
         {:ok, rpc_url} <- require_opt(opts, :rpc_url, &validate_non_empty_binary(:rpc_url, &1)),
         {:ok, nonce_key} <- optional_opt(opts, :nonce_key, 0, &validate_uint(:nonce_key, &1)),
         {:ok, gas_limit} <- optional_opt(opts, :gas_limit, @default_gas_limit, &validate_uint(:gas_limit, &1)),
         {:ok, valid_before} <- optional_opt(opts, :valid_before, 0, &validate_uint(:valid_before, &1)),
         {:ok, valid_after} <- optional_opt(opts, :valid_after, 0, &validate_uint(:valid_after, &1)),
         {:ok, sender_address} <- Curvy.get_address(private_key),
         {:ok, nonce} <- resolve_nonce(opts, sender_address, rpc_url) do
      calldata = encode_transfer_calldata(recipient, amount)
      call = [token, <<>>, calldata]

      # fee_payer_signature = <<0x00>> (placeholder), fee_token = <<>> (empty).
      # Client signs this preimage — fee_token excluded from hash when
      # fee_payer_signature is present (per Tempo spec).
      base_fields = [
        encode_uint(chain_id),
        encode_uint(@default_max_priority_fee_per_gas),
        encode_uint(@default_max_fee_per_gas),
        encode_uint(gas_limit),
        [call],
        [],
        encode_uint(nonce_key),
        encode_uint(nonce),
        encode_uint(valid_before),
        encode_uint(valid_after),
        <<>>,
        <<0x00>>,
        []
      ]

      sign_and_encode(base_fields, private_key, sender_address)
    end
  end

  @doc """
  Build and sign a fee-payer transaction with arbitrary calls.

  Accepts a `:calls` list of `[to, value, input]` RLP-ready tuples (as built by
  `MPP.Test.TempoTestHelpers.build_call/2`). Sets fee payer placeholder and empty
  fee token, same as `build_fee_payer_transfer/1`.

  Accepts the same base options as `build_fee_payer_transfer/1` except `:token`,
  `:recipient`, and `:amount` are replaced by `:calls`.
  """
  @spec build_fee_payer_multicall(keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_fee_payer_multicall(opts) do
    with {:ok, private_key} <- require_opt(opts, :private_key, &decode_key/1),
         {:ok, calls} <- require_opt(opts, :calls, &validate_calls/1),
         {:ok, chain_id} <- require_opt(opts, :chain_id, &validate_uint(:chain_id, &1)),
         {:ok, rpc_url} <- require_opt(opts, :rpc_url, &validate_non_empty_binary(:rpc_url, &1)),
         {:ok, nonce_key} <- optional_opt(opts, :nonce_key, 0, &validate_uint(:nonce_key, &1)),
         {:ok, gas_limit} <- optional_opt(opts, :gas_limit, @default_gas_limit, &validate_uint(:gas_limit, &1)),
         {:ok, valid_before} <- optional_opt(opts, :valid_before, 0, &validate_uint(:valid_before, &1)),
         {:ok, valid_after} <- optional_opt(opts, :valid_after, 0, &validate_uint(:valid_after, &1)),
         {:ok, sender_address} <- Curvy.get_address(private_key),
         {:ok, nonce} <- resolve_nonce(opts, sender_address, rpc_url) do
      base_fields = [
        encode_uint(chain_id),
        encode_uint(@default_max_priority_fee_per_gas),
        encode_uint(@default_max_fee_per_gas),
        encode_uint(gas_limit),
        calls,
        [],
        encode_uint(nonce_key),
        encode_uint(nonce),
        encode_uint(valid_before),
        encode_uint(valid_after),
        <<>>,
        <<0x00>>,
        []
      ]

      sign_and_encode(base_fields, private_key, sender_address)
    end
  end

  # --- Private helpers ---

  # Signs the base fields and returns the full encoded 0x76 transaction.
  defp sign_and_encode(base_fields, private_key, sender_address) do
    signing_payload = <<@tempo_tx_type>> <> rlp_encode(base_fields)

    with {:ok, sig} <- Curvy.sign(signing_payload, private_key),
         {:ok, recid} <- Signet.Recover.find_recid(signing_payload, sig, sender_address) do
      # Encode yParity as legacy v-value (27/28) to match ox/tempo convention.
      v = recid + 27
      sender_sig = <<sig.r::unsigned-big-size(256), sig.s::unsigned-big-size(256), v::8>>

      signed_fields = base_fields ++ [sender_sig]
      signed_raw = <<@tempo_tx_type>> <> rlp_encode(signed_fields)
      {:ok, "0x" <> Base.encode16(signed_raw, case: :lower)}
    end
  end

  # Extracts a required option, optionally applying a transform.
  defp require_opt(opts, key, transform) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) ->
        if transform, do: transform.(value), else: {:ok, value}

      _ ->
        {:error, "missing required option: #{key}"}
    end
  end

  # Extracts an optional option, applying a transform when provided.
  defp optional_opt(opts, key, default, transform) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if transform, do: transform.(value), else: {:ok, value}

      :error ->
        {:ok, default}
    end
  end

  # Fetches nonce from RPC unless explicitly provided.
  defp resolve_nonce(opts, sender_address, rpc_url) do
    case Keyword.fetch(opts, :nonce) do
      :error ->
        sender_hex = "0x" <> Base.encode16(sender_address, case: :lower)
        Onchain.RPC.get_transaction_count(sender_hex, rpc_url: rpc_url)

      {:ok, nonce} ->
        validate_uint(:nonce, nonce)
    end
  end

  # ABI-encodes transfer(address,uint256) calldata.
  defp encode_transfer_calldata(recipient_20_bytes, amount) when byte_size(recipient_20_bytes) == 20 do
    @transfer_selector <>
      <<0::96, recipient_20_bytes::binary-size(20)>> <>
      <<amount::unsigned-big-size(256)>>
  end

  # Encodes an unsigned integer as a big-endian binary (RLP convention: 0 → <<>>).
  defp encode_uint(0), do: <<>>
  defp encode_uint(n) when is_integer(n) and n > 0, do: :binary.encode_unsigned(n)

  # Decodes a hex private key (with or without 0x prefix) to a 32-byte binary.
  defp decode_key("0x" <> hex), do: decode_key(hex)

  defp decode_key(hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(32)>> = bin} -> {:ok, bin}
      :error -> {:error, "invalid private_key: expected 32-byte hex string"}
    end
  end

  defp decode_key(bin) when is_binary(bin) and byte_size(bin) == 32, do: {:ok, bin}
  defp decode_key(_), do: {:error, "invalid private_key: expected 32-byte hex string"}

  # Decodes a hex address to a 20-byte binary.
  defp decode_address(key, "0x" <> hex), do: decode_address(key, hex)

  defp decode_address(key, hex) when is_binary(hex) and byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(20)>> = bin} -> {:ok, bin}
      :error -> {:error, "invalid #{key}: expected 20-byte hex address"}
    end
  end

  defp decode_address(_key, bin) when is_binary(bin) and byte_size(bin) == 20, do: {:ok, bin}
  defp decode_address(key, _), do: {:error, "invalid #{key}: expected 20-byte hex address"}

  defp validate_uint(_key, value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_uint(key, _value), do: {:error, "invalid #{key}: expected non-negative integer"}

  defp validate_non_empty_binary(_key, value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp validate_non_empty_binary(key, _value), do: {:error, "invalid #{key}: expected non-empty string"}

  defp validate_calls([_ | _] = calls), do: {:ok, calls}
  defp validate_calls(_), do: {:error, "invalid calls: expected non-empty list"}

  # ExRLP wrapper — suppresses dialyzer false positive from default-arg arity mismatch.
  defp rlp_encode(data), do: ExRLP.encode(data)
end
