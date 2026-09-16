defmodule MPP.Methods.Tempo.AccessKeyTypeTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo
  alias MPP.Methods.Tempo.AccessKey
  alias MPP.Methods.Tempo.KeyAuthorization
  alias MPP.Methods.Tempo.Proof

  @account "0x" <> String.duplicate("12", 20)
  @key "0x" <> String.duplicate("34", 20)
  @opts [rpc_url: "https://rpc.moderato.tempo.xyz", req_options: [plug: {Req.Test, __MODULE__}]]

  test "reads the primitive key type from getKey and rejects unknown types" do
    for {id, type} <- [{0, :secp256k1}, {1, :p256}, {2, :web_authn}] do
      stub_key(id)
      assert {:ok, ^type} = AccessKey.fetch_active(@account, @key, @opts)
      assert AccessKey.active?(@account, @key, @opts)
      assert {:ok, ^type} = KeyAuthorization.key_type(id)
    end

    stub_key(3)
    assert {:error, "unsupported access key type"} = AccessKey.fetch_active(@account, @key, @opts)
    refute AccessKey.active?(@account, @key, @opts)
    assert {:error, _} = AccessKey.fetch_active("invalid", @key, @opts)
  end

  test "a valid signature cannot authenticate a different registered key type" do
    private = :binary.copy(<<1>>, 32)
    {:ok, address} = Cartouche.Signer.Curvy.get_address(private)
    params = %{account: @account, chain_id: 42_431, challenge_id: "typed-key", realm: "example.test"}
    signature = MPP.Test.TempoAccessKey.sign_proof!(Proof.hash(params), private, address)
    stub_key(1)
    assert {:error, error} = Tempo.verify(%{"type" => "proof", "signature" => signature}, charge(params))
    assert error.detail == "Proof signature does not match source"
  end

  test "the charge API preserves the explicit unsupported WebAuthn error" do
    params = %{account: @account, chain_id: 42_431, challenge_id: "web-authn", realm: "example.test"}
    assert {:error, error} = Tempo.verify(%{"type" => "proof", "signature" => "0x02"}, charge(params))
    assert error.detail == "unsupported proof signature type: WebAuthn"
  end

  defp charge(params) do
    %MPP.Intents.Charge{
      amount: "0",
      currency: "0x20c0000000000000000000000000000000000000",
      recipient: @account,
      method_details: %{
        "rpc_url" => @opts[:rpc_url],
        "req_options" => @opts[:req_options],
        "chain_id" => params.chain_id,
        "challenge_id" => params.challenge_id,
        "realm" => params.realm,
        "credential_source" => "did:pkh:eip155:42431:#{@account}"
      }
    }
  end

  defp stub_key(type) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      {:ok, key} = Onchain.Address.validate(@key)
      result = <<type::256, 0::96, key::binary, 4_000_000_000::256, 0::256, 0::256>>
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "0x" <> Base.encode16(result)})
    end)
  end
end
