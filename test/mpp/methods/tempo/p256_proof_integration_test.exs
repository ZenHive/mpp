defmodule MPP.Methods.Tempo.P256ProofIntegrationTest do
  use ExUnit.Case, async: false

  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo
  alias MPP.Methods.Tempo.Proof
  alias MPP.Receipt
  alias Onchain.Address
  alias Onchain.Contract
  alias Onchain.Tempo.Faucet

  @moduletag :integration
  @signature_verifier "0x5165300000000000000000000000000000000000"
  @keychain "0xaAAAaaAA00000000000000000000000000000000"
  @script Path.expand("../../../support/tempo_p256_access_key.mjs", __DIR__)

  for prehash <- [false, true], version <- [0, 3, 4] do
    @version version
    @prehash prehash
    test "Moderato P-256 proofs with prehash=#{prehash}, envelope=#{version} reject tampered and unrelated keys" do
      rpc_url = System.get_env("TEMPO_RPC_URL") || "https://rpc.moderato.tempo.xyz"
      opts = [rpc_url: rpc_url]
      assert {:ok, root} = Faucet.fresh_funded_wallet(opts)
      challenge_id = "p256-proof-#{System.unique_integer([:positive])}"
      params = %{account: root.address_hex, chain_id: 42_431, challenge_id: challenge_id, realm: "p256.example"}
      digest = Proof.hash(params)

      input =
        Jason.encode!(%{rootPrivateKey: hex(root.private_key), rpcUrl: rpc_url, digest: hex(digest), version: @version})

      {output, status} = System.cmd("node", [@script, input], stderr_to_stdout: true)
      assert status == 0, "Live P-256 provisioning failed (requires npm install --no-save viem@2.55.18): #{output}"
      fixture = Jason.decode!(output)
      {:ok, access_key} = Address.validate(fixture["accessKeyAddress"])

      on_exit(fn ->
        input =
          Jason.encode!(%{
            action: "revoke",
            rootPrivateKey: hex(root.private_key),
            rpcUrl: rpc_url,
            accessKeyAddress: fixture["accessKeyAddress"]
          })

        {output, status} = System.cmd("node", [@script, input], stderr_to_stdout: true)
        assert status == 0, "Live P-256 cleanup failed: #{output}"

        assert {:error, :inactive_access_key} =
                 MPP.Methods.Tempo.AccessKey.fetch_active(root.address_hex, fixture["accessKeyAddress"], opts)
      end)

      assert {:ok, [1, ^access_key, expiry, false, false]} =
               Contract.call(
                 @keychain,
                 "getKey(address,address)",
                 [root.address_bin, access_key],
                 "(uint8,address,uint64,bool,bool)",
                 opts
               )

      assert expiry > System.os_time(:second)

      charge = %Charge{
        amount: "0",
        currency: "0x20c0000000000000000000000000000000000000",
        recipient: root.address_hex,
        method_details: %{
          "rpc_url" => rpc_url,
          "chain_id" => 42_431,
          "challenge_id" => challenge_id,
          "realm" => params.realm,
          "credential_source" => "did:pkh:eip155:42431:#{root.address_hex}"
        }
      }

      signature = Enum.at(fixture["signatures"], if(@prehash, do: 1, else: 0))
      IO.puts("Moderato P-256 key #{fixture["accessKeyAddress"]}; authorization #{fixture["authorizationHash"]}")

      assert {:error, wrong_key_error} =
               Tempo.verify(%{"type" => "proof", "signature" => fixture["wrongSignature"]}, charge)

      assert wrong_key_error.detail == "Proof signature does not match source"

      payload = Base.decode16!(String.trim_leading(fixture["payload"], "0x"), case: :mixed)
      prefix = Base.decode16!(String.trim_leading(fixture["prefix"], "0x"), case: :mixed)

      bytes = Base.decode16!(String.trim_leading(signature, "0x"), case: :mixed)

      assert {:ok, [true]} =
               Contract.call(
                 @signature_verifier,
                 "verify(address,bytes32,bytes)",
                 [access_key, payload, bytes],
                 "(bool)",
                 opts
               )

      <<type, first, rest::binary>> = bytes
      tampered = <<type, Bitwise.bxor(first, 1), rest::binary>>

      assert {:error, {:rpc_error, %{code: 3, data: "0x8baa579f"}}} =
               Contract.call(
                 @signature_verifier,
                 "verify(address,bytes32,bytes)",
                 [access_key, payload, tampered],
                 "(bool)",
                 opts
               )

      assert {:error, tampered_error} =
               Tempo.verify(%{"type" => "proof", "signature" => hex(prefix <> tampered)}, charge)

      assert tampered_error.detail == "Proof signature does not match source"

      assert {:ok, %Receipt{reference: ^challenge_id}} =
               Tempo.verify(%{"type" => "proof", "signature" => hex(prefix <> bytes)}, charge)
    end
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
