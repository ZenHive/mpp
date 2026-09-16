defmodule MPP.Methods.EVMPermit2Test do
  use ExUnit.Case, async: true

  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Methods.EVM.Permit2
  alias MPP.Test.EVMAuthorization

  @token "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @recipient "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @split "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
  @contract "0x000000000022D473030F116dDEE9F6B43aC78BA3"

  setup do
    key = EVMAuthorization.private_key()
    owner = String.downcase(EVMAuthorization.signer_address())

    charge = %Charge{
      amount: "7",
      currency: @token,
      recipient: @recipient,
      method_details: %{
        "permit2" => true,
        "private_key" => key,
        "chain_id" => 11_155_111,
        "rpc_url" => "http://unused",
        "challenge_id" => "challenge",
        "realm" => "merchant"
      }
    }

    {:ok, payload} = Permit2.sign(charge, key, owner, "123", "2000000000")
    {:ok, charge: charge, payload: payload, owner: owner, key: key}
  end

  test "off-chain single signing recovers payer and binds the optional source", ctx do
    assert {:ok, ctx.owner} == Permit2.verify(ctx.payload, ctx.charge)
    assert ctx.payload["witness"]["externalId"] == ""
    charge = config(ctx.charge, "credential_source", "did:pkh:eip155:11155111:" <> ctx.owner)
    assert {:ok, ctx.owner} == Permit2.verify(ctx.payload, charge)
    assert {:ok, ctx.owner} == Permit2.verify(ctx.payload, put_in(charge.method_details["credential_source"], nil))

    for source <- ["did:pkh:eip155:1:" <> ctx.owner, "did:pkh:eip155:11155111:" <> @recipient, "bad", 1] do
      assert {:error, error} = Permit2.verify(ctx.payload, put_in(charge.method_details["credential_source"], source))
      assert error.detail == "Permit2 source does not match signer"
    end
  end

  test "ordered splits are subtracted from total and included in permissions", ctx do
    splits = [%{"recipient" => @split, "amount" => "2", "memo" => "fee"}, %{"recipient" => @recipient, "amount" => "1"}]
    charge = %{ctx.charge | external_id: "order-7", method_details: Map.put(ctx.charge.method_details, "splits", splits)}
    assert {:ok, payload} = Permit2.sign(charge, ctx.key, ctx.owner, "0", "2000000000")
    assert Enum.map(payload["transferDetails"], & &1["requestedAmount"]) == ["4", "2", "1"]
    assert Enum.map(payload["permit"]["permitted"], & &1["amount"]) == ["4", "2", "1"]
    assert payload["witness"]["externalId"] == "order-7"
    assert {:ok, ctx.owner} == Permit2.verify(payload, charge)
    assert {:ok, "0xfe8ec1a7" <> _} = Permit2.calldata(payload, ctx.owner)
    assert {:error, error} = Permit2.verify(Map.update!(payload, "transferDetails", &Enum.reverse/1), charge)
    assert error.detail == "Permit2 ordered transfers do not match charge"
    assert EVM.challenge_method_details(charge)["splits"] == splits
    assert EVM.challenge_method_details(charge)["credentialTypes"] == ["permit2"]
    assert {:error, hash_error} = EVM.verify(%{"hash" => "0x" <> String.duplicate("ab", 32)}, charge)
    assert hash_error.detail == "EVM hash credentials do not support splits"
  end

  test "advertisement is opt-in; authorization/hash stay as before for ordinary charges", ctx do
    assert EVM.challenge_method_details(ctx.charge)["credentialTypes"] == ["permit2", "authorization", "hash"]

    for config <- [Map.delete(ctx.charge.method_details, "permit2"), Map.put(ctx.charge.method_details, "permit2", false)] do
      assert EVM.challenge_method_details(%{ctx.charge | method_details: config})["credentialTypes"] == [
               "authorization",
               "hash"
             ]
    end

    assert EVM.challenge_method_details(config(ctx.charge, "private_key", nil))["credentialTypes"] == [
             "hash"
           ]

    assert EVM.challenge_method_details(%{ctx.charge | currency: @split})["credentialTypes"] == ["permit2", "hash"]
    details = EVM.challenge_method_details(ctx.charge)
    assert details |> Map.keys() |> Enum.sort() == ["chainId", "credentialTypes", "permit2Address"]
    assert details["permit2Address"] == @contract
    refute Permit2.offered?(%{ctx.charge | method_details: nil})

    for {key, value} <- [
          {"private_key", "bad"},
          {"chain_id", nil},
          {"chain_id", 0},
          {"rpc_url", nil},
          {"permit2_address", "bad"}
        ] do
      charge = config(ctx.charge, key, value)
      refute Permit2.offered?(charge)
      assert {:error, error} = Permit2.verify(ctx.payload, charge)
      assert error.detail == "Permit2 settlement is not configured"
    end

    refute Permit2.offered?(%{ctx.charge | currency: "ETH"})
  end

  test "all challenge and domain components affect authorization", ctx do
    for charge <- [
          %{ctx.charge | external_id: "other"},
          config(ctx.charge, "challenge_id", "other"),
          config(ctx.charge, "realm", "other")
        ] do
      assert {:error, error} = Permit2.verify(ctx.payload, charge)
      assert error.detail == "Permit2 witness does not match challenge"
    end

    {:ok, original} = Permit2.digest(ctx.payload, ctx.charge, ctx.owner)

    for charge <- [
          config(ctx.charge, "chain_id", 1),
          config(ctx.charge, "permit2_address", @recipient)
        ] do
      assert {:ok, digest} = Permit2.digest(ctx.payload, charge, ctx.owner)
      refute digest == original
    end

    assert {:ok, other} = Permit2.digest(ctx.payload, ctx.charge, @recipient)
    refute other == original
    assert {:error, _} = Permit2.digest(ctx.payload, config(ctx.charge, "chain_id", nil), ctx.owner)
    assert {:error, _} = Permit2.digest(ctx.payload, ctx.charge, "bad")
    assert {:ok, "0x137c29fe" <> _} = Permit2.calldata(ctx.payload, ctx.owner)
  end

  test "mismatching recipient, token, amount, or insufficient permission fails before RPC", ctx do
    for payload <- [
          put_in(ctx.payload, ["permit", "permitted"], [%{"token" => @split, "amount" => "7"}]),
          put_in(ctx.payload, ["permit", "permitted"], [%{"token" => @token, "amount" => "6"}]),
          put_in(ctx.payload, ["transferDetails"], [%{"to" => @split, "requestedAmount" => "7"}]),
          put_in(ctx.payload, ["transferDetails"], [%{"to" => @recipient, "requestedAmount" => "6"}])
        ] do
      assert {:error, error} = EVM.verify(payload, ctx.charge)
      assert error.detail == "Permit2 ordered transfers do not match charge"
    end

    assert {:error, error} = Permit2.verify(put_in(ctx.payload, ["permit", "deadline"], "0"), ctx.charge)
    assert error.detail == "Permit2 permit expired"
  end

  test "malformed JSON fields and uint256 boundaries return errors", ctx do
    bad_fields = [
      {["type"], "hash"},
      {["permit"], nil},
      {["transferDetails"], nil},
      {["witness"], nil},
      {["permit", "permitted"], []},
      {["permit", "permitted"], %{}},
      {["permit", "permitted"], [nil]},
      {["permit", "permitted"], [%{"token" => @token, "amount" => "0x7"}]},
      {["permit", "permitted"], [%{"token" => "0x" <> String.duplicate("00", 20), "amount" => "7"}]},
      {["permit", "permitted"], [%{"token" => "0x" <> String.duplicate("zz", 20), "amount" => "7"}]},
      {["transferDetails"], [nil]},
      {["transferDetails"], []},
      {["witness", "challengeHash"], "0x" <> String.duplicate("zz", 32)},
      {["witness", "challengeHash"], "bad"},
      {["witness", "externalId"], nil}
    ]

    for {path, value} <- bad_fields do
      assert {:error, error} = Permit2.verify(put_in(ctx.payload, path, value), ctx.charge)
      assert error.type =~ "invalid-payload"
    end

    for value <- [nil, 1, "-1", "+1", "01", "", "1x", "1.0", String.duplicate("9", 79), Integer.to_string(2 ** 256)] do
      for field <- ["nonce", "deadline"] do
        assert {:error, _} = Permit2.digest(put_in(ctx.payload, ["permit", field], value), ctx.charge, ctx.owner)
      end
    end

    max = Integer.to_string(2 ** 256 - 1)
    assert {:ok, _} = Permit2.sign(ctx.charge, ctx.key, ctx.owner, max, max)

    for signature <- [nil, "bad", "0x" <> String.duplicate("00", 65), "0x" <> String.duplicate("00", 64) <> "1b"] do
      assert {:error, _} = Permit2.verify(Map.put(ctx.payload, "signature", signature), ctx.charge)
    end

    assert {:error, _} = Permit2.calldata(ctx.payload, "bad")
  end

  test "invalid charge shape never produces a client signature", ctx do
    for splits <- [
          [],
          nil,
          %{},
          [nil],
          [%{"recipient" => @split, "amount" => "7"}],
          [%{"recipient" => @split, "amount" => "8"}],
          [%{"recipient" => @split, "amount" => "1", "memo" => 1}],
          [%{"recipient" => @split, "amount" => "1", "memo" => String.duplicate("x", 257)}],
          List.duplicate(%{"recipient" => @split, "amount" => "0"}, 11)
        ] do
      assert {:error, _} =
               Permit2.sign(config(ctx.charge, "splits", splits), ctx.key, ctx.owner, "0", "2000000000")
    end

    for charge <- [
          %{ctx.charge | amount: "0"},
          %{ctx.charge | recipient: nil},
          %{ctx.charge | external_id: 1},
          %{ctx.charge | currency: "ETH"},
          config(ctx.charge, "challenge_id", nil),
          config(ctx.charge, "realm", "")
        ] do
      assert {:error, _} = Permit2.sign(charge, ctx.key, ctx.owner, "0", "2000000000")
    end

    assert {:error, _} = Permit2.sign(ctx.charge, "bad", ctx.owner, "0", "2000000000")
    assert {:error, _} = Permit2.sign(ctx.charge, ctx.key, ctx.owner, "bad", "2000000000")
  end

  defp config(charge, key, value), do: %{charge | method_details: Map.put(charge.method_details, key, value)}
end
