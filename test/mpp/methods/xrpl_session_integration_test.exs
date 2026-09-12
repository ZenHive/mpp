defmodule MPP.Methods.XRPL.SessionIntegrationTest do
  @moduledoc """
  Live testnet oracle for XRPL payment-channel sessions.

  Claim signatures are produced by xrpl.js `authorizeChannel` and checked
  both locally and via `channel_verify`:
  https://xrpl.org/docs/references/protocol/transactions/types/paymentchannelclaim
  https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/payment-channel-methods/channel_verify
  """
  use ExUnit.Case, async: false

  alias MPP.Intents.Session
  alias MPP.Methods.XRPL.Claim
  alias MPP.Methods.XRPL.Session, as: XRPLSession
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Store

  @moduletag :integration
  @moduletag timeout: 180_000

  setup_all do
    url = System.get_env("XRPL_TESTNET_RPC_URL")

    if is_nil(url) or System.find_executable("node") == nil or
         not File.dir?(System.get_env("XRPL_JS_PATH") || "tmp/xrpl/node_modules/xrpl") do
      flunk("""
      Missing XRPL testnet setup. Run from the repository root:
        npm install --prefix tmp/xrpl --no-audit --no-fund xrpl@4.6.0
        export XRPL_TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
        export XRPL_JS_PATH="$PWD/tmp/xrpl/node_modules/xrpl"
        mix test test/mpp/methods/xrpl_session_integration_test.exs --include integration
      Wallets are generated and funded through https://faucet.altnet.rippletest.net/accounts.
      Setup: https://xrpl.org/resources/dev-tools/xrp-faucets
      No wallet secret is sent to the RPC or written to a fixture.
      """)
    end

    assert %{"info" => %{"network_id" => 1}} = rpc!(url, "server_info", %{})
    payer = funded_wallet!()
    recipient = funded_wallet!()
    {:ok, url: url, payer: payer, recipient: recipient}
  end

  setup do
    name = String.to_atom("xrpl_session_live_#{System.unique_integer([:positive])}")
    start_supervised!(ETSStore.child_spec(name: name))
    {:ok, store: {ETSStore, [name: name]}}
  end

  test "open, voucher and close against a real payment channel", context do
    session = session(context)
    create = payment_channel_create(context)
    signed = sign!(context, create)
    channel_id = predicted_id!(context, signed["Sequence"])
    open_sig = authorize!(context, channel_id, "100000")

    verified =
      rpc!(context.url, "channel_verify", %{
        "channel_id" => channel_id,
        "signature" => open_sig,
        "public_key" => context.payer["publicKey"],
        "amount" => "100000"
      })

    assert verified["signature_verified"] == true
    assert :ok = Claim.verify(channel_id, 100_000, open_sig, context.payer["publicKey"])

    assert {:ok, open} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => signed["tx_blob"], "amount" => "100000", "signature" => open_sig},
               session
             )

    assert open.extensions["channelId"] == channel_id
    assert open.extensions["txHash"] == signed["hash"]
    ledger = rpc!(context.url, "tx", %{"transaction" => signed["hash"]})
    assert ledger["validated"] == true
    assert ledger["meta"]["TransactionResult"] == "tesSUCCESS"

    voucher_sig = authorize!(context, channel_id, "200000")

    assert {:ok, voucher} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => channel_id, "amount" => "200000", "signature" => voucher_sig},
               session
             )

    assert voucher.extensions["cumulative"] == "200000"
    refute Map.has_key?(voucher.extensions, "txHash")
    assert {:ok, channel} = Store.get({ETSStore, [name: store_name(context.store), network: "testnet"]}, channel_id)
    assert channel.cumulative_amount == 200_000
    assert channel.spent == 200_000
    assert channel.proof.amount == 200_000
    assert channel.proof.signature == voucher_sig
    assert String.upcase(channel.proof.public_key) == String.upcase(context.payer["publicKey"])

    tampered =
      String.replace_prefix(voucher_sig, String.slice(voucher_sig, 0, 2), flip_hex(String.slice(voucher_sig, 0, 2)))

    assert {:error, %MPP.Errors{type: "https://paymentauth.org/problems/session/invalid-signature"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => channel_id, "amount" => "300000", "signature" => tampered},
               session
             )

    assert {:ok, closed} =
             XRPLSession.verify(
               %{"action" => "close", "channelId" => channel_id, "amount" => "200000", "signature" => voucher_sig},
               session
             )

    assert closed.extensions["action"] == "close"
    assert is_binary(closed.extensions["txHash"])
    refute closed.extensions["txHash"] == signed["hash"]

    claimed = rpc!(context.url, "tx", %{"transaction" => closed.extensions["txHash"]})
    assert claimed["validated"] == true
    assert claimed["meta"]["TransactionResult"] == "tesSUCCESS"

    entry = rpc!(context.url, "ledger_entry", %{"index" => channel_id, "ledger_index" => "validated"})

    cond do
      entry["error"] == "entryNotFound" ->
        :ok

      match?(%{"node" => %{"Balance" => _}}, entry) ->
        assert String.to_integer(entry["node"]["Balance"]) >= 200_000

      true ->
        flunk("PayChannel neither deleted nor advanced after PaymentChannelClaim: #{inspect(entry)}")
    end

    assert {:ok, %Channel{status: :closed, proof: proof}} =
             Store.get({ETSStore, [name: store_name(context.store), network: "testnet"]}, channel_id)

    assert proof.amount == 200_000
    assert proof.signature == voucher_sig
  end

  test "current Sequence advances after a successful claim submit", context do
    session = session(context)
    {channel_id, signature} = open_channel!(context, session)
    info = rpc!(context.url, "account_info", %{"account" => context.recipient["address"], "ledger_index" => "current"})
    sequence = info["account_data"]["Sequence"]
    ledger = rpc!(context.url, "ledger_current", %{})

    signed =
      js!(%{
        "seed" => context.recipient["seed"],
        "tx" => %{
          "TransactionType" => "PaymentChannelClaim",
          "Account" => context.recipient["address"],
          "Channel" => channel_id,
          "Balance" => "100000",
          "Amount" => "100000",
          "Signature" => signature,
          "PublicKey" => context.payer["publicKey"],
          "Flags" => 2_147_614_720,
          "Fee" => "12",
          "Sequence" => sequence,
          "LastLedgerSequence" => ledger["ledger_current_index"] + 20
        }
      })

    submitted = rpc!(context.url, "submit", %{"tx_blob" => signed["tx_blob"]})
    assert submitted["engine_result"] == "tesSUCCESS"
    current = rpc!(context.url, "account_info", %{"account" => context.recipient["address"], "ledger_index" => "current"})
    assert current["account_data"]["Sequence"] == sequence + 1

    assert {:ok, validated} =
             MPP.Methods.XRPL.RPC.await_validated(signed["hash"], session.method_details, submitted: true)

    assert validated["meta"]["TransactionResult"] == "tesSUCCESS"
  end

  @tag timeout: 300_000
  test "two concurrent closes to one Destination both settle with distinct Sequences", context do
    session = session(context)
    {id_a, sig_a} = open_channel!(context, session)
    {id_b, sig_b} = open_channel!(context, session)
    parent = self()

    close = fn channel_id, signature ->
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go ->
            XRPLSession.verify(
              %{"action" => "close", "channelId" => channel_id, "amount" => "100000", "signature" => signature},
              session
            )
        end
      end)
    end

    task_a = close.(id_a, sig_a)
    task_b = close.(id_b, sig_b)
    assert_receive {:ready, pid_a}, 30_000
    assert_receive {:ready, pid_b}, 30_000
    send(pid_a, :go)
    send(pid_b, :go)

    hashes =
      Enum.map([task_a, task_b], fn task ->
        case Task.await(task, 180_000) do
          {:ok, receipt} ->
            assert is_binary(receipt.extensions["txHash"])
            receipt.extensions["txHash"]

          other ->
            flunk("concurrent close failed: #{inspect(other)}")
        end
      end)

    assert [_, _] = Enum.uniq(hashes)

    sequences =
      Enum.map(hashes, fn hash ->
        tx = rpc!(context.url, "tx", %{"transaction" => hash})
        assert tx["validated"] == true
        assert tx["meta"]["TransactionResult"] == "tesSUCCESS"
        sequence = tx["Sequence"] || get_in(tx, ["tx_json", "Sequence"])
        assert is_integer(sequence)
        sequence
      end)

    assert [_, _] = Enum.uniq(sequences)
  end

  defp open_channel!(context, session) do
    create = payment_channel_create(context)
    signed = sign!(context, create)
    channel_id = predicted_id!(context, signed["Sequence"])
    open_sig = authorize!(context, channel_id, "100000")

    assert {:ok, open} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => signed["tx_blob"], "amount" => "100000", "signature" => open_sig},
               session
             )

    assert open.extensions["channelId"] == channel_id
    {channel_id, open_sig}
  end

  defp session(context) do
    {:ok, session} =
      Session.new(
        amount: "100000",
        currency: "XRP",
        recipient: context.recipient["address"],
        method_details: %{
          "rpc_url" => context.url,
          "network" => "testnet",
          "credential_source" => "did:pkh:xrpl:1:" <> context.payer["address"],
          "session_store" => context.store,
          "min_settle_delay" => 3600,
          "destination_secret" => context.recipient["seed"]
        }
      )

    session
  end

  defp payment_channel_create(context) do
    %{
      "TransactionType" => "PaymentChannelCreate",
      "Account" => context.payer["address"],
      "Destination" => context.recipient["address"],
      "Amount" => "1000000",
      "SettleDelay" => 3600,
      "PublicKey" => context.payer["publicKey"]
    }
  end

  defp predicted_id!(context, sequence) do
    {:ok, id} = Channel.compute_xrpl_id(context.payer["address"], context.recipient["address"], sequence)
    {:ok, wire} = Channel.to_xrpl_id(id)
    wire
  end

  defp authorize!(context, channel_id, amount) do
    js!(%{
      "seed" => context.payer["seed"],
      "claim" => %{"channel" => channel_id, "amount" => amount}
    })["signature"]
  end

  defp sign!(context, tx) do
    info = account!(context.url, context.payer["address"], System.monotonic_time(:millisecond) + 30_000)
    ledger = rpc!(context.url, "ledger_current", %{})

    tx =
      Map.merge(tx, %{
        "Fee" => "12",
        "Sequence" => info["account_data"]["Sequence"],
        "LastLedgerSequence" => ledger["ledger_current_index"] + 20
      })

    signed = js!(%{"seed" => context.payer["seed"], "tx" => tx})
    Map.put(signed, "Sequence", tx["Sequence"])
  end

  defp account!(url, address, deadline) do
    result = rpc!(url, "account_info", %{"account" => address, "ledger_index" => "validated"})

    case result do
      %{"account_data" => %{"Sequence" => sequence}} when is_integer(sequence) ->
        result

      %{"error" => "actNotFound"} ->
        assert System.monotonic_time(:millisecond) < deadline, "Faucet account did not reach a validated ledger"

        receive do
        after
          1000 -> :ok
        end

        account!(url, address, deadline)

      other ->
        flunk("XRPL account_info failed: #{inspect(other)}")
    end
  end

  defp funded_wallet! do
    wallet = js!(%{})

    assert {:ok, %{status: 200, body: body}} =
             Req.post("https://faucet.altnet.rippletest.net/accounts",
               json: %{"destination" => wallet["address"]},
               retry: false,
               receive_timeout: 60_000
             )

    assert body["account"]["address"] == wallet["address"]
    wallet
  end

  defp js!(input) do
    {output, status} = System.cmd("node", ["test/support/xrpl/sign.cjs", Jason.encode!(input)], stderr_to_stdout: true)
    assert status == 0, "XRPL signing helper failed; install xrpl@4.6.0 and set XRPL_JS_PATH"
    Jason.decode!(output)
  end

  defp rpc!(url, method, params) do
    assert {:ok, %{status: 200, body: %{"result" => result}}} =
             Req.post(url, json: %{"method" => method, "params" => [Map.put(params, "api_version", 1)]}, retry: false)

    result
  end

  defp store_name({ETSStore, opts}), do: Keyword.fetch!(opts, :name)

  defp flip_hex(<<a, b>> = pair) do
    flipped = if a == ?0, do: "1" <> <<b>>, else: "0" <> <<b>>
    if flipped == pair, do: "F" <> <<b>>, else: flipped
  end
end
