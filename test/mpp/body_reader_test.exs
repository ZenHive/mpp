defmodule MPP.BodyReaderTest do
  use ExUnit.Case, async: true

  alias MPP.BodyReader

  @body ~s({"amount":"1000"})

  defp conn(body \\ @body), do: Plug.Test.conn(:post, "/", body)

  defmodule StalledAdapter do
    @moduledoc false
    # What Bandit answers when a read times out: no bytes, more to come.
    def read_req_body(state, _opts) do
      send(state.test, :read)
      {:more, "", state}
    end
  end

  describe "read_body/2" do
    test "returns the body and keeps it in conn.private.raw_body" do
      assert {:ok, @body, conn} = BodyReader.read_body(conn(), [])
      assert conn.private.raw_body == @body
    end

    test "keeps the whole body when it arrives in several reads" do
      assert {:more, first, conn} = BodyReader.read_body(conn(), length: 5)
      refute Map.has_key?(conn.private, :raw_body)

      {chunks, conn} = read_rest(conn, [first])
      assert IO.iodata_to_binary(chunks) == @body
      assert conn.private.raw_body == @body
    end

    test "returns a kept body without reading the adapter again" do
      {:ok, @body, conn} = BodyReader.read_body(conn(), [])
      assert {:ok, @body, conn} = BodyReader.read_body(conn, [])
      assert {:ok, @body, conn} = BodyReader.read_body(conn, [])
      assert {:ok, "", _conn} = Plug.Conn.read_body(conn)
    end

    test "replays a kept body in :length parts and then starts over" do
      {:ok, @body, conn} = BodyReader.read_body(conn(), [])

      for _round <- 1..2, reduce: conn do
        conn ->
          assert {:more, "{\"amo", conn} = BodyReader.read_body(conn, length: 5)
          {chunks, conn} = read_rest(conn, ["{\"amo"])
          assert IO.iodata_to_binary(chunks) == @body
          conn
      end
    end

    test "works as the Plug.Parsers body reader" do
      opts = Plug.Parsers.init(parsers: [:json], json_decoder: Jason, body_reader: {BodyReader, :read_body, []})
      conn = conn() |> Plug.Conn.put_req_header("content-type", "application/json") |> Plug.Parsers.call(opts)

      assert conn.body_params == %{"amount" => "1000"}
      assert conn.private.raw_body == @body
    end
  end

  describe "fetch/1" do
    test "reads an unread body and keeps it" do
      assert {:ok, @body, conn} = BodyReader.fetch(conn())
      assert conn.private.raw_body == @body
      assert {:ok, @body, ^conn} = BodyReader.fetch(conn)
    end

    test "an absent body is the empty binary" do
      assert {:ok, "", _conn} = BodyReader.fetch(Plug.Test.conn(:get, "/"))
    end

    test "includes the part read_body/2 already returned" do
      {:more, "{\"amo", conn} = BodyReader.read_body(conn(), length: 5)
      assert {:ok, @body, conn} = BodyReader.fetch(conn)
      assert conn.private.raw_body == @body
    end

    test "reads a body after a parser that did not read it" do
      opts = Plug.Parsers.init(parsers: [:json], json_decoder: Jason, body_reader: {BodyReader, :read_body, []})
      conn = Plug.Parsers.call(conn(), opts)

      assert conn.body_params == %{}
      assert {:ok, @body, _conn} = BodyReader.fetch(conn)
    end

    test "fails when the bytes left do not add up to Content-Length" do
      conn = Plug.Conn.put_req_header(conn(), "content-length", "#{byte_size(@body)}")
      assert {:ok, @body, _conn} = BodyReader.fetch(conn)

      {:ok, @body, consumed} = Plug.Conn.read_body(conn)
      assert {:error, _conn} = BodyReader.fetch(consumed)

      {:more, _part, partial} = Plug.Conn.read_body(conn, length: 5)
      assert {:error, _conn} = BodyReader.fetch(partial)
    end

    test "a kept body is checked against Content-Length too" do
      # Something read "{" directly, then the parser read the rest through read_body/2.
      conn = Plug.Conn.put_req_header(conn(), "content-length", "#{byte_size(@body)}")
      {:more, "{", conn} = Plug.Conn.read_body(conn, length: 1)
      {:ok, rest, conn} = BodyReader.read_body(conn, [])

      assert conn.private.raw_body == rest
      assert {:error, ^conn} = BodyReader.fetch(conn)
    end

    test "accepts the Content-Length spellings an adapter accepts" do
      size = byte_size(@body)

      for value <- ["0#{size}", "#{size}, #{size}", " #{size}"] do
        assert {:ok, @body, _conn} = conn() |> Plug.Conn.put_req_header("content-length", value) |> BodyReader.fetch()
      end

      for value <- ["#{size}, #{size + 1}", "#{size}x", "", "-#{size}", "+#{size}"] do
        assert {:error, _conn} = conn() |> Plug.Conn.put_req_header("content-length", value) |> BodyReader.fetch()
      end
    end

    test "returns the connection the failed read left" do
      conn = Plug.Conn.put_req_header(conn(), "content-length", "#{byte_size(@body) + 1}")

      assert {:error, read} = BodyReader.fetch(conn)
      refute read == conn
      assert {:ok, "", _conn} = Plug.Conn.read_body(read)
    end

    test "gives up on a read that returns no bytes" do
      conn = %{conn() | adapter: {StalledAdapter, %{test: self()}}}

      assert {:error, _conn} = BodyReader.fetch(conn)
      assert_received :read
      refute_received :read
    end

    test "a kept body over 8 MB fails like a read one" do
      body = String.duplicate("a", 8_000_001)
      {:ok, ^body, conn} = BodyReader.read_body(conn(body), length: 9_000_000)

      assert conn.private.raw_body == body
      assert {:error, _conn} = BodyReader.fetch(conn)
    end

    test "reads a body of exactly 8 MB" do
      body = String.duplicate("a", 8_000_000)
      assert {:ok, ^body, _conn} = BodyReader.fetch(conn(body))
    end

    test "fails when a parser consumed the body without keeping it" do
      opts = Plug.Parsers.init(parsers: [:json], json_decoder: Jason)
      conn = conn() |> Plug.Conn.put_req_header("content-type", "application/json") |> Plug.Parsers.call(opts)

      assert {:error, ^conn} = BodyReader.fetch(conn)
    end

    test "fails for a body over 8 MB" do
      assert {:error, _conn} = BodyReader.fetch(conn(String.duplicate("a", 8_000_001)))
    end
  end

  defp read_rest(conn, chunks) do
    case BodyReader.read_body(conn, length: 5) do
      {:more, chunk, conn} -> read_rest(conn, chunks ++ [chunk])
      {:ok, chunk, conn} -> {chunks ++ [chunk], conn}
    end
  end
end
