defmodule MPP.Methods.StellarIntegrationTest do
  @moduledoc """
  Live Soroban testnet oracle for Stellar charge verification.

  Pins SEP-41 `transfer` semantics against the Stellar-owned token interface:
  https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0041.md
  https://developers.stellar.org/docs/tokens/token-interface
  https://developers.stellar.org/docs/data/apis/rpc/api-reference/methods/getTransaction
  https://developers.stellar.org/docs/data/apis/rpc/api-reference/methods/simulateTransaction

  Native XLM SAC on testnet is the Stellar-reserved contract
  `CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC`.
  """
  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Methods.Stellar
  alias MPP.Methods.Stellar.Envelope
  alias MPP.Methods.Stellar.RPC
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Test.Stellar, as: Fixtures

  @moduletag :integration
  @moduletag timeout: 180_000

  @rpc_url "https://soroban-testnet.stellar.org"
  @native_sac Fixtures.native_sac()

  setup_all do
    rpc_url = System.get_env("STELLAR_TESTNET_RPC_URL") || @rpc_url

    case Req.post(rpc_url,
           json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "getHealth", "params" => %{}},
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"result" => %{"status" => "healthy"}}}} ->
        :ok

      {:ok, %{status: 200, body: %{"result" => result}}} when is_map(result) ->
        :ok

      other ->
        flunk("""
        Missing Stellar testnet (Soroban RPC) setup.

        The official testnet RPC was unreachable (#{inspect(other)}).
        From the repository root:

          export STELLAR_TESTNET_RPC_URL="https://soroban-testnet.stellar.org"
          mix test test/mpp/methods/stellar_integration_test.exs --include integration

        Accounts are generated per run and funded through Friendbot:
          https://friendbot.stellar.org
        Native XLM SAC (SEP-41): #{@native_sac}
        RPC reference: https://developers.stellar.org/docs/data/apis/rpc/api-reference/methods/getTransaction
        """)
    end

    payer = Fixtures.keypair()
    recipient = Fixtures.keypair()
    fee_payer = Fixtures.keypair()
    Fixtures.fund!(payer.public)
    Fixtures.fund!(recipient.public)
    Fixtures.fund!(fee_payer.public)

    {:ok, rpc_url: rpc_url, payer: payer, recipient: recipient, fee_payer: fee_payer}
  end

  setup do
    name = :"stellar_integration_#{System.unique_integer([:positive])}"
    start_supervised!({ConCacheStore, name: name, ttl: 600_000})
    {:ok, store: {ConCacheStore, name: name}}
  end

  test "pull unsponsored: real SAC transfer success and wrong-recipient error", context do
    config = rpc_config(context)
    prepared = Fixtures.prepare_transfer(config, source: context.payer, to: context.recipient.public)
    charge = Fixtures.charge(rpc_url: context.rpc_url, recipient: context.recipient.public, store: context.store)

    wrong = %{charge | recipient: Fixtures.keypair().public}
    assert {:error, error} = Stellar.verify(%{"type" => "transaction", "transaction" => prepared.xdr}, wrong)
    assert error.type == Errors.new(:verification_failed, "").type

    assert {:ok, %Receipt{} = receipt} = Stellar.verify(%{"type" => "transaction", "transaction" => prepared.xdr}, charge)
    assert receipt.method == "stellar"
    assert receipt.reference == prepared.hash

    {:ok, on_chain} = RPC.get_transaction(receipt.reference, config)
    assert on_chain["status"] == "SUCCESS"
    assert_sep41_transfer!(on_chain, context.payer.public, context.recipient.public, 1_000_000)
  end

  test "push hash: real SAC transfer success and already-consumed replay error", context do
    config = rpc_config(context)
    prepared = Fixtures.prepare_transfer(config, source: context.payer, to: context.recipient.public)
    {:ok, sent} = RPC.send_transaction(prepared.xdr, config)
    hash = sent["hash"]
    {:ok, %{"status" => "SUCCESS"} = result} = RPC.await_transaction(hash, config)
    assert_sep41_transfer!(result, context.payer.public, context.recipient.public, 1_000_000)

    charge = Fixtures.charge(rpc_url: context.rpc_url, recipient: context.recipient.public, store: context.store)
    assert {:ok, %Receipt{} = receipt} = Stellar.verify(%{"type" => "hash", "hash" => hash}, charge)
    assert receipt.reference == String.downcase(hash)

    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => hash}, charge)
    assert error.type == Errors.new(:invalid_challenge, "").type
  end

  test "push hash: real SUCCESS transfer to a different destination is rejected", context do
    config = rpc_config(context)
    expected = Fixtures.keypair()
    Fixtures.fund!(expected.public)
    prepared = Fixtures.prepare_transfer(config, source: context.payer, to: context.recipient.public)
    {:ok, sent} = RPC.send_transaction(prepared.xdr, config)
    {:ok, %{"status" => "SUCCESS"}} = RPC.await_transaction(sent["hash"], config)

    charge = Fixtures.charge(rpc_url: context.rpc_url, recipient: expected.public, store: context.store)
    assert {:error, error} = Stellar.verify(%{"type" => "hash", "hash" => sent["hash"]}, charge)
    assert error.type == Errors.new(:verification_failed, "").type
  end

  test "pull sponsored: server rebuilds, pays fees, and rejects a drain of the fee payer", context do
    config = rpc_config(context)

    prepared =
      Fixtures.prepare_transfer(config,
        source: context.payer,
        to: context.recipient.public,
        sponsored: true
      )

    charge =
      Fixtures.charge(
        rpc_url: context.rpc_url,
        recipient: context.recipient.public,
        store: context.store,
        method_details: %{"feePayer" => true, "fee_payer_secret" => context.fee_payer.secret}
      )

    drain =
      Fixtures.prepare_transfer(config,
        source: context.payer,
        from: context.fee_payer.public,
        to: context.recipient.public,
        sponsored: true
      )

    assert {:error, drain_error} = Stellar.verify(%{"type" => "transaction", "transaction" => drain.xdr}, charge)
    assert drain_error.type == Errors.new(:verification_failed, "").type

    assert {:ok, %Receipt{} = receipt} = Stellar.verify(%{"type" => "transaction", "transaction" => prepared.xdr}, charge)
    assert receipt.method == "stellar"
    {:ok, on_chain} = RPC.get_transaction(receipt.reference, config)
    assert on_chain["status"] == "SUCCESS"
    assert_sep41_transfer!(on_chain, context.payer.public, context.recipient.public, 1_000_000)
  end

  defp rpc_config(context) do
    %{
      "rpc_url" => context.rpc_url,
      "network" => "stellar:testnet",
      "poll_interval_ms" => 1_000,
      "poll_timeout_ms" => 60_000
    }
  end

  defp assert_sep41_transfer!(result, from, to, amount) do
    envelope = result["envelopeXdr"]
    assert is_binary(envelope)
    {:ok, inspected} = Envelope.decode(envelope)
    assert inspected.transfer.contract == @native_sac
    assert inspected.transfer.from == from
    assert inspected.transfer.to == to
    assert inspected.transfer.amount == amount

    events =
      result
      |> get_in(["events", "contractEventsXdr"])
      |> List.wrap()
      |> List.flatten()
      |> Envelope.contract_events()

    diagnostic = result |> Map.get("diagnosticEventsXdr", []) |> Envelope.contract_events()
    # SEP-41 transfer topics are `["transfer", from, to]` (Stellar token interface).
    # SAC may append a SEP-11 asset topic; Envelope.contract_events/1 keeps the first two addresses.
    assert Enum.any?(events ++ diagnostic, fn event ->
             event.name == "transfer" and event.from == from and event.to == to and event.amount == amount
           end)
  end
end
