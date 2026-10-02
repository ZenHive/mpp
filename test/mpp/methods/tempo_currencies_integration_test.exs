defmodule MPP.Methods.TempoCurrenciesIntegrationTest do
  @moduledoc """
  Live OUSD settlement pin on Moderato. Uses the public faucet; no keys required.
  Override the RPC with `export TEMPO_RPC_URL=https://rpc.moderato.tempo.xyz`.
  """
  use ExUnit.Case, async: false

  alias MPP.Client.Providers.Tempo, as: TempoProvider
  alias MPP.Client.Transport.WebSocket, as: ClientTransport
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Methods.Tempo
  alias MPP.Receipt
  alias MPP.Test.FaucetWallet
  alias MPP.Transports.WebSocket
  alias Onchain.Address
  alias Onchain.Tempo.RPC

  @moduletag :integration
  # docs.tempo.xyz/guide/ousd prints this account in lowercase and deploys it on
  # both mainnet and Moderato. Challenges use the EIP-55 form (viem/mppx).
  @ousd "0x20c0000000000000000000006a37DA5C996874BE"
  @ousd_docs "0x20c0000000000000000000006a37da5c996874be"
  @path_usd "0x20c0000000000000000000000000000000000000"
  @recipient "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"

  test "Moderato OUSD payment satisfies the second WebSocket offer but not pathUSD" do
    rpc_url = System.get_env("TEMPO_RPC_URL") || "https://rpc.moderato.tempo.xyz"
    wallet = FaucetWallet.tempo!(rpc_url)

    opts = [
      secret_key: String.duplicate("k", 32),
      realm: "ousd.integration.test",
      method: Tempo,
      amount: "1000000",
      recipient: @recipient,
      method_config: %{"chain_id" => 42_431, "rpc_url" => rpc_url, "store" => false}
    ]

    config = MPP.Plug.init(opts)

    {session, [first, second]} =
      opts
      |> Keyword.merge(handler: fn _ -> "paid" end, currencies: [@path_usd, @ousd])
      |> WebSocket.init()
      |> WebSocket.open()

    assert {:ok, [first_challenge]} = ClientTransport.get_challenges(Jason.decode!(first))
    assert {:ok, [challenge]} = ClientTransport.get_challenges(Jason.decode!(second))

    assert {:ok, payment} =
             TempoProvider.pay(challenge, %{
               private_key: wallet.private_key,
               rpc_url: rpc_url,
               fee_token: @path_usd,
               nonce_key: 0
             })

    assert {:ok, hash, %{status: 1}} = RPC.broadcast_sync(payment.payload["signature"], rpc_url)

    assert Address.equal?(@ousd, @ousd_docs)
    assert Enum.map(config.method_entries, & &1.charge.currency) == [@ousd, @path_usd]
    [ousd, path_usd] = config.method_entries
    assert first_challenge.request == path_usd.request
    assert challenge.request == ousd.request
    payload = %{"type" => "hash", "hash" => hash}
    charge = %{ousd.charge | method_details: ousd.method_config}
    assert {:ok, %Receipt{funding_currency: @ousd} = receipt} = Tempo.verify(payload, charge)
    assert {:ok, ^receipt} = receipt |> Receipt.encode() |> Receipt.decode()

    wrong_charge = %{path_usd.charge | method_details: path_usd.method_config}

    assert {:error, %Errors{detail: "No matching Transfer event found in transaction"}} =
             Tempo.verify(payload, wrong_charge)

    altered = %{challenge | request: first_challenge.request}
    credential = %Credential{challenge: altered, payload: payload}
    text = credential |> then(&ClientTransport.set_credential(%{}, &1)) |> Jason.encode!()
    {rejected, [error]} = WebSocket.handle_text(text, session)
    assert rejected.status == :open
    assert Jason.decode!(error) == %{"type" => "error", "error" => "Invalid Challenge"}

    credential = %Credential{challenge: challenge, payload: payload}
    text = credential |> then(&ClientTransport.set_credential(%{}, &1)) |> Jason.encode!()
    {authorized, [receipt_text]} = WebSocket.handle_text(text, session)
    assert authorized.status == :authorized, receipt_text
    assert %{"type" => "receipt", "receipt" => ws_receipt} = Jason.decode!(receipt_text)
    assert ws_receipt["status"] == "success"
    assert ws_receipt["challengeId"] == challenge.id
    assert ws_receipt["reference"] == hash
    assert ws_receipt["fundingCurrency"] == @ousd
  end
end
