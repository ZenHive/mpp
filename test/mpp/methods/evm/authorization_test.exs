defmodule MPP.Methods.EVM.AuthorizationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Methods.EVM.Authorization
  alias MPP.Test.EVMAuthorization
  alias MPP.Test.RPCShapes
  alias Onchain.Address
  alias Onchain.Typed
  alias Onchain.Typed.Domain

  @rpc_url "https://mainnet.infura.io/v3/test"
  @chain_id 1
  @token "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @amount "1000000"
  @challenge_id "aB3cDeF4gHiJkLmN"
  @realm "api.example.com"
  @name "USD Coin"
  @version "2"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  # Observed live on Ethereum Sepolia USDC (0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
  # 2026-08-19 via DOMAIN_SEPARATOR().
  @sepolia_usdc "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @sepolia_usdc_domain "0xb90e5057db141a932946e64d09ccb7ffc9b00bd79fec26f698d29af0c83320a6"
  # Observed live: keccak256("aB3cDeF4gHiJkLmN" <> "api.example.com")
  @spec_example_challenge_hash "0x899e3a8fe6830644e150b972d4ba1fce69bcdf0bf9ea7f13d57cada71c6f281d"

  describe "challenge_hash/2" do
    test "matches draft-evm-charge packed id||realm and the live keccak sample" do
      assert Authorization.challenge_hash(@challenge_id, @realm) == @spec_example_challenge_hash
    end

    test "changes when either binding field changes" do
      refute Authorization.challenge_hash("other", @realm) == @spec_example_challenge_hash
      refute Authorization.challenge_hash(@challenge_id, "other.example.com") == @spec_example_challenge_hash
    end

    test "nonce_contract/0 is native challenge_hash, distinct from x402" do
      assert Authorization.nonce_contract() == :challenge_hash
    end
  end

  describe "Sepolia USDC EIP-712 domain" do
    test "Onchain domain separator matches the live Circle DOMAIN_SEPARATOR" do
      {:ok, verifying} = Address.validate(@sepolia_usdc)

      typed = %Typed{
        domain: %Domain{
          name: "USDC",
          version: "2",
          chain_id: 11_155_111,
          verifying_contract: verifying
        },
        types: %{"TransferWithAuthorization" => %Onchain.Typed.Type{fields: [{"from", :address}]}},
        value: %{"from" => verifying}
      }

      assert Onchain.Hex.encode(Typed.domain_seperator(typed)) == @sepolia_usdc_domain
    end
  end

  describe "offered?/1" do
    test "is false without a settlement key" do
      refute Authorization.offered?(charge())
    end

    test "is true for known mainnet USDC when private_key is configured" do
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert Authorization.offered?(charge)
    end

    test "is true for a custom token when authorization domain and key are set" do
      charge =
        charge(%{
          "private_key" => EVMAuthorization.private_key(),
          "authorization" => %{"name" => "USDC", "version" => "2"}
        })

      charge = %{charge | currency: "0x1111111111111111111111111111111111111111"}
      assert Authorization.offered?(charge)
    end

    test "is false for native ETH" do
      {:ok, eth} = Charge.new(amount: @amount, currency: "ETH", recipient: @recipient)

      eth = %{
        eth
        | method_details: %{
            "chain_id" => @chain_id,
            "private_key" => EVMAuthorization.private_key()
          }
      }

      refute Authorization.offered?(eth)
    end

    test "is false when splits are present" do
      charge =
        charge(%{
          "private_key" => EVMAuthorization.private_key(),
          "splits" => [%{"recipient" => @recipient, "amount" => "1"}]
        })

      refute Authorization.offered?(charge)
    end
  end

  describe "validate_config!/1" do
    test "accepts nil and a complete domain map" do
      assert :ok = Authorization.validate_config!(nil)
      assert :ok = Authorization.validate_config!(%{"name" => "USDC", "version" => "2"})
    end

    test "raises on a partial or non-map value" do
      assert_raise ArgumentError, ~r/name/, fn ->
        Authorization.validate_config!(%{"name" => "USDC"})
      end

      assert_raise ArgumentError, ~r/name/, fn ->
        Authorization.validate_config!("USDC")
      end
    end
  end

  describe "parse_payload/1" do
    test "accepts a well-formed authorization payload" do
      payload = signed_payload()
      assert {:ok, parsed} = Authorization.parse_payload(payload)
      assert parsed.from == String.downcase(EVMAuthorization.signer_address())
      assert parsed.value == @amount
      assert parsed.nonce == @spec_example_challenge_hash
    end

    test "rejects a missing type" do
      assert {:error, %Errors{} = error} = Authorization.parse_payload(%{"from" => EVMAuthorization.signer_address()})
      assert error.type =~ "invalid-payload"
    end

    test "rejects a malformed nonce" do
      payload = %{signed_payload() | "nonce" => "0xdead"}
      assert {:error, %Errors{} = error} = Authorization.parse_payload(payload)
      assert error.detail =~ "nonce"
    end

    test "rejects a malformed signature" do
      payload = %{signed_payload() | "signature" => "0xdead"}
      assert {:error, %Errors{} = error} = Authorization.parse_payload(payload)
      assert error.detail =~ "signature"
    end

    test "rejects missing required fields" do
      for key <- ["from", "to", "value", "validAfter", "validBefore", "nonce", "signature"] do
        payload = Map.delete(signed_payload(), key)
        assert {:error, %Errors{} = error} = Authorization.parse_payload(payload)
        assert error.type =~ "invalid-payload"
      end
    end

    test "rejects a non-address from field" do
      payload = %{signed_payload() | "from" => "not-an-address"}
      assert {:error, %Errors{} = error} = Authorization.parse_payload(payload)
      assert error.detail =~ "from"
    end

    test "rejects a non-integer value" do
      payload = %{signed_payload() | "value" => "1.5"}
      assert {:error, %Errors{} = error} = Authorization.parse_payload(payload)
      assert error.detail =~ "value"
    end

    test "rejects a non-integer validBefore" do
      payload = %{signed_payload() | "validBefore" => "soon"}
      assert {:error, %Errors{} = error} = Authorization.parse_payload(payload)
      assert error.detail =~ "validBefore"
    end

    test "accepts integer validAfter/validBefore" do
      payload = signed_payload() |> Map.put("validAfter", 0) |> Map.put("validBefore", System.system_time(:second) + 60)
      assert {:ok, parsed} = Authorization.parse_payload(payload)
      assert parsed.valid_after == 0
    end
  end

  describe "sign_transfer/2 and recover_authorization/5" do
    test "signs and recovers a well-formed authorization with a caller-supplied nonce" do
      assert {:ok, signature} = Authorization.sign_transfer(sign_params(), EVMAuthorization.private_key())
      {:ok, parsed} = Authorization.parse_payload(%{signed_payload() | "signature" => signature})

      assert {:ok, recovered} =
               Authorization.recover_authorization(parsed, @token, @chain_id, @name, @version)

      assert Address.equal?(recovered, EVMAuthorization.signer_address())
    end

    test "accepts string uints for value and the validity window" do
      params =
        sign_params(%{
          value: @amount,
          valid_after: "0",
          valid_before: Integer.to_string(System.system_time(:second) + 60)
        })

      assert {:ok, signature} = Authorization.sign_transfer(params, EVMAuthorization.private_key())
      assert String.starts_with?(signature, "0x")
    end

    test "rejects a missing required field" do
      assert {:error, %Errors{} = error} =
               Authorization.sign_transfer(Map.delete(sign_params(), :from), EVMAuthorization.private_key())

      assert error.detail =~ "from"
    end

    test "rejects an invalid chain_id" do
      assert {:error, %Errors{} = error} =
               Authorization.sign_transfer(sign_params(%{chain_id: 0}), EVMAuthorization.private_key())

      assert error.detail =~ "chain_id"
    end

    test "rejects a non-numeric value string" do
      assert {:error, %Errors{} = error} =
               Authorization.sign_transfer(sign_params(%{value: "1.5"}), EVMAuthorization.private_key())

      assert error.detail =~ "value"
    end

    test "rejects a non-integer value" do
      assert {:error, %Errors{} = error} =
               Authorization.sign_transfer(sign_params(%{value: :nope}), EVMAuthorization.private_key())

      assert error.detail =~ "value"
    end

    test "rejects an invalid from address" do
      assert {:error, %Errors{} = error} =
               Authorization.sign_transfer(sign_params(%{from: "not-an-address"}), EVMAuthorization.private_key())

      assert error.detail =~ "typed-data"
    end

    test "rejects a private key that does not recover to from" do
      assert {:error, %Errors{} = error} =
               Authorization.sign_transfer(sign_params(%{from: @recipient}), EVMAuthorization.private_key())

      assert error.detail =~ "Unable to sign"
    end

    test "recover_authorization rejects invalid typed-data fields" do
      {:ok, parsed} = Authorization.parse_payload(signed_payload())

      assert {:error, %Errors{} = error} =
               Authorization.recover_authorization(parsed, "not-a-token", @chain_id, @name, @version)

      assert error.detail =~ "typed-data"
    end

    test "recover_authorization rejects an invalid signature v byte" do
      {:ok, parsed} = Authorization.parse_payload(signed_payload())
      parsed = %{parsed | signature: "0x" <> String.duplicate("00", 64) <> "00"}

      assert {:error, %Errors{} = error} =
               Authorization.recover_authorization(parsed, @token, @chain_id, @name, @version)

      assert error.detail =~ "signature"
    end

    test "recover_authorization rejects an unrecoverable r/s pair" do
      {:ok, parsed} = Authorization.parse_payload(signed_payload())
      parsed = %{parsed | signature: "0x" <> String.duplicate("00", 64) <> "1b"}

      assert {:error, %Errors{} = error} =
               Authorization.recover_authorization(parsed, @token, @chain_id, @name, @version)

      assert error.detail =~ "signature recovery failed"
    end
  end

  describe "settle/2" do
    test "rejects splits" do
      charge =
        charge(%{
          "private_key" => EVMAuthorization.private_key(),
          "splits" => [%{"recipient" => @recipient, "amount" => "1"}]
        })

      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "splits"
    end

    test "rejects a recipient mismatch" do
      payload = signed_payload(to: "0x" <> String.duplicate("99", 20))
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge())
      assert error.detail =~ "recipient"
    end

    test "rejects an amount mismatch" do
      payload = signed_payload(value: 7)
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge())
      assert error.detail =~ "amount"
    end

    test "rejects a nonce that is not the challengeHash" do
      payload = signed_payload(nonce: "0x" <> String.duplicate("11", 32))
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge())
      assert error.detail =~ "challengeHash"
    end

    test "accepts a caller-supplied expected nonce instead of challengeHash" do
      nonce = "0x" <> String.duplicate("22", 32)
      payload = signed_payload(nonce: nonce)
      stub_settle_success()
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})

      assert {:ok, @tx_hash} = Authorization.settle(payload, charge, expected_nonce: nonce)
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge)
      assert error.detail =~ "challengeHash"
    end

    test "rejects an expected nonce that is not the signed nonce" do
      payload = signed_payload()
      other = "0x" <> String.duplicate("33", 32)
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})

      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge, expected_nonce: other)
      assert error.detail =~ "bound challenge"
    end

    test "rejects an expired validity window without RPC" do
      payload = signed_payload(valid_before: 1)
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge())
      assert error.detail =~ "expired"
    end

    test "rejects a not-yet-valid window without RPC" do
      now = System.system_time(:second)
      payload = signed_payload(valid_after: now + 86_400, valid_before: now + 172_800)
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge())
      assert error.detail =~ "not yet valid"
    end

    test "rejects a signature that does not recover to from" do
      payload = signed_payload()
      payload = %{payload | "from" => @recipient}
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge)
      assert error.detail =~ "signature"
    end

    test "rejects a missing settlement key" do
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge())
      assert error.detail =~ "private_key"
    end

    test "rejects an unknown token without an authorization domain" do
      charge =
        %{"private_key" => EVMAuthorization.private_key()}
        |> charge()
        |> Map.put(:currency, "0x1111111111111111111111111111111111111111")

      payload = signed_payload(currency: charge.currency, name: "Nope")
      assert {:error, %Errors{} = error} = Authorization.settle(payload, charge)
      assert error.detail =~ "EIP-3009"
    end

    test "rejects a used nonce from the live-shaped authorizationState response" do
      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{"eth_call" => used_state()})
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "already used"
    end

    test "broadcasts a valid unused authorization and returns the tx hash" do
      stub_settle_success()
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:ok, @tx_hash} = Authorization.settle(signed_payload(), charge)
    end

    test "queries the pending account nonce before broadcast" do
      {:ok, seen} = Agent.start_link(fn -> nil end)

      Req.Test.stub(EVM, fn conn ->
        {request, conn} = read_rpc(conn)
        method = request["method"]
        id = request["id"]

        if method == "eth_getTransactionCount" do
          Agent.update(seen, fn _ -> request["params"] end)
        end

        result =
          case method do
            "eth_call" -> unused_state()
            "eth_getTransactionCount" -> "0x1"
            "eth_estimateGas" -> "0x186a0"
            "eth_sendRawTransaction" -> @tx_hash
            "eth_getTransactionReceipt" -> receipt_with_transfer()
          end

        rpc_json(conn, id, "result", result)
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:ok, @tx_hash} = Authorization.settle(signed_payload(), charge)
      assert List.last(Agent.get(seen, & &1)) == "pending"
    end

    test "maps a reverted settlement receipt to settlement-failed" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" ->
            rpc_json(conn, id, "result", unused_state())

          "eth_getTransactionCount" ->
            rpc_json(conn, id, "result", "0x1")

          "eth_estimateGas" ->
            rpc_json(conn, id, "result", "0x186a0")

          "eth_sendRawTransaction" ->
            rpc_json(conn, id, "result", @tx_hash)

          "eth_getTransactionReceipt" ->
            rpc_json(
              conn,
              id,
              "result",
              RPCShapes.receipt(%{
                "transactionHash" => @tx_hash,
                "blockNumber" => "0x1",
                "status" => "0x0",
                "from" => EVMAuthorization.signer_address(),
                "to" => @token,
                "logs" => []
              })
            )
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.type =~ "settlement-failed"
      assert error.detail =~ "reverted"
    end

    test "maps the observed FiatTokenV2 used-or-canceled estimate revert to already used" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" ->
            rpc_json(conn, id, "result", unused_state())

          "eth_getTransactionCount" ->
            rpc_json(conn, id, "result", "0x1")

          "eth_estimateGas" ->
            rpc_json(conn, id, "error", %{
              "code" => 3,
              "message" => "execution reverted: FiatTokenV2: authorization is used or canceled"
            })
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "already used"
    end

    test "rejects native ETH currency" do
      {:ok, eth} = Charge.new(amount: @amount, currency: "ETH", recipient: @recipient)
      eth = %{eth | method_details: charge(%{"private_key" => EVMAuthorization.private_key()}).method_details}
      payload = signed_payload()
      assert {:error, %Errors{} = error} = Authorization.settle(payload, eth)
      assert error.detail =~ "EIP-3009 token"
    end

    test "rejects a missing challenge binding" do
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      charge = %{charge | method_details: Map.delete(charge.method_details, "challenge_id")}
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "challenge_id"
    end

    test "rejects a missing rpc_url after local checks pass" do
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      charge = %{charge | method_details: Map.delete(charge.method_details, "rpc_url")}
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "rpc_url"
    end

    test "rejects a missing chain_id" do
      charge =
        charge(%{
          "private_key" => EVMAuthorization.private_key(),
          "authorization" => %{"name" => @name, "version" => @version}
        })

      charge = %{charge | method_details: Map.delete(charge.method_details, "chain_id")}
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "chain_id"
    end

    test "surfaces an authorizationState RPC failure" do
      Req.Test.stub(EVM, fn conn ->
        {_method, id, conn} = read_request(conn)
        rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "server error"})
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail == "An internal payment error occurred."
    end

    test "surfaces a receipt-fetch RPC failure after broadcast" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" -> rpc_json(conn, id, "result", unused_state())
          "eth_getTransactionCount" -> rpc_json(conn, id, "result", "0x1")
          "eth_estimateGas" -> rpc_json(conn, id, "result", "0x186a0")
          "eth_sendRawTransaction" -> rpc_json(conn, id, "result", @tx_hash)
          "eth_getTransactionReceipt" -> rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "boom"})
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail == "An internal payment error occurred."
    end

    test "offered?/1 is false when chain_id is missing even with a settlement key" do
      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      charge = %{charge | method_details: Map.delete(charge.method_details, "chain_id")}
      refute Authorization.offered?(charge)
    end

    test "accepts a matching did:pkh source" do
      stub_settle_success()
      from = EVMAuthorization.signer_address()
      source = "did:pkh:eip155:#{@chain_id}:#{from}"
      charge = charge(%{"private_key" => EVMAuthorization.private_key(), "credential_source" => source})
      assert {:ok, @tx_hash} = Authorization.settle(signed_payload(), charge)
    end

    test "rejects a source that names a different address" do
      source = "did:pkh:eip155:#{@chain_id}:#{@recipient}"
      charge = charge(%{"private_key" => EVMAuthorization.private_key(), "credential_source" => source})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "source"
    end

    test "rejects a malformed credential source" do
      charge = charge(%{"private_key" => EVMAuthorization.private_key(), "credential_source" => "not-a-did"})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "source"
    end

    test "rejects a non-string credential source" do
      charge = charge(%{"private_key" => EVMAuthorization.private_key(), "credential_source" => 1})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail =~ "source"
    end

    test "applies configured EIP-1559 fees on the success path" do
      stub_settle_success()

      charge =
        charge(%{
          "private_key" => EVMAuthorization.private_key(),
          "max_fee_per_gas" => 2_000_000_000,
          "max_priority_fee_per_gas" => 1_000_000_000
        })

      assert {:ok, @tx_hash} = Authorization.settle(signed_payload(), charge)
    end

    test "maps the observed ECRecover high-s revert from estimateGas" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" ->
            rpc_json(conn, id, "result", unused_state())

          "eth_getTransactionCount" ->
            rpc_json(conn, id, "result", "0x1")

          "eth_estimateGas" ->
            rpc_json(conn, id, "error", %{
              "code" => 3,
              "message" => "execution reverted: ECRecover: invalid signature 's' value"
            })
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.type =~ "settlement-failed"
      assert error.detail == "ECRecover: invalid signature 's' value"
    end

    test "surfaces a generic RPC failure from sendRawTransaction" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" -> rpc_json(conn, id, "result", unused_state())
          "eth_getTransactionCount" -> rpc_json(conn, id, "result", "0x1")
          "eth_estimateGas" -> rpc_json(conn, id, "result", "0x186a0")
          "eth_sendRawTransaction" -> rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "nonce too low"})
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail == "An internal payment error occurred."
    end

    test "polls until the settlement receipt appears" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" ->
            rpc_json(conn, id, "result", unused_state())

          "eth_getTransactionCount" ->
            rpc_json(conn, id, "result", "0x1")

          "eth_estimateGas" ->
            rpc_json(conn, id, "result", "0x186a0")

          "eth_sendRawTransaction" ->
            rpc_json(conn, id, "result", @tx_hash)

          "eth_getTransactionReceipt" ->
            n = Agent.get_and_update(attempts, fn i -> {i, i + 1} end)
            result = if n == 0, do: nil, else: receipt_with_transfer()
            rpc_json(conn, id, "result", result)
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:ok, @tx_hash} = Authorization.settle(signed_payload(), charge)
    end

    test "maps the observed expired FiatTokenV2 revert from estimateGas" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" ->
            rpc_json(conn, id, "result", unused_state())

          "eth_getTransactionCount" ->
            rpc_json(conn, id, "result", "0x1")

          "eth_estimateGas" ->
            rpc_json(conn, id, "error", %{
              "code" => 3,
              "message" => "execution reverted: FiatTokenV2: authorization is expired"
            })
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.type =~ "settlement-failed"
      assert error.detail == "FiatTokenV2: authorization is expired"
    end

    test "surfaces a getTransactionCount RPC failure during broadcast" do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_call" -> rpc_json(conn, id, "result", unused_state())
          "eth_getTransactionCount" -> rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "boom"})
        end
      end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail == "An internal payment error occurred."
    end

    test "surfaces an RPC transport failure from authorizationState" do
      Req.Test.stub(EVM, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      charge = charge(%{"private_key" => EVMAuthorization.private_key()})
      assert {:error, %Errors{} = error} = Authorization.settle(signed_payload(), charge)
      assert error.detail == "An internal payment error occurred."
      refute error.detail =~ "econnrefused"
    end
  end

  describe "custom settlement invariants" do
    test "AUTH-CUSTOM-VALIDATE: invalid authorization never invokes the callback" do
      callback = fn _, _ -> flunk("callback invoked for invalid credential") end
      base = charge(%{"settle_authorization" => {callback, :secret}})

      for {payload, config, detail} <- [
            {signed_payload(chain_id: 2), %{}, "signature"},
            {signed_payload(), %{"authorization" => %{"name" => "wrong", "version" => "2"}}, "signature"},
            {signed_payload(recipient: EVMAuthorization.signer_address()), %{}, "recipient"},
            {signed_payload(amount: "2"), %{}, "amount"},
            {signed_payload(nonce: "0x" <> String.duplicate("ab", 32)), %{}, "nonce"},
            {signed_payload(valid_after: System.system_time(:second) + 100), %{}, "not yet valid"},
            {signed_payload(valid_before: System.system_time(:second)), %{}, "expired"},
            {signed_payload(), %{"credential_source" => "invalid"}, "source"},
            {Map.put(signed_payload(), "signature", "bad"), %{}, "signature"}
          ] do
        c = %{base | method_details: Map.merge(base.method_details, config)}
        assert {:error, %Errors{detail: error}} = EVM.verify(payload, c)
        assert error =~ detail
      end
    end

    test "AUTH-CUSTOM-VALIDATE: chain mismatch and consumed nonce never invoke callback" do
      callback = fn _, _ -> flunk("callback invoked") end
      c = charge(%{"settle_authorization" => {callback, nil}})
      stub_custom(receipt_with_authorization(), %{"eth_chainId" => "0x2"})
      assert {:error, %Errors{detail: "Settlement RPC chain mismatch"}} = EVM.verify(signed_payload(), c)
      stub_custom(receipt_with_authorization(), %{"eth_call" => used_state()})
      assert {:error, %Errors{detail: "Authorization already used"}} = EVM.verify(signed_payload(), c)
    end

    test "callback receives only validated input and caller configuration without an MPP key" do
      caller = self()

      callback = fn input, configuration ->
        send(caller, {:submitted, input, configuration})
        {:ok, @tx_hash}
      end

      c = charge(%{"settle_authorization" => {callback, %{relayer: :external}}})
      stub_custom(receipt_with_authorization())
      assert Authorization.offered?(c)
      assert {:ok, %MPP.Receipt{reference: @tx_hash}} = EVM.verify(signed_payload(), c)

      assert_receive {:submitted, %{authorization: parsed, currency: @token, chain_id: @chain_id} = input,
                      %{relayer: :external}}

      assert map_size(input) == 3
      assert parsed.nonce == @spec_example_challenge_hash
      assert parsed.value == @amount
    end

    test "callback and configuration never enter the public challenge" do
      callback = fn _, _ -> {:ok, @tx_hash} end

      config =
        MPP.Plug.init(
          secret_key: String.duplicate("s", 32),
          realm: @realm,
          method: EVM,
          amount: @amount,
          currency: @token,
          recipient: @recipient,
          method_config: charge(%{"settle_authorization" => {callback, "server-only-secret"}}).method_details
        )

      conn = MPP.Plug.call(Plug.Test.conn(:get, "/"), config)
      assert conn.status == 402
      [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = MPP.Headers.parse_challenge(header)
      request = Base.url_decode64!(challenge.request, padding: false)
      assert Jason.decode!(request)["methodDetails"]["credentialTypes"] == ["authorization", "hash"]
      refute request =~ "settle_authorization"
      refute request =~ "server-only-secret"
    end

    test "AUTH-CUSTOM-NO-FALLBACK: errors and malformed returns never submit directly" do
      for result <- [{:error, :provider_down}, :ok, {:ok, "garbage"}, {:ok, nil}] do
        stub_custom(receipt_with_authorization())

        c =
          charge(%{
            "private_key" => EVMAuthorization.private_key(),
            "settle_authorization" => {fn _, _ -> result end, nil}
          })

        assert {:error, %Errors{}} = EVM.verify(signed_payload(), c)
      end
    end

    test "AUTH-CUSTOM-NO-FALLBACK: callback exceptions propagate without direct submission" do
      stub_custom(receipt_with_authorization())

      c =
        charge(%{
          "private_key" => EVMAuthorization.private_key(),
          "settle_authorization" => {fn _, _ -> raise "relayer unavailable" end, nil}
        })

      assert_raise RuntimeError, "relayer unavailable", fn -> EVM.verify(signed_payload(), c) end
    end

    test "malformed callback config is rejected even when a direct key exists" do
      for bad <- [:invalid, {fn _ -> :ok end, nil}, {nil, :config}] do
        config = %{"private_key" => EVMAuthorization.private_key(), "settle_authorization" => bad}
        refute Authorization.offered?(charge(config))

        assert_raise ArgumentError, ~r/settle_authorization/, fn ->
          EVM.validate_config!(charge(config).method_details)
        end

        assert {:error, %Errors{detail: "Invalid settle_authorization configuration"}} =
                 EVM.verify(signed_payload(), charge(config))
      end
    end

    test "AUTH-CUSTOM-EXACT: unconfirmed, reverted and unrelated success cannot grant receipt" do
      c = charge(%{"settle_authorization" => {fn _, _ -> {:ok, @tx_hash} end, nil}})

      for {receipt, detail, type} <- [
            {nil, "not confirmed", "server-error"},
            {Map.put(receipt_with_authorization(), "status", "0x0"), "reverted", "settlement-failed"},
            {Map.put(receipt_with_authorization(), "blockNumber", nil), "An internal payment error occurred.",
             "internal-payment-error"},
            {receipt_with_transfer(), "AuthorizationUsed", "verification-failed"},
            {Map.put(receipt_with_authorization(), "logs", []), "AuthorizationUsed", "verification-failed"}
          ] do
        stub_custom(receipt)

        assert {:error, %Errors{detail: settlement_error, type: settlement_type}} =
                 Authorization.settle(signed_payload(), c)

        assert settlement_error =~ detail
        assert settlement_type =~ type
        assert {:error, %Errors{detail: error, type: verify_type}} = EVM.verify(signed_payload(), c)
        assert error =~ detail
        assert verify_type =~ type
      end
    end

    test "AUTH-CUSTOM-EXACT: an omitted removed flag still matches AuthorizationUsed" do
      c = charge(%{"settle_authorization" => {fn _, _ -> {:ok, @tx_hash} end, nil}})

      receipt =
        Map.update!(receipt_with_authorization(), "logs", fn logs ->
          Enum.map(logs, &Map.delete(&1, "removed"))
        end)

      stub_custom(receipt)
      assert {:ok, %MPP.Receipt{reference: @tx_hash}} = EVM.verify(signed_payload(), c)
    end

    test "AUTH-CUSTOM-EXACT: nonce, authorizer and token event bindings are mandatory" do
      c = charge(%{"settle_authorization" => {fn _, _ -> {:ok, @tx_hash} end, nil}})

      for change <- [
            fn event -> Map.put(event, "address", @recipient) end,
            fn event -> Map.update!(event, "topics", &List.replace_at(&1, 1, "0x" <> String.duplicate("00", 32))) end,
            fn event -> Map.update!(event, "topics", &List.replace_at(&1, 2, "0x" <> String.duplicate("00", 32))) end,
            fn event -> Map.put(event, "removed", true) end
          ] do
        receipt = Map.update!(receipt_with_authorization(), "logs", fn [auth | rest] -> [change.(auth) | rest] end)
        stub_custom(receipt)
        assert {:error, %Errors{detail: error}} = EVM.verify(signed_payload(), c)
        assert error =~ "AuthorizationUsed"
      end
    end

    test "AUTH-CUSTOM-EXACT: payment token, payer, recipient and exact amount remain mandatory" do
      c = charge(%{"settle_authorization" => {fn _, _ -> {:ok, @tx_hash} end, nil}})

      for change <- [
            fn event -> Map.put(event, "address", @recipient) end,
            fn event -> Map.update!(event, "topics", &List.replace_at(&1, 1, "0x" <> String.duplicate("00", 32))) end,
            fn event -> Map.update!(event, "topics", &List.replace_at(&1, 2, "0x" <> String.duplicate("00", 32))) end,
            fn event -> Map.put(event, "data", "0x" <> String.duplicate("00", 32)) end
          ] do
        receipt = Map.update!(receipt_with_authorization(), "logs", fn [auth, transfer] -> [auth, change.(transfer)] end)
        stub_custom(receipt)

        assert {:error, %Errors{detail: "No matching Transfer event found in transaction"}} =
                 EVM.verify(signed_payload(), c)
      end
    end

    property "AUTH-CUSTOM-VALIDATE: any unequal signed amount is rejected before submission" do
      check all(amount <- integer(1..1_000_000_000), amount != 1_000_000, max_runs: 25) do
        callback = fn _, _ -> flunk("unequal amount submitted") end
        c = charge(%{"settle_authorization" => {callback, nil}})

        assert {:error, %Errors{detail: "Authorization amount does not match charge amount"}} =
                 EVM.verify(signed_payload(amount: Integer.to_string(amount)), c)
      end
    end

    test "AUTH-CUSTOM-REPLAY: simultaneous callbacks cannot grant two receipts" do
      owner = self()

      callback = fn _, _ ->
        send(owner, {:ready, self()})

        receive do
          :submit -> {:ok, @tx_hash}
        after
          1000 -> flunk("submission barrier timed out")
        end
      end

      store = {MPP.Tempo.ConCacheStore, key_prefix: "custom-" <> Integer.to_string(System.unique_integer([:positive]))}
      c = charge(%{"settle_authorization" => {callback, nil}, "store" => store})
      stub_custom(receipt_with_authorization())
      tasks = for _ <- 1..2, do: Task.async(fn -> EVM.verify(signed_payload(), c) end)
      assert_receive {:ready, first}
      assert_receive {:ready, second}
      send(first, :submit)
      send(second, :submit)
      results = Enum.map(tasks, &Task.await/1)
      assert Enum.count(results, &match?({:ok, %MPP.Receipt{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Errors{detail: "Transaction hash already used"}}, &1)) == 1
      stub_custom(receipt_with_authorization(), %{"eth_call" => used_state()})
      assert {:error, %Errors{detail: "Authorization already used"}} = EVM.verify(signed_payload(), c)
      refute_receive {:ready, _}
    end

    test "RPC errors do not become callback successes" do
      c = charge(%{"settle_authorization" => {fn _, _ -> {:ok, @tx_hash} end, nil}})

      for failing <- ["eth_chainId", "eth_getTransactionReceipt"] do
        Req.Test.stub(EVM, fn conn ->
          {method, id, conn} = read_request(conn)

          if method == failing do
            rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "provider unavailable"})
          else
            rpc_json(conn, id, "result", Map.fetch!(%{"eth_call" => unused_state(), "eth_chainId" => "0x1"}, method))
          end
        end)

        assert {:error, %Errors{detail: error}} = EVM.verify(signed_payload(), c)
        assert error == "An internal payment error occurred."
      end
    end
  end

  defp stub_custom(receipt, overrides \\ %{}) do
    Req.Test.stub(EVM, fn conn ->
      rpc_dispatch(
        conn,
        Map.merge(
          %{"eth_call" => unused_state(), "eth_chainId" => "0x1", "eth_getTransactionReceipt" => receipt},
          overrides
        )
      )
    end)
  end

  defp receipt_with_authorization do
    receipt = receipt_with_transfer()

    event = %{
      "address" => @token,
      "topics" => [
        Onchain.Hex.encode(Onchain.Hash.keccak("AuthorizationUsed(address,bytes32)")),
        "0x" <>
          String.duplicate("0", 24) <> String.replace_prefix(String.downcase(EVMAuthorization.signer_address()), "0x", ""),
        @spec_example_challenge_hash
      ],
      "data" => "0x",
      "removed" => false,
      "blockNumber" => "0x1",
      "transactionHash" => @tx_hash,
      "logIndex" => "0x1"
    }

    Map.update!(receipt, "logs", &[event | &1])
  end

  defp signed_payload(overrides \\ []) do
    params =
      Map.merge(
        %{
          currency: @token,
          name: @name,
          version: @version,
          chain_id: @chain_id,
          recipient: @recipient,
          amount: @amount,
          challenge_id: @challenge_id,
          realm: @realm
        },
        Map.new(overrides)
      )

    EVMAuthorization.payload(params)
  end

  defp sign_params(overrides \\ %{}) do
    Map.merge(
      %{
        currency: @token,
        name: @name,
        version: @version,
        chain_id: @chain_id,
        from: EVMAuthorization.signer_address(),
        to: @recipient,
        value: String.to_integer(@amount),
        valid_after: 0,
        valid_before: System.system_time(:second) + 3600,
        nonce: @spec_example_challenge_hash
      },
      overrides
    )
  end

  defp charge(extra \\ %{}) do
    {:ok, charge} = Charge.new(amount: @amount, currency: @token, recipient: @recipient)

    %{
      charge
      | method_details:
          Map.merge(
            %{
              "rpc_url" => @rpc_url,
              "chain_id" => @chain_id,
              "req_options" => [plug: {Req.Test, EVM}],
              "store" => false,
              "challenge_id" => @challenge_id,
              "realm" => @realm
            },
            extra
          )
    }
  end

  defp stub_settle_success do
    Req.Test.stub(EVM, fn conn ->
      rpc_dispatch(conn, %{
        "eth_call" => unused_state(),
        "eth_getTransactionCount" => "0x1",
        "eth_estimateGas" => "0x186a0",
        "eth_sendRawTransaction" => @tx_hash,
        "eth_getTransactionReceipt" => receipt_with_transfer()
      })
    end)
  end

  defp unused_state, do: "0x" <> String.duplicate("0", 64)
  defp used_state, do: "0x" <> String.duplicate("0", 63) <> "1"

  defp read_request(conn) do
    {request, conn} = read_rpc(conn)
    {request["method"], request["id"], conn}
  end

  defp read_rpc(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp rpc_json(conn, id, key, value) do
    Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, key => value})
  end

  defp rpc_dispatch(conn, results_by_method) do
    {method, id, conn} = read_request(conn)
    rpc_json(conn, id, "result", Map.fetch!(results_by_method, method))
  end

  defp receipt_with_transfer do
    padded_sender =
      "0x" <> String.duplicate("0", 24) <> String.replace_prefix(EVMAuthorization.signer_address(), "0x", "")

    padded_recipient = "0x" <> String.duplicate("0", 24) <> String.replace_prefix(String.downcase(@recipient), "0x", "")

    RPCShapes.receipt(%{
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => EVMAuthorization.signer_address(),
      "to" => @token,
      "logs" => [
        %{
          "address" => @token,
          "topics" => [@transfer_topic, padded_sender, padded_recipient],
          "data" => "0x" <> String.duplicate("0", 58) <> "0f4240",
          "blockNumber" => "0x1",
          "transactionHash" => @tx_hash,
          "logIndex" => "0x0"
        }
      ]
    })
  end
end
