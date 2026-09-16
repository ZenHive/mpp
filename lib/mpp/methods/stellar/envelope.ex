defmodule MPP.Methods.Stellar.Envelope do
  @moduledoc false

  alias MPP.Errors
  alias StellarBase.StrKey
  alias StellarBase.XDR
  alias StellarBase.XDR.Operations.InvokeHostFunction

  @zero_account "GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF"
  @transfer "transfer"
  @xdr_errors [
    ArgumentError,
    ErlangError,
    MatchError,
    FunctionClauseError,
    CaseClauseError,
    Protocol.UndefinedError,
    :"Elixir.XDR.EnumError",
    :"Elixir.XDR.UnionError",
    :"Elixir.XDR.FixedArrayError",
    :"Elixir.XDR.VariableArrayError",
    :"Elixir.XDR.FixedOpaqueError",
    :"Elixir.XDR.VariableOpaqueError",
    :"Elixir.XDR.StructError",
    :"Elixir.XDR.OptionalError",
    :"Elixir.XDR.StringError"
  ]

  @type transfer :: %{contract: String.t(), from: String.t(), to: String.t(), amount: integer()}
  @type auth :: %{
          type: :address | :source_account,
          address: String.t() | nil,
          expiration: non_neg_integer() | nil,
          sub_invocations: non_neg_integer()
        }
  @type inspected :: %{
          source: String.t(),
          transfer: transfer(),
          time_bounds_max: non_neg_integer() | nil,
          auth: [auth()],
          tx: XDR.Transaction.t(),
          envelope: XDR.TransactionEnvelope.t()
        }

  @doc false
  @spec zero_account() :: String.t()
  def zero_account, do: @zero_account

  @doc false
  @spec decode(String.t()) :: {:ok, inspected()} | {:error, Errors.t()}
  def decode(xdr) when is_binary(xdr) do
    with {:ok, bytes} <- decode64(xdr),
         {:ok, envelope} <- decode_envelope(bytes),
         {:ok, tx} <- transaction(envelope),
         {:ok, source} <- account_id(tx.source_account),
         {:ok, op} <- single_invoke(tx),
         {:ok, transfer} <- transfer(op),
         {:ok, auth} <- auth_entries(op) do
      {:ok,
       %{
         source: source,
         transfer: transfer,
         time_bounds_max: time_bounds_max(tx.preconditions),
         auth: auth,
         tx: tx,
         envelope: envelope
       }}
    end
  rescue
    _ in @xdr_errors -> malformed()
  end

  def decode(_), do: malformed()

  @doc false
  @spec hash(XDR.Transaction.t(), String.t()) :: String.t()
  def hash(%XDR.Transaction{} = tx, passphrase) when is_binary(passphrase) do
    tx
    |> payload_hash(passphrase)
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec encode(inspected() | XDR.TransactionEnvelope.t()) :: String.t()
  def encode(%XDR.TransactionEnvelope{} = envelope) do
    envelope
    |> XDR.TransactionEnvelope.encode_xdr!()
    |> Base.encode64()
  end

  def encode(%{envelope: %XDR.TransactionEnvelope{} = envelope}), do: encode(envelope)

  @doc false
  @spec signed_by_source?(inspected(), String.t()) :: boolean()
  def signed_by_source?(%{tx: tx, envelope: envelope, source: source}, passphrase) when is_binary(passphrase) do
    with {:ok, raw} <- StrKey.decode(source, :ed25519_public_key),
         {:ok, signatures} <- v1_signatures(envelope) do
      payload = payload_hash(tx, passphrase)

      Enum.any?(signatures, fn
        %XDR.DecoratedSignature{signature: %XDR.Signature{signature: signature}} ->
          Ed25519.valid_signature?(signature, payload, raw)

        _ ->
          false
      end)
    else
      _ -> false
    end
  end

  def signed_by_source?(_, _), do: false

  @doc false
  @spec rebuild(inspected(), String.t(), non_neg_integer(), String.t() | nil, pos_integer() | nil) ::
          {:ok, XDR.Transaction.t()} | {:error, Errors.t()}
  def rebuild(inspected, source, sequence, soroban_data, fee)

  def rebuild(%{tx: tx}, source, sequence, soroban_data, fee) when is_binary(source) and is_integer(sequence) do
    with {:ok, account} <- muxed_account(source),
         {:ok, ext} <- transaction_ext(tx, soroban_data) do
      {:ok,
       XDR.Transaction.new(
         account,
         XDR.UInt32.new(fee || tx.fee.datum),
         XDR.SequenceNumber.new(sequence),
         tx.preconditions,
         tx.memo,
         tx.operations,
         ext
       )}
    end
  rescue
    _ in @xdr_errors -> malformed()
  end

  @doc false
  @spec sign(XDR.Transaction.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, Errors.t()}
  def sign(%XDR.Transaction{} = tx, secret, passphrase) when is_binary(secret) and is_binary(passphrase) do
    case StrKey.decode(secret, :ed25519_secret_seed) do
      {:ok, raw_secret} ->
        public = Ed25519.derive_public_key(raw_secret)
        hint = signature_hint(public)
        payload = payload_hash(tx, passphrase)
        signature = Ed25519.signature(payload, raw_secret)

        decorated =
          hint
          |> XDR.SignatureHint.new()
          |> XDR.DecoratedSignature.new(XDR.Signature.new(signature))

        envelope =
          tx
          |> XDR.TransactionV1Envelope.new(XDR.DecoratedSignatures.new([decorated]))
          |> XDR.TransactionEnvelope.new(XDR.EnvelopeType.new(:ENVELOPE_TYPE_TX))

        {:ok, encode(envelope)}

      _ ->
        {:error, Errors.new(:verification_failed, "Invalid Stellar fee-payer secret")}
    end
  end

  @doc false
  @spec sign_auth(String.t(), String.t(), String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, Errors.t()}
  def sign_auth(auth_xdr, secret, passphrase, expiration_ledger)
      when is_binary(auth_xdr) and is_binary(secret) and is_binary(passphrase) and is_integer(expiration_ledger) do
    with {:ok, bytes} <- Base.decode64(auth_xdr),
         {%XDR.SorobanAuthorizationEntry{} = entry, ""} <- XDR.SorobanAuthorizationEntry.decode_xdr!(bytes),
         {:ok, raw_secret} <- StrKey.decode(secret, :ed25519_secret_seed),
         %XDR.SorobanCredentials{
           type: %XDR.SorobanCredentialsType{identifier: :SOROBAN_CREDENTIALS_ADDRESS},
           value: %XDR.SorobanAddressCredentials{} = credentials
         } <- entry.credentials do
      expiration = XDR.UInt32.new(expiration_ledger)
      network_id = XDR.Hash.new(:crypto.hash(:sha256, passphrase))

      payload =
        network_id
        |> XDR.HashIDPreimageSorobanAuthorization.new(credentials.nonce, expiration, entry.root_invocation)
        |> XDR.HashIDPreimage.new(XDR.EnvelopeType.new(:ENVELOPE_TYPE_SOROBAN_AUTHORIZATION))
        |> XDR.HashIDPreimage.encode_xdr!()
        |> then(&:crypto.hash(:sha256, &1))

      public = Ed25519.derive_public_key(raw_secret)
      signature = Ed25519.signature(payload, raw_secret)

      signed = %{
        credentials
        | signature_expiration_ledger: expiration,
          signature: auth_signature_val(public, signature)
      }

      credentials_union =
        XDR.SorobanCredentials.new(signed, XDR.SorobanCredentialsType.new(:SOROBAN_CREDENTIALS_ADDRESS))

      encoded =
        credentials_union
        |> XDR.SorobanAuthorizationEntry.new(entry.root_invocation)
        |> XDR.SorobanAuthorizationEntry.encode_xdr!()
        |> Base.encode64()

      {:ok, encoded}
    else
      _ -> malformed()
    end
  rescue
    _ in @xdr_errors -> malformed()
  end

  @doc false
  @spec attach_auth(inspected(), [String.t()]) :: {:ok, String.t()} | {:error, Errors.t()}
  def attach_auth(%{tx: tx, envelope: envelope}, auth_xdrs) when is_list(auth_xdrs) do
    with {:ok, op} <- single_invoke(tx),
         {:ok, entries} <- decode_auth_list(auth_xdrs) do
      invoke = InvokeHostFunction.new(op.host_function, XDR.SorobanAuthorizationEntryList.new(entries))
      body = XDR.OperationBody.new(invoke, XDR.OperationType.new(:INVOKE_HOST_FUNCTION))
      operation = XDR.Operation.new(body, hd(tx.operations.operations).source_account)
      new_tx = %{tx | operations: XDR.Operations.new([operation])}

      envelope = %{envelope | envelope: %{envelope.envelope | tx: new_tx}}
      {:ok, encode(envelope)}
    end
  rescue
    _ in @xdr_errors -> malformed()
  end

  @doc false
  @spec set_ext(inspected(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, Errors.t()}
  def set_ext(%{tx: tx, envelope: envelope}, soroban_data, fee) when is_binary(soroban_data) and is_integer(fee) do
    with {:ok, bytes} <- Base.decode64(soroban_data),
         {%XDR.SorobanTransactionData{} = data, ""} <- XDR.SorobanTransactionData.decode_xdr!(bytes) do
      new_tx = %{tx | ext: XDR.TransactionExt.new(data, 1), fee: XDR.UInt32.new(fee)}
      envelope = %{envelope | envelope: %{envelope.envelope | tx: new_tx}}
      {:ok, encode(envelope)}
    else
      _ -> malformed()
    end
  rescue
    _ in @xdr_errors -> malformed()
  end

  @doc false
  @spec unsigned(String.t(), String.t(), String.t(), String.t(), integer(), non_neg_integer() | nil) ::
          {:ok, String.t()} | {:error, Errors.t()}
  def unsigned(source, contract, from, to, amount, max_time) do
    with {:ok, account} <- muxed_account(source),
         {:ok, host} <- invoke_contract(contract, from, to, amount) do
      invoke = InvokeHostFunction.new(host, XDR.SorobanAuthorizationEntryList.new([]))
      body = XDR.OperationBody.new(invoke, XDR.OperationType.new(:INVOKE_HOST_FUNCTION))
      operation = XDR.Operation.new(body, XDR.OptionalMuxedAccount.new())
      preconditions = preconditions(max_time)

      tx =
        XDR.Transaction.new(
          account,
          XDR.UInt32.new(100),
          XDR.SequenceNumber.new(0),
          preconditions,
          XDR.Memo.new(XDR.Void.new(), XDR.MemoType.new(:MEMO_NONE)),
          XDR.Operations.new([operation]),
          XDR.TransactionExt.new(XDR.Void.new(), 0)
        )

      envelope =
        tx
        |> XDR.TransactionV1Envelope.new(XDR.DecoratedSignatures.new([]))
        |> XDR.TransactionEnvelope.new(XDR.EnvelopeType.new(:ENVELOPE_TYPE_TX))

      {:ok, encode(envelope)}
    end
  end

  @doc false
  @spec contract_events([String.t()]) :: [map()]
  def contract_events(events) when is_list(events) do
    Enum.flat_map(events, &decode_event/1)
  end

  def contract_events(_), do: []

  @doc false
  @spec expected_transfer?([map()], transfer()) :: boolean()
  def expected_transfer?(events, %{from: from, to: to, amount: amount, contract: contract}) do
    case Enum.filter(events, &(&1.name in ~w(transfer mint burn clawback))) do
      [%{name: "transfer", from: ^from, to: ^to, amount: ^amount, contract: event_contract}] ->
        is_nil(event_contract) or event_contract == contract

      _ ->
        false
    end
  end

  defp transaction_ext(_tx, data) when is_binary(data) and data != "" do
    with {:ok, bytes} <- Base.decode64(data),
         {%XDR.SorobanTransactionData{} = decoded, ""} <- XDR.SorobanTransactionData.decode_xdr!(bytes) do
      {:ok, XDR.TransactionExt.new(decoded, 1)}
    else
      _ -> malformed()
    end
  end

  defp transaction_ext(tx, _), do: {:ok, tx.ext}

  defp decode_envelope(bytes) do
    case XDR.TransactionEnvelope.decode_xdr(bytes) do
      {:ok, {envelope, ""}} -> {:ok, envelope}
      _ -> malformed()
    end
  end

  defp transaction(%XDR.TransactionEnvelope{
         type: %XDR.EnvelopeType{identifier: :ENVELOPE_TYPE_TX},
         envelope: %XDR.TransactionV1Envelope{tx: tx}
       }), do: {:ok, tx}

  defp transaction(%XDR.TransactionEnvelope{
         type: %XDR.EnvelopeType{identifier: :ENVELOPE_TYPE_TX_FEE_BUMP},
         envelope: %XDR.FeeBumpTransactionEnvelope{
           tx: %XDR.FeeBumpTransaction{inner_tx: %XDR.FeeBumpInnerTx{envelope: %XDR.TransactionV1Envelope{tx: tx}}}
         }
       }), do: {:ok, tx}

  defp transaction(_), do: malformed()

  defp v1_signatures(%XDR.TransactionEnvelope{
         type: %XDR.EnvelopeType{identifier: :ENVELOPE_TYPE_TX},
         envelope: %XDR.TransactionV1Envelope{signatures: %XDR.DecoratedSignatures{signatures: signatures}}
       }) do
    {:ok, signatures}
  end

  defp v1_signatures(%XDR.TransactionEnvelope{
         type: %XDR.EnvelopeType{identifier: :ENVELOPE_TYPE_TX_FEE_BUMP},
         envelope: %XDR.FeeBumpTransactionEnvelope{
           tx: %XDR.FeeBumpTransaction{
             inner_tx: %XDR.FeeBumpInnerTx{
               envelope: %XDR.TransactionV1Envelope{signatures: %XDR.DecoratedSignatures{signatures: signatures}}
             }
           }
         }
       }) do
    {:ok, signatures}
  end

  defp v1_signatures(_), do: :error

  defp single_invoke(%XDR.Transaction{operations: %XDR.Operations{operations: [operation]}}) do
    case operation.body do
      %XDR.OperationBody{
        type: %XDR.OperationType{identifier: :INVOKE_HOST_FUNCTION},
        value: %InvokeHostFunction{} = invoke
      } ->
        {:ok, invoke}

      _ ->
        {:error, Errors.new(:verification_failed, "Stellar transaction must invoke a contract")}
    end
  end

  defp single_invoke(_),
    do: {:error, Errors.new(:verification_failed, "Stellar transaction must contain exactly one operation")}

  defp transfer(%InvokeHostFunction{
         host_function: %XDR.HostFunction{
           type: %XDR.HostFunctionType{identifier: :HOST_FUNCTION_TYPE_INVOKE_CONTRACT},
           value: %XDR.InvokeContractArgs{
             contract_address: contract,
             function_name: %XDR.SCSymbol{value: @transfer},
             args: %XDR.SCValList{items: [from, to, amount]}
           }
         }
       }) do
    with {:ok, contract_id} <- sc_address(contract),
         {:ok, from_id} <- sc_val_address(from),
         {:ok, to_id} <- sc_val_address(to),
         {:ok, value} <- sc_val_i128(amount) do
      {:ok, %{contract: contract_id, from: from_id, to: to_id, amount: value}}
    else
      _ -> {:error, Errors.new(:verification_failed, "Stellar invoke is not a SEP-41 transfer")}
    end
  end

  defp transfer(_), do: {:error, Errors.new(:verification_failed, "Stellar invoke is not a SEP-41 transfer")}

  defp auth_entries(%InvokeHostFunction{auth: %XDR.SorobanAuthorizationEntryList{items: items}}) do
    {:ok, Enum.map(items, &auth_entry/1)}
  end

  defp auth_entry(%XDR.SorobanAuthorizationEntry{credentials: credentials, root_invocation: invocation}) do
    %XDR.SorobanAuthorizedInvocation{sub_invocations: %XDR.SorobanAuthorizedInvocationList{items: items}} = invocation
    subs = length(items)

    case credentials do
      %XDR.SorobanCredentials{
        type: %XDR.SorobanCredentialsType{identifier: :SOROBAN_CREDENTIALS_ADDRESS},
        value: %XDR.SorobanAddressCredentials{address: address, signature_expiration_ledger: expiration}
      } ->
        {:ok, encoded} = sc_address(address)
        auth_record(:address, encoded, expiration.datum, subs)

      %XDR.SorobanCredentials{type: %XDR.SorobanCredentialsType{identifier: :SOROBAN_CREDENTIALS_SOURCE_ACCOUNT}} ->
        auth_record(:source_account, nil, nil, subs)
    end
  end

  defp time_bounds_max(%XDR.Preconditions{
         type: %XDR.PreconditionType{identifier: :PRECOND_TIME},
         preconditions: %XDR.TimeBounds{max_time: %XDR.TimePoint{value: value}}
       }), do: value

  defp time_bounds_max(%XDR.Preconditions{
         type: %XDR.PreconditionType{identifier: :PRECOND_V2},
         preconditions: %XDR.PreconditionsV2{time_bounds: time_bounds}
       }) do
    case time_bounds do
      %{time_bounds: %XDR.TimeBounds{max_time: %XDR.TimePoint{value: value}}} -> value
      _ -> nil
    end
  end

  defp time_bounds_max(_), do: nil

  defp account_id(%XDR.MuxedAccount{
         type: %XDR.CryptoKeyType{identifier: :KEY_TYPE_ED25519},
         account: %XDR.UInt256{datum: raw}
       }) do
    {:ok, StrKey.encode!(raw, :ed25519_public_key)}
  end

  defp account_id(%XDR.MuxedAccount{
         type: %XDR.CryptoKeyType{identifier: :KEY_TYPE_MUXED_ED25519},
         account: %XDR.MuxedAccountMed25519{ed25519: %XDR.UInt256{datum: raw}}
       }) do
    {:ok, StrKey.encode!(raw, :ed25519_public_key)}
  end

  defp muxed_account(account) when is_binary(account) do
    case StrKey.decode(account, :ed25519_public_key) do
      {:ok, raw} -> {:ok, XDR.MuxedAccount.new(XDR.UInt256.new(raw), XDR.CryptoKeyType.new(:KEY_TYPE_ED25519))}
      _ -> {:error, Errors.new(:verification_failed, "Invalid Stellar account")}
    end
  end

  defp invoke_contract(contract, from, to, amount) do
    with {:ok, contract_addr} <- contract_address(contract),
         {:ok, from_val} <- address_val(from),
         {:ok, to_val} <- address_val(to) do
      args =
        XDR.InvokeContractArgs.new(
          contract_addr,
          XDR.SCSymbol.new(@transfer),
          XDR.SCValList.new([from_val, to_val, i128_val(amount)])
        )

      {:ok, XDR.HostFunction.new(args, XDR.HostFunctionType.new(:HOST_FUNCTION_TYPE_INVOKE_CONTRACT))}
    end
  end

  defp contract_address(id) do
    case StrKey.decode(id, :contract) do
      {:ok, raw} -> {:ok, XDR.SCAddress.new(XDR.Hash.new(raw), XDR.SCAddressType.new(:SC_ADDRESS_TYPE_CONTRACT))}
      _ -> {:error, Errors.new(:verification_failed, "Invalid SEP-41 contract address")}
    end
  end

  defp address_val(id) do
    with {:ok, addr} <- account_address(id) do
      {:ok, XDR.SCVal.new(addr, XDR.SCValType.new(:SCV_ADDRESS))}
    end
  end

  defp account_address(id) do
    case StrKey.decode(id, :ed25519_public_key) do
      {:ok, raw} ->
        public = XDR.PublicKey.new(XDR.UInt256.new(raw), XDR.PublicKeyType.new())
        {:ok, XDR.SCAddress.new(XDR.AccountID.new(public), XDR.SCAddressType.new(:SC_ADDRESS_TYPE_ACCOUNT))}

      _ ->
        {:error, Errors.new(:verification_failed, "Invalid Stellar account")}
    end
  end

  defp i128_val(amount) when is_integer(amount) do
    <<hi::signed-64, lo::unsigned-64>> = <<amount::signed-128>>
    parts = XDR.Int128Parts.new(XDR.Int64.new(hi), XDR.UInt64.new(lo))
    XDR.SCVal.new(parts, XDR.SCValType.new(:SCV_I128))
  end

  defp sc_val_address(%XDR.SCVal{type: %XDR.SCValType{identifier: :SCV_ADDRESS}, value: address}), do: sc_address(address)
  defp sc_val_address(_), do: :error

  defp sc_address(%XDR.SCAddress{
         type: %XDR.SCAddressType{identifier: :SC_ADDRESS_TYPE_ACCOUNT},
         sc_address: %XDR.AccountID{account_id: %XDR.PublicKey{public_key: %XDR.UInt256{datum: raw}}}
       }) do
    {:ok, StrKey.encode!(raw, :ed25519_public_key)}
  end

  defp sc_address(%XDR.SCAddress{
         type: %XDR.SCAddressType{identifier: :SC_ADDRESS_TYPE_CONTRACT},
         sc_address: %XDR.Hash{value: raw}
       }) do
    {:ok, StrKey.encode!(raw, :contract)}
  end

  defp sc_address(%XDR.SCAddress{
         type: %XDR.SCAddressType{identifier: :SC_ADDRESS_TYPE_MUXED_ACCOUNT},
         sc_address: %XDR.MuxedEd25519Account{ed25519: %XDR.UInt256{datum: raw}}
       }) do
    {:ok, StrKey.encode!(raw, :ed25519_public_key)}
  end

  defp sc_address(_), do: :error

  defp sc_val_i128(%XDR.SCVal{
         type: %XDR.SCValType{identifier: :SCV_I128},
         value: %XDR.Int128Parts{hi: %XDR.Int64{datum: hi}, lo: %XDR.UInt64{datum: lo}}
       }) do
    <<amount::signed-128>> = <<hi::signed-64, lo::unsigned-64>>
    {:ok, amount}
  end

  defp sc_val_i128(_), do: :error

  defp preconditions(nil), do: XDR.Preconditions.new(XDR.Void.new(), XDR.PreconditionType.new(:PRECOND_NONE))

  defp preconditions(max_time) when is_integer(max_time) do
    bounds = XDR.TimeBounds.new(XDR.TimePoint.new(0), XDR.TimePoint.new(max_time))
    XDR.Preconditions.new(bounds, XDR.PreconditionType.new(:PRECOND_TIME))
  end

  defp payload_hash(tx, passphrase) do
    tagged = XDR.TransactionSignaturePayloadTaggedTransaction.new(tx, XDR.EnvelopeType.new(:ENVELOPE_TYPE_TX))

    passphrase
    |> then(&:crypto.hash(:sha256, &1))
    |> XDR.Hash.new()
    |> XDR.TransactionSignaturePayload.new(tagged)
    |> XDR.TransactionSignaturePayload.encode_xdr!()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp signature_hint(public_key) do
    encoded =
      public_key
      |> XDR.UInt256.new()
      |> XDR.PublicKey.new(XDR.PublicKeyType.new())
      |> XDR.PublicKey.encode_xdr!()

    binary_part(encoded, byte_size(encoded) - 4, 4)
  end

  defp auth_signature_val(public_key, signature) do
    pk = XDR.SCMapEntry.new(symbol_val("public_key"), bytes_val(public_key))
    sig = XDR.SCMapEntry.new(symbol_val("signature"), bytes_val(signature))
    map = XDR.OptionalSCMap.new(XDR.SCMap.new([pk, sig]))
    vec = XDR.OptionalSCVec.new(XDR.SCVec.new([XDR.SCVal.new(map, XDR.SCValType.new(:SCV_MAP))]))
    XDR.SCVal.new(vec, XDR.SCValType.new(:SCV_VEC))
  end

  defp symbol_val(name), do: XDR.SCVal.new(XDR.SCSymbol.new(name), XDR.SCValType.new(:SCV_SYMBOL))
  defp bytes_val(bytes), do: XDR.SCVal.new(XDR.SCBytes.new(bytes), XDR.SCValType.new(:SCV_BYTES))

  defp decode_auth_list(xdrs) do
    xdrs
    |> Enum.reduce_while({:ok, []}, fn xdr, {:ok, acc} ->
      with {:ok, bytes} <- Base.decode64(xdr),
           {%XDR.SorobanAuthorizationEntry{} = entry, ""} <- XDR.SorobanAuthorizationEntry.decode_xdr!(bytes) do
        {:cont, {:ok, [entry | acc]}}
      else
        _ -> {:halt, malformed()}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      other -> other
    end
  end

  defp decode_event(xdr) when is_binary(xdr) do
    with {:ok, bytes} <- Base.decode64(xdr),
         event when is_map(event) <- event_from_bytes(bytes) do
      [event]
    else
      _ -> []
    end
  end

  defp decode_event(_), do: []

  defp event_from_bytes(bytes) do
    diagnostic_event(bytes) || contract_event_from_bytes(bytes)
  end

  defp diagnostic_event(bytes) do
    case XDR.DiagnosticEvent.decode_xdr(bytes) do
      {:ok, {%XDR.DiagnosticEvent{event: event}, ""}} -> contract_event(event)
      _ -> nil
    end
  rescue
    _ in @xdr_errors -> nil
  end

  defp contract_event_from_bytes(bytes) do
    case XDR.ContractEvent.decode_xdr(bytes) do
      {:ok, {event, ""}} -> contract_event(event)
      _ -> nil
    end
  rescue
    _ in @xdr_errors -> nil
  end

  defp contract_event(%XDR.ContractEvent{
         type: %XDR.ContractEventType{identifier: type},
         contract_id: contract_id,
         body: %XDR.ContractEventBody{value: %XDR.ContractEventV0{topics: %XDR.SCValList{items: topics}, data: data}}
       })
       when type in [:CONTRACT, :DIAGNOSTIC] do
    name = topic_symbol(List.first(topics))
    addresses = topics |> Enum.drop(1) |> Enum.flat_map(&address_topic/1)

    %{
      name: name,
      from: Enum.at(addresses, 0),
      to: Enum.at(addresses, 1),
      amount: event_amount(data),
      contract: optional_contract(contract_id)
    }
  end

  defp contract_event(_), do: nil

  defp topic_symbol(%XDR.SCVal{type: %XDR.SCValType{identifier: :SCV_SYMBOL}, value: %XDR.SCSymbol{value: value}}),
    do: value

  defp topic_symbol(_), do: nil

  defp address_topic(val) do
    case sc_val_address(val) do
      {:ok, address} -> [address]
      _ -> []
    end
  end

  defp event_amount(%XDR.SCVal{type: %XDR.SCValType{identifier: :SCV_I128}} = val) do
    {:ok, amount} = sc_val_i128(val)
    amount
  end

  defp event_amount(%XDR.SCVal{
         type: %XDR.SCValType{identifier: :SCV_MAP},
         value: %XDR.OptionalSCMap{sc_map: %XDR.SCMap{items: items}}
       }) do
    Enum.find_value(items, fn
      %XDR.SCMapEntry{key: %XDR.SCVal{value: %XDR.SCSymbol{value: "amount"}}, val: val} ->
        case sc_val_i128(val) do
          {:ok, amount} -> amount
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp event_amount(_), do: nil

  defp optional_contract(%XDR.OptionalHash{hash: %XDR.Hash{value: raw}}), do: StrKey.encode!(raw, :contract)
  defp optional_contract(_), do: nil

  defp decode64(xdr) do
    case Base.decode64(xdr) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> malformed()
    end
  end

  defp auth_record(type, address, expiration, sub_invocations) do
    %{type: type, address: address, expiration: expiration, sub_invocations: sub_invocations}
  end

  defp malformed, do: {:error, Errors.new(:malformed_credential, "Malformed Stellar transaction XDR")}
end
