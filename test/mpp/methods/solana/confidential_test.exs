defmodule MPP.Methods.Solana.ConfidentialTest do
  use ExUnit.Case, async: true
  use Cartouche.Base58

  import Bitwise

  alias Cartouche.Solana.ATA
  alias Cartouche.Solana.Keys
  alias Cartouche.Solana.Programs
  alias Cartouche.Solana.SystemProgram
  alias Cartouche.Solana.Transaction
  alias Cartouche.Solana.Transaction.AccountMeta
  alias Cartouche.Solana.Transaction.Instruction
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Solana
  alias MPP.Methods.Solana.Confidential

  @rpc_url "https://api.devnet.solana.com"
  @token_2022_address "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
  @zk_proof_program ~B58[ZkE1Gama1Proof11111111111111111111111111111]
  @record_program ~B58[recr1L3PCGKLbckBqMNcJhuuyU1zgo8nBhfLVsJNwr5]
  @memo_program ~B58[MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr]
  @identity <<0::256>>
  @secret Base.encode64(<<7, 0::248>>)
  @low_ciphertext Base.decode16!(
                    "64990C6B35B06D4E83E462C37FEF71D011F277FDF79C224AB090DA880BF04A3A" <>
                      "BCE83F8BA5DD2FA572864C24BA1810F9522BC6004AFE95877AC73241CAFDAB42"
                  )
  @high_ciphertext Base.decode16!(
                     "EE18C589200482746187ED656F08142EFABEBC2E899861E88AD9B79DEC773A0BA" <>
                       "A52E000DF2E16F55FB1032FC33BC42742DAD6BD5A8FC0BE0167436C5948501F"
                   )

  setup do
    {payer, payer_seed} = Keys.generate_keypair()
    {source, source_seed} = Keys.generate_keypair()
    {recipient, _recipient_seed} = Keys.generate_keypair()
    {mint, _mint_seed} = Keys.generate_keypair()
    context_keypairs = for _index <- 1..3, do: Keys.generate_keypair()
    contexts = Enum.map(context_keypairs, &elem(&1, 0))

    {:ok, charge} =
      Charge.new(
        amount: "65539",
        currency: Keys.to_address(mint),
        recipient: Keys.to_address(recipient)
      )

    config = %{
      "rpc_url" => @rpc_url,
      "network" => "devnet",
      "decimals" => 6,
      "token_program" => @token_2022_address,
      "confidential" => true,
      "recipient_elgamal_secret_key" => @secret,
      "store" => false
    }

    {:ok,
     payer: payer,
     payer_seed: payer_seed,
     source: source,
     source_seed: source_seed,
     recipient: recipient,
     mint: mint,
     contexts: contexts,
     context_seeds: Map.new(context_keypairs),
     charge: %{charge | method_details: config},
     config: config}
  end

  describe "confidential challenge validation" do
    test "accepts Token-2022 config and advertises only bundle", %{charge: charge, config: config} do
      assert :ok = Solana.validate_config!(config)
      details = Solana.challenge_method_details(charge)

      assert details["credentialTypes"] == ["bundle"]
      assert details["tokenProgram"] == @token_2022_address
      assert details["confidential"] == true
      refute Map.has_key?(details, "recipient_elgamal_secret_key")
    end

    test "rejects confidential with splits", %{config: config} do
      assert_raise ArgumentError, ~r/do not allow splits/, fn ->
        Solana.validate_config!(Map.put(config, "splits", []))
      end
    end

    test "rejects confidential with the legacy token program", %{config: config} do
      legacy = Cartouche.Base58.encode(Programs.token_program())

      assert_raise ArgumentError, ~r/require token_program/, fn ->
        Solana.validate_config!(Map.put(config, "token_program", legacy))
      end
    end

    test "rejects confidential without a recipient ElGamal secret", %{config: config} do
      assert_raise ArgumentError, ~r/recipient_elgamal_secret_key/, fn ->
        config |> Map.delete("recipient_elgamal_secret_key") |> Solana.validate_config!()
      end
    end

    test "rejects confidential SOL challenges", %{charge: charge} do
      assert_raise ArgumentError, ~r/not SOL/, fn ->
        Solana.challenge_method_details(%{charge | currency: "sol"})
      end
    end

    test "rejects invalid max_bundle_transactions", %{config: config} do
      assert_raise ArgumentError, ~r/max_bundle_transactions/, fn ->
        Solana.validate_config!(Map.put(config, "max_bundle_transactions", 0))
      end
    end
  end

  describe "credential profile selection" do
    test "rejects ordinary credentials for confidential challenges", %{charge: charge} do
      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "signature", "signature" => "unused"}, charge)

      assert error.detail =~ ~s(type="bundle" is required)
    end

    test "rejects bundle credentials for ordinary challenges", %{charge: charge} do
      charge = %{charge | method_details: Map.delete(charge.method_details, "confidential")}
      assert {:error, %Errors{} = error} = Solana.verify(%{"type" => "bundle", "transactions" => []}, charge)
      assert error.detail =~ "allowed only"
    end

    test "rejects an empty confidential bundle", %{charge: charge} do
      assert {:error, %Errors{} = error} = Solana.verify(%{"type" => "bundle", "transactions" => []}, charge)
      assert error.detail =~ "transactions"
    end

    test "validates a signed bundle before an observed absent-account response", context do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        assert request["method"] == "getAccountInfo"

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "result" => %{
            "context" => %{"apiVersion" => "4.2.0", "slot" => 485_367_653},
            "value" => nil
          },
          "id" => request["id"]
        })
      end)

      charge = %{
        context.charge
        | method_details:
            Map.put(
              context.charge.method_details,
              "req_options",
              plug: {Req.Test, __MODULE__}
            )
      }

      payload = %{
        "type" => "bundle",
        "transactions" => Enum.map(signed_bundle(context), &(&1 |> Transaction.serialize() |> Base.encode64()))
      }

      assert {:error, %Errors{} = error} = Solana.verify(payload, charge)
      assert error.detail == "Recipient confidential token account was not found"
    end

    test "rejects malformed transaction elements", %{charge: charge} do
      assert {:error, %Errors{} = error} =
               Solana.verify(%{"type" => "bundle", "transactions" => ["not base64"]}, charge)

      assert error.detail == "Transaction is not valid base64"
    end
  end

  describe "verify_bundle/3" do
    test "accepts ordered proof setup, transfer, and close transactions", context do
      transactions = valid_bundle(context)
      assert :ok = Confidential.verify_bundle(transactions, context.charge, 8)
    end

    test "accepts confidential TransferWithFee with five contexts", context do
      contexts = for _index <- 1..5, do: elem(Keys.generate_keypair(), 0)
      context = %{context | contexts: contexts}
      [setup, transfer] = valid_bundle(context, 13)
      assert :ok = Confidential.verify_bundle([setup, transfer], context.charge, 8)
    end

    test "rejects a transfer before proof context setup", context do
      [setup, transfer] = valid_bundle(context)
      assert {:error, %Errors{} = error} = Confidential.verify_bundle([transfer, setup], context.charge, 8)
      assert error.detail =~ "proof contexts"
    end

    test "rejects disallowed Token-2022 instructions", context do
      [setup, transfer] = valid_bundle(context)
      disallowed = compiled_transaction(context.payer, [token_instruction([context.source], <<27, 8>>)])

      assert {:error, %Errors{} = error} =
               Confidential.verify_bundle([setup, disallowed, transfer], context.charge, 8)

      assert error.detail =~ "disallowed Token-2022"
    end

    test "enforces fee-payer compute-budget ceilings", context do
      [setup, transfer] = valid_bundle(context)

      compute =
        instruction(
          Programs.compute_budget_program(),
          [],
          <<3, 1_000_001::little-unsigned-64>>
        )

      setup = compiled_transaction(context.payer, [compute | decompile_instructions(setup)])

      assert {:error, %Errors{} = error} =
               Confidential.verify_bundle(
                 [setup, transfer],
                 context.charge,
                 8,
                 %{fee_payer: true}
               )

      assert error.detail =~ "Compute unit price"
    end

    test "rejects oversized and empty bundles", %{charge: charge} do
      transaction = compiled_transaction(<<1::256>>, [])
      assert {:error, %Errors{}} = Confidential.verify_bundle([], charge, 8)
      assert {:error, %Errors{}} = Confidential.verify_bundle(List.duplicate(transaction, 9), charge, 8)
    end
  end

  describe "recipient balance verification" do
    test "parses a Token-2022 confidential account snapshot" do
      account = account_info(@low_ciphertext, @high_ciphertext)
      assert {:ok, snapshot} = Confidential.parse_snapshot(account)
      assert snapshot.pending_low == split_ciphertext(@low_ciphertext)
      assert snapshot.pending_high == split_ciphertext(@high_ciphertext)
    end

    test "rejects another owner and an unapproved confidential account" do
      assert {:error, %Errors{}} = Confidential.parse_snapshot(%{owner: "other", data: []})

      account = account_info(@low_ciphertext, @high_ciphertext, approved: 0)
      assert {:error, %Errors{}} = Confidential.parse_snapshot(account)
    end

    test "confirms both encrypted pending-balance chunks with the recipient secret" do
      previous = snapshot(@identity <> @identity, @identity <> @identity)
      current = snapshot(@low_ciphertext, @high_ciphertext)

      assert :ok = Confidential.verify_amount(previous, current, "65539", @secret)
      assert {:error, %Errors{}} = Confidential.verify_amount(previous, current, "65540", @secret)
      assert {:error, %Errors{}} = Confidential.verify_amount(previous, current, "65539", Base.encode64(<<8, 0::248>>))
    end

    test "rejects a changed account key and out-of-range amount" do
      previous = snapshot(@identity <> @identity, @identity <> @identity)
      current = %{snapshot(@low_ciphertext, @high_ciphertext) | elgamal_pubkey: <<2::256>>}

      assert {:error, %Errors{}} = Confidential.verify_amount(previous, current, "65539", @secret)
      assert {:error, %Errors{}} = Confidential.verify_amount(previous, previous, Integer.to_string(1 <<< 48), @secret)
    end

    test "requires a successful confirmed final transaction" do
      assert :ok = Confidential.verify_confirmed(%{"meta" => %{"err" => nil}})
      assert :ok = Confidential.verify_confirmed(%{meta: %{err: nil}})
      assert {:error, %Errors{}} = Confidential.verify_confirmed(%{"meta" => %{"err" => "failure"}})
    end
  end

  defp valid_bundle(context, transfer_discriminator \\ 7) do
    setup_instructions =
      Enum.flat_map(context.contexts, fn proof_context ->
        [
          SystemProgram.create_account(context.payer, proof_context, 1, 128, @zk_proof_program),
          proof_instruction(proof_context, context.payer, <<1, 42>>)
        ]
      end)

    {destination, _bump} = ATA.find_address(context.recipient, context.mint, token_program: Programs.token_2022_program())

    transfer_accounts =
      [context.source, context.mint, destination, instructions_sysvar() | context.contexts] ++ [context.source]

    transfer_instructions =
      [token_instruction(transfer_accounts, <<27, transfer_discriminator>>)] ++
        Enum.map(context.contexts, &proof_close_instruction(&1, context.payer))

    [
      compiled_transaction(context.payer, setup_instructions),
      compiled_transaction(context.payer, transfer_instructions)
    ]
  end

  defp signed_bundle(context) do
    signer_seeds =
      Map.merge(context.context_seeds, %{context.payer => context.payer_seed, context.source => context.source_seed})

    context
    |> valid_bundle()
    |> Enum.map(fn transaction ->
      required = transaction.message.header.num_required_signatures

      seeds =
        transaction.message.account_keys
        |> Enum.take(required)
        |> Enum.map(&Map.fetch!(signer_seeds, &1))

      Transaction.sign(transaction.message, seeds)
    end)
  end

  defp proof_instruction(context, owner, data) do
    instruction(@zk_proof_program, [meta(context, false, true), meta(owner, false, false)], data)
  end

  defp proof_close_instruction(context, owner) do
    instruction(
      @zk_proof_program,
      [meta(context, false, true), meta(owner, false, true), meta(owner, true, false)],
      <<0>>
    )
  end

  defp token_instruction(accounts, data) do
    last_index = length(accounts) - 1

    metas =
      accounts
      |> Enum.with_index()
      |> Enum.map(fn {account, index} ->
        meta(account, index == last_index, index in [0, 2])
      end)

    instruction(Programs.token_2022_program(), metas, data)
  end

  defp instruction(program, accounts, data), do: %Instruction{program_id: program, accounts: accounts, data: data}
  defp meta(pubkey, signer, writable), do: %AccountMeta{pubkey: pubkey, is_signer: signer, is_writable: writable}

  defp compiled_transaction(payer, instructions) do
    message = Transaction.build_message(payer, instructions, <<9::256>>)
    %Transaction{message: message, signatures: List.duplicate(<<0::512>>, message.header.num_required_signatures)}
  end

  defp decompile_instructions(%Transaction{message: message}) do
    Enum.map(message.instructions, fn compiled ->
      %Instruction{
        program_id: Enum.at(message.account_keys, compiled.program_id_index),
        accounts:
          Enum.map(compiled.accounts, fn index ->
            meta(Enum.at(message.account_keys, index), false, false)
          end),
        data: compiled.data
      }
    end)
  end

  defp account_info(low, high, opts \\ []) do
    approved = Keyword.get(opts, :approved, 1)
    extension = <<approved, 1::256, low::binary-64, high::binary-64, 0::size(125)-unit(8)>>
    data = <<0::size(165)-unit(8), 2, 5::little-16, byte_size(extension)::little-16, extension::binary>>
    %{owner: @token_2022_address, data: [Base.encode64(data), "base64"]}
  end

  defp snapshot(low, high) do
    %{
      elgamal_pubkey: <<1::256>>,
      pending_low: split_ciphertext(low),
      pending_high: split_ciphertext(high)
    }
  end

  defp split_ciphertext(<<commitment::binary-32, handle::binary-32>>), do: {commitment, handle}

  defp instructions_sysvar do
    ~B58[Sysvar1nstructions1111111111111111111111111]
  end
end
