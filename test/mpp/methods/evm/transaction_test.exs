defmodule MPP.Methods.EVM.TransactionTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Methods.EVM.RPC, as: EvmRPC
  alias MPP.Methods.EVM.Transaction
  alias MPP.Receipt
  alias MPP.Tempo.Store
  alias MPP.Test.EVMTransaction

  @rpc_url "https://mainnet.infura.io/v3/test"
  @chain_id 1
  @token "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @wrong_recipient "0x9994567890AbcdEF1234567890aBcDeF12345678"
  @amount 1_000_000
  @amount_str "1000000"
  @amount_hex "0x" <> String.duplicate("0", 58) <> "0f4240"
  @sender EVMTransaction.signer_address()
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

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

  setup do
    signed = signed_transfer()
    {:ok, signed: signed, charge: charge()}
  end

  describe "offered?/1" do
    test "is false by default", %{charge: charge} do
      refute Transaction.offered?(charge)
    end

    test "is true when transaction is enabled for an ERC-20 charge", %{charge: charge} do
      assert Transaction.offered?(enable(charge))
    end

    test "is false for native ETH even when enabled", %{charge: charge} do
      eth = %{enable(charge) | currency: "ETH"}
      refute Transaction.offered?(eth)
    end

    test "is false when splits are present", %{charge: charge} do
      charge =
        enable(%{
          charge
          | method_details: Map.put(charge.method_details, "splits", [%{"recipient" => @recipient, "amount" => "1"}])
        })

      refute Transaction.offered?(charge)
    end

    test "is false for the zero address and non-binary currency", %{charge: charge} do
      refute Transaction.offered?(%{enable(charge) | currency: "0x0000000000000000000000000000000000000000"})
      refute Transaction.offered?(%{enable(charge) | currency: nil})
    end

    test "is false without a Charge struct", %{charge: charge} do
      refute Transaction.offered?(%{})
      refute Transaction.offered?(%{charge | method_details: nil})
    end
  end

  describe "RPC helpers" do
    test "canonicalizes mixed-case transaction hashes" do
      assert EvmRPC.canonicalize_hash("0xAB") == "0xab"
    end

    test "omits req_options when they are absent" do
      assert EvmRPC.rpc_opts(@rpc_url, %{}) == [rpc_url: @rpc_url]
    end
  end

  describe "challenge_method_details/1" do
    test "does not advertise transaction unless enabled", %{charge: charge} do
      assert EVM.challenge_method_details(charge)["credentialTypes"] == ["hash"]
      assert "transaction" in EVM.credential_types()
    end

    test "advertises transaction ahead of hash when enabled", %{charge: charge} do
      details = EVM.challenge_method_details(enable(charge))
      assert details["credentialTypes"] == ["transaction", "hash"]
    end

    test "keeps authorization ahead of transaction when both are offered", %{charge: charge} do
      charge =
        charge
        |> enable()
        |> Map.update!(:method_details, &Map.put(&1, "private_key", EVMTransaction.private_key()))

      assert EVM.challenge_method_details(charge)["credentialTypes"] == ["authorization", "transaction", "hash"]
    end

    test "does not advertise transaction for native ETH", %{charge: charge} do
      eth = %{enable(charge) | currency: "ETH"}
      assert EVM.challenge_method_details(eth)["credentialTypes"] == ["hash"]
    end

    test "does not advertise transaction when splits are present", %{charge: charge} do
      charge = %{
        charge
        | method_details:
            charge.method_details
            |> Map.put("transaction", true)
            |> Map.put("splits", [%{"recipient" => @recipient, "amount" => "1"}])
      }

      assert EVM.challenge_method_details(charge)["credentialTypes"] == []
    end
  end

  describe "validate/2" do
    test "accepts a signed EIP-1559 transfer matching the charge", %{signed: signed, charge: charge} do
      assert {:ok, prepared} = Transaction.validate(signed.payload, charge)
      assert prepared.hash == signed.hash
      assert prepared.raw == signed.raw
    end

    test "rejects a missing signature", %{charge: charge} do
      assert {:error, %Errors{} = error} = Transaction.validate(%{"type" => "transaction"}, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "rejects a non-type-2 envelope", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0x01" <> String.duplicate("00", 32)}
      assert {:error, %Errors{} = error} = Transaction.validate(payload, charge)
      assert error.detail =~ "EIP-1559"
    end

    test "rejects a chainId mismatch", %{charge: charge} do
      signed = signed_transfer(chain_id: 11_155_111)
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "chainId"
    end

    test "rejects a currency (to) mismatch", %{charge: charge} do
      signed = signed_transfer(currency: @wrong_recipient)
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "currency"
    end

    test "rejects a recipient mismatch", %{charge: charge} do
      signed = signed_transfer(recipient: @wrong_recipient)
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "recipient"
    end

    test "rejects an amount mismatch", %{charge: charge} do
      signed = signed_transfer(amount: 7)
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "amount"
    end

    test "rejects splits", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "splits", [%{"recipient" => @recipient, "amount" => "1"}])
      }

      signed = signed_transfer()
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "splits"
    end

    test "rejects native ETH", %{charge: charge} do
      eth = %{charge | currency: "ETH"}
      assert {:error, %Errors{} = error} = Transaction.validate(signed_transfer().payload, eth)
      assert error.detail =~ "ERC-20"
    end

    test "rejects an expired challenge before broadcast", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "challenge_expires", past_expires())}
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.type =~ "payment-expired"
    end

    test "rejects missing challenge expiry", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.delete(charge.method_details, "challenge_expires")}
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "expiry"
    end

    test "rejects a payload that is not type=transaction", %{charge: charge} do
      assert {:error, %Errors{} = error} = Transaction.validate(%{"type" => "hash"}, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "transaction"
    end

    test "rejects a non-hex signature", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0xzzzz"}
      assert {:error, %Errors{} = error} = Transaction.validate(payload, charge)
      assert error.detail =~ "EIP-1559"
    end

    test "rejects an odd-length signature", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0xabc"}
      assert {:error, %Errors{} = error} = Transaction.validate(payload, charge)
      assert error.detail =~ "EIP-1559"
    end

    test "rejects a non-string signature", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => 12}
      assert {:error, %Errors{} = error} = Transaction.validate(payload, charge)
      assert error.detail =~ "signature"
    end

    test "rejects an invalid type-2 RLP envelope", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0x02deadbeef"}
      assert {:error, %Errors{} = error} = Transaction.validate(payload, charge)
      assert error.detail =~ "EIP-1559"
    end

    test "rejects an unsigned type-2 transaction", %{charge: charge} do
      assert {:error, %Errors{} = error} = Transaction.validate(unsigned_payload(), charge)
      assert error.detail =~ "not signed"
    end

    test "rejects a missing chain_id", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.delete(charge.method_details, "chain_id")}
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "chain_id"
    end

    test "rejects calldata that is not an ERC-20 transfer", %{charge: charge} do
      {:ok, spender} = Onchain.Address.validate(@recipient)
      {:ok, hex} = Onchain.ABI.encode_call("approve(address,uint256)", [spender, @amount])
      signed = signed_transfer(data: Onchain.Hex.decode!(hex))
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "ERC-20 transfer"
    end

    test "rejects a transfer selector with truncated ABI arguments", %{charge: charge} do
      signed = signed_transfer(data: <<0xA9, 0x05, 0x9C, 0xBB, 0x00>>)
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "ERC-20 transfer"
    end

    test "rejects a non-ISO challenge expiry", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "challenge_expires", "tomorrow")}
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "ISO 8601"
    end

    test "rejects native ETH as the zero address", %{signed: signed, charge: charge} do
      zero = %{charge | currency: "0x0000000000000000000000000000000000000000"}
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, zero)
      assert error.detail =~ "ERC-20"
    end

    test "rejects an invalid charge amount", %{signed: signed, charge: charge} do
      charge = %{charge | amount: "1.5"}
      assert {:error, %Errors{} = error} = Transaction.validate(signed.payload, charge)
      assert error.detail =~ "amount"
    end
  end

  describe "verify/2" do
    test "broadcasts a valid transfer, requires the Transfer log, and records the hash", %{
      signed: signed,
      charge: charge
    } do
      stub_broadcast(signed.hash)

      assert {:ok, %Receipt{} = receipt} = EVM.verify(signed.payload, charge)
      assert receipt.method == "evm"
      assert receipt.reference == signed.hash
    end

    test "rejects a receipt that succeeded without a matching Transfer event", %{signed: signed, charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_sendRawTransaction" => signed.hash,
          "eth_getTransactionReceipt" => %{
            "transactionHash" => signed.hash,
            "blockNumber" => "0x1",
            "status" => "0x1",
            "from" => @sender,
            "to" => @token,
            "logs" => []
          }
        })
      end)

      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.detail =~ "No matching Transfer"
    end

    test "does not broadcast an expired challenge", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "challenge_expires", past_expires())}
      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.type =~ "payment-expired"
    end

    test "atomically records the broadcast hash against replay", %{signed: signed, charge: charge} do
      start_supervised!(MemoryStore)
      charge = %{charge | method_details: Map.put(charge.method_details, "store", MemoryStore)}
      stub_broadcast(signed.hash)

      assert {:ok, %Receipt{}} = EVM.verify(signed.payload, charge)
      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.detail == "Transaction hash already used"
    end

    test "rejects a zero-amount charge before broadcast", %{signed: signed, charge: charge} do
      charge = %{charge | amount: "0"}
      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.detail =~ "proof credential"
    end

    test "rejects a missing recipient before broadcast", %{signed: signed, charge: charge} do
      charge = %{charge | recipient: nil}
      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.detail =~ "recipient"
    end

    test "maps a sendRawTransaction RPC error to a generic failure", %{signed: signed, charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        "eth_sendRawTransaction" = method
        rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "nonce too low"})
      end)

      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.detail == "EVM RPC request failed"
    end

    test "maps a receipt RPC error after broadcast", %{signed: signed, charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_sendRawTransaction" ->
            rpc_json(conn, id, "result", signed.hash)

          "eth_getTransactionReceipt" ->
            rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "receipt lookup failed"})
        end
      end)

      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.detail == "EVM RPC request failed"
    end

    test "times out when the receipt never appears", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "poll_timeout_ms", 0)}

      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_sendRawTransaction" -> rpc_json(conn, id, "result", signed.hash)
          "eth_getTransactionReceipt" -> rpc_json(conn, id, "result", nil)
        end
      end)

      assert {:error, %Errors{} = error} = EVM.verify(signed.payload, charge)
      assert error.title == "Settlement Timeout"
      assert error.status == 504
    end

    test "polls until the broadcast receipt appears", %{signed: signed, charge: charge} do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      charge = %{charge | method_details: Map.put(charge.method_details, "poll_timeout_ms", 5_000)}
      mixed = "0x" <> String.upcase(strip_0x(signed.hash))

      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_sendRawTransaction" ->
            rpc_json(conn, id, "result", mixed)

          "eth_getTransactionReceipt" ->
            n = Agent.get_and_update(attempts, fn i -> {i, i + 1} end)
            result = if n == 0, do: nil, else: receipt_with_transfer(signed.hash)
            rpc_json(conn, id, "result", result)
        end
      end)

      assert {:ok, %Receipt{reference: reference}} = EVM.verify(signed.payload, charge)
      assert reference == signed.hash
    end

    test "broadcast/2 requires rpc_url", %{signed: signed, charge: charge} do
      charge = %{charge | method_details: Map.delete(charge.method_details, "rpc_url")}
      assert {:error, %Errors{} = error} = Transaction.broadcast(%{raw: signed.raw}, charge)
      assert error.detail =~ "rpc_url"
    end
  end

  defp charge(extra \\ %{}) do
    {:ok, charge} = Charge.new(amount: @amount_str, currency: @token, recipient: @recipient)

    %{
      charge
      | method_details:
          Map.merge(
            %{
              "rpc_url" => @rpc_url,
              "chain_id" => @chain_id,
              "req_options" => [plug: {Req.Test, EVM}],
              "store" => false,
              "challenge_expires" => future_expires()
            },
            extra
          )
    }
  end

  defp enable(charge) do
    %{charge | method_details: Map.put(charge.method_details, "transaction", true)}
  end

  defp signed_transfer(opts \\ []) do
    params = %{
      chain_id: Keyword.get(opts, :chain_id, @chain_id),
      currency: Keyword.get(opts, :currency, @token),
      recipient: Keyword.get(opts, :recipient, @recipient),
      amount: Keyword.get(opts, :amount, @amount)
    }

    params = if Keyword.has_key?(opts, :data), do: Map.put(params, :data, Keyword.fetch!(opts, :data)), else: params
    EVMTransaction.sign_transfer(params)
  end

  defp unsigned_payload do
    {:ok, to_bin} = Onchain.Address.validate(@recipient)
    {:ok, calldata_hex} = Onchain.ABI.encode_call("transfer(address,uint256)", [to_bin, @amount])
    calldata = Onchain.Hex.decode!(calldata_hex)

    {:ok, unsigned} =
      Onchain.Signer.build_transaction(@token, calldata,
        nonce: 0,
        chain_id: @chain_id,
        gas_limit: 100_000,
        max_fee_per_gas: {30, :gwei},
        max_priority_fee_per_gas: {2, :gwei}
      )

    raw = unsigned |> Cartouche.Transaction.V2.encode() |> Onchain.Hex.encode()
    %{"type" => "transaction", "signature" => raw}
  end

  defp stub_broadcast(hash) do
    Req.Test.stub(EVM, fn conn ->
      rpc_dispatch(conn, %{
        "eth_sendRawTransaction" => hash,
        "eth_getTransactionReceipt" => receipt_with_transfer(hash)
      })
    end)
  end

  defp receipt_with_transfer(hash) do
    sender_hex = strip_0x(@sender)
    recipient_hex = strip_0x(@recipient)

    %{
      "transactionHash" => hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => @sender,
      "to" => @token,
      "logs" => [
        %{
          "address" => @token,
          "topics" => [
            @transfer_topic,
            "0x" <> String.duplicate("0", 24) <> String.downcase(sender_hex),
            "0x" <> String.duplicate("0", 24) <> String.downcase(recipient_hex)
          ],
          "data" => @amount_hex,
          "blockNumber" => "0x1",
          "transactionHash" => hash,
          "logIndex" => "0x0"
        }
      ]
    }
  end

  defp read_request(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    {request["method"], request["id"], conn}
  end

  defp rpc_json(conn, id, key, value) do
    Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, key => value})
  end

  defp rpc_dispatch(conn, results_by_method) do
    {method, id, conn} = read_request(conn)
    rpc_json(conn, id, "result", Map.fetch!(results_by_method, method))
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x("0X" <> rest), do: rest
  defp strip_0x(hex), do: hex

  defp future_expires do
    DateTime.utc_now() |> DateTime.shift(minute: 5) |> DateTime.to_iso8601()
  end

  defp past_expires do
    DateTime.utc_now() |> DateTime.shift(minute: -1) |> DateTime.to_iso8601()
  end
end
