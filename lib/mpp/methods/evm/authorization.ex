defmodule MPP.Methods.EVM.Authorization do
  @moduledoc """
  EIP-3009 `transferWithAuthorization` credential for Circle USDC/EURC.

  The client signs an off-chain EIP-712 `TransferWithAuthorization` message.
  The server submits it to the token contract and pays gas. The EIP-3009
  `nonce` is the Payment-auth `challengeHash`:

      keccak256(challenge.id <> challenge.realm)

  matching `draft-evm-charge-00.md` § Authorization Payload and
  `refs/mppx/src/evm/Types.ts` `challengeHash`. Circle FiatTokenV2 enforces
  nonce uniqueness on-chain (`authorizationState`).
  """

  alias Cartouche.Hash
  alias Cartouche.Recover
  alias Cartouche.Typed
  alias Cartouche.Typed.Domain
  alias Cartouche.Typed.Type
  alias Curvy.Signature, as: CurvySignature
  alias MPP.DID
  alias MPP.Errors
  alias MPP.Hex
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias Onchain.ABI
  alias Onchain.Address
  alias Onchain.RPC
  alias Onchain.Signer

  @primary_type "TransferWithAuthorization"
  @transfer_fn "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
  @authorization_state_fn "authorizationState(address,bytes32)"
  @signature_bytes 65
  @nonce_bytes 32
  @gas_headroom_num 5
  @gas_headroom_den 4
  @receipt_poll_interval_ms 3_000
  @receipt_poll_max_attempts 20

  # Live-verified on Ethereum Sepolia (2026-08-19): name()/version() and
  # DOMAIN_SEPARATOR() on the Circle-issued contracts. Mainnet USDC domain
  # name/version from EIP-3009 (eips.ethereum.org/EIPS/eip-3009).
  @known_tokens %{
    {1, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"} => {"USD Coin", "2"},
    {11_155_111, "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238"} => {"USDC", "2"},
    {11_155_111, "0x08210f9170f89ab7658f0b5e3ff39b0e03c594d4"} => {"EURC", "2"}
  }

  @type parsed :: %{
          from: String.t(),
          to: String.t(),
          value: String.t(),
          valid_after: non_neg_integer(),
          valid_before: non_neg_integer(),
          nonce: String.t(),
          signature: String.t()
        }

  @doc """
  Compute the EIP-3009 nonce: `keccak256(challenge.id <> challenge.realm)`.
  """
  @spec challenge_hash(String.t(), String.t()) :: String.t()
  def challenge_hash(id, realm) when is_binary(id) and is_binary(realm) do
    Onchain.Hex.encode(Hash.keccak(id <> realm))
  end

  @doc """
  Return true when this charge can advertise and settle `type=authorization`.
  """
  @spec offered?(Charge.t()) :: boolean()
  def offered?(%Charge{} = charge) do
    config = charge.method_details || %{}

    is_binary(config["private_key"]) and config["private_key"] != "" and
      match?({:ok, _domain}, resolve_domain(charge)) and
      not splits?(config)
  end

  @doc """
  Validate optional `"authorization"` method_config (`name` + `version`).
  """
  @spec validate_config!(term()) :: :ok
  def validate_config!(nil), do: :ok

  def validate_config!(%{"name" => name, "version" => version})
      when is_binary(name) and name != "" and is_binary(version) and version != "" do
    :ok
  end

  def validate_config!(other) do
    raise ArgumentError,
          "MPP.Methods.EVM :authorization must be a map with non-empty string keys " <>
            ~s("name" and "version"; got: #{inspect(other)})
  end

  @doc """
  Validate, recover, and settle an EIP-3009 authorization; return the tx hash.
  """
  @spec settle(map(), Charge.t()) :: {:ok, String.t()} | {:error, Errors.t()}
  def settle(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with {:ok, parsed} <- parse_payload(payload),
         :ok <- reject_splits(config),
         :ok <- reject_native(charge),
         {:ok, domain} <- require_domain(charge),
         :ok <- match_recipient(parsed, charge),
         :ok <- match_amount(parsed, charge),
         :ok <- match_nonce(parsed, config),
         :ok <- check_validity_window(parsed),
         :ok <- verify_signature(parsed, charge, domain),
         :ok <- match_source(parsed, config),
         {:ok, rpc_url} <- require_rpc_url(config),
         {:ok, private_key} <- require_private_key(config),
         {:ok, chain_id} <- require_chain_id(config),
         rpc_opts = rpc_opts(rpc_url, config),
         :ok <- reject_used_nonce(parsed, charge, rpc_opts),
         {:ok, tx_hash} <- broadcast(parsed, charge, private_key, chain_id, rpc_opts),
         :ok <- await_receipt(tx_hash, rpc_opts) do
      {:ok, tx_hash}
    end
  end

  @doc """
  Parse and validate a `type=authorization` credential payload.
  """
  @spec parse_payload(map()) :: {:ok, parsed()} | {:error, Errors.t()}
  def parse_payload(%{"type" => "authorization"} = payload) do
    with {:ok, from} <- require_address(payload, "from"),
         {:ok, to} <- require_address(payload, "to"),
         {:ok, value} <- require_uint_string(payload, "value"),
         {:ok, valid_after} <- require_uint(payload, "validAfter"),
         {:ok, valid_before} <- require_uint(payload, "validBefore"),
         {:ok, nonce} <- require_bytes32(payload, "nonce"),
         {:ok, signature} <- require_signature(payload) do
      {:ok,
       %{
         from: from,
         to: to,
         value: value,
         valid_after: valid_after,
         valid_before: valid_before,
         nonce: nonce,
         signature: signature
       }}
    end
  end

  def parse_payload(_payload) do
    {:error, Errors.new(:invalid_payload, ~s(Missing or invalid 'type' field — expected "authorization"))}
  end

  defp require_domain(charge) do
    case resolve_domain(charge) do
      {:ok, domain} ->
        {:ok, domain}

      {:error, :not_eip3009} ->
        {:error, Errors.new(:verification_failed, "Token does not implement EIP-3009")}
    end
  end

  defp resolve_domain(%Charge{} = charge) do
    config = charge.method_details || %{}

    case config["authorization"] do
      %{"name" => name, "version" => version}
      when is_binary(name) and name != "" and is_binary(version) and version != "" ->
        {:ok, {name, version}}

      _other ->
        lookup_known(config["chain_id"], charge.currency)
    end
  end

  defp lookup_known(chain_id, currency) when is_integer(chain_id) and is_binary(currency) do
    with {:ok, address} <- Address.normalize(currency),
         {:ok, domain} <- Map.fetch(@known_tokens, {chain_id, address}) do
      {:ok, domain}
    else
      _ -> {:error, :not_eip3009}
    end
  end

  defp lookup_known(_chain_id, _currency), do: {:error, :not_eip3009}

  defp reject_splits(config) do
    if splits?(config) do
      {:error, Errors.new(:verification_failed, "EVM authorization does not support splits")}
    else
      :ok
    end
  end

  defp splits?(%{"splits" => splits}) when is_list(splits) and splits != [], do: true
  defp splits?(_config), do: false

  defp reject_native(%Charge{currency: currency}) when is_binary(currency) do
    down = String.downcase(currency)

    if down == "eth" or down == "0x0000000000000000000000000000000000000000" do
      {:error, Errors.new(:verification_failed, "EVM authorization requires an EIP-3009 token currency")}
    else
      :ok
    end
  end

  defp match_recipient(%{to: to}, %Charge{recipient: recipient}) do
    if Address.equal?(to, recipient) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Authorization recipient does not match charge recipient")}
    end
  end

  defp match_amount(%{value: value}, %Charge{amount: amount}) do
    if value == amount do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Authorization amount does not match charge amount")}
    end
  end

  defp match_nonce(%{nonce: nonce}, config) do
    with {:ok, expected} <- expected_challenge_hash(config) do
      if String.downcase(nonce) == String.downcase(expected) do
        :ok
      else
        {:error, Errors.new(:verification_failed, "Authorization nonce does not match challengeHash")}
      end
    end
  end

  defp expected_challenge_hash(config) do
    id = config["challenge_id"]
    realm = config["realm"]

    if is_binary(id) and id != "" and is_binary(realm) and realm != "" do
      {:ok, challenge_hash(id, realm)}
    else
      {:error, Errors.new(:verification_failed, "EVM authorization requires challenge_id and realm")}
    end
  end

  defp check_validity_window(%{valid_after: valid_after, valid_before: valid_before}) do
    now = System.system_time(:second)

    cond do
      now <= valid_after ->
        {:error, Errors.new(:verification_failed, "Authorization is not yet valid")}

      now >= valid_before ->
        {:error, Errors.new(:verification_failed, "Authorization has expired")}

      true ->
        :ok
    end
  end

  defp verify_signature(parsed, charge, {name, version}) do
    config = charge.method_details || %{}

    with {:ok, chain_id} <- require_chain_id(config),
         {:ok, typed} <- typed_data(parsed, charge.currency, chain_id, name, version),
         {:ok, recovered} <- recover_signer(typed, parsed.signature) do
      if Address.equal?(recovered, parsed.from) do
        :ok
      else
        {:error, Errors.new(:verification_failed, "Authorization signature does not match from")}
      end
    end
  end

  defp typed_data(parsed, currency, chain_id, name, version) do
    with {:ok, verifying} <- Address.validate(currency),
         {:ok, from} <- Address.validate(parsed.from),
         {:ok, to} <- Address.validate(parsed.to),
         {:ok, nonce} <- decode_bytes32(parsed.nonce),
         {value, ""} <- Integer.parse(parsed.value) do
      {:ok,
       %Typed{
         domain: %Domain{
           name: name,
           version: version,
           chain_id: chain_id,
           verifying_contract: verifying
         },
         types: authorization_types(),
         value: %{
           "from" => from,
           "to" => to,
           "value" => value,
           "validAfter" => parsed.valid_after,
           "validBefore" => parsed.valid_before,
           "nonce" => nonce
         }
       }}
    else
      _ -> {:error, Errors.new(:invalid_payload, "Invalid authorization typed-data fields")}
    end
  end

  defp authorization_types do
    %{
      @primary_type => %Type{
        fields: [
          {"from", :address},
          {"to", :address},
          {"value", {:uint, 256}},
          {"validAfter", {:uint, 256}},
          {"validBefore", {:uint, 256}},
          {"nonce", {:bytes, 32}}
        ]
      }
    }
  end

  defp recover_signer(typed, signature_hex) do
    digest = typed |> Typed.encode() |> Hash.keccak()

    with {:ok, signature} <- decode_signature(signature_hex),
         {:ok, from_bin} <- signature_address_hint(signature, digest) do
      {:ok, Onchain.Hex.encode(from_bin)}
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> {:error, Errors.new(:verification_failed, "Authorization signature recovery failed")}
    end
  end

  defp signature_address_hint(signature, digest) do
    case Recover.recover_eth_from_digest(digest, signature) do
      address when is_binary(address) and byte_size(address) == 20 -> {:ok, address}
      _ -> :error
    end
  rescue
    _error in [ArgumentError, FunctionClauseError] -> :error
  end

  defp decode_signature(signature_hex) do
    hex = Hex.strip_0x(signature_hex)

    with {:ok, <<r::binary-size(32), s::binary-size(32), v>>} <- Base.decode16(hex, case: :mixed),
         true <- v in [27, 28] do
      {:ok,
       %CurvySignature{
         crv: :secp256k1,
         r: :binary.decode_unsigned(r),
         s: :binary.decode_unsigned(s),
         recid: v - 27
       }}
    else
      _ -> {:error, Errors.new(:invalid_payload, "Invalid authorization signature format")}
    end
  end

  defp match_source(parsed, config) do
    case config["credential_source"] do
      nil -> :ok
      source when is_binary(source) -> match_binary_source(parsed, config, source)
      _other -> source_mismatch()
    end
  end

  defp match_binary_source(parsed, config, source) do
    with {:ok, %{chain_id: chain_id, address: address}} <- parse_source(source),
         {:ok, expected_chain} <- require_chain_id(config),
         true <- chain_id == expected_chain and Address.equal?(address, parsed.from) do
      :ok
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> source_mismatch()
    end
  end

  defp source_mismatch do
    {:error, Errors.new(:verification_failed, "Authorization source does not match from")}
  end

  defp parse_source(source) do
    case DID.parse_evm_did(source) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, Errors.new(:verification_failed, "Authorization source does not match from")}
    end
  end

  defp reject_used_nonce(parsed, charge, rpc_opts) do
    with {:ok, from_bin} <- Address.validate(parsed.from),
         {:ok, nonce_bin} <- decode_bytes32(parsed.nonce),
         {:ok, [used?]} <-
           Onchain.Contract.call(charge.currency, @authorization_state_fn, [from_bin, nonce_bin], "(bool)", rpc_opts) do
      if used? do
        {:error, Errors.new(:verification_failed, "Authorization already used")}
      else
        :ok
      end
    else
      {:error, %Errors{} = error} ->
        {:error, error}

      {:error, reason} ->
        wrap_rpc_error(reason)
    end
  end

  defp broadcast(parsed, charge, private_key, chain_id, rpc_opts) do
    with {:ok, from_bin} <- Address.validate(parsed.from),
         {:ok, to_bin} <- Address.validate(parsed.to),
         {:ok, nonce_bin} <- decode_bytes32(parsed.nonce),
         {:ok, <<r::binary-size(32), s::binary-size(32), v>>} <- decode_signature_bytes(parsed.signature),
         {value, ""} <- Integer.parse(parsed.value),
         {:ok, calldata_hex} <-
           ABI.encode_call(@transfer_fn, [
             from_bin,
             to_bin,
             value,
             parsed.valid_after,
             parsed.valid_before,
             nonce_bin,
             v,
             r,
             s
           ]),
         {:ok, calldata} <- Onchain.Hex.decode(calldata_hex),
         {:ok, sender} <- Signer.address_from_key(private_key),
         {:ok, nonce} <- RPC.get_transaction_count(sender, Keyword.put(rpc_opts, :block, "pending")),
         {:ok, gas} <- estimate_gas(sender, charge.currency, calldata_hex, rpc_opts),
         {:ok, unsigned} <-
           Signer.build_transaction(
             charge.currency,
             calldata,
             tx_build_opts(charge.method_details || %{}, nonce, chain_id, gas)
           ),
         {:ok, signed} <- Signer.sign_transaction(unsigned, private_key, chain_id),
         {:ok, raw} <- Signer.encode_transaction(signed) do
      send_raw(raw, rpc_opts)
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, reason} -> wrap_rpc_error(reason)
      _ -> {:error, Errors.new(:invalid_payload, "Invalid authorization settlement fields")}
    end
  end

  defp send_raw(raw, rpc_opts) do
    case RPC.eth_send_raw_transaction(raw, rpc_opts) do
      {:ok, tx_hash} -> {:ok, canonicalize_hash(tx_hash)}
      {:error, reason} -> wrap_rpc_error(reason)
    end
  end

  defp tx_build_opts(config, nonce, chain_id, gas) do
    [nonce: nonce, chain_id: chain_id, gas_limit: gas]
    |> maybe_put_fee(:max_fee_per_gas, config["max_fee_per_gas"])
    |> maybe_put_fee(:max_priority_fee_per_gas, config["max_priority_fee_per_gas"])
  end

  defp maybe_put_fee(opts, _key, nil), do: opts
  defp maybe_put_fee(opts, key, value), do: Keyword.put(opts, key, value)

  defp estimate_gas(from, to, calldata_hex, rpc_opts) do
    case RPC.eth_estimate_gas(%{from: from, to: to, data: calldata_hex}, rpc_opts) do
      {:ok, gas} -> {:ok, div(gas * @gas_headroom_num + @gas_headroom_den - 1, @gas_headroom_den)}
      {:error, reason} -> wrap_rpc_error(reason)
    end
  end

  defp await_receipt(tx_hash, rpc_opts), do: await_receipt(tx_hash, rpc_opts, 0)

  defp await_receipt(_tx_hash, _rpc_opts, attempt) when attempt >= @receipt_poll_max_attempts do
    {:error, Errors.new(:settlement_timeout, "Authorization settlement was not confirmed")}
  end

  defp await_receipt(tx_hash, rpc_opts, attempt) do
    case RPC.get_transaction_receipt(tx_hash, rpc_opts) do
      {:ok, nil} ->
        Process.sleep(@receipt_poll_interval_ms)
        await_receipt(tx_hash, rpc_opts, attempt + 1)

      {:ok, receipt} ->
        case Shared.check_receipt_status(receipt) do
          :ok ->
            :ok

          {:error, _error} ->
            {:error, Errors.new(:settlement_failed, "Authorization settlement transaction reverted")}
        end

      {:error, reason} ->
        wrap_rpc_error(reason)
    end
  end

  defp require_rpc_url(config) do
    case config["rpc_url"] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, Errors.new(:verification_failed, "EVM method missing required config: rpc_url")}
    end
  end

  defp require_private_key(config) do
    case config["private_key"] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, Errors.new(:verification_failed, "EVM authorization requires private_key")}
    end
  end

  defp require_chain_id(config) do
    case config["chain_id"] do
      chain_id when is_integer(chain_id) and chain_id >= 0 -> {:ok, chain_id}
      _ -> {:error, Errors.new(:verification_failed, "EVM method missing required config: chain_id")}
    end
  end

  defp require_address(payload, key) do
    case payload[key] do
      value when is_binary(value) ->
        case Address.normalize(value) do
          {:ok, address} -> {:ok, address}
          {:error, _} -> {:error, Errors.new(:invalid_payload, "Invalid authorization '#{key}' address")}
        end

      _ ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid authorization '#{key}' field")}
    end
  end

  defp require_uint_string(payload, key) do
    case payload[key] do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> {:ok, value}
          _ -> {:error, Errors.new(:invalid_payload, "Invalid authorization '#{key}' amount")}
        end

      _ ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid authorization '#{key}' field")}
    end
  end

  defp require_uint(payload, key) do
    case payload[key] do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> {:ok, int}
          _ -> {:error, Errors.new(:invalid_payload, "Invalid authorization '#{key}' timestamp")}
        end

      int when is_integer(int) and int >= 0 ->
        {:ok, int}

      _ ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid authorization '#{key}' field")}
    end
  end

  defp require_bytes32(payload, key) do
    case payload[key] do
      value when is_binary(value) ->
        hex = Hex.strip_0x(value)

        if byte_size(hex) == @nonce_bytes * 2 and Hex.hex_string?(hex) do
          {:ok, "0x" <> String.downcase(hex)}
        else
          {:error, Errors.new(:invalid_payload, "Invalid authorization '#{key}' bytes32")}
        end

      _ ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid authorization '#{key}' field")}
    end
  end

  defp require_signature(payload) do
    case payload["signature"] do
      value when is_binary(value) ->
        hex = Hex.strip_0x(value)

        if byte_size(hex) == @signature_bytes * 2 and Hex.hex_string?(hex) do
          {:ok, "0x" <> String.downcase(hex)}
        else
          {:error, Errors.new(:invalid_payload, "Invalid authorization signature format")}
        end

      _ ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid authorization 'signature' field")}
    end
  end

  defp decode_bytes32(hex), do: Onchain.Hex.decode(hex)

  defp decode_signature_bytes(signature_hex), do: Onchain.Hex.decode(signature_hex)

  defp canonicalize_hash(hash) when is_binary(hash) do
    "0x" <> String.downcase(Hex.strip_0x(hash))
  end

  defp rpc_opts(rpc_url, config) do
    case config["req_options"] do
      nil -> [rpc_url: rpc_url]
      req_options -> [rpc_url: rpc_url, req_options: req_options]
    end
  end

  defp wrap_rpc_error(reason) do
    message = rpc_message(reason)

    cond do
      is_binary(message) and String.contains?(message, "authorization is used") ->
        {:error, Errors.new(:verification_failed, "Authorization already used")}

      is_binary(message) and fiat_token_message?(message) ->
        {:error, Errors.new(:settlement_failed, message)}

      true ->
        {:error, Errors.new(:verification_failed, "EVM RPC request failed")}
    end
  end

  defp fiat_token_message?(message) do
    String.contains?(message, "FiatTokenV2:") or
      String.contains?(message, "ERC20:") or
      String.contains?(message, "ECRecover:")
  end

  defp rpc_message({:rpc_error, %{message: message}}) when is_binary(message) do
    strip_revert_prefix(message)
  end

  defp rpc_message(_reason), do: nil

  defp strip_revert_prefix("execution reverted: " <> rest), do: rest
  defp strip_revert_prefix(message), do: message
end
