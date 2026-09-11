defmodule MPP.Methods.XRPL.Codec do
  @moduledoc """
  Bounded XRPL Payment decoder for pre-submission field verification.

  Field ordinals and encodings follow https://xrpl.org/docs/references/protocol/binary-format
  and XRPLF/xrpl.js `packages/ripple-binary-codec/src/enums/definitions.json`.
  Unknown fields, duplicate fields, noncanonical order and truncated objects fail closed.
  This decoder does not sign transactions; the ledger verifies signatures.
  """

  alias Cartouche.Base58

  @bitcoin ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  # https://xrpl.org/docs/references/protocol/data-types/base58-encodings
  @ripple ~c"rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz"
  @to_ripple Map.new(Enum.zip(@bitcoin, @ripple))
  @to_bitcoin Map.new(Enum.zip(@ripple, @bitcoin))
  @fields %{
    {1, 2} => "TransactionType",
    {2, 1} => "NetworkID",
    {2, 2} => "Flags",
    {2, 3} => "SourceTag",
    {2, 4} => "Sequence",
    {2, 14} => "DestinationTag",
    {2, 27} => "LastLedgerSequence",
    {2, 41} => "TicketSequence",
    {5, 9} => "AccountTxnID",
    {5, 17} => "InvoiceID",
    {6, 1} => "Amount",
    {6, 8} => "Fee",
    {6, 9} => "SendMax",
    {6, 10} => "DeliverMin",
    {7, 3} => "SigningPubKey",
    {7, 4} => "TxnSignature",
    {7, 12} => "MemoType",
    {7, 13} => "MemoData",
    {7, 14} => "MemoFormat",
    {8, 1} => "Account",
    {8, 3} => "Destination",
    {14, 10} => "Memo",
    {14, 16} => "Signer",
    {15, 3} => "Signers",
    {15, 9} => "Memos",
    {18, 1} => "Paths"
  }

  @doc "Decode a hex Payment blob, rejecting malformed or unsupported encodings."
  @spec decode(term()) :: {:ok, map()} | {:error, :malformed_blob}
  def decode(hex) when is_binary(hex) and byte_size(hex) in 2..131_072 do
    with {:ok, bytes} <- Base.decode16(hex, case: :mixed),
         {:ok, tx, <<>>} <- object(bytes, %{}, {0, 0}, 0),
         0 <- tx["TransactionType"] do
      {:ok, Map.put(tx, "TransactionType", "Payment")}
    else
      _ -> {:error, :malformed_blob}
    end
  end

  def decode(_), do: {:error, :malformed_blob}

  @doc "Validate a classic address's version, length and checksum."
  @spec address?(term()) :: boolean()
  def address?(address) when is_binary(address) and byte_size(address) in 25..35 do
    translated = for <<char <- address>>, into: "", do: <<Map.get(@to_bitcoin, char, ?0)>>

    case Base58.decode(translated) do
      {:ok, <<0, _::binary-20, checksum::binary-4>> = bytes} ->
        binary_part(double_hash(binary_part(bytes, 0, 21)), 0, 4) == checksum

      _ ->
        false
    end
  end

  def address?(_), do: false

  defp address(bytes) do
    body = <<0, bytes::binary>>
    checksum = binary_part(double_hash(body), 0, 4)
    for <<char <- Base58.encode(body <> checksum)>>, into: "", do: <<Map.fetch!(@to_ripple, char)>>
  end

  defp double_hash(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp object(<<>>, acc, _previous, 0), do: {:ok, acc, <<>>}
  defp object(<<0xE1, rest::binary>>, acc, _previous, depth) when depth > 0, do: {:ok, acc, rest}

  defp object(bytes, acc, previous, depth) when depth < 4 do
    with {:ok, {type, _} = id, rest} <- field_id(bytes),
         true <- id > previous,
         {:ok, name} <- Map.fetch(@fields, id),
         {:ok, value, tail} <- value(type, rest, depth) do
      object(tail, Map.put(acc, name, value), id, depth)
    else
      _ -> :error
    end
  end

  defp object(_, _, _, _), do: :error

  defp field_id(<<type::4, field::4, rest::binary>>) do
    with {:ok, type, rest} <- ordinal(type, rest),
         {:ok, field, rest} <- ordinal(field, rest) do
      {:ok, {type, field}, rest}
    end
  end

  defp field_id(_), do: :error
  defp ordinal(0, <<n, rest::binary>>) when n >= 16, do: {:ok, n, rest}
  defp ordinal(n, rest) when n > 0, do: {:ok, n, rest}
  defp ordinal(_, _), do: :error

  defp value(1, <<n::16, rest::binary>>, _depth), do: {:ok, n, rest}
  defp value(2, <<n::32, rest::binary>>, _depth), do: {:ok, n, rest}
  defp value(5, <<n::binary-32, rest::binary>>, _depth), do: {:ok, Base.encode16(n), rest}
  defp value(6, bytes, _depth), do: amount(bytes)

  defp value(7, bytes, _depth) do
    with {:ok, bytes, rest} <- variable(bytes), do: {:ok, Base.encode16(bytes), rest}
  end

  defp value(8, <<20, bytes::binary-20, rest::binary>>, _depth), do: {:ok, address(bytes), rest}
  defp value(14, bytes, depth), do: object(bytes, %{}, {0, 0}, depth + 1)
  defp value(15, bytes, depth), do: array(bytes, [], depth + 1)
  defp value(18, bytes, _depth), do: paths(bytes)
  defp value(_, _, _), do: :error

  defp variable(<<n, rest::binary>>) when n <= 192, do: take(rest, n)
  defp variable(<<n, second, rest::binary>>) when n in 193..240, do: take(rest, 193 + (n - 193) * 256 + second)

  defp variable(<<n, second, third, rest::binary>>) when n in 241..254,
    do: take(rest, 12_481 + (n - 241) * 65_536 + second * 256 + third)

  defp variable(_), do: :error

  defp take(bytes, n) when byte_size(bytes) >= n do
    <<value::binary-size(^n), rest::binary>> = bytes
    {:ok, value, rest}
  end

  defp take(_, _), do: :error

  defp array(<<0xF1, rest::binary>>, acc, _depth), do: {:ok, Enum.reverse(acc), rest}

  defp array(bytes, acc, depth) when depth < 4 do
    with {:ok, {14, _} = id, rest} <- field_id(bytes),
         {:ok, name} <- Map.fetch(@fields, id),
         {:ok, item, rest} <- object(rest, %{}, {0, 0}, depth) do
      array(rest, [%{name => item} | acc], depth)
    else
      _ -> :error
    end
  end

  defp array(_, _, _), do: :error

  defp paths(<<0, rest::binary>>), do: {:ok, :paths, rest}
  defp paths(<<255, rest::binary>>), do: paths(rest)

  defp paths(<<flags, rest::binary>>) when flags in [1, 16, 17, 32, 33, 48, 49] do
    size = Enum.count([1, 16, 32], &(Bitwise.band(flags, &1) != 0)) * 20
    with {:ok, _, rest} <- take(rest, size), do: paths(rest)
  end

  defp paths(_), do: :error

  defp amount(<<1::1, sign::1, exponent::8, mantissa::54, currency::binary-20, issuer::binary-20, rest::binary>>) do
    value = signed(sign, mantissa) <> "e" <> Integer.to_string(exponent - 97)
    {:ok, %{"currency" => currency(currency), "issuer" => address(issuer), "value" => value}, rest}
  end

  defp amount(<<0::1, sign::1, 1::1, 0::5, n::64, issuance::binary-24, rest::binary>>) do
    {:ok, %{"mpt_issuance_id" => Base.encode16(issuance), "value" => signed(sign, n)}, rest}
  end

  defp amount(<<0::1, sign::1, 0::1, n::61, rest::binary>>), do: {:ok, signed(sign, n), rest}
  defp amount(_), do: :error
  defp signed(0, n) when n != 0, do: "-" <> Integer.to_string(n)
  defp signed(_, n), do: Integer.to_string(n)
  defp currency(<<0::96, code::binary-3, 0::40>>), do: code
  defp currency(bytes), do: Base.encode16(bytes)
end
