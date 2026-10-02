defmodule MPP.Methods.TempoMachIntegrationTest do
  @moduledoc """
  Live Moderato pins for MACH charge verification.

  Settlement is a historical push-mode `swapTo` (payer → canonical swapper →
  merchant `TransferWithMemo`). No faucet or private key is required; the
  public Moderato RPC is the credential. A failed RPC call flunks with the
  exact `export` needed to point at another endpoint.
  """

  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo
  alias MPP.Receipt

  @moduletag :integration

  @default_rpc_url "https://rpc.moderato.tempo.xyz"
  @chain_id 42_431

  # Live swapTo calldata and receipt checked on 2026-10-02 (block 33_878_504).
  @tx_hash "0xce5ea421fbc52b6de951c658ca574e9eff4d5601fcdd5526f15b78895629725b"
  @payer "0x65977729bbeaeec090a55db10b04a537fa96e373"
  @merchant "0xa74666cd3aab591a2628e3efa160530ec13f2f15"
  @currency "0x20c00000000000000000000077c462cfbb6d61cf"
  @amount "100000"
  @wrong_source "0x1111111111111111111111111111111111111111"

  setup_all do
    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    ping_machine_token_settlement!(rpc_url, @tx_hash)
    {:ok, rpc_url: rpc_url}
  end

  test "live swapTo input agrees with the charge route ABI", %{rpc_url: rpc_url} do
    assert {:ok, %Req.Response{status: 200, body: %{"result" => tx}}} =
             Req.post(rpc_url,
               json: %{jsonrpc: "2.0", id: 1, method: "eth_getTransactionByHash", params: [@tx_hash]}
             )

    assert tx["from"] == @payer
    assert [%{"to" => swapper, "input" => input}] = tx["calls"]
    assert swapper == "0xd05f8edfbb54da0d765c9fe9b2b3f7d2e3a8c466"

    assert {:ok, [_approve, swap]} =
             MPP.Methods.Tempo.MachineToken.settlement_calls(
               @chain_id,
               @currency,
               @amount,
               @merchant,
               <<0::256>>,
               :mach
             )

    assert input == "0x" <> Base.encode16(swap.input, case: :lower)
  end

  test "verifies a real Moderato MACH push settlement", %{rpc_url: rpc_url} do
    charge = machine_token_charge(rpc_url)

    assert {:ok, %Receipt{} = receipt} =
             Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)

    assert receipt.method == "tempo"
    assert receipt.status == "success"
    assert receipt.reference == @tx_hash
    assert receipt.funding_currency == "0x20c000000000000000000000f37de3740ADec032"
    assert {:ok, ^receipt} = receipt |> Receipt.encode() |> Receipt.decode()
  end

  test "rejects the same settlement when the credential source is not the payer", %{rpc_url: rpc_url} do
    charge = machine_token_charge(rpc_url)

    charge = %{
      charge
      | method_details:
          Map.put(charge.method_details, "credential_source", "did:pkh:eip155:#{@chain_id}:#{@wrong_source}")
    }

    assert {:error, %Errors{} = error} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
    assert error.type =~ "verification-failed"
    assert error.detail =~ "No matching Transfer"
  end

  test "accepts the settlement when the credential source is the on-chain payer", %{rpc_url: rpc_url} do
    charge = machine_token_charge(rpc_url)

    charge = %{
      charge
      | method_details: Map.put(charge.method_details, "credential_source", "did:pkh:eip155:#{@chain_id}:#{@payer}")
    }

    assert {:ok, %Receipt{}} = Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)
  end

  defp machine_token_charge(rpc_url) do
    {:ok, charge} =
      Charge.new(
        amount: @amount,
        currency: @currency,
        recipient: @merchant
      )

    %{
      charge
      | method_details: %{
          "rpc_url" => rpc_url,
          "chain_id" => @chain_id,
          "machine_token_enabled" => true,
          "store" => false
        }
    }
  end

  defp ping_machine_token_settlement!(rpc_url, tx_hash) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_getTransactionReceipt",
        "params" => [tx_hash],
        "id" => 1
      })

    case Req.post(rpc_url, headers: [{"content-type", "application/json"}], body: body) do
      {:ok, %Req.Response{status: status, body: %{"result" => receipt}}}
      when status in 200..299 and is_map(receipt) ->
        if receipt["status"] != "0x1" do
          flunk("Pinned MACH settlement reverted on-chain (tx: #{tx_hash})")
        end

        :ok

      {:ok, %Req.Response{status: status, body: %{"result" => nil}}} when status in 200..299 ->
        flunk("""
        Pinned MACH settlement was not found on Moderato.

        Tx hash: #{tx_hash}
        RPC URL: #{rpc_url}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        flunk("""
        Failed to fetch pinned MACH settlement from Moderato.

        Tx hash: #{tx_hash}
        RPC URL: #{rpc_url}
        HTTP status: #{status}
        Body: #{inspect(resp_body)}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)

      {:error, exception} ->
        flunk("""
        Tempo Moderato RPC is unreachable — cannot pin MACH settlement.

        Tx hash: #{tx_hash}
        RPC URL: #{rpc_url}
        Error: #{Exception.message(exception)}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)
    end
  end
end
