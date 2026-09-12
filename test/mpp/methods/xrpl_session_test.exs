defmodule MPP.Methods.XRPL.SessionTest do
  # RedeemLock is a node-global ETS table keyed by Destination. These tests share
  # fixture Destination addresses and some hold the lease across a gate, so
  # they cannot run in parallel with each other.
  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.Methods.XRPL.Codec
  alias MPP.Methods.XRPL.RedeemLock
  alias MPP.Methods.XRPL.RPC
  alias MPP.Methods.XRPL.Session, as: XRPLSession
  alias MPP.Methods.XRPL.Wallet
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Store

  defmodule DownStore do
    @moduledoc false
    def get(_id), do: {:error, :unavailable}
  end

  defmodule UpdateFailStore do
    @moduledoc false
    def get(id), do: Store.get(Process.get({__MODULE__, :backing}), id)
    def update(_id, _fun), do: {:error, :unavailable}
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
    refute Map.has_key?(XRPLSession.challenge_method_details(session), "destination_secret")

    assert_raise ArgumentError, ~r/rpc_url/, fn ->
      XRPLSession.validate_config!(%{"rpc_url" => "http://example.com", "network" => "testnet"})
    end

    assert_raise ArgumentError, ~r/rpc_url/, fn ->
      XRPLSession.validate_config!(%{
        "rpc_url" => "https://xrpl.test",
        "network" => "testnet"
      })
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
    assert channel.proof.amount == 100_000
    assert channel.proof.signature == @open_sig
    assert channel.proof.public_key == @fixture["payer"]["publicKey"]

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
    assert after_voucher.proof.amount == 200_000
    assert after_voucher.proof.signature == @voucher_sig
    highest = after_voucher.proof

    assert {:ok, closed} =
             XRPLSession.verify(
               %{"action" => "close", "channelId" => @channel_id, "amount" => "200000", "signature" => @voucher_sig},
               context.session
             )

    assert closed.extensions["action"] == "close"
    refute Map.has_key?(closed.extensions, "txHash")

    assert {:ok, %Channel{status: :closed, cumulative_amount: 200_000, proof: ^highest}} =
             Store.get(context.store, @channel_id)
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
    assert before.proof.amount == 100_000
    assert before.proof.signature == @open_sig

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/invalid-signature"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "50000", "signature" => @open_sig},
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

  test "a forged voucher against a live channel id costs one ledger_entry", context do
    stub(context, @hash)

    assert {:ok, _} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    flush_rpc()
    tampered = String.replace_prefix(@voucher_sig, "CC", "CD")

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/invalid-signature"}} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "200000", "signature" => tampered},
               context.session
             )

    assert rpc_calls() == ["ledger_entry"]
  end

  test "redeem/2 submits the retained PaymentChannelClaim", context do
    destination = @fixture["destination"]["ed25519"]
    claim = @fixture["claim"]["ed25519"]
    {:ok, wallet} = Wallet.from_seed(destination["seed"])

    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: wallet.address,
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 200_000,
        spent: 200_000,
        proof: %{
          amount: 200_000,
          signature: @voucher_sig,
          public_key: @fixture["payer"]["publicKey"]
        }
      )

    {:ok, channel} = Channel.activate(channel)
    {:ok, channel} = Channel.close(channel)
    assert :ok = Store.put(context.store, channel)

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => destination["seed"],
        "defer_redemption" => true
      })

    stub(%{context | session: session}, @hash)
    assert {:ok, hash} = XRPLSession.redeem(@channel_id, session.method_details)
    assert hash == claim["hash"]
    assert_received {:submitted, blob}
    assert String.upcase(blob) == claim["tx_blob"]
    assert {:ok, tx} = Codec.decode_claim(blob)
    assert tx["TransactionType"] == "PaymentChannelClaim"
    assert tx["Flags"] == 131_072
    assert tx["Channel"] == @channel_id
    assert tx["Balance"] == "200000"
    assert tx["Amount"] == "200000"
    assert tx["Signature"] == @voucher_sig
    assert tx["PublicKey"] == @fixture["payer"]["publicKey"]
    assert tx["Account"] == wallet.address
    assert tx["PublicKey"] != tx["SigningPubKey"]
  end

  test "close without deferral puts the claim txHash on the receipt", context do
    destination = @fixture["destination"]["ed25519"]

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => destination["seed"],
        "defer_redemption" => false,
        "credential_source" => "did:pkh:xrpl:1:" <> @payer
      })

    {:ok, session} = then(%{session | recipient: destination["address"]}, &{:ok, &1})

    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: destination["address"],
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 100_000,
        spent: 100_000,
        proof: %{
          amount: 100_000,
          signature: @open_sig,
          public_key: @fixture["payer"]["publicKey"]
        }
      )

    {:ok, channel} = Channel.activate(channel)
    assert :ok = Store.put(context.store, channel)

    stub(%{context | session: session}, @hash, destination: destination["address"])

    assert {:ok, closed} =
             XRPLSession.verify(
               %{"action" => "close", "channelId" => @channel_id, "amount" => "100000", "signature" => @open_sig},
               session
             )

    assert closed.extensions["action"] == "close"
    assert closed.extensions["txHash"]
    refute closed.extensions["txHash"] == @hash
  end

  test "signs PaymentChannelClaim blobs to the xrpl.js 4.6.0 goldens" do
    for {label, expected} <- @fixture["claim"] do
      wallet_fixture = @fixture["destination"][label]
      {:ok, wallet} = Wallet.from_seed(wallet_fixture["seed"])
      assert wallet.address == wallet_fixture["address"]
      assert wallet.public_key == wallet_fixture["publicKey"]

      tx = %{
        "TransactionType" => "PaymentChannelClaim",
        "Account" => wallet.address,
        "Channel" => @channel_id,
        "Amount" => "200000",
        "Balance" => "200000",
        "Signature" => @voucher_sig,
        "PublicKey" => @fixture["payer"]["publicKey"],
        "Flags" => 131_072,
        "Sequence" => 1,
        "LastLedgerSequence" => 100,
        "Fee" => "12"
      }

      # Goldens regenerated with test/support/xrpl/sign.cjs (xrpl.js 4.6.0) on
      # this exact map; NetworkID is omitted on networks with id <= 1024.
      assert {:ok, blob, hash} = Wallet.sign_claim(wallet, tx)
      assert hash == expected["hash"]
      assert blob == expected["tx_blob"]
      assert {:ok, decoded} = Codec.decode_claim(blob)
      assert {:ok, ^blob} = Codec.encode_claim(decoded)
    end

    assert :error = Wallet.from_seed("not-a-seed")
    assert {:error, :malformed_blob} = Codec.decode_claim(@blob)
    assert :error = Codec.encode_claim(%{})
  end

  test "the claim encoder fails closed on every malformed field" do
    base = %{
      "TransactionType" => "PaymentChannelClaim",
      "Account" => @fixture["destination"]["ed25519"]["address"],
      "Channel" => @channel_id,
      "Amount" => "200000",
      "Balance" => "200000",
      "Signature" => @voucher_sig,
      "PublicKey" => @fixture["payer"]["publicKey"],
      "Flags" => 131_072,
      "Sequence" => 1,
      "LastLedgerSequence" => 100,
      "Fee" => "12"
    }

    assert {:ok, _blob} = Codec.encode_claim(base)

    for {field, value} <- [
          {"Channel", "00"},
          {"Channel", "zz"},
          {"Amount", "-1"},
          {"Balance", 1.5},
          {"Account", "not-an-address"},
          {"Flags", "131072"},
          {"Signature", "ABC"},
          {"Fee", nil}
        ] do
      assert :error = Codec.encode_claim(Map.put(base, field, value)), "#{field}=#{inspect(value)} encoded"
    end

    # 0x-prefixed blob fields are accepted and normalise to the same bytes.
    assert Codec.encode_claim(Map.put(base, "Signature", "0x" <> @voucher_sig)) == Codec.encode_claim(base)

    # A family seed with a valid prefix but a broken checksum is rejected.
    seed = @fixture["destination"]["ed25519"]["seed"]
    assert :error = Wallet.from_seed(String.replace_suffix(seed, String.last(seed), "2"))
    assert :error = Wallet.from_seed(:not_a_binary)
    assert :error = Codec.claim_signing_data(%{})
  end

  test "redeem/2 fails when the store has no proof", context do
    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: @fixture["destination"]["ed25519"]["address"],
        token: "XRP",
        deposit: 1_000_000
      )

    {:ok, channel} = Channel.activate(channel)
    {:ok, channel} = Channel.close(channel)
    assert :ok = Store.put(context.store, channel)

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => @fixture["destination"]["ed25519"]["seed"]
      })

    assert {:error, %Errors{type: type}} = XRPLSession.redeem(@channel_id, session.method_details)
    assert type == Errors.new(:settlement_failed, "").type

    assert {:error, %Errors{type: "https://paymentauth.org/problems/malformed-credential"}} =
             XRPLSession.redeem("zz", session.method_details)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.redeem(1, %{})
  end

  test "redeem/2 accepts a PayChannel whose Balance advanced", context do
    destination = @fixture["destination"]["ed25519"]
    {:ok, wallet} = Wallet.from_seed(destination["seed"])

    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: wallet.address,
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 200_000,
        spent: 200_000,
        proof: %{
          amount: 200_000,
          signature: @voucher_sig,
          public_key: @fixture["payer"]["publicKey"]
        }
      )

    {:ok, channel} = Channel.activate(channel)
    {:ok, channel} = Channel.close(channel)
    assert :ok = Store.put(context.store, channel)

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => destination["seed"]
      })

    stub(%{context | session: session}, @hash, claim_advanced: true)
    assert {:ok, hash} = XRPLSession.redeem(@channel_id, session.method_details)
    assert hash == @fixture["claim"]["ed25519"]["hash"]
  end

  test "redeem/2 refuses a destination_secret that is not the channel recipient", context do
    destination = @fixture["destination"]["ed25519"]

    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: destination["address"],
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 200_000,
        spent: 200_000,
        proof: %{
          amount: 200_000,
          signature: @voucher_sig,
          public_key: @fixture["payer"]["publicKey"]
        }
      )

    {:ok, channel} = Channel.activate(channel)
    {:ok, channel} = Channel.close(channel)
    assert :ok = Store.put(context.store, channel)

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => @fixture["destination"]["secp256k1"]["seed"]
      })

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.redeem(@channel_id, session.method_details)
  end

  test "redeem/2 reports a rejected or unreadable submit", context do
    session = redeemable!(context)

    stub(%{context | session: session}, @hash,
      submit: %{"engine_result" => "tecNO_PERMISSION", "tx_json" => %{"hash" => @hash}}
    )

    assert {:error, %Errors{type: type, detail: detail}} = XRPLSession.redeem(@channel_id, session.method_details)
    assert type == Errors.new(:settlement_failed, "").type
    assert detail =~ "tecNO_PERMISSION"

    stub(%{context | session: session}, @hash, submit: %{"tx_json" => %{"hash" => @hash}})

    assert {:error, %Errors{type: ^type}} = XRPLSession.redeem(@channel_id, session.method_details)
  end

  test "redeem/2 fails closed on a missing channel, a broken store and a foreign seed", context do
    session = redeemable!(context)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/session/channel-not-found"}} =
             XRPLSession.redeem(@fixture["hashPaymentChannel"]["channelId"], session.method_details)

    down = Map.put(session.method_details, "session_store", DownStore)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.redeem(@channel_id, down)

    assert {:error, %Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPLSession.redeem(@channel_id, Map.put(session.method_details, "destination_secret", "not-a-seed"))
  end

  test "redeem/2 fails closed when the ledger cannot supply a sequence or a ledger index", context do
    session = redeemable!(context)
    settlement_failed = Errors.new(:settlement_failed, "").type

    for results <- [
          %{"account_info" => %{}},
          %{"ledger" => %{}},
          %{"ledger" => %{"ledger_index" => "not-a-number"}},
          %{"ledger" => %{"ledger_index" => -1}}
        ] do
      stub(%{context | session: session}, @hash, results: results)
      assert {:error, %Errors{type: ^settlement_failed}} = XRPLSession.redeem(@channel_id, session.method_details)
    end

    stub(%{context | session: session}, @hash, results: %{"ledger" => %{"ledger" => %{"ledger_index" => "120"}}})
    assert {:ok, _hash} = XRPLSession.redeem(@channel_id, session.method_details)
  end

  test "redeem/2 refuses a PayChannel whose Balance did not advance", context do
    session = redeemable!(context)

    stub(%{context | session: session}, @hash,
      claim_advanced: true,
      results: %{
        "ledger_entry" => %{
          "node" => %{"LedgerEntryType" => "PayChannel", "Balance" => "1", "Amount" => "1000000"}
        }
      }
    )

    assert {:error, %Errors{type: type}} = XRPLSession.redeem(@channel_id, session.method_details)
    assert type == Errors.new(:settlement_failed, "").type
  end

  test "close surfaces a settlement failure after the store already recorded the claim", context do
    destination = @fixture["destination"]["ed25519"]

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => destination["seed"],
        "defer_redemption" => false
      })

    session = %{session | recipient: destination["address"]}

    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: destination["address"],
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 100_000,
        spent: 100_000,
        proof: %{amount: 100_000, signature: @open_sig, public_key: @fixture["payer"]["publicKey"]}
      )

    {:ok, channel} = Channel.activate(channel)
    assert :ok = Store.put(context.store, channel)

    stub(%{context | session: session}, @hash,
      destination: destination["address"],
      submit: %{"engine_result" => "tefPAST_SEQ", "tx_json" => %{"hash" => @hash}}
    )

    assert {:error, %Errors{type: type, detail: detail}} =
             XRPLSession.verify(
               %{"action" => "close", "channelId" => @channel_id, "amount" => "100000", "signature" => @open_sig},
               session
             )

    assert type == Errors.new(:settlement_failed, "").type

    # draft §Error Responses: the raw ledger result code stays out of the client's problem detail.
    refute detail =~ "tefPAST_SEQ"

    # The claim survives the failed submit, so an operator can still redeem it.
    assert {:ok, %Channel{status: :closed, proof: %{amount: 100_000}}} = Store.get(context.store, @channel_id)
  end

  test "concurrent redeem/2 of two channels sharing a Destination uses distinct Sequences", context do
    destination = @fixture["destination"]["ed25519"]
    {:ok, wallet} = Wallet.from_seed(destination["seed"])
    {:ok, other_id} = Channel.compute_xrpl_id(@payer, wallet.address, 2)
    {:ok, other_wire} = Channel.to_xrpl_id(other_id)
    plug = unique_plug()

    {:ok, session} =
      isolated_session(context, plug, %{
        "destination_secret" => destination["seed"],
        "defer_redemption" => true
      })

    put_redeemable!(context, @channel_id, wallet.address)
    put_redeemable!(context, other_id, wallet.address)
    counters = stub_redeem(%{context | session: session}, destination: wallet.address, gate: true)
    parent = self()

    start = fn channel_id ->
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> XRPLSession.redeem(channel_id, session.method_details)
        end
      end)
    end

    task_a = start.(@channel_id)
    task_b = start.(other_id)
    assert_receive {:ready, pid_a}
    assert_receive {:ready, pid_b}
    send(pid_a, :go)
    assert_receive {:sequence_read, ^pid_a, 1}, 1_000
    :erlang.trace(pid_b, true, [:running])
    send(pid_b, :go)
    assert_receive {:trace, ^pid_b, :out, {RedeemLock, :wait_for_owner, 3}}, 1_000
    :erlang.trace(pid_b, false, [:running])
    refute_received {:sequence_read, ^pid_b, _}
    send(pid_a, :submit)
    assert_receive {:validation_waiting, ^pid_a}
    assert_receive {:sequence_read, ^pid_b, 2}
    send(pid_b, :submit)
    assert_receive {:validation_waiting, ^pid_b}
    send(pid_a, :validate)
    send(pid_b, :validate)

    results = Enum.map([task_a, task_b], &Task.await(&1, 5_000))

    hashes =
      Enum.map(results, fn
        {:ok, hash} -> hash
        other -> flunk("concurrent redeem failed: #{inspect(other)}")
      end)

    assert [_, _] = Enum.uniq(hashes)
    assert :atomics.get(counters.submits, 1) == 2

    blobs = submitted_blobs()
    assert [_, _] = blobs

    sequences =
      Enum.map(blobs, fn blob ->
        assert {:ok, tx} = Codec.decode_claim(blob)
        assert tx["Account"] == wallet.address
        assert tx["Channel"] in [@channel_id, other_wire]
        tx["Sequence"]
      end)

    assert Enum.sort(sequences) == [1, 2]
  end

  test "redeem/2 on an already-redeemed channel returns the recorded txHash without submitting", context do
    session = redeemable!(context)
    counters = stub_redeem(%{context | session: session})

    assert {:ok, hash} = XRPLSession.redeem(@channel_id, session.method_details)
    assert RPC.hex?(hash, 64)
    assert :atomics.get(counters.submits, 1) == 1
    assert {:ok, %Channel{proof: %{tx_hash: ^hash}}} = Store.get(context.store, @channel_id)

    flush_rpc()
    assert {:ok, ^hash} = XRPLSession.redeem(@channel_id, session.method_details)
    assert :atomics.get(counters.submits, 1) == 1
    refute_received {:submitted, _}
    assert rpc_calls() == []
  end

  test "tefPAST_SEQ on submit is retried once with a fresh Sequence", context do
    session = redeemable!(context)
    counters = stub_redeem(%{context | session: session}, past_seq_once: true)

    assert {:ok, hash} = XRPLSession.redeem(@channel_id, session.method_details)
    assert RPC.hex?(hash, 64)
    assert :atomics.get(counters.submits, 1) == 2

    blobs = submitted_blobs()
    assert [_, _] = blobs

    sequences =
      Enum.map(blobs, fn blob ->
        assert {:ok, tx} = Codec.decode_claim(blob)
        tx["Sequence"]
      end)

    assert sequences == [1, 2]
  end

  test "concurrent redeem/2 of one channel returns the recorded hash without a second submit", context do
    session = redeemable!(context)
    counters = stub_redeem(%{context | session: session})
    parent = self()

    start = fn ->
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> XRPLSession.redeem(@channel_id, session.method_details)
        end
      end)
    end

    task_a = start.()
    task_b = start.()
    assert_receive {:ready, pid_a}
    assert_receive {:ready, pid_b}
    send(pid_a, :go)
    send(pid_b, :go)

    hashes =
      Enum.map([task_a, task_b], fn task ->
        case Task.await(task, 5_000) do
          {:ok, hash} -> hash
          other -> flunk("same-channel redeem failed: #{inspect(other)}")
        end
      end)

    assert [_] = Enum.uniq(hashes)
    assert :atomics.get(counters.submits, 1) == 1
  end

  test "a tefPAST_SEQ retry that hits another engine result fails closed", context do
    session = redeemable!(context)
    stub_redeem(%{context | session: session}, submit_engines: ["tefPAST_SEQ", "tecNO_PERMISSION"])

    assert {:error, %Errors{type: type, detail: detail}} = XRPLSession.redeem(@channel_id, session.method_details)
    assert type == Errors.new(:settlement_failed, "").type
    assert detail =~ "tecNO_PERMISSION"
    blobs = submitted_blobs()
    assert [_, _] = blobs
  end

  test "a second tefPAST_SEQ is not retried", context do
    session = redeemable!(context)
    counters = stub_redeem(%{context | session: session}, submit_engines: ["tefPAST_SEQ", "tefPAST_SEQ"])

    assert {:error, %Errors{type: type, detail: detail}} = XRPLSession.redeem(@channel_id, session.method_details)
    assert type == Errors.new(:settlement_failed, "").type
    assert detail =~ "tefPAST_SEQ"
    assert :atomics.get(counters.submits, 1) == 2
    blobs = submitted_blobs()
    assert [_, _] = blobs
  end

  test "redeem/2 fails closed when the store cannot record the settled txHash", context do
    session = redeemable!(context)
    Process.put({UpdateFailStore, :backing}, context.store)
    details = Map.put(session.method_details, "session_store", UpdateFailStore)
    stub_redeem(%{context | session: %{session | method_details: details}})

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        assert {:error, %Errors{type: type}} = XRPLSession.redeem(@channel_id, details)
        assert type == Errors.new(:settlement_failed, "").type
      end)

    [blob] = submitted_blobs()
    assert log =~ "[error]"
    assert log =~ RPC.blob_hash(blob)
    assert {:ok, id} = Channel.normalize_id(@channel_id)
    assert log =~ id
    assert log =~ @fixture["destination"]["ed25519"]["address"]
  end

  test "redeem/2 logs the validated txHash when the ledger confirmation fails afterwards", context do
    session = redeemable!(context)
    stub_redeem(%{context | session: session}, ledger_entry_after_claim: %{"error" => "lgrNotFound"})

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        assert {:error, %Errors{type: type}} = XRPLSession.redeem(@channel_id, session.method_details)
        assert type == Errors.new(:settlement_failed, "").type
      end)

    [blob] = submitted_blobs()
    assert log =~ "[error]"
    assert log =~ "ledger confirmation"
    assert log =~ RPC.blob_hash(blob)
    assert {:ok, id} = Channel.normalize_id(@channel_id)
    assert log =~ id
    assert log =~ @fixture["destination"]["ed25519"]["address"]
    assert {:ok, %Channel{proof: proof}} = Store.get(context.store, @channel_id)
    refute Map.has_key?(proof, :tx_hash)
  end

  test "redeem/2 rejects a malformed redeem_lock_timeout_ms without submitting", context do
    session = redeemable!(context)
    counters = stub_redeem(%{context | session: session})

    for bad <- ["fast", -1, 1.5, nil] do
      details = Map.put(session.method_details, "redeem_lock_timeout_ms", bad)
      assert {:error, %Errors{type: type, detail: detail}} = XRPLSession.redeem(@channel_id, details)
      assert type == Errors.new(:verification_failed, "").type
      assert detail =~ "redeem_lock_timeout_ms"
    end

    assert :atomics.get(counters.submits, 1) == 0
  end

  test "queued claims wait for validation and fail closed when validation is unavailable", context do
    session = redeemable!(context)

    stub(%{context | session: session}, @hash,
      submit: %{"engine_result" => "terQUEUED", "tx_json" => %{"hash" => @fixture["claim"]["ed25519"]["hash"]}},
      lease_address: @fixture["destination"]["ed25519"]["address"],
      validated: false
    )

    assert {:error, %Errors{type: type}} = XRPLSession.redeem(@channel_id, session.method_details)
    assert type == Errors.new(:settlement_failed, "").type

    stub(%{context | session: session}, @hash,
      submit: %{"engine_result" => "terQUEUED", "tx_json" => %{"hash" => @fixture["claim"]["ed25519"]["hash"]}},
      lease_address: @fixture["destination"]["ed25519"]["address"],
      missing: true
    )

    assert {:ok, _} = XRPLSession.redeem(@channel_id, session.method_details)
  end

  test "active channels refuse redemption and keep accepting vouchers", context do
    stub(context, @hash)

    assert {:ok, _} =
             XRPLSession.verify(
               %{"action" => "open", "transaction" => @blob, "amount" => "100000", "signature" => @open_sig},
               context.session
             )

    counters = stub_redeem(context, destination: @recipient)
    assert {:error, %Errors{type: type, detail: detail}} = XRPLSession.redeem(@channel_id, context.session.method_details)
    assert type == Errors.new(:verification_failed, "").type
    assert detail =~ "channel_not_closed"
    assert :atomics.get(counters.submits, 1) == 0

    assert {:ok, _} =
             XRPLSession.verify(
               %{"action" => "voucher", "channelId" => @channel_id, "amount" => "200000", "signature" => @voucher_sig},
               context.session
             )

    assert {:ok, %Channel{status: :active, cumulative_amount: 200_000}} = Store.get(context.store, @channel_id)
    assert :atomics.get(counters.submits, 1) == 0
  end

  test "a stuck Destination lease times out and retains a redeemable claim", context do
    session = redeemable!(context)
    counters = stub_redeem(%{context | session: session})
    parent = self()

    holder =
      Task.async(fn ->
        RedeemLock.with_account(@fixture["destination"]["ed25519"]["address"], fn ->
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held
    config = Map.put(session.method_details, "redeem_lock_timeout_ms", 30)
    assert {:error, %Errors{type: type}} = XRPLSession.redeem(@channel_id, config)
    assert type == Errors.new(:settlement_failed, "").type
    assert :atomics.get(counters.submits, 1) == 0
    assert {:ok, %Channel{status: :closed, proof: %{amount: 200_000} = proof}} = Store.get(context.store, @channel_id)
    refute Map.has_key?(proof, :tx_hash)
    assert Process.alive?(holder.pid)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert {:ok, _} = XRPLSession.redeem(@channel_id, config)
    assert :atomics.get(counters.submits, 1) == 1
  end

  defp redeemable!(context) do
    destination = @fixture["destination"]["ed25519"]
    {:ok, wallet} = Wallet.from_seed(destination["seed"])

    {:ok, channel} =
      Channel.new(
        channel_id: @channel_id,
        payer: @payer,
        recipient: wallet.address,
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 200_000,
        spent: 200_000,
        proof: %{amount: 200_000, signature: @voucher_sig, public_key: @fixture["payer"]["publicKey"]}
      )

    {:ok, channel} = Channel.activate(channel)
    {:ok, channel} = Channel.close(channel)
    assert :ok = Store.put(context.store, channel)

    {:ok, session} =
      session(%{
        "session_store" => context.session.method_details["session_store"],
        "destination_secret" => destination["seed"]
      })

    session
  end

  defp put_redeemable!(context, channel_id, recipient) do
    {:ok, channel} =
      Channel.new(
        channel_id: channel_id,
        payer: @payer,
        recipient: recipient,
        token: "XRP",
        deposit: 1_000_000,
        cumulative_amount: 200_000,
        spent: 200_000,
        proof: %{amount: 200_000, signature: @voucher_sig, public_key: @fixture["payer"]["publicKey"]}
      )

    {:ok, channel} = Channel.activate(channel)
    {:ok, channel} = Channel.close(channel)
    assert :ok = Store.put(context.store, channel)
    channel
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
            "defer_redemption" => true,
            "poll_timeout_ms" => 2_000,
            "poll_interval_ms" => 10,
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

  defp stub_redeem(context, opts \\ []) do
    {_req, name} = context.session.method_details["req_options"][:plug]
    owner = context.owner
    sequence = :atomics.new(1, [])
    submits = :atomics.new(1, [])
    past = :atomics.new(1, [])
    claimed = :ets.new(:xrpl_redeem_claimed, [:public, :set])
    :atomics.put(sequence, 1, Keyword.get(opts, :sequence, 1))
    if Keyword.get(opts, :past_seq_once, false), do: :atomics.put(past, 1, 1)
    counters = %{sequence: sequence, submits: submits, claimed: claimed}

    Req.Test.stub(name, fn conn ->
      redeem_rpc_response(conn, owner, opts, counters, past)
    end)

    counters
  end

  defp redeem_rpc_response(conn, owner, opts, counters, past) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    decoded = Jason.decode!(body)
    method = decoded["method"]
    params = decoded |> Map.get("params", []) |> List.first() || %{}
    send(owner, {:rpc, method})
    Req.Test.json(conn, %{"result" => redeem_rpc_result(method, params, owner, opts, counters, past)})
  end

  defp redeem_rpc_result("server_info", _params, _owner, _opts, _counters, _past), do: %{"info" => %{"network_id" => 1}}

  defp redeem_rpc_result("account_info", params, owner, opts, counters, _past) do
    assert params["ledger_index"] == "current"
    sequence = :atomics.get(counters.sequence, 1)

    if Keyword.get(opts, :gate) do
      send(owner, {:sequence_read, self(), sequence})

      receive do
        :submit -> :ok
      end
    end

    %{"account_data" => %{"Sequence" => sequence}}
  end

  defp redeem_rpc_result("ledger", _params, _owner, _opts, _counters, _past) do
    %{"ledger_index" => 80, "ledger" => %{"close_time" => 1, "ledger_index" => 80}}
  end

  defp redeem_rpc_result("submit", params, owner, opts, counters, past) do
    blob = params["tx_blob"]
    n = :atomics.add_get(counters.submits, 1, 1)
    send(owner, {:submitted, blob})
    hash = RPC.blob_hash(blob)

    cond do
      engines = Keyword.get(opts, :submit_engines) ->
        engine = Enum.at(engines, n - 1) || List.last(engines)
        submit_engine_result(engine, hash, blob, counters)

      :atomics.compare_exchange(past, 1, 1, 0) == :ok ->
        :atomics.add(counters.sequence, 1, 1)
        %{"engine_result" => "tefPAST_SEQ", "tx_json" => %{"hash" => hash}}

      true ->
        mark_claimed(counters.claimed, blob)
        :atomics.add(counters.sequence, 1, 1)
        %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => hash}}
    end
  end

  defp redeem_rpc_result("tx", params, owner, opts, _counters, _past) do
    if Keyword.get(opts, :gate) do
      send(owner, {:validation_waiting, self()})

      receive do
        :validate -> :ok
      end
    end

    hash = params["transaction"]

    %{
      "validated" => true,
      "hash" => hash,
      "ledger_index" => 9,
      "meta" => %{
        "TransactionResult" => "tesSUCCESS",
        "AffectedNodes" => [%{"DeletedNode" => %{"LedgerEntryType" => "PayChannel", "LedgerIndex" => @channel_id}}]
      }
    }
  end

  defp redeem_rpc_result("ledger_entry", params, _owner, opts, counters, _past) do
    index = params["index"] |> to_string() |> String.upcase()

    case :ets.lookup(counters.claimed, index) do
      [{^index, true}] ->
        Keyword.get(opts, :ledger_entry_after_claim, %{"error" => "entryNotFound"})

      [] ->
        %{
          "node" => %{
            "LedgerEntryType" => "PayChannel",
            "Account" => @payer,
            "Destination" => Keyword.get(opts, :destination, @fixture["destination"]["ed25519"]["address"]),
            "Amount" => "1000000",
            "Balance" => "0",
            "PublicKey" => @fixture["payer"]["publicKey"],
            "SettleDelay" => 3600
          }
        }
    end
  end

  defp redeem_rpc_result(_method, _params, _owner, _opts, _counters, _past), do: %{}

  defp submit_engine_result("tesSUCCESS", hash, blob, counters) do
    mark_claimed(counters.claimed, blob)
    :atomics.add(counters.sequence, 1, 1)
    %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => hash}}
  end

  defp submit_engine_result("tefPAST_SEQ", hash, _blob, counters) do
    :atomics.add(counters.sequence, 1, 1)
    %{"engine_result" => "tefPAST_SEQ", "tx_json" => %{"hash" => hash}}
  end

  defp submit_engine_result(engine, hash, _blob, _counters) do
    %{"engine_result" => engine, "tx_json" => %{"hash" => hash}}
  end

  defp mark_claimed(table, blob) do
    case Codec.decode_claim(blob) do
      {:ok, %{"Channel" => channel}} when is_binary(channel) ->
        :ets.insert(table, {String.upcase(channel), true})

      _ ->
        :ok
    end
  end

  defp submitted_blobs(acc \\ []) do
    receive do
      {:submitted, blob} -> submitted_blobs(acc ++ [blob])
      {:rpc, _} -> submitted_blobs(acc)
    after
      0 -> acc
    end
  end

  defp stub(context, hash, opts \\ []) do
    {_req, name} = context.session.method_details["req_options"][:plug]
    owner = context.owner
    claimed = :atomics.new(1, [])
    Req.Test.stub(name, fn conn -> rpc_response(conn, owner, hash, opts, claimed) end)
  end

  defp rpc_response(conn, owner, hash, opts, claimed) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    decoded = Jason.decode!(body)
    method = decoded["method"]
    params = decoded |> Map.get("params", []) |> List.first() || %{}
    send(owner, {:rpc, method})
    Req.Test.json(conn, %{"result" => rpc_override(method, hash, opts, params, claimed, owner)})
  end

  defp rpc_override(method, hash, opts, params, claimed, owner) do
    case opts |> Keyword.get(:results, %{}) |> Map.fetch(method) do
      {:ok, override} -> override
      :error -> rpc_result(method, hash, opts, params, claimed, owner)
    end
  end

  defp rpc_result("server_info", _hash, opts, _params, _claimed, _owner),
    do: %{"info" => %{"network_id" => Keyword.get(opts, :network_id, 1)}}

  defp rpc_result("submit", hash, opts, params, claimed, owner), do: submit_result(hash, opts, params, claimed, owner)

  defp rpc_result("tx", hash, opts, params, _claimed, _owner) do
    if address = opts[:lease_address] do
      assert {:error, %Errors{}} =
               RedeemLock.with_account(address, fn -> flunk("queued lease released before validation") end, 0)
    end

    queried = params["transaction"] || hash
    tx_rpc(queried, hash, opts)
  end

  defp rpc_result("ledger_entry", _hash, opts, _params, claimed, _owner), do: ledger_entry(opts, claimed)

  defp rpc_result("ledger", _hash, opts, _params, _claimed, _owner) do
    index = Keyword.get(opts, :ledger_index, 80)
    %{"ledger_index" => index, "ledger" => %{"close_time" => Keyword.get(opts, :close_time, 1), "ledger_index" => index}}
  end

  defp rpc_result("account_info", _hash, opts, _params, _claimed, _owner) do
    %{"account_data" => %{"Sequence" => Keyword.get(opts, :sequence, 1)}}
  end

  defp submit_result(hash, opts, params, claimed, owner) do
    blob = params["tx_blob"]

    cond do
      Keyword.has_key?(opts, :submit) ->
        Keyword.fetch!(opts, :submit)

      is_binary(blob) ->
        expected = RPC.blob_hash(blob)
        if expected != hash, do: :atomics.put(claimed, 1, 1)
        send(owner, {:submitted, blob})
        %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => expected}}

      true ->
        %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => hash}}
    end
  end

  defp tx_rpc(queried, create_hash, opts) do
    if Keyword.get(opts, :validated, true) do
      tx_result(queried, create_hash, opts)
    else
      %{"validated" => false, "hash" => queried}
    end
  end

  defp tx_result(queried, create_hash, opts) do
    if is_binary(queried) and String.upcase(queried) == String.upcase(create_hash) do
      %{
        "validated" => true,
        "hash" => create_hash,
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
    else
      claim_tx_result(queried, opts)
    end
  end

  defp claim_tx_result(hash, opts) do
    node =
      if Keyword.get(opts, :claim_advanced) do
        %{
          "ModifiedNode" => %{
            "LedgerEntryType" => "PayChannel",
            "LedgerIndex" => @channel_id,
            "FinalFields" => %{"Balance" => "200000"}
          }
        }
      else
        %{
          "DeletedNode" => %{
            "LedgerEntryType" => "PayChannel",
            "LedgerIndex" => @channel_id
          }
        }
      end

    %{
      "validated" => true,
      "hash" => hash,
      "ledger_index" => 9,
      "meta" => %{"TransactionResult" => "tesSUCCESS", "AffectedNodes" => [node]}
    }
  end

  defp ledger_entry(opts, claimed) do
    cond do
      Keyword.has_key?(opts, :entry) ->
        Keyword.fetch!(opts, :entry)

      Keyword.get(opts, :missing) ->
        %{"error" => "entryNotFound"}

      :atomics.get(claimed, 1) == 1 and Keyword.get(opts, :claim_advanced) ->
        %{
          "node" => %{
            "LedgerEntryType" => "PayChannel",
            "Account" => @payer,
            "Destination" => Keyword.get(opts, :destination, @recipient),
            "Amount" => Keyword.get(opts, :amount, "1000000"),
            "Balance" => "200000",
            "PublicKey" => @fixture["payer"]["publicKey"],
            "SettleDelay" => 3600
          }
        }

      :atomics.get(claimed, 1) == 1 ->
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

  defp flush_rpc do
    receive do
      {:rpc, _} -> flush_rpc()
      {:submitted, _} -> flush_rpc()
    after
      0 -> :ok
    end
  end

  defp rpc_calls(acc \\ []) do
    receive do
      {:rpc, method} -> rpc_calls(acc ++ [method])
      {:submitted, _} -> rpc_calls(acc)
    after
      0 -> acc
    end
  end
end
