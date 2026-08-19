defmodule MPP.Methods.EVMTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

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
  @property_runs 25
  @evm_address_bytes 20

  # draft-evm-charge-00.md:235 — canonical Permit2 deployment
  @canonical_permit2 "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  # draft-evm-charge-00.md:302-303 — valid credentialTypes values
  @spec_credential_types ~w(permit2 authorization transaction hash)
  # draft-evm-charge-00.md:1244-1253 — decoded challenge request example
  @spec_example_request %{
    "amount" => "1000000000000000000",
    "currency" => "0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7",
    "recipient" => "0x742d35Cc6634C0532925a3b844Bc9e7595f8fE00",
    "methodDetails" => %{
      "chainId" => 4326,
      "credentialTypes" => ["permit2"]
    }
  }

  # --- Dedup test stores (EVM-scoped names — reuse the MPP.Tempo.Store behaviour) ---

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

    def keys, do: Agent.get(__MODULE__, &Map.keys/1)
  end

  # Stateless failure stores exercising each dedup error branch.
  defmodule GetFailStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: {:error, :connection_lost}
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: :ok
  end

  defmodule AlreadyExistsStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: {:error, :already_exists}
  end

  defmodule AtomicFailStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: {:error, :unexpected_store_error}
  end

  setup do
    {:ok, charge} =
      Charge.new(
        amount: @amount,
        currency: @token_address,
        recipient: @recipient
      )

    # Simulate what Plug does: merge method_config into charge.method_details.
    # Dedup is on by default now; these verification-logic tests opt out
    # (`store: false`) so the app-started shared default store doesn't carry the
    # fixed @tx_hash across async tests. Dedup is covered by the dedicated
    # describes below (which override the store via with_store/2).
    charge = %{
      charge
      | method_details: %{
          "rpc_url" => @rpc_url,
          "chain_id" => @chain_id,
          "req_options" => [plug: {Req.Test, EVM}],
          "store" => false
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
    # draft-evm-charge-00.md:276-291
    # (tempoxyz/mpp-specs@3fa03a9385fb4cc65b05815ba4acdaf5b0d9766a):
    # methodDetails.chainId is REQUIRED (EIP-155 chain ID).
    test "returns :ok with valid config" do
      assert :ok = EVM.validate_config!(required_config())
    end

    test "raises on missing rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        EVM.validate_config!(%{"chain_id" => @chain_id})
      end
    end

    test "raises on nil rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        EVM.validate_config!(required_config(%{"rpc_url" => nil}))
      end
    end

    test "raises on missing chain_id" do
      assert_raise ArgumentError, ~r/chain_id/, fn ->
        EVM.validate_config!(%{"rpc_url" => @rpc_url})
      end
    end

    test "raises on nil chain_id" do
      assert_raise ArgumentError, ~r/chain_id/, fn ->
        EVM.validate_config!(required_config(%{"chain_id" => nil}))
      end
    end
  end

  describe "challenge_method_details/1" do
    test "returns chainId when chain_id is configured", %{charge: charge} do
      assert %{"chainId" => 1} = EVM.challenge_method_details(charge)
    end

    test "Plug.init rejects missing chain_id instead of emitting a 402 that omits chainId" do
      opts = [
        secret_key: "hmac-secret-for-evm-challenge-test",
        realm: "api.example.com",
        method: EVM,
        amount: @amount,
        currency: @token_address,
        recipient: @recipient,
        method_config: %{"rpc_url" => @rpc_url}
      ]

      assert_raise ArgumentError, ~r/chain_id/, fn ->
        PaymentPlug.init(opts)
      end
    end

    test "Plug.init rejects nil chain_id instead of emitting a 402 that omits chainId" do
      opts = [
        secret_key: "hmac-secret-for-evm-challenge-test",
        realm: "api.example.com",
        method: EVM,
        amount: @amount,
        currency: @token_address,
        recipient: @recipient,
        method_config: %{"rpc_url" => @rpc_url, "chain_id" => nil}
      ]

      assert_raise ArgumentError, ~r/chain_id/, fn ->
        PaymentPlug.init(opts)
      end
    end

    test "advertises exactly the credential types verify/2 accepts", %{charge: charge} do
      details = EVM.challenge_method_details(charge)

      assert details["credentialTypes"] == ["hash"]
      assert "hash" in EVM.credential_types()
      assert "authorization" in EVM.credential_types()
    end

    test "advertises authorization ahead of hash for known USDC when private_key is set", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "private_key", "0x" <> String.duplicate("11", 32))
      }

      details = EVM.challenge_method_details(charge)

      assert details["credentialTypes"] == ["authorization", "hash"]
      refute Map.has_key?(details, "private_key")
    end

    test "does not advertise authorization for native ETH even with a settlement key", %{charge: charge} do
      {:ok, eth} = Charge.new(amount: "1", currency: "ETH", recipient: @recipient)

      eth = %{
        eth
        | method_details: Map.put(charge.method_details, "private_key", "0x" <> String.duplicate("11", 32))
      }

      details = EVM.challenge_method_details(eth)
      assert details["credentialTypes"] == ["hash"]
    end

    test "defaults permit2Address to the canonical Permit2 deployment", %{charge: charge} do
      details = EVM.challenge_method_details(charge)

      assert details["permit2Address"] == @canonical_permit2
    end

    test "overrides permit2Address from method_config", %{charge: charge} do
      custom = "0x1111111111111111111111111111111111111111"
      charge = %{charge | method_details: Map.put(charge.method_details, "permit2_address", custom)}
      details = EVM.challenge_method_details(charge)

      assert details["permit2Address"] == custom
      refute Map.has_key?(details, "permit2_address")
    end

    test "handles nil method_details" do
      {:ok, charge} = Charge.new(amount: @amount, currency: @token_address)
      details = EVM.challenge_method_details(charge)

      assert details["credentialTypes"] == ["hash"]
      assert details["permit2Address"] == @canonical_permit2
    end

    test "does not leak server-only method_config keys", %{charge: charge} do
      details = EVM.challenge_method_details(charge)

      refute Map.has_key?(details, "rpc_url")
      refute Map.has_key?(details, "chain_id")
      refute Map.has_key?(details, "store")
      refute Map.has_key?(details, "req_options")
    end

    test "cross-validates methodDetails against the draft-evm-charge-00 example" do
      spec_details = @spec_example_request["methodDetails"]

      # Spec example uses camelCase wire keys; credentialTypes values are from the
      # registered set (draft-evm-charge-00.md:302-303). We advertise the hash-path
      # types rather than permit2, and always include the required permit2Address.
      assert Map.has_key?(spec_details, "chainId")
      assert Map.has_key?(spec_details, "credentialTypes")
      assert spec_details["credentialTypes"] != []
      assert Enum.all?(spec_details["credentialTypes"], &(&1 in @spec_credential_types))

      {:ok, charge} =
        Charge.new(
          amount: @spec_example_request["amount"],
          currency: @spec_example_request["currency"],
          recipient: @spec_example_request["recipient"]
        )

      charge = %{charge | method_details: %{"chain_id" => spec_details["chainId"]}}
      details = EVM.challenge_method_details(charge)
      request = Charge.to_request(%{charge | method_details: details})

      assert request["methodDetails"]["chainId"] == spec_details["chainId"]
      assert request["methodDetails"]["credentialTypes"] == ["hash"]
      assert request["methodDetails"]["permit2Address"] == @canonical_permit2

      for type <- request["methodDetails"]["credentialTypes"] do
        assert type in @spec_credential_types
      end
    end

    test "402 challenge encodes credentialTypes and permit2Address in methodDetails" do
      config =
        PaymentPlug.init(
          secret_key: "hmac-secret-for-evm-challenge-test",
          realm: "api.example.com",
          method: EVM,
          amount: @amount,
          currency: @token_address,
          recipient: @recipient,
          method_config: %{
            "rpc_url" => @rpc_url,
            "chain_id" => @chain_id
          }
        )

      conn =
        :get
        |> Plug.Test.conn("/resource")
        |> PaymentPlug.call(config)

      assert conn.status == 402
      [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert {:ok, challenge} = Headers.parse_challenge(header)
      assert {:ok, json} = Base.url_decode64(challenge.request, padding: false)
      assert {:ok, request} = Jason.decode(json)

      assert request["methodDetails"]["chainId"] == @chain_id
      assert request["methodDetails"]["credentialTypes"] == ["hash"]
      assert request["methodDetails"]["permit2Address"] == @canonical_permit2
    end
  end

  describe "validate_config!/1 — authorization domain" do
    test "accepts a complete EIP-712 domain map" do
      assert :ok =
               EVM.validate_config!(required_config(%{"authorization" => %{"name" => "USDC", "version" => "2"}}))
    end

    test "raises on a partial authorization domain" do
      assert_raise ArgumentError, ~r/authorization/, fn ->
        EVM.validate_config!(required_config(%{"authorization" => %{"name" => "USDC"}}))
      end
    end
  end

  describe "verify/2 — ERC-20 path" do
    test "returns receipt on successful ERC-20 transfer", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        result =
          case method do
            "eth_getTransactionReceipt" -> receipt_with_transfer()
            _ -> nil
          end

        rpc_json(conn, id, "result", result)
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

    test "accepts hash without 0x prefix", %{charge: charge} do
      bare_hash = String.duplicate("ab", 32)

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{"eth_getTransactionReceipt" => receipt_with_transfer()})
      end)

      assert {:ok, %Receipt{}} = EVM.verify(%{"hash" => bare_hash}, charge)
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
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => %{
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
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => %{
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
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => receipt_with_transfer(recipient: wrong_recipient)
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
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => receipt_with_transfer(amount_hex: wrong_amount_hex)
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "No matching Transfer"
    end

    property "rejects generated amount and recipient mismatches", %{charge: charge} do
      check all(
              fault <- StreamData.member_of([:amount, :recipient]),
              wrong_amount <- StreamData.integer(1..999_999),
              wrong_recipient <- generated_address_except(@recipient),
              max_runs: @property_runs
            ) do
        options =
          case fault do
            :amount -> [amount_hex: uint256_hex(wrong_amount)]
            :recipient -> [recipient: wrong_recipient]
          end

        Req.Test.stub(EVM, fn conn ->
          rpc_dispatch(conn, %{"eth_getTransactionReceipt" => receipt_with_transfer(options)})
        end)

        assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
        assert error.detail =~ "No matching Transfer"
      end
    end

    test "returns error when transaction not found", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{"eth_getTransactionReceipt" => nil})
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "not found"
    end

    test "returns error on RPC error response", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {_method, id, conn} = read_request(conn)
        rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "server error"})
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail == "EVM RPC request failed"
      refute error.detail =~ "server error"
    end

    test "rejects hash credential for zero-amount charge", %{charge: charge} do
      charge = %{charge | amount: "0"}
      payload = %{"hash" => @tx_hash}

      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "proof credential"
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
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => native_receipt(),
          "eth_getTransactionByHash" => native_tx()
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = EVM.verify(payload, charge)
      assert receipt.method == "evm"
      assert receipt.reference == @tx_hash
    end

    test "returns error when ETH value does not match", %{eth_charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => native_receipt(),
          # Wrong value: 0.5 ETH instead of 1 ETH
          "eth_getTransactionByHash" => %{native_tx() | "value" => "0x6f05b59d3b20000"}
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "value"
    end

    test "returns error when ETH recipient does not match", %{eth_charge: charge} do
      wrong_recipient = "0x" <> String.duplicate("99", 20)

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => %{native_receipt() | "to" => wrong_recipient},
          "eth_getTransactionByHash" => %{native_tx() | "to" => wrong_recipient}
        })
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
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => native_receipt(),
          "eth_getTransactionByHash" => native_tx()
        })
      end)

      payload = %{"hash" => @tx_hash}
      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)
    end
  end

  describe "verify/2 — authorization dispatch" do
    alias MPP.Test.EVMAuthorization

    @challenge_id "aB3cDeF4gHiJkLmN"
    @realm "api.example.com"

    defp authorization_charge(charge, extra \\ %{}) do
      %{
        charge
        | method_details:
            Map.merge(
              charge.method_details,
              Map.merge(
                %{
                  "private_key" => EVMAuthorization.private_key(),
                  "challenge_id" => @challenge_id,
                  "realm" => @realm,
                  "authorization" => %{"name" => "USD Coin", "version" => "2"}
                },
                extra
              )
            )
      }
    end

    defp authorization_payload(charge, overrides \\ []) do
      EVMAuthorization.payload(
        Map.merge(
          %{
            currency: charge.currency,
            name: "USD Coin",
            version: "2",
            chain_id: @chain_id,
            recipient: charge.recipient,
            amount: charge.amount,
            challenge_id: @challenge_id,
            realm: @realm
          },
          Map.new(overrides)
        )
      )
    end

    test "routes a well-formed authorization before the hash credential catch-all", %{charge: charge} do
      charge = authorization_charge(charge)
      payload = authorization_payload(charge)

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_call" => "0x" <> String.duplicate("0", 64),
          "eth_getTransactionCount" => "0x1",
          "eth_estimateGas" => "0x186a0",
          "eth_sendRawTransaction" => @tx_hash,
          "eth_getTransactionReceipt" => receipt_with_transfer(sender: EVMAuthorization.signer_address())
        })
      end)

      assert {:ok, %Receipt{} = receipt} = EVM.verify(payload, charge)
      assert receipt.method == "evm"
      assert receipt.reference == @tx_hash
    end

    test "rejects a matching settlement Transfer whose from is not the authorization signer", %{charge: charge} do
      charge = authorization_charge(charge)
      payload = authorization_payload(charge)

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_call" => "0x" <> String.duplicate("0", 64),
          "eth_getTransactionCount" => "0x1",
          "eth_estimateGas" => "0x186a0",
          "eth_sendRawTransaction" => @tx_hash,
          "eth_getTransactionReceipt" => receipt_with_transfer()
        })
      end)

      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects a zero-amount authorization charge", %{charge: charge} do
      charge = authorization_charge(%{charge | amount: "0"})
      payload = authorization_payload(charge)
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "proof credential"
    end

    test "rejects replay when authorizationState is already true", %{charge: charge} do
      charge = authorization_charge(charge)
      payload = authorization_payload(charge)

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{"eth_call" => "0x" <> String.duplicate("0", 63) <> "1"})
      end)

      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "already used"
    end
  end

  describe "verify/2 — RPC and parsing edge cases" do
    setup %{charge: charge} do
      {:ok, eth_charge} =
        Charge.new(amount: "1000000000000000000", currency: "ETH", recipient: @recipient)

      {:ok, eth_charge: %{eth_charge | method_details: charge.method_details}}
    end

    test "native path: error when transaction-by-hash is not found", %{eth_charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => native_receipt(),
          "eth_getTransactionByHash" => nil
        })
      end)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail =~ "Transaction not found"
    end

    test "native path: error when transaction-by-hash RPC returns an error", %{eth_charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "eth_getTransactionReceipt" ->
            rpc_json(conn, id, "result", native_receipt())

          "eth_getTransactionByHash" ->
            rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "boom"})
        end
      end)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail == "EVM RPC request failed"
    end

    test "error when the RPC transport fails", %{charge: charge} do
      Req.Test.stub(EVM, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail == "EVM RPC request failed"
      refute error.detail =~ "econnrefused"
    end

    test "error on an unexpected RPC response shape (no result or error)", %{charge: charge} do
      Req.Test.stub(EVM, fn conn ->
        {_method, id, conn} = read_request(conn)
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id})
      end)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail == "EVM RPC request failed"
    end

    test "error when method_config is missing rpc_url", %{charge: charge} do
      charge = %{charge | method_details: %{"req_options" => [plug: {Req.Test, EVM}]}}

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail =~ "missing required config: rpc_url"
    end

    test "error when the charge amount is not a valid integer", %{eth_charge: charge} do
      {:ok, bad} = Charge.new(amount: "not-a-number", currency: "ETH", recipient: @recipient)
      bad = %{bad | method_details: charge.method_details}

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => native_receipt(),
          "eth_getTransactionByHash" => native_tx()
        })
      end)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, bad)
      assert error.detail =~ "Invalid charge amount"
    end

    test "treats lowercase \"eth\" currency as native ETH", %{charge: charge} do
      {:ok, eth} = Charge.new(amount: "1000000000000000000", currency: "eth", recipient: @recipient)
      eth = %{eth | method_details: charge.method_details}

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => native_receipt(),
          "eth_getTransactionByHash" => native_tx()
        })
      end)

      assert {:ok, %Receipt{}} = EVM.verify(%{"hash" => @tx_hash}, eth)
    end

    test "tolerates a receipt with a missing blockNumber (nil hex value)", %{charge: charge} do
      receipt = Map.delete(receipt_with_transfer(), "blockNumber")

      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{"eth_getTransactionReceipt" => receipt})
      end)

      assert {:ok, %Receipt{}} = EVM.verify(%{"hash" => @tx_hash}, charge)
    end
  end

  describe "validate_config!/1 — store" do
    test "accepts a module implementing the Store behaviour" do
      assert :ok = EVM.validate_config!(required_config(%{"store" => MemoryStore}))
    end

    test "accepts {ConCacheStore, opts}" do
      assert :ok = EVM.validate_config!(required_config(%{"store" => {ConCacheStore, ttl: 600}}))
    end

    test "raises on a module that does not implement the Store behaviour" do
      assert_raise ArgumentError, ~r/must be a module implementing MPP.Tempo.Store/, fn ->
        EVM.validate_config!(required_config(%{"store" => Enum}))
      end
    end

    test "raises on an unsupported store tuple form" do
      assert_raise ArgumentError, ~r/tuple form is only supported/, fn ->
        EVM.validate_config!(required_config(%{"store" => {MemoryStore, []}}))
      end
    end

    test "raises at init when ConCacheStore opts is not a keyword list" do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        EVM.validate_config!(required_config(%{"store" => {ConCacheStore, [1, 2, 3]}}))
      end
    end

    test "rejects a store missing the atomic check_and_mark/2" do
      # get/1 + put/2 only — no longer accepted; atomicity is required (GHSA-w8j7-7qc3-5f24).
      defmodule GetPutOnlyStore do
        @moduledoc false
        def get(_key), do: :not_found
        def put(_key, _value), do: :ok
      end

      assert_raise ArgumentError, ~r/check_and_mark/, fn ->
        EVM.validate_config!(required_config(%{"store" => GetPutOnlyStore}))
      end
    end
  end

  describe "verify/2 — single-use dedup" do
    setup %{charge: charge} do
      start_supervised!(MemoryStore)
      {:ok, charge: with_store(charge, MemoryStore)}
    end

    test "accepts a transaction once then rejects replay on the same challenge", %{charge: charge} do
      stub_success()
      payload = %{"hash" => @tx_hash}

      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)

      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "rejects the same tx hash presented for a fresh challenge (cross-challenge reuse)", %{
      charge: charge
    } do
      stub_success()
      payload = %{"hash" => @tx_hash}

      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)

      # A brand-new charge/challenge sharing the same store — the settled tx must
      # not satisfy a second, unrelated charge. Binding is keyed on the tx hash,
      # not the (per-402-fresh) challenge id, so the replay is caught.
      {:ok, fresh} = Charge.new(amount: @amount, currency: @token_address, recipient: @recipient)
      fresh = with_store(%{fresh | method_details: charge.method_details}, MemoryStore)

      assert {:error, %Errors{} = error} = EVM.verify(payload, fresh)
      assert error.detail =~ "already used"
    end

    test "canonicalizes the hash — an uppercase-hex variant collides with the stored entry", %{
      charge: charge
    } do
      stub_success()

      assert {:ok, %Receipt{}} = EVM.verify(%{"hash" => @tx_hash}, charge)

      upper = "0x" <> String.upcase(String.duplicate("ab", 32))
      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => upper}, charge)
      assert error.detail =~ "already used"
    end

    test "does not mark a hash used when verification fails (commit is after verify)", %{
      charge: charge
    } do
      # First presentation: receipt has no matching Transfer → verification fails,
      # so the hash must NOT be recorded as used.
      Req.Test.stub(EVM, fn conn ->
        rpc_dispatch(conn, %{
          "eth_getTransactionReceipt" => %{receipt_with_transfer() | "logs" => []}
        })
      end)

      assert {:error, %Errors{}} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert MemoryStore.keys() == []

      # A later valid presentation of the same hash then succeeds.
      stub_success()
      assert {:ok, %Receipt{}} = EVM.verify(%{"hash" => @tx_hash}, charge)
    end
  end

  describe "verify/2 — replay protection on by default" do
    test "with no configured store, the app-started default store rejects replay", %{charge: charge} do
      # Drop the base opt-out so the store resolves to the app-started default.
      # Use a unique hash so the shared default store isn't polluted by other tests.
      charge = %{charge | method_details: Map.delete(charge.method_details, "store")}
      hash = "0x" <> String.duplicate("d1", 32)
      stub_success()
      payload = %{"hash" => hash}

      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)
      assert {:error, %Errors{} = error} = EVM.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "store: false opts out — the same hash verifies again", %{charge: charge} do
      # The base charge already carries store: false.
      stub_success()
      payload = %{"hash" => @tx_hash}

      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)
      assert {:ok, %Receipt{}} = EVM.verify(payload, charge)
    end
  end

  describe "verify/2 — dedup store failures" do
    test "read failure in the pre-check surfaces a generic dedup error", %{charge: charge} do
      # get/1 fails before the receipt is even fetched — no RPC stub needed.
      charge = with_store(charge, GetFailStore)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail == "Dedup store error"
    end

    test "atomic commit collision (already_exists) is rejected as replay", %{charge: charge} do
      stub_success()
      charge = with_store(charge, AlreadyExistsStore)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail =~ "already used"
    end

    test "unexpected atomic commit error surfaces a generic dedup error", %{charge: charge} do
      stub_success()
      charge = with_store(charge, AtomicFailStore)

      assert {:error, %Errors{} = error} = EVM.verify(%{"hash" => @tx_hash}, charge)
      assert error.detail == "Dedup store error"
    end
  end

  # --- Test helpers ---

  defp required_config(extra \\ %{}) do
    Map.merge(%{"rpc_url" => @rpc_url, "chain_id" => @chain_id}, extra)
  end

  defp uint256_hex(amount) do
    "0x" <> (amount |> Integer.to_string(16) |> String.pad_leading(64, "0"))
  end

  defp generated_address_except(address) do
    [length: @evm_address_bytes]
    |> StreamData.binary()
    |> StreamData.map(&("0x" <> Base.encode16(&1, case: :lower)))
    |> StreamData.filter(&(String.downcase(&1) != String.downcase(address)))
  end

  # Merges a dedup store into the charge's method_details.
  defp with_store(charge, store) do
    %{charge | method_details: Map.put(charge.method_details, "store", store)}
  end

  # Stubs a successful ERC-20 receipt matching the default charge.
  defp stub_success do
    Req.Test.stub(EVM, fn conn ->
      rpc_dispatch(conn, %{"eth_getTransactionReceipt" => receipt_with_transfer()})
    end)
  end

  # Reads and decodes a JSON-RPC request from the stub conn, returning the
  # method, the request id (which the response MUST echo — Onchain.RPC/Cartouche
  # matches the response id against the random request id), and the conn.
  defp read_request(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    {request["method"], request["id"], conn}
  end

  # Sends a JSON-RPC response with the given key ("result" or "error"), echoing id.
  defp rpc_json(conn, id, key, value) do
    Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, key => value})
  end

  # Dispatches a Req.Test stub by JSON-RPC method name, wrapping each value as a
  # result and echoing the request id.
  defp rpc_dispatch(conn, results_by_method) do
    {method, id, conn} = read_request(conn)
    rpc_json(conn, id, "result", Map.fetch!(results_by_method, method))
  end

  # Builds a valid receipt with an ERC-20 Transfer log matching the default charge.
  defp receipt_with_transfer(opts \\ []) do
    recipient = Keyword.get(opts, :recipient, @recipient)
    sender = Keyword.get(opts, :sender, @sender)
    amount_hex = Keyword.get(opts, :amount_hex, @amount_hex)

    # Topics: Transfer topic, padded sender address, padded recipient address
    padded_sender = "0x" <> String.duplicate("0", 24) <> strip_0x(sender)
    padded_recipient = "0x" <> String.duplicate("0", 24) <> strip_0x(recipient)

    %{
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => sender,
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

  # A successful native-ETH transaction receipt to @recipient.
  defp native_receipt do
    %{
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => @sender,
      "to" => @recipient,
      "logs" => []
    }
  end

  # A native-ETH transaction of exactly 1 ETH to @recipient.
  defp native_tx do
    %{
      "hash" => @tx_hash,
      "from" => @sender,
      "to" => @recipient,
      "value" => "0xde0b6b3a7640000",
      "input" => "0x"
    }
  end
end
