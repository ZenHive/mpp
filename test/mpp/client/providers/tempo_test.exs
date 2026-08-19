defmodule MPP.Client.Providers.TempoTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.Providers.Tempo
  alias MPP.Expires
  alias MPP.Intents.Charge
  alias MPP.Intents.Subscription
  alias MPP.Methods.Tempo.MachineToken
  alias MPP.Methods.Tempo.Proof
  alias MPP.Test.SubscriptionHelpers
  alias Onchain.Tempo.Transaction

  @chain_id 42_431
  @private_key String.duplicate("11", 32)
  @token "0x20c0000000000000000000000000000000000001"
  @recipient "0x2222222222222222222222222222222222222222"
  @realm "payments.example.com"
  @challenge_id "challenge-attribution-123"
  @client_id "mpp-elixir-test-client"
  @gas_limit 100_000
  @attribution_tag Base.decode16!("EF1ED712")

  setup do
    stub_chain_id(@chain_id)
    :ok
  end

  describe "supports?/3" do
    test "supports Tempo charge and subscription challenges" do
      assert Tempo.supports?("tempo", "charge", %{})
      assert Tempo.supports?("tempo", "subscription", %{})
      refute Tempo.supports?("stripe", "charge", %{})
      refute Tempo.supports?("tempo", "session", %{})
    end
  end

  describe "pay/2" do
    test "signs a transfer with the reference-compatible attribution memo" do
      challenge = challenge()

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert credential.challenge == challenge
      assert %{"type" => "transaction", "signature" => signature} = credential.payload
      assert {:ok, tx} = Transaction.deserialize(signature)
      assert tx.chain_id == @chain_id

      assert {:ok, %{memo: memo_hex}} =
               Transaction.find_payment_call(tx, @token,
                 amount: "1250",
                 recipient: @recipient
               )

      assert {:ok, memo} = Base.decode16(String.trim_leading(memo_hex, "0x"), case: :mixed)
      tag = @attribution_tag

      # refs/mppx/src/tempo/Attribution.ts and
      # refs/mpp-rs/src/tempo/attribution.rs independently define this 32-byte layout.
      assert <<^tag::binary-size(4), 1, server::binary-size(10), client::binary-size(10), nonce::binary-size(7)>> = memo

      assert server == fingerprint(@realm, 10)
      assert client == fingerprint(@client_id, 10)
      assert nonce == fingerprint(@challenge_id, 7)
    end

    test "builds approve + swapTo when the challenge advertises machineTokenEnabled" do
      challenge = challenge(method_details: %{"chainId" => @chain_id, "machineTokenEnabled" => true})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert {:ok, tx} = Transaction.deserialize(credential.payload["signature"])
      assert tx.chain_id == @chain_id

      assert {:ok, route} = MachineToken.match_route(tx.calls, @chain_id, @token, "1250", @recipient, nil)
      assert route.settlement_sender == MachineToken.settlement_sender(@chain_id)

      assert {:ok, memo} = Base.decode16(String.trim_leading(route.memo, "0x"), case: :mixed)
      tag = @attribution_tag

      assert <<^tag::binary-size(4), 1, server::binary-size(10), client::binary-size(10), nonce::binary-size(7)>> = memo
      assert server == fingerprint(@realm, 10)
      assert client == fingerprint(@client_id, 10)
      assert nonce == fingerprint(@challenge_id, 7)

      assert {:error, reason} =
               Transaction.find_payment_call(tx, @token,
                 amount: "1250",
                 recipient: @recipient
               )

      assert reason =~ "No matching transfer"
    end

    test "keeps a static memo and chain pin on the machine-token route" do
      memo = "0x" <> String.duplicate("ab", 32)

      challenge =
        challenge(method_details: %{"chainId" => @chain_id, "machineTokenEnabled" => true, "memo" => memo})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert {:ok, tx} = Transaction.deserialize(credential.payload["signature"])

      assert {:ok, route} = MachineToken.match_route(tx.calls, @chain_id, @token, "1250", @recipient, memo)
      assert route.memo == String.downcase(memo)

      assert {:error, {:chain_id_mismatch, @chain_id, 1}} =
               Tempo.pay(
                 challenge(method_details: %{"chainId" => 1, "machineTokenEnabled" => true}),
                 provider_config()
               )
    end

    test "builds a fee-payer machine-token route when both are advertised" do
      challenge =
        challenge(method_details: %{"chainId" => @chain_id, "machineTokenEnabled" => true, "feePayer" => true})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert {:ok, tx} = Transaction.deserialize(credential.payload["signature"])
      assert Transaction.has_fee_payer_placeholder?(tx)
      assert Transaction.fee_token_empty?(tx)
      assert {:ok, _route} = MachineToken.match_route(tx.calls, @chain_id, @token, "1250", @recipient, nil)
    end

    test "rejects machineTokenEnabled on a chain with no first-party deployment" do
      stub_chain_id(1)

      assert {:error, :unsupported_machine_token_chain} =
               Tempo.pay(
                 challenge(method_details: %{"chainId" => 1, "machineTokenEnabled" => true}),
                 Map.put(provider_config(), :expected_chain_id, 1)
               )
    end

    test "still signs a transfer when machineTokenEnabled is not exactly true" do
      challenge = challenge(method_details: %{"chainId" => @chain_id, "machineTokenEnabled" => false})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert {:ok, _payment} = payment_call(credential)
    end

    test "uses a challenge-provided static memo verbatim" do
      memo = "0x" <> String.duplicate("ab", 32)
      challenge = challenge(method_details: %{"chainId" => @chain_id, "memo" => memo})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert {:ok, tx} = Transaction.deserialize(credential.payload["signature"])

      assert {:ok, %{memo: decoded_memo}} =
               Transaction.find_payment_call(tx, @token,
                 amount: "1250",
                 recipient: @recipient,
                 memo: memo
               )

      assert decoded_memo == String.downcase(memo)
    end

    test "builds a fee-payer transaction when advertised by the challenge" do
      challenge = challenge(method_details: %{"chainId" => @chain_id, "feePayer" => true})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert {:ok, tx} = Transaction.deserialize(credential.payload["signature"])
      assert Transaction.has_fee_payer_placeholder?(tx)
      assert Transaction.fee_token_empty?(tx)
    end

    test "adds a presenter signature when advertised by the challenge" do
      challenge = challenge(method_details: %{"chainId" => @chain_id, "presenterBinding" => true})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert %{"presenterSignature" => signature} = credential.payload
      assert {:ok, %{address: address}} = MPP.DID.parse_evm_did(credential.source)

      assert :ok =
               Proof.verify_signature(
                 %{
                   account: address,
                   challenge_id: challenge.id,
                   realm: challenge.realm,
                   chain_id: @chain_id
                 },
                 signature,
                 address
               )
    end

    test "creates a signed proof for a zero-amount machine-token challenge" do
      challenge = challenge(amount: "0", method_details: %{"chainId" => @chain_id, "machineTokenEnabled" => true})

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert %{"type" => "proof", "signature" => signature} = credential.payload
      assert {:ok, %{address: address}} = MPP.DID.parse_evm_did(credential.source)

      assert :ok =
               Proof.verify_signature(
                 %{
                   account: address,
                   challenge_id: challenge.id,
                   realm: challenge.realm,
                   chain_id: @chain_id
                 },
                 signature,
                 address
               )
    end

    test "creates a signed proof for a zero-amount challenge" do
      challenge = challenge(amount: "0")

      assert {:ok, credential} = Tempo.pay(challenge, provider_config())
      assert %{"type" => "proof", "signature" => signature} = credential.payload
      assert {:ok, %{address: address}} = MPP.DID.parse_evm_did(credential.source)

      assert :ok =
               Proof.verify_signature(
                 %{
                   account: address,
                   challenge_id: challenge.id,
                   realm: challenge.realm,
                   chain_id: @chain_id
                 },
                 signature,
                 address
               )
    end

    test "rejects an advertised chain that disagrees with the explicit pin" do
      challenge = challenge(method_details: %{"chainId" => 1})

      assert {:error, {:chain_id_mismatch, @chain_id, 1}} =
               Tempo.pay(challenge, provider_config())
    end

    test "rejects an RPC serving a different chain before signing" do
      stub_chain_id(1)

      assert {:error, {:rpc_chain_id_mismatch, @chain_id, 1}} =
               Tempo.pay(challenge(), provider_config())
    end

    test "propagates an RPC transport error before signing" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      config =
        Map.put(provider_config(), :req_options,
          plug: {Req.Test, __MODULE__},
          retry: false
        )

      assert {:error, {:rpc_error, %{message: message}}} = Tempo.pay(challenge(), config)
      assert message =~ "econnrefused"
    end

    test "accepts the advertised chain or the explicit pin as the chain source" do
      raw_key = Base.decode16!(@private_key, case: :mixed)

      advertised_config =
        provider_config()
        |> Map.delete(:expected_chain_id)
        |> Map.put(:private_key, raw_key)
        |> Map.delete(:client_id)

      advertised_challenge = %{challenge() | expires: nil}
      assert {:ok, credential} = Tempo.pay(advertised_challenge, advertised_config)
      assert {:ok, %{memo: memo}} = payment_call(credential)
      assert {:ok, memo_bytes} = Base.decode16(String.trim_leading(memo, "0x"), case: :mixed)

      assert <<_tag::binary-size(4), 1, _server::binary-size(10), client::binary-size(10), _nonce::binary-size(7)>> =
               memo_bytes

      assert client == <<0::80>>

      pinned_config = Map.put(provider_config(), :private_key, "0x" <> @private_key)
      assert {:ok, _credential} = Tempo.pay(challenge(method_details: nil, amount: "0"), pinned_config)
    end

    test "rejects malformed payment details and memos" do
      assert {:error, :invalid_method_details} =
               Tempo.pay(
                 challenge(method_details: "invalid"),
                 provider_config() |> Map.delete(:req_options) |> Map.delete(:client_id)
               )

      assert {:error, :invalid_amount} = Tempo.pay(challenge(amount: "-1"), provider_config())

      assert {:error, :invalid_memo} =
               Tempo.pay(challenge(method_details: %{"chainId" => @chain_id, "memo" => "0xab"}), provider_config())

      assert {:error, :invalid_memo} =
               Tempo.pay(challenge(method_details: %{"chainId" => @chain_id, "memo" => 12}), provider_config())
    end

    test "validates all explicit provider config fields" do
      base = %{private_key: @private_key}

      assert {:error, {:invalid_config, :expected_map}} = Tempo.pay(challenge(), [])
      assert {:error, {:missing_config, :rpc_url}} = Tempo.pay(challenge(), base)
      assert {:error, {:invalid_config, :rpc_url}} = Tempo.pay(challenge(), Map.put(base, :rpc_url, 12))

      assert {:error, {:invalid_config, :private_key}} =
               Tempo.pay(challenge(), Map.put(provider_config(), :private_key, String.duplicate("zz", 32)))

      assert {:error, {:invalid_config, :private_key}} =
               Tempo.pay(challenge(), Map.put(provider_config(), :private_key, :invalid))

      assert {:error, {:invalid_config, :expected_chain_id}} =
               Tempo.pay(challenge(), Map.put(provider_config(), :expected_chain_id, -1))

      assert {:error, {:invalid_config, :expected_chain_id}} =
               Tempo.pay(challenge(), %{
                 private_key: @private_key,
                 rpc_url: "https://moderato.invalid",
                 expected_chain_id: -1
               })

      assert {:error, {:invalid_config, :client_id}} =
               Tempo.pay(challenge(), Map.put(provider_config(), :client_id, 12))

      assert {:error, {:invalid_config, :req_options}} =
               Tempo.pay(challenge(), Map.put(provider_config(), :req_options, %{}))
    end

    test "returns explicit config and challenge errors" do
      assert {:error, {:missing_config, :private_key}} = Tempo.pay(challenge(), %{})

      assert {:error, :invalid_chain_id} =
               Tempo.pay(challenge(method_details: %{}), Map.delete(provider_config(), :expected_chain_id))

      assert {:error, :invalid_chain_id} =
               Tempo.pay(challenge(method_details: %{"chainId" => "42431"}), provider_config())

      expired = %{challenge() | expires: Expires.seconds(-1)}
      assert {:error, :payment_expired} = Tempo.pay(expired, provider_config())
    end

    test "calls wallet_authorizeAccessKey with the normative subscription shape" do
      challenge = subscription_challenge()
      {:ok, subscription} = challenge |> decode_challenge_request() |> Subscription.from_request()
      {_serialized, _authorization, rpc_authorization} = SubscriptionHelpers.signed_authorization(subscription)
      test_process = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_process, {:wallet_request, request})

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{"keyAuthorization" => rpc_authorization}
        })
      end)

      assert {:ok, credential} = Tempo.pay(challenge, wallet_provider_config())
      assert credential.payload["type"] == "keyAuthorization"
      assert credential.source =~ SubscriptionHelpers.root_address()

      assert_receive {:wallet_request,
                      %{
                        "method" => "wallet_authorizeAccessKey",
                        "params" => [params]
                      }}

      assert params["address"] == SubscriptionHelpers.access_address()
      assert [%{"selector" => "0xa9059cbb"}, %{"selector" => "0x95777d59"}] = params["scopes"]
      assert [%{"limit" => "0xf4240", "period" => 86_400}] = params["limits"]
    end

    test "returns wallet errors and rejects malformed subscription challenges" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_602, "message" => "authorization rejected"}
        })
      end)

      assert {:error, {:wallet_authorization_failed, "authorization rejected"}} =
               Tempo.pay(subscription_challenge(), wallet_provider_config())

      assert {:error, {:missing_config, :wallet_rpc_url}} = Tempo.pay(subscription_challenge(), %{})

      missing_access_key = subscription_challenge(method_details: %{"chainId" => @chain_id})
      assert {:error, :missing_access_key} = Tempo.pay(missing_access_key, wallet_provider_config())
    end

    test "returns subscription challenge-shape and wallet transport errors" do
      assert {:error, :missing_method_details} =
               Tempo.pay(subscription_challenge(method_details: nil), wallet_provider_config())

      missing_chain =
        subscription_challenge(
          method_details: %{
            "accessKey" => %{
              "accessKeyAddress" => SubscriptionHelpers.access_address(),
              "keyType" => "secp256k1"
            }
          }
        )

      assert {:error, :invalid_chain_id} = Tempo.pay(missing_chain, wallet_provider_config())

      invalid_key_type =
        subscription_challenge(
          method_details: %{
            "accessKey" => %{
              "accessKeyAddress" => SubscriptionHelpers.access_address(),
              "keyType" => "rsa"
            },
            "chainId" => @chain_id
          }
        )

      assert {:error, :invalid_access_key} = Tempo.pay(invalid_key_type, wallet_provider_config())

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      end)

      for key_type <- ["p256", "webAuthn"] do
        challenge =
          subscription_challenge(
            method_details: %{
              "accessKey" => %{
                "accessKeyAddress" => SubscriptionHelpers.access_address(),
                "keyType" => key_type
              },
              "chainId" => @chain_id
            }
          )

        assert {:error, {:wallet_authorization_failed, 200}} = Tempo.pay(challenge, wallet_provider_config())
      end

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:wallet_authorization_failed, %Req.TransportError{reason: :econnrefused}}} =
               Tempo.pay(subscription_challenge(), wallet_provider_config())
    end
  end

  defp challenge(opts \\ []) do
    amount = Keyword.get(opts, :amount, "1250")
    details = Keyword.get(opts, :method_details, %{"chainId" => @chain_id})

    {:ok, charge} =
      Charge.new(
        amount: amount,
        currency: @token,
        recipient: @recipient,
        method_details: details
      )

    request = charge |> Charge.to_request() |> Jason.encode!() |> Base.url_encode64(padding: false)

    %Challenge{
      id: @challenge_id,
      realm: @realm,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Expires.minutes(5)
    }
  end

  defp provider_config do
    %{
      private_key: @private_key,
      rpc_url: "https://moderato.invalid",
      expected_chain_id: @chain_id,
      client_id: @client_id,
      nonce: 0,
      gas_limit: @gas_limit,
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp subscription_challenge(opts \\ []) do
    method_details =
      Keyword.get(opts, :method_details, %{
        "accessKey" => %{
          "accessKeyAddress" => SubscriptionHelpers.access_address(),
          "keyType" => "secp256k1"
        },
        "chainId" => @chain_id
      })

    subscription =
      SubscriptionHelpers.subscription(
        subscription_expires:
          DateTime.utc_now()
          |> DateTime.truncate(:second)
          |> DateTime.shift(day: 30)
          |> DateTime.to_iso8601(),
        method_details: method_details
      )

    request = subscription |> Subscription.to_request() |> Jason.encode!() |> Base.url_encode64(padding: false)

    %Challenge{
      id: @challenge_id,
      realm: @realm,
      method: "tempo",
      intent: "subscription",
      request: request,
      expires: Expires.minutes(5)
    }
  end

  defp wallet_provider_config do
    %{
      wallet_rpc_url: "https://wallet.invalid",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp decode_challenge_request(challenge) do
    {:ok, json} = Base.url_decode64(challenge.request, padding: false)
    Jason.decode!(json)
  end

  defp fingerprint(value, byte_count) do
    binary_part(ExSha3.keccak_256(value), 0, byte_count)
  end

  defp payment_call(credential) do
    {:ok, tx} = Transaction.deserialize(credential.payload["signature"])

    Transaction.find_payment_call(tx, @token,
      amount: "1250",
      recipient: @recipient
    )
  end

  defp stub_chain_id(chain_id) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => "0x" <> Integer.to_string(chain_id, 16)
      })
    end)
  end
end
