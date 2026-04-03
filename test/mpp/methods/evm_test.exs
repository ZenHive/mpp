defmodule MPP.Methods.EVMTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Receipt

  @rpc_url "https://mainnet.infura.io/v3/test"
  @chain_id 1
  @token_address "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @sender "0xaBcDeF1234567890AbCdEf1234567890AbCdEf12"
  @tx_hash "0x" <> String.duplicate("ab", 32)

  # ERC-20 Transfer(address,address,uint256) topic
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # Amount: 1_000_000 (USDC has 6 decimals, so this is 1 USDC)
  @amount "1000000"
  # 1_000_000 in hex = 0xF4240 — padded to 32 bytes for log data
  @amount_hex "0x" <> String.duplicate("0", 58) <> "0f4240"

  setup do
    {:ok, charge} =
      Charge.new(
        amount: @amount,
        currency: @token_address,
        recipient: @recipient
      )

    # Simulate what Plug does: merge method_config into charge.method_details
    charge = %{
      charge
      | method_details: %{
          "rpc_url" => @rpc_url,
          "chain_id" => @chain_id,
          "req_options" => [plug: {Req.Test, EVM}]
        }
    }

    {:ok, charge: charge}
  end

  describe "method_name/0" do
    test "returns \"evm\"" do
      assert EVM.method_name() == "evm"
    end
  end

  describe "validate_config!/1" do
    test "returns :ok with valid config" do
      assert :ok = EVM.validate_config!(%{"rpc_url" => @rpc_url})
    end

    test "raises on missing rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        EVM.validate_config!(%{})
      end
    end

    test "raises on nil rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        EVM.validate_config!(%{"rpc_url" => nil})
      end
    end
  end

  describe "challenge_method_details/1" do
    test "returns chainId when chain_id is configured", %{charge: charge} do
      assert %{"chainId" => 1} = EVM.challenge_method_details(charge)
    end

    test "returns nil when no chain_id configured", %{charge: charge} do
      charge = %{charge | method_details: %{"rpc_url" => @rpc_url}}
      assert is_nil(EVM.challenge_method_details(charge))
    end
  end

  describe "verify/2 — ERC-20 path" do
    test "returns receipt on successful ERC-20 transfer", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => receipt_with_transfer()})

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
        end
      end)

      payload = %{"hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = EVM.verify(payload, charge)
      assert receipt.method == "evm"
      assert receipt.reference == @tx_hash
      assert receipt.status == "success"
    end

    test "returns error when hash is missing", %{charge: charge} do
      assert {:error, %Errors{} = error} = EVM.verify(%{}, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "hash"
    end

    test "returns error when hash is empty string", %{charge: charge} do
      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => ""}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when hash has wrong length", %{charge: charge} do
      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => "0xdead"}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when hash lacks 0x prefix", %{charge: charge} do
      bare_hash = String.duplicate("ab", 32)
      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => bare_hash}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when recipient is nil", %{charge: charge} do
      charge = %{charge | recipient: nil}
      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "recipient"
    end

    test "returns error when hash has non-hex characters", %{charge: charge} do
      bad_hash = "0x" <> String.duplicate("zz", 32)
      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => bad_hash}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when transaction failed (reverted)", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{
            "transactionHash" => @tx_hash,
            "blockNumber" => "0x1",
            "status" => "0x0",
            "from" => @sender,
            "to" => @token_address,
            "logs" => []
          }
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "reverted"
    end

    test "returns error when no matching Transfer event", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{
            "transactionHash" => @tx_hash,
            "blockNumber" => "0x1",
            "status" => "0x1",
            "from" => @sender,
            "to" => @token_address,
            "logs" => []
          }
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error when Transfer has wrong recipient", %{charge: charge} do
      wrong_recipient = "0x" <> String.duplicate("99", 20)

      Req.Test.stub(EVM, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => receipt_with_transfer(recipient: wrong_recipient)
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error when Transfer has wrong amount", %{charge: charge} do
      # 500_000 instead of 1_000_000
      wrong_amount_hex = "0x" <> String.duplicate("0", 58) <> "07a120"

      Req.Test.stub(EVM, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => receipt_with_transfer(amount_hex: wrong_amount_hex)
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error when transaction not found", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "not found"
    end

    test "returns error on RPC error response", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_000, "message" => "server error"}
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "RPC error"
    end
  end

  describe "verify/2 — native ETH path" do
    setup %{charge: charge} do
      # Override currency to ETH
      {:ok, eth_charge} =
        Charge.new(
          amount: "1000000000000000000",
          currency: "ETH",
          recipient: @recipient
        )

      eth_charge = %{eth_charge | method_details: charge.method_details}

      {:ok, eth_charge: eth_charge}
    end

    test "returns receipt on successful native ETH transfer", %{eth_charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "transactionHash" => @tx_hash,
                "blockNumber" => "0x1",
                "status" => "0x1",
                "from" => @sender,
                "to" => @recipient,
                "logs" => []
              }
            })

          "eth_getTransactionByHash" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "hash" => @tx_hash,
                "from" => @sender,
                "to" => @recipient,
                "value" => "0xde0b6b3a7640000",
                "input" => "0x"
              }
            })
        end
      end)

      payload = %{"hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = EVM.verify(payload, charge)
      assert receipt.method == "evm"
      assert receipt.reference == @tx_hash
    end

    test "returns error when ETH value does not match", %{eth_charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "transactionHash" => @tx_hash,
                "blockNumber" => "0x1",
                "status" => "0x1",
                "from" => @sender,
                "to" => @recipient,
                "logs" => []
              }
            })

          "eth_getTransactionByHash" ->
            # Wrong value: 0.5 ETH instead of 1 ETH
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "hash" => @tx_hash,
                "from" => @sender,
                "to" => @recipient,
                "value" => "0x6f05b59d3b20000",
                "input" => "0x"
              }
            })
        end
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "value"
    end

    test "returns error when ETH recipient does not match", %{eth_charge: charge} do
      wrong_recipient = "0x" <> String.duplicate("99", 20)

      Req.Test.stub(EVM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "transactionHash" => @tx_hash,
                "blockNumber" => "0x1",
                "status" => "0x1",
                "from" => @sender,
                "to" => wrong_recipient,
                "logs" => []
              }
            })

          "eth_getTransactionByHash" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "hash" => @tx_hash,
                "from" => @sender,
                "to" => wrong_recipient,
                "value" => "0xde0b6b3a7640000",
                "input" => "0x"
              }
            })
        end
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "recipient"
    end

    test "also accepts zero address as native currency" do
      {:ok, charge} =
        Charge.new(
          amount: "1000000000000000000",
          currency: "0x0000000000000000000000000000000000000000",
          recipient: @recipient
        )

      charge = %{
        charge
        | method_details: %{
            "rpc_url" => @rpc_url,
            "req_options" => [plug: {Req.Test, EVM}]
          }
      }

      Req.Test.stub(EVM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "transactionHash" => @tx_hash,
                "blockNumber" => "0x1",
                "status" => "0x1",
                "from" => @sender,
                "to" => @recipient,
                "logs" => []
              }
            })

          "eth_getTransactionByHash" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "hash" => @tx_hash,
                "from" => @sender,
                "to" => @recipient,
                "value" => "0xde0b6b3a7640000",
                "input" => "0x"
              }
            })
        end
      end)

      payload = %{"hash" => @tx_hash}
      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)
    end
  end

  # --- Test helpers ---

  # Builds a valid receipt with an ERC-20 Transfer log matching the default charge.
  defp receipt_with_transfer(opts \\ []) do
    recipient = Keyword.get(opts, :recipient, @recipient)
    amount_hex = Keyword.get(opts, :amount_hex, @amount_hex)

    # Topics: Transfer topic, padded sender address, padded recipient address
    padded_sender = "0x" <> String.duplicate("0", 24) <> strip_0x(@sender)
    padded_recipient = "0x" <> String.duplicate("0", 24) <> strip_0x(recipient)

    %{
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => @sender,
      "to" => @token_address,
      "logs" => [
        %{
          "address" => @token_address,
          "topics" => [
            @transfer_topic,
            padded_sender,
            padded_recipient
          ],
          "data" => amount_hex,
          "blockNumber" => "0x1",
          "transactionHash" => @tx_hash,
          "logIndex" => "0x0"
        }
      ]
    }
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(hex), do: hex
end
