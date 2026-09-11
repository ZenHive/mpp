defmodule MPP.Methods.XRPL.Codec do
  @moduledoc """
  Bounded XRPL Payment, PaymentChannelCreate and PaymentChannelClaim codec.

  Field ordinals and encodings follow https://xrpl.org/docs/references/protocol/binary-format
  and XRPLF/xrpl.js `packages/ripple-binary-codec/src/enums/definitions.json`.
  Unknown fields, duplicate fields, noncanonical order and truncated objects fail closed.
  The decoder does not sign transactions; `encode_claim/1` serializes a
  PaymentChannelClaim for local signing.
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
    {2, 10} => "Expiration",
    {2, 14} => "DestinationTag",
    {2, 27} => "LastLedgerSequence",
    {2, 36} => "CancelAfter",
    {2, 39} => "SettleDelay",
    {2, 41} => "TicketSequence",
    {5, 9} => "AccountTxnID",
    {5, 17} => "InvoiceID",
    {5, 22} => "Channel",
    {6, 1} => "Amount",
    {6, 2} => "Balance",
    {6, 8} => "Fee",
    {6, 9} => "SendMax",
    {6, 10} => "DeliverMin",
    {7, 1} => "PublicKey",
    {7, 3} => "SigningPubKey",
    {7, 4} => "TxnSignature",
    {7, 6} => "Signature",
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

  @transaction_types %{0 => "Payment", 13 => "PaymentChannelCreate", 15 => "PaymentChannelClaim"}
  @claim_type 15
  @signing_omit ~w(TxnSignature Signature)
  @claim_fields [
    {"TransactionType", {1, 2}},
    {"NetworkID", {2, 1}},
    {"Flags", {2, 2}},
    {"Sequence", {2, 4}},
    {"LastLedgerSequence", {2, 27}},
    {"Channel", {5, 22}},
    {"Amount", {6, 1}},
    {"Balance", {6, 2}},
    {"Fee", {6, 8}},
    {"PublicKey", {7, 1}},
    {"SigningPubKey", {7, 3}},
    {"TxnSignature", {7, 4}},
    {"Signature", {7, 6}},
    {"Account", {8, 1}}
  ]

  @doc "Decode a hex Payment blob, rejecting malformed or unsupported encodings."
  @spec decode(term()) :: {:ok, map()} | {:error, :malformed_blob}
  def decode(hex) do
    case decode_typed(hex) do
      {:ok, %{"TransactionType" => "Payment"} = tx} -> {:ok, tx}
      _ -> {:error, :malformed_blob}
    end
  end

  @doc "Decode a signed PaymentChannelCreate blob for session open."
  @spec decode_create(term()) :: {:ok, map()} | {:error, :malformed_blob}
  def decode_create(hex) do
    case decode_typed(hex) do
      {:ok, %{"TransactionType" => "PaymentChannelCreate"} = tx} -> {:ok, tx}
      _ -> {:error, :malformed_blob}
    end
  end

  @doc "Decode a signed PaymentChannelClaim blob."
  @spec decode_claim(term()) :: {:ok, map()} | {:error, :malformed_blob}
  def decode_claim(hex) do
    case decode_typed(hex) do
      {:ok, %{"TransactionType" => "PaymentChannelClaim"} = tx} -> {:ok, tx}
      _ -> {:error, :malformed_blob}
    end
  end

  @doc "Serialize a PaymentChannelClaim. Pass `signing: true` to omit Signature and TxnSignature."
  @spec encode_claim(map()) :: {:ok, String.t()} | :error
  def encode_claim(tx) when is_map(tx), do: encode_claim(tx, [])

  @doc false
  @spec encode_claim(map(), keyword()) :: {:ok, String.t()} | :error
  def encode_claim(tx, opts) when is_map(tx) and is_list(opts) do
    case encode_claim_fields(tx, Keyword.get(opts, :signing, false)) do
      :error -> :error
      bytes when is_binary(bytes) and bytes != <<>> -> {:ok, Base.encode16(bytes)}
      _ -> :error
    end
  end

  @doc "STX-prefixed signing serialization for a PaymentChannelClaim."
  @spec claim_signing_data(map()) :: {:ok, binary()} | :error
  def claim_signing_data(tx) when is_map(tx) do
    case encode_claim(tx, signing: true) do
      {:ok, hex} -> {:ok, <<"STX", 0>> <> Base.decode16!(hex)}
      :error -> :error
    end
  end

  @doc "Decode a family seed to algorithm and 16-byte entropy."
  @spec decode_seed(term()) :: {:ok, {:ed25519 | :secp256k1, binary()}} | :error
  def decode_seed(seed) when is_binary(seed) and byte_size(seed) in 25..40 do
    translated = for <<char <- seed>>, into: "", do: <<Map.get(@to_bitcoin, char, ?0)>>

    case Base58.decode(translated) do
      {:ok, <<1, 0xE1, 0x4B, entropy::binary-16, _checksum::binary-4>> = bytes} ->
        if checksum?(bytes), do: {:ok, {:ed25519, entropy}}, else: :error

      {:ok, <<0x21, entropy::binary-16, _checksum::binary-4>> = bytes} ->
        if checksum?(bytes), do: {:ok, {:secp256k1, entropy}}, else: :error

      _ ->
        :error
    end
  end

  def decode_seed(_), do: :error

  @doc "Validate a classic address's version, length and checksum."
  @spec address?(term()) :: boolean()
  def address?(address), do: match?({:ok, _}, account_id(address))

  @doc "Return true when the transaction carries a signature or a non-empty signer list."
  @spec signed?(term()) :: boolean()
  def signed?(%{"TxnSignature" => signature}), do: is_binary(signature) and byte_size(signature) > 0
  def signed?(%{"Signers" => signers}), do: is_list(signers) and signers != []
  def signed?(_), do: false

  @doc "Encode a 20-byte AccountID as a classic address."
  @spec encode_account(binary()) :: {:ok, String.t()} | :error
  def encode_account(<<id::binary-20>>), do: {:ok, address(id)}
  def encode_account(_), do: :error

  @doc "Decode a classic address to its 20-byte AccountID."
  @spec account_id(term()) :: {:ok, binary()} | :error
  def account_id(address) when is_binary(address) and byte_size(address) in 25..35 do
    translated = for <<char <- address>>, into: "", do: <<Map.get(@to_bitcoin, char, ?0)>>

    case Base58.decode(translated) do
      {:ok, <<0, id::binary-20, checksum::binary-4>> = bytes} ->
        if binary_part(double_hash(binary_part(bytes, 0, 21)), 0, 4) == checksum, do: {:ok, id}, else: :error

      _ ->
        :error
    end
  end

  def account_id(_), do: :error

  defp decode_typed(hex) when is_binary(hex) and byte_size(hex) in 2..131_072 do
    with {:ok, bytes} <- Base.decode16(hex, case: :mixed),
         {:ok, tx, <<>>} <- object(bytes, %{}, {0, 0}, 0),
         type when is_binary(type) <- Map.get(@transaction_types, tx["TransactionType"]) do
      {:ok, Map.put(tx, "TransactionType", type)}
    else
      _ -> {:error, :malformed_blob}
    end
  end

  defp decode_typed(_), do: {:error, :malformed_blob}

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

  defp encode_claim_fields(tx, signing?) do
    Enum.reduce_while(@claim_fields, <<>>, fn {name, id}, acc ->
      encode_claim_field(tx, name, id, signing?, acc)
    end)
  end

  defp encode_claim_field(_tx, name, _id, true, acc) when name in @signing_omit, do: {:cont, acc}
  defp encode_claim_field(tx, name, _id, _signing?, acc) when not is_map_key(tx, name), do: {:cont, acc}

  defp encode_claim_field(tx, name, id, _signing?, acc) do
    case encode_field(id, name, tx[name]) do
      {:ok, bytes} -> {:cont, acc <> bytes}
      :error -> {:halt, :error}
    end
  end

  defp checksum?(bytes) when byte_size(bytes) > 4 do
    size = byte_size(bytes) - 4
    binary_part(double_hash(binary_part(bytes, 0, size)), 0, 4) == binary_part(bytes, size, 4)
  end

  defp checksum?(_), do: false

  defp encode_field(id, "TransactionType", "PaymentChannelClaim"), do: encode_uint(id, 16, @claim_type)
  defp encode_field({2, _} = id, _name, value) when is_integer(value) and value >= 0, do: encode_uint(id, 32, value)

  defp encode_field({5, _} = id, _name, value) when is_binary(value) do
    case hex_bytes(value, 32) do
      {:ok, bytes} -> {:ok, header(id) <> bytes}
      :error -> :error
    end
  end

  defp encode_field({6, _} = id, _name, value) do
    case xrp_amount(value) do
      {:ok, bytes} -> {:ok, header(id) <> bytes}
      :error -> :error
    end
  end

  defp encode_field({7, _} = id, _name, value) when is_binary(value) do
    with {:ok, bytes} <- hex_bytes(value),
         true <- byte_size(bytes) <= 192 do
      {:ok, header(id) <> vl(bytes)}
    else
      _ -> :error
    end
  end

  defp encode_field({8, _} = id, _name, value) when is_binary(value) do
    case account_id(value) do
      {:ok, bytes} -> {:ok, header(id) <> <<20, bytes::binary>>}
      :error -> :error
    end
  end

  defp encode_field(_id, _name, _value), do: :error

  defp encode_uint(id, 16, value) when value in 0..0xFFFF, do: {:ok, header(id) <> <<value::unsigned-16>>}
  defp encode_uint(id, 32, value) when value in 0..0xFFFFFFFF, do: {:ok, header(id) <> <<value::unsigned-32>>}
  defp encode_uint(_id, _size, _value), do: :error

  defp header({type, field}) when type < 16 and field < 16, do: <<type::4, field::4>>
  defp header({type, field}) when type < 16 and field >= 16, do: <<type::4, 0::4, field>>
  defp header({type, field}) when type >= 16 and field < 16, do: <<0::4, field::4, type>>
  defp header({type, field}), do: <<0, type, field>>

  defp xrp_amount(value) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9]\d*)\z/, value), do: xrp_amount(String.to_integer(value)), else: :error
  end

  defp xrp_amount(value) when is_integer(value) and value >= 0 and value < 0x4000000000000000 do
    {:ok, <<0::1, 1::1, 0::1, value::61>>}
  end

  defp xrp_amount(_), do: :error

  defp hex_bytes(value, size) do
    with {:ok, bytes} <- hex_bytes(value),
         true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp hex_bytes("0x" <> rest), do: hex_bytes(rest)
  defp hex_bytes("0X" <> rest), do: hex_bytes(rest)

  defp hex_bytes(value) when is_binary(value) and rem(byte_size(value), 2) == 0 do
    Base.decode16(value, case: :mixed)
  end

  defp hex_bytes(_), do: :error

  defp vl(bytes) when byte_size(bytes) <= 192, do: <<byte_size(bytes), bytes::binary>>
  defp vl(_), do: <<>>
end
