defmodule MPP.Methods.EVM.Permit2 do
  @moduledoc """
  EVM Permit2 credentials with challenge-bound witnesses and ordered splits.

  Enable with `"permit2" => true` and a server `"private_key"` in method_config.
  `sign/5` takes the server's transaction-sending address as `spender`; this must
  be agreed with the client because draft-evm-charge-00 does not define spender
  discovery. The payer must already approve the Permit2 contract for the token.

  The draft's exact witness suffix contains a space after the comma. Preserve
  it in the Permit2 root type hash; the nested PaymentWitness struct uses the
  canonical EIP-712 encoding. The canonical contract's batch entry point is an
  overload of `permitWitnessTransferFrom`, not `permitBatchWitnessTransferFrom`.
  """

  alias Cartouche.Hash
  alias Cartouche.Recover
  alias MPP.DID
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM.Authorization
  alias MPP.Methods.EVM.Permit2.Settlement
  alias MPP.Receipt
  alias Onchain.Address
  alias Onchain.Hex
  alias Onchain.Signer

  @address "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  @max_uint 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  @witness_type "PaymentWitness witness)PaymentWitness(bytes32 challengeHash, string externalId)TokenPermissions(address token,uint256 amount)"
  @single "permitWitnessTransferFrom(((address,uint256),uint256,uint256),(address,uint256),address,bytes32,string,bytes)"
  @batch "permitWitnessTransferFrom(((address,uint256)[],uint256,uint256),(address,uint256)[],address,bytes32,string,bytes)"

  @doc "Return whether this charge has an explicitly configured Permit2 settler."
  @spec offered?(Charge.t()) :: boolean()
  def offered?(%Charge{method_details: config} = charge) when is_map(config) do
    configured?(config) and
      match?({:ok, _}, Signer.address_from_key(config["private_key"] || "")) and
      match?({:ok, _}, address(config["permit2_address"] || @address)) and
      match?({:ok, _}, address(charge.currency)) and
      match?({:ok, _}, legs(charge))
  end

  def offered?(_charge), do: false

  defp configured?(config) do
    config["permit2"] == true and is_binary(config["rpc_url"]) and config["rpc_url"] != "" and
      is_integer(config["chain_id"]) and config["chain_id"] > 0 and config["chain_id"] <= @max_uint
  end

  @doc "Sign a credential; nonce and deadline are decimal uint256 strings."
  @spec sign(Charge.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def sign(%Charge{} = charge, private_key, spender, nonce, deadline) do
    with {:ok, transfers} <- legs(charge),
         {:ok, witness} <- expected_witness(charge),
         {:ok, _token} <- address(charge.currency),
         {:ok, key} <- Onchain.PrivateKey.decode(private_key),
         {:ok, owner} <- Signer.address_from_key(private_key) do
      payload = %{
        "type" => "permit2",
        "permit" => %{
          "permitted" => Enum.map(transfers, &%{"token" => charge.currency, "amount" => &1["requestedAmount"]}),
          "nonce" => nonce,
          "deadline" => deadline
        },
        "transferDetails" => transfers,
        "witness" => witness
      }

      with {:ok, digest} <- digest(payload, charge, spender),
           {:ok, signature} <- Cartouche.Signer.Curvy.sign_payload(digest, key),
           signature = Recover.normalize_low_s(signature),
           {:ok, owner_bin} <- address(owner),
           {:ok, recid} <- Recover.find_recid_from_digest(digest, signature, owner_bin) do
        bytes = <<signature.r::256, signature.s::256, recid + 27>>
        {:ok, Map.put(payload, "signature", Hex.encode(bytes))}
      else
        {:error, %Errors{} = error} -> {:error, error}
        _ -> invalid("Unable to sign Permit2 credential")
      end
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> invalid("Invalid Permit2 signing key")
    end
  end

  @doc "Compute the exact draft witness / canonical Permit2 EIP-712 digest."
  @spec digest(map(), Charge.t(), String.t()) :: {:ok, binary()} | {:error, Errors.t()}
  def digest(payload, %Charge{} = charge, spender) do
    config = charge.method_details || %{}

    with {:ok, parsed} <- parse(payload),
         {:ok, spender_bin} <- address(spender),
         {:ok, contract} <- address(config["permit2_address"] || @address),
         chain when is_integer(chain) and chain > 0 and chain <= @max_uint <- config["chain_id"] do
      array? = match?([_, _ | _], parsed.permitted)

      type =
        if array?,
          do: "PermitBatchWitnessTransferFrom(TokenPermissions[]",
          else: "PermitWitnessTransferFrom(TokenPermissions"

      type_hash = Hash.keccak(type <> " permitted,address spender,uint256 nonce,uint256 deadline," <> @witness_type)

      hashes =
        Enum.map(parsed.permitted, fn {token, amount} ->
          Hash.keccak(Hash.keccak("TokenPermissions(address token,uint256 amount)") <> word(token) <> word(amount))
        end)

      permitted_hash = if array?, do: Hash.keccak(IO.iodata_to_binary(hashes)), else: hd(hashes)

      struct_hash =
        Hash.keccak(
          type_hash <>
            permitted_hash <>
            word(spender_bin) <>
            word(parsed.nonce) <> word(parsed.deadline) <> witness_hash(parsed)
        )

      domain =
        Hash.keccak(
          Hash.keccak("EIP712Domain(string name,uint256 chainId,address verifyingContract)") <>
            Hash.keccak("Permit2") <> word(chain) <> word(contract)
        )

      {:ok, Hash.keccak(<<0x19, 0x01>> <> domain <> struct_hash)}
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> invalid("Invalid Permit2 chain_id")
    end
  end

  @doc "Validate the charge binding and recover the payer before any RPC or submission."
  @spec verify(map(), Charge.t()) :: {:ok, String.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with true <- offered?(charge),
         {:ok, parsed} <- parse(payload),
         {:ok, expected} <- legs(charge),
         {:ok, witness} <- expected_witness(charge),
         :ok <- match_witness(payload["witness"], witness),
         :ok <- match_legs(parsed, expected, charge.currency),
         :ok <- not_expired(parsed.deadline),
         {:ok, spender} <- Signer.address_from_key(config["private_key"]),
         {:ok, digest} <- digest(payload, charge, spender),
         {:ok, owner} <- recover(digest, payload["signature"]),
         :ok <- match_source(owner, config) do
      {:ok, owner}
    else
      false -> failed("Permit2 settlement is not configured")
      {:error, %Errors{} = error} -> {:error, error}
      _ -> invalid("Invalid Permit2 credential")
    end
  end

  @doc "Verify, submit, and confirm every ordered transfer in a Permit2 credential."
  @spec settle(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def settle(payload, charge) do
    config = charge.method_details || %{}
    contract = config["permit2_address"] || @address

    with {:ok, owner} <- verify(payload, charge),
         {:ok, parsed} <- parse(payload),
         :ok <- Settlement.check_nonce(contract, owner, parsed.nonce, config),
         {:ok, data} <- calldata(payload, owner),
         {:ok, receipt} <- Settlement.submit(contract, data, config),
         :ok <- match_logs(receipt, parsed, owner) do
      {:ok, Receipt.new(method: "evm", reference: receipt.transaction_hash, external_id: charge.external_id)}
    end
  end

  @doc "Encode the canonical single or batch overload, retaining the draft witness suffix."
  @spec calldata(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def calldata(payload, owner) do
    with {:ok, parsed} <- parse(payload),
         {:ok, owner_bin} <- address(owner),
         {:ok, signature} <- signature_bytes(payload["signature"]) do
      batch? = match?([_, _ | _], parsed.permitted)
      permissions = if batch?, do: parsed.permitted, else: hd(parsed.permitted)
      transfers = if batch?, do: parsed.transfers, else: hd(parsed.transfers)

      Onchain.ABI.encode_call(if(batch?, do: @batch, else: @single), [
        {permissions, parsed.nonce, parsed.deadline},
        transfers,
        owner_bin,
        witness_hash(parsed),
        @witness_type,
        signature
      ])
    end
  end

  defp legs(%Charge{} = charge) do
    config = charge.method_details || %{}
    splits = Map.get(config, "splits", [])

    with {:ok, total} <- uint(charge.amount),
         {:ok, _recipient} <- address(charge.recipient),
         true <- is_list(splits) and Enum.count_until(splits, 11) <= 10,
         true <- not Map.has_key?(config, "splits") or splits != [],
         {:ok, extra} <- map_ok(splits, &split/1),
         sum = Enum.reduce(extra, 0, fn {_to, amount}, sum -> sum + amount end),
         true <- total > sum do
      {:ok,
       [
         %{"to" => charge.recipient, "requestedAmount" => Integer.to_string(total - sum)}
         | Enum.map(extra, fn {to, amount} ->
             %{"to" => Hex.encode(to), "requestedAmount" => Integer.to_string(amount)}
           end)
       ]}
    else
      _ -> invalid("Invalid Permit2 amount, recipient, or splits")
    end
  end

  defp split(%{"recipient" => recipient, "amount" => amount} = split) do
    with {:ok, to} <- address(recipient),
         {:ok, amount} <- uint(amount),
         true <- valid_memo?(split["memo"]) do
      {:ok, {to, amount}}
    else
      _ -> invalid("Invalid Permit2 split")
    end
  end

  defp split(_), do: invalid("Invalid Permit2 split")
  defp valid_memo?(nil), do: true
  defp valid_memo?(memo) when is_binary(memo), do: String.valid?(memo) and String.length(memo) <= 256
  defp valid_memo?(_), do: false

  defp expected_witness(%Charge{} = charge) do
    config = charge.method_details || %{}
    id = config["challenge_id"]
    realm = config["realm"]
    external = charge.external_id || ""

    if is_binary(id) and id != "" and is_binary(realm) and realm != "" and is_binary(external) do
      {:ok, %{"challengeHash" => Authorization.challenge_hash(id, realm), "externalId" => external}}
    else
      invalid("Permit2 requires challenge_id, realm, and a string externalId")
    end
  end

  defp parse(%{"type" => "permit2", "permit" => permit, "transferDetails" => transfers, "witness" => witness})
       when is_map(permit) and is_list(transfers) and is_map(witness) do
    permitted = permit["permitted"]

    with true <- is_list(permitted) and length(permitted) in 1..11 and length(permitted) == length(transfers),
         {:ok, permissions} <- map_ok(permitted, &permission/1),
         {:ok, details} <- map_ok(transfers, &transfer/1),
         {:ok, nonce} <- uint(permit["nonce"]),
         {:ok, deadline} <- uint(permit["deadline"]),
         {:ok, challenge_hash} <- bytes(witness["challengeHash"], 32),
         external when is_binary(external) <- witness["externalId"] do
      {:ok,
       %{
         permitted: permissions,
         transfers: details,
         nonce: nonce,
         deadline: deadline,
         challenge_hash: challenge_hash,
         external_id: external
       }}
    else
      _ -> invalid("Invalid Permit2 permit, transferDetails, or witness")
    end
  end

  defp parse(_), do: invalid("Invalid Permit2 payload")

  defp permission(%{"token" => token, "amount" => amount}), do: pair(token, amount)
  defp permission(_), do: invalid("Invalid Permit2 permission")
  defp transfer(%{"to" => to, "requestedAmount" => amount}), do: pair(to, amount)
  defp transfer(_), do: invalid("Invalid Permit2 transfer")

  defp pair(to, amount) do
    with {:ok, to} <- address(to), {:ok, amount} <- uint(amount), do: {:ok, {to, amount}}
  end

  defp match_witness(actual, expected) do
    if String.downcase(actual["challengeHash"]) == expected["challengeHash"] and
         actual["externalId"] == expected["externalId"], do: :ok, else: failed("Permit2 witness does not match challenge")
  end

  defp match_legs(parsed, expected, currency) do
    {:ok, token} = address(currency)
    {:ok, expected} = map_ok(expected, &transfer/1)

    matches =
      parsed.transfers == expected and
        Enum.all?(Enum.zip(parsed.permitted, parsed.transfers), fn {{t, limit}, {_to, amount}} ->
          t == token and limit >= amount
        end)

    if matches, do: :ok, else: failed("Permit2 ordered transfers do not match charge")
  end

  defp match_logs(receipt, parsed, owner) do
    with {:ok, transfers} <- Onchain.Transfer.parse_logs(receipt.logs),
         actual = Enum.filter(transfers, &Address.equal?(&1.from, owner)),
         expected = Enum.zip(parsed.permitted, parsed.transfers),
         true <- length(actual) == Enum.count(expected, fn {_, {_, amount}} -> amount > 0 end),
         expected = Enum.reject(expected, fn {_, {_, amount}} -> amount == 0 end),
         true <-
           actual
           |> Enum.zip(expected)
           |> Enum.all?(fn {event, {{token, _}, {to, amount}}} ->
             Address.equal?(event.token, Hex.encode(token)) and Address.equal?(event.to, Hex.encode(to)) and
               event.amount == amount
           end) do
      :ok
    else
      _ -> failed("Permit2 receipt does not match ordered transfers")
    end
  end

  defp match_source(_owner, %{"credential_source" => nil}), do: :ok

  defp match_source(owner, %{"credential_source" => source, "chain_id" => chain}) do
    case DID.parse_evm_did(source) do
      {:ok, %{chain_id: ^chain, address: address}} ->
        if Address.equal?(address, owner), do: :ok, else: failed("Permit2 source does not match signer")

      _ ->
        failed("Permit2 source does not match signer")
    end
  end

  defp match_source(_owner, config) when not is_map_key(config, "credential_source"), do: :ok

  defp not_expired(deadline) do
    if deadline >= System.system_time(:second), do: :ok, else: failed("Permit2 permit expired")
  end

  defp recover(digest, signature) do
    with {:ok, <<r::256, s::256, v>>} <- signature_bytes(signature) do
      sig = %Curvy.Signature{crv: :secp256k1, r: r, s: s, recid: v - 27}
      {:ok, Hex.encode(Recover.recover_eth_from_digest(digest, sig))}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, ArithmeticError] -> invalid("Invalid Permit2 signature")
  end

  defp signature_bytes(signature) do
    with {:ok, <<_r::256, _s::256, v>> = bytes} <- bytes(signature, 65), true <- v in [27, 28] do
      {:ok, bytes}
    else
      _ -> invalid("Invalid Permit2 signature")
    end
  end

  defp witness_hash(parsed) do
    Hash.keccak(
      Hash.keccak("PaymentWitness(bytes32 challengeHash,string externalId)") <>
        parsed.challenge_hash <> Hash.keccak(parsed.external_id)
    )
  end

  defp word(int) when is_integer(int), do: <<int::256>>
  defp word(<<address::binary-size(20)>>), do: <<0::96, address::binary>>

  defp address("0x" <> hex = value) when byte_size(hex) == 40 do
    case Address.validate(value) do
      {:ok, <<0::160>>} -> invalid("Permit2 requires nonzero addresses")
      {:ok, address} -> {:ok, address}
      _ -> invalid("Invalid Permit2 address")
    end
  end

  defp address(_), do: invalid("Invalid Permit2 address")

  defp bytes("0x" <> value, size) when byte_size(value) == size * 2 do
    case Base.decode16(value, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> invalid("Invalid Permit2 hex")
    end
  end

  defp bytes(_, _), do: invalid("Invalid Permit2 hex")

  defp uint(value) when is_binary(value) and byte_size(value) in 1..78 do
    case Integer.parse(value) do
      {int, ""} when int >= 0 and int <= @max_uint ->
        if Integer.to_string(int) == value, do: {:ok, int}, else: invalid("Invalid Permit2 uint256")

      _ ->
        invalid("Invalid Permit2 uint256")
    end
  end

  defp uint(_), do: invalid("Invalid Permit2 uint256")

  defp map_ok(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp invalid(detail), do: {:error, Errors.new(:invalid_payload, detail)}
  defp failed(detail), do: {:error, Errors.new(:verification_failed, detail)}
end
