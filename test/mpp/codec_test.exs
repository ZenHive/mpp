defmodule MPP.CodecTest do
  use ExUnit.Case, async: true

  alias MPP.Codec

  describe "decode_base64_json/1" do
    test "decodes a base64url JSON object into a map" do
      encoded = Base.url_encode64(Jason.encode!(%{"a" => 1, "b" => "two"}), padding: false)
      assert {:ok, %{"a" => 1, "b" => "two"}} = Codec.decode_base64_json(encoded)
    end

    test "decodes non-object JSON (array) — shape validation is the caller's job" do
      encoded = Base.url_encode64(Jason.encode!([1, 2, 3]), padding: false)
      assert {:ok, [1, 2, 3]} = Codec.decode_base64_json(encoded)
    end

    test "returns :invalid_base64 for a non-base64url string" do
      assert {:error, :invalid_base64} = Codec.decode_base64_json("@@not base64@@")
    end

    test "returns :invalid_json for valid base64url that is not JSON" do
      encoded = Base.url_encode64("not json at all", padding: false)
      assert {:error, :invalid_json} = Codec.decode_base64_json(encoded)
    end
  end
end
