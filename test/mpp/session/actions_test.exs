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
  @zero_address "0x0000000000000000000000000000000000000000"

  defmodule FailingStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_channel_id), do: {:error, :unavailable}
    @impl true
    def put(_channel), do: {:error, :unavailable}
    @impl true
    def update(_channel_id, _fun), do: {:error, :unavailable}
    @impl true
    def delete(_channel_id), do: {:error, :unavailable}
  end

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
      assert is_nil(channel.proof)
      assert Channel.available_balance(channel) == 90
      assert Channel.remaining_deposit(channel) == 900

      assert {:ok, voucher_receipt} = Actions.dispatch(voucher_payload(250), opts)
      assert voucher_receipt.extensions["action"] == "voucher"
      assert voucher_receipt.extensions["acceptedCumulative"] == "250"
      assert voucher_receipt.extensions["spent"] == "20"

      top_up_opts = Keyword.put(opts, :verify_top_up, fn _payload, _channel, _opts -> {:ok, 1_400} end)
      assert {:ok, top_up_receipt} = Actions.dispatch(top_up_payload(400), top_up_opts)
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

    test "verify/2 honors the server-only request amount override", %{store: store} do
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
            "authorizedSigner" => @signer,
            "request_amount" => 0
          }
        )

      assert {:ok, receipt} = Actions.verify(open_payload(50), session)
      assert receipt.extensions["spent"] == "0"
      assert receipt.extensions["units"] == 0
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

    test "rejects an equal cumulative voucher even with a zero minimum delta", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      assert {:ok, before} = Store.get(store, @channel_id)

      for minimum <- [0, "0", 1, 20] do
        assert {:error, %Errors{} = error} =
                 Actions.dispatch(voucher_payload(50), Keyword.put(opts, :min_voucher_delta, minimum))

        assert error.type == "https://paymentauth.org/problems/session/delta-too-small"
        assert error.status == 402
        assert {:ok, ^before} = Store.get(store, @channel_id)
      end
    end

    test "concurrent identical vouchers have exactly one winner", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(100), opts)
      opts = Keyword.put(opts, :min_voucher_delta, 0)
      payload = voucher_payload(200)

      results = concurrent_vouchers([payload, payload], opts, store)
      assert [{:ok, receipt}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, %Errors{} = error}] = Enum.filter(results, &match?({:error, _}, &1))
      assert error.type == "https://paymentauth.org/problems/session/delta-too-small"
      assert receipt.extensions["spent"] == "20"
      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.cumulative_amount == 200
      assert channel.spent == 20
      assert channel.units == 2
      assert channel.deposit == 1_000
    end

    test "concurrent increasing vouchers check the minimum delta atomically", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(100), opts)
      opts = Keyword.put(opts, :min_voucher_delta, 100)

      assert [{:ok, receipt}, {:error, %Errors{} = error}] =
               concurrent_vouchers([voucher_payload(200), voucher_payload(250)], opts, store)

      assert error.type == "https://paymentauth.org/problems/session/delta-too-small"
      assert receipt.extensions["acceptedCumulative"] == "200"
      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.cumulative_amount == 200
      assert channel.spent == 20
      assert channel.units == 2
      assert channel.deposit == 1_000
    end
  end

  describe "topUp" do
    test "rejects a top-up of a missing channel", %{opts: opts} do
      assert {:error, %Errors{} = error} = Actions.dispatch(top_up_payload(10), opts)
      assert String.contains?(error.type, "channel-not-found")
    end

    test "rejects a zero additional deposit", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      opts = Keyword.put(opts, :verify_top_up, fn _payload, _channel, _opts -> flunk("verifier called") end)
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(top_up_payload(0), opts)
      assert detail =~ "additional_deposit"
    end

    test "fails closed without a funding verifier and leaves the deposit unchanged", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)

      assert {:error, %Errors{} = error} = Actions.dispatch(top_up_payload(1_000_000), opts)
      assert String.contains?(error.type, "verification-failed")
      assert error.detail =~ "verify_top_up"

      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.deposit == 1_000
    end

    test "sets the deposit to the verified total, not the claimed increment", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      test_pid = self()

      verifier = fn payload, channel, _opts ->
        send(test_pid, {:verified, payload.additional_deposit, channel.deposit})
        {:ok, 1_200}
      end

      assert {:ok, _} = Actions.dispatch(top_up_payload(1_000_000), Keyword.put(opts, :verify_top_up, verifier))
      assert_received {:verified, 1_000_000, 1_000}

      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.deposit == 1_200
    end

    test "rejects a verified deposit that did not increase", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      opts = Keyword.put(opts, :verify_top_up, fn _payload, _channel, _opts -> {:ok, 1_000} end)

      assert {:error, %Errors{detail: detail}} = Actions.dispatch(top_up_payload(400), opts)
      assert detail =~ "did not increase"
      assert {:ok, %Channel{deposit: 1_000}} = Store.get(store, @channel_id)
    end

    test "propagates verifier errors and rejects malformed verifier results", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      reverted = Errors.new(:verification_failed, "topUp transaction reverted")

      assert {:error, ^reverted} =
               Actions.dispatch(
                 top_up_payload(400),
                 Keyword.put(opts, :verify_top_up, fn _payload, _channel, _opts -> {:error, reverted} end)
               )

      for result <- [:ok, {:ok, "1400"}, {:ok, -1}, {:error, :rpc_down}] do
        assert {:error, %Errors{detail: detail}} =
                 Actions.dispatch(
                   top_up_payload(400),
                   Keyword.put(opts, :verify_top_up, fn _payload, _channel, _opts -> result end)
                 )

        assert detail =~ "funding verification failed"
      end

      assert {:ok, %Channel{deposit: 1_000}} = Store.get(store, @channel_id)
    end

    test "re-checks channel state after verification", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)

      closing = fn _payload, channel, _opts ->
        {:ok, _} = Store.update(store, channel.channel_id, fn %Channel{} = current -> Channel.close(current) end)
        {:ok, 2_000}
      end

      assert {:error, %Errors{status: 410}} =
               Actions.dispatch(top_up_payload(400), Keyword.put(opts, :verify_top_up, closing))

      assert :ok = Store.delete(store, @channel_id)
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)

      deleting = fn _payload, channel, _opts ->
        :ok = Store.delete(store, channel.channel_id)
        {:ok, 2_000}
      end

      assert {:error, %Errors{} = error} =
               Actions.dispatch(top_up_payload(400), Keyword.put(opts, :verify_top_up, deleting))

      assert String.contains?(error.type, "channel-not-found")
    end

    test "surfaces a store read failure before verification", %{opts: opts} do
      opts =
        opts
        |> Keyword.put(:store, __MODULE__.FailingStore)
        |> Keyword.put(:verify_top_up, fn _payload, _channel, _opts -> flunk("verifier called") end)

      assert {:error, %Errors{detail: detail}} = Actions.dispatch(top_up_payload(400), opts)
      assert detail =~ "session store update failed"
    end

    test "verify/2 reads the funding verifier from server-only method details", %{store: store} do
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
            "escrowContract" => @tip1034_escrow,
            "chainId" => 42_431,
            "authorizedSigner" => @signer,
            "verify_top_up" => fn _payload, _channel, _opts -> {:ok, 1_500} end
          }
        )

      assert {:ok, _} = Actions.verify(open_payload(50), session)
      assert {:ok, _} = Actions.verify(top_up_payload(500), session)
      assert {:ok, %Channel{deposit: 1_500}} = Store.get(store, @channel_id)
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
    test "skips EIP-712 when the caller already verified the signature", %{opts: opts} do
      payload = 50 |> open_payload() |> Map.put("signature", "0x" <> String.duplicate("ab", 65))
      assert {:ok, receipt} = Actions.dispatch(payload, Keyword.put(opts, :verify_signature, :already_verified))
      assert receipt.extensions["action"] == "open"
    end

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

      # A top-level authorizedSigner never selects the verification key.
      assert {:error, %Errors{} = mismatch} =
               Actions.dispatch(open_with_payload_signer, Keyword.delete(signed_opts, :authorized_signer))

      assert String.contains?(mismatch.type, "signer-mismatch")
    end

    test "fails closed when a signature is presented without a complete EIP-712 domain", %{opts: opts} do
      payload = Map.put(open_payload(100), "signature", @signature)

      for missing <- [:escrow_contract, :chain_id] do
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

  describe "channel signer binding" do
    test "the other test key verifies when the server authorizes it", %{opts: opts} do
      opts = Keyword.put(opts, :authorized_signer, SessionSigning.other_signer_address())
      payload = Map.put(open_payload(50), "signature", other_voucher("open", @channel_id, 50)["signature"])
      assert {:ok, _} = Actions.dispatch(payload, opts)
    end

    test "open rejects a credential-named signer that differs from the channel signer", %{opts: opts} do
      payload =
        50
        |> open_payload()
        |> Map.put("signature", other_voucher("open", @channel_id, 50)["signature"])
        |> Map.put("authorizedSigner", SessionSigning.other_signer_address())

      assert {:error, %Errors{} = error} = Actions.dispatch(payload, opts)
      assert String.contains?(error.type, "signer-mismatch")
    end

    test "voucher and close verify against the signer stored at open, not server config", %{opts: opts, store: store} do
      {channel_id, descriptor} = bound_descriptor(@signer)
      assert {:ok, _} = Actions.dispatch(descriptor_open(channel_id, descriptor, 50), opts)

      # A later server config naming another key does not re-key an open channel.
      rekeyed = Keyword.put(opts, :authorized_signer, SessionSigning.other_signer_address())
      assert {:error, %Errors{} = error} = Actions.dispatch(other_voucher("voucher", channel_id, 80), rekeyed)
      assert String.contains?(error.type, "invalid-signature")

      voucher = %{"action" => "voucher", "channelId" => channel_id, "cumulativeAmount" => "80"}
      assert {:ok, _} = Actions.dispatch(Map.put(voucher, "signature", sign(channel_id, 80)), rekeyed)

      assert {:error, %Errors{}} = Actions.dispatch(other_voucher("close", channel_id, 80), rekeyed)
      assert {:ok, channel} = Store.get(store, channel_id)
      assert channel.status == :active
    end

    test "voucher and close reject a descriptor naming a different signer", %{opts: opts, store: store} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      {_other_id, other_descriptor} = bound_descriptor(SessionSigning.other_signer_address())

      for action <- ["voucher", "close"] do
        payload = Map.put(other_voucher(action, @channel_id, 80), "descriptor", other_descriptor)
        assert {:error, %Errors{} = error} = Actions.dispatch(payload, opts)
        assert error.detail =~ "descriptor does not match channelId"
      end

      {channel_id, descriptor} = bound_descriptor(@signer, %{"salt" => "0x" <> String.duplicate("02", 32)})
      assert {:ok, _} = Actions.dispatch(descriptor_open(channel_id, descriptor, 50), opts)

      # Same channel-bound descriptor shape, but claiming a zero signer (payer) instead.
      assert {:error, %Errors{}} =
               Actions.dispatch(
                 Map.put(other_voucher("voucher", channel_id, 80), "descriptor", %{
                   descriptor
                   | "authorizedSigner" => @zero_address
                 }),
                 opts
               )

      assert {:ok, channel} = Store.get(store, channel_id)
      assert channel.cumulative_amount == 50
    end

    test "a voucher carrying the channel's own descriptor still verifies", %{opts: opts} do
      {channel_id, descriptor} = bound_descriptor(@signer)
      assert {:ok, _} = Actions.dispatch(descriptor_open(channel_id, descriptor, 50), opts)

      voucher = %{
        "action" => "voucher",
        "channelId" => channel_id,
        "cumulativeAmount" => "80",
        "signature" => sign(channel_id, 80),
        "descriptor" => descriptor
      }

      assert {:ok, _} = Actions.dispatch(voucher, opts)
    end

    test "open rejects a descriptor that does not hash to the channelId", %{opts: opts} do
      {_channel_id, descriptor} = bound_descriptor(SessionSigning.other_signer_address())
      payload = Map.put(other_voucher("open", @channel_id, 50), "descriptor", descriptor)
      payload = Map.merge(open_payload(50), payload)

      assert {:error, %Errors{} = error} = Actions.dispatch(payload, opts)
      assert error.detail =~ "descriptor does not match channelId"
    end

    test "open rejects a descriptor whose payee or token differs from server config", %{opts: opts} do
      for {key, value} <- [{"payee", @payer}, {"token", @payer}] do
        {channel_id, descriptor} = bound_descriptor(@signer, %{key => value})
        assert {:error, %Errors{} = error} = Actions.dispatch(descriptor_open(channel_id, descriptor, 50), opts)
        assert error.detail =~ "does not match server configuration"
      end
    end

    test "open rejects a descriptor when the escrow domain is not configured", %{opts: opts} do
      {channel_id, descriptor} = bound_descriptor(@signer)

      for missing <- [:escrow_contract, :chain_id] do
        payload = descriptor_open(channel_id, descriptor, 50)
        assert {:error, %Errors{} = error} = Actions.dispatch(payload, Keyword.delete(opts, missing))
        assert error.detail =~ "escrow_contract and chain_id must be configured"
      end
    end

    test "a zero descriptor signer delegates signing to the payer", %{opts: opts, store: store} do
      payer = SessionSigning.signer_address()
      opts = Keyword.drop(opts, [:payer, :authorized_signer])
      {channel_id, descriptor} = bound_descriptor(@zero_address, %{"payer" => payer})

      assert {:ok, _} = Actions.dispatch(descriptor_open(channel_id, descriptor, 50), opts)
      assert {:ok, channel} = Store.get(store, channel_id)
      assert channel.authorized_signer == payer
    end

    test "custom verifiers receive the channel's signer", %{opts: opts} do
      assert {:ok, _} = Actions.dispatch(open_payload(50), opts)
      test_pid = self()

      verify = fn _payload, verify_opts ->
        send(test_pid, {:signer, Keyword.fetch!(verify_opts, :authorized_signer)})
        :ok
      end

      opts =
        opts
        |> Keyword.put(:authorized_signer, SessionSigning.other_signer_address())
        |> Keyword.put(:verify_signature, verify)

      assert {:ok, _} = Actions.dispatch(voucher_payload(80), opts)
      assert_received {:signer, signer}
      assert signer == String.downcase(@signer)
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

    test "open requires identity and can take it from a channel-bound descriptor", %{opts: opts, store: store} do
      bare = Keyword.drop(opts, [:payer, :recipient, :token, :authorized_signer])
      assert {:error, %Errors{detail: detail}} = Actions.dispatch(open_payload(50), bare)
      assert detail =~ "payer, recipient, and token"

      {channel_id, descriptor} = bound_descriptor(@signer)
      assert {:ok, _} = Actions.dispatch(descriptor_open(channel_id, descriptor, 50), bare)
      assert {:ok, channel} = Store.get(store, channel_id)
      assert channel.payer == @payer
      assert channel.recipient == @recipient
      assert channel.authorized_signer == String.downcase(@signer)
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

  defp concurrent_vouchers(payloads, opts, {ETSStore, store_opts}) do
    server = Process.whereis(Keyword.fetch!(store_opts, :name))
    :ok = :sys.suspend(server)

    # Queue both updates before the real store processes either, in payload order.
    tasks =
      try do
        Enum.map(payloads, fn payload ->
          task =
            Task.async(fn ->
              receive do
                :present -> Actions.dispatch(payload, opts)
              end
            end)

          pid = task.pid
          :erlang.trace(pid, true, [:send])
          send(pid, :present)

          assert_receive {:trace, ^pid, :send, {:"$gen_call", _, {:update, @channel_id, @channel_id, _}}, ^server},
                         1_000

          :erlang.trace(pid, false, [:send])
          task
        end)
      after
        :ok = :sys.resume(server)
      end

    Enum.map(tasks, &Task.await/1)
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

  defp bound_descriptor(signer, overrides \\ %{}) do
    descriptor =
      Map.merge(
        %{
          "payer" => @payer,
          "payee" => @recipient,
          "operator" => @zero_address,
          "token" => @token,
          "salt" => "0x0000000000000000000000000000000000000000000000000000000000000001",
          "authorizedSigner" => signer,
          "expiringNonceHash" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        overrides
      )

    channel_id =
      Channel.compute_id!(
        payer: descriptor["payer"],
        payee: descriptor["payee"],
        operator: descriptor["operator"],
        token: descriptor["token"],
        salt: descriptor["salt"],
        authorized_signer: descriptor["authorizedSigner"],
        expiring_nonce_hash: descriptor["expiringNonceHash"],
        escrow_contract: @tip1034_escrow,
        chain_id: 42_431
      )

    {channel_id, descriptor}
  end

  defp descriptor_open(channel_id, descriptor, amount) do
    %{
      "action" => "open",
      "type" => "transaction",
      "channelId" => channel_id,
      "transaction" => @transaction,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => sign(channel_id, amount),
      "descriptor" => descriptor
    }
  end

  defp other_voucher(action, channel_id, amount) do
    %{
      "action" => action,
      "channelId" => channel_id,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => SessionSigning.sign_voucher_as_other(channel_id, amount, @tip1034_escrow, 42_431)
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
