defmodule MPP.Session.PayloadTest do
  use ExUnit.Case, async: true

  alias MPP.Session.Payload

  @channel_id "0x5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"
  @transaction "0x76abcd"
  @signature "0x729359a3e060a6822af39785f1c806d820f6fb25bf94cb075038c60dc33fb37262db7e618685db686c2f870ead2e955ae0d907dde5739607d15ef1dafc65a31b1c"
  @payer "0x1111111111111111111111111111111111111111"
  @payee "0x2222222222222222222222222222222222222222"
  @operator "0x0000000000000000000000000000000000000000"
  @token "0x3333333333333333333333333333333333333333"
  @salt "0x0000000000000000000000000000000000000000000000000000000000000001"
  @authorized_signer "0x4444444444444444444444444444444444444444"
  @expiring_nonce_hash "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  describe "parse/1 and to_map/1" do
    test "parses open, topUp, voucher, and close wire payloads" do
      assert {:ok, open} = Payload.parse(open_map())
      assert open.action == :open
      assert open.type == "transaction"
      assert open.channel_id == @channel_id
      assert open.cumulative_amount == 100
      assert open.transaction == @transaction
      assert open.signature == @signature

      assert {:ok, top_up} = Payload.parse(top_up_map())
      assert top_up.action == :top_up
      assert top_up.additional_deposit == 200
      assert top_up.type == "transaction"

      assert {:ok, voucher} = Payload.parse(voucher_map())
      assert voucher.action == :voucher
      assert voucher.cumulative_amount == 300
      refute voucher.type

      assert {:ok, close} = Payload.parse(close_map())
      assert close.action == :close
      assert close.cumulative_amount == 400
    end

    test "round-trips camelCase JSON including optional descriptor" do
      map = Map.put(open_map(), "descriptor", descriptor_map())
      assert {:ok, payload} = Payload.parse(map)
      assert payload.descriptor.payer == @payer
      assert payload.descriptor.payee == @payee
      assert payload.descriptor.authorized_signer == @authorized_signer

      assert Payload.to_map(payload)["action"] == "open"
      assert Payload.to_map(payload)["cumulativeAmount"] == "100"
      assert Payload.to_map(payload)["descriptor"]["authorizedSigner"] == @authorized_signer
    end

    test "rejects invalid actions, types, and amounts" do
      assert {:error, :invalid_action} = Payload.parse(Map.put(open_map(), "action", "top_up"))
      assert {:error, :invalid_payload} = Payload.parse("open")

      assert {:error, :invalid_transaction_type} =
               Payload.parse(Map.put(open_map(), "type", "hash"))

      assert {:error, {:invalid_amount, :cumulative_amount}} =
               Payload.parse(Map.put(open_map(), "cumulativeAmount", "1.5"))

      assert {:error, {:invalid_amount, :cumulative_amount}} =
               Payload.parse(Map.put(open_map(), "cumulativeAmount", -1))

      assert {:error, {:invalid_hex, :transaction}} =
               Payload.parse(Map.put(open_map(), "transaction", "not-hex"))

      assert {:error, {:invalid_hex, :transaction}} =
               Payload.parse(Map.put(open_map(), "transaction", 12))

      assert {:error, {:invalid_channel_id, "0xabc"}} =
               Payload.parse(Map.put(open_map(), "channelId", "0xabc"))
    end

    test "accepts integer amounts, optional authorizedSigner, and settlementRoute" do
      map =
        open_map()
        |> Map.put("cumulativeAmount", 80)
        |> Map.put("authorizedSigner", @authorized_signer)
        |> Map.put("settlementRoute", %{
          "adapter" => @payer,
          "recipient" => @payee,
          "targetToken" => @token,
          "routeSalt" => @expiring_nonce_hash
        })

      assert {:ok, payload} = Payload.parse(map)
      assert payload.cumulative_amount == 80
      assert payload.authorized_signer == @authorized_signer
      assert payload.settlement_route.adapter == @payer
      assert Payload.to_map(payload)["settlementRoute"]["targetToken"] == @token
    end

    test "rejects malformed descriptor and settlementRoute objects" do
      assert {:error, :invalid_descriptor} = Payload.parse(Map.put(open_map(), "descriptor", "nope"))

      assert {:error, {:invalid_address, :payer}} =
               Payload.parse(Map.put(open_map(), "descriptor", Map.put(descriptor_map(), "payer", "0xdead")))

      assert {:error, {:invalid_hash, :salt}} =
               Payload.parse(Map.put(open_map(), "descriptor", Map.put(descriptor_map(), "salt", "0x01")))

      assert {:error, :invalid_settlement_route} =
               Payload.parse(Map.put(open_map(), "settlementRoute", "nope"))
    end
  end

  defp open_map do
    %{
      "action" => "open",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => @transaction,
      "cumulativeAmount" => "100",
      "signature" => @signature
    }
  end

  defp top_up_map do
    %{
      "action" => "topUp",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => @transaction,
      "additionalDeposit" => "200"
    }
  end

  defp voucher_map do
    %{
      "action" => "voucher",
      "channelId" => @channel_id,
      "cumulativeAmount" => "300",
      "signature" => @signature
    }
  end

  defp close_map do
    %{
      "action" => "close",
      "channelId" => @channel_id,
      "cumulativeAmount" => "400",
      "signature" => @signature
    }
  end

  defp descriptor_map do
    %{
      "payer" => @payer,
      "payee" => @payee,
      "operator" => @operator,
      "token" => @token,
      "salt" => @salt,
      "authorizedSigner" => @authorized_signer,
      "expiringNonceHash" => @expiring_nonce_hash
    }
  end
end
