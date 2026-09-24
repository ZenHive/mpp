defmodule MPP.Methods.USDCIntegrationTest do
  @moduledoc """
  Live direct USDC charges.

  EVM uses Ethereum Sepolia Circle USDC. Solana uses the Circle devnet mint.
  Missing credentials or an unfunded account fail the test with the exact
  exports and faucet URLs. Mocks are not a substitute for these cases.

  Run with:

      mix test test/mpp/methods/usdc_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias Cartouche.Solana.ATA
  alias Cartouche.Solana.Keys
  alias Cartouche.Solana.RPC
  alias Cartouche.Solana.TokenProgram
  alias Cartouche.Solana.Transaction
  alias MPP.Intents.Charge
  alias MPP.Methods.USDC
  alias MPP.Methods.USDC.Binding
  alias MPP.Receipt
  alias MPP.Test.EVMAuthorization
  alias Onchain.Address

  @moduletag :integration
  @moduletag timeout: 180_000

  @sepolia_chain 11_155_111
  @sepolia_usdc "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @devnet_usdc "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  @token_program "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  @realm "usdc-integration.example.com"
  @devnet_caip "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"

  describe "ethereum sepolia" do
    setup do
      rpc_url = System.get_env("ETH_SEPOLIA_RPC_URL") || System.get_env("EVM_RPC_URL")
      private_key = System.get_env("ETH_SEPOLIA_PRIVATE_KEY") || System.get_env("EVM_PRIVATE_KEY")

      if is_nil(rpc_url) or is_nil(private_key) do
        flunk("""
        Missing EVM testnet credentials for the USDC charge profile.

        Set these environment variables:
          export ETH_SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
          export ETH_SEPOLIA_PRIVATE_KEY="0x<your-funded-sepolia-private-key>"

        Get Sepolia USDC from Circle's faucet:
          https://faucet.circle.com/

        Then run:
          mix test test/mpp/methods/usdc_integration_test.exs --include integration
        """)
      end

      {:ok, sender} = Onchain.Signer.address_from_key(private_key)
      {:ok, from_bin} = Address.validate(sender)

      {:ok, [balance]} =
        Onchain.Contract.call(@sepolia_usdc, "balanceOf(address)", [from_bin], "(uint256)", rpc_url: rpc_url)

      {:ok, recipient} = Onchain.Signer.address_from_key(EVMAuthorization.private_key())

      {:ok, rpc_url: rpc_url, private_key: private_key, sender: sender, recipient: recipient, balance: balance}
    end

    test "Circle USDC rejects an authorization larger than the payer balance", context do
      if context.balance < 1, do: flunk_sepolia_balance(context)
      amount = Integer.to_string(context.balance + 1)
      charge = evm_charge(context, amount)
      payload = evm_payload(charge, context)

      assert {:error, error} = USDC.verify(payload, charge)
      assert error.detail == "ERC20: transfer amount exceeds balance" or error.detail =~ "exceeds balance"
    end

    test "settles one base unit and returns the USDC receipt", context do
      if context.balance < 1, do: flunk_sepolia_balance(context)

      charge = evm_charge(context, "1")
      payload = evm_payload(charge, context)

      assert {:ok, %Receipt{} = receipt} = USDC.verify(payload, charge)
      assert receipt.method == "usdc"
      assert receipt.status == "success"
      assert receipt.extensions["type"] == "evm"
      assert receipt.extensions["network"] == "eip155:#{@sepolia_chain}"
      assert receipt.reference =~ ~r/^0x[0-9a-f]{64}$/
      assert receipt.external_id == "invoice-evm-live"
    end
  end

  describe "solana devnet" do
    setup do
      rpc_url = System.get_env("SOLANA_RPC_URL") || System.get_env("SOLANA_DEVNET_RPC_URL")
      private_key = System.get_env("SOLANA_PRIVATE_KEY")

      if is_nil(rpc_url) or is_nil(private_key) do
        flunk("""
        Missing Solana devnet credentials for the USDC charge profile.

        Set these environment variables:
          export SOLANA_RPC_URL="https://api.devnet.solana.com"
          export SOLANA_PRIVATE_KEY="<hex seed, base58 seed, or Solana CLI JSON keypair>"

        Fund SOL at https://faucet.solana.com and devnet USDC at https://faucet.circle.com/
        (Solana Devnet, mint #{@devnet_usdc}). Then run:
          mix test test/mpp/methods/usdc_integration_test.exs --include integration
        """)
      end

      seed = decode_seed!(private_key)
      {payer, ^seed} = Keys.from_seed(seed)
      rpc_opts = [solana_node: rpc_url, commitment: :confirmed, preflight_commitment: :confirmed]

      case RPC.send_rpc("getGenesisHash", [], rpc_opts) do
        {:ok, hash} ->
          caip = "solana:" <> String.slice(hash, 0, 32)

          if caip != @devnet_caip do
            flunk("""
            SOLANA_RPC_URL is not Solana devnet.

            getGenesisHash returned #{hash}, CAIP-2 #{caip}.
            The USDC devnet profile expects #{@devnet_caip}.
            export SOLANA_RPC_URL="https://api.devnet.solana.com"
            """)
          end

        {:error, reason} ->
          flunk("Solana getGenesisHash failed: #{inspect(reason)}")
      end

      mint_key =
        case Cartouche.Base58.decode(@devnet_usdc) do
          {:ok, <<key::binary-32>>} -> key
          other -> flunk("devnet USDC mint did not decode: #{inspect(other)}")
        end

      {source, _} = ATA.find_address(payer, mint_key)
      balance = token_amount(source, rpc_opts)

      {:ok, rpc_url: rpc_url, rpc_opts: rpc_opts, payer: payer, seed: seed, balance: balance, mint: mint_key}
    end

    test "simulation rejects a transfer larger than the token balance", context do
      if context.balance < 1, do: flunk_solana_balance(context)
      {recipient, _} = Keys.generate_keypair()
      ensure_destination!(context, recipient)
      amount = context.balance + 1
      charge = solana_charge(context, recipient, amount)
      payload = solana_payload(context, recipient, amount)

      assert {:error, error} = USDC.verify(payload, charge)
      assert error.detail =~ "simulation" or error.detail =~ "insufficient" or error.detail =~ "amount"
    end

    test "settles one base unit and returns the USDC receipt", context do
      if context.balance < 1, do: flunk_solana_balance(context)

      {recipient, _} = Keys.generate_keypair()
      ensure_destination!(context, recipient)
      charge = solana_charge(context, recipient, 1)
      payload = solana_payload(context, recipient, 1)

      assert {:ok, %Receipt{} = receipt} = USDC.verify(payload, charge)
      assert receipt.method == "usdc"
      assert receipt.status == "success"
      assert receipt.extensions["type"] == "solana"
      assert receipt.extensions["network"] == @devnet_caip
      assert {:ok, <<_::binary-64>>} = Cartouche.Base58.decode(receipt.reference)
      assert receipt.external_id == "invoice-sol-live"
    end
  end

  defp flunk_sepolia_balance(context) do
    flunk("""
    Missing Sepolia USDC for the USDC charge profile.

    Account #{context.sender} has #{context.balance} base units on #{@sepolia_usdc}.

    Get Sepolia USDC from Circle's faucet:
      https://faucet.circle.com/

    Request USDC on Ethereum Sepolia for #{context.sender}, then rerun:
      mix test test/mpp/methods/usdc_integration_test.exs --include integration
    """)
  end

  defp flunk_solana_balance(context) do
    flunk("""
    Missing Solana devnet USDC for the USDC charge profile.

    Payer #{Keys.to_address(context.payer)} has #{context.balance} base units of #{@devnet_usdc}.

    Get devnet USDC from Circle's faucet:
      https://faucet.circle.com/

    Request USDC on Solana Devnet for #{Keys.to_address(context.payer)}, then rerun:
      mix test test/mpp/methods/usdc_integration_test.exs --include integration
    """)
  end

  defp evm_charge(context, amount) do
    challenge_id = "usdc-live-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    %Charge{
      amount: amount,
      currency: @sepolia_usdc,
      recipient: context.recipient,
      external_id: "invoice-evm-live",
      method_details: %{
        "profile" => "evm",
        "type" => "evm",
        "evm" => %{"chainId" => @sepolia_chain, "credentialTypes" => ["authorization"], "decimals" => 6},
        "rpc_url" => context.rpc_url,
        "chain_id" => @sepolia_chain,
        "private_key" => context.private_key,
        "challenge_id" => challenge_id,
        "realm" => @realm,
        "store" => false,
        "max_fee_per_gas" => 2_000_000_000,
        "max_priority_fee_per_gas" => 1_000_000_000
      }
    }
  end

  defp evm_payload(charge, context) do
    {:ok, request} = Binding.public_request(charge)
    nonce = Binding.authorization_nonce(charge.method_details["challenge_id"], @realm, request)

    EVMAuthorization.payload(%{
      currency: @sepolia_usdc,
      name: "USDC",
      version: "2",
      chain_id: @sepolia_chain,
      from: context.sender,
      recipient: context.recipient,
      amount: charge.amount,
      challenge_id: charge.method_details["challenge_id"],
      realm: @realm,
      nonce: nonce,
      private_key: context.private_key
    })
  end

  defp solana_charge(context, recipient, amount) do
    challenge_id = "usdc-sol-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    %Charge{
      amount: Integer.to_string(amount),
      currency: @devnet_usdc,
      recipient: Keys.to_address(recipient),
      external_id: "invoice-sol-live",
      method_details: %{
        "profile" => "solana",
        "type" => "solana",
        "solana" => %{"network" => "devnet", "decimals" => 6, "tokenProgram" => @token_program},
        "rpc_url" => context.rpc_url,
        "network" => "devnet",
        "challenge_id" => challenge_id,
        "realm" => @realm,
        "store" => false
      }
    }
  end

  defp solana_payload(context, recipient, amount) do
    {source, _} = ATA.find_address(context.payer, context.mint)
    {dest, _} = ATA.find_address(recipient, context.mint)
    transfer = TokenProgram.transfer_checked(source, context.mint, dest, context.payer, amount, 6)
    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)
    message = Transaction.build_message(context.payer, [transfer], blockhash)
    tx = Transaction.sign(message, [context.seed])
    %{"type" => "transaction", "transaction" => Base.encode64(Transaction.serialize(tx))}
  end

  defp ensure_destination!(context, recipient) do
    create = ATA.create_idempotent(context.payer, recipient, context.mint)
    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)
    message = Transaction.build_message(context.payer, [create], blockhash)
    tx = Transaction.sign(message, [context.seed])

    case RPC.send_and_confirm(tx, Keyword.put(context.rpc_opts, :timeout, 30_000)) do
      {:ok, _signature} -> :ok
      {:error, reason} -> flunk("Could not create the recipient USDC account: #{inspect(reason)}")
    end
  end

  defp token_amount(source, rpc_opts) do
    case RPC.get_account_info(source, Keyword.put(rpc_opts, :encoding, :base64)) do
      {:ok, %{data: [encoded, "base64"]}} ->
        {:ok, data} = Base.decode64(encoded)
        <<_mint::binary-32, _owner::binary-32, amount::little-unsigned-64, _rest::binary>> = data
        amount

      {:ok, nil} ->
        0

      other ->
        flunk("Unable to read the payer USDC token account: #{inspect(other)}")
    end
  end

  defp decode_seed!(key) do
    trimmed = String.trim(key)

    cond do
      String.starts_with?(trimmed, "[") -> decode_json_seed!(trimmed)
      hex_seed?(trimmed) -> decode_hex_seed!(trimmed)
      true -> decode_base58_seed!(trimmed)
    end
  end

  defp decode_json_seed!(trimmed) do
    case Keys.from_json(trimmed) do
      {:ok, {_pub, seed}} -> seed
      {:error, reason} -> flunk("SOLANA_PRIVATE_KEY JSON keypair is invalid: #{inspect(reason)}")
    end
  end

  defp decode_hex_seed!(trimmed) do
    hex = String.replace_prefix(trimmed, "0x", "")

    case Base.decode16(hex, case: :mixed) do
      {:ok, <<seed::binary-32>>} -> seed
      {:ok, <<seed::binary-32, _pub::binary-32>>} -> seed
      _other -> flunk("SOLANA_PRIVATE_KEY hex seed is not 32 or 64 bytes")
    end
  end

  defp decode_base58_seed!(trimmed) do
    case Cartouche.Base58.decode(trimmed) do
      {:ok, <<seed::binary-32>>} -> seed
      {:ok, <<seed::binary-32, _pub::binary-32>>} -> seed
      other -> flunk("SOLANA_PRIVATE_KEY is not a valid hex, base58, or JSON key: #{inspect(other)}")
    end
  end

  defp hex_seed?(trimmed) do
    hex = String.replace_prefix(trimmed, "0x", "")
    Regex.match?(~r/\A[0-9a-fA-F]+\z/, hex) and byte_size(hex) in [64, 128]
  end
end
