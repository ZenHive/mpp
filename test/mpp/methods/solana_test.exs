defmodule MPP.Methods.SolanaTest do
  use ExUnit.Case, async: true

  alias Cartouche.Solana.ATA
  alias Cartouche.Solana.Keys
  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.SystemProgram
  alias Cartouche.Solana.TokenProgram
  alias Cartouche.Solana.Transaction
  alias Cartouche.Solana.Transaction.Instruction
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Methods.Solana
  alias MPP.Methods.Solana.Instructions
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  @rpc_url "https://api.devnet.solana.com"
  @amount 10_000
  @blockhash <<7::256>>
  @usdc_devnet "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  @token_program "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"

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

  defmodule ErrorDeleteStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: :ok
    @impl true
    def delete(_key, _expected), do: {:error, :backend_down}
  end

  defmodule RaisingDeleteStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: :ok
    @impl true
    def delete(_key, _expected), do: raise("backend crashed")
  end

  defmodule ExitingDeleteStore do
    @moduledoc false
    @behaviour Store

    @impl true
    def get(_key), do: :not_found
    @impl true
    def put(_key, _value), do: :ok
    @impl true
    def check_and_mark(_key, _value), do: :ok
    @impl true
    def delete(_key, _expected), do: exit(:backend_gone)
  end

  setup do
    {payer, payer_seed} = Keys.generate_keypair()
    {recipient, _} = Keys.generate_keypair()
    {fee_payer, fee_payer_seed} = Keys.generate_keypair()

    {:ok, charge} =
      Charge.new(
        amount: Integer.to_string(@amount),
        currency: "sol",
        recipient: Keys.to_address(recipient)
      )

    charge = %{
      charge
      | method_details: %{
          "rpc_url" => @rpc_url,
          "network" => "devnet",
          "req_options" => [plug: {Req.Test, Solana}],
          "store" => false,
          "push" => "unbound"
        }
    }

    {:ok,
     charge: charge,
     payer: payer,
     payer_seed: payer_seed,
     recipient: recipient,
     fee_payer: fee_payer,
     fee_payer_seed: fee_payer_seed}
  end

  describe "method_name/0" do
    test "returns solana" do
      assert Solana.method_name() == "solana"
    end
  end

  describe "credential_types/0" do
    test "accepts transaction, signature, and bundle" do
      assert Solana.credential_types() == ["transaction", "signature", "bundle"]
    end
  end

  describe "validate_config!/1" do
    test "returns :ok with rpc_url" do
      assert :ok = Solana.validate_config!(%{"rpc_url" => @rpc_url})
    end

    test "raises on missing rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Solana.validate_config!(%{})
      end
    end

    test "raises on invalid network" do
      assert_raise ArgumentError, ~r/network/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "network" => "testnet"})
      end
    end

    test "raises on incomplete confidential config" do
      assert_raise ArgumentError, ~r/token_program/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "confidential" => true})
      end
    end

    test "raises when fee_payer is missing a private key" do
      assert_raise ArgumentError, ~r/fee_payer_private_key/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "fee_payer" => true})
      end
    end

    test "accepts fee_payer with a hex seed", %{fee_payer_seed: seed} do
      hex = Base.encode16(seed, case: :lower)

      assert :ok =
               Solana.validate_config!(%{
                 "rpc_url" => @rpc_url,
                 "fee_payer" => true,
                 "fee_payer_private_key" => hex
               })
    end

    test "raises on too many splits" do
      splits = for _i <- 1..9, do: %{"recipient" => "x", "amount" => "1"}

      assert_raise ArgumentError, ~r/at most 8/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "splits" => splits})
      end
    end

    test "raises on a non-atomic custom store" do
      assert_raise ArgumentError, ~r/MPP.Tempo.Store/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "store" => Enum})
      end
    end

    test "accepts ConCacheStore tuple opts" do
      assert :ok = Solana.validate_config!(%{"rpc_url" => @rpc_url, "store" => {ConCacheStore, [name: :solana_test]}})
    end

    test "accepts the ConCacheStore module" do
      assert :ok = Solana.validate_config!(%{"rpc_url" => @rpc_url, "store" => ConCacheStore})
    end

    test "accepts a custom dedup-capable store" do
      assert :ok = Solana.validate_config!(%{"rpc_url" => @rpc_url, "store" => MemoryStore})
    end
  end

  describe "challenge_method_details/1" do
    test "advertises network, credential types, and feePayer", %{charge: charge} do
      details = Solana.challenge_method_details(charge)

      assert details["network"] == "devnet"
      assert details["credentialTypes"] == ["transaction", "signature"]
      assert details["feePayer"] == false
      refute Map.has_key?(details, "rpc_url")
      refute Map.has_key?(details, "store")
      refute Map.has_key?(details, "req_options")
    end

    test "defaults network to mainnet when unset" do
      {:ok, charge} = Charge.new(amount: "1", currency: "sol")
      details = Solana.challenge_method_details(charge)
      assert details["network"] == "mainnet"
    end

    test "includes decimals and tokenProgram for SPL", %{charge: charge} do
      charge = %{
        charge
        | currency: @usdc_devnet,
          method_details:
            Map.merge(charge.method_details, %{
              "decimals" => 6,
              "token_program" => @token_program
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["decimals"] == 6
      assert details["tokenProgram"] == @token_program
    end

    test "omits decimals for native SOL even if configured", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "decimals", 9)}
      details = Solana.challenge_method_details(charge)
      refute Map.has_key?(details, "decimals")
      refute Map.has_key?(details, "tokenProgram")
    end

    test "includes feePayerKey derived from the private key", %{
      charge: charge,
      fee_payer: fee_payer,
      fee_payer_seed: seed
    } do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(seed, case: :lower)
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayer"] == true
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "402 challenge encodes Solana methodDetails" do
      {recipient, _} = Keys.generate_keypair()

      config =
        PaymentPlug.init(
          secret_key: "hmac-secret-for-solana-challenge-test",
          realm: "api.example.com",
          method: Solana,
          amount: Integer.to_string(@amount),
          currency: "sol",
          recipient: Keys.to_address(recipient),
          method_config: %{"rpc_url" => @rpc_url, "network" => "devnet"}
        )

      conn = :get |> Plug.Test.conn("/resource") |> PaymentPlug.call(config)
      assert conn.status == 402
      [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert {:ok, challenge} = Headers.parse_challenge(header)
      assert {:ok, json} = Base.url_decode64(challenge.request, padding: false)
      assert {:ok, request} = Jason.decode(json)
      assert request["methodDetails"]["network"] == "devnet"
      assert request["methodDetails"]["credentialTypes"] == ["transaction"]
      assert request["methodDetails"]["feePayer"] == false
      refute Map.has_key?(request["methodDetails"], "rpc_url")
      refute Map.has_key?(request["methodDetails"], "pushBinding")
    end
  end

  describe "push (type=signature) enablement and challenge binding" do
    setup %{charge: charge} do
      {:ok, bare: %{charge | method_details: Map.delete(charge.method_details, "push")}}
    end

    test "push is disabled by default", %{bare: charge, payer: payer, recipient: recipient} do
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))

      assert Solana.challenge_method_details(charge)["credentialTypes"] == ["transaction"]

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.type =~ "invalid-payload"
      assert error.detail =~ "not enabled"
    end

    test "push: false keeps push disabled", %{bare: charge} do
      charge = put_details(charge, %{"push" => false})
      assert :ok = Solana.validate_config!(charge.method_details)
      assert Solana.challenge_method_details(charge)["credentialTypes"] == ["transaction"]

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "not enabled"
    end

    test "rejects an unknown push mode at init", %{bare: charge} do
      assert_raise ArgumentError, ~r/"push" must be/, fn ->
        Solana.validate_config!(Map.put(charge.method_details, "push", true))
      end
    end

    test "accepts both push modes at init", %{bare: charge} do
      for mode <- ["challenge_memo", "unbound"] do
        assert :ok = Solana.validate_config!(Map.put(charge.method_details, "push", mode))
      end
    end

    test "unbound push advertises signature without a binding marker", %{charge: charge} do
      details = Solana.challenge_method_details(charge)
      assert details["credentialTypes"] == ["transaction", "signature"]
      refute Map.has_key?(details, "pushBinding")
    end

    test "fee-payer endpoints never advertise push", %{bare: charge, fee_payer_seed: seed} do
      charge =
        put_details(charge, %{
          "push" => "challenge_memo",
          "fee_payer" => true,
          "fee_payer_private_key" => Base.encode16(seed, case: :lower)
        })

      details = Solana.challenge_method_details(charge)
      assert details["credentialTypes"] == ["transaction"]
      refute Map.has_key?(details, "pushBinding")
    end

    test "challenge_memo advertises the binding profile", %{bare: charge} do
      details = charge |> put_details(%{"push" => "challenge_memo"}) |> Solana.challenge_method_details()
      assert details["credentialTypes"] == ["transaction", "signature"]
      assert details["pushBinding"] == "challengeMemo"
    end

    test "push_memo/1 is a prefixed, domain-separated SHA-256 of the challenge id" do
      memo = Solana.push_memo("challenge-a")
      assert memo == "mpp-push:" <> Base.encode16(:crypto.hash(:sha256, "mpp-solana-push:challenge-a"), case: :lower)
      assert byte_size(memo) == 73
      refute memo == Solana.push_memo("challenge-b")
      refute memo =~ "challenge-a"
    end

    test "challenge_memo accepts a transfer carrying this challenge's memo", %{
      bare: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "chal-1"})
      signature = fake_signature()
      stub_get_transaction(memo_parsed_tx(signature, payer, recipient, Solana.push_memo("chal-1")))

      assert {:ok, %Receipt{reference: ^signature}} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)
    end

    test "challenge_memo rejects a matching transfer made for a different challenge", %{
      bare: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "fresh-challenge"})
      signature = fake_signature()
      stub_get_transaction(memo_parsed_tx(signature, payer, recipient, Solana.push_memo("victim-challenge")))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.type =~ "verification-failed"
      assert error.detail =~ "memo"
    end

    test "challenge_memo rejects a matching transfer without any memo", %{
      bare: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "chal-1"})
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "memo"
    end

    test "challenge_memo rejects the raw challenge id as memo", %{bare: charge, payer: payer, recipient: recipient} do
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "chal-1"})
      signature = fake_signature()
      stub_get_transaction(memo_parsed_tx(signature, payer, recipient, "chal-1"))

      assert {:error, %Errors{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, charge)
    end

    test "challenge_memo does not burn the signature when the memo does not bind", %{
      bare: charge,
      payer: payer,
      recipient: recipient
    } do
      start_supervised!(MemoryStore)
      charge = put_details(charge, %{"push" => "challenge_memo", "store" => MemoryStore})
      signature = fake_signature()
      stub_get_transaction(memo_parsed_tx(signature, payer, recipient, Solana.push_memo("owner")))

      attacker = put_details(charge, %{"challenge_id" => "attacker"})
      assert {:error, %Errors{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, attacker)

      owner = put_details(charge, %{"challenge_id" => "owner"})
      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, owner)

      assert {:error, %Errors{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, owner)
    end

    test "challenge_memo fails closed without a challenge id", %{bare: charge} do
      charge = put_details(charge, %{"push" => "challenge_memo"})

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "challenge binding"
    end

    test "challenge_memo rejects a pull transaction bound to another challenge", context do
      %{bare: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "attacker"})
      {tx, encoded} = memo_pull_tx(payer, seed, recipient, [Solana.push_memo("victim")])
      stub_pull_success(pull_signature(tx), sol_parsed_tx(pull_signature(tx), payer, recipient, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "memo"
    end

    test "challenge_memo rejects a pull transaction with an unexpected memo", context do
      %{bare: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "chal-1"})
      {_tx, encoded} = memo_pull_tx(payer, seed, recipient, ["order-1"])

      assert {:error, %Errors{}} = Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end

    test "challenge_memo accepts pull memos a reference client adds", context do
      %{bare: charge, payer: payer, payer_seed: seed, recipient: recipient} = context

      charge =
        put_details(%{charge | external_id: "order-42"}, %{"push" => "challenge_memo", "challenge_id" => "chal-1"})

      {tx, encoded} = memo_pull_tx(payer, seed, recipient, ["order-42", Solana.push_memo("chal-1")])
      stub_pull_success(pull_signature(tx), sol_parsed_tx(pull_signature(tx), payer, recipient, @amount))

      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end

    test "challenge_memo accepts a memo-free pull transaction", context do
      %{bare: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      charge = put_details(charge, %{"push" => "challenge_memo", "challenge_id" => "chal-1"})
      {tx, encoded} = memo_pull_tx(payer, seed, recipient, [])
      stub_pull_success(pull_signature(tx), sol_parsed_tx(pull_signature(tx), payer, recipient, @amount))

      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end

    test "challenge_memo rejects a foreign push memo even when it is the externalId", context do
      %{bare: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      victim_memo = Solana.push_memo("victim")

      charge =
        put_details(%{charge | external_id: victim_memo}, %{"push" => "challenge_memo", "challenge_id" => "attacker"})

      {tx, encoded} = memo_pull_tx(payer, seed, recipient, [victim_memo])
      stub_pull_success(pull_signature(tx), sol_parsed_tx(pull_signature(tx), payer, recipient, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "memo"
    end

    test "challenge_memo treats the reserved prefix case-insensitively", context do
      %{bare: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      memo = "MPP-PUSH:" <> String.duplicate("a", 64)

      charge =
        put_details(%{charge | external_id: memo}, %{"push" => "challenge_memo", "challenge_id" => "attacker"})

      {tx, encoded} = memo_pull_tx(payer, seed, recipient, [memo])
      stub_pull_success(pull_signature(tx), sol_parsed_tx(pull_signature(tx), payer, recipient, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "memo"
    end

    test "validate_config! rejects a split memo in push-memo shape", %{bare: charge, recipient: recipient} do
      splits = [%{"recipient" => recipient, "amount" => "1", "memo" => Solana.push_memo("victim")}]

      assert_raise ArgumentError, ~r/mpp-push:/, fn ->
        Solana.validate_config!(Map.put(charge.method_details, "splits", splits))
      end

      assert :ok =
               Solana.validate_config!(Map.put(charge.method_details, "splits", [Map.put(hd(splits), "memo", "vendor")]))
    end

    test "challenge issue rejects a push-shaped externalId under challenge_memo", %{bare: charge} do
      bound = put_details(%{charge | external_id: Solana.push_memo("victim")}, %{"push" => "challenge_memo"})
      assert_raise ArgumentError, ~r/externalId/, fn -> Solana.challenge_method_details(bound) end

      unbound = put_details(%{charge | external_id: Solana.push_memo("victim")}, %{"push" => "unbound"})
      assert %{"credentialTypes" => _} = Solana.challenge_method_details(unbound)
    end

    test "through MPP.Plug only the issuing challenge's memo is accepted", %{payer: payer, recipient: recipient} do
      config = push_plug_config(recipient, 300)
      other = issue_challenge(push_plug_config(recipient, 600), "/a")
      owner = issue_challenge(config, "/a")
      refute owner.id == other.id

      signature = fake_signature()
      stub_get_transaction(memo_parsed_tx(signature, payer, recipient, Solana.push_memo(owner.id)))

      assert present_signature(config, other, signature).status == 402

      paid = present_signature(config, owner, signature)
      refute paid.halted
      assert %Receipt{reference: ^signature} = paid.assigns.mpp_receipt
    end
  end

  describe "verify/2 — payload errors" do
    test "rejects a missing type", %{charge: charge} do
      assert {:error, %Errors{} = error} = Solana.verify(%{}, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "type"
    end

    test "rejects type=hash", %{charge: charge} do
      assert {:error, %Errors{} = error} = Solana.verify(%{"type" => "hash", "hash" => "x"}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "rejects a zero-amount charge", %{charge: charge} do
      charge = %{charge | amount: "0"}
      payload = %{"type" => "signature", "signature" => fake_signature()}
      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "Zero-amount"
    end

    test "rejects a missing recipient", %{charge: charge} do
      charge = %{charge | recipient: nil}
      payload = %{"type" => "signature", "signature" => fake_signature()}
      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "recipient"
    end
  end

  describe "verify/2 — signature (push)" do
    test "returns a receipt for a matching native SOL transfer", %{
      charge: charge,
      payer: payer,
      recipient: recipient
    } do
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))

      assert {:ok, %Receipt{} = receipt} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert receipt.method == "solana"
      assert receipt.reference == signature
      assert receipt.status == "success"
    end

    test "returns a receipt for a matching SPL transferChecked", %{
      payer: payer,
      payer_seed: _seed,
      recipient: recipient
    } do
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {ata, _} = ATA.find_address(recipient, mint)
      signature = fake_signature()

      {:ok, charge} =
        Charge.new(
          amount: "1",
          currency: @usdc_devnet,
          recipient: Keys.to_address(recipient)
        )

      charge = %{
        charge
        | method_details: %{
            "rpc_url" => @rpc_url,
            "decimals" => 6,
            "token_program" => @token_program,
            "req_options" => [plug: {Req.Test, Solana}],
            "store" => false,
            "push" => "unbound"
          }
      }

      # Observed 2026-08-19 on devnet getTransaction jsonParsed for a USDC transferChecked.
      parsed = %{
        "meta" => %{"err" => nil, "status" => %{"Ok" => nil}},
        "transaction" => %{
          "signatures" => [signature],
          "message" => %{
            "instructions" => [
              %{
                "parsed" => %{
                  "info" => %{
                    "authority" => Keys.to_address(payer),
                    "destination" => Keys.to_address(ata),
                    "mint" => @usdc_devnet,
                    "source" => Keys.to_address(payer),
                    "tokenAmount" => %{
                      "amount" => "1",
                      "decimals" => 6,
                      "uiAmount" => 1.0e-6,
                      "uiAmountString" => "0.000001"
                    }
                  },
                  "type" => "transferChecked"
                },
                "program" => "spl-token",
                "programId" => @token_program,
                "stackHeight" => 1
              }
            ]
          }
        }
      }

      stub_get_transaction(parsed)
      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, charge)
    end

    test "rejects an invalid signature encoding", %{charge: charge} do
      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => "not-base58-0"}, charge)

      assert error.type =~ "invalid-payload"
    end

    test "rejects a missing signature field", %{charge: charge} do
      assert {:error, %Errors{} = error} = Solana.verify(%{"type" => "signature"}, charge)
      assert error.detail =~ "signature"
    end

    test "rejects signature credentials when feePayer is true", %{charge: charge, fee_payer_seed: seed} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(seed, case: :lower)
            })
      }

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "feePayer"
    end

    test "rejects a missing on-chain transaction", %{charge: charge} do
      Req.Test.stub(Solana, fn conn -> rpc_dispatch(conn, %{"getTransaction" => nil}) end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "not found"
    end

    test "rejects a failed on-chain transaction", %{charge: charge, payer: payer, recipient: recipient} do
      signature = fake_signature()
      parsed = sol_parsed_tx(signature, payer, recipient, @amount)
      parsed = put_in(parsed, ["meta", "err"], %{"InstructionError" => [0, "Custom"]})
      stub_get_transaction(parsed)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "failed on-chain"
    end

    test "rejects a transfer to the wrong recipient", %{charge: charge, payer: payer} do
      {wrong, _} = Keys.generate_keypair()
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, wrong, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "No matching transfer"
    end

    test "rejects a transfer with the wrong amount", %{charge: charge, payer: payer, recipient: recipient} do
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount - 1))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "No matching transfer"
    end

    test "matches each split to a distinct transfer", %{
      charge: charge,
      payer: payer,
      recipient: recipient
    } do
      {split_owner, _} = Keys.generate_keypair()
      split_amount = 1_000
      primary = @amount - split_amount

      charge = %{
        charge
        | method_details:
            Map.put(charge.method_details, "splits", [
              %{"recipient" => Keys.to_address(split_owner), "amount" => Integer.to_string(split_amount)}
            ])
      }

      signature = fake_signature()

      parsed = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "signatures" => [signature],
          "message" => %{
            "instructions" => [
              sol_ix(payer, recipient, primary),
              sol_ix(payer, split_owner, split_amount)
            ]
          }
        }
      }

      stub_get_transaction(parsed)
      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, charge)
    end

    test "does not let one transfer satisfy two legs to the same recipient", %{
      charge: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = %{
        charge
        | amount: "2000",
          method_details:
            Map.put(charge.method_details, "splits", [
              %{"recipient" => Keys.to_address(recipient), "amount" => "1000"}
            ])
      }

      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, 1000))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "No matching transfer"
    end
  end

  describe "verify/2 — transaction (pull)" do
    test "broadcasts a client-signed SOL transfer and returns a receipt", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      stub_pull_success(signature, sol_parsed_tx(signature, payer, recipient, @amount))

      assert {:ok, %Receipt{} = receipt} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert receipt.reference == signature
    end

    test "co-signs as fee payer before broadcast", context do
      %{
        charge: charge,
        payer: payer,
        payer_seed: payer_seed,
        recipient: recipient,
        fee_payer: fee_payer,
        fee_payer_seed: fee_payer_seed
      } = context

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(fee_payer_seed, case: :lower)
            })
      }

      ix = SystemProgram.transfer(payer, recipient, @amount)
      message = Transaction.build_message(fee_payer, [ix], @blockhash)
      partial = Transaction.sign_partial(message, %{1 => payer_seed})
      encoded = Base.encode64(Transaction.serialize(partial))

      expected_sig =
        :crypto.sign(:eddsa, :none, Transaction.serialize_message(message), [fee_payer_seed, :ed25519])

      expected_b58 = Cartouche.Base58.encode(expected_sig)

      stub_pull_success(expected_b58, sol_parsed_tx(expected_b58, payer, recipient, @amount))

      assert {:ok, %Receipt{reference: ^expected_b58}} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end

    test "rejects a fee-payer-sourced SOL transfer", context do
      %{
        charge: charge,
        recipient: recipient,
        fee_payer: fee_payer,
        fee_payer_seed: fee_payer_seed
      } = context

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(fee_payer_seed, case: :lower)
            })
      }

      ix = SystemProgram.transfer(fee_payer, recipient, @amount)
      message = Transaction.build_message(fee_payer, [ix], @blockhash)
      # Client is also the fee payer here — slot 0 must stay empty for sponsorship.
      partial = Transaction.sign_partial(message, %{})
      encoded = Base.encode64(Transaction.serialize(partial))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "Fee payer must not be the source"
    end

    test "rejects unexpected compiled instructions", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      {other, _} = Keys.generate_keypair()
      ix1 = SystemProgram.transfer(payer, recipient, @amount)
      ix2 = SystemProgram.transfer(payer, other, 1)
      message = Transaction.build_message(payer, [ix1, ix2], @blockhash)
      tx = Transaction.sign(message, [seed])
      encoded = Base.encode64(Transaction.serialize(tx))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "unexpected transfer" or error.detail =~ "No matching transfer"
    end

    test "rejects invalid base64", %{charge: charge} do
      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => "%%%"}, charge)

      assert error.type =~ "invalid-payload"
    end

    test "rejects a transaction that is too large", %{charge: charge} do
      huge = Base.encode64(:crypto.strong_rand_bytes(1233))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => huge}, charge)

      assert error.detail =~ "1232"
    end

    test "rejects unde-serializable bytes", %{charge: charge} do
      encoded = Base.encode64(<<1, 2, 3, 4>>)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "deserialized"
    end

    test "rejects a missing transaction field", %{charge: charge} do
      assert {:error, %Errors{} = error} = Solana.verify(%{"type" => "transaction"}, charge)
      assert error.detail =~ "transaction"
    end

    test "rejects a simulation failure", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))

      Req.Test.stub(Solana, fn conn ->
        rpc_dispatch(conn, %{
          "simulateTransaction" => %{"err" => "AccountNotFound", "logs" => [], "unitsConsumed" => 0}
        })
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "simulation"
    end

    test "broadcasts an SPL transferChecked", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      ix = TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6)
      message = Transaction.build_message(payer, [ix], @blockhash)
      tx = Transaction.sign(message, [seed])
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      {:ok, charge} =
        Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      charge = %{
        charge
        | method_details: %{
            "rpc_url" => @rpc_url,
            "decimals" => 6,
            "token_program" => @token_program,
            "req_options" => [plug: {Req.Test, Solana}],
            "store" => false
          }
      }

      parsed = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "signatures" => [signature],
          "message" => %{
            "instructions" => [
              %{
                "parsed" => %{
                  "info" => %{
                    "authority" => Keys.to_address(payer),
                    "destination" => Keys.to_address(dest_ata),
                    "mint" => @usdc_devnet,
                    "source" => Keys.to_address(source_ata),
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

      stub_pull_success(signature, parsed)
      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end
  end

  describe "verify/2 — replay protection" do
    setup %{charge: charge} do
      start_supervised!(MemoryStore)
      {:ok, charge: with_store(charge, MemoryStore)}
    end

    test "rejects a reused signature", %{charge: charge, payer: payer, recipient: recipient} do
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))
      payload = %{"type" => "signature", "signature" => signature}

      assert {:ok, %Receipt{}} = Solana.verify(payload, charge)
      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "does not mark a signature used when verification fails", %{
      charge: charge,
      payer: payer
    } do
      {wrong, _} = Keys.generate_keypair()
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, wrong, @amount))

      assert {:error, %Errors{}} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert MemoryStore.keys() == []
    end
  end

  describe "verify/2 — pull signature reservation" do
    setup %{payer: payer, payer_seed: seed, recipient: recipient} do
      message = Transaction.build_message(payer, [SystemProgram.transfer(payer, recipient, @amount)], @blockhash)
      tx = Transaction.sign(message, [seed])
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      {:ok,
       payload: %{"type" => "transaction", "transaction" => Base.encode64(Transaction.serialize(tx))},
       signature: signature,
       parsed: sol_parsed_tx(signature, payer, recipient, @amount)}
    end

    test "concurrent presentations of the same bytes under different challenges: exactly one proceeds", %{
      charge: charge,
      payload: payload,
      signature: signature,
      parsed: parsed
    } do
      start_supervised!(MemoryStore)
      test_pid = self()

      Req.Test.stub(Solana, fn conn ->
        {method, id, conn} = read_request(conn)
        send(test_pid, {:rpc, method, self()})

        if method == "simulateTransaction" do
          receive do: (:go -> :ok)
        end

        rpc_json(conn, id, "result", Map.fetch!(pull_results(signature, parsed), method))
      end)

      first = put_details(charge, %{"store" => MemoryStore, "challenge_id" => "challenge-a"})
      second = put_details(charge, %{"store" => MemoryStore, "challenge_id" => "challenge-b"})

      task = Task.async(fn -> Solana.verify(payload, first) end)
      assert_receive {:rpc, "simulateTransaction", simulating}

      assert {:error, %Errors{} = error} = Solana.verify(payload, second)
      assert error.detail =~ "already used"

      send(simulating, :go)
      assert {:ok, %Receipt{reference: ^signature}} = Task.await(task)
      assert_received {:rpc, "sendTransaction", _pid}
      refute_received {:rpc, "sendTransaction", _pid}
      refute_received {:rpc, "simulateTransaction", _pid}
    end

    test "a reservation store error fails closed before simulation", %{charge: charge, payload: payload} do
      charge = put_details(charge, %{"store" => AtomicFailStore})

      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail == "Dedup store error"
    end

    test "a signature reserved by an in-flight pull is refused as a push credential", %{
      charge: charge,
      payload: payload,
      signature: signature,
      parsed: parsed
    } do
      start_supervised!(MemoryStore)
      charge = put_details(charge, %{"store" => MemoryStore})
      stub_pull_success(signature, parsed)

      assert {:ok, %Receipt{}} = Solana.verify(payload, charge)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "already used"
    end

    test "a simulation failure releases the reservation so the same bytes can retry", %{
      charge: charge,
      payload: payload,
      signature: signature,
      parsed: parsed
    } do
      charge = %{charge | method_details: Map.delete(charge.method_details, "store")}
      stub_simulation_fails_once(signature, parsed)

      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "simulation"
      assert {:ok, %Receipt{reference: ^signature}} = Solana.verify(payload, charge)
      assert {:error, %Errors{} = replay} = Solana.verify(payload, charge)
      assert replay.detail =~ "already used"
    end

    test "a store without delete/2 keeps the reservation after a simulation failure", %{
      charge: charge,
      payload: payload,
      signature: signature,
      parsed: parsed
    } do
      start_supervised!(MemoryStore)
      charge = put_details(charge, %{"store" => MemoryStore})
      stub_simulation_fails_once(signature, parsed)

      assert {:error, %Errors{}} = Solana.verify(payload, charge)
      assert MemoryStore.keys() == ["mpp:solana:" <> signature]
      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "a failed broadcast keeps the reservation because the transaction may still land", %{
      charge: charge,
      payload: payload,
      signature: signature,
      parsed: parsed
    } do
      charge = %{charge | method_details: Map.delete(charge.method_details, "store")}

      Req.Test.stub(Solana, fn conn ->
        {method, id, conn} = read_request(conn)

        if method == "sendTransaction" do
          rpc_json(conn, id, "error", %{"code" => -32_002, "message" => "node unhealthy"})
        else
          rpc_json(conn, id, "result", Map.fetch!(pull_results(signature, parsed), method))
        end
      end)

      assert {:error, %Errors{}} = Solana.verify(payload, charge)
      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    for store <- [ErrorDeleteStore, RaisingDeleteStore, ExitingDeleteStore] do
      test "a #{inspect(store)} release fault keeps the simulation error", %{
        charge: charge,
        payload: payload,
        signature: signature,
        parsed: parsed
      } do
        charge = put_details(charge, %{"store" => unquote(store)})
        stub_simulation_fails_once(signature, parsed)

        assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
        assert error.detail =~ "simulation"
      end
    end
  end

  describe "verify/2 — replay protection on by default" do
    test "the app-started default store rejects replay", %{
      charge: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = %{charge | method_details: Map.delete(charge.method_details, "store")}
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))
      payload = %{"type" => "signature", "signature" => signature}

      assert {:ok, %Receipt{}} = Solana.verify(payload, charge)
      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail =~ "already used"
    end

    test "store: false opts out", %{charge: charge, payer: payer, recipient: recipient} do
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))
      payload = %{"type" => "signature", "signature" => signature}

      assert {:ok, %Receipt{}} = Solana.verify(payload, charge)
      assert {:ok, %Receipt{}} = Solana.verify(payload, charge)
    end
  end

  describe "verify/2 — dedup store failures" do
    test "read failure in the pre-check surfaces a generic dedup error", %{charge: charge} do
      charge = with_store(charge, GetFailStore)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail == "Dedup store error"
    end

    test "atomic commit collision is rejected as replay", %{
      charge: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = with_store(charge, AlreadyExistsStore)
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "already used"
    end

    test "unexpected atomic commit error surfaces a generic dedup error", %{
      charge: charge,
      payer: payer,
      recipient: recipient
    } do
      charge = with_store(charge, AtomicFailStore)
      signature = fake_signature()
      stub_get_transaction(sol_parsed_tx(signature, payer, recipient, @amount))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail == "Dedup store error"
    end
  end

  describe "verify/2 — RPC errors" do
    test "getTransaction transport failure is a generic RPC error", %{charge: charge} do
      Req.Test.stub(Solana, fn conn ->
        {_, id, conn} = read_request(conn)
        rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "boom"})
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail == "Solana RPC request failed"
    end

    test "simulateTransaction transport failure is a generic RPC error", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))

      Req.Test.stub(Solana, fn conn ->
        {_, id, conn} = read_request(conn)
        rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "sim-fail"})
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail == "Solana RPC request failed"
    end

    test "on-chain error after send is rejected", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      Req.Test.stub(Solana, fn conn ->
        rpc_dispatch(conn, %{
          "simulateTransaction" => %{"err" => nil, "logs" => [], "unitsConsumed" => 1},
          "sendTransaction" => signature,
          "getSignatureStatuses" => [
            %{"slot" => 1, "confirmations" => 0, "err" => "InstructionError", "confirmationStatus" => "confirmed"}
          ]
        })
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "failed on-chain"
    end

    test "confirmation timeout is rejected", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "confirmation_timeout", 1)
      }

      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      Req.Test.stub(Solana, fn conn ->
        rpc_dispatch(conn, %{
          "simulateTransaction" => %{"err" => nil, "logs" => [], "unitsConsumed" => 1},
          "sendTransaction" => signature,
          "getSignatureStatuses" => [nil]
        })
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "Timed out"
    end

    test "wait_for_confirmation false returns after sendTransaction", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "wait_for_confirmation", false)
      }

      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      Req.Test.stub(Solana, fn conn ->
        rpc_dispatch(conn, %{
          "simulateTransaction" => %{"err" => nil, "logs" => [], "unitsConsumed" => 1},
          "sendTransaction" => signature
        })
      end)

      assert {:ok, %Receipt{reference: ^signature}} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end

    test "wait_for_confirmation false surfaces sendTransaction errors", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "wait_for_confirmation", false)
      }

      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))

      Req.Test.stub(Solana, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "simulateTransaction" ->
            rpc_json(conn, id, "result", %{"err" => nil, "logs" => [], "unitsConsumed" => 1})

          "sendTransaction" ->
            rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "send-fail"})
        end
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail == "Solana RPC request failed"
    end
  end

  describe "verify/2 — compiled instruction policy" do
    test "allows memo and compute-budget instructions", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      memo_program = elem(Cartouche.Base58.decode("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"), 1)

      ixs = [
        %Instruction{program_id: Programs.compute_budget_program(), accounts: [], data: <<2, 2000::little-32>>},
        %Instruction{program_id: memo_program, accounts: [], data: "order-1"},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))
      stub_pull_success(signature, sol_parsed_tx(signature, payer, recipient, @amount))

      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end

    test "rejects a compute-unit ceiling breach when fee paying", context do
      %{
        charge: charge,
        payer: payer,
        payer_seed: payer_seed,
        recipient: recipient,
        fee_payer: fee_payer,
        fee_payer_seed: fee_payer_seed
      } = context

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(fee_payer_seed, case: :lower),
              "max_compute_unit_limit" => 1_000
            })
      }

      ixs = [
        %Instruction{program_id: Programs.compute_budget_program(), accounts: [], data: <<2, 50_000::little-32>>},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(fee_payer, ixs, @blockhash)
      partial = Transaction.sign_partial(message, %{1 => payer_seed})
      encoded = Base.encode64(Transaction.serialize(partial))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "Compute unit limit"
    end

    test "rejects an unknown program instruction", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context

      ixs = [
        %Instruction{program_id: <<9::256>>, accounts: [], data: <<1>>},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      encoded = Base.encode64(Transaction.serialize(tx))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "unexpected"
    end

    test "rejects an unsigned transaction", context do
      %{charge: charge, payer: payer, recipient: recipient} = context
      ix = SystemProgram.transfer(payer, recipient, @amount)
      message = Transaction.build_message(payer, [ix], @blockhash)
      unsigned = Transaction.sign_partial(message, %{})
      encoded = Base.encode64(Transaction.serialize(unsigned))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "missing a required signature"
    end

    test "rejects a fee-payer slot that is already signed", context do
      %{
        charge: charge,
        payer: payer,
        payer_seed: payer_seed,
        recipient: recipient,
        fee_payer: fee_payer,
        fee_payer_seed: fee_payer_seed
      } = context

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(fee_payer_seed, case: :lower)
            })
      }

      ix = SystemProgram.transfer(payer, recipient, @amount)
      message = Transaction.build_message(fee_payer, [ix], @blockhash)
      fully_signed = Transaction.sign(message, [fee_payer_seed, payer_seed])
      encoded = Base.encode64(Transaction.serialize(fully_signed))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "Fee payer signature slot must be empty"
    end

    test "rejects a fee payer mismatch", context do
      %{
        charge: charge,
        payer: payer,
        payer_seed: payer_seed,
        recipient: recipient,
        fee_payer_seed: fee_payer_seed
      } = context

      {other_fee_payer, _} = Keys.generate_keypair()

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(fee_payer_seed, case: :lower)
            })
      }

      ix = SystemProgram.transfer(payer, recipient, @amount)
      message = Transaction.build_message(other_fee_payer, [ix], @blockhash)
      partial = Transaction.sign_partial(message, %{1 => payer_seed})
      encoded = Base.encode64(Transaction.serialize(partial))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "fee payer does not match"
    end

    test "rejects ATA creation on a native SOL charge", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      ixs = [ATA.create_idempotent(payer, recipient, mint), SystemProgram.transfer(payer, recipient, @amount)]
      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      encoded = Base.encode64(Transaction.serialize(tx))

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail =~ "unexpected"
    end

    test "accepts idempotent ATA creation for a split recipient", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      {split_owner, _} = Keys.generate_keypair()
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      {split_ata, _} = ATA.find_address(split_owner, mint)

      ixs = [
        ATA.create_idempotent(payer, split_owner, mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 9_000, 6),
        TokenProgram.transfer_checked(source_ata, mint, split_ata, payer, 1_000, 6)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      encoded = Base.encode64(Transaction.serialize(tx))
      signature = Cartouche.Base58.encode(hd(tx.signatures))

      {:ok, charge} =
        Charge.new(amount: "10000", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      charge = %{
        charge
        | method_details: %{
            "rpc_url" => @rpc_url,
            "decimals" => 6,
            "token_program" => @token_program,
            "splits" => [
              %{
                "recipient" => Keys.to_address(split_owner),
                "amount" => "1000",
                "ataCreationRequired" => true
              }
            ],
            "req_options" => [plug: {Req.Test, Solana}],
            "store" => false
          }
      }

      parsed = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "signatures" => [signature],
          "message" => %{
            "instructions" => [
              %{
                "parsed" => %{
                  "info" => %{
                    "authority" => Keys.to_address(payer),
                    "destination" => Keys.to_address(dest_ata),
                    "mint" => @usdc_devnet,
                    "source" => Keys.to_address(source_ata),
                    "tokenAmount" => %{"amount" => "9000", "decimals" => 6}
                  },
                  "type" => "transferChecked"
                },
                "program" => "spl-token",
                "programId" => @token_program
              },
              %{
                "parsed" => %{
                  "info" => %{
                    "authority" => Keys.to_address(payer),
                    "destination" => Keys.to_address(split_ata),
                    "mint" => @usdc_devnet,
                    "source" => Keys.to_address(source_ata),
                    "tokenAmount" => %{"amount" => "1000", "decimals" => 6}
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

      stub_pull_success(signature, parsed)
      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)
    end
  end

  describe "verify/2 — more config and payload edges" do
    test "rejects a missing rpc_url at verify time", %{charge: charge} do
      charge = %{charge | method_details: Map.delete(charge.method_details, "rpc_url")}

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "rpc_url"
    end

    test "rejects splits that consume the entire amount", %{charge: charge, recipient: recipient} do
      charge = %{
        charge
        | method_details:
            Map.put(charge.method_details, "splits", [
              %{"recipient" => Keys.to_address(recipient), "amount" => Integer.to_string(@amount)}
            ])
      }

      stub_get_transaction(%{"meta" => %{"err" => nil}, "transaction" => %{"message" => %{"instructions" => []}}})

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "remainder"
    end

    test "rejects missing transaction metadata", %{charge: charge} do
      stub_get_transaction(%{"transaction" => %{"message" => %{"instructions" => []}}})

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "metadata"
    end

    test "rejects missing parsed instructions", %{charge: charge} do
      stub_get_transaction(%{"meta" => %{"err" => nil}, "transaction" => %{}})

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)

      assert error.detail =~ "parsed instructions"
    end

    test "accepts fee_payer_private_key as base58", %{charge: charge, fee_payer_seed: seed, fee_payer: fee_payer} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Cartouche.Base58.encode(seed)
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "accepts an explicit fee_payer_key", %{charge: charge, fee_payer: fee_payer, fee_payer_seed: seed} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(seed, case: :lower),
              "fee_payer_key" => Keys.to_address(fee_payer)
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "accepts a 64-byte hex keypair as fee_payer_private_key", %{
      charge: charge,
      fee_payer: fee_payer,
      fee_payer_seed: seed
    } do
      hex = Base.encode16(seed <> fee_payer, case: :lower)

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => "0x" <> hex
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "accepts a Solana JSON keypair as fee_payer_private_key", %{
      charge: charge,
      fee_payer: fee_payer,
      fee_payer_seed: seed
    } do
      json = Jason.encode!(:binary.bin_to_list(seed <> fee_payer))

      assert :ok =
               Solana.validate_config!(%{
                 "rpc_url" => @rpc_url,
                 "fee_payer" => true,
                 "fee_payer_private_key" => json
               })

      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => json
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "raises on unsupported store tuple form" do
      assert_raise ArgumentError, ~r/tuple form/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "store" => {Enum, []}})
      end
    end

    test "raises on non-keyword ConCacheStore opts" do
      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "store" => {ConCacheStore, %{name: :x}}})
      end
    end

    test "raises on non-list splits" do
      assert_raise ArgumentError, ~r/list of maps/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "splits" => %{}})
      end
    end

    test "raises on a non-map split entry" do
      assert_raise ArgumentError, ~r/list of maps/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "splits" => [1]})
      end
    end

    test "raises on a split missing recipient" do
      assert_raise ArgumentError, ~r/recipient/, fn ->
        Solana.validate_config!(%{"rpc_url" => @rpc_url, "splits" => [%{"amount" => "1"}]})
      end
    end

    test "includes splits in challenge details", %{charge: charge, recipient: recipient} do
      splits = [%{"recipient" => Keys.to_address(recipient), "amount" => "1"}]
      charge = %{charge | method_details: Map.put(charge.method_details, "splits", splits)}
      details = Solana.challenge_method_details(charge)
      assert details["splits"] == splits
    end

    test "omits invalid decimals for SPL", %{charge: charge} do
      charge = %{
        charge
        | currency: @usdc_devnet,
          method_details: Map.merge(charge.method_details, %{"decimals" => 99, "tokenProgram" => @token_program})
      }

      details = Solana.challenge_method_details(charge)
      refute Map.has_key?(details, "decimals")
      assert details["tokenProgram"] == @token_program
    end

    test "advertises feePayer from the camelCase config key", %{
      charge: charge,
      fee_payer_seed: seed,
      fee_payer: fee_payer
    } do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "feePayer" => true,
              "fee_payer_private_key" => Base.encode16(seed, case: :lower)
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayer"] == true
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "omits feePayerKey when no key material is configured", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", true)}
      details = Solana.challenge_method_details(charge)
      assert details["feePayer"] == true
      refute Map.has_key?(details, "feePayerKey")
    end

    test "accepts a 64-byte base58 fee_payer_private_key", %{charge: charge, fee_payer: fee_payer, fee_payer_seed: seed} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Cartouche.Base58.encode(seed <> fee_payer)
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "omits feePayerKey for an invalid base58 seed", %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => "!!!!"
            })
      }

      details = Solana.challenge_method_details(charge)
      refute Map.has_key?(details, "feePayerKey")
    end

    test "falls back when fee_payer_key is not a valid address", %{charge: charge, fee_payer_seed: seed} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(seed, case: :lower),
              "fee_payer_key" => "not-a-pubkey"
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == "not-a-pubkey"
    end

    test "omits feePayerKey when the private key cannot be decoded", %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => "[not-json"
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayer"] == true
      refute Map.has_key?(details, "feePayerKey")
    end

    test "falls back when token_program is not valid base58", %{charge: charge} do
      charge = %{
        charge
        | currency: @usdc_devnet,
          method_details: Map.put(charge.method_details, "token_program", "%%%")
      }

      details = Solana.challenge_method_details(charge)
      assert details["tokenProgram"] == "%%%"
    end

    test "uses feePayerKey when provided", %{charge: charge, fee_payer: fee_payer, fee_payer_seed: seed} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => Base.encode16(seed, case: :lower),
              "feePayerKey" => Keys.to_address(fee_payer)
            })
      }

      details = Solana.challenge_method_details(charge)
      assert details["feePayerKey"] == Keys.to_address(fee_payer)
    end

    test "rejects leftover extra transfers in push mode", %{charge: charge, payer: payer, recipient: recipient} do
      {other, _} = Keys.generate_keypair()
      signature = fake_signature()

      parsed = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "signatures" => [signature],
          "message" => %{
            "instructions" => [
              sol_ix(payer, recipient, @amount),
              sol_ix(payer, other, 1)
            ]
          }
        }
      }

      stub_get_transaction(parsed)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

      assert error.detail =~ "unexpected transfer"
    end

    test "verifies SPL with an undecodable token_program by falling back", context do
      %{payer: payer, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      signature = fake_signature()

      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      charge = %{
        charge
        | method_details: %{
            "rpc_url" => @rpc_url,
            "token_program" => "not-base58",
            "req_options" => [plug: {Req.Test, Solana}],
            "store" => false,
            "push" => "unbound"
          }
      }

      parsed = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "message" => %{
            "instructions" => [
              %{
                "parsed" => %{
                  "type" => "transferChecked",
                  "info" => %{
                    "authority" => Keys.to_address(payer),
                    "destination" => Keys.to_address(dest_ata),
                    "mint" => @usdc_devnet,
                    "source" => Keys.to_address(payer),
                    "tokenAmount" => %{"amount" => "1", "decimals" => 6}
                  }
                },
                "program" => "spl-token",
                "programId" => @token_program
              }
            ]
          }
        }
      }

      stub_get_transaction(parsed)
      assert {:ok, %Receipt{}} = Solana.verify(%{"type" => "signature", "signature" => signature}, charge)
    end

    test "rejects a non-sol currency that is not a mint", %{charge: charge} do
      charge = %{charge | currency: "usd"}
      stub_get_transaction(%{"meta" => %{"err" => nil}, "transaction" => %{"message" => %{"instructions" => []}}})

      assert {:error, %Errors{}} =
               Solana.verify(%{"type" => "signature", "signature" => fake_signature()}, charge)
    end

    test "sendTransaction RPC error with wait true is generic", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      encoded = Base.encode64(Transaction.serialize(tx))

      Req.Test.stub(Solana, fn conn ->
        {method, id, conn} = read_request(conn)

        case method do
          "simulateTransaction" ->
            rpc_json(conn, id, "result", %{"err" => nil, "logs" => [], "unitsConsumed" => 1})

          "sendTransaction" ->
            rpc_json(conn, id, "error", %{"code" => -32_000, "message" => "send-fail"})
        end
      end)

      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

      assert error.detail == "Solana RPC request failed"
    end
  end

  describe "Instructions.payment_legs/1" do
    test "returns the primary remainder and splits", %{charge: charge, recipient: recipient} do
      {split_owner, _} = Keys.generate_keypair()

      charge = %{
        charge
        | method_details:
            Map.put(charge.method_details, "splits", [
              %{"recipient" => Keys.to_address(split_owner), "amount" => "1000"}
            ])
      }

      assert {:ok, [primary, split]} = Instructions.payment_legs(charge)
      assert primary.amount == @amount - 1000
      assert primary.recipient == recipient
      assert split.amount == 1000
      assert split.recipient == split_owner
    end

    test "rejects a non-binary recipient", %{charge: charge} do
      charge = %{charge | recipient: 1}
      assert {:error, %Errors{}} = Instructions.payment_legs(charge)
    end

    test "rejects a nil recipient" do
      {:ok, charge} = Charge.new(amount: "10", currency: "sol")
      assert {:error, %Errors{} = error} = Instructions.payment_legs(charge)
      assert error.detail =~ "recipient"
    end

    test "rejects more than 8 valid splits", %{charge: charge} do
      splits =
        for _i <- 1..9 do
          {pub, _} = Keys.generate_keypair()
          %{"recipient" => Keys.to_address(pub), "amount" => "1"}
        end

      charge = %{charge | amount: "100", method_details: Map.put(charge.method_details, "splits", splits)}
      assert {:error, %Errors{} = error} = Instructions.payment_legs(charge)
      assert error.detail =~ "Too many"
    end

    test "rejects a non-base58 recipient", %{charge: charge} do
      charge = %{charge | recipient: "%%%"}
      assert {:error, %Errors{}} = Instructions.payment_legs(charge)
    end

    test "rejects a non-integer amount", %{charge: charge} do
      charge = %{charge | amount: "1.5"}
      assert {:error, %Errors{}} = Instructions.payment_legs(charge)
    end

    test "rejects a split with amount 0", %{charge: charge, recipient: recipient} do
      charge = %{
        charge
        | method_details:
            Map.put(charge.method_details, "splits", [
              %{"recipient" => Keys.to_address(recipient), "amount" => "0"}
            ])
      }

      assert {:error, %Errors{} = error} = Instructions.payment_legs(charge)
      assert error.detail =~ "positive"
    end

    test "rejects a non-map split", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "splits", ["nope"])}
      assert {:error, %Errors{}} = Instructions.payment_legs(charge)
    end
  end

  describe "Instructions.classify_compiled/1" do
    test "errors when a compiled instruction account list is out of range", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      [ix] = tx.message.instructions
      tx = %{tx | message: %{tx.message | instructions: [%{ix | accounts: [255, 254]}]}}
      assert {:error, reason} = Instructions.classify_compiled(tx)
      assert reason =~ "out of range"
    end

    test "errors when a compiled account index is out of range", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      [ix] = tx.message.instructions
      bad = %{ix | program_id_index: 255}
      tx = %{tx | message: %{tx.message | instructions: [bad]}}
      assert {:error, reason} = Instructions.classify_compiled(tx)
      assert reason =~ "out of range"
    end

    test "classifies a non-idempotent ATA create as ata_create", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      ixs = [ATA.create(payer, recipient, mint)]
      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      assert {:ok, [{:ata_create, %{idempotent?: false}}]} = Instructions.classify_compiled(tx)
    end

    test "classifies a compute-unit price instruction", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context

      ixs = [
        %Instruction{program_id: Programs.compute_budget_program(), accounts: [], data: <<3, 500::little-64>>},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      assert {:ok, classified} = Instructions.classify_compiled(tx)
      assert Enum.any?(classified, &match?({:compute_budget, {:set_price, 500}}, &1))
    end

    test "classifies a compute-budget discriminator that is not limit or price", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context

      ixs = [
        %Instruction{program_id: Programs.compute_budget_program(), accounts: [], data: <<1, 0, 0, 0, 0>>},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      assert {:ok, classified} = Instructions.classify_compiled(tx)
      assert Enum.any?(classified, &match?({:compute_budget, {:other, 1}}, &1))
    end

    test "classifies a truncated ATA instruction as unknown", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      ix = ATA.create_idempotent(payer, recipient, mint)
      message = Transaction.build_message(payer, [ix], @blockhash)
      tx = Transaction.sign(message, [seed])
      [compiled] = tx.message.instructions
      tx = %{tx | message: %{tx.message | instructions: [%{compiled | accounts: [0], data: <<1>>}]}}
      assert {:ok, [{:unknown, _}]} = Instructions.classify_compiled(tx)
    end

    test "verify_compiled maps a classify error into a typed error", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      [ix] = tx.message.instructions
      tx = %{tx | message: %{tx.message | instructions: [%{ix | program_id_index: 255}]}}
      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "out of range"
    end

    test "classifies empty compute-budget data as other", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context

      ixs = [
        %Instruction{program_id: Programs.compute_budget_program(), accounts: [], data: <<>>},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      assert {:ok, classified} = Instructions.classify_compiled(tx)
      assert Enum.any?(classified, &match?({:compute_budget, {:other, nil}}, &1))
    end

    test "classifies a non-transfer system instruction as unknown", context do
      %{payer: payer, payer_seed: seed} = context
      {new_account, new_seed} = Keys.generate_keypair()
      ix = SystemProgram.create_account(payer, new_account, 1_000, 0, payer)
      message = Transaction.build_message(payer, [ix], @blockhash)
      tx = Transaction.sign(message, [seed, new_seed])
      assert {:ok, [{:unknown, <<0::256>>}]} = Instructions.classify_compiled(tx)
    end
  end

  describe "Instructions.classify_parsed/1" do
    test "classifies system transfers by programId without program name" do
      rpc_tx = %{
        "transaction" => %{
          "message" => %{
            "instructions" => [
              %{
                "programId" => "11111111111111111111111111111111",
                "parsed" => %{
                  "type" => "transfer",
                  "info" => %{
                    "source" => "11111111111111111111111111111111",
                    "destination" => "11111111111111111111111111111111",
                    "lamports" => "10"
                  }
                }
              }
            ]
          }
        }
      }

      assert {:ok, [{:sol_transfer, %{lamports: 10}}]} = Instructions.classify_parsed(rpc_tx)
    end

    test "classifies a map without parsed fields as unknown" do
      rpc_tx = %{"transaction" => %{"message" => %{"instructions" => [%{"foo" => 1}]}}}
      assert {:ok, [{:unknown, <<>>}]} = Instructions.classify_parsed(rpc_tx)
    end

    test "classifies jsonParsed ATA createIdempotent and compute-budget and memo" do
      memo = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
      cu = "ComputeBudget111111111111111111111111111111"

      rpc_tx = %{
        "transaction" => %{
          "message" => %{
            "instructions" => [
              %{
                "parsed" => %{
                  "type" => "createIdempotent",
                  "info" => %{
                    "account" => "11111111111111111111111111111111",
                    "wallet" => "11111111111111111111111111111111",
                    "mint" => @usdc_devnet,
                    "source" => "11111111111111111111111111111111",
                    "tokenProgram" => @token_program
                  }
                },
                "programId" => "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
              },
              %{"programId" => cu, "data" => "EuxTsD"},
              %{"programId" => memo, "parsed" => "hello"},
              %{"programId" => "11111111111111111111111111111112"},
              "not-a-map"
            ]
          }
        }
      }

      assert {:ok, classified} = Instructions.classify_parsed(rpc_tx)
      assert match?({:ata_create, %{idempotent?: true}}, hd(classified))
      assert Enum.any?(classified, &match?({:compute_budget, _}, &1))
      assert Enum.any?(classified, &match?({:memo, "hello"}, &1))
      assert Enum.any?(classified, &match?({:unknown, _}, &1))
    end
  end

  describe "Instructions.verify_compiled/3" do
    test "treats missing fee_payer opt as not sponsored", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      tx = signed_sol_transfer(payer, seed, recipient, @amount)
      assert :ok = Instructions.verify_compiled(tx, charge, %{})
    end

    test "rejects leftover extra SOL transfers", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      {other, _} = Keys.generate_keypair()
      ixs = [SystemProgram.transfer(payer, recipient, @amount), SystemProgram.transfer(payer, other, 1)]
      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])

      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "unexpected transfer"
    end

    test "rejects an extra SPL transfer on a native SOL charge", context do
      %{charge: charge, payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)

      ixs = [
        SystemProgram.transfer(payer, recipient, @amount),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])

      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "unexpected"
    end

    test "rejects an extra SOL transfer on an SPL charge", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)

      ixs = [
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6),
        SystemProgram.transfer(payer, recipient, 1)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "unexpected"
    end

    test "rejects a fee-payer-authorized SPL transfer", context do
      %{recipient: recipient, fee_payer: fee_payer} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(fee_payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      ix = TokenProgram.transfer_checked(source_ata, mint, dest_ata, fee_payer, 1, 6)
      message = Transaction.build_message(fee_payer, [ix], @blockhash)
      tx = Transaction.sign_partial(message, %{})
      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      assert {:error, %Errors{} = error} =
               Instructions.verify_compiled(tx, charge, %{fee_payer: true, fee_payer_pubkey: fee_payer})

      assert error.detail =~ "authority"
    end

    test "rejects ATA creation for the primary recipient", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)

      ixs = [
        ATA.create_idempotent(payer, recipient, mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "authorized split"
    end

    test "rejects a compute-unit price ceiling breach when fee paying", context do
      %{
        charge: charge,
        payer: payer,
        payer_seed: payer_seed,
        recipient: recipient,
        fee_payer: fee_payer
      } = context

      ixs = [
        %Instruction{program_id: Programs.compute_budget_program(), accounts: [], data: <<3, 9_000_000::little-64>>},
        SystemProgram.transfer(payer, recipient, @amount)
      ]

      message = Transaction.build_message(fee_payer, ixs, @blockhash)
      tx = Transaction.sign_partial(message, %{1 => payer_seed})

      assert {:error, %Errors{} = error} =
               Instructions.verify_compiled(tx, charge, %{
                 fee_payer: true,
                 fee_payer_pubkey: fee_payer,
                 max_compute_unit_price: 1_000
               })

      assert error.detail =~ "Compute unit price"
    end

    test "rejects a plain SPL transfer that is not transferChecked", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      ix = TokenProgram.transfer(source_ata, dest_ata, payer, 1)
      message = Transaction.build_message(payer, [ix], @blockhash)
      tx = Transaction.sign(message, [seed])
      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))
      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "unexpected"
    end

    test "rejects ATA creation for an unauthorized owner", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      {stranger, _} = Keys.generate_keypair()
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)

      ixs = [
        ATA.create_idempotent(payer, stranger, mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))
      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "authorized split"
    end

    test "rejects ATA creation funded by someone other than the fee payer", context do
      %{payer: payer, payer_seed: payer_seed, recipient: recipient, fee_payer: fee_payer} = context
      {split_owner, _} = Keys.generate_keypair()
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      {split_ata, _} = ATA.find_address(split_owner, mint)

      ixs = [
        ATA.create_idempotent(payer, split_owner, mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 9_000, 6),
        TokenProgram.transfer_checked(source_ata, mint, split_ata, payer, 1_000, 6)
      ]

      message = Transaction.build_message(fee_payer, ixs, @blockhash)
      tx = Transaction.sign_partial(message, %{1 => payer_seed})

      {:ok, charge} = Charge.new(amount: "10000", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      charge = %{
        charge
        | method_details: %{
            "splits" => [
              %{"recipient" => Keys.to_address(split_owner), "amount" => "1000", "ataCreationRequired" => true}
            ]
          }
      }

      assert {:error, %Errors{} = error} =
               Instructions.verify_compiled(tx, charge, %{fee_payer: true, fee_payer_pubkey: fee_payer})

      assert error.detail =~ "fee payer"
    end

    test "rejects ATA creation for the wrong mint", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      other_mint = <<3::256>>
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      {split_owner, _} = Keys.generate_keypair()

      {split_ata, _} = ATA.find_address(split_owner, mint)

      ixs = [
        ATA.create_idempotent(payer, split_owner, other_mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 9_000, 6),
        TokenProgram.transfer_checked(source_ata, mint, split_ata, payer, 1_000, 6)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])
      {:ok, charge} = Charge.new(amount: "10000", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      charge = %{
        charge
        | method_details: %{
            "splits" => [
              %{"recipient" => Keys.to_address(split_owner), "amount" => "1000", "ataCreationRequired" => true}
            ]
          }
      }

      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "mint"
    end

    test "rejects a transferChecked with too few accounts by classifying it unknown", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      ix = TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6)
      message = Transaction.build_message(payer, [ix], @blockhash)
      tx = Transaction.sign(message, [seed])
      [compiled] = tx.message.instructions
      tx = %{tx | message: %{tx.message | instructions: [%{compiled | accounts: [0, 1]}]}}
      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))
      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "unexpected"
    end

    test "rejects non-idempotent ATA creation", context do
      %{payer: payer, payer_seed: seed, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {source_ata, _} = ATA.find_address(payer, mint)
      {dest_ata, _} = ATA.find_address(recipient, mint)

      ixs = [
        ATA.create(payer, recipient, mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 1, 6)
      ]

      message = Transaction.build_message(payer, ixs, @blockhash)
      tx = Transaction.sign(message, [seed])

      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      assert {:error, %Errors{} = error} = Instructions.verify_compiled(tx, charge, %{fee_payer: false})
      assert error.detail =~ "idempotent"
    end
  end

  describe "Instructions.validate_splits_config!/1" do
    test "accepts nil" do
      assert :ok = Instructions.validate_splits_config!(nil)
    end

    test "raises when there are too many splits" do
      splits = for _i <- 1..9, do: %{"recipient" => "x", "amount" => "1"}

      assert_raise ArgumentError, ~r/at most 8/, fn ->
        Instructions.validate_splits_config!(splits)
      end
    end

    test "accepts an integer split amount" do
      {pub, _} = Keys.generate_keypair()
      assert :ok = Instructions.validate_splits_config!([%{"recipient" => Keys.to_address(pub), "amount" => 1}])
    end
  end

  describe "Instructions.verify_parsed/3" do
    test "matches an SPL transfer without a mint opt by decoding the currency", context do
      %{payer: payer, recipient: recipient} = context
      mint = elem(Cartouche.Base58.decode(@usdc_devnet), 1)
      {dest_ata, _} = ATA.find_address(recipient, mint)
      {source_ata, _} = ATA.find_address(payer, mint)

      {:ok, charge} = Charge.new(amount: "1", currency: @usdc_devnet, recipient: Keys.to_address(recipient))

      rpc_tx = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "message" => %{
            "instructions" => [
              %{
                "parsed" => %{
                  "type" => "transferChecked",
                  "info" => %{
                    "authority" => Keys.to_address(payer),
                    "destination" => Keys.to_address(dest_ata),
                    "mint" => @usdc_devnet,
                    "source" => Keys.to_address(source_ata),
                    "tokenAmount" => %{"amount" => "1", "decimals" => 6}
                  }
                },
                "program" => "spl-token",
                "programId" => @token_program
              }
            ]
          }
        }
      }

      assert :ok = Instructions.verify_parsed(rpc_tx, charge, %{fee_payer: false})
    end

    test "treats non-integer parsed amounts as a non-match", context do
      %{payer: payer, recipient: recipient} = context
      {:ok, charge} = Charge.new(amount: "10", currency: "sol", recipient: Keys.to_address(recipient))

      rpc_tx = %{
        "meta" => %{"err" => nil},
        "transaction" => %{
          "message" => %{
            "instructions" => [
              %{
                "program" => "system",
                "programId" => "11111111111111111111111111111111",
                "parsed" => %{
                  "type" => "transfer",
                  "info" => %{
                    "source" => Keys.to_address(payer),
                    "destination" => Keys.to_address(recipient),
                    "lamports" => "nope"
                  }
                }
              }
            ]
          }
        }
      }

      assert {:error, %Errors{}} = Instructions.verify_parsed(rpc_tx, charge, %{fee_payer: false})
    end
  end

  defp with_store(charge, store) do
    %{charge | method_details: Map.put(charge.method_details, "store", store)}
  end

  defp fake_signature do
    Cartouche.Base58.encode(:crypto.strong_rand_bytes(64))
  end

  defp signed_sol_transfer(payer, seed, recipient, amount) do
    ix = SystemProgram.transfer(payer, recipient, amount)
    message = Transaction.build_message(payer, [ix], @blockhash)
    Transaction.sign(message, [seed])
  end

  defp sol_ix(source, destination, lamports) do
    %{
      "program" => "system",
      "programId" => "11111111111111111111111111111111",
      "parsed" => %{
        "type" => "transfer",
        "info" => %{
          "source" => Keys.to_address(source),
          "destination" => Keys.to_address(destination),
          "lamports" => lamports
        }
      }
    }
  end

  defp sol_parsed_tx(signature, source, destination, lamports) do
    %{
      "meta" => %{"err" => nil, "status" => %{"Ok" => nil}},
      "transaction" => %{
        "signatures" => [signature],
        "message" => %{"instructions" => [sol_ix(source, destination, lamports)]}
      }
    }
  end

  defp put_details(charge, extra), do: %{charge | method_details: Map.merge(charge.method_details, extra)}

  defp memo_parsed_tx(signature, source, destination, memo) do
    signature
    |> sol_parsed_tx(source, destination, @amount)
    |> update_in(["transaction", "message", "instructions"], fn instructions ->
      instructions ++
        [
          %{
            "parsed" => memo,
            "program" => "spl-memo",
            "programId" => "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr",
            "stackHeight" => nil
          }
        ]
    end)
  end

  defp push_plug_config(recipient, expires_in) do
    PaymentPlug.init(
      secret_key: "hmac-secret-for-solana-push-binding",
      realm: "api.example.com",
      method: Solana,
      amount: Integer.to_string(@amount),
      currency: "sol",
      recipient: Keys.to_address(recipient),
      expires_in: expires_in,
      method_config: %{
        "rpc_url" => @rpc_url,
        "network" => "devnet",
        "req_options" => [plug: {Req.Test, Solana}],
        "store" => false,
        "push" => "challenge_memo"
      }
    )
  end

  defp memo_pull_tx(payer, seed, recipient, memos) do
    memo_program = elem(Cartouche.Base58.decode("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"), 1)
    memo_ixs = Enum.map(memos, &%Instruction{program_id: memo_program, accounts: [], data: &1})
    transfer = SystemProgram.transfer(payer, recipient, @amount)
    message = Transaction.build_message(payer, [transfer | memo_ixs], @blockhash)
    tx = Transaction.sign(message, [seed])
    {tx, Base.encode64(Transaction.serialize(tx))}
  end

  defp pull_signature(tx), do: Cartouche.Base58.encode(hd(tx.signatures))

  defp issue_challenge(config, path) do
    conn = :get |> Plug.Test.conn(path) |> PaymentPlug.call(config)
    assert conn.status == 402
    [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    {:ok, challenge} = Headers.parse_challenge(header)
    challenge
  end

  defp present_signature(config, challenge, signature) do
    credential = %MPP.Credential{
      challenge: challenge,
      payload: %{"type" => "signature", "signature" => signature}
    }

    :get
    |> Plug.Test.conn("/a")
    |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
    |> PaymentPlug.call(config)
  end

  defp stub_get_transaction(result) do
    Req.Test.stub(Solana, fn conn ->
      rpc_dispatch(conn, %{"getTransaction" => result})
    end)
  end

  defp stub_pull_success(signature, parsed) do
    Req.Test.stub(Solana, fn conn ->
      rpc_dispatch(conn, %{
        "simulateTransaction" => %{"err" => nil, "logs" => ["ok"], "unitsConsumed" => 500},
        "sendTransaction" => signature,
        "getSignatureStatuses" => [
          %{
            "slot" => 1,
            "confirmations" => 1,
            "err" => nil,
            "confirmationStatus" => "confirmed"
          }
        ],
        "getTransaction" => parsed
      })
    end)
  end

  defp read_request(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    {request["method"], request["id"], conn}
  end

  defp rpc_json(conn, id, key, value) do
    Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, key => value})
  end

  defp pull_results(signature, parsed) do
    %{
      "simulateTransaction" => %{"err" => nil, "logs" => ["ok"], "unitsConsumed" => 500},
      "sendTransaction" => signature,
      "getSignatureStatuses" => [
        %{"slot" => 1, "confirmations" => 1, "err" => nil, "confirmationStatus" => "confirmed"}
      ],
      "getTransaction" => parsed
    }
  end

  defp stub_simulation_fails_once(signature, parsed) do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Solana, fn conn ->
      {method, id, conn} = read_request(conn)
      results = pull_results(signature, parsed)

      if method == "simulateTransaction" and Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        rpc_json(conn, id, "result", %{"err" => %{"InstructionError" => [0, "Custom"]}, "logs" => []})
      else
        rpc_json(conn, id, "result", Map.fetch!(results, method))
      end
    end)
  end

  defp rpc_dispatch(conn, results_by_method) do
    {method, id, conn} = read_request(conn)
    rpc_json(conn, id, "result", Map.fetch!(results_by_method, method))
  end
end
