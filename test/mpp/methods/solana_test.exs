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
          "store" => false
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
    test "accepts transaction and signature" do
      assert Solana.credential_types() == ["transaction", "signature"]
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

    test "raises on confidential transfers" do
      assert_raise ArgumentError, ~r/confidential/, fn ->
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
      assert request["methodDetails"]["credentialTypes"] == ["transaction", "signature"]
      assert request["methodDetails"]["feePayer"] == false
      refute Map.has_key?(request["methodDetails"], "rpc_url")
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
            "store" => false
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

      assert error.detail =~ "ATA creation is not allowed"
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
            "store" => false
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

      ixs = [
        ATA.create_idempotent(payer, split_owner, other_mint),
        TokenProgram.transfer_checked(source_ata, mint, dest_ata, payer, 9_000, 6),
        TokenProgram.transfer_checked(source_ata, mint, split_owner |> ATA.find_address(mint) |> elem(0), payer, 1_000, 6)
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

    test "max_splits is 8" do
      assert Instructions.max_splits() == 8
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

  defp rpc_dispatch(conn, results_by_method) do
    {method, id, conn} = read_request(conn)
    rpc_json(conn, id, "result", Map.fetch!(results_by_method, method))
  end
end
