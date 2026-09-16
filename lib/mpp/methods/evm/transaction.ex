defmodule MPP.Methods.EVM.Transaction do
  @moduledoc """
  EVM `type=transaction` credential: client-signed EIP-1559 transfer, server broadcast.

  The payload `signature` is a hex-encoded signed type-2 transaction
  (`draft-evm-charge-00` § Transaction Payload). The server deserializes it,
  checks it against the challenged chain, token, recipient, and amount, rejects
  splits, checks the **challenge** expiry (a signed transfer has none of its own),
  then broadcasts via `eth_sendRawTransaction`. Settlement still requires the
  ERC-20 `Transfer` log, not only receipt status.

  Advertise this path by setting `"transaction" => true` in method_config.
  Native ETH and split charges never advertise or accept it.
  """

  alias Cartouche.Hash
  alias Cartouche.Transaction.V2
  alias MPP.Errors
  alias MPP.Hex
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM.RPC, as: EvmRPC
  alias MPP.Methods.Shared
  alias Onchain.ABI
  alias Onchain.Address
  alias Onchain.RPC
  alias Onchain.Signer

  @transfer_fn "transfer(address,uint256)"
  # draft-evm-charge-00.md:880 — transfer(address,uint256) selector
  @transfer_selector <<0xA9, 0x05, 0x9C, 0xBB>>
  @poll_interval_ms 1_000

  @type prepared :: %{hash: String.t(), raw: String.t()}

  @doc "Return true when this charge advertises and accepts `type=transaction`."
  @spec offered?(Charge.t()) :: boolean()
  def offered?(%Charge{method_details: config} = charge) when is_map(config) do
    config["transaction"] == true and not splits?(config) and not native?(charge.currency)
  end

  def offered?(_charge), do: false

  @doc """
  Decode and validate a signed EIP-1559 transfer against the charge.

  Does not broadcast. Returns the canonical raw hex and its keccak hash.
  """
  @spec validate(map(), Charge.t()) :: {:ok, prepared()} | {:error, Errors.t()}
  def validate(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_splits(config),
         :ok <- reject_native(charge),
         {:ok, bytes} <- decode_signature(payload),
         {:ok, tx} <- decode_eip1559(bytes),
         {:ok, raw} <- Signer.encode_transaction(tx),
         {:ok, canonical} <- Onchain.Hex.decode(raw),
         {:ok, chain_id} <- EvmRPC.require_chain_id(config),
         :ok <- match_chain_id(tx, chain_id),
         :ok <- match_currency(tx, charge),
         :ok <- match_transfer(tx, charge),
         :ok <- check_challenge_expiry(config) do
      {:ok, %{hash: tx_hash(canonical), raw: raw}}
    end
  end

  def validate(_payload, _charge) do
    {:error, Errors.new(:invalid_payload, ~s(Missing or invalid 'type' field — expected "transaction"))}
  end

  @doc "Broadcast a validated signed transaction and wait until the receipt is present."
  @spec broadcast(prepared(), Charge.t()) :: {:ok, String.t()} | {:error, Errors.t()}
  def broadcast(%{raw: raw}, %Charge{} = charge) do
    config = charge.method_details || %{}

    with {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "EVM"),
         rpc_opts = EvmRPC.rpc_opts(rpc_url, config),
         {:ok, sent} <- send_raw(raw, rpc_opts),
         :ok <- await_receipt(sent, rpc_opts, deadline(config)) do
      {:ok, sent}
    end
  end

  defp decode_signature(%{"signature" => value}) when is_binary(value) do
    hex = Hex.strip_0x(value)

    if hex != "" and rem(byte_size(hex), 2) == 0 and Hex.hex_string?(hex) do
      Onchain.Hex.decode(value)
    else
      {:error, Errors.new(:invalid_payload, "Invalid EIP-1559 signed transaction")}
    end
  end

  defp decode_signature(_payload) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'signature' field in credential payload")}
  end

  defp decode_eip1559(<<0x02, _::binary>> = bytes) do
    case V2.decode(bytes) do
      {:ok, %V2{} = tx} -> require_signed(tx)
      {:error, _reason} -> {:error, Errors.new(:invalid_payload, "Invalid EIP-1559 signed transaction")}
    end
  end

  defp decode_eip1559(_bytes) do
    {:error, Errors.new(:invalid_payload, "Transaction must be an EIP-1559 type-2 envelope")}
  end

  defp require_signed(%V2{signature_y_parity: v, signature_r: r, signature_s: s} = tx)
       when is_boolean(v) and is_binary(r) and is_binary(s) do
    {:ok, tx}
  end

  defp require_signed(_tx) do
    {:error, Errors.new(:invalid_payload, "Transaction is not signed")}
  end

  defp match_chain_id(%V2{chain_id: chain_id}, chain_id), do: :ok

  defp match_chain_id(_tx, _expected) do
    {:error, Errors.new(:verification_failed, "Transaction chainId does not match charge chainId")}
  end

  defp match_currency(%V2{destination: destination}, %Charge{currency: currency}) do
    if Address.equal?(destination, currency) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Transaction to does not match charge currency")}
    end
  end

  defp match_transfer(%V2{data: data}, %Charge{} = charge) do
    with :ok <- require_transfer_selector(data),
         {:ok, [to, amount]} <- decode_transfer(data),
         {:ok, expected} <- Shared.parse_charge_amount(charge.amount) do
      cond do
        !Address.equal?(to, charge.recipient) ->
          {:error, Errors.new(:verification_failed, "Transaction recipient does not match charge recipient")}

        amount != expected ->
          {:error, Errors.new(:verification_failed, "Transaction amount does not match charge amount")}

        true ->
          :ok
      end
    end
  end

  defp require_transfer_selector(<<@transfer_selector, _::binary>>), do: :ok

  defp require_transfer_selector(_data) do
    {:error, Errors.new(:verification_failed, "Transaction is not an ERC-20 transfer")}
  end

  defp decode_transfer(data) do
    case ABI.decode_call(@transfer_fn, Onchain.Hex.encode(data)) do
      {:ok, [to, amount]} -> {:ok, [to, amount]}
      _ -> {:error, Errors.new(:verification_failed, "Transaction is not an ERC-20 transfer")}
    end
  end

  defp check_challenge_expiry(config) do
    case config["challenge_expires"] do
      expires when is_binary(expires) -> parse_expiry(expires)
      _ -> {:error, Errors.new(:verification_failed, "EVM transaction credentials require challenge expiry")}
    end
  end

  defp parse_expiry(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, expires_dt, _offset} -> reject_expired(expires_dt)
      _ -> {:error, Errors.new(:verification_failed, "Challenge expires is not a valid ISO 8601 timestamp")}
    end
  end

  defp reject_expired(expires_dt) do
    if DateTime.before?(DateTime.utc_now(), expires_dt) do
      :ok
    else
      {:error, Errors.new(:payment_expired, "Challenge has expired")}
    end
  end

  defp send_raw(raw, rpc_opts) do
    case RPC.eth_send_raw_transaction(raw, rpc_opts) do
      {:ok, tx_hash} -> {:ok, EvmRPC.canonicalize_hash(tx_hash)}
      {:error, reason} -> wrap_rpc_error(reason)
    end
  end

  defp await_receipt(hash, rpc_opts, deadline) do
    case RPC.get_transaction_receipt(hash, rpc_opts) do
      {:ok, nil} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            @poll_interval_ms -> await_receipt(hash, rpc_opts, deadline)
          end
        else
          {:error, Errors.new(:settlement_timeout, "Transaction settlement was not confirmed")}
        end

      {:ok, _receipt} ->
        :ok

      {:error, reason} ->
        wrap_rpc_error(reason)
    end
  end

  defp deadline(config), do: System.monotonic_time(:millisecond) + Shared.poll_timeout_ms(config)

  defp tx_hash(bytes), do: Onchain.Hex.encode(Hash.keccak(bytes))

  defp wrap_rpc_error(_reason) do
    {:error, Errors.new(:verification_failed, "EVM RPC request failed")}
  end

  defp reject_splits(config) do
    if splits?(config) do
      {:error, Errors.new(:verification_failed, "EVM transaction credentials do not support splits")}
    else
      :ok
    end
  end

  defp splits?(%{"splits" => splits}) when is_list(splits) and splits != [], do: true
  defp splits?(_config), do: false

  defp reject_native(%Charge{currency: currency}) do
    if native?(currency) do
      {:error, Errors.new(:verification_failed, "EVM transaction credentials require an ERC-20 currency")}
    else
      :ok
    end
  end

  defp native?(currency) when is_binary(currency) do
    down = String.downcase(currency)
    down == "eth" or down == "0x0000000000000000000000000000000000000000"
  end

  defp native?(_currency), do: true
end
