defmodule MPP.Methods.TempoMachineTokenIntegrationTest do
  @moduledoc """
  Live Moderato pins for first-party machine-token charge verification.

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

  # Live Moderato push settlement observed 2026-08-19:
  # tx 0x6b1cdd6740dfe19c4a3e5e92cf7001b609fe21e845474cf1133b86338e5cd2f0
  # swapper 0x07f1FE0467Ae01DE340024aa4b7DD9729b1c169b, input MPPC, target pathUSD sibling.
  @tx_hash "0x6b1cdd6740dfe19c4a3e5e92cf7001b609fe21e845474cf1133b86338e5cd2f0"
  @payer "0x1f8836f4478743d61230467881edd51599b08969"
  @merchant "0x967fa869a1f124770f93d48cc900255936de641a"
  @currency "0x20c0000000000000000000000000000000000001"
  @amount "10000000"
  @memo "0x1b9389b6b5448148fbf008ef525dbb5107467f234586b4fad360b7aff3509dde"
  @wrong_source "0x1111111111111111111111111111111111111111"

  setup_all do
    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    ping_machine_token_settlement!(rpc_url, @tx_hash)
    {:ok, rpc_url: rpc_url}
  end

  test "verifies a real Moderato machine-token push settlement", %{rpc_url: rpc_url} do
    charge = machine_token_charge(rpc_url)

    assert {:ok, %Receipt{} = receipt} =
             Tempo.verify(%{"type" => "hash", "hash" => @tx_hash}, charge)

    assert receipt.method == "tempo"
    assert receipt.status == "success"
    assert receipt.reference == @tx_hash
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
    assert error.detail =~ "No matching TransferWithMemo"
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
          "memo" => @memo,
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
          flunk("Pinned machine-token settlement reverted on-chain (tx: #{tx_hash})")
        end

        :ok

      {:ok, %Req.Response{status: status, body: %{"result" => nil}}} when status in 200..299 ->
        flunk("""
        Pinned machine-token settlement was not found on Moderato.

        Tx hash: #{tx_hash}
        RPC URL: #{rpc_url}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        flunk("""
        Failed to fetch pinned machine-token settlement from Moderato.

        Tx hash: #{tx_hash}
        RPC URL: #{rpc_url}
        HTTP status: #{status}
        Body: #{inspect(resp_body)}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)

      {:error, exception} ->
        flunk("""
        Tempo Moderato RPC is unreachable — cannot pin machine-token settlement.

        Tx hash: #{tx_hash}
        RPC URL: #{rpc_url}
        Error: #{Exception.message(exception)}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)
    end
  end
end
