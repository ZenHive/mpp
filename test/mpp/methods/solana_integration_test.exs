defmodule MPP.Methods.SolanaIntegrationTest do
  @moduledoc """
  Integration tests for the Solana payment method against a live cluster.

  Requires two environment variables:
    * `SOLANA_RPC_URL` (or `SOLANA_DEVNET_RPC_URL`) — JSON-RPC endpoint
    * `SOLANA_PRIVATE_KEY` — funded Ed25519 seed as hex, base58, or Solana CLI JSON

  Run with: `mix test test/mpp/methods/solana_integration_test.exs --include integration`
  """

  use ExUnit.Case, async: false

  alias Cartouche.Solana.Keys
  alias Cartouche.Solana.RPC
  alias Cartouche.Solana.SystemProgram
  alias Cartouche.Solana.Transaction
  alias MPP.Intents.Charge
  alias MPP.Methods.Solana
  alias MPP.Receipt

  @moduletag :integration

  @lamports 1_000
  @airdrop_lamports 1_000_000_000
  @confirmation_timeout_ms 30_000

  setup_all do
    rpc_url = System.get_env("SOLANA_RPC_URL") || System.get_env("SOLANA_DEVNET_RPC_URL")
    private_key = System.get_env("SOLANA_PRIVATE_KEY")

    if is_nil(rpc_url) or is_nil(private_key) do
      flunk("""
      Missing Solana testnet credentials!

      Set these environment variables:
        export SOLANA_RPC_URL="https://api.devnet.solana.com"
        export SOLANA_PRIVATE_KEY="<hex seed, base58 seed, or Solana CLI JSON keypair>"

      Fund the key on Solana devnet (https://faucet.solana.com) so it can pay
      transaction fees and a 1000-lamport transfer. Then run:
        mix test test/mpp/methods/solana_integration_test.exs --include integration
      """)
    end

    seed = decode_seed!(private_key)
    {payer, ^seed} = Keys.from_seed(seed)
    rpc_opts = [solana_node: rpc_url, commitment: :confirmed]

    ensure_funded!(payer, rpc_opts)

    {recipient, _} = Keys.generate_keypair()
    {fee_payer, fee_payer_seed} = Keys.generate_keypair()

    {:ok,
     rpc_url: rpc_url,
     rpc_opts: rpc_opts,
     payer: payer,
     payer_seed: seed,
     recipient: recipient,
     fee_payer: fee_payer,
     fee_payer_seed: fee_payer_seed}
  end

  test "pull mode broadcasts a signed SOL transfer and confirms it", context do
    charge = sol_charge(context, context.recipient)
    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)

    ix = SystemProgram.transfer(context.payer, context.recipient, @lamports)
    message = Transaction.build_message(context.payer, [ix], blockhash)
    tx = Transaction.sign(message, [context.payer_seed])
    encoded = Base.encode64(Transaction.serialize(tx))

    assert {:ok, %Receipt{} = receipt} =
             Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

    assert receipt.method == "solana"
    assert is_binary(receipt.reference)
    assert {:ok, <<_::binary-64>>} = Cartouche.Base58.decode(receipt.reference)
  end

  test "push mode verifies a confirmed SOL transfer signature", context do
    {recipient, _} = Keys.generate_keypair()
    charge = sol_charge(context, recipient)
    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)

    ix = SystemProgram.transfer(context.payer, recipient, @lamports)
    message = Transaction.build_message(context.payer, [ix], blockhash)
    tx = Transaction.sign(message, [context.payer_seed])

    assert {:ok, signature} =
             RPC.send_and_confirm(tx, Keyword.put(context.rpc_opts, :timeout, @confirmation_timeout_ms))

    assert {:ok, %Receipt{} = receipt} =
             Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

    assert receipt.reference == signature
  end

  test "push mode rejects a confirmed transfer to the wrong recipient", context do
    {wrong, _} = Keys.generate_keypair()
    {expected, _} = Keys.generate_keypair()
    charge = sol_charge(context, expected)
    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)

    ix = SystemProgram.transfer(context.payer, wrong, @lamports)
    message = Transaction.build_message(context.payer, [ix], blockhash)
    tx = Transaction.sign(message, [context.payer_seed])

    assert {:ok, signature} =
             RPC.send_and_confirm(tx, Keyword.put(context.rpc_opts, :timeout, @confirmation_timeout_ms))

    assert {:error, %MPP.Errors{} = error} =
             Solana.verify(%{"type" => "signature", "signature" => signature}, charge)

    assert error.detail =~ "No matching transfer"
  end

  test "pull mode co-signs as fee payer", context do
    {recipient, _} = Keys.generate_keypair()
    fund_fee_payer!(context)

    charge =
      context
      |> sol_charge(recipient)
      |> put_fee_payer(context)

    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)
    ix = SystemProgram.transfer(context.payer, recipient, @lamports)
    message = Transaction.build_message(context.fee_payer, [ix], blockhash)
    partial = Transaction.sign_partial(message, %{1 => context.payer_seed})
    encoded = Base.encode64(Transaction.serialize(partial))

    assert {:ok, %Receipt{} = receipt} =
             Solana.verify(%{"type" => "transaction", "transaction" => encoded}, charge)

    assert is_binary(receipt.reference)
  end

  defp sol_charge(context, recipient) do
    {:ok, charge} =
      Charge.new(
        amount: Integer.to_string(@lamports),
        currency: "sol",
        recipient: Keys.to_address(recipient)
      )

    %{
      charge
      | method_details: %{
          "rpc_url" => context.rpc_url,
          "network" => "devnet",
          "store" => false
        }
    }
  end

  defp put_fee_payer(charge, context) do
    %{
      charge
      | method_details:
          Map.merge(charge.method_details, %{
            "fee_payer" => true,
            "fee_payer_private_key" => Base.encode16(context.fee_payer_seed, case: :lower)
          })
    }
  end

  defp fund_fee_payer!(context) do
    {:ok, %{blockhash: blockhash}} = RPC.get_latest_blockhash(context.rpc_opts)
    ix = SystemProgram.transfer(context.payer, context.fee_payer, 100_000)
    message = Transaction.build_message(context.payer, [ix], blockhash)
    tx = Transaction.sign(message, [context.payer_seed])

    case RPC.send_and_confirm(tx, Keyword.put(context.rpc_opts, :timeout, @confirmation_timeout_ms)) do
      {:ok, _sig} ->
        :ok

      {:error, reason} ->
        flunk("Failed to fund fee-payer account for pull-mode co-sign: #{inspect(reason)}")
    end
  end

  defp ensure_funded!(payer, rpc_opts) do
    case RPC.get_balance(payer, rpc_opts) do
      {:ok, balance} when is_integer(balance) and balance > @lamports * 10 ->
        :ok

      {:ok, _low} ->
        request_airdrop_or_flunk!(payer, rpc_opts)

      {:error, reason} ->
        flunk("Solana getBalance failed: #{inspect(reason)}")
    end
  end

  defp request_airdrop_or_flunk!(payer, rpc_opts) do
    case RPC.request_airdrop(payer, @airdrop_lamports, rpc_opts) do
      {:ok, signature} ->
        wait_for_airdrop!(payer, rpc_opts, signature)

      {:error, reason} ->
        flunk("""
        Payer account #{Keys.to_address(payer)} is unfunded and requestAirdrop failed:
          #{inspect(reason)}

        Fund it at https://faucet.solana.com and retry.
        """)
    end
  end

  defp wait_for_airdrop!(payer, rpc_opts, _airdrop_signature) do
    1..20
    |> Enum.reduce_while(:error, fn _i, _acc ->
      Process.sleep(1_500)

      case RPC.get_balance(payer, rpc_opts) do
        {:ok, balance} when is_integer(balance) and balance > 0 -> {:halt, :ok}
        _other -> {:cont, :error}
      end
    end)
    |> case do
      :ok ->
        :ok

      :error ->
        flunk("Airdrop submitted but payer #{Keys.to_address(payer)} still has zero balance")
    end
  end

  defp decode_seed!(key) do
    trimmed = String.trim(key)

    cond do
      String.starts_with?(trimmed, "[") ->
        case Keys.from_json(trimmed) do
          {:ok, {_pub, seed}} -> seed
          {:error, reason} -> flunk("SOLANA_PRIVATE_KEY JSON keypair is invalid: #{inspect(reason)}")
        end

      hex_seed?(trimmed) ->
        decode_hex_seed!(trimmed)

      true ->
        case Cartouche.Base58.decode(trimmed) do
          {:ok, <<seed::binary-32>>} -> seed
          {:ok, <<seed::binary-32, _pub::binary-32>>} -> seed
          other -> flunk("SOLANA_PRIVATE_KEY is not a valid hex, base58, or JSON key: #{inspect(other)}")
        end
    end
  end

  defp hex_seed?(value) do
    hex = String.replace_prefix(value, "0x", "")
    Regex.match?(~r/\A[0-9a-fA-F]+\z/, hex) and byte_size(hex) in [64, 128]
  end

  defp decode_hex_seed!(value) do
    hex = String.replace_prefix(value, "0x", "")

    case Base.decode16(hex, case: :mixed) do
      {:ok, <<seed::binary-32>>} -> seed
      {:ok, <<seed::binary-32, _pub::binary-32>>} -> seed
      _other -> flunk("SOLANA_PRIVATE_KEY hex seed is not 32 or 64 bytes")
    end
  end
end
