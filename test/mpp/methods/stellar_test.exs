defmodule MPP.Methods.StellarTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Stellar
  alias MPP.Methods.Stellar.Envelope
  alias MPP.Methods.Stellar.RPC
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.Test.Stellar, as: Fixtures

  @rpc_url "https://soroban-testnet.stellar.org"
  @passphrase "Test SDF Network ; September 2015"
  @native_sac Fixtures.native_sac()

  defmodule MemoryStore do
    @moduledoc false
    @behaviour Store

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

  defmodule GetFailStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: {:error, :connection_lost}
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: :ok
  end

  defmodule AlreadyExistsStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: {:error, :already_exists}
  end

  defmodule AtomicFailStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: {:error, :unexpected_store_error}
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
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)

    stub_rpc(context, fn
      "simulateTransaction" ->
        %{
          "events" => [event],
          "results" => [%{"auth" => []}],
          "minResourceFee" => "100"
        }

      "sendTransaction" ->
        %{"status" => "PENDING", "hash" => context.hash}

      "getTransaction" ->
        %{"status" => "FAILED", "envelopeXdr" => context.signed}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)
    assert error.type == Errors.new(:settlement_failed, "").type
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
               "store" => {ConCacheStore, [name: :stellar_unit]}
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

  test "unsigned unsponsored pull is verification-failed before RPC", context do
    assert {:error, error} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.unsigned}, context.charge)

    assert error.type == Errors.new(:verification_failed, "").type
    assert error.detail =~ "signed"
  end

  test "unsponsored pull signed for a different network is verification-failed", context do
    charge = %{context.charge | method_details: Map.put(context.charge.method_details, "network", "stellar:pubnet")}

    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, charge)
    assert error.type == Errors.new(:verification_failed, "").type
    assert error.detail =~ "network"
  end

  test "replay store requires a challenge_id", context do
    charge = %{context.charge | method_details: Map.delete(context.charge.method_details, "challenge_id")}

    stub_rpc(context, fn
      "getTransaction" -> %{"status" => "SUCCESS", "envelopeXdr" => context.signed, "txHash" => context.hash}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, charge)
    assert error.detail =~ "challenge_id"
  end

  test "getLedgerEntries LedgerEntryData yields the account sequence without Horizon", context do
    xdr = Fixtures.account_entry_data_xdr(context.payer.public, 42)

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => xdr}]}
      "horizon" -> %{"sequence" => "99"}
    end)

    assert {:ok, 42} = RPC.account_sequence(context.payer.public, context.charge.method_details)
  end

  test "sign_auth writes address credentials and attach_auth round-trips them", context do
    {:ok, draft} =
      Envelope.unsigned(
        Envelope.zero_account(),
        @native_sac,
        context.payer.public,
        context.recipient.public,
        1_000_000,
        nil
      )

    auth = Fixtures.address_auth_xdr(draft, context.payer.public, 15)
    {:ok, signed} = Envelope.sign_auth(auth, context.payer.secret, @passphrase, 25)
    {:ok, inspected} = Envelope.decode(draft)
    {:ok, with_auth} = Envelope.attach_auth(inspected, [signed])
    {:ok, decoded} = Envelope.decode(with_auth)
    [entry] = decoded.auth
    assert entry.type == :address
    assert entry.address == context.payer.public
    assert entry.expiration == 25
    assert entry.sub_invocations == 0
    {:ok, signed_inspected} = Envelope.decode(context.signed)
    assert Envelope.signed_by_source?(signed_inspected, @passphrase)
    refute Envelope.signed_by_source?(inspected, @passphrase)
  end

  test "sponsored pull rebuilds, submits, and rejects a fee-payer drain", context do
    fee_payer = Fixtures.keypair()
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)

    {:ok, draft} =
      Envelope.unsigned(
        Envelope.zero_account(),
        @native_sac,
        context.payer.public,
        context.recipient.public,
        1_000_000,
        nil
      )

    auth = Fixtures.address_auth_xdr(draft, context.payer.public, 20)
    {:ok, inspected} = Envelope.decode(draft)
    {:ok, sponsored} = Envelope.attach_auth(inspected, [auth])

    charge = %{
      context.charge
      | method_details:
          context.charge.method_details
          |> Map.put("feePayer", true)
          |> Map.put("fee_payer_secret", fee_payer.secret)
    }

    stub_rpc(context, fn
      "getLatestLedger" -> %{"sequence" => 10}
      "simulateTransaction" -> %{"events" => [event], "results" => [%{"auth" => [auth]}]}
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => Fixtures.account_entry_data_xdr(fee_payer.public, 12)}]}
      "sendTransaction" -> %{"status" => "PENDING", "hash" => context.hash}
      "getTransaction" -> %{"status" => "SUCCESS", "envelopeXdr" => sponsored, "txHash" => context.hash}
    end)

    assert {:ok, %Receipt{} = receipt} = Stellar.verify(%{"type" => "transaction", "transaction" => sponsored}, charge)
    assert receipt.reference == context.hash

    {:ok, drain_draft} =
      Envelope.unsigned(
        Envelope.zero_account(),
        @native_sac,
        fee_payer.public,
        context.recipient.public,
        1_000_000,
        nil
      )

    drain_auth = Fixtures.address_auth_xdr(drain_draft, fee_payer.public, 20)
    {:ok, drain_inspected} = Envelope.decode(drain_draft)
    {:ok, drain} = Envelope.attach_auth(drain_inspected, [drain_auth])
    drain_charge = %{charge | method_details: Map.put(charge.method_details, "challenge_id", "stellar-drain")}

    assert {:error, drain_error} = Stellar.verify(%{"type" => "transaction", "transaction" => drain}, drain_charge)
    assert drain_error.type == Errors.new(:verification_failed, "").type
    assert drain_error.detail =~ "fee payer"
  end

  test "observed testnet getTransaction envelope, events and ledger entries" do
    observed = Fixtures.observed_transfer()
    envelope = observed["getTransaction"]["envelopeXdr"]
    {:ok, inspected} = Envelope.decode(envelope)

    assert inspected.source == observed["payer"]
    assert inspected.transfer.contract == observed["native_sac"]
    assert inspected.transfer.from == observed["payer"]
    assert inspected.transfer.to == observed["recipient"]
    assert inspected.transfer.amount == observed["amount"]
    assert [%{type: :source_account, sub_invocations: 0}] = inspected.auth
    assert Envelope.encode(inspected) == envelope

    diagnostic = Envelope.contract_events([observed["getTransaction"]["diagnosticTransferXdr"]])
    sim_events = Envelope.contract_events(observed["simulateTransaction"]["events"])
    assert Envelope.expected_transfer?(diagnostic, inspected.transfer)
    assert Envelope.expected_transfer?(sim_events, inspected.transfer)

    contract_event = Fixtures.contract_event_xdr(observed["payer"], observed["recipient"], observed["amount"])
    assert Envelope.expected_transfer?(Envelope.contract_events([contract_event]), inspected.transfer)

    map_event = Fixtures.map_amount_event_xdr(observed["payer"], observed["recipient"], observed["amount"])
    assert Envelope.expected_transfer?(Envelope.contract_events([map_event]), inspected.transfer)

    bumped = Fixtures.fee_bump_xdr(envelope, observed["payer"])
    {:ok, bump_inspected} = Envelope.decode(bumped)
    assert bump_inspected.transfer == inspected.transfer
    assert Envelope.signed_by_source?(bump_inspected, @passphrase)

    assert :ok =
             Stellar.validate_config!(%{
               "rpc_url" => @rpc_url,
               "network" => "stellar:testnet"
             })

    assert RPC.passphrases()["stellar:testnet"] == @passphrase
  end

  test "push mode uses the observed SUCCESS envelope and rejects missing envelopeXdr", context do
    observed = Fixtures.observed_transfer()
    envelope = observed["getTransaction"]["envelopeXdr"]
    hash = observed["getTransaction"]["txHash"]
    {:ok, inspected} = Envelope.decode(envelope)

    {:ok, charge} =
      Charge.new(
        amount: Integer.to_string(observed["amount"]),
        currency: observed["native_sac"],
        recipient: observed["recipient"],
        method_details:
          Map.merge(context.charge.method_details, %{
            "challenge_id" => "stellar-observed-push",
            "store" => false
          })
      )

    stub_rpc(context, fn
      "getTransaction" ->
        %{
          "status" => "SUCCESS",
          "envelopeXdr" => envelope,
          "txHash" => hash
        }
    end)

    assert {:ok, %Receipt{reference: ^hash}} = Stellar.verify(%{"type" => "hash", "hash" => hash}, charge)

    stub_rpc(context, fn
      "getTransaction" -> %{"status" => "SUCCESS", "txHash" => hash}
    end)

    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => hash}, charge)
    assert error.detail =~ "envelopeXdr"

    stub_rpc(context, fn
      "getTransaction" -> %{"status" => "NOT_A_STATUS", "envelopeXdr" => envelope}
    end)

    assert {:error, status_error} = Stellar.verify(%{"type" => "hash", "hash" => hash}, charge)
    assert status_error.type == Errors.new(:verification_failed, "").type

    assert inspected.transfer.amount == observed["amount"]
  end

  test "pull unsponsored covers RPC settlement, expiry and config error branches", context do
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)

    stub_rpc(context, fn
      "simulateTransaction" -> %{"events" => [event], "results" => [%{"auth" => []}]}
      "sendTransaction" -> %{"status" => "PENDING"}
    end)

    assert {:error, missing_hash} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)

    assert missing_hash.detail =~ "did not return a hash"

    stub_rpc(context, fn
      "simulateTransaction" -> %{"events" => [], "results" => [%{"auth" => []}]}
    end)

    assert {:error, sim} = Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, context.charge)
    assert sim.detail =~ "Simulation events"

    assert {:error, amount} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{
               context.charge
               | amount: "1.5"
             })

    assert amount.detail =~ "not a valid integer"

    assert {:error, currency} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{
               context.charge
               | currency: nil
             })

    assert currency.detail =~ "SEP-41"

    assert {:error, expiry} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, %{
               context.charge
               | method_details: Map.put(context.charge.method_details, "challenge_expires", "not-a-date")
             })

    assert expiry.detail =~ "expiry is invalid"

    no_expires = %{context.charge | method_details: Map.delete(context.charge.method_details, "challenge_expires")}
    assert {:error, signed} = Stellar.verify(%{"type" => "transaction", "transaction" => context.unsigned}, no_expires)
    assert signed.detail =~ "signed"

    unknown_network = %{
      context.charge
      | method_details: Map.put(context.charge.method_details, "network", "stellar:devnet")
    }

    assert {:error, network} =
             Stellar.verify(%{"type" => "transaction", "transaction" => context.signed}, unknown_network)

    assert network.detail =~ "stellar:pubnet"

    charge = %{context.charge | method_details: Map.put(context.charge.method_details, "store", GetFailStore)}
    stub_rpc(context, fn "getTransaction" -> %{"status" => "SUCCESS", "envelopeXdr" => context.signed} end)
    assert {:error, read} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, charge)
    assert read.detail == "Dedup store error"

    exists = %{context.charge | method_details: Map.put(context.charge.method_details, "store", AlreadyExistsStore)}
    assert {:error, replay} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, exists)
    assert replay.detail =~ "already been used"

    atomic = %{context.charge | method_details: Map.put(context.charge.method_details, "store", AtomicFailStore)}
    assert {:error, commit} = Stellar.verify(%{"type" => "hash", "hash" => context.hash}, atomic)
    assert commit.detail == "Dedup store error"
  end

  test "sponsored pull covers secret, auth-tree, resource fee and missing send hash", context do
    fee_payer = Fixtures.keypair()
    event = Fixtures.transfer_event_xdr(context.payer.public, context.recipient.public, 1_000_000)
    observed = Fixtures.observed_transfer()

    {:ok, draft} =
      Envelope.unsigned(
        Envelope.zero_account(),
        @native_sac,
        context.payer.public,
        context.recipient.public,
        1_000_000,
        nil
      )

    auth = Fixtures.address_auth_xdr(draft, context.payer.public, 20)
    nested = Fixtures.address_auth_xdr(draft, context.payer.public, 20, nested: true)
    expired = Fixtures.address_auth_xdr(draft, context.payer.public, 99_999)
    {:ok, inspected} = Envelope.decode(draft)
    {:ok, sponsored} = Envelope.attach_auth(inspected, [auth])
    {:ok, nested_xdr} = Envelope.attach_auth(inspected, [nested])
    {:ok, expired_xdr} = Envelope.attach_auth(inspected, [expired])

    base_details =
      context.charge.method_details
      |> Map.put("feePayer", true)
      |> Map.put("fee_payer_secret", fee_payer.secret)

    charge = %{context.charge | method_details: base_details}

    stub_rpc(context, fn
      "getLatestLedger" -> %{"sequence" => 10}
    end)

    assert {:error, missing_secret} =
             Stellar.verify(%{"type" => "transaction", "transaction" => sponsored}, %{
               charge
               | method_details: Map.delete(base_details, "fee_payer_secret")
             })

    assert missing_secret.detail =~ "fee_payer_secret"

    assert {:error, bad_secret} =
             Stellar.verify(%{"type" => "transaction", "transaction" => sponsored}, %{
               charge
               | method_details: Map.put(base_details, "fee_payer_secret", "SNOTAKEY")
             })

    assert bad_secret.detail =~ "fee-payer secret"

    assert {:error, nested_error} = Stellar.verify(%{"type" => "transaction", "transaction" => nested_xdr}, charge)
    assert nested_error.detail =~ "subInvocations"

    assert {:error, expiry} = Stellar.verify(%{"type" => "transaction", "transaction" => expired_xdr}, charge)
    assert expiry.detail =~ "authorization expiration"

    stub_rpc(context, fn
      "getLatestLedger" ->
        %{"sequence" => 10}

      "simulateTransaction" ->
        %{
          "events" => [event],
          "results" => [%{"auth" => [auth]}],
          "minResourceFee" => observed["simulateTransaction"]["minResourceFee"],
          "transactionData" => observed["simulateTransaction"]["transactionData"]
        }

      "getLedgerEntries" ->
        %{"entries" => [%{"xdr" => Fixtures.account_entry_data_xdr(fee_payer.public, 12)}]}

      "sendTransaction" ->
        %{"status" => "ERROR"}
    end)

    assert {:error, send_error} = Stellar.verify(%{"type" => "transaction", "transaction" => sponsored}, charge)
    assert send_error.type == Errors.new(:settlement_failed, "").type

    stub_rpc(context, fn
      "getLatestLedger" ->
        %{"sequence" => 10}

      "simulateTransaction" ->
        %{
          "events" => [event],
          "results" => [%{"auth" => [auth]}],
          "minResourceFee" => 100,
          "transactionData" => observed["simulateTransaction"]["transactionData"]
        }

      "getLedgerEntries" ->
        %{"entries" => [%{"xdr" => Fixtures.account_entry_data_xdr(fee_payer.public, 12)}]}

      "sendTransaction" ->
        %{"status" => "PENDING"}
    end)

    assert {:error, no_hash} = Stellar.verify(%{"type" => "transaction", "transaction" => sponsored}, charge)
    assert no_hash.detail =~ "sponsored settlement"

    stub_rpc(context, fn
      "getLatestLedger" ->
        %{"sequence" => 10}

      "simulateTransaction" ->
        %{
          "events" => [event],
          "results" => [%{"auth" => [auth]}],
          "minResourceFee" => "nope",
          "transactionData" => observed["simulateTransaction"]["transactionData"]
        }

      "getLedgerEntries" ->
        %{"entries" => [%{"xdr" => Fixtures.account_entry_data_xdr(fee_payer.public, 12)}]}

      "sendTransaction" ->
        %{"status" => "PENDING", "hash" => context.hash}

      "getTransaction" ->
        %{"status" => "NOT_A_STATUS", "envelopeXdr" => sponsored}
    end)

    assert {:error, settled} = Stellar.verify(%{"type" => "transaction", "transaction" => sponsored}, charge)
    assert settled.type == Errors.new(:settlement_failed, "").type
  end

  test "Envelope decode rejects malformed, wrong-op and non-transfer host functions", context do
    alias StellarBase.XDR
    alias StellarBase.XDR.Operations.InvokeHostFunction

    observed = Fixtures.observed_transfer()
    {:ok, inspected} = Envelope.decode(observed["getTransaction"]["envelopeXdr"])

    assert match?({:error, %Errors{}}, Envelope.decode(123))
    assert match?({:error, %Errors{}}, Envelope.decode(Base.encode64(<<1, 2, 3, 4>>)))
    leftover = Base.encode64(Base.decode64!(observed["getTransaction"]["envelopeXdr"]) <> <<0, 0, 0, 1>>)
    assert match?({:error, %Errors{}}, Envelope.decode(leftover))

    empty = Fixtures.reencode(%{inspected | tx: %{inspected.tx | operations: XDR.Operations.new([])}})
    assert {:error, empty_error} = Envelope.decode(empty)
    assert empty_error.detail =~ "exactly one operation"

    restore =
      XDR.Void.new()
      |> XDR.ExtensionPoint.new(0)
      |> XDR.Operations.RestoreFootprint.new()
      |> XDR.OperationBody.new(XDR.OperationType.new(:RESTORE_FOOTPRINT))

    [op] = inspected.tx.operations.operations
    restore_op = %{op | body: restore}
    restore_xdr = Fixtures.reencode(%{inspected | tx: %{inspected.tx | operations: XDR.Operations.new([restore_op])}})
    assert {:error, restore_error} = Envelope.decode(restore_xdr)
    assert restore_error.detail =~ "must invoke a contract"

    host =
      XDR.HostFunction.new(
        XDR.VariableOpaque.new(<<1, 2, 3, 4>>),
        XDR.HostFunctionType.new(:HOST_FUNCTION_TYPE_UPLOAD_CONTRACT_WASM)
      )

    invoke = InvokeHostFunction.new(host, XDR.SorobanAuthorizationEntryList.new([]))
    upload_body = XDR.OperationBody.new(invoke, XDR.OperationType.new(:INVOKE_HOST_FUNCTION))
    upload_op = %{op | body: upload_body}
    upload_xdr = Fixtures.reencode(%{inspected | tx: %{inspected.tx | operations: XDR.Operations.new([upload_op])}})
    assert {:error, upload_error} = Envelope.decode(upload_xdr)
    assert upload_error.detail =~ "SEP-41 transfer"

    {:ok, raw} = StellarBase.StrKey.decode(inspected.source, :ed25519_public_key)
    muxed = XDR.MuxedAccountMed25519.new(XDR.UInt64.new(7), XDR.UInt256.new(raw))
    muxed_account = XDR.MuxedAccount.new(muxed, XDR.CryptoKeyType.new(:KEY_TYPE_MUXED_ED25519))
    muxed_xdr = Fixtures.reencode(%{inspected | tx: %{inspected.tx | source_account: muxed_account}})
    {:ok, muxed_inspected} = Envelope.decode(muxed_xdr)
    assert muxed_inspected.source == inspected.source

    bounds = XDR.TimeBounds.new(XDR.TimePoint.new(0), XDR.TimePoint.new(1_700_000_000))

    v2 =
      XDR.PreconditionsV2.new(
        XDR.OptionalTimeBounds.new(bounds),
        XDR.OptionalLedgerBounds.new(),
        XDR.OptionalSequenceNumber.new(),
        XDR.Duration.new(0),
        XDR.UInt32.new(0),
        XDR.SignerKeyList.new([])
      )

    v2_xdr =
      Fixtures.reencode(%{
        inspected
        | tx: %{inspected.tx | preconditions: XDR.Preconditions.new(v2, XDR.PreconditionType.new(:PRECOND_V2))}
      })

    {:ok, v2_inspected} = Envelope.decode(v2_xdr)
    assert v2_inspected.time_bounds_max == 1_700_000_000

    v2_none =
      XDR.PreconditionsV2.new(
        XDR.OptionalTimeBounds.new(),
        XDR.OptionalLedgerBounds.new(),
        XDR.OptionalSequenceNumber.new(),
        XDR.Duration.new(0),
        XDR.UInt32.new(0),
        XDR.SignerKeyList.new([])
      )

    none_xdr =
      Fixtures.reencode(%{
        inspected
        | tx: %{inspected.tx | preconditions: XDR.Preconditions.new(v2_none, XDR.PreconditionType.new(:PRECOND_V2))}
      })

    {:ok, none_inspected} = Envelope.decode(none_xdr)
    assert none_inspected.time_bounds_max == nil

    {:ok, rebuilt} =
      Envelope.rebuild(inspected, inspected.source, 9, observed["simulateTransaction"]["transactionData"], 200)

    assert rebuilt.seq_num.sequence_number == 9
    {:ok, with_ext} = Envelope.set_ext(inspected, observed["simulateTransaction"]["transactionData"], 200)
    {:ok, ext_inspected} = Envelope.decode(with_ext)
    assert ext_inspected.tx.fee.datum == 200

    assert match?({:error, %Errors{}}, Envelope.sign_auth("!!!!", context.payer.secret, @passphrase, 1))

    assert match?(
             {:error, %Errors{}},
             Envelope.sign_auth(observed["simulateTransaction"]["auth"], context.payer.secret, @passphrase, 1)
           )

    assert match?({:error, %Errors{}}, Envelope.attach_auth(inspected, ["!!!!"]))

    assert match?(
             {:error, %Errors{}},
             Envelope.unsigned(
               context.payer.public,
               "not-a-contract",
               context.payer.public,
               context.recipient.public,
               1,
               nil
             )
           )

    assert match?(
             {:error, %Errors{}},
             Envelope.unsigned(context.payer.public, @native_sac, "not-an-account", context.recipient.public, 1, nil)
           )

    assert match?({:error, %Errors{}}, Envelope.rebuild(inspected, "not-an-account", 1, nil, 1))

    refute Envelope.signed_by_source?(:not_inspected, @passphrase)
    refute Envelope.signed_by_source?(%{tx: inspected.tx, envelope: :nope, source: inspected.source}, @passphrase)

    refute Envelope.signed_by_source?(
             %{tx: inspected.tx, envelope: inspected.envelope, source: "not-an-account"},
             @passphrase
           )

    garbage_envelope = %{
      inspected.envelope
      | envelope: %{inspected.envelope.envelope | signatures: XDR.DecoratedSignatures.new([:not_a_signature])}
    }

    refute Envelope.signed_by_source?(%{inspected | envelope: garbage_envelope}, @passphrase)
    assert Envelope.contract_events([123, nil]) == []

    topics = XDR.SCValList.new([XDR.SCVal.new(XDR.SCSymbol.new("transfer"), XDR.SCValType.new(:SCV_SYMBOL))])
    data = XDR.SCVal.new(XDR.Void.new(), XDR.SCValType.new(:SCV_VOID))
    body = XDR.ContractEventBody.new(XDR.ContractEventV0.new(topics, data), 0)

    system_xdr =
      XDR.Void.new()
      |> XDR.ExtensionPoint.new(0)
      |> XDR.ContractEvent.new(XDR.OptionalHash.new(), XDR.ContractEventType.new(:SYSTEM), body)
      |> XDR.ContractEvent.encode_xdr!()
      |> Base.encode64()

    assert Envelope.contract_events([system_xdr]) == []

    {:ok, raw} = StellarBase.StrKey.decode(inspected.source, :ed25519_public_key)

    v0 =
      raw
      |> XDR.UInt256.new()
      |> XDR.TransactionV0.new(
        XDR.UInt32.new(100),
        XDR.SequenceNumber.new(0),
        XDR.OptionalTimeBounds.new(),
        XDR.Memo.new(XDR.Void.new(), XDR.MemoType.new(:MEMO_NONE)),
        XDR.Operations.new([]),
        XDR.Ext.new()
      )
      |> XDR.TransactionV0Envelope.new(XDR.DecoratedSignatures.new([]))
      |> XDR.TransactionEnvelope.new(XDR.EnvelopeType.new(:ENVELOPE_TYPE_TX_V0))
      |> Envelope.encode()

    assert {:error, v0_error} = Envelope.decode(v0)
    assert v0_error.detail =~ "Malformed"

    [op] = inspected.tx.operations.operations
    invoke = op.body.value
    args = invoke.host_function.value
    [from_val, to_val, amount_val] = args.args.items
    muxed = XDR.MuxedEd25519Account.new(XDR.UInt64.new(1), XDR.UInt256.new(raw))

    from_muxed =
      muxed
      |> XDR.SCAddress.new(XDR.SCAddressType.new(:SC_ADDRESS_TYPE_MUXED_ACCOUNT))
      |> XDR.SCVal.new(XDR.SCValType.new(:SCV_ADDRESS))

    muxed_args = %{args | args: XDR.SCValList.new([from_muxed, to_val, amount_val])}
    muxed_host = %{invoke.host_function | value: muxed_args}
    muxed_invoke = %{invoke | host_function: muxed_host}
    muxed_op = %{op | body: %{op.body | value: muxed_invoke}}
    muxed_from_xdr = Fixtures.reencode(%{inspected | tx: %{inspected.tx | operations: XDR.Operations.new([muxed_op])}})
    {:ok, muxed_from} = Envelope.decode(muxed_from_xdr)
    assert muxed_from.transfer.from == inspected.source

    void_amount = XDR.SCVal.new(XDR.Void.new(), XDR.SCValType.new(:SCV_VOID))
    void_args = %{args | args: XDR.SCValList.new([from_val, to_val, void_amount])}
    void_host = %{invoke.host_function | value: void_args}
    void_invoke = %{invoke | host_function: void_host}
    void_op = %{op | body: %{op.body | value: void_invoke}}
    void_xdr = Fixtures.reencode(%{inspected | tx: %{inspected.tx | operations: XDR.Operations.new([void_op])}})
    assert {:error, void_error} = Envelope.decode(void_xdr)
    assert void_error.detail =~ "SEP-41 transfer"

    topics_addr = XDR.SCValList.new([from_val])
    body_addr = XDR.ContractEventBody.new(XDR.ContractEventV0.new(topics_addr, amount_val), 0)

    no_symbol =
      XDR.Void.new()
      |> XDR.ExtensionPoint.new(0)
      |> XDR.ContractEvent.new(XDR.OptionalHash.new(), XDR.ContractEventType.new(:CONTRACT), body_addr)
      |> XDR.ContractEvent.encode_xdr!()
      |> Base.encode64()

    assert [%{name: nil, amount: amount}] = Envelope.contract_events([no_symbol])
    assert is_integer(amount) or is_nil(amount)

    empty_event = Base.encode64(<<0, 0, 0, 0>>)
    assert Envelope.contract_events([empty_event]) == []

    assert Envelope.expected_transfer?(
             Envelope.contract_events([observed["getTransaction"]["contractEventsXdr"]]),
             inspected.transfer
           )

    padded = Base.encode64(Base.decode64!(observed["simulateTransaction"]["transactionData"]) <> <<0>>)
    assert match?({:error, %Errors{}}, Envelope.set_ext(inspected, padded, 1))

    assert match?(
             {:error, %Errors{}},
             Envelope.rebuild(inspected, inspected.source, 9, padded, 200)
           )

    padded_auth = Base.encode64(Base.decode64!(observed["simulateTransaction"]["auth"]) <> <<0>>)
    assert match?({:error, %Errors{}}, Envelope.sign_auth(padded_auth, context.payer.secret, @passphrase, 1))
    assert match?({:error, %Errors{}}, Envelope.attach_auth(inspected, [padded_auth]))

    leftover_diag =
      Base.encode64(Base.decode64!(observed["getTransaction"]["diagnosticTransferXdr"]) <> <<0, 0, 0, 1>>)

    leftover_contract = Base.encode64(Base.decode64!(observed["getTransaction"]["contractEventsXdr"]) <> <<0, 0, 0, 1>>)
    assert Envelope.contract_events([leftover_diag, leftover_contract]) == []

    claim =
      32
      |> :crypto.strong_rand_bytes()
      |> XDR.Hash.new()
      |> XDR.ClaimableBalanceID.new(XDR.ClaimableBalanceIDType.new(:CLAIMABLE_BALANCE_ID_TYPE_V0))
      |> XDR.SCAddress.new(XDR.SCAddressType.new(:SC_ADDRESS_TYPE_CLAIMABLE_BALANCE))
      |> XDR.SCVal.new(XDR.SCValType.new(:SCV_ADDRESS))

    claim_args = %{args | args: XDR.SCValList.new([claim, to_val, amount_val])}
    claim_host = %{invoke.host_function | value: claim_args}
    claim_invoke = %{invoke | host_function: claim_host}
    claim_op = %{op | body: %{op.body | value: claim_invoke}}
    claim_xdr = Fixtures.reencode(%{inspected | tx: %{inspected.tx | operations: XDR.Operations.new([claim_op])}})
    assert {:error, claim_error} = Envelope.decode(claim_xdr)
    assert claim_error.detail =~ "SEP-41 transfer"

    void_map =
      XDR.SCMapEntry.new(
        XDR.SCVal.new(XDR.SCSymbol.new("amount"), XDR.SCValType.new(:SCV_SYMBOL)),
        XDR.SCVal.new(XDR.Void.new(), XDR.SCValType.new(:SCV_VOID))
      )

    map_data = XDR.SCVal.new(XDR.OptionalSCMap.new(XDR.SCMap.new([void_map])), XDR.SCValType.new(:SCV_MAP))
    map_body = XDR.ContractEventBody.new(XDR.ContractEventV0.new(XDR.SCValList.new([]), map_data), 0)

    map_void_xdr =
      true
      |> XDR.Bool.new()
      |> XDR.DiagnosticEvent.new(
        XDR.ContractEvent.new(
          XDR.ExtensionPoint.new(XDR.Void.new(), 0),
          XDR.OptionalHash.new(),
          XDR.ContractEventType.new(:CONTRACT),
          map_body
        )
      )
      |> XDR.DiagnosticEvent.encode_xdr!()
      |> Base.encode64()

    assert [%{amount: nil}] = Envelope.contract_events([map_void_xdr])
  end

  test "RPC error, timeout, Horizon fallback and ledger-entry shapes", context do
    alias StellarBase.XDR

    observed = Fixtures.observed_transfer()
    config = context.charge.method_details
    short = Map.merge(config, %{"poll_interval_ms" => 1, "poll_timeout_ms" => 20})

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 500, "nope")
    end)

    assert {:error, http} = RPC.get_latest_ledger(config)
    assert http.status == 503

    stub_rpc(context, fn
      "getLatestLedger" -> %{"latestLedger" => 1}
    end)

    assert {:error, latest} = RPC.get_latest_ledger(config)
    assert latest.status == 503

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, send_err} = RPC.send_transaction(context.signed, config)
    assert send_err.status == 503
    assert {:error, get_err} = RPC.get_transaction(context.hash, config)
    assert get_err.status == 503
    assert {:error, await_err} = RPC.await_transaction(context.hash, short)
    assert await_err.status == 503

    stub_rpc(context, fn
      "getTransaction" -> %{"status" => "NOT_FOUND"}
    end)

    assert {:error, timeout} = RPC.await_transaction(context.hash, short)
    assert timeout.type == Errors.new(:settlement_timeout, "").type

    {:ok, hits} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => "getTransaction"} = Jason.decode!(body)
      n = Agent.get_and_update(hits, &{&1, &1 + 1})

      result =
        if n == 0 do
          %{"status" => "NOT_FOUND"}
        else
          %{"status" => "SUCCESS", "envelopeXdr" => context.signed}
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => result})
    end)

    assert {:ok, %{"status" => "SUCCESS"}} = RPC.await_transaction(context.hash, short)

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => observed["getLedgerEntries"]["xdr"]}]}
    end)

    assert {:ok, sequence} = RPC.account_sequence(observed["payer"], config)
    assert is_integer(sequence)

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => Fixtures.ledger_entry_xdr(observed["getLedgerEntries"]["xdr"])}]}
    end)

    assert {:ok, wrapped} = RPC.account_sequence(observed["payer"], config)
    assert is_integer(wrapped)

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => "!!!!"}]}
      "horizon" -> %{"sequence" => "12abc"}
    end)

    assert {:error, bad_xdr} = RPC.account_sequence(context.payer.public, config)
    assert bad_xdr.status == 503

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => 12}]}
      "horizon" -> %{"sequence" => 44}
    end)

    assert {:ok, 44} = RPC.account_sequence(context.payer.public, config)

    pubnet = Map.merge(config, %{"network" => "stellar:pubnet", "horizon_url" => "https://horizon.test.example"})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          assert String.starts_with?(conn.request_path, "/accounts/") or String.contains?(to_string(conn.host), "horizon")
          Req.Test.json(conn, %{"sequence" => 9})

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"method" => "getLedgerEntries"} = Jason.decode!(body)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32_000}})
      end
    end)

    assert {:ok, 9} = RPC.account_sequence(context.payer.public, pubnet)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.transport_error(conn, :etime)

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"method" => "getLedgerEntries"} = Jason.decode!(body)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      end
    end)

    assert {:error, horizon_down} = RPC.account_sequence(context.payer.public, config)
    assert horizon_down.status == 503

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"status" => 404})

        _ ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      end
    end)

    assert {:error, missing} = RPC.account_sequence(context.payer.public, config)
    assert missing.status == 503

    assert {:error, invalid} = RPC.account_sequence("not-an-account", config)
    assert invalid.status == 503

    stub_rpc(context, fn
      "sendTransaction" -> %{"status" => "UNKNOWN"}
    end)

    assert {:error, weird} = RPC.send_transaction(context.signed, config)
    assert weird.status == 503

    pubnet_default = Map.put(config, "network", "stellar:pubnet")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{"sequence" => 3})

        _ ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      end
    end)

    assert {:ok, 3} = RPC.account_sequence(context.payer.public, pubnet_default)

    assert_raise ArgumentError, fn ->
      Stellar.validate_config!(%{"rpc_url" => @rpc_url, "network" => "stellar:testnet", "store" => {ConCacheStore, %{}}})
    end

    assert_raise ArgumentError, fn ->
      Stellar.validate_config!(%{"rpc_url" => @rpc_url, "network" => "stellar:testnet", "store" => Integer})
    end

    assert_raise ArgumentError, fn ->
      Stellar.validate_config!(%{
        "rpc_url" => @rpc_url,
        "network" => "stellar:testnet",
        "feePayer" => true,
        "fee_payer_secret" => 123
      })
    end

    leftover_ledger = Base.encode64(Base.decode64!(observed["getLedgerEntries"]["xdr"]) <> <<0, 0, 0, 1>>)

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => leftover_ledger}]}
      "horizon" -> %{"sequence" => 7}
    end)

    assert {:ok, 7} = RPC.account_sequence(observed["payer"], config)

    {:ok, payer_raw} = StellarBase.StrKey.decode(observed["payer"], :ed25519_public_key)

    data_xdr =
      payer_raw
      |> XDR.UInt256.new()
      |> XDR.PublicKey.new(XDR.PublicKeyType.new())
      |> XDR.AccountID.new()
      |> XDR.DataEntry.new(
        XDR.String64.new("n"),
        XDR.DataValue.new(<<>>),
        XDR.Ext.new()
      )
      |> XDR.LedgerEntryData.new(XDR.LedgerEntryType.new(:DATA))
      |> XDR.LedgerEntryData.encode_xdr!()
      |> Base.encode64()

    stub_rpc(context, fn
      "getLedgerEntries" -> %{"entries" => [%{"xdr" => data_xdr}]}
      "horizon" -> %{"sequence" => 8}
    end)

    assert {:ok, 8} = RPC.account_sequence(observed["payer"], config)
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
