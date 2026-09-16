defmodule MPP.Methods.StellarTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Stellar
  alias MPP.Methods.Stellar.Envelope
  alias MPP.Methods.Stellar.RPC
  alias MPP.Receipt
  alias MPP.Test.Stellar, as: Fixtures

  @rpc_url "https://soroban-testnet.stellar.org"
  @passphrase "Test SDF Network ; September 2015"
  @native_sac Fixtures.native_sac()

  defmodule MemoryStore do
    @moduledoc false
    @behaviour MPP.Tempo.Store

    use Agent

    def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    @impl true
    def get(key) do
      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil -> :not_found
        value -> {:ok, value}
      end
    end

    @impl true
    def put(key, value) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
      :ok
    end

    @impl true
    def check_and_mark(key, value) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Map.has_key?(state, key),
          do: {{:error, :already_exists}, state},
          else: {:ok, Map.put(state, key, value)}
      end)
    end
  end

  setup do
    start_supervised!(MemoryStore)
    payer = Fixtures.keypair()
    recipient = Fixtures.keypair()

    {:ok, unsigned} =
      Envelope.unsigned(
        payer.public,
        @native_sac,
        payer.public,
        recipient.public,
        1_000_000,
        System.os_time(:second) + 300
      )

    {:ok, inspected} = Envelope.decode(unsigned)
    {:ok, signed} = Envelope.sign(inspected.tx, payer.secret, @passphrase)
    hash = Envelope.hash(inspected.tx, @passphrase)

    {:ok, charge} =
      Charge.new(
        amount: "1000000",
        currency: @native_sac,
        recipient: recipient.public,
        method_details: %{
          "rpc_url" => @rpc_url,
          "network" => "stellar:testnet",
          "challenge_id" => "stellar-unit-#{System.unique_integer([:positive])}",
          "challenge_expires" => DateTime.to_iso8601(DateTime.shift(DateTime.utc_now(), minute: 5)),
          "store" => MemoryStore,
          "req_options" => [plug: {Req.Test, __MODULE__}]
        }
      )

    {:ok,
     payer: payer,
     recipient: recipient,
     unsigned: unsigned,
     signed: signed,
     hash: hash,
     charge: charge,
     inspected: inspected}
  end

  test "wire names and advertised fields match the draft", context do
    assert Stellar.method_name() == "stellar"
    assert Stellar.credential_types() == ~w(transaction hash)
    assert :ok = Stellar.validate_config!(context.charge.method_details)

    details = Stellar.challenge_method_details(context.charge)
    assert details["network"] == "stellar:testnet"
    assert details["feePayer"] == false
    assert details["credentialTypes"] == ~w(transaction hash)
    refute Map.has_key?(details, "rpc_url")
    refute Map.has_key?(details, "store")
    refute Map.has_key?(details, "fee_payer_secret")
  end

  test "validate_config! rejects missing rpc, network and fee-payer secret" do
    assert_raise ArgumentError, fn -> Stellar.validate_config!(%{}) end

    assert_raise ArgumentError, fn ->
      Stellar.validate_config!(%{"rpc_url" => @rpc_url, "network" => "stellar:devnet"})
    end

    assert_raise ArgumentError, fn ->
      Stellar.validate_config!(%{"rpc_url" => @rpc_url, "network" => "stellar:testnet", "fee_payer" => true})
    end

    secret = Fixtures.keypair().secret

    assert :ok =
             Stellar.validate_config!(%{
               "rpc_url" => @rpc_url,
               "network" => "stellar:pubnet",
               "fee_payer" => true,
               "fee_payer_secret" => secret,
               "store" => false
             })

    assert :ok =
             Stellar.validate_config!(%{"rpc_url" => @rpc_url, "network" => "stellar:testnet", "store" => MemoryStore})

    assert_raise ArgumentError, fn ->
      Stellar.validate_config!(%{"rpc_url" => @rpc_url, "network" => "stellar:testnet", "store" => {Integer, []}})
    end
  end

  test "challenge_method_details advertises feePayer when configured", context do
    charge = %{context.charge | method_details: Map.put(context.charge.method_details, "fee_payer", true)}
    details = Stellar.challenge_method_details(charge)
    assert details["feePayer"] == true
  end

  test "zero amount, bad recipient and non-contract currency fail locally", context do
    assert {:error, _} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{context.charge | amount: "0"})

    assert {:error, _} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{
               context.charge
               | recipient: "not-an-account"
             })

    assert {:error, _} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{
               context.charge
               | currency: "USD"
             })

    assert {:error, _} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{
               context.charge
               | recipient: nil
             })
  end

  test "malformed credentials fail before RPC", context do
    for payload <- [
          %{},
          %{"type" => "signature"},
          %{"type" => "hash"},
          %{"type" => "hash", "hash" => "zz"},
          %{"type" => "hash", "hash" => String.duplicate("z", 64)},
          %{"type" => "transaction"},
          %{"type" => "transaction", "transaction" => "not-base64"}
        ] do
      assert {:error, %Errors{}} = Stellar.verify(payload, context.charge)
    end
  end

  test "push mode is rejected when feePayer is true", context do
    charge = %{context.charge | method_details: Map.put(context.charge.method_details, "feePayer", true)}
    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, charge)
    assert error.type == Errors.new(:verification_failed, "").type
  end

  test "unsigned envelopes decode the SEP-41 transfer arguments", context do
    {:ok, inspected} = Envelope.decode(context.unsigned)
    assert inspected.transfer.contract == @native_sac
    assert inspected.transfer.from == context.payer.public
    assert inspected.transfer.to == context.recipient.public
    assert inspected.transfer.amount == 1_000_000
    assert inspected.source == context.payer.public
    assert is_integer(inspected.time_bounds_max)
  end

  test "sponsored pull rejects a non-zero source without calling sendTransaction", context do
    secret = context.payer.secret

    charge = %{
      context.charge
      | method_details:
          context.charge.method_details
          |> Map.put("feePayer", true)
          |> Map.put("fee_payer_secret", secret)
    }

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => context.unsigned}, charge)
    assert error.type == Errors.new(:verification_failed, "").type
  end

  test "push mode verifies a successful getTransaction and consumes the hash", context do
    stub_rpc(context, fn
      "getTransaction" ->
        %{
          "status" => "SUCCESS",
          "envelopeXdr" => context.signed,
          "txHash" => context.hash
        }
    end)

    payload = %{"type" => "hash", "hash" => context.hash}
    assert {:ok, %Receipt{} = receipt} = Stellar.verify(payload, context.charge)
    assert receipt.method == "stellar"
    assert receipt.reference == context.hash

    assert {:error, error} = Stellar.verify(payload, context.charge)
    assert error.type == Errors.new(:invalid_challenge, "").type
  end

  test "push mode rejects a SUCCESS transfer to the wrong recipient", context do
    stub_rpc(context, fn
      "getTransaction" ->
        %{"status" => "SUCCESS", "envelopeXdr" => context.signed, "txHash" => context.hash}
    end)

    wrong = %{context.charge | recipient: Fixtures.keypair().public}
    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, wrong)
    assert error.type == Errors.new(:verification_failed, "").type
  end

  test "push mode treats FAILED on-chain status as verification-failed", context do
    stub_rpc(context, fn
      "getTransaction" -> %{"status" => "FAILED", "envelopeXdr" => context.signed}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, context.charge)
    assert error.type == Errors.new(:verification_failed, "").type
  end

  test "pull unsponsored simulates, submits and returns settlement-failed on FAILED", context do
    stub_rpc(context, fn
      "simulateTransaction" ->
        %{
          "events" => [],
          "results" => [%{"auth" => []}],
          "minResourceFee" => "100",
          "transactionData" => Base.encode64(<<0, 0, 0, 0>>)
        }

      "sendTransaction" ->
        %{"status" => "PENDING", "hash" => context.hash}

      "getTransaction" ->
        %{"status" => "FAILED", "envelopeXdr" => context.signed}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)
    assert error.type in [Errors.new(:verification_failed, "").type, Errors.new(:settlement_failed, "").type]
  end

  test "pull unsponsored succeeds when simulation events match the SEP-41 transfer", context do
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)

    stub_rpc(context, fn
      "simulateTransaction" ->
        %{
          "events" => [event],
          "results" => [%{"auth" => []}],
          "minResourceFee" => "100",
          "latestLedger" => 1
        }

      "sendTransaction" ->
        %{"status" => "PENDING", "hash" => context.hash}

      "getTransaction" ->
        %{"status" => "SUCCESS", "envelopeXdr" => context.signed, "txHash" => context.hash}
    end)

    assert {:ok, %Receipt{} = receipt} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)

    assert receipt.reference == context.hash
  end

  test "sendTransaction ERROR after a valid simulation is settlement-failed", context do
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)

    stub_rpc(context, fn
      "simulateTransaction" -> %{"events" => [event], "results" => [%{"auth" => []}]}
      "sendTransaction" -> %{"status" => "ERROR", "hash" => context.hash}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)
    assert error.type == Errors.new(:settlement_failed, "").type
  end

  test "Envelope rebuilds, signs and checks SEP-41 simulation events", context do
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)
    assert [%{name: "transfer", from: from, to: to, amount: 1_000_000}] = Envelope.contract_events([event])
    assert from == context.payer.public
    assert to == context.recipient.public
    assert Envelope.expected_transfer?(Envelope.contract_events([event]), context.inspected.transfer)

    {:ok, rebuilt} = Envelope.rebuild(context.inspected, context.payer.public, 7, nil, 200)
    assert rebuilt.seq_num.sequence_number == 7
    {:ok, signed} = Envelope.sign(rebuilt, context.payer.secret, @passphrase)
    {:ok, inspected} = Envelope.decode(signed)
    assert inspected.source == context.payer.public
    assert Envelope.hash(inspected.tx, @passphrase) != ""
  end

  test "RPC getLatestLedger, send DUPLICATE, Horizon sequence and NOT_FOUND budget", context do
    stub_rpc(context, fn
      "getLatestLedger" -> %{"sequence" => 99}
      "sendTransaction" -> %{"status" => "DUPLICATE", "hash" => context.hash}
      "getLedgerEntries" -> %{}
      "getTransaction" -> %{"status" => "NOT_FOUND"}
      "horizon" -> %{"sequence" => "12"}
    end)

    config = Map.merge(context.charge.method_details, %{"poll_interval_ms" => 1, "poll_timeout_ms" => 50})
    assert {:ok, 99} = RPC.get_latest_ledger(config)
    assert {:ok, %{"status" => "DUPLICATE"}} = RPC.send_transaction(context.signed, config)
    assert {:ok, 12} = RPC.account_sequence(context.payer.public, config)
    assert {:error, error} = RPC.await_existing(context.hash, config)
    assert error.type == Errors.new(:verification_failed, "").type
  end

  test "sponsored pull rejects missing address credentials", context do
    {:ok, xdr} =
      Envelope.unsigned(
        Envelope.zero_account(),
        @native_sac,
        context.payer.public,
        context.recipient.public,
        1_000_000,
        System.os_time(:second) + 300
      )

    charge = %{
      context.charge
      | method_details:
          context.charge.method_details
          |> Map.put("feePayer", true)
          |> Map.put("fee_payer_secret", context.payer.secret)
    }

    stub_rpc(context, fn
      "getLatestLedger" -> %{"sequence" => 10}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => xdr}, charge)
    assert error.detail =~ "sorobanCredentialsAddress"
  end

  test "Envelope.unsigned zeros source and unexpected events fail the transfer check", context do
    {:ok, xdr} =
      Envelope.unsigned(
        Envelope.zero_account(),
        @native_sac,
        context.payer.public,
        context.recipient.public,
        1_000_000,
        nil
      )

    {:ok, inspected} = Envelope.decode(xdr)
    assert inspected.source == Envelope.zero_account()
    refute Envelope.expected_transfer?([], inspected.transfer)

    refute Envelope.expected_transfer?(
             [%{name: "burn", from: context.payer.public, to: nil, amount: 1, contract: nil}],
             inspected.transfer
           )

    assert match?({:error, %Errors{}}, Envelope.decode("!!!!"))
    assert Envelope.contract_events(nil) == []
    assert Envelope.contract_events(["not-xdr"]) == []

    assert match?(
             {:error, %Errors{}},
             Envelope.unsigned("bad", @native_sac, context.payer.public, context.recipient.public, 1, nil)
           )

    assert match?({:error, %Errors{}}, Envelope.sign(context.inspected.tx, "SNOTAKEY", @passphrase))
    assert match?({:error, %Errors{}}, Envelope.set_ext(context.inspected, "AAAA", 1))
    assert match?({:error, %Errors{}}, Envelope.rebuild(context.inspected, context.payer.public, 1, "!!!!", 1))
    {:ok, attached} = Envelope.attach_auth(context.inspected, [])
    assert is_binary(attached)
  end

  test "RPC send TRY_AGAIN_LATER, getTransaction and await SUCCESS", context do
    stub_rpc(context, fn
      "sendTransaction" -> %{"status" => "TRY_AGAIN_LATER"}
      "getTransaction" -> %{"status" => "SUCCESS", "envelopeXdr" => context.signed}
      "simulateTransaction" -> %{"error" => "footprint"}
    end)

    assert {:error, error} = RPC.send_transaction(context.signed, context.charge.method_details)
    assert error.status == 503
    assert {:ok, %{"status" => "SUCCESS"}} = RPC.get_transaction(context.hash, context.charge.method_details)
    assert {:ok, %{"status" => "SUCCESS"}} = RPC.await_transaction(context.hash, context.charge.method_details)
    assert {:error, sim} = RPC.simulate(context.signed, context.charge.method_details)
    assert sim.type == Errors.new(:verification_failed, "").type
    assert RPC.passphrase("stellar:pubnet") =~ "Public Global"
  end

  test "store false allows the same hash twice and ConCacheStore tuples validate", context do
    assert :ok =
             Stellar.validate_config!(%{
               "rpc_url" => @rpc_url,
               "network" => "stellar:testnet",
               "store" => {MPP.Tempo.ConCacheStore, [name: :stellar_unit]}
             })

    charge = %{context.charge | method_details: Map.put(context.charge.method_details, "store", false)}

    stub_rpc(context, fn
      "getTransaction" -> %{"status" => "SUCCESS", "envelopeXdr" => context.signed, "txHash" => context.hash}
    end)

    payload = %{"type" => "hash", "hash" => context.hash}
    assert {:ok, _} = Stellar.verify(payload, charge)
    assert {:ok, _} = Stellar.verify(payload, charge)
  end

  test "JSON-RPC error objects are settlement-unavailable", context do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32_000, "message" => "unavailable"}})
    end)

    assert {:error, error} = RPC.get_latest_ledger(context.charge.method_details)
    assert error.status == 503
  end

  test "RPC unavailability during simulation is a server error", context do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)
    assert error.status == 503
  end

  defp stub_rpc(_context, fun) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, fun.("horizon"))

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"method" => method} = Jason.decode!(body)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => fun.(method)})
      end
    end)
  end
end
