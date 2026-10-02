defmodule MPP.Methods.Tempo.SubscriptionTransactionTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.EnvelopeFields
  alias MPP.Methods.Tempo.FeePayerPolicy
  alias MPP.Methods.Tempo.SubscriptionTransaction
  alias MPP.Test.SubscriptionHelpers
  alias Onchain.Address
  alias Onchain.Tempo.Transaction

  test "builds an activation transaction with key authorization and keychain-v2 signature" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    assert {:ok, tx, memo} =
             SubscriptionTransaction.build(
               subscription,
               authorization,
               SubscriptionHelpers.root_address(),
               config(),
               "challenge_1"
             )

    assert %Transaction{chain_id: 42_431} = tx
    assert tx.key_authorization
    assert EnvelopeFields.key_authorization_field(tx) == {:ok, authorization.field}

    {:ok, source} = Address.validate(SubscriptionHelpers.root_address())
    assert {:keychain, 2, ^source, {:secp256k1, _inner}} = tx.signature

    assert {:ok, %{memo: ^memo}} =
             Transaction.find_payment_call(tx, subscription.currency,
               amount: subscription.amount,
               recipient: subscription.recipient,
               memo: memo
             )
  end

  test "builds a renewal without reprovisioning the key authorization" do
    subscription = SubscriptionHelpers.subscription()

    assert {:ok, tx, _memo} =
             SubscriptionTransaction.build(
               subscription,
               nil,
               SubscriptionHelpers.root_address(),
               config(),
               "renewal:sub_1:1"
             )

    assert tx.key_authorization == nil
    assert tx.fee_token == decode_address(subscription.currency)
    assert tx.fee_payer_signature == nil
  end

  test "locally co-signs the subscription transaction for fee sponsorship" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
    sponsored = sponsored_config(subscription)

    assert {:ok, tx, _memo} =
             SubscriptionTransaction.build(
               subscription,
               authorization,
               SubscriptionHelpers.root_address(),
               sponsored,
               "challenge_sponsored"
             )

    assert tx.fee_token == decode_address(subscription.currency)
    assert %{r: r, s: s, y_parity: y_parity} = tx.fee_payer_signature
    assert y_parity in [0, 1]
    assert r in 1..(Bitwise.bsl(1, 256) - 1)
    assert s in 1..(Bitwise.bsl(1, 256) - 1)
    refute Transaction.has_fee_payer_placeholder?(tx)
    assert tx.valid_before <= System.os_time(:second) + 24
  end

  test "rejects invalid signing and sponsorship configuration" do
    subscription = SubscriptionHelpers.subscription()

    assert {:error, "missing subscription access key private key"} =
             SubscriptionTransaction.build(
               subscription,
               nil,
               SubscriptionHelpers.root_address(),
               Map.delete(config(), "subscription_access_key_private_key"),
               "renewal"
             )

    assert {:error, "hosted fee payer does not support subscription keychain transactions"} =
             SubscriptionTransaction.build(
               subscription,
               nil,
               SubscriptionHelpers.root_address(),
               Map.put(config(), "fee_payer_url", "https://sponsor.invalid"),
               "renewal"
             )

    assert {:error, "invalid subscription amount"} =
             SubscriptionTransaction.build(
               %{subscription | amount: "0"},
               nil,
               SubscriptionHelpers.root_address(),
               config(),
               "renewal"
             )

    assert {:error, "invalid subscription nonce"} =
             SubscriptionTransaction.build(
               subscription,
               nil,
               SubscriptionHelpers.root_address(),
               Map.put(config(), "subscription_nonce", -1),
               "renewal"
             )

    for invalid_key <- [String.duplicate("zz", 32), :invalid] do
      assert {:error, "invalid private key"} =
               SubscriptionTransaction.build(
                 subscription,
                 nil,
                 SubscriptionHelpers.root_address(),
                 Map.put(config(), "subscription_access_key_private_key", invalid_key),
                 "renewal"
               )
    end
  end

  test "accepts raw and 0x-prefixed access keys and falls back to the subscription token for fees" do
    subscription = SubscriptionHelpers.subscription()
    raw_key = Base.decode16!(SubscriptionHelpers.access_private_key(), case: :mixed)

    for key <- [raw_key, "0x" <> SubscriptionHelpers.access_private_key()] do
      configured =
        config()
        |> Map.put("subscription_access_key_private_key", key)
        |> Map.put("fee_token", "invalid")

      assert {:ok, tx, _memo} =
               SubscriptionTransaction.build(
                 subscription,
                 nil,
                 SubscriptionHelpers.root_address(),
                 configured,
                 "renewal"
               )

      assert tx.fee_token == decode_address(subscription.currency)
    end
  end

  test "fetches the account nonce when no subscription nonce is configured" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:rpc, request})
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "0x7"})
    end)

    configured =
      config()
      |> Map.delete("subscription_nonce")
      |> Map.put("req_options", plug: {Req.Test, __MODULE__})

    assert {:ok, tx, _memo} =
             SubscriptionTransaction.build(
               SubscriptionHelpers.subscription(),
               nil,
               SubscriptionHelpers.root_address(),
               configured,
               "renewal"
             )

    assert tx.nonce == 7
    assert_received {:rpc, %{"method" => "eth_getTransactionCount"}}
  end

  test "rejects disallowed fee tokens, invalid fee-payer keys, and over-budget sponsorship" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    disallowed = Map.put(sponsored_config(subscription), "fee_payer_allowed_fee_tokens", [])

    assert {:error, "fee token is not allowed for sponsorship"} =
             SubscriptionTransaction.build(
               subscription,
               authorization,
               SubscriptionHelpers.root_address(),
               disallowed,
               "sponsored"
             )

    invalid_key = Map.put(sponsored_config(subscription), "fee_payer_private_key", "invalid")

    assert {:error, "invalid private key"} =
             SubscriptionTransaction.build(
               subscription,
               authorization,
               SubscriptionHelpers.root_address(),
               invalid_key,
               "sponsored"
             )

    over_budget = put_in(sponsored_config(subscription), ["fee_payer_policy", "max_gas"], 1)

    assert {:error, reason} =
             SubscriptionTransaction.build(
               subscription,
               authorization,
               SubscriptionHelpers.root_address(),
               over_budget,
               "sponsored"
             )

    assert reason =~ "gas"
  end

  test "sponsored activation pins the verified key authorization in the sponsor policy" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)
    sponsored = sponsored_config(subscription)

    assert {:ok, tx, _memo} =
             SubscriptionTransaction.build(
               subscription,
               authorization,
               SubscriptionHelpers.root_address(),
               sponsored,
               "sponsored"
             )

    assert EnvelopeFields.key_authorization_field(tx) == {:ok, authorization.field}

    # The same envelope is exactly what the activation policy accepts and what
    # the renewal policy (no authorization expected) refuses to sponsor.
    now = System.os_time(:second)
    policy = FeePayerPolicy.resolve(sponsored["chain_id"], sponsored["fee_payer_policy"])

    assert :ok = FeePayerPolicy.validate(tx, FeePayerPolicy.expect_key_authorization(policy, authorization), now)
    assert {:error, reason} = FeePayerPolicy.validate(tx, policy, now)
    assert reason =~ "must not carry a key authorization"
  end

  test "sponsored renewal builds a plain envelope that the unpinned sponsor policy accepts" do
    subscription = SubscriptionHelpers.subscription()
    sponsored = sponsored_config(subscription)

    assert {:ok, renewal, _memo} =
             SubscriptionTransaction.build(
               subscription,
               nil,
               SubscriptionHelpers.root_address(),
               sponsored,
               "renewal:sub_1:2"
             )

    assert renewal.key_authorization == nil

    policy = FeePayerPolicy.resolve(sponsored["chain_id"], sponsored["fee_payer_policy"])
    assert :ok = FeePayerPolicy.validate(renewal, policy, System.os_time(:second))
  end

  defp config do
    %{
      "chain_id" => SubscriptionHelpers.chain_id(),
      "rpc_url" => "https://moderato.invalid",
      "subscription_access_key_private_key" => SubscriptionHelpers.access_private_key(),
      "subscription_nonce" => 0,
      "subscription_gas_limit" => 1_000_000,
      "fee_token" => SubscriptionHelpers.token()
    }
  end

  defp sponsored_config(subscription) do
    Map.merge(config(), %{
      "fee_payer" => true,
      "fee_payer_private_key" => SubscriptionHelpers.fee_payer_private_key(),
      "fee_token" => subscription.currency,
      "fee_payer_allowed_fee_tokens" => [subscription.currency],
      "fee_payer_policy" => %{
        "max_gas" => 1_000_000,
        "max_total_fee" => 30_000_000_000_000_000,
        "max_validity_window_seconds" => 30
      }
    })
  end

  defp decode_address(address) do
    {:ok, decoded} = Address.validate(address)
    decoded
  end
end
