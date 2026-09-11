defmodule MPP.Methods.XRPL.ClaimTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.XRPL.Claim

  @fixture "test/fixtures/xrpl/session.json" |> File.read!() |> Jason.decode!()
  @channel_id @fixture["channelId"]
  @ed_pubkey @fixture["payer"]["publicKey"]
  @ed_sig @fixture["claims"]["open"]
  @secp @fixture["secp256k1"]

  test "verifies an xrpl.js Ed25519 authorizeChannel signature" do
    assert :ok = Claim.verify(@channel_id, 100_000, @ed_sig, @ed_pubkey)
  end

  test "verifies an xrpl.js secp256k1 authorizeChannel signature" do
    assert :ok = Claim.verify(@secp["channelId"], 100_000, @secp["signature"], @secp["publicKey"])
  end

  test "rejects a tampered claim signature" do
    tampered = String.replace_prefix(@ed_sig, "27", "28")
    refute tampered == @ed_sig
    assert {:error, :invalid_signature} = Claim.verify(@channel_id, 100_000, tampered, @ed_pubkey)
  end

  test "rejects a signature over a different amount or channel" do
    assert {:error, :invalid_signature} = Claim.verify(@channel_id, 200_000, @ed_sig, @ed_pubkey)
    assert {:error, :invalid_channel_id} = Claim.verify("00", 100_000, @ed_sig, @ed_pubkey)
  end

  test "rejects a high-S secp256k1 encoding of an otherwise valid claim" do
    {:ok, der} = Base.decode16(@secp["signature"], case: :mixed)
    %Curvy.Signature{r: r, s: s} = Curvy.Signature.parse(der)
    n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    high = Curvy.Signature.to_der(%Curvy.Signature{r: r, s: n - s})

    assert {:error, :invalid_signature} =
             Claim.verify(@secp["channelId"], 100_000, Base.encode16(high), @secp["publicKey"])
  end

  test "rejects malformed keys, signatures and amounts" do
    assert {:error, :invalid_signature} = Claim.verify(@channel_id, 100_000, "00", @ed_pubkey)
    assert {:error, :invalid_public_key} = Claim.verify(@channel_id, 100_000, @ed_sig, "00")
    assert {:error, :invalid_amount} = Claim.verify(@channel_id, -1, @ed_sig, @ed_pubkey)
    assert {:error, :invalid_signature} = Claim.verify(@channel_id, 100_000, @ed_sig, nil)
    assert {:error, :invalid_public_key} = Claim.verify(@channel_id, 100_000, @ed_sig, String.duplicate("aa", 32))
  end

  test "digest hashes the CLM prefix and accepts 0x-prefixed hex" do
    assert {:ok, digest} = Claim.digest("0x" <> String.downcase(@channel_id), 100_000)
    assert byte_size(digest) == 32
    assert {:error, :invalid_amount} = Claim.digest(@channel_id, :nope)
    assert :ok = Claim.verify("0x" <> @channel_id, 100_000, "0x" <> @ed_sig, "0x" <> @ed_pubkey)
    assert :ok = Claim.verify(@channel_id, 100_000, "0X" <> @ed_sig, "0X" <> @ed_pubkey)

    oversized = @ed_sig <> "00"
    assert {:error, :invalid_signature} = Claim.verify(@channel_id, 100_000, oversized, @ed_pubkey)
  end
end
