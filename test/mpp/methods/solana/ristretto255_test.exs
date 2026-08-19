defmodule MPP.Methods.Solana.Ristretto255Test do
  use ExUnit.Case, async: true

  alias MPP.Methods.Solana.Ristretto255

  @scalar_order 7_237_005_577_332_262_213_973_186_563_042_994_240_857_116_359_379_907_606_001_950_938_285_454_250_989
  @identity <<0::256>>
  @basepoint Base.decode16!("E2F2AE0A6ABC4E71A884A961C500515F58E30B6AA582DD8DB6A65945E08D2D76")
  @low_ciphertext Base.decode16!(
                    "64990C6B35B06D4E83E462C37FEF71D011F277FDF79C224AB090DA880BF04A3A" <>
                      "BCE83F8BA5DD2FA572864C24BA1810F9522BC6004AFE95877AC73241CAFDAB42"
                  )

  describe "decode_scalar/1" do
    test "accepts a canonical nonzero scalar" do
      assert {:ok, 7} = Ristretto255.decode_scalar(<<7, 0::248>>)
    end

    test "rejects zero, the group order, and malformed values" do
      assert :error = Ristretto255.decode_scalar(<<0::256>>)
      assert :error = Ristretto255.decode_scalar(<<@scalar_order::little-unsigned-size(256)>>)
      assert :error = Ristretto255.decode_scalar(<<1>>)
    end
  end

  describe "decompress/1" do
    test "accepts the canonical Ristretto basepoint and identity" do
      assert {:ok, {_x, _y, _z, _t}} = Ristretto255.decompress(@basepoint)
      assert {:ok, {0, 1, 1, 0}} = Ristretto255.decompress(@identity)
    end

    test "rejects malformed, noncanonical, and negative encodings" do
      assert :error = Ristretto255.decompress(<<1>>)
      assert :error = Ristretto255.decompress(<<1, 0::248>>)
      assert :error = Ristretto255.decompress(<<255::size(8)-unit(32)>>)
    end
  end

  describe "delta_matches?/4" do
    test "matches an independent libsodium Ristretto255 vector" do
      <<commitment::binary-32, handle::binary-32>> = @low_ciphertext
      before = {@identity, @identity}
      current = {commitment, handle}

      assert Ristretto255.delta_matches?(before, current, 3, 7)
      refute Ristretto255.delta_matches?(before, current, 4, 7)
      refute Ristretto255.delta_matches?(before, current, 3, 8)
    end

    test "rejects invalid points" do
      invalid = {<<1>>, @identity}
      refute Ristretto255.delta_matches?(invalid, {@identity, @identity}, 0, 1)
    end
  end
end
