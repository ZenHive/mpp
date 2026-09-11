defmodule MPP.Methods.XRPL.SessionTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.Methods.XRPL.Codec
  alias MPP.Methods.XRPL.Session, as: XRPLSession
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Store

  defmodule DownStore do
    @moduledoc false
    def get(_id), do: {:error, :unavailable}
  end

  @fixture "test/fixtures/xrpl/session.json" |> File.read!() |> Jason.decode!()
  @blob @fixture["create"]["tx_blob"]
  @hash @fixture["create"]["hash"]
  @channel_id @fixture["channelId"]
  @payer @fixture["payer"]["address"]
  @recipient @fixture["recipient"]["address"]
  @open_sig @fixture["claims"]["open"]
  @voucher_sig @fixture["claims"]["voucher"]

  setup do
    name = String.to_atom("xrpl_session_#{System.unique_integer([:positive])}")
    start_supervised!(ETSStore.child_spec(name: name))
    {:ok, session} = session(%{"session_store" => {ETSStore, [name: name]}})
    {:ok, session: session, store: {ETSStore, [name: name, network: "testnet"]}, owner: self()}
  end

  test "wire names and config validation", %{session: session} do
    assert XRPLSession.method_name() == "xrpl"
    assert XRPLSession.credential_types() == []
    assert :ok = XRPLSession.validate_config!(session.method_details)
    assert XRPLSession.challenge_method_details(session) == %{"network" => "testnet"}
    refute Map.has_key?(XRPLSession.challenge_method_details(session), "rpc_url")

    assert_raise ArgumentError, ~r/rpc_url/, fn ->
      XRPLSession.validate_config!(%{"rpc_url" => "http://example.com", "network" => "testnet"})
    end
  end

  test "rejects a charge intent and malformed session payloads", %{session: session} do
    {:ok, charge} = Charge.new(amount: "1", currency: "XRP", recipient: @recipient)
    assert {:error, %Errors{} = error} = XRPLSession.verify(%{"action" => "open"}, charge)
    assert String.contains?(error.type, "invalid-payload")

    for payload <- [
          %{},
          %{"action" => "topUp", "transaction" => @blob, "additionalDeposit" => "1"},
          %{"action" => "open", "transaction" => "00", "amount" => "100000", "signature" => @open_sig},
          %{"action" => "voucher", "channelId" => "zz", "amount" => "100000", "signature" => @open_sig},
          %{"action" => "open", "blob" => @blob, "amount" => "100000", "signature" => @open_sig},
          %{
            "action" => "open",
            "transaction" => @blob,
            "amount" => String.duplicate("9", 19),
            "signature" => @open_sig
          }
        ] do
      assert {:error, %Errors{type: type}} = XRPLSession.verify(payload, session)
      assert type in [Errors.new(:malformed_credential, "").type, Errors.new(:verification_failed, "").type]
    end

    refute_received {:rpc, _}
  end

  test "open, voucher and close update the session store atomically", context do
    stub(context, @hash)

    assert {:ok, open} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    assert open.method == "xrpl"
    assert open.reference == @channel_id
    assert open.extensions["action"] == "open"
    assert open.extensions["channelId"] == @channel_id
    assert open.extensions["cumulative"] == "100000"
    assert open.extensions["acceptedCumulative"] == "100000"
    assert open.extensions["spent"] == "100000"
    assert open.extensions["txHash"] == @hash
    assert {:ok, channel} = Store.get(context.store, @channel_id)
    assert channel.token == "XRP"
    assert channel.payer == @payer
    assert channel.recipient == @recipient
    assert channel.deposit == 1_000_000
    assert channel.cumulative_amount == 100_000
    assert channel.spent == 100_000

    assert {:ok, voucher} =
             XRPLSession.verify(
               %{
                 "action" => "voucher",
                 "channelId" => String.downcase(@channel_id),
                 "amount" => "200000",
                 "signature" => @voucher_sig
               },
               context.session
             )

    assert voucher.extensions["action"] == "voucher"
    refute Map.has_key?(voucher.extensions, "txHash")
    assert voucher.extensions["cumulative"] == "200000"
    assert {:ok, after_voucher} = Store.get(context.store, @channel_id)
    assert after_voucher.cumulative_amount == 200_000
    assert after_voucher.spent == 200_000

    assert {:ok, closed} =
             XRPLSession.verify(
               %{"action" => "close", "channelId" => @channel_id, "amount" => "200000", "signature" => @voucher_sig},
               context.session
             )

    assert closed.extensions["action"] == "close"
    assert {:ok, %Channel{status: :closed, cumulative_amount: 200_000}} = Store.get(context.store, @channel_id)
  end

  test "an equal voucher is a no-op on the store", context do
    stub(context, @hash)

    assert {:ok, _} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    assert {:ok, before} = Store.get(context.store, @channel_id)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/delta-too-small"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    assert {:ok, ^before} = Store.get(context.store, @channel_id)
  end

  test "tampered claim signatures fail before the store is written", context do
    stub(context, @hash)
    tampered = String.replace_prefix(@open_sig, "27", "28")

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/invalid-signature"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => tampered},
               context.session
             )

    assert :not_found = Store.get(context.store, @channel_id)
  end

  test "destination mismatch and a short settle delay fail closed", context do
    stub(context, @hash, destination: @payer)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    {:ok, session} =
      session(%{"min_settle_delay" => 86_400, "session_store" => context.session.method_details["session_store"]})

    stub(%{context | session: session}, @hash)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               session
             )
  end

  test "decode_create reads the PaymentChannelCreate fixture" do
    assert {:ok, tx} = Codec.decode_create(@blob)
    assert tx["TransactionType"] == "PaymentChannelCreate"
    assert tx["Account"] == @payer
    assert tx["Destination"] == @recipient
    assert tx["Amount"] == "1000000"
    assert tx["SettleDelay"] == 3600
    assert {:error, :malformed_blob} = Codec.decode(@blob)
    assert Codec.signed?(tx)
    refute Codec.signed?(%{})
    assert Codec.signed?(%{"Signers" => [%{}]})
  end

  test "rejects missing source, wrong currency, expired channels and exhausted claims", context do
    {:ok, no_source} =
      session(%{"credential_source" => nil, "session_store" => context.session.method_details["session_store"]})

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               no_source
             )

    {:ok, usd} =
      Session.new(
        amount: "100000",
        currency: "USD",
        recipient: @recipient,
        method_details: context.session.method_details
      )

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               usd
             )

    stub(context, @hash, expiration: 1)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/channel-finalized"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )
  end

  test "rejects a claim above the deposit and a missing ledger channel", context do
    stub(context, @hash, amount: "50000")

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/amount-exceeds-deposit"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    stub(context, @hash, missing: true)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/channel-not-found"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "200000", "signature" => @voucher_sig},
               context.session
             )

    stub(context, @hash, entry: %{"node" => %{"LedgerEntryType" => "AccountRoot"}})

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "200000", "signature" => @voucher_sig},
               context.session
             )
  end

  test "rejects a second open of the same channel", context do
    stub(context, @hash)

    assert {:ok, _} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    assert {:error, %Errors{detail: detail}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    assert detail =~ "already exists"
  end

  test "rejects odd-length hex, non-hex amounts and non-binary fields", %{session: session} do
    assert {:error, %Errors{type: "https://paymentauth.org/problems/malformed-credential"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => "123", "amount" => "100000", "signature" => @open_sig},
               session
             )

    assert {:error, %Errors{type: "https://paymentauth.org/problems/malformed-credential"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "1.5", "signature" => @open_sig},
               session
             )

    assert {:error, %Errors{type: "https://paymentauth.org/problems/malformed-credential"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => 12, "amount" => "100000", "signature" => @open_sig},
               session
             )

    assert {:error, %Errors{type: "https://paymentauth.org/problems/malformed-credential"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => 12},
               session
             )
  end

  test "rejects a replayed claim at the ledger balance and a broken create receipt", context do
    stub(context, @hash, balance: "100000")

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    stub(context, @hash, expiration: "soon")

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/channel-finalized"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    {:ok, down} = session(%{"session_store" => DownStore})

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               down
             )

    stub(context, @hash, created_index: "00" <> String.duplicate("11", 31))

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )
  end

  test "maps RPC failures onto verification_failed rather than a bare :error", context do
    plug = unique_plug()
    {:ok, session} = isolated_session(context, plug)

    stub(%{context | session: session}, @hash, network_id: 0)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               session
             )

    stub(%{context | session: session}, @hash,
      submit: %{"engine_result" => "tecUNFUNDED", "tx_json" => %{"hash" => @hash}}
    )

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               session
             )

    {:ok, impatient} =
      isolated_session(context, plug, %{"poll_timeout_ms" => 1, "poll_interval_ms" => 1000})

    stub(%{context | session: impatient}, @hash, validated: false)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               impatient
             )

    stub(%{context | session: session}, @hash, network_id: 0)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "200000", "signature" => @voucher_sig},
               session
             )
  end

  test "namespaces the default ETS store by network", context do
    {:ok, session} = session(%{"session_store" => ETSStore})
    stub(%{context | session: session}, @hash)

    on_exit(fn ->
      Store.delete({ETSStore, [network: "testnet"]}, @channel_id)
      Store.delete(ETSStore, @channel_id)
    end)

    assert {:ok, _} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               session
             )

    assert {:ok, %Channel{token: "XRP"}} = Store.get({ETSStore, [network: "testnet"]}, @channel_id)
    assert :not_found = Store.get(ETSStore, @channel_id)
  end

  test "rejects a 0x-prefixed blob, integer ledger amounts and a bad DID", context do
    stub(context, @hash, amount: 1_000_000)

    assert {:ok, _} =
             XRPLSession.verify(
               %{
                 "action" => "open",
                 "transaction" => "0x" <> @blob,
                 "amount" => "100000",
                 "signature" => "0X" <> @open_sig
               },
               context.session
             )
  end

  test "rejects an unusable source DID and a zero settle-delay floor", context do
    {:ok, bad_did} =
      session(%{
        "credential_source" => "did:pkh:xrpl:1:not-an-address",
        "session_store" => context.session.method_details["session_store"]
      })

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               bad_did
             )

    {:ok, zero} =
      session(%{
        "min_settle_delay" => 0,
        "session_store" => context.session.method_details["session_store"]
      })

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               zero
             )
  end

  test "rejects a closed channel and a source that is not the funder", context do
    {:ok, closed} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: @recipient,
        token: "XRP",
        deposit: 1_000_000
      )

    {:ok, closed} = Channel.activate(closed)
    {:ok, closed} = Channel.close(closed)
    assert :ok = Store.put(context.store, closed)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/channel-finalized"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    {:ok, other} =
      session(%{
        "credential_source" => "did:pkh:xrpl:1:" <> @recipient,
        "session_store" => context.session.method_details["session_store"]
      })

    stub(%{context | session: other}, @hash)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               other
             )
  end

  defp session(config) do
    Session.new(
      amount: "100000",
      currency: "XRP",
      recipient: @recipient,
      method_details:
        Map.merge(
          %{
            "rpc_url" => "https://xrpl.test",
            "network" => "testnet",
            "credential_source" => "did:pkh:xrpl:1:" <> @payer,
            "req_options" => [plug: {Req.Test, __MODULE__}]
          },
          config
        )
    )
  end

  defp isolated_session(context, plug, extra \\ %{}) do
    session(
      Map.merge(
        %{
          "session_store" => context.session.method_details["session_store"],
          "req_options" => [plug: {Req.Test, plug}]
        },
        extra
      )
    )
  end

  defp unique_plug, do: String.to_atom("xrpl_session_rpc_#{System.unique_integer([:positive])}")

  defp stub(context, hash, opts \\ []) do
    {_req, name} = context.session.method_details["req_options"][:plug]
    owner = context.owner
    Req.Test.stub(name, fn conn -> rpc_response(conn, owner, hash, opts) end)
  end

  defp rpc_response(conn, owner, hash, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"method" => method} = Jason.decode!(body)
    send(owner, {:rpc, method})
    Req.Test.json(conn, %{"result" => rpc_result(method, hash, opts)})
  end

  defp rpc_result("server_info", _hash, opts), do: %{"info" => %{"network_id" => Keyword.get(opts, :network_id, 1)}}
  defp rpc_result("submit", hash, opts), do: submit_result(hash, opts)
  defp rpc_result("tx", hash, opts), do: tx_rpc(hash, opts)
  defp rpc_result("ledger_entry", _hash, opts), do: ledger_entry(opts)
  defp rpc_result("ledger", _hash, opts), do: %{"ledger" => %{"close_time" => Keyword.get(opts, :close_time, 1)}}

  defp submit_result(hash, opts) do
    Keyword.get(opts, :submit, %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => hash}})
  end

  defp tx_rpc(hash, opts) do
    if Keyword.get(opts, :validated, true) do
      tx_result(hash, opts)
    else
      %{"validated" => false, "hash" => hash}
    end
  end

  defp tx_result(hash, opts) do
    %{
      "validated" => true,
      "hash" => hash,
      "ledger_index" => 8,
      "meta" => %{
        "TransactionResult" => "tesSUCCESS",
        "AffectedNodes" => [
          %{
            "CreatedNode" => %{
              "LedgerEntryType" => "PayChannel",
              "LedgerIndex" => Keyword.get(opts, :created_index, @channel_id)
            }
          }
        ]
      }
    }
  end

  defp ledger_entry(opts) do
    cond do
      Keyword.has_key?(opts, :entry) ->
        Keyword.fetch!(opts, :entry)

      Keyword.get(opts, :missing) ->
        %{"error" => "entryNotFound"}

      true ->
        node = %{
          "LedgerEntryType" => "PayChannel",
          "Account" => @payer,
          "Destination" => Keyword.get(opts, :destination, @recipient),
          "Amount" => Keyword.get(opts, :amount, "1000000"),
          "Balance" => Keyword.get(opts, :balance, "0"),
          "PublicKey" => @fixture["payer"]["publicKey"],
          "SettleDelay" => 3600
        }

        node =
          case Keyword.get(opts, :expiration) do
            nil -> node
            expiration -> Map.put(node, "Expiration", expiration)
          end

        %{"node" => node}
    end
  end
end
