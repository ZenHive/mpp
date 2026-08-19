defmodule MPP.Session.ActionsTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Session
  alias MPP.Session.Actions
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Payload
  alias MPP.Session.Store
  alias MPP.Test.SessionSigning

  @channel_id "0x5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"
  @payer "0x1111111111111111111111111111111111111111"
  @recipient "0x2222222222222222222222222222222222222222"
  @token "0x3333333333333333333333333333333333333333"
  @transaction "0x76abcd"
  @signature "0x729359a3e060a6822af39785f1c806d820f6fb25bf94cb075038c60dc33fb37262db7e618685db686c2f870ead2e955ae0d907dde5739607d15ef1dafc65a31b1c"
  @signer "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @tip1034_channel_id "0x57e629663a75a0a49f8dc65c9f62ee38ab5dfa9124d7316d160766e4ecbc1227"
  @tip1034_escrow "0x4d50500000000000000000000000000000000000"
  @tip1034_signature "0x543a3c0d8484f2f0e2a6f190c87e07803cf96b9abdd6d15337455469c003861f40ef9cbf9411ef324692c1bfbc384efee9fd0476d1cd46743afcd6c82638b3b11b"
  @tip1034_amount 50

  setup do
    name = unique_store_name()
    start_supervised!(ETSStore.child_spec(name: name))
    {:ok, store: {ETSStore, [name: name]}, opts: base_opts({ETSStore, [name: name]})}
  end

  describe "action lifecycle" do
    test "open → voucher → topUp → close tracks channel balance", %{opts: opts, store: store} do
      assert {:ok, open_receipt} = Actions.dispatch(open_payload(100), opts)
      assert open_receipt.reference == @channel_id
      assert open_receipt.extensions["action"] == "open"
      assert open_receipt.extensions["acceptedCumulative"] == "100"
      assert open_receipt.extensions["spent"] == "10"
      assert open_receipt.extensions["units"] == 1

      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.status == :active
      assert channel.deposit == 1_000
      assert channel.cumulative_amount == 100
      assert channel.spent == 10
      assert Channel.available_balance(channel) == 90
      assert Channel.remaining_deposit(channel) == 900

      assert {:ok, voucher_receipt} = Actions.dispatch(voucher_payload(250), opts)
      assert voucher_receipt.extensions["action"] == "voucher"
      assert voucher_receipt.extensions["acceptedCumulative"] == "250"
      assert voucher_receipt.extensions["spent"] == "20"

      assert {:ok, top_up_receipt} = Actions.dispatch(top_up_payload(400), opts)
      assert top_up_receipt.extensions["action"] == "topUp"
      assert {:ok, topped} = Store.get(store, @channel_id)
      assert topped.deposit == 1_400
      assert topped.cumulative_amount == 250

      assert {:ok, close_receipt} = Actions.dispatch(close_payload(250), opts)
      assert close_receipt.extensions["action"] == "close"
      assert {:ok, closed} = Store.get(store, @channel_id)
      assert closed.status == :closed
      assert closed.cumulative_amount == 250
      assert closed.spent == 20
    end

    test "verify/2 reads store and identity from the session intent", %{store: store} do
      {:ok, session} =
        Session.new(
          amount: "10",
          currency: @token,
          recipient: @recipient,
          suggested_deposit: "1000",
          method_details: %{
            "session_store" => store,
            "payer" => @payer,
            "token" => @token,
            "method" => "mocksession",
            "escrowContract" => @tip1034_escrow,
            "chainId" => 42_431,
            "authorizedSigner" => @signer
          }
        )

      assert {:ok, receipt} = Actions.verify(open_payload(50), session)
      assert receipt.method == "mocksession"
      assert receipt.extensions["spent"] == "10"
    end
  end

  describe "open" do
    test "rejects a second open of the same channel", %{opts: opts} do
      assert {:ok, _receipt} = Actions.dispatch(open_payload(50), opts)

      assert {:error, %Errors{} = error} = Actions.dispatch(open_payload(60), opts)
      assert error.status == 402
      assert error.detail =~ "already exists"
    end

    test "rejects an open whose voucher exceeds the deposit", %{opts: opts} do
      assert {:error, %Errors{} = error} = Actions.dispatch(open_payload(2_000), opts)
      assert String.contains?(error.type, "amount-exceeds-deposit")
    end

    test "rejects an open that does not cover the request amount", %{opts: opts} do
      opts = Keyword.put(opts, :request_amount, 200)

      assert {:error, %Errors{} = error} = Actions.dispatch(open_payload(50), opts)
      assert String.contains?(error.type, "verification-failed")
      assert error.detail =~ "less than request amount"
    end
  end

  describe "voucher" do
    test "rejects a voucher against an unknown or closed channel", %{opts: opts} do
      assert {:error, %Errors{} = error} = Actions.dispatch(voucher_payload(50), opts)
      assert error.status == 410
      assert String.contains?(error.type, "channel-not-found")

      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      assert {:ok, _} = Actions.dispatch(close_payload(10), opts)

      assert {:error, %Errors{} = closed} = Actions.dispatch(voucher_payload(80), opts)
      assert closed.status == 410
      assert String.contains?(closed.type, "channel-finalized")
    end

    test "rejects a non-monotonic or too-small voucher delta", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), Keyword.put(opts, :min_voucher_delta, 20))

      assert {:error, %Errors{} = small} =
               Actions.dispatch(voucher_payload(55), Keyword.put(opts, :min_voucher_delta, 20))

      assert String.contains?(small.type, "delta-too-small")

      assert {:error, %Errors{} = rewind} = Actions.dispatch(voucher_payload(40), opts)
      assert String.contains?(rewind.type, "invalid-payload")
      assert rewind.detail =~ "monotonic"

      assert {:error, %Errors{} = over} = Actions.dispatch(voucher_payload(2_000), opts)
      assert String.contains?(over.type, "amount-exceeds-deposit")
    end

    test "treats an equal cumulative voucher as idempotent", %{opts: opts, store: store} do
      assert {:ok, first} = Actions.dispatch(open_payload(50), opts)
      assert {:ok, again} = Actions.dispatch(voucher_payload(50), opts)
      assert again.extensions["spent"] == first.extensions["spent"]
      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.units == 1
    end
  end

  describe "topUp" do
    test "rejects a top-up of a missing channel", %{opts: opts} do
      assert {:error, %Errors{} = error} = Actions.dispatch(top_up_payload(10), opts)
      assert String.contains?(error.type, "channel-not-found")
    end

    test "rejects a zero additional deposit", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(top_up_payload(0), opts)
      assert detail =~ "additional_deposit"
    end
  end

  describe "close" do
    test "rejects a close voucher below spent or above deposit", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)

      assert {:error, %Errors{} = below} = Actions.dispatch(close_payload(5), opts)
      assert String.contains?(below.type, "verification-failed")
      assert below.detail =~ "spent"

      assert {:error, %Errors{} = above} = Actions.dispatch(close_payload(2_000), opts)
      assert String.contains?(above.type, "amount-exceeds-deposit")
    end
  end

  describe "signature verification" do
    test "accepts the mpp-rs TIP-1034 voucher vector and rejects a tampered one", %{opts: opts} do
      signed_opts =
        opts
        |> Keyword.put(:deposit, @tip1034_amount)
        |> Keyword.put(:escrow_contract, @tip1034_escrow)
        |> Keyword.put(:chain_id, 42_431)
        |> Keyword.put(:authorized_signer, @signer)
        |> Keyword.put(:request_amount, 0)

      payload = tip1034_payload(:open, @tip1034_amount, @tip1034_signature)
      assert {:ok, _receipt} = Actions.dispatch(payload, signed_opts)

      tampered = tip1034_payload(:voucher, @tip1034_amount + 1, @tip1034_signature)
      assert {:error, %Errors{} = error} = Actions.dispatch(tampered, signed_opts)
      assert String.contains?(error.type, "invalid-signature")

      assert {:error, %Errors{} = malformed} =
               Actions.dispatch(tip1034_payload(:voucher, @tip1034_amount, "0x01"), signed_opts)

      assert String.contains?(malformed.type, "invalid-signature")

      fresh_channel = "0x" <> String.duplicate("cd", 32)

      open_with_payload_signer = %{
        "action" => "open",
        "type" => "transaction",
        "channelId" => fresh_channel,
        "transaction" => @transaction,
        "cumulativeAmount" => Integer.to_string(@tip1034_amount),
        "signature" => SessionSigning.sign_voucher(fresh_channel, @tip1034_amount, @tip1034_escrow, 42_431),
        "authorizedSigner" => @signer
      }

      assert {:ok, _} =
               Actions.dispatch(open_with_payload_signer, Keyword.delete(signed_opts, :authorized_signer))
    end

    test "fails closed when a signature is presented without a complete EIP-712 domain", %{opts: opts} do
      payload = Map.put(open_payload(100), "signature", @signature)

      for missing <- [:escrow_contract, :chain_id, :authorized_signer] do
        domain_opts =
          opts
          |> Keyword.put(:escrow_contract, @tip1034_escrow)
          |> Keyword.put(:chain_id, 42_431)
          |> Keyword.put(:authorized_signer, @signer)
          |> Keyword.delete(missing)

        assert {:error, %Errors{} = error} = Actions.dispatch(payload, domain_opts)
        assert String.contains?(error.type, "invalid-signature")
        assert error.detail =~ "must all be configured"
      end
    end
  end

  describe "payload errors" do
    test "maps an unknown action to invalid_payload" do
      assert {:error, %Errors{} = error} =
               Actions.dispatch(%{"action" => "bearer", "channelId" => @channel_id})

      assert String.contains?(error.type, "invalid-payload")
      assert error.detail =~ "action"

      assert {:error, %Errors{detail: detail}} = Actions.dispatch("open")
      assert detail =~ "payload"

      assert {:error, %Errors{detail: id_detail}} = Actions.dispatch(%{"action" => "open"})
      assert id_detail =~ "channelId"
    end

    test "maps remaining parse failures to invalid_payload" do
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(Map.put(open_payload(10), "descriptor", "x"))
      assert detail =~ "descriptor"

      assert {:error, %Errors{detail: hex_detail}} = Actions.dispatch(Map.put(open_payload(10), "transaction", "zz"))
      assert hex_detail =~ "transaction"

      assert {:error, %Errors{detail: amount_detail}} =
               Actions.dispatch(Map.put(open_payload(10), "cumulativeAmount", "1.0"))

      assert amount_detail =~ "cumulative_amount"

      assert {:error, %Errors{detail: route_detail}} =
               Actions.dispatch(Map.put(open_payload(10), "settlementRoute", "x"))

      assert route_detail =~ "settlementRoute"

      bad_descriptor = %{
        "payer" => "0xdead",
        "payee" => @recipient,
        "operator" => "0x0000000000000000000000000000000000000000",
        "token" => @token,
        "salt" => "0x0000000000000000000000000000000000000000000000000000000000000001",
        "authorizedSigner" => @signer,
        "expiringNonceHash" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }

      assert {:error, %Errors{detail: address_detail}} =
               Actions.dispatch(Map.put(open_payload(10), "descriptor", bad_descriptor))

      assert address_detail =~ "payer"

      assert {:error, %Errors{detail: type_detail}} =
               Actions.dispatch(Map.put(open_payload(10), "type", "hash"))

      assert type_detail =~ "transaction type"

      bad_hash = bad_descriptor |> Map.put("payer", @payer) |> Map.put("salt", "0x01")

      assert {:error, %Errors{detail: hash_detail}} =
               Actions.dispatch(Map.put(open_payload(10), "descriptor", bad_hash))

      assert hash_detail =~ "salt"
    end
  end

  describe "closed-channel and identity edges" do
    test "open/topUp/close reject a finalized channel", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      assert {:ok, _} = Actions.dispatch(close_payload(10), opts)

      assert {:error, %Errors{status: 410}} = Actions.dispatch(open_payload(60), opts)
      assert {:error, %Errors{status: 410}} = Actions.dispatch(top_up_payload(10), opts)
      assert {:error, %Errors{status: 410}} = Actions.dispatch(close_payload(20), opts)
    end

    test "close of a missing channel is 410 and close can raise the voucher ceiling", %{opts: opts} do
      assert {:error, %Errors{status: 410}} = Actions.dispatch(close_payload(10), opts)

      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      assert {:ok, receipt} = Actions.dispatch(close_payload(80), opts)
      assert receipt.extensions["acceptedCumulative"] == "80"
    end

    test "close of an unactivated channel is an invalid transition", %{opts: opts, store: store} do
      channel =
        Channel.new!(
          channel_id: @channel_id,
          payer: @payer,
          recipient: @recipient,
          token: @token,
          deposit: 1_000
        )

      assert :ok = Store.put(store, channel)
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(close_payload(0), Keyword.put(opts, :request_amount, 0))
      assert detail =~ "invalid channel transition"
    end

    test "handle/2 accepts a parsed open payload without a signature", %{opts: opts} do
      {:ok, parsed} = Payload.parse(open_payload(50))
      assert {:ok, receipt} = Actions.handle(%{parsed | signature: nil}, opts)
      assert receipt.extensions["action"] == "open"
    end

    test "open requires identity and can take it from a descriptor", %{opts: opts} do
      bare = Keyword.drop(opts, [:payer, :recipient, :token])
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(open_payload(50), bare)
      assert detail =~ "payer, recipient, and token"

      descriptor = %{
        "payer" => @payer,
        "payee" => @recipient,
        "operator" => "0x0000000000000000000000000000000000000000",
        "token" => @token,
        "salt" => "0x0000000000000000000000000000000000000000000000000000000000000001",
        "authorizedSigner" => @signer,
        "expiringNonceHash" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }

      assert {:ok, _} = Actions.dispatch(Map.put(open_payload(50), "descriptor", descriptor), bare)
    end

    test "open deposit must cover the request amount", %{opts: opts} do
      opts = Keyword.merge(opts, deposit: 50, request_amount: 80)
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(open_payload(50), opts)
      assert detail =~ "open deposit is less than request amount"
    end

    test "missing deposit is invalid_payload", %{opts: opts} do
      opts = Keyword.delete(opts, :deposit)
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(open_payload(50), opts)
      assert detail =~ "deposit required"
    end

    test "rejects a non-numeric deposit", %{opts: opts} do
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(open_payload(50), Keyword.put(opts, :deposit, :nope))
      assert detail =~ "deposit required"
    end

    test "rejects a voucher that leaves too little authorized balance to spend", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      opts = Keyword.put(opts, :request_amount, 80)
      assert {:error, %Errors{} = error} = Actions.dispatch(voucher_payload(60), opts)
      assert String.contains?(error.type, "insufficient-balance")
    end

    test "verify/2 honors suggested_deposit and extra method_details keys", %{store: store} do
      {:ok, session} =
        Session.new(
          amount: "bad",
          currency: @token,
          recipient: @recipient,
          suggested_deposit: "500",
          method_details: %{
            "session_store" => store,
            "payer" => @payer,
            "token" => @token,
            "minVoucherDelta" => "nope",
            "escrowContract" => @tip1034_escrow,
            "chainId" => 42_431,
            "authorizedSigner" => @signer
          }
        )

      assert {:ok, receipt} = Actions.verify(open_payload(50), session)
      assert receipt.extensions["acceptedCumulative"] == "50"
      assert {:ok, _} = Actions.verify(voucher_payload(80), session)
    end
  end

  defp open_payload(amount) do
    %{
      "action" => "open",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => @transaction,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => sign(@channel_id, amount)
    }
  end

  defp voucher_payload(amount) do
    %{
      "action" => "voucher",
      "channelId" => @channel_id,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => sign(@channel_id, amount)
    }
  end

  defp tip1034_payload(:open, amount, signature) do
    amount
    |> open_payload()
    |> Map.put("channelId", @tip1034_channel_id)
    |> Map.put("signature", signature)
  end

  defp tip1034_payload(:voucher, amount, signature) do
    amount
    |> voucher_payload()
    |> Map.put("channelId", @tip1034_channel_id)
    |> Map.put("signature", signature)
  end

  defp top_up_payload(amount) do
    %{
      "action" => "topUp",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => @transaction,
      "additionalDeposit" => Integer.to_string(amount)
    }
  end

  defp close_payload(amount) do
    %{
      "action" => "close",
      "channelId" => @channel_id,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => sign(@channel_id, amount)
    }
  end

  defp sign(channel_id, amount) do
    SessionSigning.sign_voucher(channel_id, amount, @tip1034_escrow, 42_431)
  end

  defp base_opts(store) do
    [
      store: store,
      deposit: 1_000,
      payer: @payer,
      recipient: @recipient,
      token: @token,
      request_amount: 10,
      method_name: "mocksession",
      escrow_contract: @tip1034_escrow,
      chain_id: 42_431,
      authorized_signer: @signer
    ]
  end

  defp unique_store_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end
end
