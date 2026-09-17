defmodule MPP.Methods.XRPL.CodecTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.XRPL.Codec

  @vectors "test/fixtures/xrpl/codec.json" |> File.read!() |> Jason.decode!()

  test "decodes Payment vectors from the XRPL-owned binary codec" do
    for %{"blob" => blob, "decoded" => expected} <- @vectors do
      assert {:ok, decoded} = Codec.decode(String.downcase(blob))
      assert normalize(decoded) == normalize(expected)
    end
  end

  test "classic addresses verify the XRPL alphabet, version, checksum and length" do
    for vector <- @vectors do
      assert Codec.address?(vector["decoded"]["Account"])
      assert Codec.address?(vector["decoded"]["Destination"])
    end

    for invalid <- [
          nil,
          4,
          "",
          String.duplicate("r", 36),
          String.duplicate("0", 30),
          "rhewi79quXUDwcqjkpj4bXuw3cuHYC9fwx",
          "Xhewi79quXUDwcqjkpj4bXuw3cuHYC9fwv"
        ] do
      refute Codec.address?(invalid)
    end
  end

  test "truncation, unknown ordinals, duplicates, disorder and trailing data fail closed" do
    for input <- [
          nil,
          %{},
          "",
          "0",
          "GG",
          String.duplicate("00", 65_537),
          "120001",
          "120000120000",
          "2400000001120000",
          "12000000",
          "1200000010",
          "1200001010",
          "1200007010",
          "120000E1",
          "120000F9",
          "120000F9EA",
          "120000F9F2",
          "120000F9EAEA",
          "120000F9EA7DFF",
          "120000F9EA7DF10000",
          "120000F9EA7DC101",
          "1200000110",
          "120000011001",
          "1200001200",
          "12000061",
          "1200008101",
          "120000011200000000"
        ] do
      assert {:error, :malformed_blob} = Codec.decode(input), inspect(input)
    end

    for %{"blob" => blob} <- @vectors do
      # Truncate inside the final field or its required container terminator.
      assert {:error, :malformed_blob} = Codec.decode(binary_part(blob, 0, byte_size(blob) - 2))
      assert {:error, :malformed_blob} = Codec.decode(blob <> "00")
    end
  end

  test "bounds long variable-length fields and malformed path sets" do
    data = String.duplicate("41", 12_481)

    assert {:ok, %{"Memos" => [%{"Memo" => %{"MemoData" => ^data}}]}} =
             Codec.decode("120000F9EA7DF10000" <> data <> "E1F1")

    assert {:error, :malformed_blob} = Codec.decode("120000F9EA7DF10001" <> data <> "E1F1")
    assert {:error, :malformed_blob} = Codec.decode("12000001120100")
    assert {:error, :malformed_blob} = Codec.decode("120000011202")
  end

  test "decode_seed rejects a classic address that is not a family seed" do
    account = hd(@vectors)["decoded"]["Account"]
    assert byte_size(account) in 25..40
    assert :error = Codec.decode_seed(account)
  end

  test "encode_account rejects an AccountID that is not 20 bytes" do
    assert :error = Codec.encode_account(<<>>)
    assert :error = Codec.encode_account(<<1, 2, 3>>)
  end

  test "decode rejects objects nested beyond the depth bound" do
    # Four nested type-14 (Memo) objects: the fourth call is depth 4, which the
    # bounded object decoder rejects rather than recursing.
    assert {:error, :malformed_blob} = Codec.decode("120000EAEAEAEA")
  end

  test "encode_claim rejects a Sequence that does not fit in a uint32" do
    assert :error =
             Codec.encode_claim(%{
               "TransactionType" => "PaymentChannelClaim",
               "Sequence" => 0x1_0000_0000
             })
  end

  test "encode_claim accepts a 0X-prefixed Channel hash" do
    channel = "7A4178B01DC1B19665745CC5720C1A8198678A3C0048844E86998F35A470D2AE"

    assert {:ok, blob} =
             Codec.encode_claim(%{
               "TransactionType" => "PaymentChannelClaim",
               "Channel" => "0X" <> channel
             })

    assert {:ok, decoded} = Codec.decode_claim(blob)
    assert decoded["Channel"] == channel
  end

  defp normalize(map) when is_map(map) do
    Map.new(map, fn
      {"Paths", _} -> {"Paths", :paths}
      {"value", value} -> {"value", value |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal)}
      {key, value} -> {key, normalize(value)}
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value
end
