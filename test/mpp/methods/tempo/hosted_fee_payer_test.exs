defmodule MPP.Methods.Tempo.HostedFeePayerTest do
  use ExUnit.Case, async: true

  import MPP.Test.TempoTestHelpers

  alias MPP.Methods.Tempo
  alias MPP.Methods.Tempo.HostedFeePayer
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @fee_payer_private_key "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @hosted_url "https://sponsor.moderato.tempo.xyz"

  test "build_fill_request mirrors mppx hostedFeePayerRequest shape" do
    {:ok, tx_hex} =
      TempoTxBuilder.build_fee_payer_transfer(
        private_key: @client_private_key,
        token: @token_address,
        recipient: @recipient,
        amount: 1_000_000,
        chain_id: 42_431,
        rpc_url: @rpc_url,
        gas_limit: 1_000_000,
        nonce: 0,
        nonce_key: expiring_nonce_key_int(),
        valid_before: future_valid_before()
      )

    {:ok, tx} = Transaction.deserialize(tx_hex)
    assert {:ok, request} = HostedFeePayer.build_fill_request(tx)
    assert request["type"] == "0x76"
    assert request["feePayer"] == true
    assert is_binary(request["from"])
    assert is_list(request["calls"])
    assert request["nonce"] == "0x0"
    refute Map.has_key?(request, "feeToken")
  end

  test "fill applies hosted response and preserves sender signature" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)
    fill_tx = hosted_fill_response(tx)

    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      response =
        if request["method"] == "eth_fillTransaction" do
          %{"jsonrpc" => "2.0", "result" => %{"tx" => fill_tx}, "id" => request["id"]}
        end

      Req.Test.json(conn, response)
    end)

    assert {:ok, cosigned} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])

    assert cosigned.raw != tx.raw
    assert {:ok, sender_before} = Transaction.sender(tx)
    assert {:ok, sender_after} = Transaction.sender(cosigned)
    assert sender_before == sender_after
  end

  test "fill parses hex-encoded yParity from hosted responses" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)
    fill_tx = hosted_fill_response(tx)
    fill_tx = put_in(fill_tx["feePayerSignature"]["yParity"], "0x1")

    Req.Test.stub(Tempo, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => %{"tx" => fill_tx},
        "id" => 1
      })
    end)

    assert {:ok, cosigned} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])

    assert cosigned.raw != tx.raw
  end

  test "fill rejects missing feeToken in hosted response" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => %{"tx" => %{"feePayerSignature" => %{"r" => "0x1", "s" => "0x2", "yParity" => 0}}},
        "id" => 1
      })
    end)

    assert {:error, "hosted fee payer did not return a feeToken"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill surfaces hosted JSON-RPC errors" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "error" => %{"message" => "policy rejected"}, "id" => 1})
    end)

    assert {:error, "policy rejected"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill surfaces transport failures" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, reason} = HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
    assert reason =~ "hosted fee payer request failed"
  end

  test "fill rejects invalid feeToken address" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => %{
          "tx" => %{
            "feeToken" => "0xdead",
            "feePayerSignature" => %{"r" => "0x1", "s" => "0x2", "yParity" => 0}
          }
        },
        "id" => 1
      })
    end)

    assert {:error, "hosted fee payer did not return a feeToken"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill rejects malformed feePayerSignature" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => %{"tx" => %{"feeToken" => @token_address, "feePayerSignature" => "not-a-signature"}},
        "id" => 1
      })
    end)

    assert {:error, "hosted fee payer returned an invalid feePayerSignature"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill parses v-based recovery id when yParity is absent" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)
    fill_tx = hosted_fill_response(tx)
    fill_tx = update_in(fill_tx, ["feePayerSignature"], fn sig -> Map.delete(sig, "yParity") end)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{"tx" => fill_tx}, "id" => 1})
    end)

    assert {:ok, filled} = HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
    assert filled.raw != tx.raw
  end

  test "fill uses default options" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{"tx" => hosted_fill_response(tx)}, "id" => 1})
    end)

    assert {:ok, _} = HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill falls back to default hosted error message" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1})
    end)

    assert {:error, "hosted fee payer failed to sponsor transaction"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill surfaces non-2xx HTTP status" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, "hosted fee payer request failed with status 500"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill rejects unexpected successful response bodies" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Plug.Conn.send_resp(conn, 200, "not-json")
    end)

    assert {:error, "hosted fee payer failed to sponsor transaction"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill rejects invalid yParity values" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)
    fill_tx = hosted_fill_response(tx)
    fill_tx = put_in(fill_tx["feePayerSignature"]["yParity"], 2)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{"tx" => fill_tx}, "id" => 1})
    end)

    assert {:error, "hosted fee payer returned an invalid feePayerSignature"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "build_fill_request includes non-empty access lists" do
    calldata = transfer_calldata(@recipient, 1_000_000)
    access = [[<<0x01, 0x02>>, [<<0x03>>]]]

    tx_hex =
      build_tempo_tx(
        calls: [build_call(@token_address, calldata)],
        chain_id: 42_431,
        fee_payer: true,
        access_list: access
      )

    {:ok, tx} = Transaction.deserialize(tx_hex)
    assert {:ok, %{"accessList" => ^access}} = HostedFeePayer.build_fill_request(tx)
  end

  test "build_fill_request omits empty call targets and data" do
    tx_hex =
      build_tempo_tx(
        calls: [[<<>>, <<>>, <<>>]],
        chain_id: 42_431,
        fee_payer: false
      )

    {:ok, tx} = Transaction.deserialize(tx_hex)
    assert {:ok, %{"calls" => [%{"value" => "0x0"}]}} = HostedFeePayer.build_fill_request(tx)
  end

  test "build_fill_request includes optional gas and validity fields" do
    calldata = transfer_calldata(@recipient, 1_000_000)

    tx_hex =
      build_tempo_tx(
        calls: [build_call(@token_address, calldata)],
        chain_id: 42_431,
        fee_payer: true
      )

    {:ok, tx} = Transaction.deserialize(tx_hex)
    assert {:ok, request} = HostedFeePayer.build_fill_request(tx)
    assert String.starts_with?(request["gas"], "0x")
    assert String.starts_with?(request["validBefore"], "0x")
    refute Map.has_key?(request, "validAfter")
  end

  test "fill rejects corrupt signature hex components" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => %{
          "tx" => %{
            "feeToken" => @token_address,
            "feePayerSignature" => %{"r" => "0xzz", "s" => "0x2", "yParity" => 0}
          }
        },
        "id" => 1
      })
    end)

    assert {:error, "hosted fee payer returned an invalid feePayerSignature"} =
             HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
  end

  test "fill accepts feeToken without 0x prefix" do
    {:ok, tx_hex} = build_unsigned_fee_payer_tx()
    {:ok, tx} = Transaction.deserialize(tx_hex)
    fill_tx = Map.put(hosted_fill_response(tx), "feeToken", String.replace_prefix(@token_address, "0x", ""))

    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => %{"tx" => fill_tx}, "id" => 1})
    end)

    assert {:ok, filled} = HostedFeePayer.fill(tx, @hosted_url, req_options: [plug: {Req.Test, Tempo}])
    assert filled.raw != tx.raw
  end

  defp build_unsigned_fee_payer_tx do
    TempoTxBuilder.build_fee_payer_transfer(
      private_key: @client_private_key,
      token: @token_address,
      recipient: @recipient,
      amount: 1_000_000,
      chain_id: 42_431,
      rpc_url: @rpc_url,
      gas_limit: 1_000_000,
      nonce: 0,
      nonce_key: expiring_nonce_key_int(),
      valid_before: future_valid_before()
    )
  end

  defp hosted_fill_response(tx) do
    fee_payer_key = Base.decode16!(@fee_payer_private_key, case: :mixed)
    fee_token = Base.decode16!(String.replace_prefix(@token_address, "0x", ""), case: :mixed)

    {:ok, cosigned} = Transaction.cosign_fee_payer(tx, fee_payer_key, fee_token)
    [y_parity, r_bin, s_bin] = Enum.at(cosigned.fields, 11)

    %{
      "feeToken" => @token_address,
      "feePayerSignature" => %{
        "yParity" => if(y_parity == <<1>>, do: 1, else: 0),
        "v" => if(y_parity == <<1>>, do: "0x1c", else: "0x1b"),
        "r" => "0x" <> Base.encode16(r_bin, case: :lower),
        "s" => "0x" <> Base.encode16(s_bin, case: :lower)
      }
    }
  end
end
