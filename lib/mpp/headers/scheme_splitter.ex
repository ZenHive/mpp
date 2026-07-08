defmodule MPP.Headers.SchemeSplitter do
  @moduledoc false

  # Byte-level state machine that splits a `WWW-Authenticate` header into the
  # individual `Payment ...` challenge segments. Walks the header
  # character-by-character, tracking quoted-string state so commas inside quoted
  # auth-param values are not mistaken for scheme boundaries. Internal support
  # for `MPP.Headers.parse_challenges/1`.

  @doc """
  Split a `WWW-Authenticate` header into its `Payment` challenge segments.

  Returns a list of trimmed segment strings (each a `Payment ...` challenge),
  ignoring non-`Payment` schemes and correctly handling commas inside quoted
  auth-param values.
  """
  @spec split(binary()) :: [binary()]
  def split(header) do
    all_starts = find_scheme_boundaries(header)

    # Identify which boundaries are Payment schemes (exact match, not prefix)
    all_starts
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.filter(fn [pos, _next] -> payment_scheme_at?(header, pos) end)
    |> Enum.map(fn [start, next_boundary] ->
      # Segment ends at the next scheme boundary (any scheme, not just Payment)
      segment_end = next_boundary || byte_size(header)

      header
      |> binary_part(start, segment_end - start)
      |> String.trim_trailing()
      |> String.trim_trailing(",")
      |> String.trim_trailing()
    end)
  end

  # Walks the header byte-by-byte, tracking quoted-string state to find scheme
  # boundary positions. A boundary is a token followed by whitespace, occurring
  # at position 0 or immediately after a comma (outside quotes).
  defp find_scheme_boundaries(header), do: find_boundaries(header, 0, false, true, [])

  # Base case: end of input
  defp find_boundaries(<<>>, _pos, _in_q, _after_sep, acc), do: Enum.reverse(acc)

  # Inside a quoted string: handle escapes, closing quote
  defp find_boundaries(<<"\\", _, rest::binary>>, pos, true, after_sep, acc),
    do: find_boundaries(rest, pos + 2, true, after_sep, acc)

  defp find_boundaries(<<"\"", rest::binary>>, pos, true, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, false, false, acc)

  defp find_boundaries(<<_, rest::binary>>, pos, true, after_sep, acc),
    do: find_boundaries(rest, pos + 1, true, after_sep, acc)

  # Outside quotes: opening quote
  defp find_boundaries(<<"\"", rest::binary>>, pos, false, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, true, false, acc)

  # Comma sets the "after separator" flag
  defp find_boundaries(<<",", rest::binary>>, pos, false, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, false, true, acc)

  # Whitespace after separator is still "after separator"
  defp find_boundaries(<<c, rest::binary>>, pos, false, true, acc) when c in [?\s, ?\t],
    do: find_boundaries(rest, pos + 1, false, true, acc)

  # Non-whitespace after separator (or at start): potential scheme boundary
  defp find_boundaries(<<c, _::binary>> = bin, pos, false, true, acc) when c in ?A..?Z or c in ?a..?z do
    case extract_scheme_token(bin) do
      {:ok, _token, len} ->
        find_boundaries(binary_part(bin, len, byte_size(bin) - len), pos + len, false, false, [pos | acc])

      :not_scheme ->
        find_boundaries(binary_part(bin, 1, byte_size(bin) - 1), pos + 1, false, false, acc)
    end
  end

  # Any other character resets "after separator" flag
  defp find_boundaries(<<_, rest::binary>>, pos, false, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, false, false, acc)

  # Extracts a scheme token (RFC 9110: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ))
  # followed by at least one whitespace character. Returns {:ok, token, total_len}
  # where total_len includes the token + first whitespace char.
  defp extract_scheme_token(bin), do: extract_scheme_token(bin, 0)

  defp extract_scheme_token(bin, len) when len < byte_size(bin) do
    c = :binary.at(bin, len)

    cond do
      c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?+, ?-, ?.] ->
        extract_scheme_token(bin, len + 1)

      len > 0 and c in [?\s, ?\t] ->
        {:ok, binary_part(bin, 0, len), len + 1}

      true ->
        :not_scheme
    end
  end

  defp extract_scheme_token(_bin, _len), do: :not_scheme

  # Checks if the scheme token at `pos` is exactly "Payment" (case-insensitive).
  # Requires that the character after "Payment" is whitespace, preventing prefix
  # matches like "Payments" or "PaymentX".
  defp payment_scheme_at?(header, pos) do
    case binary_part(header, pos, min(8, byte_size(header) - pos)) do
      <<token::binary-size(7), c>> when c in [?\s, ?\t] ->
        String.downcase(token) == "payment"

      _ ->
        false
    end
  end
end
