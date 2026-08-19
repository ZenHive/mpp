defmodule MPP.Methods.Tempo.KeyAuthorizationTest do
  use ExUnit.Case, async: true

  alias Cartouche.Hash
  alias MPP.Methods.Tempo.KeyAuthorization
  alias MPP.Test.SubscriptionHelpers

  @transfer_selector "0xa9059cbb"
  @transfer_with_memo_selector "0x95777d59"

  test "deserializes, verifies, and reserializes a normative subscription authorization" do
    subscription = SubscriptionHelpers.subscription()
    {serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    assert authorization.chain_id == SubscriptionHelpers.chain_id()
    assert authorization.key_type == :secp256k1
    assert authorization.key_id == SubscriptionHelpers.access_address()
    assert authorization.source == SubscriptionHelpers.root_address()
    assert KeyAuthorization.serialize(authorization) == serialized
    assert KeyAuthorization.transaction_field(authorization) == authorization.field

    assert :ok =
             KeyAuthorization.verify(authorization, subscription,
               chain_id: SubscriptionHelpers.chain_id(),
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1,
               challenge_expires: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
               source: "did:pkh:eip155:#{SubscriptionHelpers.chain_id()}:#{SubscriptionHelpers.root_address()}"
             )
  end

  test "builds the normative wallet_authorizeAccessKey parameter shape" do
    subscription = SubscriptionHelpers.subscription(amount: "16", period_unit: :week, period_count: "2")

    assert {:ok, params} =
             KeyAuthorization.wallet_params(subscription,
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1
             )

    assert params["address"] == SubscriptionHelpers.access_address()
    assert params["keyType"] == "secp256k1"
    assert [%{"limit" => "0x10", "period" => 1_209_600, "token" => token}] = params["limits"]
    assert token == String.downcase(SubscriptionHelpers.token())

    assert [transfer, transfer_with_memo] = params["scopes"]

    assert transfer == %{
             "address" => String.downcase(SubscriptionHelpers.token()),
             "selector" => @transfer_selector,
             "recipients" => [String.downcase(SubscriptionHelpers.recipient())]
           }

    assert transfer_with_memo["selector"] == @transfer_with_memo_selector

    for {input, wire} <- [{"secp256k1", "secp256k1"}, {"p256", "p256"}, {"webAuthn", "webAuthn"}] do
      assert {:ok, %{"keyType" => ^wire}} =
               KeyAuthorization.wallet_params(subscription,
                 access_key: SubscriptionHelpers.access_address(),
                 key_type: input
               )
    end

    {_serialized, zero_tagged, _rpc} = SubscriptionHelpers.signed_authorization(subscription, key_type: <<0>>)
    assert zero_tagged.key_type == :secp256k1
  end

  test "decodes the exact RPC object returned by wallet_authorizeAccessKey" do
    subscription = SubscriptionHelpers.subscription()
    {serialized, _authorization, rpc} = SubscriptionHelpers.signed_authorization(subscription)

    assert {:ok, decoded} = KeyAuthorization.from_rpc(rpc)
    assert KeyAuthorization.serialize(decoded) == serialized

    assert {:error, "wallet_authorizeAccessKey returned an invalid keyAuthorization"} =
             KeyAuthorization.from_rpc(%{})

    assert {:error, "wallet returned an invalid primitive signature"} =
             KeyAuthorization.from_rpc(%{rpc | "signature" => %{"type" => "keychain"}})
  end

  test "verifies p256 and WebAuthn primitive signatures returned by the wallet" do
    subscription = SubscriptionHelpers.subscription()

    for key_type <- [:p256, :web_authn] do
      rpc = signed_p256_rpc(subscription, key_type)
      assert {:ok, authorization} = KeyAuthorization.from_rpc(rpc)
      assert authorization.key_type == key_type

      assert :ok =
               KeyAuthorization.verify(authorization, subscription,
                 chain_id: SubscriptionHelpers.chain_id(),
                 access_key: SubscriptionHelpers.access_address(),
                 key_type: key_type
               )
    end
  end

  test "rejects broader, incomplete, or mismatched authorization fields" do
    subscription = SubscriptionHelpers.subscription()
    recipient_bytes = decode_address(SubscriptionHelpers.recipient())

    cases = [
      {[chain_id: 1], "keyAuthorization chainId mismatch"},
      {[access_key: "0x9999999999999999999999999999999999999999"], "keyAuthorization access key mismatch"},
      {[limits: []], "keyAuthorization must contain exactly one token limit"},
      {[limits: [valid_limit(subscription), valid_limit(subscription)]],
       "keyAuthorization must contain exactly one token limit"},
      {[
         limits: [
           [decode_address("0x9999999999999999999999999999999999999999"), encode_uint(1_000_000), encode_uint(86_400)]
         ]
       ], "keyAuthorization currency mismatch"},
      {[limits: [[decode_address(subscription.currency), encode_uint(1), encode_uint(86_400)]]],
       "keyAuthorization amount mismatch"},
      {[limits: [[decode_address(subscription.currency), encode_uint(1_000_000), encode_uint(1)]]],
       "keyAuthorization period mismatch"},
      {[scopes: []], "keyAuthorization must contain exactly one restricted call target"},
      {[scopes: [valid_scope(subscription), valid_scope(subscription)]],
       "keyAuthorization must contain exactly one restricted call target"},
      {[scopes: [[decode_address("0x9999999999999999999999999999999999999999"), valid_rules(subscription)]]],
       "keyAuthorization call target mismatch"},
      {[rules: []], "keyAuthorization must use explicit selector rules"},
      {[rules: [valid_transfer_rule(subscription), valid_transfer_rule(subscription)]],
       "keyAuthorization contains a duplicate selector"},
      {[rules: [valid_transfer_rule(subscription)]], "keyAuthorization must allow transferWithMemo"},
      {[rules: [[<<0x09, 0x5E, 0xA7, 0xB3>>, [recipient_bytes]]]], "keyAuthorization selector not allowed"},
      {[rules: [valid_transfer_rule(subscription), [<<0x09, 0x5E, 0xA7, 0xB3>>, [recipient_bytes]]]],
       "keyAuthorization selector not allowed"},
      {[rules: [[<<0xA9, 0x05, 0x9C, 0xBB>>, []]]], "keyAuthorization recipient mismatch"}
    ]

    for {authorization_opts, expected_error} <- cases do
      {_serialized, authorization, _rpc} =
        SubscriptionHelpers.signed_authorization(subscription, authorization_opts)

      assert {:error, ^expected_error} = verify(authorization, subscription)
    end
  end

  test "accepts a transferWithMemo-only authorization matching the mppx grant" do
    subscription = SubscriptionHelpers.subscription()
    recipient_bytes = decode_address(SubscriptionHelpers.recipient())

    {_serialized, authorization, _rpc} =
      SubscriptionHelpers.signed_authorization(subscription,
        rules: [[<<0x95, 0x77, 0x7D, 0x59>>, [recipient_bytes]]]
      )

    assert :ok = verify(authorization, subscription)
  end

  test "rejects a declared source that does not match the root signature" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    assert {:error, "credential source does not match signature"} =
             KeyAuthorization.verify(authorization, subscription,
               chain_id: SubscriptionHelpers.chain_id(),
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1,
               source: "did:pkh:eip155:#{SubscriptionHelpers.chain_id()}:0x9999999999999999999999999999999999999999"
             )

    assert {:error, "credential source is invalid"} =
             KeyAuthorization.verify(authorization, subscription,
               chain_id: SubscriptionHelpers.chain_id(),
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1,
               source: "not-a-did"
             )

    assert {:error, "credential source chain mismatch"} =
             KeyAuthorization.verify(authorization, subscription,
               chain_id: SubscriptionHelpers.chain_id(),
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1,
               source: "did:pkh:eip155:1:#{SubscriptionHelpers.root_address()}"
             )
  end

  test "rejects unrepresentable Tempo timing" do
    month = SubscriptionHelpers.subscription(period_unit: :month)
    assert {:error, "Tempo subscriptions support periodUnit day or week"} = KeyAuthorization.period_seconds(month)

    overflow = SubscriptionHelpers.subscription(period_count: "213503982334602")

    assert {:error, "subscription period cannot be represented as an unsigned 64-bit integer"} =
             KeyAuthorization.period_seconds(overflow)

    fractional = SubscriptionHelpers.subscription(subscription_expires: "2027-01-01T00:00:00.001Z")

    assert {:error, "subscriptionExpires must be representable as whole seconds"} =
             KeyAuthorization.wallet_params(fractional,
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1
             )

    missing = Map.put(SubscriptionHelpers.subscription(), :subscription_expires, nil)

    assert {:error, "Tempo subscriptions require subscriptionExpires"} =
             KeyAuthorization.wallet_params(missing,
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1
             )

    invalid = Map.put(SubscriptionHelpers.subscription(), :subscription_expires, "invalid")

    assert {:error, "subscriptionExpires is invalid"} =
             KeyAuthorization.wallet_params(invalid,
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1
             )

    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    assert {:error, "subscriptionExpires must be strictly later than challenge expires"} =
             KeyAuthorization.verify(authorization, subscription,
               chain_id: SubscriptionHelpers.chain_id(),
               access_key: SubscriptionHelpers.access_address(),
               key_type: :secp256k1,
               challenge_expires: subscription.subscription_expires
             )
  end

  test "rejects malformed wire payloads and signatures" do
    for value <- [nil, "0x", "0xzz", "0xc0", "0xdeadbeef"] do
      assert {:error, _reason} = KeyAuthorization.deserialize(value)
    end

    subscription = SubscriptionHelpers.subscription()
    {serialized, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
    decoded = Base.decode16!(String.replace_prefix(serialized, "0x", ""), case: :mixed)
    [authorization, _signature] = ExRLP.decode(decoded)
    malformed = "0x" <> Base.encode16(ExRLP.encode([authorization, <<0>>]), case: :lower)

    assert {:error, "keyAuthorization must use a primitive signature"} =
             KeyAuthorization.deserialize(malformed)
  end

  test "rejects malformed decoded authorization fields before signature verification" do
    subscription = SubscriptionHelpers.subscription()
    {serialized, _authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
    [authorization, signature] = decode_serialized(serialized)
    token = decode_address(subscription.currency)
    recipient = decode_address(subscription.recipient)
    valid_rules = [[decode_hex!(@transfer_selector), [recipient]]]
    valid_limit = [token, encode_uint(1_000_000), encode_uint(86_400)]

    cases = [
      {[], "unsupported or missing fields"},
      {List.replace_at(authorization, 0, []), "invalid keyAuthorization chainId"},
      {List.replace_at(authorization, 1, <<3>>), "invalid keyAuthorization key type"},
      {List.replace_at(authorization, 2, <<1>>), "invalid access key address"},
      {List.replace_at(authorization, 3, <<>>), "invalid keyAuthorization expiry"},
      {List.replace_at(authorization, 4, <<>>), "invalid keyAuthorization token limits"},
      {List.replace_at(authorization, 4, [[<<1>>, encode_uint(1), encode_uint(1)]]), "invalid limit token address"},
      {List.replace_at(authorization, 4, [[token]]), "invalid keyAuthorization token limit"},
      {List.replace_at(authorization, 4, [[token, encode_uint(1), <<>>]]), "invalid keyAuthorization limit period"},
      {List.replace_at(authorization, 5, <<>>), "invalid keyAuthorization call scopes"},
      {List.replace_at(authorization, 5, [[<<1>>, valid_rules]]), "invalid scope target address"},
      {List.replace_at(authorization, 5, [[token]]), "invalid keyAuthorization call scope"},
      {List.replace_at(authorization, 5, [[token, [[<<1>>, [recipient]]]]]), "invalid keyAuthorization selector rule"},
      {List.replace_at(authorization, 5, [[token, [[decode_hex!(@transfer_selector), [<<1>>]]]]]),
       "invalid scope recipient address"},
      {List.replace_at(authorization, 4, [valid_limit]), nil}
    ]

    for {mutated, expected} <- cases do
      result = deserialize_fields(mutated, signature)

      if expected do
        assert {:error, reason} = result
        assert reason =~ expected
      else
        assert {:ok, _authorization} = result
      end
    end
  end

  test "rejects invalid verifier inputs and subscription mismatches" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    invalid_opts = [
      {[chain_id: -1, access_key: SubscriptionHelpers.access_address(), key_type: :secp256k1], "invalid chain_id"},
      {[chain_id: SubscriptionHelpers.chain_id(), access_key: "invalid", key_type: :secp256k1],
       "access_key must be an address"},
      {[chain_id: SubscriptionHelpers.chain_id(), access_key: SubscriptionHelpers.access_address(), key_type: :rsa],
       "invalid subscription access key type"},
      {[chain_id: SubscriptionHelpers.chain_id(), access_key: SubscriptionHelpers.access_address(), key_type: :p256],
       "keyAuthorization key type mismatch"}
    ]

    for {opts, reason} <- invalid_opts do
      assert {:error, ^reason} = KeyAuthorization.verify(authorization, subscription, opts)
    end

    assert {:error, "subscription amount is invalid"} = verify(authorization, %{subscription | amount: "invalid"})

    later_expiry =
      subscription.subscription_expires
      |> DateTime.from_iso8601()
      |> elem(1)
      |> DateTime.shift(second: 1)
      |> DateTime.to_iso8601()

    assert {:error, "keyAuthorization expiry mismatch"} =
             verify(authorization, %{subscription | subscription_expires: later_expiry})
  end

  test "rejects every malformed wallet keyAuthorization response boundary" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, _authorization, rpc} = SubscriptionHelpers.signed_authorization(subscription)

    cases = [
      Map.put(rpc, "chainId", "0xzz"),
      Map.put(rpc, "keyType", "rsa"),
      Map.put(rpc, "keyId", "0x01"),
      Map.put(rpc, "expiry", -1),
      Map.put(rpc, "limits", "invalid"),
      Map.put(rpc, "limits", [%{}]),
      put_in(rpc, ["limits", Access.at(0), "token"], "0x01"),
      put_in(rpc, ["limits", Access.at(0), "limit"], "invalid"),
      Map.put(rpc, "allowedCalls", "invalid"),
      Map.put(rpc, "allowedCalls", [%{}]),
      put_in(rpc, ["allowedCalls", Access.at(0), "target"], "0x01"),
      put_in(rpc, ["allowedCalls", Access.at(0), "selectorRules"], "invalid"),
      put_in(rpc, ["allowedCalls", Access.at(0), "selectorRules", Access.at(0), "selector"], "0x01"),
      put_in(rpc, ["allowedCalls", Access.at(0), "selectorRules", Access.at(0), "recipients"], ["0x01"]),
      put_in(rpc, ["signature", "r"], "invalid"),
      put_in(rpc, ["signature", "yParity"], 2)
    ]

    for malformed <- cases do
      assert {:error, reason} = KeyAuthorization.from_rpc(malformed)
      assert is_binary(reason)
    end

    integer_rpc =
      rpc
      |> Map.put("chainId", SubscriptionHelpers.chain_id())
      |> Map.update!("expiry", &hex_to_integer/1)
      |> update_in(["limits", Access.at(0), "limit"], &hex_to_integer/1)
      |> update_in(["limits", Access.at(0), "period"], &hex_to_integer/1)
      |> update_in(["signature", "r"], &hex_to_integer/1)
      |> update_in(["signature", "s"], &hex_to_integer/1)
      |> update_in(["signature"], &Map.delete(&1, "yParity"))

    assert {:ok, _authorization} = KeyAuthorization.from_rpc(integer_rpc)
  end

  defp verify(authorization, subscription) do
    KeyAuthorization.verify(authorization, subscription,
      chain_id: SubscriptionHelpers.chain_id(),
      access_key: SubscriptionHelpers.access_address(),
      key_type: :secp256k1
    )
  end

  defp signed_p256_rpc(subscription, key_type) do
    {_serialized, _authorization, rpc} = SubscriptionHelpers.signed_authorization(subscription)
    rpc = Map.put(rpc, "keyType", if(key_type == :p256, do: "p256", else: "webAuthn"))
    authorization = rpc_authorization(rpc)
    digest = authorization |> ExRLP.encode() |> Hash.keccak()
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public_key

    signature =
      case key_type do
        :p256 -> p256_rpc_signature(digest, private_key, x, y)
        :web_authn -> web_authn_rpc_signature(digest, private_key, x, y)
      end

    Map.put(rpc, "signature", signature)
  end

  defp p256_rpc_signature(digest, private_key, x, y) do
    {r, s} = ecdsa_signature(digest, :sha256, private_key)

    %{
      "type" => "p256",
      "r" => fixed_hex(r),
      "s" => fixed_hex(s),
      "pubKeyX" => hex(x),
      "pubKeyY" => hex(y),
      "preHash" => false
    }
  end

  defp web_authn_rpc_signature(digest, private_key, x, y) do
    authenticator_data = :binary.copy(<<0>>, 37)
    client_data = Jason.encode!(%{"challenge" => Base.url_encode64(digest, padding: false)})
    signed = authenticator_data <> :crypto.hash(:sha256, client_data)
    {r, s} = ecdsa_signature(signed, :sha256, private_key)

    %{
      "type" => "webAuthn",
      "webauthnData" => hex(authenticator_data <> client_data),
      "r" => fixed_hex(r),
      "s" => fixed_hex(s),
      "pubKeyX" => hex(x),
      "pubKeyY" => hex(y)
    }
  end

  defp ecdsa_signature(payload, digest_type, private_key) do
    der = :crypto.sign(:ecdsa, digest_type, payload, [private_key, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    {r, s}
  end

  defp rpc_authorization(rpc) do
    key_type = if rpc["keyType"] == "p256", do: <<1>>, else: <<2>>

    limits =
      Enum.map(rpc["limits"], fn limit ->
        [
          decode_address(limit["token"]),
          encode_uint(hex_to_integer(limit["limit"])),
          encode_uint(hex_to_integer(limit["period"]))
        ]
      end)

    scopes =
      Enum.map(rpc["allowedCalls"], fn scope ->
        rules =
          Enum.map(scope["selectorRules"], fn rule ->
            [decode_hex!(rule["selector"]), Enum.map(rule["recipients"], &decode_address/1)]
          end)

        [decode_address(scope["target"]), rules]
      end)

    [
      encode_uint(hex_to_integer(rpc["chainId"])),
      key_type,
      decode_address(rpc["keyId"]),
      encode_uint(hex_to_integer(rpc["expiry"])),
      limits,
      scopes
    ]
  end

  defp deserialize_fields(authorization, signature) do
    [authorization, signature]
    |> ExRLP.encode()
    |> hex()
    |> KeyAuthorization.deserialize()
  end

  defp decode_serialized("0x" <> value), do: value |> Base.decode16!(case: :mixed) |> ExRLP.decode()

  defp valid_limit(subscription) do
    [decode_address(subscription.currency), encode_uint(String.to_integer(subscription.amount)), encode_uint(86_400)]
  end

  defp valid_scope(subscription), do: [decode_address(subscription.currency), valid_rules(subscription)]
  defp valid_rules(subscription), do: [valid_transfer_rule(subscription)]
  defp valid_transfer_rule(subscription), do: [decode_hex!(@transfer_selector), [decode_address(subscription.recipient)]]

  defp decode_address("0x" <> address), do: Base.decode16!(address, case: :mixed)
  defp decode_hex!("0x" <> value), do: Base.decode16!(value, case: :mixed)
  defp encode_uint(0), do: <<>>
  defp encode_uint(value), do: :binary.encode_unsigned(value)
  defp fixed_hex(value), do: value |> :binary.encode_unsigned() |> left_pad(32) |> hex()
  defp left_pad(value, size), do: :binary.copy(<<0>>, size - byte_size(value)) <> value
  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)
  defp hex_to_integer("0x" <> value), do: String.to_integer(value, 16)
end
