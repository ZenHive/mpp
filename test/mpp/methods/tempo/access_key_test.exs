defmodule MPP.Methods.Tempo.AccessKeyTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.AccessKey

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @account "0x1a642f0E3c3aF545E7AcBD38b07251B3990914F1"
  @access_key "0x5050a4f4b3f9338c3472dcc01a87c76a144b3c9c"

  setup do
    Req.Test.stub(AccessKeyStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => build_get_key_result(false),
        "id" => request["id"]
      })
    end)

    :ok
  end

  test "active?/3 returns true for non-revoked unexpired key metadata" do
    assert AccessKey.active?(@account, @access_key,
             rpc_url: @rpc_url,
             req_options: [plug: {Req.Test, AccessKeyStub}]
           )
  end

  test "active?/3 returns false when key is revoked" do
    Req.Test.stub(AccessKeyStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => build_get_key_result(true),
        "id" => request["id"]
      })
    end)

    refute AccessKey.active?(@account, @access_key,
             rpc_url: @rpc_url,
             req_options: [plug: {Req.Test, AccessKeyStub}]
           )
  end

  test "active?/3 returns false when RPC reverts" do
    Req.Test.stub(AccessKeyStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "error" => %{"code" => 3, "message" => "execution reverted"},
        "id" => request["id"]
      })
    end)

    refute AccessKey.active?(@account, @access_key,
             rpc_url: @rpc_url,
             req_options: [plug: {Req.Test, AccessKeyStub}]
           )
  end

  defp build_get_key_result(revoked?) do
    key = Base.decode16!(String.replace_prefix(@access_key, "0x", ""), case: :mixed)
    expiry_bin = 4_000_000_000 |> :binary.encode_unsigned() |> pad32()
    revoked_bin = if(revoked?, do: pad32(1), else: pad32(0))

    words = [
      pad32(0),
      :binary.copy(<<0>>, 12) <> key,
      expiry_bin,
      pad32(0),
      revoked_bin
    ]

    "0x" <> Base.encode16(IO.iodata_to_binary(words), case: :lower)
  end

  defp pad32(value) when is_integer(value), do: value |> :binary.encode_unsigned() |> pad32()
  defp pad32(bin) when byte_size(bin) <= 32, do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin
end
