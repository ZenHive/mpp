defmodule MPP.Methods.USDCTest do
  use ExUnit.Case, async: false

  alias Cartouche.Solana.ATA
  alias Cartouche.Solana.Keys
  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.TokenProgram
  alias Cartouche.Solana.Transaction
  alias Cartouche.Typed
  alias Cartouche.Typed.Domain
  alias Cartouche.Typed.Type
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.JCS
  alias MPP.Methods.EVM.Authorization
  alias MPP.Methods.USDC
  alias MPP.Methods.USDC.Assets
  alias MPP.Methods.USDC.Binding
  alias MPP.Methods.USDC.EVM, as: USDCEvm
  alias MPP.Methods.USDC.Solana, as: USDCSolana
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.Test.EVMAuthorization
  alias Onchain.Address
  alias Onchain.Hex

  @mainnet_usdc "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  @sepolia_usdc "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @devnet_usdc "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  @token_program "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @amount "1000000"
  @realm "api.example.com"
  @challenge_id "usdc_evm_direct_001"
  @rpc_url "https://mainnet.infura.io/v3/test"
  @solana_rpc "https://api.devnet.solana.com"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @devnet_genesis "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
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

    @impl true
    def delete(key, expected) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Map.get(state, key) == expected, do: {:ok, Map.delete(state, key)}, else: {{:error, :mismatch}, state}
      end)
    end

    def keys, do: Agent.get(__MODULE__, &Map.keys/1)
  end

  describe "profile selection" do
    test "rejects a second profile object" do
      charge = evm_charge()
      details = Map.put(charge.method_details, "solana", %{"network" => "devnet"})

      assert {:error, error} = USDC.verify(auth_payload(charge), %{charge | method_details: details})
      assert error.detail =~ "exactly one profile"
    end

    test "rejects a stacks credential until that profile is registered" do
      {:ok, charge} =
        Charge.new(amount: @amount, currency: "ST1.usdcx::usdcx-token", recipient: "ST1RECIPIENT")

      charge = %{
        charge
        | method_details: %{
            "type" => "stacks",
            "stacks" => %{"network" => "testnet", "decimals" => 6}
          }
      }

      assert {:error, error} = USDC.verify(%{"type" => "transaction"}, charge)
      assert error.detail =~ "stacks profile is not implemented"
      refute Map.has_key?(USDC.profiles(), "stacks")
    end

    test "rejects an EVM authorization presented to the Solana profile" do
      charge = solana_charge()
      assert {:error, error} = USDC.verify(auth_payload(evm_charge()), charge)
      assert error.detail =~ "transaction"
    end

    test "rejects a non-charge intent" do
      {:ok, session} = Session.new(amount: "1", currency: "usd")
      assert {:error, error} = USDC.verify(%{}, session)
      assert error.detail =~ "charge intent"
    end

    test "rejects a zero amount" do
      charge = %{evm_charge() | amount: "0"}
      assert {:error, error} = USDC.verify(auth_payload(evm_charge()), charge)
      assert error.detail =~ "positive integer"
    end
  end

  describe "authorization nonce" do
    test "binds method, intent, realm, id, and the JCS request hash" do
      charge = evm_charge()
      {:ok, request} = Binding.public_request(charge)
      request_hash = request |> JCS.canonicalize() |> hash_hex()

      preimage =
        JCS.canonicalize(%{
          "id" => @challenge_id,
          "intent" => "charge",
          "method" => "usdc",
          "realm" => @realm,
          "requestHash" => request_hash
        })

      nonce = Binding.authorization_nonce(@challenge_id, @realm, request)
      assert nonce == hash_hex(preimage)
      refute nonce == Authorization.challenge_hash(@challenge_id, @realm)
    end
  end

  describe "challenge" do
    test "advertises only the nested EVM profile" do
      config =
        MPP.Plug.init(
          secret_key: "test-secret",
          realm: @realm,
          method: USDC,
          amount: @amount,
          currency: @sepolia_usdc,
          recipient: @recipient,
          external_id: "invoice-evm-001",
          method_config: evm_config(11_155_111)
        )

      conn = MPP.Plug.call(Plug.Test.conn(:get, "/paid"), config)
      assert conn.status == 402
      [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(header)
      {:ok, json} = Base.url_decode64(challenge.request, padding: false)
      {:ok, request} = Jason.decode(json)

      assert request["methodDetails"] == %{
               "type" => "evm",
               "evm" => %{"chainId" => 11_155_111, "credentialTypes" => ["authorization"], "decimals" => 6}
             }

      refute request["methodDetails"]["evm"]["private_key"]
      assert challenge.method == "usdc"
    end

    test "rejects a currency that is not native USDC for the chain" do
      assert_raise ArgumentError, ~r/native USDC/, fn ->
        USDC.validate_config!(evm_config(1))

        USDC.challenge_method_details(%{
          evm_charge()
          | currency: "0x0000000000000000000000000000000000000001"
        })
      end
    end

    test "requires a known chain and a settlement key" do
      assert_raise ArgumentError, ~r/chain_id/, fn ->
        USDC.validate_config!(Map.delete(evm_config(1), "chain_id"))
      end

      assert_raise ArgumentError, ~r/no native USDC/, fn ->
        USDC.validate_config!(evm_config(999_999))
      end

      assert_raise ArgumentError, ~r/private_key/, fn ->
        USDC.validate_config!(Map.delete(evm_config(1), "private_key"))
      end

      assert_raise ArgumentError, ~r/profile/, fn ->
        USDC.validate_config!(%{"profile" => "gateway", "rpc_url" => @rpc_url})
      end
    end
  end

  describe "evm verification" do
    test "settles a bound authorization and returns a USDC receipt" do
      stub_evm()
      charge = evm_charge()

      assert {:ok, %Receipt{} = receipt} = USDC.verify(auth_payload(charge), charge)
      assert receipt.method == "usdc"
      assert receipt.reference == @tx_hash
      assert receipt.status == "success"
      assert receipt.external_id == "invoice-evm-001"
      assert receipt.extensions["type"] == "evm"
      assert receipt.extensions["network"] == "eip155:1"
      assert receipt.extensions["challengeId"] == @challenge_id
    end

    test "rejects a nonce from the generic EVM challengeHash" do
      charge = evm_charge()

      payload =
        EVMAuthorization.payload(%{
          currency: @mainnet_usdc,
          name: "USD Coin",
          version: "2",
          chain_id: 1,
          from: EVMAuthorization.signer_address(),
          recipient: @recipient,
          amount: @amount,
          challenge_id: @challenge_id,
          realm: @realm,
          private_key: EVMAuthorization.private_key()
        })

      assert {:error, error} = USDC.verify(payload, charge)
      assert error.detail =~ "USDC challenge binding"
    end

    test "rejects a paused token and a blocklisted payer" do
      charge = evm_charge()
      payload = auth_payload(charge)

      stub_evm(%{"paused()" => word(1)})
      assert {:error, paused} = USDC.verify(payload, charge)
      assert paused.detail =~ "paused"

      stub_evm(%{"isBlacklisted(address)" => word(1)})
      assert {:error, blocked} = USDC.verify(payload, charge)
      assert blocked.detail =~ "payer is blocklisted"
    end

    test "rejects a blocklisted recipient and a foreign domain separator" do
      charge = evm_charge()
      payload = auth_payload(charge)
      recipient = padded_word(@recipient)

      stub_evm(fn data ->
        if String.contains?(data, recipient) and
             String.starts_with?(selector_of(data), selector("isBlacklisted(address)")) do
          word(1)
        end
      end)

      assert {:error, blocked} = USDC.verify(payload, charge)
      assert blocked.detail =~ "recipient is blocklisted"

      stub_evm(%{"DOMAIN_SEPARATOR()" => word(0)})
      assert {:error, domain} = USDC.verify(payload, charge)
      assert domain.detail =~ "EIP-712 domain"
    end

    test "releases a replay claim when settlement reverts, then accepts a fresh submit" do
      start_supervised!(MemoryStore)
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(USDC, fn conn ->
        {request, conn} = read_rpc(conn)
        method = request["method"]
        id = request["id"]
        data = if method == "eth_call", do: request["params"] |> hd() |> Map.get("data"), else: ""

        result =
          cond do
            method == "eth_call" and String.starts_with?(data, "0x" <> selector("authorizationState(address,bytes32)")) ->
              attempt = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)
              if attempt == 0, do: word(1), else: word(0)

            method == "eth_call" ->
              evm_view(data)

            method == "eth_getTransactionCount" ->
              "0x1"

            method == "eth_estimateGas" ->
              "0x186a0"

            method == "eth_sendRawTransaction" ->
              @tx_hash

            method == "eth_getTransactionReceipt" ->
              transfer_receipt()
          end

        rpc_json(conn, id, "result", result)
      end)

      charge = %{
        evm_charge()
        | external_id: nil,
          method_details: Map.put(evm_charge().method_details, "store", MemoryStore)
      }

      payload = auth_payload(charge)

      assert {:error, first} = USDC.verify(payload, charge)
      assert first.detail =~ "already used"
      assert MemoryStore.keys() == []

      assert {:ok, %Receipt{reference: @tx_hash}} = USDC.verify(payload, charge)
      assert MemoryStore.keys() != []
      assert {:error, replay} = USDC.verify(payload, charge)
      assert replay.detail =~ "already used"
    end

    test "rejects a second merchant order with the same externalId" do
      start_supervised!(MemoryStore)
      stub_evm()
      first = Map.put(evm_charge().method_details, "store", MemoryStore)
      charge = %{evm_charge() | method_details: first}
      assert {:ok, _receipt} = USDC.verify(auth_payload(charge), charge)

      other = %{charge | method_details: Map.put(first, "challenge_id", "usdc_evm_direct_002")}
      assert {:error, error} = USDC.verify(auth_payload(other), other)
      assert error.detail =~ "merchant order"
    end
  end

  describe "solana verification" do
    test "advertises the legacy devnet profile" do
      config =
        MPP.Plug.init(
          secret_key: "test-secret",
          realm: @realm,
          method: USDC,
          amount: "1",
          currency: @devnet_usdc,
          recipient: "AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9",
          method_config: %{
            "profile" => "solana",
            "rpc_url" => @solana_rpc,
            "network" => "devnet",
            "fee_payer" => true,
            "fee_payer_key" => "AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9",
            "fee_payer_private_key" => "00"
          }
        )

      conn = MPP.Plug.call(Plug.Test.conn(:get, "/paid"), config)
      {:ok, challenge} = Headers.parse_challenge(hd(Plug.Conn.get_resp_header(conn, "www-authenticate")))
      {:ok, json} = Base.url_decode64(challenge.request, padding: false)
      {:ok, request} = Jason.decode(json)

      assert request["methodDetails"]["type"] == "solana"

      assert request["methodDetails"]["solana"] == %{
               "decimals" => 6,
               "feePayer" => true,
               "feePayerKey" => "AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9",
               "network" => "devnet",
               "tokenProgram" => @token_program
             }
    end

    test "rejects token-2022, the wrong mint, and a mismatched amount before RPC" do
      charge = solana_charge()
      {payer, seed} = keypair()
      {recipient, _seed} = keypair()
      charge = %{charge | recipient: Keys.to_address(recipient)}

      assert {:error, program} = USDC.verify(encoded_transfer(payer, seed, recipient, token_2022: true), charge)
      assert program.detail =~ "allow-list"

      assert {:error, mint} = USDC.verify(encoded_transfer(payer, seed, recipient, mint: <<9::256>>), charge)
      assert mint.detail =~ "advertised USDC mint"

      assert {:error, amount} = USDC.verify(encoded_transfer(payer, seed, recipient, amount: 2), charge)
      assert amount.detail =~ "amount"
    end

    test "rejects a genesis hash for a different cluster" do
      stub_solana(%{"getGenesisHash" => "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"})
      {payer, seed} = keypair()
      {recipient, _} = keypair()
      charge = %{solana_charge() | recipient: Keys.to_address(recipient)}

      assert {:error, error} = USDC.verify(encoded_transfer(payer, seed, recipient), charge)
      assert error.detail =~ "genesis hash"
    end

    test "settles when the transaction creates the recipient associated token account" do
      {payer, seed} = keypair()
      {recipient, _} = keypair()
      charge = %{solana_charge() | recipient: Keys.to_address(recipient)}
      payload = encoded_transfer_with_ata(payer, seed, recipient)
      {:ok, tx} = payload["transaction"] |> Base.decode64!() |> Transaction.deserialize()
      signature = Cartouche.Base58.encode(hd(tx.signatures))
      stub_solana_success(payer, recipient, signature, dest_missing: true)

      assert {:ok, %Receipt{} = receipt} = USDC.verify(payload, charge)
      assert receipt.reference == signature
      assert receipt.extensions["type"] == "solana"
    end

    test "settles a devnet transfer and rejects the same transaction bytes" do
      start_supervised!(MemoryStore)
      {payer, seed} = keypair()
      {recipient, _} = keypair()
      charge = %{solana_charge() | recipient: Keys.to_address(recipient)}
      charge = %{charge | method_details: Map.put(charge.method_details, "store", MemoryStore)}
      payload = encoded_transfer(payer, seed, recipient)
      {:ok, tx} = payload["transaction"] |> Base.decode64!() |> Transaction.deserialize()
      signature = Cartouche.Base58.encode(hd(tx.signatures))
      stub_solana_success(payer, recipient, signature)

      charge = %{charge | external_id: "invoice-sol-001"}
      assert {:ok, %Receipt{} = receipt} = USDC.verify(payload, charge)
      assert receipt.method == "usdc"
      assert receipt.reference == signature
      assert receipt.extensions["type"] == "solana"
      assert receipt.extensions["network"] == "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"

      assert {:error, replay} = USDC.verify(payload, charge)
      assert replay.detail =~ "merchant order"
    end
  end

  describe "edge cases" do
    test "covers config, binding, and profile rejection branches" do
      assert USDC.method_name() == "usdc"
      assert USDC.credential_types() == ["authorization", "transaction"]
      assert "evm" in Binding.profile_types()
      assert USDC.challenge_method_details(elem(Session.new(amount: "1", currency: "usd"), 1)) == nil
      assert {:error, _} = Binding.positive_amount(%{amount: 1})
      assert {:error, _} = Binding.select_profile("evm")
      assert :error = Assets.evm_currency("1")
      refute Assets.known_evm_chain?("1")
      refute Assets.evm?(1, 1)
      refute Assets.solana?(1, @devnet_usdc)
      assert :error = Assets.solana_mint(1)

      assert :ok = USDC.validate_config!(Map.put(evm_config(1), "store", false))
      assert :ok = USDC.validate_config!(Map.put(evm_config(1), "store", MemoryStore))
      assert :ok = USDC.validate_config!(Map.put(evm_config(1), "store", {ConCacheStore, []}))

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        USDC.validate_config!(Map.put(evm_config(1), "store", {ConCacheStore, [1]}))
      end

      assert_raise ArgumentError, ~r/Tempo.Store/, fn ->
        USDC.validate_config!(Map.put(evm_config(1), "store", String))
      end

      assert_raise ArgumentError, ~r/invalid/, fn ->
        USDC.validate_config!(Map.put(evm_config(1), "store", {"nope", []}))
      end

      assert_raise ArgumentError, ~r/https/, fn ->
        USDC.validate_config!(Map.put(evm_config(1), "rpc_url", "http://example.com"))
      end

      assert_raise ArgumentError, ~r/https/, fn ->
        USDC.validate_config!(solana_server_config("http://example.com"))
      end

      assert_raise ArgumentError, ~r/network/, fn ->
        USDC.validate_config!(solana_server_config(@solana_rpc, %{"network" => "testnet"}))
      end

      assert_raise ArgumentError, ~r/fee_payer_private_key/, fn ->
        USDC.validate_config!(solana_server_config(@solana_rpc, %{"fee_payer" => true}))
      end

      assert_raise ArgumentError, ~r/fee_payer_key/, fn ->
        USDC.validate_config!(solana_server_config(@solana_rpc, %{"fee_payer" => true, "fee_payer_private_key" => "00"}))
      end

      assert_raise ArgumentError, ~r/native USDC mint/, fn ->
        USDCSolana.challenge_details(%{solana_charge() | currency: "not-a-mint"})
      end

      assert_raise ArgumentError, ~r/localnet/, fn ->
        USDCSolana.challenge_details(%{
          solana_charge()
          | method_details: Map.put(solana_charge().method_details, "network", "localnet")
        })
      end

      assert_raise ArgumentError, ~r/no native USDC/, fn ->
        USDCEvm.challenge_details(%{evm_charge() | method_details: Map.put(evm_charge().method_details, "chain_id", nil)})
      end

      charge = evm_charge()
      assert {:error, _} = USDC.verify(%{"type" => "hash"}, charge)
      assert {:error, _} = USDC.verify(%{}, charge)

      mismatched = put_in(charge.method_details["profile"], "solana")
      assert {:error, profile} = USDC.verify(auth_payload(charge), mismatched)
      assert profile.detail =~ "does not match"

      assert {:error, recipient} = USDCEvm.verify(auth_payload(charge), %{charge | recipient: nil})
      assert recipient.detail =~ "recipient"

      assert {:error, chain} = USDCEvm.verify(auth_payload(charge), drop_detail(charge, "chain_id"))
      assert chain.detail =~ "chain_id"

      assert {:error, object} = USDCEvm.verify(auth_payload(charge), put_in(charge.method_details["evm"], "nope"))
      assert object.detail =~ "profile object"

      bad_chain = put_in(charge.method_details["evm"]["chainId"], 11_155_111)
      assert {:error, _} = USDCEvm.verify(auth_payload(charge), bad_chain)

      bad_decimals = put_in(charge.method_details["evm"]["decimals"], 18)
      assert {:error, _} = USDCEvm.verify(auth_payload(charge), bad_decimals)

      no_types = update_in(charge.method_details["evm"], &Map.delete(&1, "credentialTypes"))
      assert {:error, _} = USDCEvm.verify(%{"type" => "authorization"}, no_types)

      bad_types = put_in(charge.method_details["evm"]["credentialTypes"], ["hash"])
      assert {:error, _} = USDCEvm.verify(auth_payload(charge), bad_types)

      foreign = %{charge | currency: "0x0000000000000000000000000000000000000001"}
      assert {:error, asset} = USDCEvm.verify(auth_payload(charge), foreign)
      assert asset.detail =~ "not native USDC"

      payload = auth_payload(charge)
      assert {:error, _} = USDCEvm.verify(Map.put(payload, "value", "2"), charge)
      assert {:error, _} = USDCEvm.verify(Map.put(payload, "to", "0x0000000000000000000000000000000000000001"), charge)
      assert {:error, _} = USDCEvm.verify(payload, drop_detail(charge, "challenge_id"))
      assert {:error, _} = USDCEvm.verify(payload, put_in(charge.method_details["realm"], 1))
      assert {:error, _} = USDCEvm.verify(payload, drop_detail(charge, "type"))
      refute Assets.evm?(999_999, @mainnet_usdc)
    end

    test "evm control and receipt failures" do
      charge = evm_charge()
      payload = auth_payload(charge)

      stub_evm(%{"decimals()" => word(18)})
      assert {:error, decimals} = USDC.verify(payload, charge)
      assert decimals.detail =~ "decimals"

      stub_evm(%{"DOMAIN_SEPARATOR()" => "0x01"})
      assert {:error, domain} = USDC.verify(payload, charge)
      assert domain.detail =~ "EVM RPC" or domain.detail =~ "domain"

      Req.Test.stub(USDC, fn conn ->
        {request, conn} = read_rpc(conn)

        if request["method"] == "eth_getTransactionReceipt" do
          rpc_json(conn, request["id"], "result", %{"status" => "0x1", "transactionHash" => @tx_hash})
        else
          data = if request["method"] == "eth_call", do: hd(request["params"])["data"], else: ""

          result =
            case request["method"] do
              "eth_call" -> evm_view_default(data)
              "eth_getTransactionCount" -> "0x1"
              "eth_estimateGas" -> "0x186a0"
              "eth_sendRawTransaction" -> @tx_hash
            end

          rpc_json(conn, request["id"], "result", result)
        end
      end)

      assert {:error, logs} = USDC.verify(payload, charge)
      assert logs.detail =~ "Transfer"

      Req.Test.stub(USDC, fn conn ->
        {request, conn} = read_rpc(conn)

        if request["method"] == "eth_getTransactionReceipt" do
          rpc_json(conn, request["id"], "error", %{"code" => -32_000, "message" => "receipt down"})
        else
          data = if request["method"] == "eth_call", do: hd(request["params"])["data"], else: ""

          result =
            case request["method"] do
              "eth_call" -> evm_view_default(data)
              "eth_getTransactionCount" -> "0x1"
              "eth_estimateGas" -> "0x186a0"
              "eth_sendRawTransaction" -> @tx_hash
            end

          rpc_json(conn, request["id"], "result", result)
        end
      end)

      assert {:error, receipt_rpc} = USDC.verify(payload, charge)
      assert receipt_rpc.detail =~ "EVM RPC"
    end

    test "a dedup store error is reported and solana profile fields are rejected" do
      defmodule BoomStore do
        @moduledoc false
        @behaviour Store

        def get(_key), do: :not_found
        def put(_key, _value), do: :ok
        def check_and_mark(_key, _value), do: {:error, :db_down}
      end

      stub_evm()

      charge = %{
        evm_charge()
        | external_id: nil,
          method_details: Map.put(evm_charge().method_details, "store", BoomStore)
      }

      assert {:error, store} = USDC.verify(auth_payload(charge), charge)
      assert store.detail =~ "Dedup store"

      {payer, seed} = keypair()
      {recipient, _} = keypair()
      solana = %{solana_charge() | recipient: Keys.to_address(recipient)}
      tx = encoded_transfer(payer, seed, recipient)

      assert {:error, _} = USDCSolana.verify(tx, %{solana | recipient: nil})
      assert {:error, _} = USDCSolana.verify(%{"type" => "transaction"}, solana)
      assert {:error, _} = USDCSolana.verify(%{"type" => "signature"}, solana)
      assert {:error, _} = USDCSolana.verify(%{}, solana)
      assert {:error, _} = USDCSolana.verify(%{"type" => "transaction", "transaction" => "!!!!"}, solana)

      assert {:error, _} =
               USDCSolana.verify(%{"type" => "transaction", "transaction" => Base.encode64(<<1, 2, 3>>)}, solana)

      bad_network = put_in(solana.method_details["solana"]["network"], "testnet")
      assert {:error, _} = USDCSolana.verify(tx, bad_network)

      drifted = put_in(solana.method_details["network"], "mainnet")
      assert {:error, _} = USDCSolana.verify(tx, drifted)

      bad_decimals = put_in(solana.method_details["solana"]["decimals"], 9)
      assert {:error, _} = USDCSolana.verify(tx, bad_decimals)

      bad_program = put_in(solana.method_details["solana"]["tokenProgram"], "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
      assert {:error, _} = USDCSolana.verify(tx, bad_program)

      fee = put_in(solana.method_details["solana"]["feePayer"], true)
      assert {:error, _} = USDCSolana.verify(tx, fee)

      with_key = put_in(fee.method_details["solana"]["feePayerKey"], "not-when-false")
      false_fee = put_in(with_key.method_details["solana"]["feePayer"], false)
      assert {:error, _} = USDCSolana.verify(tx, false_fee)

      weird = put_in(solana.method_details["solana"]["feePayer"], "yes")
      assert {:error, _} = USDCSolana.verify(tx, weird)

      memo = memo_payload(payer, seed)
      assert {:error, empty} = USDCSolana.verify(memo, solana)
      assert empty.detail =~ "exactly one"

      stub_solana(%{"getGenesisHash" => "short"})
      assert {:error, _} = USDC.verify(tx, solana)

      Req.Test.stub(USDC, fn conn ->
        {request, conn} = read_rpc(conn)
        rpc_json(conn, request["id"], "error", %{"code" => -32_002, "message" => "down"})
      end)

      assert {:error, rpc} = USDC.verify(tx, solana)
      assert rpc.detail =~ "Solana RPC"

      stub_solana(%{
        "getGenesisHash" => @devnet_genesis,
        "getAccountInfo" => %{"context" => %{"slot" => 1}, "value" => nil}
      })

      assert {:error, missing} = USDC.verify(tx, solana)
      assert missing.detail =~ "mint account"

      frozen = account_value(Base.encode64(token_data(payer, 2)), 165)

      Req.Test.stub(USDC, fn conn ->
        {request, conn} = read_rpc(conn)
        id = request["id"]

        result =
          case request["method"] do
            "getGenesisHash" ->
              @devnet_genesis

            "getAccountInfo" ->
              pubkey = hd(request["params"])

              value =
                if pubkey == @devnet_usdc do
                  account_value(Base.encode64(<<0::32, 0::256, 0::64, 8, 1, 0::32, 0::256>>), 82)
                else
                  frozen
                end

              %{"context" => %{"slot" => 1}, "value" => value}
          end

        rpc_json(conn, id, "result", result)
      end)

      assert {:error, bad_mint} = USDC.verify(tx, solana)
      assert bad_mint.detail =~ "decimals"

      assert USDCSolana.challenge_details(solana)["network"] == "devnet"
      assert {:error, _} = USDCSolana.verify(tx, %{solana | method_details: Map.delete(solana.method_details, "solana")})
      assert {:error, _} = USDCSolana.verify(tx, %{solana | currency: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"})
      assert {:error, _} = USDCSolana.verify(tx, %{solana | amount: "nope"})

      odd_decimals = encoded_transfer(payer, seed, recipient, decimals: 5)
      assert {:error, _} = USDCSolana.verify(odd_decimals, solana)

      plain = encoded_transfer(payer, seed, recipient, transfer: true)
      assert {:error, plain_error} = USDCSolana.verify(plain, solana)
      assert plain_error.detail =~ "transferChecked"

      offline = %{
        solana
        | method_details:
            solana.method_details
            |> Map.put("rpc_url", "http://127.0.0.1:9")
            |> Map.put("confirmation_timeout", 200)
            |> Map.delete("req_options")
      }

      assert {:error, offline_error} = USDCSolana.verify(tx, offline)
      assert offline_error.detail =~ "Solana RPC"

      assert {:error, frozen} = USDC.verify(tx, solana_with_accounts(payer, recipient, :frozen))
      assert frozen.detail =~ "frozen"

      assert {:error, short} = USDC.verify(tx, solana_with_accounts(payer, recipient, :short_mint))
      assert short.detail =~ "mint"

      assert {:error, owned} = USDC.verify(tx, solana_with_accounts(payer, recipient, :wrong_owner))
      assert owned.detail =~ "legacy SPL"

      assert {:error, encoded} = USDC.verify(tx, solana_with_accounts(payer, recipient, :bad_base64))
      assert encoded.detail =~ "could not be decoded"

      assert {:error, rpc_account} = USDC.verify(tx, solana_with_accounts(payer, recipient, :account_error))
      assert rpc_account.detail =~ "Solana RPC"

      bad_recipient = %{solana | recipient: "not a solana address"}

      assert {:error, recipient_error} =
               USDC.verify(tx, solana_with_accounts(payer, recipient, :dest_present, bad_recipient))

      assert recipient_error.detail =~ "recipient"

      assert {:error, _} = USDC.verify(tx, solana_with_accounts(payer, recipient, :binary_data))
      assert {:error, _} = USDC.verify(tx, solana_with_accounts(payer, recipient, :weird_data))

      sponsored = solana_with_accounts(payer, recipient, :simulate)
      {fee_payer, fee_seed} = keypair()

      sponsored = %{
        sponsored
        | external_id: nil,
          method_details:
            sponsored.method_details
            |> Map.put("fee_payer_private_key", Base.encode16(fee_seed, case: :lower))
            |> put_in(["solana", "feePayer"], true)
            |> put_in(["solana", "feePayerKey"], Keys.to_address(fee_payer))
      }

      assert {:error, sponsored_error} = USDC.verify(tx, sponsored)
      assert sponsored_error.detail =~ "feePayerKey"
    end
  end

  describe "assets" do
    test "matches Circle mainnet, Sepolia, and devnet identities" do
      assert Assets.evm?(1, @mainnet_usdc)
      assert Assets.evm?(11_155_111, String.downcase(@sepolia_usdc))
      refute Assets.evm?(1, @sepolia_usdc)
      assert Assets.solana?("devnet", @devnet_usdc)
      refute Assets.solana?("mainnet", @devnet_usdc)
      refute Assets.solana?("localnet", @devnet_usdc)
    end
  end

  defp evm_config(chain_id) do
    %{
      "profile" => "evm",
      "rpc_url" => @rpc_url,
      "chain_id" => chain_id,
      "private_key" => EVMAuthorization.private_key()
    }
  end

  defp evm_charge do
    {:ok, charge} =
      Charge.new(
        amount: @amount,
        currency: @mainnet_usdc,
        recipient: @recipient,
        description: "Arc Testnet USDC charge",
        external_id: "invoice-evm-001"
      )

    %{
      charge
      | method_details:
          Map.merge(evm_config(1), %{
            "type" => "evm",
            "evm" => %{"chainId" => 1, "credentialTypes" => ["authorization"], "decimals" => 6},
            "challenge_id" => @challenge_id,
            "realm" => @realm,
            "req_options" => [plug: {Req.Test, USDC}],
            "store" => false
          })
    }
  end

  defp solana_charge do
    {:ok, charge} = Charge.new(amount: "1", currency: @devnet_usdc, recipient: "11111111111111111111111111111111")

    %{
      charge
      | method_details: %{
          "profile" => "solana",
          "type" => "solana",
          "solana" => %{
            "network" => "devnet",
            "decimals" => 6,
            "tokenProgram" => @token_program
          },
          "rpc_url" => @solana_rpc,
          "network" => "devnet",
          "challenge_id" => "usdc_solana_direct_001",
          "realm" => @realm,
          "req_options" => [plug: {Req.Test, USDC}],
          "store" => false
        }
    }
  end

  defp auth_payload(charge) do
    {:ok, request} = Binding.public_request(charge)
    nonce = Binding.authorization_nonce(charge.method_details["challenge_id"], @realm, request)

    EVMAuthorization.payload(%{
      currency: charge.currency,
      name: "USD Coin",
      version: "2",
      chain_id: charge.method_details["chain_id"],
      from: EVMAuthorization.signer_address(),
      recipient: charge.recipient,
      amount: charge.amount,
      challenge_id: charge.method_details["challenge_id"],
      realm: @realm,
      nonce: nonce,
      private_key: EVMAuthorization.private_key()
    })
  end

  defp hash_hex(bytes), do: bytes |> ExKeccak.hash_256() |> Hex.encode()

  defp selector(signature) do
    <<sel::binary-size(4), _rest::binary>> = ExKeccak.hash_256(signature)
    Base.encode16(sel, case: :lower)
  end

  defp selector_of("0x" <> rest), do: String.slice(rest, 0, 8)
  defp selector_of(_data), do: ""

  defp word(integer) do
    "0x" <> Base.encode16(<<integer::unsigned-big-256>>, case: :lower)
  end

  defp padded_word(address) do
    {:ok, <<bytes::binary-20>>} = Address.validate(address)
    Base.encode16(<<0::96, bytes::binary>>, case: :lower)
  end

  defp domain_separator do
    {:ok, verifying} = Address.validate(@mainnet_usdc)

    %Typed{
      domain: %Domain{name: "USD Coin", version: "2", chain_id: 1, verifying_contract: verifying},
      types: %{"TransferWithAuthorization" => %Type{fields: [{"from", :address}]}},
      value: %{"from" => verifying}
    }
    |> Typed.domain_seperator()
    |> Hex.encode()
  end

  defp stub_evm(overrides \\ %{})

  defp stub_evm(fun) when is_function(fun, 1) do
    stub_evm_dispatch(fn data -> fun.(data) || evm_view_default(data) end)
  end

  defp stub_evm(overrides) when is_map(overrides) do
    stub_evm_dispatch(fn data -> evm_view(data, overrides) end)
  end

  defp stub_evm_dispatch(view) do
    Req.Test.stub(USDC, fn conn ->
      {request, conn} = read_rpc(conn)
      method = request["method"]
      id = request["id"]
      data = if method == "eth_call", do: hd(request["params"])["data"], else: ""

      result =
        case method do
          "eth_call" -> view.(data)
          "eth_getTransactionCount" -> "0x1"
          "eth_estimateGas" -> "0x186a0"
          "eth_sendRawTransaction" -> @tx_hash
          "eth_getTransactionReceipt" -> transfer_receipt()
        end

      rpc_json(conn, id, "result", result)
    end)
  end

  defp evm_view(data, overrides \\ %{}) do
    Enum.find_value(overrides, fn
      {signature, value} when is_binary(signature) ->
        if String.starts_with?(data, "0x" <> selector(signature)), do: value

      _other ->
        nil
    end) || evm_view_default(data)
  end

  defp evm_view_default(data) do
    cond do
      String.starts_with?(data, "0x" <> selector("DOMAIN_SEPARATOR()")) -> domain_separator()
      String.starts_with?(data, "0x" <> selector("decimals()")) -> word(6)
      String.starts_with?(data, "0x" <> selector("paused()")) -> word(0)
      String.starts_with?(data, "0x" <> selector("isBlacklisted(address)")) -> word(0)
      String.starts_with?(data, "0x" <> selector("authorizationState(address,bytes32)")) -> word(0)
      true -> word(0)
    end
  end

  defp transfer_receipt do
    from = padded_word(EVMAuthorization.signer_address())
    to = padded_word(@recipient)

    %{
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1",
      "status" => "0x1",
      "from" => EVMAuthorization.signer_address(),
      "to" => @mainnet_usdc,
      "logs" => [
        %{
          "address" => @mainnet_usdc,
          "topics" => [@transfer_topic, "0x" <> from, "0x" <> to],
          "data" => "0x" <> String.duplicate("0", 58) <> "0f4240",
          "blockNumber" => "0x1",
          "transactionHash" => @tx_hash,
          "logIndex" => "0x0"
        }
      ]
    }
  end

  defp solana_with_accounts(payer, recipient, mode, charge \\ nil) do
    mint = elem(Cartouche.Base58.decode(@devnet_usdc), 1)
    {source, _} = ATA.find_address(payer, mint)
    {dest, _} = ATA.find_address(recipient, mint)
    charge = charge || %{solana_charge() | recipient: Keys.to_address(recipient)}

    Req.Test.stub(USDC, fn conn ->
      {request, conn} = read_rpc(conn)
      respond_solana(conn, request, mode, payer, source, dest)
    end)

    charge
  end

  defp respond_solana(conn, request, :account_error, _payer, _source, _dest) do
    if request["method"] == "getAccountInfo" do
      rpc_json(conn, request["id"], "error", %{"code" => -32_002, "message" => "missing"})
    else
      rpc_json(conn, request["id"], "result", @devnet_genesis)
    end
  end

  defp respond_solana(conn, request, mode, payer, source, dest) do
    result =
      case request["method"] do
        "getGenesisHash" ->
          @devnet_genesis

        "getAccountInfo" ->
          pubkey = hd(request["params"])
          %{"context" => %{"slot" => 1}, "value" => solana_account(mode, pubkey, payer, source, dest)}

        "simulateTransaction" ->
          %{"err" => "BlockhashNotFound", "logs" => [], "unitsConsumed" => 0}
      end

    rpc_json(conn, request["id"], "result", result)
  end

  defp solana_account(:short_mint, pubkey, _payer, _source, _dest) do
    if pubkey == @devnet_usdc, do: account_value(Base.encode64(<<0::80>>), 10)
  end

  defp solana_account(:bad_base64, pubkey, _payer, _source, _dest) do
    if pubkey == @devnet_usdc, do: account_value("@@@", 82)
  end

  defp solana_account(:wrong_owner, pubkey, _payer, _source, _dest) do
    if pubkey == @devnet_usdc do
      Map.put(account_value(Base.encode64(mint_data()), 82), "owner", "11111111111111111111111111111111")
    end
  end

  defp solana_account(:frozen, pubkey, payer, source, _dest) do
    cond do
      pubkey == @devnet_usdc -> account_value(Base.encode64(mint_data()), 82)
      pubkey == Keys.to_address(source) -> account_value(Base.encode64(token_data(payer, 2)), 165)
      true -> nil
    end
  end

  defp solana_account(:simulate, pubkey, payer, source, _dest) do
    cond do
      pubkey == @devnet_usdc -> account_value(Base.encode64(mint_data()), 82)
      pubkey == Keys.to_address(source) -> account_value(Base.encode64(token_data(payer, 1)), 165)
      true -> nil
    end
  end

  defp solana_account(:binary_data, pubkey, _payer, _source, _dest) do
    if pubkey == @devnet_usdc, do: Map.put(account_value("", 82), "data", Base.encode64(mint_data()))
  end

  defp solana_account(:weird_data, pubkey, _payer, _source, _dest) do
    if pubkey == @devnet_usdc, do: Map.put(account_value("", 82), "data", %{"raw" => true})
  end

  defp solana_account(:dest_present, pubkey, payer, source, dest) do
    cond do
      pubkey == @devnet_usdc -> account_value(Base.encode64(mint_data()), 82)
      pubkey == Keys.to_address(source) -> account_value(Base.encode64(token_data(payer, 1)), 165)
      pubkey == Keys.to_address(dest) -> account_value(Base.encode64(token_data(<<0::256>>, 1)), 165)
      true -> nil
    end
  end

  defp solana_server_config(rpc_url, extra \\ %{}) do
    Map.merge(%{"profile" => "solana", "rpc_url" => rpc_url, "network" => "devnet"}, extra)
  end

  defp drop_detail(charge, key), do: %{charge | method_details: Map.delete(charge.method_details, key)}

  defp memo_payload(payer, seed) do
    ix = %Transaction.Instruction{
      program_id: memo_program(),
      accounts: [],
      data: "note"
    }

    message = Transaction.build_message(payer, [ix], <<1::256>>)
    tx = Transaction.sign(message, [seed])
    %{"type" => "transaction", "transaction" => Base.encode64(Transaction.serialize(tx))}
  end

  defp memo_program do
    {:ok, key} = Cartouche.Base58.decode("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")
    key
  end

  defp keypair do
    {public, seed} = Keys.generate_keypair()
    {public, seed}
  end

  defp encoded_transfer_with_ata(payer, seed, recipient) do
    mint = elem(Cartouche.Base58.decode(@devnet_usdc), 1)
    {source, _} = ATA.find_address(payer, mint)
    {dest, _} = ATA.find_address(recipient, mint)
    create = ATA.create_idempotent(payer, recipient, mint)
    transfer = TokenProgram.transfer_checked(source, mint, dest, payer, 1, 6)
    message = Transaction.build_message(payer, [create, transfer], <<1::256>>)
    tx = Transaction.sign(message, [seed])
    %{"type" => "transaction", "transaction" => Base.encode64(Transaction.serialize(tx))}
  end

  defp encoded_transfer(payer, seed, recipient, opts \\ []) do
    mint = Keyword.get(opts, :mint, elem(Cartouche.Base58.decode(@devnet_usdc), 1))
    amount = Keyword.get(opts, :amount, 1)
    decimals = Keyword.get(opts, :decimals, 6)
    program = if Keyword.get(opts, :token_2022, false), do: Programs.token_2022_program(), else: Programs.token_program()
    {source, _} = ATA.find_address(payer, mint, token_program: program)
    {dest, _} = ATA.find_address(recipient, mint, token_program: program)

    ix =
      if Keyword.get(opts, :transfer, false) do
        TokenProgram.transfer(source, dest, payer, amount, token_program: program)
      else
        TokenProgram.transfer_checked(source, mint, dest, payer, amount, decimals, token_program: program)
      end

    message = Transaction.build_message(payer, [ix], <<1::256>>)
    tx = Transaction.sign(message, [seed])
    %{"type" => "transaction", "transaction" => Base.encode64(Transaction.serialize(tx))}
  end

  defp stub_solana(results) do
    Req.Test.stub(USDC, fn conn ->
      {method, id, conn} = read_request(conn)
      rpc_json(conn, id, "result", Map.fetch!(results, method))
    end)
  end

  defp stub_solana_success(payer, recipient, signature, opts \\ []) do
    mint = elem(Cartouche.Base58.decode(@devnet_usdc), 1)
    {source, _} = ATA.find_address(payer, mint)
    {dest, _} = ATA.find_address(recipient, mint)

    Req.Test.stub(USDC, fn conn ->
      {request, conn} = read_rpc(conn)
      method = request["method"]
      id = request["id"]

      result =
        case method do
          "getGenesisHash" ->
            @devnet_genesis

          "getAccountInfo" ->
            account_info(hd(request["params"]), payer, recipient, source, dest, opts)

          "simulateTransaction" ->
            %{"err" => nil, "logs" => ["ok"], "unitsConsumed" => 500}

          "sendTransaction" ->
            signature

          "getSignatureStatuses" ->
            [%{"slot" => 1, "confirmations" => 1, "err" => nil, "confirmationStatus" => "confirmed"}]

          "getTransaction" ->
            spl_parsed(signature, payer, source, dest, mint)
        end

      rpc_json(conn, id, "result", result)
    end)
  end

  defp account_info(pubkey, payer, recipient, source, dest, opts) do
    value =
      cond do
        pubkey == @devnet_usdc ->
          account_value(Base.encode64(mint_data()), 82)

        pubkey == Keys.to_address(source) ->
          account_value(Base.encode64(token_data(payer, 1)), 165)

        pubkey == Keys.to_address(dest) and Keyword.get(opts, :dest_missing, false) ->
          nil

        pubkey == Keys.to_address(dest) ->
          account_value(Base.encode64(token_data(recipient, 1)), 165)

        true ->
          nil
      end

    %{"context" => %{"slot" => 1}, "value" => value}
  end

  defp account_value(encoded, space) do
    %{
      "data" => [encoded, "base64"],
      "executable" => false,
      "lamports" => 1_000_000,
      "owner" => @token_program,
      "rentEpoch" => 0,
      "space" => space
    }
  end

  defp mint_data do
    <<0::32, 0::256, 0::64, 6, 1, 0::32, 0::256>>
  end

  defp token_data(owner, state) do
    <<0::256, owner::binary-32, 0::64, 0::32, 0::256, state, 0::unit(8)-size(56)>>
  end

  defp spl_parsed(signature, payer, source, dest, mint) do
    %{
      "meta" => %{"err" => nil},
      "transaction" => %{
        "signatures" => [signature],
        "message" => %{
          "instructions" => [
            %{
              "parsed" => %{
                "info" => %{
                  "authority" => Keys.to_address(payer),
                  "destination" => Keys.to_address(dest),
                  "mint" => Keys.to_address(mint),
                  "source" => Keys.to_address(source),
                  "tokenAmount" => %{"amount" => "1", "decimals" => 6}
                },
                "type" => "transferChecked"
              },
              "program" => "spl-token",
              "programId" => @token_program
            }
          ]
        }
      }
    }
  end

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
end
