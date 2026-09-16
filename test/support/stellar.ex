defmodule MPP.Test.Stellar do
  @moduledoc false

  alias MPP.Intents.Charge
  alias MPP.Methods.Stellar.Envelope
  alias MPP.Methods.Stellar.RPC
  alias StellarBase.StrKey

  @friendbot "https://friendbot.stellar.org"
  @native_sac "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
  @passphrase "Test SDF Network ; September 2015"

  @spec native_sac() :: String.t()
  def native_sac, do: @native_sac

  @spec passphrase() :: String.t()
  def passphrase, do: @passphrase

  @spec address_auth_xdr(String.t(), String.t(), non_neg_integer()) :: String.t()
  def address_auth_xdr(envelope_xdr, account, expiration_ledger)
      when is_binary(envelope_xdr) and is_binary(account) and is_integer(expiration_ledger) do
    alias StellarBase.XDR

    {:ok, inspected} = Envelope.decode(envelope_xdr)
    [operation] = inspected.tx.operations.operations
    args = operation.body.value.host_function.value
    {:ok, raw} = StrKey.decode(account, :ed25519_public_key)
    public = XDR.PublicKey.new(XDR.UInt256.new(raw), XDR.PublicKeyType.new())
    address = XDR.SCAddress.new(XDR.AccountID.new(public), XDR.SCAddressType.new(:SC_ADDRESS_TYPE_ACCOUNT))

    credentials =
      XDR.SorobanAddressCredentials.new(
        address,
        XDR.Int64.new(1),
        XDR.UInt32.new(expiration_ledger),
        XDR.SCVal.new(XDR.Void.new(), XDR.SCValType.new(:SCV_VOID))
      )

    function =
      XDR.SorobanAuthorizedFunction.new(
        args,
        XDR.SorobanAuthorizedFunctionType.new(:SOROBAN_AUTHORIZED_FUNCTION_TYPE_CONTRACT_FN)
      )

    invocation = XDR.SorobanAuthorizedInvocation.new(function, XDR.SorobanAuthorizedInvocationList.new([]))

    credentials
    |> XDR.SorobanCredentials.new(XDR.SorobanCredentialsType.new(:SOROBAN_CREDENTIALS_ADDRESS))
    |> XDR.SorobanAuthorizationEntry.new(invocation)
    |> XDR.SorobanAuthorizationEntry.encode_xdr!()
    |> Base.encode64()
  end

  @spec account_entry_data_xdr(String.t(), non_neg_integer()) :: String.t()
  def account_entry_data_xdr(account, sequence) when is_binary(account) and is_integer(sequence) do
    alias StellarBase.XDR

    {:ok, raw} = StrKey.decode(account, :ed25519_public_key)
    account_id = raw |> XDR.UInt256.new() |> XDR.PublicKey.new(XDR.PublicKeyType.new()) |> XDR.AccountID.new()

    entry =
      XDR.AccountEntry.new(
        account_id,
        XDR.Int64.new(0),
        XDR.SequenceNumber.new(sequence),
        XDR.UInt32.new(0),
        XDR.OptionalAccountID.new(),
        XDR.UInt32.new(0),
        XDR.String32.new(""),
        XDR.Thresholds.new(master_weight: 1, low: 0, med: 0, high: 0),
        XDR.Signers.new([]),
        XDR.AccountEntryExt.new(XDR.Void.new(), 0)
      )

    entry
    |> XDR.LedgerEntryData.new(XDR.LedgerEntryType.new(:ACCOUNT))
    |> XDR.LedgerEntryData.encode_xdr!()
    |> Base.encode64()
  end

  @spec keypair() :: %{public: String.t(), secret: String.t()}
  def keypair do
    {secret, public} = Ed25519.generate_key_pair()

    %{
      public: StrKey.encode!(public, :ed25519_public_key),
      secret: StrKey.encode!(secret, :ed25519_secret_seed)
    }
  end

  @spec fund!(String.t()) :: :ok
  def fund!(account) when is_binary(account) do
    url = @friendbot <> "?addr=" <> URI.encode_www_form(account)

    case Req.get(url, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 400, body: body}} ->
        if already_funded?(body), do: :ok, else: raise("Friendbot rejected #{account}: #{inspect(body)}")

      other ->
        raise("Friendbot failed for #{account}: #{inspect(other)}")
    end
  end

  @spec charge(keyword() | map()) :: Charge.t()
  def charge(attrs) when is_list(attrs), do: charge(Map.new(attrs))

  def charge(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    {:ok, charge} =
      Charge.new(
        amount: Map.get(attrs, :amount, "1000000"),
        currency: Map.get(attrs, :currency, @native_sac),
        recipient: attrs.recipient,
        external_id: Map.get(attrs, :external_id),
        method_details:
          Map.merge(
            %{
              "rpc_url" => attrs.rpc_url,
              "network" => "stellar:testnet",
              "challenge_id" => Map.get(attrs, :challenge_id, "stellar-challenge-#{System.unique_integer([:positive])}"),
              "challenge_expires" => DateTime.to_iso8601(DateTime.shift(now, minute: 5)),
              "store" => Map.get(attrs, :store, false)
            },
            Map.get(attrs, :method_details, %{})
          )
      )

    charge
  end

  @spec prepare_transfer(map(), keyword()) :: %{xdr: String.t(), hash: String.t(), inspected: map()}
  def prepare_transfer(config, opts) do
    source = Keyword.fetch!(opts, :source)
    from = Keyword.get(opts, :from, source.public)
    to = Keyword.fetch!(opts, :to)
    amount = Keyword.get(opts, :amount, 1_000_000)
    contract = Keyword.get(opts, :contract, @native_sac)
    sponsored? = Keyword.get(opts, :sponsored, false)
    max_time = Keyword.get(opts, :max_time, System.os_time(:second) + 300)
    source_account = if sponsored?, do: Envelope.zero_account(), else: source.public
    sequence = if sponsored?, do: 0, else: sequence!(config, source.public)

    {:ok, draft} = Envelope.unsigned(source_account, contract, from, to, amount, max_time)
    {:ok, inspected} = Envelope.decode(draft)
    {:ok, sequenced} = Envelope.rebuild(inspected, source_account, sequence, nil, nil)
    {:ok, simulate_xdr} = unsigned_for_simulate(sequenced)
    {:ok, simulated} = RPC.simulate(simulate_xdr, config)
    auth = simulated["results"] |> List.first(%{}) |> Map.get("auth", [])
    expiration = Map.get(simulated, "latestLedger", 0) + 60

    signed_auth =
      Enum.map(auth, fn entry ->
        case Envelope.sign_auth(entry, source.secret, @passphrase, expiration) do
          {:ok, signed} -> signed
          _ -> entry
        end
      end)

    {:ok, inspected} = Envelope.decode(simulate_xdr)
    {:ok, with_auth} = Envelope.attach_auth(inspected, signed_auth)
    {:ok, inspected} = Envelope.decode(with_auth)

    xdr =
      if sponsored? do
        with_auth
      else
        fee = resource_fee(simulated)
        {:ok, rebuilt} = Envelope.rebuild(inspected, source.public, sequence, simulated["transactionData"], fee)
        {:ok, signed} = Envelope.sign(rebuilt, source.secret, @passphrase)
        signed
      end

    {:ok, inspected} = Envelope.decode(xdr)
    hash = Envelope.hash(inspected.tx, @passphrase)
    %{xdr: xdr, hash: hash, inspected: inspected}
  end

  defp sequence!(config, account) do
    1..10
    |> Enum.reduce_while(nil, fn _attempt, _ ->
      case RPC.account_sequence(account, config) do
        {:ok, sequence} ->
          {:halt, sequence + 1}

        {:error, error} ->
          Process.sleep(500)
          {:cont, error}
      end
    end)
    |> case do
      sequence when is_integer(sequence) -> sequence
      error -> raise "Stellar account sequence unavailable: #{inspect(error)}"
    end
  end

  defp unsigned_for_simulate(tx) do
    envelope =
      tx
      |> StellarBase.XDR.TransactionV1Envelope.new(StellarBase.XDR.DecoratedSignatures.new([]))
      |> StellarBase.XDR.TransactionEnvelope.new(StellarBase.XDR.EnvelopeType.new(:ENVELOPE_TYPE_TX))

    {:ok, Envelope.encode(envelope)}
  end

  defp resource_fee(%{"minResourceFee" => fee}) when is_binary(fee) do
    case Integer.parse(fee) do
      {int, ""} -> int + 100
      _ -> 100
    end
  end

  defp resource_fee(%{"minResourceFee" => fee}) when is_integer(fee), do: fee + 100
  defp resource_fee(_), do: 100

  @spec transfer_event_xdr(String.t(), String.t(), integer(), String.t()) :: String.t()
  def transfer_event_xdr(from, to, amount, contract \\ @native_sac) do
    alias StellarBase.XDR

    topics =
      XDR.SCValList.new([
        XDR.SCVal.new(XDR.SCSymbol.new("transfer"), XDR.SCValType.new(:SCV_SYMBOL)),
        address_scval(from),
        address_scval(to)
      ])

    <<hi::signed-64, lo::unsigned-64>> = <<amount::signed-128>>
    amount_val = XDR.SCVal.new(XDR.Int128Parts.new(XDR.Int64.new(hi), XDR.UInt64.new(lo)), XDR.SCValType.new(:SCV_I128))
    body = XDR.ContractEventBody.new(XDR.ContractEventV0.new(topics, amount_val), 0)
    {:ok, contract_raw} = StrKey.decode(contract, :contract)
    contract_id = XDR.OptionalHash.new(XDR.Hash.new(contract_raw))

    event =
      XDR.ContractEvent.new(
        XDR.ExtensionPoint.new(XDR.Void.new(), 0),
        contract_id,
        XDR.ContractEventType.new(:CONTRACT),
        body
      )

    true
    |> XDR.Bool.new()
    |> XDR.DiagnosticEvent.new(event)
    |> XDR.DiagnosticEvent.encode_xdr!()
    |> Base.encode64()
  end

  defp address_scval(id) do
    alias StellarBase.XDR

    {:ok, raw} = StrKey.decode(id, :ed25519_public_key)
    public = XDR.PublicKey.new(XDR.UInt256.new(raw), XDR.PublicKeyType.new())
    addr = XDR.SCAddress.new(XDR.AccountID.new(public), XDR.SCAddressType.new(:SC_ADDRESS_TYPE_ACCOUNT))
    XDR.SCVal.new(addr, XDR.SCValType.new(:SCV_ADDRESS))
  end

  defp already_funded?(body) when is_map(body) do
    inspect(body) =~ "op_already_exists" or inspect(body) =~ "already funded"
  end

  defp already_funded?(body) when is_binary(body) do
    String.contains?(body, "op_already_exists") or String.contains?(body, "already funded")
  end

  defp already_funded?(_), do: false
end
