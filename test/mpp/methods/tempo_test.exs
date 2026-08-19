defmodule MPP.Methods.TempoTest do
  # async: false — these tests start MPP.Test.TempoMemoryStore, whose Agent is
  # registered under the global name __MODULE__. Two async modules starting it
  # concurrently raise {:already_started, pid} and, worse, share one dedup table.
  use ExUnit.Case, async: false

  import MPP.Test.TempoTestHelpers

  alias Cartouche.Signer.Curvy
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo
  alias MPP.Methods.Tempo.MachineToken
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Test.FailingPutStore
  alias MPP.Test.TempoMemoryStore
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @payer "0x1111111111111111111111111111111111111111"
  @realm "api.test.com"
  @challenge_id "challenge-test-1"

  defmodule SponsorLifecycleStore do
    @moduledoc false
    @behaviour MPP.Tempo.Store

    alias MPP.Tempo.Store

    @state_key {__MODULE__, :state}
    @update_count_key {__MODULE__, :update_count}
    @fail_on_update_key {__MODULE__, :fail_on_update}

    @spec configure(pos_integer()) :: :ok
    def configure(fail_on_update) do
      Process.put(@state_key, %{})
      Process.put(@update_count_key, 0)
      Process.put(@fail_on_update_key, fail_on_update)
      :ok
    end

    @impl Store
    def get(key) do
      case Map.fetch(state(), key) do
        {:ok, value} -> {:ok, value}
        :error -> :not_found
      end
    end

    @impl Store
    def put(key, value) do
      Process.put(@state_key, Map.put(state(), key, value))
      :ok
    end

    @impl Store
    def check_and_mark(key, value) do
      if Map.has_key?(state(), key) do
        {:error, :already_exists}
      else
        put(key, value)
      end
    end

    @impl Store
    def update(key, fun, _opts) do
      update_count = Process.get(@update_count_key, 0) + 1
      Process.put(@update_count_key, update_count)

      if update_count == Process.get(@fail_on_update_key) do
        {:error, :forced_failure}
      else
        # ERC-20 Transfer(address,address,uint256) topic
        apply_update(key, fun.(Map.get(state(), key, :not_found)))
      end
    end

    # TIP-20 TransferWithMemo(address,address,uint256,bytes32) topic
    defp apply_update(key, {:put, value, result}) do
      Process.put(@state_key, Map.put(state(), key, value))
      {:ok, result}
    end

    defp apply_update(key, {:delete, result}) do
      Process.put(@state_key, Map.delete(state(), key))
      {:ok, result}
    end

    # Simulate what Plug does: merge method_config into charge.method_details.
    # Dedup is on by default now; these verification-logic tests opt out
    # (`store: false`) so the app-started shared default store doesn't carry the
    # fixed @tx_hash across async tests. Dedup is covered by the dedicated dedup
    # describes below (which set their own store).
    defp apply_update(_key, {:noop, result}), do: {:ok, result}
    defp state, do: Process.get(@state_key, %{})
  end

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @transfer_with_memo_topic "0x57bc7354aa85aed339e000bccffabbc529466af35f0772c8f8ee1145927de7f0"

  @test_memo "0x" <> String.duplicate("ab", 32)

  setup do
    {:ok, charge} =
      Charge.new(
        amount: "1000000",
        currency: @token_address,
        recipient: @recipient
      )

    charge = %{
      charge
      | method_details: %{
          "rpc_url" => @rpc_url,
          "chain_id" => 42_431,
          "req_options" => [plug: {Req.Test, Tempo}],
          "store" => false
        }
    }

    {:ok, charge: charge}
  end

  describe "method_name/0" do
    test "returns \"tempo\"" do
      assert Tempo.method_name() == "tempo"
    end
  end

  describe "validate_config!/1" do
    test "returns :ok with valid config" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url})
    end

    test "raises on missing rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Tempo.validate_config!(%{})
      end
    end

    test "raises on nil rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Tempo.validate_config!(%{"rpc_url" => nil})
      end
    end

    test "accepts valid memo with 0x prefix (with a store)" do
      memo = "0x" <> String.duplicate("ab", 32)
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo, "store" => ConCacheStore})
    end

    test "accepts valid memo without 0x prefix (with a store)" do
      memo = String.duplicate("ab", 32)
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo, "store" => ConCacheStore})
    end

    test "accepts nil memo" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => nil})
    end

    test "raises when a static memo is configured with dedup explicitly disabled (store: false)" do
      memo = "0x" <> String.duplicate("ab", 32)

      assert_raise ArgumentError, ~r/static "memo" requires dedup/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo, "store" => false})
      end
    end

    test "accepts a static memo with no store configured (dedup is on by default)" do
      memo = "0x" <> String.duplicate("ab", 32)

      # nil/absent store resolves to the app-started default, so the memo's missing
      # attribution binding is backstopped by single-use enforcement automatically.
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo})
    end

    test "raises on memo with wrong length" do
      assert_raise ArgumentError, ~r/32-byte hex string/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => "0xdead"})
      end
    end

    test "raises on memo with non-hex characters" do
      memo = "0x" <> String.duplicate("zz", 32)

      assert_raise ArgumentError, ~r/32-byte hex string/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo})
      end
    end

    test "raises on non-string memo" do
      assert_raise ArgumentError, ~r/32-byte hex string/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => 12_345})
      end
    end

    test "accepts boolean require_presenter_binding" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "require_presenter_binding" => true})
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "require_presenter_binding" => false})
    end

    test "raises on non-boolean require_presenter_binding" do
      assert_raise ArgumentError, ~r/require_presenter_binding.*boolean/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "require_presenter_binding" => "yes"})
      end
    end

    test "accepts machine_token_enabled true on Moderato (default chain)" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "machine_token_enabled" => true})
    end

    test "accepts machine_token_enabled true on Tempo mainnet" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "chain_id" => 4217, "machine_token_enabled" => true})
    end

    test "accepts machine_token_enabled false" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "machine_token_enabled" => false})
    end

    test "raises when machine_token_enabled is true on an unsupported chain" do
      assert_raise ArgumentError, ~r/machine tokens are not supported on chain ID 1/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "chain_id" => 1, "machine_token_enabled" => true})
      end
    end

    test "raises on non-boolean machine_token_enabled" do
      assert_raise ArgumentError, ~r/machine_token_enabled.*boolean/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "machine_token_enabled" => "yes"})
      end
    end

    test "rejects malformed sponsorship store references and policy containers" do
      sponsor_config = %{
        "rpc_url" => @rpc_url,
        "fee_payer" => true,
        "fee_payer_private_key" => "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "fee_token" => @token_address
      }

      assert_raise ArgumentError, ~r/:store tuple form/, fn ->
        Tempo.validate_config!(Map.put(sponsor_config, "store", {TempoMemoryStore, []}))
      end

      assert_raise ArgumentError, ~r/fee_payer_policy must be a map/, fn ->
        Tempo.validate_config!(Map.merge(sponsor_config, %{"store" => ConCacheStore, "fee_payer_policy" => :invalid}))
      end
    end
  end

  describe "challenge_method_details/1" do
    test "returns chainId and feePayer with defaults", %{charge: charge} do
      charge = %{charge | method_details: %{"rpc_url" => @rpc_url}}
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 42_431
      assert details["feePayer"] == false
      refute Map.has_key?(details, "memo")
    end

    test "uses configured chain_id", %{charge: charge} do
      charge = %{charge | method_details: %{"chain_id" => 4217}}
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 4217
    end

    test "includes feePayer when configured", %{charge: charge} do
      charge = %{charge | method_details: %{"fee_payer" => true}}
      details = Tempo.challenge_method_details(charge)

      assert details["feePayer"] == true
    end

    test "includes memo when configured", %{charge: charge} do
      memo = "0x" <> String.duplicate("ab", 32)
      charge = %{charge | method_details: %{"memo" => memo}}
      details = Tempo.challenge_method_details(charge)

      assert details["memo"] == memo
    end

    test "omits memo when not configured", %{charge: charge} do
      details = Tempo.challenge_method_details(charge)

      refute Map.has_key?(details, "memo")
    end

    test "handles nil method_details" do
      {:ok, charge} = Charge.new(amount: "1000", currency: @token_address)
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 42_431
      assert details["feePayer"] == false
    end

    test "includes presenterBinding when required", %{charge: charge} do
      charge = %{charge | method_details: %{"require_presenter_binding" => true}}
      details = Tempo.challenge_method_details(charge)

      assert details["presenterBinding"] == true
    end

    test "omits presenterBinding when not required", %{charge: charge} do
      refute Map.has_key?(Tempo.challenge_method_details(charge), "presenterBinding")

      charge = %{charge | method_details: %{"require_presenter_binding" => false}}
      refute Map.has_key?(Tempo.challenge_method_details(charge), "presenterBinding")
    end

    test "includes machineTokenEnabled only when enabled", %{charge: charge} do
      refute Map.has_key?(Tempo.challenge_method_details(charge), "machineTokenEnabled")

      charge = %{charge | method_details: %{"machine_token_enabled" => false}}
      refute Map.has_key?(Tempo.challenge_method_details(charge), "machineTokenEnabled")

      charge = %{charge | method_details: %{"machine_token_enabled" => true}}
      assert Tempo.challenge_method_details(charge)["machineTokenEnabled"] == true
    end
  end

  describe "verify/2 — hash credential" do
    test "returns receipt on successful Transfer match", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.reference == @tx_hash
      assert receipt.status == "success"
      assert receipt.timestamp
    end

    test "accepts hash credential source matching transfer sender", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "credential_source", "did:pkh:eip155:42431:#{@payer}")
      }

      stub_receipt(success_receipt(logs: [transfer_log(from: @payer)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "accepts auto-attribution memo bound to the challenge", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.merge(charge.method_details, %{"challenge_id" => @challenge_id, "realm" => @realm})
      }

      memo = attribution_memo(@realm, @challenge_id)
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "rejects plain transfer when challenge binding context requires attribution memo", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.merge(charge.method_details, %{"challenge_id" => @challenge_id, "realm" => @realm})
      }

      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects auto-attribution memo bound to a different challenge", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.merge(charge.method_details, %{"challenge_id" => @challenge_id, "realm" => @realm})
      }

      memo = attribution_memo(@realm, "other-challenge")
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects a memo whose bytes are the right length but not attribution-tagged", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.merge(charge.method_details, %{"challenge_id" => @challenge_id, "realm" => @realm})
      }

      # 32 bytes (correct memo length) but without the "mpp" attribution tag/version prefix.
      untagged_memo = "0x" <> String.duplicate("00", 32)
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: untagged_memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects a memo whose byte length is not the attribution length", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.merge(charge.method_details, %{"challenge_id" => @challenge_id, "realm" => @realm})
      }

      # Too short to be a valid 32-byte attribution memo.
      short_memo = "0xabcd"
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: short_memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects hash credential source with wrong chain", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "credential_source", "did:pkh:eip155:1:#{@payer}")
      }

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "source"
    end

    test "rejects hash credential source that does not match transfer sender", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "credential_source", "did:pkh:eip155:42431:#{@payer}")
      }

      wrong_payer = "0x2222222222222222222222222222222222222222"
      stub_receipt(success_receipt(logs: [transfer_log(from: wrong_payer)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error on missing hash field", %{charge: charge} do
      payload = %{"type" => "hash"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error on empty hash", %{charge: charge} do
      payload = %{"type" => "hash", "hash" => ""}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error on invalid hash format", %{charge: charge} do
      payload = %{"type" => "hash", "hash" => "0xnothex"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error on missing type field", %{charge: charge} do
      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error for unsupported type", %{charge: charge} do
      payload = %{"type" => "unknown"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when transaction not found", %{charge: charge} do
      stub_receipt_response(%{"jsonrpc" => "2.0", "result" => nil, "id" => 1})

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "returns error when transaction reverted", %{charge: charge} do
      stub_receipt(reverted_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "reverted"
    end

    test "returns error when amount mismatches", %{charge: charge} do
      # Receipt has transfer for 999999 instead of 1000000
      receipt = success_receipt(amount: 999_999)
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error when recipient mismatches", %{charge: charge} do
      receipt = success_receipt(to: "0x0000000000000000000000000000000000000000")
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error when token mismatches", %{charge: charge} do
      receipt = success_receipt(token: "0x0000000000000000000000000000000000000001")
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error when no Transfer events in logs", %{charge: charge} do
      receipt = success_receipt(logs: [])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error on RPC error response", %{charge: charge} do
      stub_receipt_response(%{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32_000, "message" => "internal error"},
        "id" => 1
      })

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "returns error on network failure", %{charge: charge} do
      Req.Test.stub(Tempo, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "returns error on unexpected RPC response body", %{charge: charge} do
      Req.Test.stub(Tempo, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"oops" => true})
      end)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "rejects transaction with invalid hex in signature field", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0xdeadbeef"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Not a Tempo transaction"
    end

    test "preserves external_id in receipt", %{charge: charge} do
      charge = %{charge | external_id: "order-42"}
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.external_id == "order-42"
    end

    test "returns error on non-numeric charge amount", %{charge: charge} do
      charge = %{charge | amount: "not_a_number"}
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "not a valid integer"
    end

    test "verifies RPC request body contains correct method and hash", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:rpc_request, Jason.decode!(body)})
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
      end)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      assert_received {:rpc_request, request}
      assert request["method"] == "eth_getTransactionReceipt"
      assert request["params"] == [@tx_hash]
    end
  end

  describe "verify/2 — memo enforcement" do
    setup %{charge: charge} do
      # Add memo to method_details
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "memo", @test_memo)
      }

      {:ok, charge: charge}
    end

    test "returns receipt when TransferWithMemo matches with correct memo", %{charge: charge} do
      receipt = success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
    end

    test "returns error when only plain Transfer event (memo configured)", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "TransferWithMemo"
    end

    test "returns error when TransferWithMemo has wrong memo", %{charge: charge} do
      wrong_memo = "0x" <> String.duplicate("cd", 32)
      receipt = success_receipt(logs: [transfer_with_memo_log(memo: wrong_memo)])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "TransferWithMemo"
    end

    test "accepts TransferWithMemo when no memo configured (no-memo path)", %{charge: charge} do
      # Remove memo from config
      charge = %{
        charge
        | method_details: Map.delete(charge.method_details, "memo")
      }

      receipt = success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  describe "verify/2 — hash credential with machine tokens" do
    test "does not fetch the transaction sender when the flag is off", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
      end)

      assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
      assert_received {:rpc_call, "eth_getTransactionReceipt"}
      refute_received {:rpc_call, "eth_getTransactionByHash"}
    end

    test "accepts TransferWithMemo from the canonical swapper when the tx sender is the payer", %{charge: charge} do
      charge = enable_machine_token(charge)
      swapper = machine_token_swapper()
      memo = @test_memo
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", memo)}

      stub_receipt_and_transaction_from(
        success_receipt(logs: [transfer_with_memo_log(from: swapper, memo: memo)]),
        @payer
      )

      assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
    end

    test "accepts an ordinary payer Transfer when machine tokens are enabled", %{charge: charge} do
      charge = enable_machine_token(charge)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "credential_source", "did:pkh:eip155:42431:#{@payer}")
      }

      stub_receipt_and_transaction_from(success_receipt(logs: [transfer_log(from: @payer)]), @payer)

      assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
    end

    test "rejects a swapper settlement when the tx sender is not the credential source", %{charge: charge} do
      charge = enable_machine_token(charge)
      swapper = machine_token_swapper()
      memo = @test_memo
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", memo)}

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "credential_source", "did:pkh:eip155:42431:#{@payer}")
      }

      stub_receipt_and_transaction_from(
        success_receipt(logs: [transfer_with_memo_log(from: swapper, memo: memo)]),
        "0x2222222222222222222222222222222222222222"
      )

      assert {:error, %Errors{} = error} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching TransferWithMemo"
    end

    test "rejects machine tokens on an unsupported chain at verify time", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.merge(charge.method_details, %{"machine_token_enabled" => true, "chain_id" => 1})
      }

      stub_receipt(success_receipt())

      assert {:error, %Errors{} = error} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
      assert error.detail =~ "Machine tokens are not supported on chain ID 1"
    end

    test "returns a verification error when the transaction is missing on-chain", %{charge: charge} do
      charge = enable_machine_token(charge)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        result =
          case request["method"] do
            "eth_getTransactionReceipt" -> success_receipt()
            "eth_getTransactionByHash" -> nil
            _other -> nil
          end

        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => result, "id" => request["id"]})
      end)

      assert {:error, %Errors{} = error} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
      assert error.detail =~ "Transaction not found on-chain"
    end

    test "returns a verification error when eth_getTransactionByHash omits from", %{charge: charge} do
      charge = enable_machine_token(charge)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        result =
          case request["method"] do
            "eth_getTransactionReceipt" -> success_receipt()
            "eth_getTransactionByHash" -> %{"hash" => @tx_hash}
            _other -> nil
          end

        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => result, "id" => request["id"]})
      end)

      assert {:error, %Errors{} = error} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
      assert error.detail == "Tempo RPC request failed"
    end
  end

  describe "verify/2 — transaction credential" do
    setup %{charge: charge} do
      # Build a valid 0x76 transaction with a transfer call matching the charge
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)

      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)
      {:ok, tx_hex: tx_hex, charge: charge}
    end

    test "returns receipt on valid transaction credential", %{charge: charge, tx_hex: tx_hex} do
      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"
    end

    test "preserves external_id in transaction receipt", %{charge: charge, tx_hex: tx_hex} do
      charge = %{charge | external_id: "tx-order-99"}
      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.external_id == "tx-order-99"
    end

    test "returns error on missing signature field", %{charge: charge} do
      payload = %{"type" => "transaction"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "returns error on empty signature field", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => ""}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "returns error on chain_id mismatch", %{charge: charge} do
      # Build tx with wrong chain_id
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      wrong_chain_tx = build_tempo_tx(calls: [call], chain_id: 9999)

      payload = %{"type" => "transaction", "signature" => wrong_chain_tx}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Chain ID mismatch"
    end

    test "returns error when no matching transfer call", %{charge: charge} do
      # Build tx with transfer to wrong recipient
      wrong_recipient = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
      calldata = transfer_calldata(wrong_recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      bad_tx = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => bad_tx}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching transfer call"
    end

    test "returns error on broadcast failure", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransactionSync" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => -32_000, "message" => "nonce too low"},
              "id" => 1
            })
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "returns error when transaction reverts on-chain", %{charge: charge, tx_hex: tx_hex} do
      stub_broadcast_and_receipt(reverted_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "reverted"
    end

    test "returns error on non-0x76 transaction", %{charge: charge} do
      # Build something that starts with 0x02 (EIP-1559)
      body = ExRLP.encode([<<1>>, <<>>, <<>>, <<>>, [], [], <<>>, <<>>, <<>>])
      bad_hex = "0x02" <> Base.encode16(body, case: :lower)

      payload = %{"type" => "transaction", "signature" => bad_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Not a Tempo transaction"
    end

    test "sends raw hex via eth_sendRawTransactionSync and uses receipt tx hash", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"], request["params"]})

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          _ ->
            # eth_sendRawTransactionSync returns the full receipt directly
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.reference == @tx_hash

      # Verify the sync RPC method was called with raw tx hex
      assert_received {:rpc_call, "eth_sendRawTransactionSync", [sent_hex]}
      assert sent_hex == tx_hex

      # Verify NO separate receipt fetch was made (sync returns receipt directly)
      refute_received {:rpc_call, "eth_getTransactionReceipt", _}
    end

    test "returns receipt on valid transferWithMemo transaction when memo configured", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", @test_memo)}

      calldata = transfer_with_memo_calldata(@recipient, 1_000_000, @test_memo)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      receipt = success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)])
      stub_broadcast_and_receipt(receipt)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.reference == @tx_hash
    end

    test "returns error on broadcast network failure", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransactionSync" ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "returns error on unexpected broadcast response body", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransactionSync" ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"oops" => true})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end
  end

  describe "verify/2 — pre-broadcast simulation gate (fee-payer DoS guard)" do
    setup %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)
      {:ok, tx_hex: tx_hex, charge: charge}
    end

    test "confirmation path rejects a reverting transaction BEFORE broadcasting", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_simulateV1" ->
            # Underfunded gas → the call runs out of gas on-chain → status 0x0.
            # This is the drain vector: without this gate the fee payer broadcasts,
            # pays the gas, and the client pays nothing.
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "result" => [%{"calls" => [%{"status" => "0x0"}]}],
              "id" => 1
            })

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Pre-broadcast simulation rejected"

      # The fee payer never commits gas — broadcast is never attempted.
      assert_received {:rpc_call, "eth_simulateV1"}
      refute_received {:rpc_call, "eth_sendRawTransactionSync"}
      refute_received {:rpc_call, "eth_sendRawTransaction"}
    end

    test "degrades gracefully and broadcasts when the node lacks eth_simulateV1 (-32601)", %{
      charge: charge,
      tx_hex: tx_hex
    } do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => -32_601, "message" => "the method eth_simulateV1 does not exist"},
              "id" => 1
            })

          "eth_sendRawTransactionSync" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Simulation was attempted, degraded gracefully, then broadcast proceeded.
      assert_received {:rpc_call, "eth_simulateV1"}
      assert_received {:rpc_call, "eth_sendRawTransactionSync"}
    end
  end

  describe "verify/2 — optimistic broadcast (wait_for_confirmation: false)" do
    setup %{charge: charge} do
      # Enable optimistic mode
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "wait_for_confirmation", false)
      }

      # Build a valid 0x76 transaction with a transfer call matching the charge
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      {:ok, charge: charge, tx_hex: tx_hex}
    end

    test "returns optimistic receipt after simulation + async broadcast", %{charge: charge, tx_hex: tx_hex} do
      stub_optimistic_flow(@tx_hash)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"
      assert receipt.reference == @tx_hash
    end

    test "preserves external_id in optimistic receipt", %{charge: charge, tx_hex: tx_hex} do
      charge = %{charge | external_id: "optimistic-order-1"}
      stub_optimistic_flow(@tx_hash)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.external_id == "optimistic-order-1"
    end

    test "returns error when simulation fails (never broadcasts)", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_simulateV1" ->
            # Simulation reports the transaction would revert (the gas-drain DoS guard)
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "result" => [%{"calls" => [%{"status" => "0x0"}]}],
              "id" => 1
            })

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Pre-broadcast simulation rejected"

      # Verify simulation was called but broadcast was NOT
      assert_received {:rpc_call, "eth_simulateV1"}
      refute_received {:rpc_call, "eth_sendRawTransaction"}
    end

    test "returns error when async broadcast fails after successful simulation", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransaction" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => -32_000, "message" => "nonce too low"},
              "id" => 1
            })
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "calls eth_simulateV1 then eth_sendRawTransaction (not sync variant)", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"], request["params"]})

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransaction" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => @tx_hash, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Verify the correct RPC methods were called with the raw tx
      assert_received {:rpc_call, "eth_simulateV1", _}
      assert_received {:rpc_call, "eth_sendRawTransaction", [sent_hex]}
      assert sent_hex == tx_hex

      # Verify sync variant was NOT called
      refute_received {:rpc_call, "eth_sendRawTransactionSync", _}
    end

    test "simulation network failure returns error", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Pre-broadcast simulation failed"
    end

    test "async broadcast network failure returns error", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            # Simulation succeeds
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransaction" ->
            # Broadcast hits network error
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "async broadcast unexpected response status returns error", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransaction" ->
            # Return 503 with no error/result fields
            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"jsonrpc" => "2.0", "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Tempo RPC request failed"
    end

    test "multicall: simulates the full co-signed transaction before broadcast", %{charge: charge} do
      # Build a 3-call multicall: [approve(dex), swap(dex), transfer(token)].
      # The full transaction (all calls) is simulated via eth_simulateV1 — there is
      # no longer a per-call eth_call that could target the wrong call in the batch.
      dex_address = dex_address()
      approve_call = build_call(@token_address, approve_calldata(dex_address, 1_000_000))
      swap_call = build_call(dex_address, swap_calldata())
      transfer_call = build_call(@token_address, transfer_calldata(@recipient, 1_000_000))

      tx_hex = build_tempo_tx(calls: [approve_call, swap_call, transfer_call], chain_id: 42_431)

      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransaction" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => @tx_hash, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # The full tx is simulated once, then broadcast.
      assert_received {:rpc_call, "eth_simulateV1"}
      assert_received {:rpc_call, "eth_sendRawTransaction"}
    end
  end

  describe "verify/2 — transaction credential with machine tokens" do
    test "accepts the canonical [approve, swapTo] route", %{charge: charge} do
      charge = enable_machine_token(charge)
      memo = @test_memo
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", memo)}
      tx_hex = build_tempo_tx(calls: machine_token_calls(1_000_000, memo), chain_id: 42_431)

      stub_broadcast_and_receipt(
        success_receipt(logs: [transfer_with_memo_log(from: machine_token_swapper(), memo: memo)])
      )

      assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "transaction", "signature" => tx_hex}, charge)
    end

    test "falls through to TIP-20 transfer matching when the route does not match", %{charge: charge} do
      charge = enable_machine_token(charge)
      calldata = transfer_calldata(@recipient, 1_000_000)
      tx_hex = build_tempo_tx(calls: [build_call(@token_address, calldata)], chain_id: 42_431)
      stub_broadcast_and_receipt(success_receipt(logs: [transfer_log(from: test_sender_address())]))

      assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "transaction", "signature" => tx_hex}, charge)
    end

    test "rejects a mutated machine-token route that is not a TIP-20 transfer", %{charge: charge} do
      charge = enable_machine_token(charge)
      memo = @test_memo
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", memo)}
      [_approve, swap] = machine_token_calls(1_000_000, memo)
      tx_hex = build_tempo_tx(calls: [swap], chain_id: 42_431)

      assert {:error, %Errors{} = error} = Tempo.verify(%{"type" => "transaction", "signature" => tx_hex}, charge)
      assert error.detail =~ "No matching transferWithMemo call"
    end
  end

  describe "verify/2 — dedup store" do
    setup %{charge: charge} do
      start_supervised!(TempoMemoryStore)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", TempoMemoryStore)
      }

      {:ok, charge: charge}
    end

    test "hash path rejects replay of already-used hash", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}

      # First call succeeds
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Second call with same hash is rejected
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "already used"
    end

    test "transaction path rejects replay of already-used signed tx", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # First call succeeds
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Second call with same signed tx is rejected before broadcast
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "already used"
    end

    test "static-memo hash path rejects replay of already-used hash (store backstops missing attribution binding)",
         %{charge: charge} do
      # Static memo disables per-challenge attribution binding, so the dedup store is the
      # sole replay defense — this proves it holds on the static-memo path.
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", @test_memo)}
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash}

      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "already used"
    end

    test "hash path allows retry after transient RPC failure", %{charge: charge} do
      # First attempt: RPC returns error (transient failure)
      stub_receipt_response(%{"jsonrpc" => "2.0", "error" => %{"code" => -32_000, "message" => "timeout"}, "id" => 1})

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{}} = Tempo.verify(payload, charge)

      # Hash should NOT be burned — store should have no entry
      expected_key = "mpp:charge:" <> String.downcase(@tx_hash)
      assert :not_found = TempoMemoryStore.get(expected_key)

      # Second attempt: RPC succeeds — retry should work
      stub_receipt(success_receipt())
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Now the hash IS marked
      assert {:ok, _timestamp} = TempoMemoryStore.get(expected_key)
    end

    test "hash path records key in store after success", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      expected_key = "mpp:charge:" <> String.downcase(@tx_hash)
      assert {:ok, _timestamp} = TempoMemoryStore.get(expected_key)
    end

    test "post-broadcast dedup records on-chain hash when it differs from input", %{charge: charge} do
      # Stub broadcast to return a DIFFERENT tx hash than the input
      different_on_chain_hash = "0x" <> String.duplicate("cd", 32)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransactionSync" ->
            receipt = %{success_receipt() | "transactionHash" => different_on_chain_hash}
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
        end
      end)

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Both the input hex and the on-chain hash should be recorded
      input_key = "mpp:charge:" <> String.downcase(tx_hex)
      onchain_key = "mpp:charge:" <> String.downcase(different_on_chain_hash)
      assert {:ok, _} = TempoMemoryStore.get(input_key)
      assert {:ok, _} = TempoMemoryStore.get(onchain_key)
    end

    test "store get error surfaces as verification_failed", %{charge: charge} do
      # Override store with a failing module
      defmodule FailingStore do
        @moduledoc false
        @behaviour Store

        def get(_key), do: {:error, :connection_refused}
        def put(_key, _value), do: :ok
        # Required by the contract; unreached here (get fails first).
        def check_and_mark(_key, _value), do: :ok
      end

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", FailingStore)
      }

      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Dedup store error"
    end

    test "concurrent requests with same signed tx — only one succeeds", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Fire two concurrent verify calls with identical signed tx
      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Tempo.verify(payload, charge) end)
        end

      results = Task.await_many(tasks)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      error_count = Enum.count(results, &match?({:error, _}, &1))

      assert ok_count == 1, "Expected exactly 1 success, got #{ok_count}: #{inspect(results)}"
      assert error_count == 1, "Expected exactly 1 rejection, got #{error_count}: #{inspect(results)}"

      # The rejected one should cite "already used"
      [{:error, %Errors{} = error}] =
        Enum.filter(results, &match?({:error, _}, &1))

      assert error.detail =~ "already used"
    end

    test "post-broadcast store.put crash does not fail the request", %{charge: charge} do
      # Store that succeeds on check_and_mark but raises on put (post-broadcast path)
      defmodule CrashingPutStore do
        @moduledoc false
        @behaviour Store

        use Agent

        def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

        def get(key) do
          case Agent.get(__MODULE__, &Map.get(&1, key)) do
            nil -> :not_found
            value -> {:ok, value}
          end
        end

        def put(_key, _value), do: raise("store crashed!")

        def check_and_mark(key, value) do
          Agent.get_and_update(__MODULE__, fn state ->
            if Map.has_key?(state, key) do
              {{:error, :already_exists}, state}
            else
              {:ok, Map.put(state, key, value)}
            end
          end)
        end
      end

      start_supervised!(CrashingPutStore)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", CrashingPutStore)
      }

      # Broadcast returns a DIFFERENT hash to trigger safe_dedup_post_broadcast
      different_hash = "0x" <> String.duplicate("ef", 32)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransactionSync" ->
            receipt = %{success_receipt() | "transactionHash" => different_hash}
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
        end
      end)

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Should succeed despite post-broadcast store.put raising
      assert {:ok, %Receipt{reference: ^different_hash}} = Tempo.verify(payload, charge)
    end

    test "post-broadcast dead store process does not fail the request", %{charge: charge} do
      # Store with a real Agent for check_and_mark, but we kill it before post-broadcast
      defmodule DeadProcessStore do
        @moduledoc false
        @behaviour MPP.Tempo.Store

        use Agent

        def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

        def get(key) do
          case Agent.get(__MODULE__, &Map.get(&1, key)) do
            nil -> :not_found
            value -> {:ok, value}
          end
        end

        def put(_key, _value), do: Agent.update(__MODULE__, & &1)

        def check_and_mark(key, value) do
          Agent.get_and_update(__MODULE__, fn state ->
            if Map.has_key?(state, key) do
              {{:error, :already_exists}, state}
            else
              {:ok, Map.put(state, key, value)}
            end
          end)
        end
      end

      start_supervised!(DeadProcessStore)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", DeadProcessStore)
      }

      # Broadcast returns a DIFFERENT hash to trigger safe_dedup_post_broadcast
      different_hash = "0x" <> String.duplicate("de", 32)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransactionSync" ->
            # Kill the store process AFTER broadcast succeeds but before post-broadcast dedup runs.
            # We can't time it precisely, so we kill it here — the post-broadcast put will hit a dead process.
            Agent.stop(DeadProcessStore)

            receipt = %{success_receipt() | "transactionHash" => different_hash}
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
        end
      end)

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Should succeed despite post-broadcast store process being dead (catch :exit)
      assert {:ok, %Receipt{reference: ^different_hash}} = Tempo.verify(payload, charge)
    end

    test "validate_config! rejects invalid store module" do
      assert_raise ArgumentError, ~r/must be a module implementing/, fn ->
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => :not_a_real_module})
      end

      assert_raise ArgumentError, ~r/must be a module implementing/, fn ->
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => "not_a_module"})
      end
    end

    test "validate_config! rejects a ConCacheStore tuple whose opts is not a keyword list" do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => {ConCacheStore, [1, 2, 3]}})
      end
    end
  end

  describe "verify/2 — ConCacheStore" do
    setup %{charge: charge} do
      # Use a uniquely-named instance — the default :mpp_tempo_dedup is already
      # started by MPP.Application, so starting another default-named one collides.
      name = :test_cc_dedup
      start_supervised!(ConCacheStore.child_spec(name: name, ttl: to_timeout(second: 10)))

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", {ConCacheStore, name: name})
      }

      {:ok, charge: charge}
    end

    test "hash path stores and rejects replay", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}

      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Replay rejected
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "concurrent hash-credential requests for same confirmed hash — exactly one succeeds", %{
      charge: charge
    } do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}

      # Two concurrent verifications of the same confirmed on-chain hash both pass the
      # early read and fetch the receipt, then collide at the atomic commit
      # (check_and_mark) — exactly one wins, the other is rejected as already-used.
      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Tempo.verify(payload, charge) end)
        end

      results = Task.await_many(tasks)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      error_count = Enum.count(results, &match?({:error, _}, &1))

      assert ok_count == 1, "Expected exactly 1 success, got #{ok_count}: #{inspect(results)}"
      assert error_count == 1, "Expected exactly 1 rejection, got #{error_count}: #{inspect(results)}"

      [{:error, %Errors{} = error}] = Enum.filter(results, &match?({:error, _}, &1))
      assert error.detail =~ "already used"
    end

    test "transaction path stores and rejects replay", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Replay rejected
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "validate_config! accepts ConCacheStore" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => ConCacheStore})
    end

    test "validate_config! accepts named ConCacheStore tuple" do
      assert :ok =
               Tempo.validate_config!(%{
                 "rpc_url" => "https://example.com",
                 "store" => {ConCacheStore, name: :my_custom_dedup}
               })
    end

    test "child_spec id avoids ConCache collision" do
      spec = ConCacheStore.child_spec([])
      assert spec.id == {ConCacheStore, :mpp_tempo_dedup}
    end

    test "child_spec with no args uses defaults" do
      spec = ConCacheStore.child_spec()
      assert spec.id == {ConCacheStore, :mpp_tempo_dedup}
      assert is_tuple(spec.start)
    end

    test "child_spec accepts custom name" do
      spec = ConCacheStore.child_spec(name: :my_custom_dedup)
      assert spec.id == {ConCacheStore, :my_custom_dedup}
    end

    test "custom named store works end-to-end", %{charge: charge} do
      custom_name = :my_custom_dedup
      start_supervised!(ConCacheStore.child_spec(name: custom_name, ttl: to_timeout(second: 10)))

      named_charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", {ConCacheStore, name: custom_name})
      }

      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}

      assert {:ok, %Receipt{}} = Tempo.verify(payload, named_charge)
      assert {:error, %Errors{} = error} = Tempo.verify(payload, named_charge)
      assert error.detail =~ "already used"
    end

    test "named ConCacheStore tuple works for transaction path (atomic reserve)", %{charge: charge} do
      custom_name = :tx_path_dedup
      start_supervised!(ConCacheStore.child_spec(name: custom_name, ttl: to_timeout(second: 10)))

      named_charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", {ConCacheStore, name: custom_name})
      }

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # First call succeeds via atomic check_and_mark on named store
      assert {:ok, %Receipt{}} = Tempo.verify(payload, named_charge)

      # Replay rejected
      assert {:error, %Errors{} = error} = Tempo.verify(payload, named_charge)
      assert error.detail =~ "already used"
    end

    test "check_and_mark is atomic — concurrent tx submissions", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Run 5 concurrent verifications — exactly 1 should succeed via atomic reserve
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> Tempo.verify(payload, charge) end)
        end

      results = Task.await_many(tasks)
      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      assert successes == 1, "Expected exactly 1 success, got #{successes}"
      assert failures == 4, "Expected exactly 4 failures, got #{failures}"
    end
  end

  describe "verify/2 — store put error (mark_hash_used)" do
    test "put failure surfaces as verification_failed", %{charge: charge} do
      # FailingPutStore: get returns :not_found (no dedup hit), put returns {:error, :store_failure}
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", FailingPutStore)
      }

      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Dedup store error"
    end
  end

  describe "verify/2 — atomic store unexpected error" do
    test "unexpected check_and_mark error surfaces as verification_failed", %{charge: charge} do
      # FailingPutStore has check_and_mark returning {:error, :unexpected_store_error}
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", FailingPutStore)
      }

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Dedup store error"
    end
  end

  describe "validate_config! — store tuple edge cases" do
    test "rejects unsupported tuple store" do
      assert_raise ArgumentError, ~r/only supported for.*ConCacheStore/, fn ->
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => {SomeOtherModule, []}})
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
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => GetPutOnlyStore})
      end
    end

    test "accepts store: false (explicit opt-out of dedup)" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => false})
    end
  end

  describe "verify/2 — simulation unexpected response" do
    test "malformed RPC response without result or error keys", %{charge: charge} do
      # Simulation only runs on async path (wait_for_confirmation: false)
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "wait_for_confirmation", false)
      }

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      # Stub eth_simulateV1 (simulation) to return a malformed response
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_simulateV1" ->
            # Malformed: no "result" or "error" key
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "unexpected" => "field", "id" => 1})

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Pre-broadcast simulation failed"
    end
  end

  describe "verify/2 — missing required config" do
    test "missing rpc_url returns error" do
      {:ok, charge} =
        Charge.new(
          amount: "1000000",
          currency: @token_address,
          recipient: @recipient
        )

      # method_details without rpc_url
      charge = %{
        charge
        | method_details: %{
            "chain_id" => 42_431,
            "req_options" => [plug: {Req.Test, Tempo}]
          }
      }

      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "rpc_url"
    end
  end

  # --- Test helpers ---

  # Stubs a successful JSON-RPC response wrapping the given receipt map.
  defp stub_receipt(receipt) do
    stub_receipt_response(%{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
  end

  defp stub_receipt_and_transaction_from(receipt, from) do
    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "eth_getTransactionReceipt" -> receipt
          "eth_getTransactionByHash" -> %{"from" => from, "hash" => @tx_hash}
          _other -> nil
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => result, "id" => request["id"]})
    end)
  end

  defp machine_token_swapper, do: MachineToken.settlement_sender(42_431)

  defp machine_token_token, do: MachineToken.token(42_431)

  defp machine_token_calls(amount, memo) do
    token = machine_token_token()
    swapper = machine_token_swapper()

    [
      build_call(token, approve_calldata(swapper, amount)),
      build_call(swapper, swap_to_calldata(token, amount, @token_address, @recipient, memo))
    ]
  end

  defp enable_machine_token(charge) do
    %{charge | method_details: Map.put(charge.method_details, "machine_token_enabled", true)}
  end

  # Stubs a raw JSON-RPC response body.
  defp stub_receipt_response(response_body) do
    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, response_body)
    end)
  end

  # Builds a successful receipt with a matching Transfer log.
  # Override individual fields with opts.
  defp success_receipt(opts \\ []) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)

    default_logs = [transfer_log(amount: amount, to: to, token: token)]
    logs = Keyword.get(opts, :logs, default_logs)

    %{
      "status" => "0x1",
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1a",
      # --- Coverage: store error paths and edge cases ---
      "blockHash" => "0x" <> String.duplicate("00", 32),
      "logs" => logs
    }
  end

  # Builds a reverted receipt (status 0x0).
  defp reverted_receipt do
    %{success_receipt() | "status" => "0x0"}
  end

  # Builds a raw ERC-20 Transfer log entry matching JSON-RPC format.
  defp transfer_log(opts) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    from = Keyword.get(opts, :from, "0x" <> String.duplicate("00", 20))
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)

    # ERC-20 Transfer: 3 topics [topic0, from_padded, to_padded] + value in data
    from_padded = "0x" <> String.pad_leading(strip_0x(from), 64, "0")
    to_padded = "0x" <> String.pad_leading(strip_0x(to), 64, "0")
    data = "0x" <> String.pad_leading(Integer.to_string(amount, 16), 64, "0")

    %{
      "address" => token,
      "topics" => [@transfer_topic, from_padded, to_padded],
      "data" => data,
      "blockNumber" => "0x1a",
      "transactionHash" => @tx_hash,
      "logIndex" => "0x0"
    }
  end

  # Builds a raw TIP-20 TransferWithMemo log entry matching real Moderato JSON-RPC format.
  # The memo is indexed, so it appears in topics[3]; data contains only the amount.
  defp transfer_with_memo_log(opts) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    from = Keyword.get(opts, :from, "0x" <> String.duplicate("00", 20))
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)
    memo = Keyword.get(opts, :memo, @test_memo)

    from_padded = "0x" <> String.pad_leading(strip_0x(from), 64, "0")
    to_padded = "0x" <> String.pad_leading(strip_0x(to), 64, "0")

    memo_topic = "0x" <> String.pad_leading(strip_0x(memo), 64, "0")
    amount_hex = String.pad_leading(Integer.to_string(amount, 16), 64, "0")
    data = "0x" <> amount_hex

    %{
      "address" => token,
      "topics" => [@transfer_with_memo_topic, from_padded, to_padded, memo_topic],
      "data" => data,
      "blockNumber" => "0x1a",
      "transactionHash" => @tx_hash,
      "logIndex" => "0x0"
    }
  end

  defp attribution_memo(realm, challenge_id) do
    tag = binary_part(ExSha3.keccak_256("mpp"), 0, 4)
    server = binary_part(ExSha3.keccak_256(realm), 0, 10)
    client = <<0::80>>
    nonce = binary_part(ExSha3.keccak_256(challenge_id), 0, 7)

    "0x" <> Base.encode16(tag <> <<1>> <> server <> client <> nonce, case: :lower)
  end

  describe "validate_config!/1 — fee payer" do
    @fee_payer_key String.duplicate("ab", 32)
    @fee_payer_token "0x20C0000000000000000000000000000000000000"

    test "accepts valid fee payer config" do
      assert :ok =
               Tempo.validate_config!(%{
                 "rpc_url" => @rpc_url,
                 "fee_payer" => true,
                 "fee_payer_private_key" => @fee_payer_key,
                 "fee_token" => @fee_payer_token,
                 "store" => ConCacheStore
               })
    end

    test "requires an explicitly selected atomic sponsor store" do
      base = %{
        "rpc_url" => @rpc_url,
        "fee_payer" => true,
        "fee_payer_private_key" => @fee_payer_key,
        "fee_token" => @fee_payer_token
      }

      assert_raise ArgumentError, ~r/requires an explicit store/, fn ->
        Tempo.validate_config!(base)
      end

      assert_raise ArgumentError, ~r/requires an explicit store/, fn ->
        Tempo.validate_config!(Map.put(base, "store", false))
      end

      assert_raise ArgumentError, ~r/atomic store implementing update\/3/, fn ->
        Tempo.validate_config!(Map.put(base, "store", FailingPutStore))
      end
    end

    test "rejects invalid or inconsistent aggregate limits" do
      base = %{
        "rpc_url" => @rpc_url,
        "fee_payer" => true,
        "fee_payer_private_key" => @fee_payer_key,
        "fee_token" => @fee_payer_token,
        "store" => ConCacheStore
      }

      for value <- [0, -1, "100"] do
        config = put_in(base["fee_payer_policy"], %{"max_in_flight_reservations" => value})

        assert_raise ArgumentError, ~r/max_in_flight_reservations must be a positive integer/, fn ->
          Tempo.validate_config!(config)
        end
      end

      config =
        put_in(base["fee_payer_policy"], %{
          "max_total_fee" => 10,
          "max_in_flight_total_fee" => 9
        })

      assert_raise ArgumentError, ~r/max_in_flight_total_fee must be greater than or equal/, fn ->
        Tempo.validate_config!(config)
      end
    end

    test "requires the local sponsor identity to be derivable" do
      assert_raise ArgumentError, ~r/could not derive the local sponsor identity/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => String.duplicate("00", 32),
          "fee_token" => @fee_payer_token,
          "store" => ConCacheStore
        })
      end
    end

    test "raises when fee_payer true but missing fee_payer_private_key" do
      assert_raise ArgumentError, ~r/fee_payer_private_key/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_token" => @fee_payer_token
        })
      end
    end

    test "raises when fee_payer true but missing fee_token" do
      assert_raise ArgumentError, ~r/fee_token/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key
        })
      end
    end

    test "raises on invalid fee_payer_private_key (wrong length)" do
      assert_raise ArgumentError, ~r/fee_payer_private_key/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => "deadbeef",
          "fee_token" => @fee_payer_token
        })
      end
    end

    test "raises on invalid fee_token (wrong length)" do
      assert_raise ArgumentError, ~r/fee_token/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key,
          "fee_token" => "0xdead"
        })
      end
    end

    test "skips fee payer validation when fee_payer is false" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "fee_payer" => false})
    end

    test "skips fee payer validation when fee_payer is absent" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url})
    end

    test "accepts a valid fee_payer_allowed_fee_tokens list" do
      assert :ok =
               Tempo.validate_config!(%{
                 "rpc_url" => @rpc_url,
                 "fee_payer" => true,
                 "fee_payer_private_key" => @fee_payer_key,
                 "fee_token" => @fee_payer_token,
                 "store" => ConCacheStore,
                 "fee_payer_allowed_fee_tokens" => [@fee_payer_token]
               })
    end

    test "raises when fee_payer_allowed_fee_tokens contains an invalid address" do
      assert_raise ArgumentError, ~r/fee_payer_allowed_fee_tokens must be a list of 20-byte hex addresses/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key,
          "fee_token" => @fee_payer_token,
          "store" => ConCacheStore,
          "fee_payer_allowed_fee_tokens" => [@fee_payer_token, "0xdead", 123]
        })
      end
    end

    test "raises when fee_payer_allowed_fee_tokens contains a non-binary element" do
      assert_raise ArgumentError, ~r/fee_payer_allowed_fee_tokens must be a list of 20-byte hex addresses/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key,
          "fee_token" => @fee_payer_token,
          "store" => ConCacheStore,
          "fee_payer_allowed_fee_tokens" => [123, @fee_payer_token]
        })
      end
    end

    test "raises when fee_payer_allowed_fee_tokens is not a list" do
      assert_raise ArgumentError, ~r/fee_payer_allowed_fee_tokens must be a list of hex addresses/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key,
          "fee_token" => @fee_payer_token,
          "store" => ConCacheStore,
          "fee_payer_allowed_fee_tokens" => "not-a-list"
        })
      end
    end
  end

  describe "verify/2 — hash + fee_payer rejection" do
    test "rejects type=hash when fee_payer is true", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", true)}

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "hash"
      assert error.detail =~ "feePayer"
    end

    test "allows type=hash when fee_payer is false", %{charge: charge} do
      stub_receipt(success_receipt())
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", false)}

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  describe "verify/2 — fee payer co-signing" do
    # Hardhat default test keys (testnet only, no security concern).
    @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    @fee_payer_private_key "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    @fee_token_address "0x20C0000000000000000000000000000000000000"

    setup %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => @fee_payer_private_key,
              "fee_token" => @fee_token_address,
              "store" => start_sponsor_store()
            })
      }

      {:ok, charge: charge}
    end

    test "co-signs and broadcasts fee payer transaction", %{charge: charge} do
      # Build a real signed tx with fee payer placeholder using TempoTxBuilder
      {:ok, tx_hex} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: @client_private_key,
          token: @token_address,
          recipient: @recipient,
          amount: 1_000_000,
          chain_id: 42_431,
          rpc_url: @rpc_url,
          # Pin gas so the builder skips eth_estimateGas — this test stubs RPC;
          # an omitted gas_limit would make a real network call.
          gas_limit: 1_000_000,
          nonce: 0,
          nonce_key: expiring_nonce_key_int(),
          valid_before: future_valid_before()
        )

      # Stub broadcast — server will co-sign then broadcast the modified tx
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"], request["params"]})

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"

      # Verify the broadcast used a DIFFERENT hex than the original (co-signed version)
      assert_received {:rpc_call, "eth_sendRawTransactionSync", [broadcast_hex]}
      assert broadcast_hex != tx_hex
      assert String.starts_with?(broadcast_hex, "0x76")
      assert :not_found = sponsor_budget_state(charge, @fee_payer_private_key)
    end

    test "rejects a reverting CO-SIGNED sponsored tx before the fee payer broadcasts", %{charge: charge} do
      # The actual gas-drain threat: the server co-signs as fee payer, so the SPONSOR
      # pays gas. Simulate the co-signed tx → it would revert (status 0x0) → reject
      # before broadcast, so the sponsor never commits gas for a doomed transaction.
      {:ok, tx_hex} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: @client_private_key,
          token: @token_address,
          recipient: @recipient,
          amount: 1_000_000,
          chain_id: 42_431,
          rpc_url: @rpc_url,
          gas_limit: 1_000_000,
          nonce: 0,
          nonce_key: expiring_nonce_key_int(),
          valid_before: future_valid_before()
        )

      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_simulateV1" ->
            # Co-signed tx would run out of gas / revert on-chain → status 0x0.
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "result" => [%{"calls" => [%{"status" => "0x0"}]}],
              "id" => 1
            })

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Pre-broadcast simulation rejected"

      # The co-signed tx was simulated, but the sponsor NEVER broadcast it.
      assert_received {:rpc_call, "eth_simulateV1"}
      refute_received {:rpc_call, "eth_sendRawTransactionSync"}
      refute_received {:rpc_call, "eth_sendRawTransaction"}
      assert :not_found = sponsor_budget_state(charge, @fee_payer_private_key)
    end

    test "rejects transaction without fee_payer_signature placeholder", %{charge: charge} do
      # Build a normal tx (no fee payer placeholder) with otherwise-valid gas
      # economics, so the placeholder check is what rejects it.
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)

      tx_hex =
        build_tempo_tx(
          calls: [call],
          chain_id: 42_431,
          fee_payer: false,
          gas_limit: 51_299,
          max_fee_per_gas: 1_000_000_000,
          max_priority_fee_per_gas: 1_000_000_000,
          nonce_key: expiring_nonce_key(),
          valid_before: future_valid_before()
        )

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "placeholder"
      assert :not_found = sponsor_budget_state(charge, @fee_payer_private_key)
    end

    test "rejects transaction with non-empty fee_token", %{charge: charge} do
      # Build a tx with fee_payer placeholder but with fee_token set
      # (client shouldn't set fee_token when requesting fee sponsorship)
      calldata = transfer_calldata(@recipient, 1_000_000)
      call_rlp = build_call(@token_address, calldata)
      token_bytes = decode_address(@token_address)

      body = [
        :binary.encode_unsigned(42_431),
        :binary.encode_unsigned(1_000_000_000),
        :binary.encode_unsigned(1_000_000_000),
        :binary.encode_unsigned(51_299),
        [call_rlp],
        [],
        expiring_nonce_key(),
        <<>>,
        :binary.encode_unsigned(future_valid_before()),
        <<>>,
        token_bytes,
        <<0x00>>,
        [],
        <<1::512>>
      ]

      raw = <<0x76>> <> ExRLP.encode(body)
      tx_hex = "0x" <> Base.encode16(raw, case: :lower)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "fee_token"
      assert :not_found = sponsor_budget_state(charge, @fee_payer_private_key)
    end

    test "retains a broadcasting reservation when the broadcast response is lost", %{charge: charge} do
      {:ok, tx_hex} = build_sponsored_client_tx(nonce: 7)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(body)["method"] do
          "eth_simulateV1" -> Req.Test.json(conn, simulate_success_body())
          "eth_sendRawTransactionSync" -> Req.Test.transport_error(conn, :timeout)
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{detail: "Tempo RPC request failed"}} = Tempo.verify(payload, charge)
      assert {:ok, state} = sponsor_budget_state(charge, @fee_payer_private_key)
      assert [%{phase: :broadcasting}] = Map.values(state.reservations)
    end

    test "releases on a terminal receipt before payment-domain validation", %{charge: charge} do
      {:ok, tx_hex} = build_sponsored_client_tx(nonce: 8)
      stub_broadcast_and_receipt(reverted_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "reverted"
      assert :not_found = sponsor_budget_state(charge, @fee_payer_private_key)
    end

    test "retains async sponsorship and rejects the next request with retry timing", %{charge: charge} do
      limit = 25_000_000_000_000_000

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "wait_for_confirmation" => false,
              "fee_payer_policy" => %{
                "max_total_fee" => limit,
                "max_in_flight_total_fee" => limit,
                "max_in_flight_reservations" => 1
              }
            })
      }

      {:ok, first_tx} = build_sponsored_client_tx(nonce: 9)
      stub_optimistic_flow(@tx_hash)

      assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "transaction", "signature" => first_tx}, charge)
      assert {:ok, state} = sponsor_budget_state(charge, @fee_payer_private_key)
      assert [%{phase: :pending, tx_hash: @tx_hash}] = Map.values(state.reservations)

      {:ok, second_tx} = build_sponsored_client_tx(nonce: 10)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "sponsor_budget_reconcile", true)
      }

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(body)["method"] do
          "eth_getTransactionReceipt" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})

          other ->
            flunk("Unexpected RPC method while reconciling sponsor capacity: #{other}")
        end
      end)

      assert {:error, %Errors{} = error} =
               Tempo.verify(%{"type" => "transaction", "signature" => second_tx}, charge)

      assert error.type == "https://zenhive.github.io/mpp/problems/sponsor-capacity-exhausted"
      assert error.retry_after > 0
      refute error.detail =~ "25000000000000000"
    end

    test "enforces fail-closed accounting before broadcast and retains ownership afterward", %{charge: charge} do
      {:ok, reserve_failure_tx} = build_sponsored_client_tx(nonce: 11)
      :ok = SponsorLifecycleStore.configure(1)
      reserve_failure_charge = put_in(charge.method_details["store"], SponsorLifecycleStore)

      assert {:error, %Errors{} = reserve_error} =
               Tempo.verify(%{"type" => "transaction", "signature" => reserve_failure_tx}, reserve_failure_charge)

      assert reserve_error.detail == "Tempo sponsorship is temporarily unavailable"

      {:ok, store_failure_tx} = build_sponsored_client_tx(nonce: 12)
      missing_store_charge = put_in(charge.method_details["store"], false)

      assert {:error, %Errors{} = store_error} =
               Tempo.verify(%{"type" => "transaction", "signature" => store_failure_tx}, missing_store_charge)

      assert store_error.detail == "Tempo sponsorship is temporarily unavailable"

      {:ok, transition_failure_tx} = build_sponsored_client_tx(nonce: 13)
      :ok = SponsorLifecycleStore.configure(2)
      transition_failure_charge = put_in(charge.method_details["store"], SponsorLifecycleStore)
      stub_broadcast_and_receipt(success_receipt())

      assert {:error, %Errors{} = transition_error} =
               Tempo.verify(%{"type" => "transaction", "signature" => transition_failure_tx}, transition_failure_charge)

      assert transition_error.detail == "Tempo sponsorship is temporarily unavailable"

      {:ok, release_failure_tx} = build_sponsored_client_tx(nonce: 14)
      :ok = SponsorLifecycleStore.configure(3)
      release_failure_charge = put_in(charge.method_details["store"], SponsorLifecycleStore)
      stub_broadcast_and_receipt(success_receipt())

      assert {:ok, %Receipt{}} =
               Tempo.verify(%{"type" => "transaction", "signature" => release_failure_tx}, release_failure_charge)

      {:ok, pending_failure_tx} = build_sponsored_client_tx(nonce: 15)
      :ok = SponsorLifecycleStore.configure(3)

      pending_failure_charge =
        charge
        |> put_in([Access.key(:method_details), "store"], SponsorLifecycleStore)
        |> put_in([Access.key(:method_details), "wait_for_confirmation"], false)

      stub_optimistic_flow(@tx_hash)

      assert {:ok, %Receipt{}} =
               Tempo.verify(%{"type" => "transaction", "signature" => pending_failure_tx}, pending_failure_charge)
    end

    test "passes through when fee_payer is false (no co-signing)", %{charge: charge} do
      # Disable fee_payer
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", false)}

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  describe "verify/2 — fee payer gas economics (gas-draining defense)" do
    @fee_payer_private_key_econ "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    @fee_token_address_econ "0x20C0000000000000000000000000000000000000"

    setup %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => @fee_payer_private_key_econ,
              "fee_token" => @fee_token_address_econ,
              "store" => start_sponsor_store()
            })
      }

      {:ok, charge: charge}
    end

    # Builds a fee-payer tx carrying a valid payment call (so find_payment_call
    # passes) plus attacker-chosen gas economics. No RPC stubs — economics
    # validation must reject before any broadcast.
    defp econ_tx(opts) do
      call = build_call(@token_address, transfer_calldata(@recipient, 1_000_000))
      build_tempo_tx([calls: [call], chain_id: 42_431, fee_payer: true] ++ opts)
    end

    test "rejects inflated max_fee_per_gas (GHSA-vv77-66rf-pm86)", %{charge: charge} do
      # 1 ETH/gas — would drain the sponsor's wallet.
      tx_hex = econ_tx(max_fee_per_gas: 1_000_000_000_000_000_000, gas_limit: 21_000)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "max_fee_per_gas"
    end

    test "rejects a total fee budget over the cap", %{charge: charge} do
      # Each field in range, product over the 0.05 ETH cap.
      tx_hex =
        econ_tx(
          gas_limit: 2_000_000,
          max_fee_per_gas: 100_000_000_000,
          max_priority_fee_per_gas: 50_000_000_000
        )

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "total fee budget"
    end

    test "rejects a padded access list (GHSA-qpxh-ff8m-c62v)", %{charge: charge} do
      access_list = for _ <- 1..137, do: [<<0::160>>, []]
      tx_hex = econ_tx(access_list: access_list)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "access list"
    end

    test "honors a fee_payer_policy override", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "fee_payer_policy", %{"max_fee_per_gas" => 1})
      }

      # 2 Gwei now exceeds the lowered 1-wei ceiling.
      tx_hex = econ_tx(max_fee_per_gas: 2_000_000_000, max_priority_fee_per_gas: 1, gas_limit: 21_000)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "max_fee_per_gas"
    end
  end

  describe "verify/2 — fee payer call scope validation" do
    @fee_payer_private_key_scope "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    @fee_token_address_scope "0x20C0000000000000000000000000000000000000"

    setup %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => @fee_payer_private_key_scope,
              "fee_token" => @fee_token_address_scope,
              "store" => start_sponsor_store()
            })
      }

      {:ok, charge: charge}
    end

    test "rejects rogue extra call in fee-payer transaction", %{charge: charge} do
      # transfer + rogue transfer = 2 calls, doesn't match any callScope
      calldata = transfer_calldata(@recipient, 1_000_000)
      rogue_calldata = transfer_calldata(@recipient, 999)
      call1 = build_call(@token_address, calldata)
      call2 = build_call(@token_address, rogue_calldata)
      tx_hex = build_tempo_tx(calls: [call1, call2], chain_id: 42_431, fee_payer: true)

      # No RPC stubs needed — validation fires before broadcast
      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "disallowed call pattern"
    end

    test "rejects valid transfer + rogue unknown selector in fee-payer transaction", %{charge: charge} do
      # Valid transfer (so find_payment_call passes) + unknown rogue call
      valid_call = build_call(@token_address, transfer_calldata(@recipient, 1_000_000))
      unknown = <<0xDE, 0xAD, 0xBE, 0xEF>> <> :binary.copy(<<0>>, 64)
      rogue_call = build_call(@token_address, unknown)
      tx_hex = build_tempo_tx(calls: [valid_call, rogue_call], chain_id: 42_431, fee_payer: true)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "disallowed call pattern"
    end

    test "passes through when fee_payer is false (no scope validation)", %{charge: charge} do
      # Disable fee_payer — rogue calls should not be rejected
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", false)}

      # Two transfers would fail scope validation, but fee_payer is false
      calldata = transfer_calldata(@recipient, 1_000_000)
      call1 = build_call(@token_address, calldata)
      call2 = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call1, call2], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "skips DEX call-scope when the canonical machine-token route matches", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "machine_token_enabled", true)}
      memo = @test_memo
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", memo)}

      tx_hex = build_tempo_tx(calls: machine_token_calls(1_000_000, memo), chain_id: 42_431, fee_payer: true)

      stub_broadcast_and_receipt(
        success_receipt(logs: [transfer_with_memo_log(from: machine_token_swapper(), memo: memo)])
      )

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  # Stubs the optimistic flow: pre-broadcast eth_simulateV1 succeeds, then
  # eth_sendRawTransaction returns the tx hash.
  defp stub_optimistic_flow(tx_hash) do
    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "eth_simulateV1" ->
          Req.Test.json(conn, simulate_success_body())

        "eth_sendRawTransaction" ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => tx_hash, "id" => 1})
      end
    end)
  end

  # Stubs the confirmation flow: pre-broadcast eth_simulateV1 succeeds, then
  # eth_sendRawTransactionSync returns a receipt directly (synchronous broadcast).
  defp stub_broadcast_and_receipt(receipt) do
    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "eth_simulateV1" ->
          Req.Test.json(conn, simulate_success_body())

        "eth_sendRawTransactionSync" ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})

        other ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1, "_method" => other})
      end
    end)
  end

  # eth_simulateV1 success response body: one block, one call with status 0x1.
  defp simulate_success_body do
    %{"jsonrpc" => "2.0", "result" => [%{"calls" => [%{"status" => "0x1"}]}], "id" => 1}
  end

  describe "verify/2 — proof credentials (zero-amount)" do
    @proof_account "0x1a642f0E3c3aF545E7AcBD38b07251B3990914F1"
    @proof_signature "0x53f5d64d9f995e841b4212639b2e17e508e96752e10316df3814a16443dcbdb626c082190a4c3ecc3148101eb443d15bd83b579380b1be735a9c99f0df36c9fe1b"
    @proof_challenge_id "kM9xPqWvT2nJrHsY4aDfEb"

    setup %{charge: charge} do
      zero_charge = %{
        charge
        | amount: "0",
          method_details:
            Map.merge(charge.method_details, %{
              "challenge_id" => @proof_challenge_id,
              "realm" => "api.example.com",
              "credential_source" => "did:pkh:eip155:42431:#{@proof_account}"
            })
      }

      {:ok, charge: zero_charge}
    end

    test "accepts a valid proof credential for zero-amount charge", %{charge: charge} do
      payload = %{"type" => "proof", "signature" => @proof_signature}

      assert {:ok, %Receipt{reference: @proof_challenge_id}} = Tempo.verify(payload, charge)
    end

    test "rejects proof for non-zero amount", %{charge: charge} do
      charge = %{charge | amount: "1000"}
      payload = %{"type" => "proof", "signature" => @proof_signature}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "zero-amount"
    end

    test "rejects hash credential for zero-amount charge", %{charge: charge} do
      payload = %{"type" => "hash", "hash" => @tx_hash}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "proof credential"
    end

    test "rejects proof without source", %{charge: charge} do
      charge = put_in(charge.method_details["credential_source"], nil)
      payload = %{"type" => "proof", "signature" => @proof_signature}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "source"
    end

    test "rejects proof with a non-binary credential_source", %{charge: charge} do
      charge = put_in(charge.method_details["credential_source"], 12_345)
      payload = %{"type" => "proof", "signature" => @proof_signature}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "source"
    end

    test "rejects proof credential missing the signature field", %{charge: charge} do
      payload = %{"type" => "proof"}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "rejects proof credential with a non-binary signature", %{charge: charge} do
      payload = %{"type" => "proof", "signature" => 42}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "accepts proof signed by an authorized access key for the root source", %{charge: charge} do
      root_private_key = Base.decode16!(String.duplicate("01", 32), case: :mixed)
      access_private_key = Base.decode16!(String.duplicate("02", 32), case: :mixed)
      {:ok, root_address} = Curvy.get_address(root_private_key)
      {:ok, access_address} = Curvy.get_address(access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)

      charge =
        put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{root_hex}")

      proof_params = %{
        account: root_hex,
        chain_id: 42_431,
        challenge_id: @proof_challenge_id,
        realm: "api.example.com"
      }

      signature = sign_access_key_proof!(proof_params, access_private_key, access_address)
      stub_active_access_key_metadata!()

      payload = %{"type" => "proof", "signature" => signature}
      assert {:ok, %Receipt{reference: @proof_challenge_id}} = Tempo.verify(payload, charge)
    end

    test "rejects proof signed by a revoked access key for the root source", %{charge: charge} do
      root_private_key = Base.decode16!(String.duplicate("01", 32), case: :mixed)
      access_private_key = Base.decode16!(String.duplicate("02", 32), case: :mixed)
      {:ok, root_address} = Curvy.get_address(root_private_key)
      {:ok, access_address} = Curvy.get_address(access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)

      charge =
        put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{root_hex}")

      proof_params = %{
        account: root_hex,
        chain_id: 42_431,
        challenge_id: @proof_challenge_id,
        realm: "api.example.com"
      }

      signature = sign_access_key_proof!(proof_params, access_private_key, access_address)
      stub_active_access_key_metadata!(revoked: true)

      payload = %{"type" => "proof", "signature" => signature}

      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Proof signature does not match source"
    end
  end

  describe "verify/2 — presenter binding (hash credential)" do
    setup %{charge: charge} do
      wallet_key = Base.decode16!(String.duplicate("01", 32), case: :mixed)
      attacker_key = Base.decode16!(String.duplicate("02", 32), case: :mixed)
      {:ok, wallet_addr} = Curvy.get_address(wallet_key)
      {:ok, attacker_addr} = Curvy.get_address(attacker_key)

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "challenge_id" => @challenge_id,
              "realm" => @realm,
              "require_presenter_binding" => true
            })
      }

      {:ok,
       charge: charge,
       wallet: %{key: wallet_key, address: wallet_addr, hex: "0x" <> Base.encode16(wallet_addr, case: :lower)},
       attacker: %{key: attacker_key, address: attacker_addr, hex: "0x" <> Base.encode16(attacker_addr, case: :lower)}}
    end

    test "accepts a hash credential with a valid presenter signature", %{charge: charge, wallet: wallet} do
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")
      signature = sign_access_key_proof!(presenter_params(wallet.hex), wallet.key, wallet.address)
      memo = attribution_memo(@realm, @challenge_id)
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(from: wallet.hex, memo: memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "regression (GHSA-34g7-vx6g-82mq residual): a third party cannot claim an observed transfer against their own challenge",
         %{charge: charge, wallet: wallet, attacker: attacker} do
      # The attacker holds their own wallet and presents a VALID presenter signature
      # over their own account — but the observed settled transfer was sent by the
      # victim's wallet, so the source/sender match fails and the claim is rejected.
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{attacker.hex}")
      signature = sign_access_key_proof!(presenter_params(attacker.hex), attacker.key, attacker.address)
      memo = attribution_memo(@realm, @challenge_id)
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(from: wallet.hex, memo: memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects a presenter signature that does not recover to the claimed source",
         %{charge: charge, wallet: wallet, attacker: attacker} do
      # Attacker claims the victim's wallet as source but can only sign with their own key.
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")
      signature = sign_access_key_proof!(presenter_params(wallet.hex), attacker.key, attacker.address)
      stub_active_access_key_metadata!(revoked: true)

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Presenter signature does not match the transfer sender"
    end

    test "rejects a presenter signature bound to a different challenge", %{charge: charge, wallet: wallet} do
      # A signature captured for challenge A is useless for challenge B: challengeId
      # is inside the signed EIP-712 digest.
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")
      signature = sign_access_key_proof!(presenter_params(wallet.hex, "other-challenge"), wallet.key, wallet.address)
      stub_active_access_key_metadata!(revoked: true)

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Presenter signature does not match the transfer sender"
    end

    test "rejects a hash credential without presenterSignature when binding is required",
         %{charge: charge, wallet: wallet} do
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "Presenter binding is required"
    end

    test "rejects presenterSignature without a credential source", %{charge: charge, wallet: wallet} do
      signature = sign_access_key_proof!(presenter_params(wallet.hex), wallet.key, wallet.address)

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "requires a credential source"
    end

    test "rejects a non-binary presenterSignature", %{charge: charge, wallet: wallet} do
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => 42}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "presenterSignature"
    end

    test "accepts an access-key presenter signature for the transfer sender",
         %{charge: charge, wallet: wallet, attacker: attacker} do
      # attacker's key here plays the role of an on-chain-authorized access key
      # delegated by the wallet (the transfer sender).
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")
      signature = sign_access_key_proof!(presenter_params(wallet.hex), attacker.key, attacker.address)
      memo = attribution_memo(@realm, @challenge_id)
      stub_receipt_and_access_key!(success_receipt(logs: [transfer_with_memo_log(from: wallet.hex, memo: memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "accepts a valid presenter signature when binding is not required", %{charge: charge, wallet: wallet} do
      charge = put_in(charge.method_details["require_presenter_binding"], false)
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")
      signature = sign_access_key_proof!(presenter_params(wallet.hex), wallet.key, wallet.address)
      memo = attribution_memo(@realm, @challenge_id)
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(from: wallet.hex, memo: memo)]))

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => signature}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "rejects an invalid provided presenter signature even when binding is not required",
         %{charge: charge, wallet: wallet} do
      charge = put_in(charge.method_details["require_presenter_binding"], false)
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{wallet.hex}")

      payload = %{"type" => "hash", "hash" => @tx_hash, "presenterSignature" => "0xdeadbeef"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Presenter signature does not match the transfer sender"
    end
  end

  describe "verify/2 — presenter binding (transaction credential)" do
    setup %{charge: charge} do
      memo = attribution_memo(@realm, @challenge_id)
      calldata = transfer_with_memo_calldata(@recipient, 1_000_000, memo)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "challenge_id" => @challenge_id,
              "realm" => @realm,
              "require_presenter_binding" => true
            })
      }

      {:ok, charge: charge, tx_hex: tx_hex, memo: memo}
    end

    test "accepts a transaction credential with a valid presenter signature (source matching sender)",
         %{charge: charge, tx_hex: tx_hex, memo: memo} do
      sender_hex = test_sender_address()
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{sender_hex}")
      signature = sign_presenter_by_test_sender!(presenter_params(sender_hex))
      stub_broadcast_and_receipt(success_receipt(logs: [transfer_with_memo_log(from: sender_hex, memo: memo)]))

      payload = %{"type" => "transaction", "signature" => tx_hex, "presenterSignature" => signature}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end

    test "rejects a transaction credential without presenterSignature when binding is required",
         %{charge: charge, tx_hex: tx_hex} do
      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "Presenter binding is required"
    end

    test "rejects a credential source that does not match the transaction sender",
         %{charge: charge, tx_hex: tx_hex} do
      other = "0x2222222222222222222222222222222222222222"
      charge = put_in(charge.method_details["credential_source"], "did:pkh:eip155:42431:#{other}")
      signature = sign_presenter_by_test_sender!(presenter_params(test_sender_address()))

      payload = %{"type" => "transaction", "signature" => tx_hex, "presenterSignature" => signature}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Credential source does not match the transaction sender"
    end

    test "rejects a presenter signature from a wallet other than the transaction sender",
         %{charge: charge, tx_hex: tx_hex} do
      attacker_key = Base.decode16!(String.duplicate("02", 32), case: :mixed)
      {:ok, attacker_addr} = Curvy.get_address(attacker_key)
      signature = sign_access_key_proof!(presenter_params(test_sender_address()), attacker_key, attacker_addr)
      stub_active_access_key_metadata!(revoked: true)

      payload = %{"type" => "transaction", "signature" => tx_hex, "presenterSignature" => signature}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Presenter signature does not match the transfer sender"
    end

    test "rejects an invalid provided presenter signature even when binding is not required",
         %{charge: charge, tx_hex: tx_hex} do
      charge = put_in(charge.method_details["require_presenter_binding"], false)

      payload = %{"type" => "transaction", "signature" => tx_hex, "presenterSignature" => "0xdeadbeef"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "Presenter signature does not match the transfer sender"
    end
  end

  defp presenter_params(account_hex, challenge_id \\ @challenge_id) do
    %{account: account_hex, chain_id: 42_431, challenge_id: challenge_id, realm: @realm}
  end

  defp sign_presenter_by_test_sender!(params) do
    key = test_sender_key()
    {:ok, addr} = Curvy.get_address(key)
    sign_access_key_proof!(params, key, addr)
  end

  defp sign_access_key_proof!(params, private_key, address) do
    digest = MPP.Methods.Tempo.Proof.hash(params)
    {:ok, sig} = Curvy.sign_payload(digest, private_key)
    sig = Cartouche.Recover.normalize_low_s(sig)
    {:ok, recid} = Cartouche.Recover.find_recid_from_digest(digest, sig, address)

    r = sig.r |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    s = sig.s |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    "0x" <> r <> s <> Base.encode16(<<27 + recid>>, case: :lower)
  end

  defp stub_active_access_key_metadata!(opts \\ []) do
    result = access_key_metadata_result(Keyword.get(opts, :revoked, false))

    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      rpc_result =
        if request["method"] == "eth_call" do
          result
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => rpc_result, "id" => request["id"]})
    end)
  end

  # Combined stub for flows that verify an access-key signature (eth_call) AND
  # fetch a tx receipt (eth_getTransactionReceipt) in the same verification.
  defp stub_receipt_and_access_key!(receipt) do
    metadata = access_key_metadata_result(false)

    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      rpc_result =
        case request["method"] do
          "eth_call" -> metadata
          "eth_getTransactionReceipt" -> receipt
          _other -> nil
        end

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => rpc_result, "id" => request["id"]})
    end)
  end

  # ABI-encoded AccountKeychain.getKey metadata blob (key, expiry, revoked flag).
  defp access_key_metadata_result(revoked?) do
    access_key = "0x5050a4f4b3f9338c3472dcc01a87c76a144b3c9c"
    key = Base.decode16!(String.replace_prefix(access_key, "0x", ""), case: :mixed)
    expiry_bin = 4_000_000_000 |> :binary.encode_unsigned() |> pad_word32()
    revoked_bin = if(revoked?, do: pad_word32(1), else: pad_word32(0))

    "0x" <>
      ([
         pad_word32(0),
         :binary.copy(<<0>>, 12) <> key,
         expiry_bin,
         pad_word32(0),
         revoked_bin
       ]
       |> IO.iodata_to_binary()
       |> Base.encode16(case: :lower))
  end

  defp pad_word32(value) when is_integer(value), do: value |> :binary.encode_unsigned() |> pad_word32()
  defp pad_word32(bin) when byte_size(bin) <= 32, do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin

  describe "verify/2 — fee payer token allowlist" do
    @fee_payer_key_allow "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    @rogue_token "0x1111111111111111111111111111111111111111"

    setup %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => @fee_payer_key_allow,
              "fee_token" => @rogue_token,
              "store" => start_sponsor_store()
            })
      }

      {:ok, charge: charge}
    end

    test "rejects non-allowlisted fee_token before broadcast", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      tx_hex = build_tempo_tx(calls: [build_call(@token_address, calldata)], chain_id: 42_431, fee_payer: true)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "not allowed"
    end

    test "accepts custom allowlisted fee_token override", %{charge: charge} do
      charge =
        put_in(charge.method_details["fee_payer_allowed_fee_tokens"], [@rogue_token])

      calldata = transfer_calldata(@recipient, 1_000_000)
      tx_hex = build_tempo_tx(calls: [build_call(@token_address, calldata)], chain_id: 42_431, fee_payer: true)

      stub_broadcast_and_receipt(success_receipt())
      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, _} = Tempo.verify(payload, charge)
    end
  end

  describe "validate_config!/1 — hosted fee payer" do
    @hosted_url "https://sponsor.moderato.tempo.xyz"

    test "accepts fee_payer_url without local key material" do
      assert :ok =
               Tempo.validate_config!(%{
                 "rpc_url" => @rpc_url,
                 "fee_payer_url" => @hosted_url,
                 "sponsor_budget_id" => "Hosted-Wallet",
                 "store" => ConCacheStore
               })
    end

    test "requires an explicit hosted sponsor budget identity" do
      assert_raise ArgumentError, ~r/requires a non-empty sponsor_budget_id/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer_url" => @hosted_url,
          "store" => ConCacheStore
        })
      end
    end

    test "raises when fee_payer_url is combined with fee_payer_private_key" do
      assert_raise ArgumentError, ~r/cannot be combined/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer_url" => @hosted_url,
          "fee_payer_private_key" => String.duplicate("ab", 32)
        })
      end
    end

    test "raises on invalid fee_payer_url scheme" do
      assert_raise ArgumentError, ~r/fee_payer_url must be an http or https URL/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer_url" => "ftp://sponsor.example.com"
        })
      end
    end
  end

  describe "verify/2 — hosted fee payer fill" do
    @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    @fee_payer_private_key "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    @hosted_url "https://sponsor.moderato.tempo.xyz"
    @rogue_token "0x1111111111111111111111111111111111111111"

    setup %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer_url" => @hosted_url,
              "sponsor_budget_id" => "hosted-wallet",
              "store" => start_sponsor_store()
            })
      }

      {:ok, charge: charge}
    end

    test "fills via eth_fillTransaction then broadcasts", %{charge: charge} do
      {:ok, tx_hex} = build_hosted_client_tx()
      {:ok, tx} = Transaction.deserialize(tx_hex)
      fill_tx = hosted_fill_tx_map(tx)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        response =
          case request["method"] do
            "eth_fillTransaction" ->
              %{"jsonrpc" => "2.0", "result" => %{"tx" => fill_tx}, "id" => request["id"]}

            "eth_simulateV1" ->
              simulate_success_body()

            _ ->
              %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => request["id"]}
          end

        Req.Test.json(conn, response)
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"
    end

    test "rejects hosted fill when returned feeToken is outside configured allowlist", %{charge: charge} do
      charge = put_in(charge.method_details["fee_payer_allowed_fee_tokens"], [@rogue_token])

      {:ok, tx_hex} = build_hosted_client_tx()
      {:ok, tx} = Transaction.deserialize(tx_hex)
      fill_tx = hosted_fill_tx_map(tx)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        response =
          if request["method"] == "eth_fillTransaction" do
            %{"jsonrpc" => "2.0", "result" => %{"tx" => fill_tx}, "id" => request["id"]}
          end

        Req.Test.json(conn, response)
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.detail =~ "not allowed"
    end

    test "challenge_method_details reports feePayer true for hosted config", %{charge: charge} do
      assert %{"feePayer" => true} = Tempo.challenge_method_details(charge)
    end
  end

  defp start_sponsor_store do
    cache_name = :"#{__MODULE__}.SponsorBudget.#{System.unique_integer([:positive])}"
    start_supervised!(ConCacheStore.child_spec(name: cache_name))
    {ConCacheStore, name: cache_name}
  end

  defp sponsor_budget_state(charge, private_key) do
    {:ok, sponsor_id} = Onchain.Signer.address_from_key(private_key)
    {ConCacheStore, opts} = charge.method_details["store"]
    key = "mpp:sponsor-budget:42431:#{String.downcase(sponsor_id)}"
    ConCacheStore.get(key, opts)
  end

  defp build_sponsored_client_tx(opts) do
    TempoTxBuilder.build_fee_payer_transfer(
      private_key: @client_private_key,
      token: @token_address,
      recipient: @recipient,
      amount: 1_000_000,
      chain_id: 42_431,
      rpc_url: @rpc_url,
      gas_limit: 1_000_000,
      nonce: Keyword.fetch!(opts, :nonce),
      nonce_key: expiring_nonce_key_int(),
      valid_before: future_valid_before()
    )
  end

  defp build_hosted_client_tx do
    build_sponsored_client_tx(nonce: 0)
  end

  defp hosted_fill_tx_map(tx) do
    fee_payer_key = Base.decode16!(@fee_payer_private_key, case: :mixed)
    fee_token = Base.decode16!(String.replace_prefix(@token_address, "0x", ""), case: :mixed)
    {:ok, cosigned} = Transaction.cosign_fee_payer(tx, fee_payer_key, fee_token)
    [y_parity, r_bin, s_bin] = Enum.at(cosigned.fields, 11)

    %{
      "feeToken" => @token_address,
      "feePayerSignature" => %{
        "yParity" => if(y_parity == <<1>>, do: 1, else: 0),
        "r" => "0x" <> Base.encode16(r_bin, case: :lower),
        "s" => "0x" <> Base.encode16(s_bin, case: :lower)
      }
    }
  end
end
