defmodule MPP.BodyReader do
  @moduledoc """
  Request body reader that keeps the raw body in `conn.private.raw_body`.

  A challenge with a `digest` binds the request body, so `MPP.Plug` compares
  the body's SHA-256 with it before the payment is verified, for native and
  x402 payments alike. That needs the bytes as they arrived, which
  `Plug.Parsers` discards after parsing.

  Mount it as the parser's body reader when parsers run before the payment plug:

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {MPP.BodyReader, :read_body, []}

  When the payment plug runs first it reads the body itself through `fetch/1`;
  a later `Plug.Parsers` with this reader gets the same bytes back.

  ## Limits

    * `Plug.Parsers` does not use `:body_reader` for `multipart/*`, and a
      multipart parser reads the adapter directly. A route with a digest cannot
      take a multipart body through `Plug.Parsers` on either side of the
      payment plug.
    * A body that something read with `Plug.Conn.read_body/2` directly is gone.
      `fetch/1` refuses a body, kept or read, whose size is not the request's
      `Content-Length`, and an empty one when a parser produced parameters.
      A request without `Content-Length` (chunked, HTTP/2) gives no such sign:
      what `fetch/1` returns is what was left to read, so nothing before the
      payment plug may read such a body except through `read_body/2`.
    * `fetch/1` returns at most 8 MB, also for a kept body, and gives up when
      a read returns no bytes or the body takes longer than 15 seconds.
  """

  use Descripex, namespace: "/protocol"

  alias Plug.Conn

  # Plug.Conn.read_body/2's own default.
  @default_length 8_000_000
  @read_deadline_ms 15_000

  api(
    :read_body,
    "Read the request body as `Plug.Conn.read_body/2` does and keep the complete body in `conn.private.raw_body`. A body already kept there is replayed instead of reading again.",
    params: [
      conn: [kind: :value, description: "Plug connection"],
      opts: [kind: :value, description: "`Plug.Conn.read_body/2` options (`:length`, `:read_length`, `:read_timeout`)"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, binary, conn}`, `{:more, binary, conn}` or `{:error, reason}`, as `Plug.Conn.read_body/2`"
    }
  )

  @doc """
  Read the request body and keep the complete body in `conn.private.raw_body`.

  Has the contract of `Plug.Conn.read_body/2`, so it can be given to
  `Plug.Parsers` as `:body_reader`. A body already kept in the connection is
  replayed without touching the adapter, `:length` bytes per call; after the
  last part the replay starts over.
  """
  @spec read_body(Conn.t(), keyword()) :: {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()} | {:error, term()}
  def read_body(conn, opts \\ [])

  def read_body(%Conn{private: %{raw_body: body}} = conn, opts) when is_binary(body) do
    length = Keyword.get(opts, :length, @default_length)
    offset = Map.get(conn.private, :mpp_raw_body_offset, 0)
    left = byte_size(body) - offset

    if left <= length do
      {:ok, binary_part(body, offset, left), Conn.put_private(conn, :mpp_raw_body_offset, 0)}
    else
      {:more, binary_part(body, offset, length), Conn.put_private(conn, :mpp_raw_body_offset, offset + length)}
    end
  end

  def read_body(%Conn{} = conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = IO.iodata_to_binary([pending(conn), chunk])
        {:ok, chunk, conn |> Conn.put_private(:raw_body, body) |> Conn.put_private(:mpp_raw_body_pending, [])}

      {:more, chunk, conn} ->
        {:more, chunk, Conn.put_private(conn, :mpp_raw_body_pending, [pending(conn), chunk])}

      {:error, _reason} = error ->
        error
    end
  end

  api(
    :fetch,
    "Return the complete raw request body: the one kept in `conn.private.raw_body`, or the body read now (after any part `read_body/2` already returned) and kept there. Fails when the body exceeds 8 MB, cannot be read in time, or does not add up to the request's `Content-Length`.",
    params: [conn: [kind: :value, description: "Plug connection"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, body, conn}` or `{:error, conn}`"}
  )

  @doc """
  Return the complete raw request body, reading it when it was not read yet.

  `{:error, conn}` means the complete bytes cannot be had: the body is larger
  than 8 MB, the read failed or stalled, the bytes do not add up to
  `Content-Length`, or a parser produced parameters and left no bytes. Go on
  with the returned connection either way. See the module's limits.
  """
  @spec fetch(Conn.t()) :: {:ok, binary(), Conn.t()} | {:error, Conn.t()}
  def fetch(%Conn{private: %{raw_body: body}} = conn) when is_binary(body) do
    if byte_size(body) <= @default_length and complete?(conn, body), do: {:ok, body, conn}, else: {:error, conn}
  end

  def fetch(%Conn{} = conn) do
    read = pending(conn)
    deadline = System.monotonic_time(:millisecond) + @read_deadline_ms

    case read_rest(conn, read, IO.iodata_length(read), deadline) do
      {:ok, body, conn} ->
        if complete?(conn, body),
          do: {:ok, body, conn |> Conn.put_private(:raw_body, body) |> Conn.put_private(:mpp_raw_body_pending, [])},
          else: {:error, conn}

      {:error, conn} ->
        {:error, conn}
    end
  end

  defp read_rest(conn, _read, size, _deadline) when size > @default_length, do: {:error, conn}

  defp read_rest(conn, read, size, deadline) do
    case Conn.read_body(conn, length: @default_length - size + 1) do
      {:ok, chunk, conn} when size + byte_size(chunk) <= @default_length ->
        {:ok, IO.iodata_to_binary([read, chunk]), conn}

      {:ok, _chunk, conn} ->
        {:error, conn}

      # An adapter answers a timed-out read with an empty part.
      {:more, <<>>, conn} ->
        {:error, conn}

      {:more, chunk, conn} ->
        if System.monotonic_time(:millisecond) < deadline,
          do: read_rest(conn, [read, chunk], size + byte_size(chunk), deadline),
          else: {:error, conn}

      {:error, _reason} ->
        {:error, conn}
    end
  end

  # Whether `body` is the whole request body, as far as the request can tell.
  defp complete?(conn, body) do
    case Conn.get_req_header(conn, "content-length") do
      [] -> body != "" or not parsed_params?(conn.body_params)
      values -> content_length(values) == {:ok, byte_size(body)}
    end
  end

  # One length; a list repeating the same length counts as that length, as the
  # adapters read it (RFC 9110 section 8.6).
  defp content_length(values) do
    lengths =
      values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> decimal()))
      |> Enum.uniq()

    case lengths do
      [length] when is_integer(length) -> {:ok, length}
      _other -> :error
    end
  end

  defp decimal(text) do
    if text != "" and text =~ ~r/\A[0-9]{1,19}\z/, do: String.to_integer(text), else: :error
  end

  # `Plug.Parsers` sets an empty map without reading a body it does not parse.
  defp parsed_params?(%Conn.Unfetched{}), do: false
  defp parsed_params?(params), do: map_size(params) > 0

  defp pending(conn), do: Map.get(conn.private, :mpp_raw_body_pending, [])
end
