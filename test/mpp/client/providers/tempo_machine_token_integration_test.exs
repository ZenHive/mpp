defmodule MPP.Client.Providers.TempoMachineTokenIntegrationTest do
  @moduledoc """
  Live Moderato pins for built-in Tempo provider machine-token construction.

  The faucet funds pathUSD, not MPP Credits, so these tests pin construction
  and chain pinning through `MPP.Client.Providers.Tempo` rather than a
  broadcast settlement. A failed RPC or faucet call flunks with the exact
  `export` needed to point at another endpoint.
  """

  use ExUnit.Case, async: false

  alias MPP.Client.Providers.Tempo, as: TempoProvider
  alias MPP.Headers
  alias MPP.Methods.Tempo
  alias MPP.Methods.Tempo.MachineToken
  alias Onchain.Tempo.Faucet
  alias Onchain.Tempo.Transaction

  @moduletag :integration

  @default_rpc_url "https://rpc.moderato.tempo.xyz"
  @chain_id 42_431
  @path_usd "0x20c0000000000000000000000000000000000000"
  @hmac_secret "test-hmac-secret-for-tempo-machine-token-client"
  @realm "tempo-machine-token-client.example.com"
  @transfer_amount 1_000_000
  @gas_limit 1_000_000
  @attribution_tag Base.decode16!("EF1ED712")
  @client_id "mpp-elixir-machine-token"

  setup_all do
    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    ping_moderato!(rpc_url)
    recipient = fresh_wallet!(rpc_url)

    {:ok, rpc_url: rpc_url, recipient: recipient.address_hex}
  end

  test "pays a machineTokenEnabled challenge as approve + swapTo with bound attribution", %{
    rpc_url: rpc_url,
    recipient: recipient
  } do
    config = machine_token_config(recipient, rpc_url)
    challenge = request_challenge!(config)
    assert challenge_request(challenge)["methodDetails"]["machineTokenEnabled"] == true
    refute get_in(challenge_request(challenge), ["methodDetails", "memo"])

    sender = fresh_wallet!(rpc_url)

    assert {:ok, credential} =
             TempoProvider.pay(challenge, %{
               private_key: sender.private_key,
               rpc_url: rpc_url,
               expected_chain_id: @chain_id,
               client_id: @client_id,
               nonce: 0,
               gas_limit: @gas_limit
             })

    assert %{"type" => "transaction", "signature" => signature} = credential.payload
    assert {:ok, tx} = Transaction.deserialize(signature)
    assert tx.chain_id == @chain_id

    assert {:ok, route} =
             MachineToken.match_route(
               tx.calls,
               @chain_id,
               @path_usd,
               Integer.to_string(@transfer_amount),
               recipient,
               nil
             )

    assert route.settlement_sender == MachineToken.settlement_sender(@chain_id)

    assert {:ok, memo} = Base.decode16(String.trim_leading(route.memo, "0x"), case: :mixed)
    tag = @attribution_tag

    assert <<^tag::binary-size(4), 1, server::binary-size(10), client::binary-size(10), nonce::binary-size(7)>> = memo
    assert server == fingerprint(@realm, 10)
    assert client == fingerprint(@client_id, 10)
    assert nonce == fingerprint(challenge.id, 7)

    assert {:error, reason} =
             Transaction.find_payment_call(tx, @path_usd,
               amount: Integer.to_string(@transfer_amount),
               recipient: recipient
             )

    assert reason =~ "No matching transfer"
  end

  test "rejects a machineTokenEnabled challenge whose chain disagrees with live Moderato", %{
    rpc_url: rpc_url,
    recipient: recipient
  } do
    challenge =
      recipient
      |> machine_token_config(rpc_url)
      |> request_challenge!()
      |> put_challenge_chain_id(1)

    assert {:error, {:rpc_chain_id_mismatch, 1, @chain_id}} =
             TempoProvider.pay(challenge, %{
               private_key: String.duplicate("11", 32),
               rpc_url: rpc_url
             })
  end

  defp machine_token_config(recipient, rpc_url) do
    MPP.Plug.init(
      secret_key: @hmac_secret,
      realm: @realm,
      method: Tempo,
      amount: Integer.to_string(@transfer_amount),
      currency: @path_usd,
      recipient: recipient,
      method_config: %{
        "rpc_url" => rpc_url,
        "chain_id" => @chain_id,
        "machine_token_enabled" => true,
        "store" => false
      }
    )
  end

  defp request_challenge!(config) do
    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> MPP.Plug.call(config)

    assert conn.status == 402
    assert [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert {:ok, challenge} = Headers.parse_challenge(challenge_header)
    challenge
  end

  defp challenge_request(challenge) do
    {:ok, json} = Base.url_decode64(challenge.request, padding: false)
    Jason.decode!(json)
  end

  defp put_challenge_chain_id(challenge, chain_id) do
    request = challenge |> challenge_request() |> put_in(["methodDetails", "chainId"], chain_id)
    encoded = request |> Jason.encode!() |> Base.url_encode64(padding: false)
    %{challenge | request: encoded}
  end

  defp fingerprint(value, byte_count) do
    binary_part(ExSha3.keccak_256(value), 0, byte_count)
  end

  defp ping_moderato!(rpc_url) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_chainId", "params" => [], "id" => 1})

    case Req.post(rpc_url, headers: [{"content-type", "application/json"}], body: body) do
      {:ok, %Req.Response{status: status, body: %{"result" => "0xa5bf"}}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        flunk("""
        Tempo Moderato RPC did not return chain ID 42431.

        RPC URL: #{rpc_url}
        HTTP status: #{status}
        Body: #{inspect(resp_body)}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)

      {:error, exception} ->
        flunk("""
        Tempo Moderato RPC is unreachable — cannot pin machine-token client construction.

        RPC URL: #{rpc_url}
        Error: #{Exception.message(exception)}

        export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)
    end
  end

  defp fresh_wallet!(rpc_url) do
    case Faucet.fresh_funded_wallet(rpc_url: rpc_url) do
      {:ok, wallet} ->
        wallet

      {:error, msg} ->
        flunk("""
        Tempo Moderato faucet failed to fund a fresh test wallet.

        Error: #{msg}
        RPC URL: #{rpc_url}

        The Tempo Moderato testnet faucet may be down or rate-limited.
        Set TEMPO_RPC_URL to override: export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)
    end
  end
end
