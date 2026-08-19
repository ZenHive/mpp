defmodule MPP.Methods.NearIntentsTest do
  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.NearIntents
  alias MPP.Methods.NearIntents.Origin
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore

  @one_click_url "https://1click.example"
  @origin_rpc_url "https://origin-rpc.example"
  @origin_network "eip155:1"
  @origin_token "0xdac17f958d2ee523a2206206994597c13d831ec7"
  @origin_asset @origin_network <> "/erc20:" <> @origin_token
  @destination_network "tron:mainnet"
  @destination_asset @destination_network <> "/trc20:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @destination_recipient "TJ4FU4NFMqFDtcLYxFnJvfv3rWfLN9vCB7"
  @deposit_address "0x990F6413D7c397A66988adDaAc429eB8e7A6B5CC"
  @refund_to "0x2cBEaF069aF231E1FAAB15D0aFEFD6aeaf06448A"
  @origin_hash "0xdeb759ce1f8186ea526910797debbf1bdb7271f887c1e17550af3631c31ae015"
  @destination_hash "00efc9710dc8b821fae6e7873cce8ab9f01637084714475bff40a3eded48adfd"
  @amount_in "24499630000"
  @amount_out "24452693201"
  @quote_deadline "2099-08-22T05:09:48.000Z"
  @settled_at "2026-08-19T04:36:16.000Z"
  @sender "0x2cbeaf069af231e1faab15d0afefd6aeaf06448a"
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @amount_hex "0x" <> String.pad_leading(Integer.to_string(24_499_630_000, 16), 64, "0")
  @cache_name :near_intents_test_cache

  setup do
    {:ok, charge} =
      Charge.new(
        amount: @amount_in,
        currency: @origin_asset,
        recipient: @deposit_address,
        external_id: "order-79"
      )

    {:ok, charge: %{charge | method_details: method_config()}}
  end

  describe "method contract" do
    test "advertises the nearintents hash-only method", %{charge: charge} do
      assert NearIntents.method_name() == "nearintents"
      assert NearIntents.credential_types() == ["hash"]

      assert %{
               "originNetwork" => @origin_network,
               "destinationNetwork" => @destination_network,
               "destinationAsset" => @destination_asset,
               "destinationRecipient" => @destination_recipient,
               "amountOut" => @amount_out,
               "minAmountIn" => @amount_in,
               "refundTo" => @refund_to,
               "settlementBackend" => "near-intents",
               "credentialTypes" => ["hash"]
             } = NearIntents.challenge_method_details(charge)

      details = NearIntents.challenge_method_details(charge)
      refute Map.has_key?(details, "one_click_jwt")
      refute Map.has_key?(details, "origin_rpc_url")
      refute Map.has_key?(details, "store")
      refute Map.has_key?(details, "depositMemo")

      charge =
        update_in(charge.method_details, fn config ->
          Map.merge(config, %{
            "slippage_tolerance" => 75,
            "time_estimate" => 120,
            "deposit_memo" => "memo-79"
          })
        end)

      assert %{"slippageTolerance" => 75, "timeEstimate" => 120, "depositMemo" => "memo-79"} =
               NearIntents.challenge_method_details(charge)
    end

    test "validates required configuration and atomic stores" do
      assert :ok = NearIntents.validate_config!(method_config())
      assert :ok = method_config() |> Map.delete("store") |> NearIntents.validate_config!()
      assert :ok = NearIntents.validate_config!(method_config(%{"store" => false}))
      assert :ok = NearIntents.validate_config!(method_config(%{"store" => ConCacheStore}))
      assert :ok = NearIntents.validate_config!(method_config(%{"store" => {ConCacheStore, ttl: 600}}))

      assert_raise ArgumentError, ~r/refund_to/, fn ->
        method_config() |> Map.delete("refund_to") |> NearIntents.validate_config!()
      end

      assert_raise ArgumentError, ~r/non-negative integer string/, fn ->
        NearIntents.validate_config!(method_config(%{"min_amount_in" => "1.5"}))
      end

      assert_raise ArgumentError, ~r/RFC 3339/, fn ->
        NearIntents.validate_config!(method_config(%{"quote_deadline" => "tomorrow"}))
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        NearIntents.validate_config!(method_config(%{"store" => {ConCacheStore, [1, 2]}}))
      end

      assert_raise ArgumentError, ~r/atomic/, fn ->
        NearIntents.validate_config!(method_config(%{"store" => Enum}))
      end
    end
  end

  describe "quote/1" do
    test "requests the live-observed EXACT_OUTPUT shape and returns Plug options" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v0/quote"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer partner-token"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "amount" => "1000000",
                 "deadline" => @quote_deadline,
                 "depositType" => "ORIGIN_CHAIN",
                 "destinationAsset" => "nep141:tron-usdt.omft.near",
                 "dry" => false,
                 "originAsset" => "nep141:eth-usdt.omft.near",
                 "recipient" => @destination_recipient,
                 "recipientType" => "DESTINATION_CHAIN",
                 "referral" => "mpp-live-observation",
                 "refundTo" => @refund_to,
                 "refundType" => "ORIGIN_CHAIN",
                 "slippageTolerance" => 100,
                 "swapType" => "EXACT_OUTPUT"
               }

        Req.Test.json(conn, observed_quote_response())
      end)

      assert {:ok, quote} = NearIntents.quote(quote_parameters())
      assert quote.amount == "1929010"
      assert quote.currency == @origin_asset
      assert quote.recipient == "0x8446675C0D5f55CbeF9Bc92B8B5AfCC3E57C3c55"
      assert quote.expires_at == @quote_deadline
      assert quote.method_config["min_amount_in"] == "1909719"
      assert quote.method_config["amount_out"] == "1000000"
      assert quote.method_config["one_click_jwt"] == "partner-token"
      assert quote.method_config["origin_network"] == @origin_network
      assert quote.method_config["destination_network"] == @destination_network
    end

    test "rejects missing and malformed parameters before calling 1Click" do
      assert {:error, {:missing_quote_parameters, ["refund_to"]}} =
               quote_parameters() |> Map.delete("refund_to") |> NearIntents.quote()

      assert {:error, :invalid_origin_asset} =
               NearIntents.quote(quote_parameters(%{"origin_asset" => "USDT"}))

      assert {:error, :invalid_destination_asset} =
               NearIntents.quote(quote_parameters(%{"destination_asset" => "USDT"}))
    end

    test "rejects an invalid provider response" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"quote" => %{"amountIn" => "1"}}) end)

      assert {:error, :invalid_quote_response} = NearIntents.quote(quote_parameters())

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)
      assert {:error, :invalid_quote_response} = NearIntents.quote(quote_parameters())
    end

    test "preserves 1Click rejections and classifies transport failure" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "bad quote"})
      end)

      assert {:error, {:rejected, 422, %{"message" => "bad quote"}}} =
               NearIntents.quote(quote_parameters())

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, :unavailable} = NearIntents.quote(quote_parameters())
    end
  end

  describe "verify/2 validation" do
    test "requires a non-empty hash payload", %{charge: charge} do
      assert_error(NearIntents.verify(%{}, charge), "invalid-payload", "non-empty hash")
      assert_error(NearIntents.verify(%{"type" => "hash", "hash" => ""}, charge), "invalid-payload", "non-empty hash")
    end

    test "requires the challenge id and deposit recipient", %{charge: charge} do
      assert_error(
        verify(%{charge | recipient: nil}),
        "verification-failed",
        "deposit address"
      )

      charge = put_in(charge.method_details["challenge_id"], nil)
      assert_error(verify(charge), "verification-failed", "challenge")
    end

    test "requires CAIP assets to match their configured networks", %{charge: charge} do
      wrong_origin = %{charge | currency: "eip155:8453/erc20:" <> @origin_token}

      assert_error(
        verify(wrong_origin),
        "verification-failed",
        "Origin asset"
      )

      wrong_destination =
        put_in(charge.method_details["destination_asset"], "near:mainnet/nep141:usdt.tether-token.near")

      assert_error(
        verify(wrong_destination),
        "verification-failed",
        "Destination asset"
      )
    end

    test "rejects expired and malformed quote deadlines", %{charge: charge} do
      expired = put_in(charge.method_details["quote_deadline"], "2020-01-01T00:00:00Z")
      assert_error(verify(expired), "payment-expired", "expired")

      malformed = put_in(charge.method_details["quote_deadline"], "invalid")
      assert_error(verify(malformed), "verification-failed", "deadline")
    end
  end

  describe "verify/2 settlement" do
    test "verifies the observed ERC-20 deposit and returns a receipt only on SUCCESS", %{charge: charge} do
      stub_settlement(success_status(), receipt: origin_receipt())

      charge =
        update_in(charge.method_details, fn config ->
          Map.merge(config, %{
            "origin_rpc_url" => @origin_rpc_url,
            "origin_req_options" => [plug: {Req.Test, __MODULE__}]
          })
        end)

      assert {:ok, %Receipt{} = receipt} = verify(charge)
      assert receipt.method == "nearintents"
      assert receipt.reference == @destination_hash
      assert receipt.timestamp == @settled_at
      assert receipt.external_id == "order-79"
      assert receipt.extensions["challengeId"] == "challenge-79"
      assert receipt.extensions["originTxHash"] == @origin_hash
      assert receipt.extensions["destinationNetwork"] == @destination_network
    end

    test "uses 1Click's observed origin transaction for non-EVM origins", %{charge: charge} do
      origin_hash = "5dw4Hd2uVkJmBgZvGnPjSxeUH4Kg5eNmnC9TD5dQUDjG"
      charge = put_in(charge.method_details["origin_network"], "near:mainnet")
      charge = %{charge | currency: "near:mainnet/nep141:usdt.tether-token.near"}
      charge = with_store(charge)
      stub_settlement(success_status(origin_hash), hash: origin_hash)

      assert {:ok, %Receipt{}} = verify(charge, origin_hash)
    end

    test "does not consume an unrelated presented hash and permits the observed hash", %{charge: charge} do
      charge = with_store(charge)
      unrelated_hash = "0x" <> String.duplicate("ab", 32)
      stub_settlement(success_status(), hash: unrelated_hash)

      assert_error(
        verify(charge, unrelated_hash),
        "verification-failed",
        "not observed"
      )

      stub_settlement(success_status(), receipt: origin_receipt())
      assert {:ok, %Receipt{}} = verify(charge)
    end

    test "REFUNDED consumes the hash and retires the quote", %{charge: charge} do
      charge = with_store(charge)
      stub_settlement(refunded_status())

      assert_error(
        verify(charge),
        "settlement-failed",
        "refunded to refundTo"
      )

      assert_error(verify(charge), "invalid-challenge", "already been settled")

      fresh_quote = %{charge | recipient: "0x1111111111111111111111111111111111111111"}
      assert_error(verify(fresh_quote), "verification-failed", "already been consumed")

      fresh_hash = "0x" <> String.duplicate("cd", 32)
      assert_error(verify(charge, fresh_hash), "invalid-challenge", "already been settled")
    end

    test "FAILED and INCOMPLETE_DEPOSIT return their terminal payment errors", %{charge: charge} do
      stub_settlement(failed_status())
      assert_error(verify(charge), "settlement-failed", "NO_QUOTES")

      stub_settlement(incomplete_status())

      assert_error(
        verify(charge),
        "payment-insufficient",
        "below minAmountIn"
      )
    end

    test "a non-terminal status times out without consuming the credential", %{charge: charge} do
      charge = charge |> with_store() |> put_in([Access.key!(:method_details), "poll_timeout_ms"], 0)
      stub_settlement(processing_status())

      assert_error(verify(charge), "server-error", "terminal state")

      stub_settlement(success_status())
      assert {:ok, %Receipt{}} = verify(charge)
    end

    test "backend failures release the credential and 4xx status errors remain verification failures", %{charge: charge} do
      charge = charge |> with_store() |> with_origin_rpc() |> put_in([Access.key!(:method_details), "poll_timeout_ms"], 0)
      stub_status_response(503, %{"message" => "maintenance"})
      assert_error(verify(charge), "server-error", "unavailable")

      stub_status_response(404, %{"message" => "deposit not found"})

      assert_error(
        verify(charge),
        "verification-failed",
        "HTTP 404"
      )

      stub_settlement(success_status(), receipt: origin_receipt())
      assert {:ok, %Receipt{}} = verify(charge)
    end

    test "retries an unavailable status endpoint while the settlement window remains", %{charge: charge} do
      counter = start_supervised!({Agent, fn -> 0 end})
      charge = with_origin_rpc(charge)
      charge = put_in(charge.method_details["one_click_req_options"], plug: {Req.Test, __MODULE__}, retry: false)

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/v0/deposit/submit" ->
            Req.Test.json(conn, %{"status" => "KNOWN_DEPOSIT_TX"})

          "/v0/status" ->
            case Agent.get_and_update(counter, &{&1, &1 + 1}) do
              0 -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "maintenance"})
              _attempt -> Req.Test.json(conn, success_status())
            end

          path when path in [nil, "/"] ->
            {_method, id, conn} = read_rpc_request(conn)
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => origin_receipt()})
        end
      end)

      assert {:ok, %Receipt{}} = verify(charge)
    end

    test "matches Bitcoin hashes canonically and supports provider deposit memos", %{charge: charge} do
      bitcoin_network = "bip122:000000000019d6689c085ae165831e93"
      hash = String.duplicate("ab", 32)

      charge =
        charge
        |> Map.put(:currency, bitcoin_network <> "/slip44:0")
        |> update_in([Access.key!(:method_details)], fn config ->
          config
          |> Map.put("origin_network", bitcoin_network)
          |> Map.put("deposit_memo", "memo-79")
          |> Map.delete("poll_timeout_ms")
          |> Map.delete("poll_interval_ms")
          |> Map.put("time_estimate", 0)
        end)

      charge = with_store(charge)

      stub_settlement(success_status(String.upcase(hash)), hash: hash, memo: "memo-79")
      assert {:ok, %Receipt{}} = verify(charge, hash)

      charge = put_in(charge.method_details["store"], false)

      stub_settlement(
        success_status(%{"originChainTxHashes" => ["malformed", %{"hash" => nil}]}),
        hash: hash,
        memo: "memo-79"
      )

      assert_error(verify(charge, hash), "verification-failed", "not observed")
    end

    test "rejects malformed terminal responses", %{charge: charge} do
      direct_charge = with_origin_rpc(charge)
      stub_settlement(%{"updatedAt" => @settled_at}, receipt: origin_receipt())
      assert_error(verify(direct_charge), "server-error", "invalid status")

      stub_settlement(success_status(%{"destinationChainTxHashes" => [], "nearTxHashes" => []}))
      assert_error(verify(charge), "server-error", "no destination reference")

      stub_settlement(success_status(%{"depositedAmount" => "1"}))
      assert_error(verify(charge), "payment-insufficient", "below minAmountIn")
    end

    test "releases a stateless claim when settlement reports a different hash", %{charge: charge} do
      charge = with_origin_rpc(charge)
      other_hash = "0x" <> String.duplicate("ef", 32)
      stub_settlement(success_status(other_hash), receipt: origin_receipt())
      assert_error(verify(charge), "verification-failed", "not observed")
    end
  end

  describe "origin RPC verification" do
    test "classifies 1Click observation failures", %{charge: charge} do
      stub_status_response(503, %{"message" => "maintenance"})
      assert_error(verify(charge), "server-error", "unavailable")

      stub_status_response(404, %{"message" => "deposit not found"})
      assert_error(verify(charge), "verification-failed", "HTTP 404")

      stub_settlement(%{"updatedAt" => @settled_at})
      assert_error(verify(charge), "server-error", "invalid status")
    end

    test "rejects a missing or wrong ERC-20 origin transaction", %{charge: charge} do
      charge = with_origin_rpc(charge)
      stub_settlement(success_status(), receipt: nil)
      assert_error(verify(charge), "verification-failed", "not found")

      stub_settlement(success_status(), receipt: origin_receipt(%{"logs" => []}))

      assert_error(
        verify(charge),
        "verification-failed",
        "required deposit"
      )
    end

    test "classifies origin RPC failure and unsupported direct-RPC origins as server errors", %{charge: charge} do
      charge = with_origin_rpc(charge)
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert_error(verify(charge), "server-error", "Origin RPC")

      charge = put_in(charge.method_details["origin_network"], "near:mainnet")
      charge = %{charge | currency: "near:mainnet/nep141:usdt.tether-token.near"}

      assert_error(
        verify(charge),
        "server-error",
        "supports eip155"
      )
    end

    test "verifies native EVM deposits", %{charge: charge} do
      {:ok, native_charge} =
        Charge.new(
          amount: @amount_in,
          currency: @origin_network <> "/slip44:60",
          recipient: @deposit_address
        )

      native_charge = %{native_charge | method_details: with_origin_rpc(charge).method_details}
      stub_settlement(success_status(), receipt: native_receipt(), transaction: native_transaction())

      assert {:ok, %Receipt{}} = verify(native_charge)
    end

    test "rejects invalid EVM assets and minimum amounts", %{charge: charge} do
      charge = with_origin_rpc(charge)
      stub_settlement(success_status(), receipt: origin_receipt())
      invalid_asset = %{charge | currency: @origin_network <> "/unknown:asset"}
      assert_error(verify(invalid_asset), "verification-failed", "Invalid origin asset")

      stub_settlement(success_status(), receipt: origin_receipt())
      invalid_minimum = put_in(charge.method_details["min_amount_in"], "invalid")
      assert_error(verify(invalid_minimum), "verification-failed", "Invalid minAmountIn")
    end

    test "rejects malformed receipt and native transaction shapes", %{charge: charge} do
      charge = with_origin_rpc(charge)
      stub_settlement(success_status(), receipt: origin_receipt())

      assert {:error, %Errors{detail: "Origin transaction does not contain the required deposit"}} =
               Origin.verify(@origin_hash, %{charge | recipient: nil}, charge.method_details)

      native = %{charge | currency: @origin_network <> "/slip44:60"}
      stub_settlement(success_status(), receipt: native_receipt(), transaction: nil)
      assert_error(verify(native), "verification-failed", "required deposit")

      stub_settlement(success_status(), receipt: native_receipt())

      assert {:error, %Errors{detail: "Near Intents method requires a deposit address"}} =
               Origin.verify(@origin_hash, %{native | recipient: nil}, native.method_details)
    end

    test "classifies a native transaction RPC failure as unavailable", %{charge: charge} do
      native = charge |> with_origin_rpc() |> Map.put(:currency, @origin_network <> "/slip44:60")

      Req.Test.stub(__MODULE__, fn conn ->
        {method, id, conn} = read_rpc_request(conn)

        case method do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => native_receipt()})

          "eth_getTransactionByHash" ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      assert_error(verify(native), "server-error", "Origin RPC")
    end
  end

  describe "atomic settlement claims" do
    test "reclaims active and expired in-flight state", %{charge: charge} do
      charge = with_store(charge)
      put_hash_state(%{state: :active})
      stub_settlement(success_status())
      assert {:ok, %Receipt{}} = verify(charge)

      expired = System.system_time(:millisecond) - 1
      put_hash_state(%{state: :inflight, owner: 1, lease_until: expired})
      put_deposit_state(%{state: :inflight, owner: 1, lease_until: expired})
      stub_settlement(success_status())
      assert {:ok, %Receipt{}} = verify(charge)
    end

    test "rejects in-flight hash and deposit claims", %{charge: charge} do
      charge = with_store(charge)
      future = System.system_time(:millisecond) + 60_000
      put_hash_state(%{state: :inflight, owner: 1, lease_until: future})
      assert_error(verify(charge), "verification-failed", "transaction hash is already in progress")

      put_hash_state(%{state: :active})
      put_deposit_state(%{state: :inflight, owner: 1, lease_until: future})
      assert_error(verify(charge), "verification-failed", "deposit address is already in progress")
    end

    test "treats unknown persisted hash state as consumed", %{charge: charge} do
      charge = with_store(charge)
      put_hash_state(:unexpected)
      assert_error(verify(charge), "verification-failed", "already been consumed")
    end

    test "rejects a quote claimed concurrently after status verification", %{charge: charge} do
      charge = with_store(charge)
      future = System.system_time(:millisecond) + 60_000

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v0/status"
        put_deposit_state(%{state: :inflight, owner: 1, lease_until: future})
        Req.Test.json(conn, success_status())
      end)

      assert_error(verify(charge), "verification-failed", "deposit address is already in progress")
    end

    test "rejects a quote consumed concurrently after status verification", %{charge: charge} do
      charge = with_store(charge)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v0/status"
        put_deposit_state(%{state: :consumed})
        Req.Test.json(conn, success_status())
      end)

      assert_error(verify(charge), "invalid-challenge", "already been settled")
    end

    test "rejects unexpected quote state introduced after status verification", %{charge: charge} do
      charge = with_store(charge)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v0/status"
        put_deposit_state(:unexpected)
        Req.Test.json(conn, success_status())
      end)

      assert_error(verify(charge), "invalid-challenge", "already been settled")
    end

    test "does not release a hash consumed concurrently after status verification", %{charge: charge} do
      charge = with_store(charge)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v0/status"
        put_hash_state(%{state: :consumed})
        Req.Test.json(conn, success_status())
      end)

      assert_error(verify(charge), "verification-failed", "already been consumed")
    end
  end

  defp method_config(extra \\ %{}) do
    Map.merge(
      %{
        "origin_network" => @origin_network,
        "destination_network" => @destination_network,
        "destination_asset" => @destination_asset,
        "destination_recipient" => @destination_recipient,
        "amount_out" => @amount_out,
        "min_amount_in" => @amount_in,
        "refund_to" => @refund_to,
        "quote_deadline" => @quote_deadline,
        "challenge_id" => "challenge-79",
        "one_click_url" => @one_click_url,
        "one_click_req_options" => [plug: {Req.Test, __MODULE__}],
        "poll_timeout_ms" => 50,
        "poll_interval_ms" => 0,
        "store" => false
      },
      extra
    )
  end

  defp quote_parameters(extra \\ %{}) do
    Map.merge(
      %{
        "origin_asset" => @origin_asset,
        "origin_asset_id" => "nep141:eth-usdt.omft.near",
        "destination_asset" => @destination_asset,
        "destination_asset_id" => "nep141:tron-usdt.omft.near",
        "destination_recipient" => @destination_recipient,
        "amount_out" => "1000000",
        "refund_to" => @refund_to,
        "deadline" => @quote_deadline,
        "referral" => "mpp-live-observation",
        "one_click_url" => @one_click_url,
        "one_click_jwt" => "partner-token",
        "one_click_req_options" => [plug: {Req.Test, __MODULE__}]
      },
      extra
    )
  end

  defp observed_quote_response do
    %{
      "quote" => %{
        "amountIn" => "1929010",
        "minAmountIn" => "1909719",
        "amountOut" => "1000000",
        "timeEstimate" => 100,
        "deadline" => @quote_deadline,
        "depositAddress" => "0x8446675C0D5f55CbeF9Bc92B8B5AfCC3E57C3c55"
      },
      "signature" => "provider-signature",
      "timestamp" => "2026-08-19T05:09:48.000Z"
    }
  end

  defp success_status(origin_hash \\ @origin_hash)

  defp success_status(origin_hash) when is_binary(origin_hash) do
    success_status(%{"originChainTxHashes" => [%{"hash" => origin_hash}]})
  end

  defp success_status(overrides) when is_map(overrides) do
    details =
      Map.merge(
        %{
          "depositedAmount" => @amount_in,
          "originChainTxHashes" => [%{"hash" => @origin_hash}],
          "destinationChainTxHashes" => [%{"hash" => @destination_hash}],
          "nearTxHashes" => ["5dw4Hd2uVkJmBgZvGnPjSxeUH4Kg5eNmnC9TD5dQUDjG"]
        },
        overrides
      )

    %{"status" => "SUCCESS", "updatedAt" => @settled_at, "swapDetails" => details}
  end

  defp refunded_status do
    %{
      "status" => "REFUNDED",
      "updatedAt" => @settled_at,
      "swapDetails" => %{
        "depositedAmount" => @amount_in,
        "originChainTxHashes" => [%{"hash" => @origin_hash}],
        "refundReason" => "AMOUNT_LESS_THAN_MIN_AMOUNT_OUT",
        "refundedAmount" => "150347"
      }
    }
  end

  defp failed_status do
    %{
      "status" => "FAILED",
      "swapDetails" => %{
        "depositedAmount" => @amount_in,
        "originChainTxHashes" => [%{"hash" => @origin_hash}],
        "refundReason" => "NO_QUOTES"
      }
    }
  end

  defp incomplete_status do
    %{
      "status" => "INCOMPLETE_DEPOSIT",
      "swapDetails" => %{
        "originChainTxHashes" => [%{"hash" => @origin_hash}],
        "depositedAmount" => "1"
      }
    }
  end

  defp processing_status do
    %{
      "status" => "PROCESSING",
      "swapDetails" => %{
        "originChainTxHashes" => [%{"hash" => @origin_hash}],
        "depositedAmount" => @amount_in
      }
    }
  end

  defp with_origin_rpc(charge) do
    update_in(charge.method_details, fn config ->
      Map.merge(config, %{
        "origin_rpc_url" => @origin_rpc_url,
        "origin_req_options" => [plug: {Req.Test, __MODULE__}]
      })
    end)
  end

  defp with_store(charge) do
    start_supervised!(ConCacheStore.child_spec(name: @cache_name))
    put_in(charge.method_details["store"], {ConCacheStore, name: @cache_name})
  end

  defp put_hash_state(value) do
    hash = @origin_hash |> String.trim_leading("0x") |> String.downcase()
    ConCacheStore.put("mpp:nearintents:hash:" <> hash, value, name: @cache_name)
  end

  defp put_deposit_state(value) do
    ConCacheStore.put("mpp:nearintents:deposit:" <> @deposit_address, value, name: @cache_name)
  end

  defp stub_settlement(status, opts \\ []) do
    expected_hash = Keyword.get(opts, :hash, @origin_hash)
    memo = Keyword.get(opts, :memo)
    receipt = Keyword.get(opts, :receipt, :not_configured)
    transaction = Keyword.get(opts, :transaction, :not_configured)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v0/deposit/submit" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          expected_body = maybe_put(%{"depositAddress" => @deposit_address, "txHash" => expected_hash}, "memo", memo)

          assert Jason.decode!(body) == expected_body

          Req.Test.json(conn, %{"status" => "KNOWN_DEPOSIT_TX"})

        "/v0/status" ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["depositAddress"] == @deposit_address
          assert conn.query_params["depositMemo"] == memo
          Req.Test.json(conn, status)

        path when path in [nil, "/"] ->
          {method, id, conn} = read_rpc_request(conn)
          result = rpc_result(method, receipt, transaction)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
      end
    end)
  end

  defp stub_status_response(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v0/deposit/submit" ->
          Req.Test.json(conn, %{"status" => "KNOWN_DEPOSIT_TX"})

        "/v0/status" ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

        path when path in [nil, "/"] ->
          {_method, id, conn} = read_rpc_request(conn)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => origin_receipt()})
      end
    end)
  end

  defp read_rpc_request(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    {request["method"], request["id"], conn}
  end

  defp rpc_result("eth_getTransactionReceipt", receipt, _transaction), do: receipt
  defp rpc_result("eth_getTransactionByHash", _receipt, transaction), do: transaction

  defp origin_receipt(overrides \\ %{}) do
    padded_sender = "0x" <> String.duplicate("0", 24) <> strip_0x(@sender)
    padded_recipient = "0x" <> String.duplicate("0", 24) <> strip_0x(@deposit_address)

    Map.merge(
      %{
        "transactionHash" => @origin_hash,
        "blockNumber" => "0x1",
        "status" => "0x1",
        "from" => @sender,
        "to" => @origin_token,
        "logs" => [
          %{
            "address" => @origin_token,
            "topics" => [@transfer_topic, padded_sender, padded_recipient],
            "data" => @amount_hex,
            "blockNumber" => "0x1",
            "transactionHash" => @origin_hash,
            "logIndex" => "0x0"
          }
        ]
      },
      overrides
    )
  end

  defp native_receipt do
    %{
      "transactionHash" => @origin_hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => @sender,
      "to" => @deposit_address,
      "logs" => []
    }
  end

  defp native_transaction do
    %{
      "hash" => @origin_hash,
      "from" => @sender,
      "to" => @deposit_address,
      "value" => "0x" <> Integer.to_string(24_499_630_000, 16),
      "blockNumber" => "0x1"
    }
  end

  defp assert_error({:error, %Errors{} = error}, type_suffix, detail) do
    assert String.ends_with?(error.type, type_suffix)
    assert error.detail =~ detail
  end

  defp verify(charge, hash \\ @origin_hash) do
    NearIntents.verify(%{"type" => "hash", "hash" => hash}, charge)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp strip_0x("0x" <> rest), do: rest
end
