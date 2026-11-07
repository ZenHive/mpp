defmodule MPP.Methods.Tempo.SponsoredSimulation do
  @moduledoc false

  # Pre-broadcast simulation of a fee-sponsored 0x76 transaction, as two
  # `eth_call`s (mppx `FeePayer.preflightSponsorship`,
  # refs/mppx/src/tempo/internal/fee-payer.ts:433; mpp-rs
  # refs/mpp-rs/src/protocol/methods/tempo/method/simulate.rs:322-366):
  #
  #   1. The sender simulation, before any sponsor signs: the client's
  #      transaction at its exact gas limit, without `feeToken` and with zero
  #      fee fields, so the node bills nobody and checks no fee-token balance
  #      (fee-payer.ts:274 `simulationTransaction`). This is the gas bound: an
  #      under-gassed transaction fails here before the sponsor commits gas.
  #   2. The sponsored simulation, after co-sign: the co-signed transaction with
  #      its fee token and `feePayerSignature` (fee-payer.ts:322
  #      `sponsoredSimulationTransaction`; simulate.rs:253). Tempo nodes v1.18+
  #      bill the fee payer recovered from `feePayerSignature` and the sender
  #      when it is absent, so without it an honest sender that holds none of
  #      the sponsor's fee token is rejected. Verified live on Moderato
  #      (tempo/v1.18.2) 2026-11-07, which also showed the node accepts the
  #      request without a bare `feePayer` address.
  #
  # A sponsored `eth_call` can charge more gas than the mined transaction
  # (cold fee-token slots). The sponsored simulation runs at the broadcast gas
  # limit, so a failure that is only the node's own gas-limit error passes: the
  # sender simulation already bounded gas at that limit (fee-payer.ts:490-492,
  # simulate.rs:357-366). Reverts, fee-balance errors and everything else stay
  # fatal.
  #
  # The node rebuilds the fee-payer signing payload from the request, so both
  # requests carry every signed envelope field (`validAfter` and
  # `keyAuthorization` on top of what `Transaction.simulate_request/1` emits),
  # and the sender signature's `keyType`/`keyData`/`keyId` hints, so the node
  # charges the signature verification gas and access-key limits the broadcast
  # transaction pays (simulate.rs:171-222; fee-payer.ts:278-308). Without the
  # hints the sender simulation would bound gas for a secp256k1 root key.

  alias Onchain.Hash
  alias Onchain.Recover
  alias Onchain.Signature
  alias Onchain.Tempo.Codec
  alias Onchain.Tempo.Transaction

  require Logger

  @execution_reverted 3
  @keychain_v2 0x04
  @rejection_codes [@execution_reverted, -32_000, -32_003]
  @gas_limit_message ~r/\A(?:out of gas|intrinsic gas too low)(?::|\z)/

  @type result :: :ok | {:error, :rejected | :unavailable}

  @doc false
  @spec simulate_sender(Transaction.t(), String.t(), keyword()) :: result()
  def simulate_sender(%Transaction{} = tx, rpc_url, req_options) do
    with {:ok, request} <- sender_request(tx) do
      eth_call(request, rpc_url, req_options, false)
    end
  end

  @doc false
  @spec simulate_sponsored(Transaction.t(), String.t(), keyword()) :: result()
  def simulate_sponsored(%Transaction{} = tx, rpc_url, req_options) do
    with {:ok, request} <- sponsored_request(tx) do
      eth_call(request, rpc_url, req_options, true)
    end
  end

  @doc false
  @spec sender_request(Transaction.t()) :: {:ok, map()} | {:error, :unavailable}
  def sender_request(%Transaction{} = tx) do
    with {:ok, request} <- base_request(tx) do
      {:ok,
       request
       |> Map.delete("feeToken")
       |> Map.merge(%{"maxFeePerGas" => "0x0", "maxPriorityFeePerGas" => "0x0"})}
    end
  end

  @doc false
  @spec sponsored_request(Transaction.t()) :: {:ok, map()} | {:error, :unavailable}
  def sponsored_request(%Transaction{fee_payer_signature: %{r: _, s: _, y_parity: _} = signature} = tx) do
    with {:ok, request} <- base_request(tx) do
      {:ok, Map.put(request, "feePayerSignature", rpc_signature(signature))}
    end
  end

  def sponsored_request(%Transaction{}), do: {:error, :unavailable}

  # The signed envelope fields `Transaction.simulate_request/1` leaves out or
  # omits when zero, each only when set.
  @doc false
  @spec envelope_fields(Transaction.t()) :: map()
  def envelope_fields(%Transaction{} = tx) do
    %{}
    |> put_quantity("nonceKey", tx.nonce_key)
    |> put_quantity("validBefore", tx.valid_before)
    |> put_quantity("validAfter", tx.valid_after)
    |> put_key_authorization(tx.key_authorization)
  end

  defp base_request(tx) do
    with {:ok, request} <- Transaction.simulate_request(tx),
         {:ok, hints} <- key_hints(tx) do
      {:ok, request |> Map.merge(envelope_fields(tx)) |> Map.merge(hints)}
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp put_quantity(map, _key, value) when value in [nil, 0], do: map
  defp put_quantity(map, key, value), do: Map.put(map, key, hex_quantity(value))

  defp put_key_authorization(map, nil), do: map
  defp put_key_authorization(map, authorization), do: Map.put(map, "keyAuthorization", Codec.authorization(authorization))

  # tempo-primitives `KeychainSignature::key_id`: the access key that signed
  # the effective hash, keccak256(0x04 || sig_hash || user_address) for V2 and
  # sig_hash for V1; a P-256 / WebAuthn key is the address of its public key
  # (`derive_p256_address`).
  defp key_hints(%Transaction{signature: {:keychain, version, user, inner}} = tx) do
    with {:ok, key_id} <- keychain_key_id(tx, version, user, inner) do
      {:ok, Map.put(primitive_hints(inner), "keyId", hex(key_id))}
    end
  end

  defp key_hints(%Transaction{signature: {_type, _signature} = signature}), do: {:ok, primitive_hints(signature)}
  defp key_hints(%Transaction{}), do: {:error, :unavailable}

  defp primitive_hints({:secp256k1, _signature}), do: %{"keyType" => "secp256k1"}
  defp primitive_hints({:p256, _signature}), do: %{"keyType" => "p256"}
  defp primitive_hints({:webauthn, %{webauthn_data: data}}), do: %{"keyType" => "webAuthn", "keyData" => hex(data)}

  defp keychain_key_id(_tx, _version, _user, {type, %{pub_key_x: x, pub_key_y: y}}) when type in [:p256, :webauthn],
    do: {:ok, binary_part(Hash.keccak(x <> y), 12, 20)}

  defp keychain_key_id(tx, version, user, {:secp256k1, %{r: r, s: s, y_parity: y_parity}}) do
    with {:ok, sig_hash} <- Transaction.signing_hash(tx) do
      digest = if version == 1, do: sig_hash, else: Hash.keccak(<<@keychain_v2>> <> sig_hash <> user)
      {:ok, Recover.recover_eth_from_digest(digest, %Signature{r: r, s: s, recid: y_parity})}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # JSON-RPC signature form, hex quantities (ox `Signature.toRpc`;
  # simulate.rs:79 `rpc_signature`).
  @doc false
  @spec rpc_signature(%{r: non_neg_integer(), s: non_neg_integer(), y_parity: 0 | 1}) :: map()
  def rpc_signature(%{r: r, s: s, y_parity: y_parity}) do
    %{"r" => hex_quantity(r), "s" => hex_quantity(s), "yParity" => hex_quantity(y_parity)}
  end

  # Whether a node error is only the gas limit: the node's own message starts
  # with "out of gas" or "intrinsic gas too low" followed by ":" or its end.
  # -32003 is shared with the fee-token balance error, so the code alone
  # cannot tell them apart; a revert (code 3) or revert data never counts,
  # because the reverting contract chooses that text (simulate.rs:88-127,
  # fee-payer.ts:544 `isOutOfGasError`).
  @doc false
  @spec gas_limit_error?(term()) :: boolean()
  def gas_limit_error?(%{"code" => code, "message" => message} = error)
      when is_integer(code) and code != @execution_reverted and is_binary(message) do
    not revert_data?(error["data"]) and
      Regex.match?(@gas_limit_message, message |> String.trim() |> String.downcase())
  end

  def gas_limit_error?(_error), do: false

  defp revert_data?(data) when data in [nil, "", "0x"], do: false
  defp revert_data?(_data), do: true

  defp eth_call(request, rpc_url, req_options, tolerate_gas_limit?) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_call", "params" => [request, "latest"], "id" => 1})
    http = [url: rpc_url, method: :post, headers: [{"content-type", "application/json"}], body: body]

    case Req.request(http, req_options) do
      {:ok, %Req.Response{status: status, body: %{"result" => result}}} when status in 200..299 and is_binary(result) ->
        :ok

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        classify(error, tolerate_gas_limit?)

      _other ->
        {:error, :unavailable}
    end
  end

  defp classify(error, true = _tolerate_gas_limit?) do
    if gas_limit_error?(error), do: :ok, else: classify(error, false)
  end

  defp classify(%{"code" => code} = error, false) when code in @rejection_codes do
    Logger.warning("MPP.Methods.Tempo: sponsored transaction rejected in pre-broadcast simulation: #{inspect(error)}")
    {:error, :rejected}
  end

  defp classify(error, false) do
    Logger.warning("MPP.Methods.Tempo: sponsored pre-broadcast simulation failed: #{inspect(error)}")
    {:error, :unavailable}
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  defp hex_quantity(0), do: "0x0"
  defp hex_quantity(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))
end
