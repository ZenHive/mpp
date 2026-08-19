defmodule MPP.Test.WebSocketLoopback do
  # Minimal RFC 6455 loopback for Task 48 e2e tests. Not a production WS stack.
  @moduledoc false

  alias MPP.Transports.WebSocket

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @recv_timeout 2_000

  @type server :: %{port: :inet.port_number(), listen: :gen_tcp.socket(), pid: pid()}
  @type client :: %{socket: :gen_tcp.socket(), buf: binary()}

  @spec start(keyword()) :: {:ok, server()}
  def start(opts) when is_list(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()
    pid = spawn_link(fn -> accept_loop(listen, opts, parent) end)
    {:ok, %{port: port, listen: listen, pid: pid}}
  end

  @spec stop(server()) :: :ok
  def stop(%{listen: listen, pid: pid}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(listen)
    :ok
  end

  @spec connect(:inet.port_number()) :: {:ok, client()} | {:error, term()}
  def connect(port) when is_integer(port) do
    with {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 1_000) do
      key = Base.encode64(:crypto.strong_rand_bytes(16))

      request = [
        "GET / HTTP/1.1\r\n",
        "Host: 127.0.0.1:#{port}\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n"
      ]

      :ok = :gen_tcp.send(socket, request)

      case recv_http(socket, <<>>) do
        {:ok, _headers, leftover} -> {:ok, %{socket: socket, buf: leftover}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec send_text(client(), String.t()) :: :ok | {:error, term()}
  def send_text(%{socket: socket}, text) when is_binary(text) do
    :gen_tcp.send(socket, encode_frame(0x1, text, masked: true))
  end

  @spec recv_text(client(), timeout()) :: {:ok, String.t(), client()} | {:error, term()}
  def recv_text(%{socket: socket, buf: buf} = client, timeout \\ @recv_timeout) do
    case recv_frame(socket, buf, timeout) do
      {:ok, text, rest} -> {:ok, text, %{client | buf: rest}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(client()) :: :ok
  def close(%{socket: socket}), do: :gen_tcp.close(socket)

  defp accept_loop(listen, opts, parent) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        spawn_link(fn -> serve(socket, opts, parent) end)
        accept_loop(listen, opts, parent)

      {:error, :timeout} ->
        accept_loop(listen, opts, parent)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, opts, parent) do
    case recv_http(socket, <<>>) do
      {:ok, headers, _leftover} ->
        key = ws_key(headers)
        accept = ws_accept(key)

        response =
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"

        :ok = :gen_tcp.send(socket, response)
        run_script(socket, opts, parent)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp run_script(socket, opts, parent) do
    case Keyword.get(opts, :mode, :adapter) do
      :adapter -> adapter_loop(socket, Keyword.fetch!(opts, :session))
      :script -> script_loop(socket, Keyword.fetch!(opts, :script), parent)
    end
  end

  defp adapter_loop(socket, session) do
    {session, frames} = WebSocket.open(session)
    Enum.each(frames, fn text -> :gen_tcp.send(socket, encode_frame(0x1, text, masked: false)) end)
    adapter_recv(socket, session, <<>>)
  end

  defp adapter_recv(socket, session, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> dispatch_inbound(socket, session, acc <> data)
      {:error, _reason} -> :gen_tcp.close(socket)
    end
  end

  defp dispatch_inbound(socket, session, buffer) do
    case consume_frames(buffer, masked: true) do
      {:ok, frames, rest} ->
        session = Enum.reduce(frames, session, fn frame, session -> push_inbound(socket, session, frame) end)
        adapter_recv(socket, session, rest)

      {:error, :incomplete, rest} ->
        adapter_recv(socket, session, rest)

      {:error, :closed} ->
        :gen_tcp.close(socket)
    end
  end

  defp push_inbound(socket, session, {:text, text}) do
    {session, replies} = WebSocket.handle_text(text, session)
    Enum.each(replies, fn reply -> :gen_tcp.send(socket, encode_frame(0x1, reply, masked: false)) end)
    session
  end

  defp push_inbound(socket, session, :close) do
    :gen_tcp.send(socket, encode_frame(0x8, <<>>, masked: false))
    :gen_tcp.close(socket)
    session
  end

  defp push_inbound(socket, session, {:ping, payload}) do
    :gen_tcp.send(socket, encode_frame(0xA, payload, masked: false))
    session
  end

  defp push_inbound(_socket, session, _other), do: session

  defp script_loop(socket, script, parent) do
    Enum.each(script, fn
      {:send, text} when is_binary(text) ->
        :gen_tcp.send(socket, encode_frame(0x1, text, masked: false))

      :recv ->
        case recv_frame(socket, <<>>, 5_000) do
          {:ok, text, _rest} -> send(parent, {:ws_script_recv, text})
          {:error, reason} -> send(parent, {:ws_script_error, reason})
        end

      :close ->
        :gen_tcp.send(socket, encode_frame(0x8, <<>>, masked: false))
        :gen_tcp.close(socket)
    end)
  end

  defp recv_http(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [headers, leftover] ->
        {:ok, headers, leftover}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, data} -> recv_http(socket, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ws_key(headers) do
    headers
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(&ws_key_line/1)
  end

  defp ws_key_line(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> ws_key_value(name, value)
      _other -> nil
    end
  end

  defp ws_key_value(name, value) do
    if String.downcase(String.trim(name)) == "sec-websocket-key", do: String.trim(value)
  end

  defp ws_accept(key) when is_binary(key) do
    :sha |> :crypto.hash(key <> @guid) |> Base.encode64()
  end

  defp recv_frame(socket, acc, timeout) do
    case decode_frame(acc, []) do
      {:ok, {:text, text}, rest} ->
        {:ok, text, rest}

      {:ok, _other, rest} ->
        recv_frame(socket, rest, timeout)

      {:error, :incomplete} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} -> recv_frame(socket, acc <> data, timeout)
          {:error, reason} -> {:error, reason}
        end

      {:error, :closed} ->
        {:error, :closed}
    end
  end

  defp consume_frames(buffer, opts, acc \\ [])

  defp consume_frames(<<>>, _opts, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp consume_frames(buffer, opts, acc) do
    case decode_frame(buffer, opts) do
      {:ok, frame, rest} -> consume_frames(rest, opts, [frame | acc])
      {:error, :incomplete} -> {:error, :incomplete, buffer}
      {:error, :closed} -> {:error, :closed}
    end
  end

  defp encode_frame(opcode, payload, opts) do
    masked? = Keyword.get(opts, :masked, false)
    len = byte_size(payload)

    len_bytes =
      cond do
        len < 126 -> <<len::7>>
        len < 65_536 -> <<126::7, len::16>>
        true -> <<127::7, len::64>>
      end

    if masked? do
      mask = :crypto.strong_rand_bytes(4)
      <<1::1, 0::3, opcode::4, 1::1, len_bytes::bitstring, mask::binary, mask_payload(payload, mask)::binary>>
    else
      <<1::1, 0::3, opcode::4, 0::1, len_bytes::bitstring, payload::binary>>
    end
  end

  defp decode_frame(<<fin::1, _rsv::3, opcode::4, mask_bit::1, 127::7, len::64, rest::binary>>, opts) when fin == 1 do
    take_payload(opcode, mask_bit, len, rest, opts)
  end

  defp decode_frame(<<fin::1, _rsv::3, opcode::4, mask_bit::1, 126::7, len::16, rest::binary>>, opts) when fin == 1 do
    take_payload(opcode, mask_bit, len, rest, opts)
  end

  defp decode_frame(<<fin::1, _rsv::3, opcode::4, mask_bit::1, len::7, rest::binary>>, opts)
       when fin == 1 and len < 126 do
    take_payload(opcode, mask_bit, len, rest, opts)
  end

  defp decode_frame(_buffer, _opts), do: {:error, :incomplete}

  defp take_payload(opcode, 1, len, rest, _opts) when byte_size(rest) >= len + 4 do
    <<mask::binary-size(4), payload::binary-size(^len), rem::binary>> = rest
    finish_frame(opcode, mask_payload(payload, mask), rem)
  end

  defp take_payload(opcode, 0, len, rest, _opts) when byte_size(rest) >= len do
    <<payload::binary-size(^len), rem::binary>> = rest
    finish_frame(opcode, payload, rem)
  end

  defp take_payload(_opcode, _mask, _len, _rest, _opts), do: {:error, :incomplete}

  defp finish_frame(0x1, payload, rest), do: {:ok, {:text, payload}, rest}
  defp finish_frame(0x8, _payload, _rest), do: {:error, :closed}
  defp finish_frame(0x9, payload, rest), do: {:ok, {:ping, payload}, rest}
  defp finish_frame(0xA, _payload, rest), do: {:ok, :pong, rest}
  defp finish_frame(_opcode, _payload, rest), do: {:ok, :other, rest}

  defp mask_payload(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end
end
