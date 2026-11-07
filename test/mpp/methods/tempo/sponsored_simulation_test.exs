defmodule MPP.Methods.Tempo.SponsoredSimulationTest do
  use ExUnit.Case, async: true

  import MPP.Test.TempoTestHelpers

  alias MPP.Methods.Tempo
  alias MPP.Methods.Tempo.SponsoredSimulation
  alias Onchain.Signer.Secp256k1
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @moduletag :capture_log

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @fee_payer_private_key "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @req_options [plug: {Req.Test, Tempo}]

  defp client_tx(overrides \\ %{}) do
    {:ok, tx_hex} =
      TempoTxBuilder.build_fee_payer_transfer(
        private_key: @client_private_key,
        token: @token_address,
        recipient: @recipient,
        amount: 1_000_000,
        chain_id: 42_431,
        rpc_url: @rpc_url,
        gas_limit: 60_000,
        nonce: 0,
        nonce_key: expiring_nonce_key_int(),
        valid_before: future_valid_before()
      )

    {:ok, tx} = Transaction.deserialize(tx_hex)
    Map.merge(tx, overrides)
  end

  defp cosigned(tx) do
    key = Base.decode16!(@fee_payer_private_key, case: :mixed)
    token = Base.decode16!(String.replace_prefix(@token_address, "0x", ""), case: :mixed)
    {:ok, cosigned} = Transaction.cosign_fee_payer(tx, key, token)
    cosigned
  end

  # Re-signs `tx` as a V2 keychain signature: the access key signs
  # keccak256(0x04 || sig_hash || user_address) on behalf of `user`.
  defp keychain_signed(tx, access_key, user) do
    {:ok, sig_hash} = Transaction.signing_hash(tx)
    digest = Onchain.Hash.keccak(<<0x04>> <> sig_hash <> user)
    {:ok, access_address} = Secp256k1.get_address(access_key)
    {:ok, sig} = Secp256k1.sign_payload(digest, access_key)
    sig = Onchain.Recover.normalize_low_s(sig)
    {:ok, recid} = Onchain.Recover.find_recid_from_digest(digest, sig, access_address)
    signed = %{tx | signature: {:keychain, 2, user, {:secp256k1, %{r: sig.r, s: sig.s, y_parity: recid}}}}
    {:ok, raw} = Transaction.serialize(signed)
    {:ok, decoded} = Transaction.deserialize(raw)
    {decoded, access_address}
  end

  defp stub_eth_call(response) do
    test_pid = self()

    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:rpc_call, Jason.decode!(body)})
      response.(conn)
    end)
  end

  defp rpc_error(error), do: &Req.Test.json(&1, %{"jsonrpc" => "2.0", "error" => error, "id" => 1})

  describe "sender_request/1" do
    test "keeps the gas limit and nonce fields but drops the fee token and zeroes the fees" do
      tx = client_tx()
      assert {:ok, request} = SponsoredSimulation.sender_request(tx)

      refute Map.has_key?(request, "feeToken")
      refute Map.has_key?(request, "feePayerSignature")
      assert request["gas"] == "0xea60"
      assert request["maxFeePerGas"] == "0x0"
      assert request["maxPriorityFeePerGas"] == "0x0"
      assert request["nonceKey"] == "0x" <> String.downcase(Integer.to_string(tx.nonce_key, 16))
      assert request["validBefore"] == "0x" <> String.downcase(Integer.to_string(tx.valid_before, 16))
    end
  end

  describe "sender key hints and signed envelope fields" do
    test "carry the secp256k1 key type and a set validAfter in both requests" do
      valid_after = System.os_time(:second) - 60
      tx = cosigned(client_tx(%{valid_after: valid_after}))
      expected_valid_after = "0x" <> String.downcase(Integer.to_string(valid_after, 16))

      assert {:ok, sender} = SponsoredSimulation.sender_request(tx)
      assert {:ok, sponsored} = SponsoredSimulation.sponsored_request(tx)

      for request <- [sender, sponsored] do
        assert request["keyType"] == "secp256k1"
        assert request["validAfter"] == expected_valid_after
        refute Map.has_key?(request, "keyId")
        refute Map.has_key?(request, "keyAuthorization")
      end
    end

    test "omit validAfter when the envelope has none" do
      assert {:ok, request} = SponsoredSimulation.sender_request(client_tx())
      refute Map.has_key?(request, "validAfter")
    end

    test "name the signing access key of a keychain sender" do
      access_key = Base.decode16!(@fee_payer_private_key, case: :mixed)
      user = Base.decode16!("1111111111111111111111111111111111111111")
      {tx, access_address} = keychain_signed(client_tx(), access_key, user)

      assert {:ok, request} = SponsoredSimulation.sender_request(tx)
      assert request["keyType"] == "secp256k1"
      assert request["keyId"] == "0x" <> Base.encode16(access_address, case: :lower)
      assert request["from"] == "0x" <> Base.encode16(user, case: :lower)
    end
  end

  describe "sponsored_request/1" do
    test "carries the fee token and the fee payer signature as hex quantities" do
      tx = cosigned(client_tx())
      %{r: r, s: s, y_parity: y_parity} = tx.fee_payer_signature

      assert {:ok, request} = SponsoredSimulation.sponsored_request(tx)
      assert String.downcase(request["feeToken"]) == String.downcase(@token_address)
      assert request["gas"] == "0xea60"

      assert request["feePayerSignature"] == %{
               "r" => "0x" <> String.downcase(Integer.to_string(r, 16)),
               "s" => "0x" <> String.downcase(Integer.to_string(s, 16)),
               "yParity" => "0x#{y_parity}"
             }
    end

    test "keeps a zero maxPriorityFeePerGas in the request (mppx #1202)" do
      tx = cosigned(client_tx(%{max_priority_fee_per_gas: 0}))
      assert {:ok, %{"maxPriorityFeePerGas" => "0x0"}} = SponsoredSimulation.sponsored_request(tx)
    end

    test "refuses a transaction without a fee payer signature" do
      assert {:error, :unavailable} = SponsoredSimulation.sponsored_request(client_tx())
      assert {:error, :unavailable} = SponsoredSimulation.simulate_sponsored(client_tx(), @rpc_url, @req_options)
    end

    test "reports a transaction it cannot build a request for as unavailable" do
      tx = %{cosigned(client_tx()) | calls: []}
      assert {:error, :unavailable} = SponsoredSimulation.sponsored_request(tx)
      assert {:error, :unavailable} = SponsoredSimulation.sender_request(client_tx(%{calls: []}))
    end
  end

  describe "gas_limit_error?/1" do
    test "accepts only the node's own gas-limit messages" do
      assert SponsoredSimulation.gas_limit_error?(%{
               "code" => -32_003,
               "message" => "out of gas: gas exhausted during precompiled contract execution: 40960"
             })

      assert SponsoredSimulation.gas_limit_error?(%{"code" => -32_000, "message" => "intrinsic gas too low"})
      assert SponsoredSimulation.gas_limit_error?(%{"code" => -32_000, "message" => "  Out of gas  "})
      assert SponsoredSimulation.gas_limit_error?(%{"code" => -32_003, "message" => "out of gas", "data" => "0x"})
    end

    test "rejects reverts, revert data, balance errors and lookalike text" do
      refute SponsoredSimulation.gas_limit_error?(%{"code" => 3, "message" => "out of gas"})
      refute SponsoredSimulation.gas_limit_error?(%{"code" => -32_003, "message" => "out of gas", "data" => "0x08c379a0"})

      refute SponsoredSimulation.gas_limit_error?(%{
               "code" => -32_003,
               "message" => "insufficient fee token balance: required 8929, but only have 0"
             })

      refute SponsoredSimulation.gas_limit_error?(%{"code" => -32_000, "message" => "execution reverted: out of gas"})
      refute SponsoredSimulation.gas_limit_error?(%{"code" => -32_000, "message" => "out of gasoline"})
      refute SponsoredSimulation.gas_limit_error?(%{"message" => "out of gas"})
      refute SponsoredSimulation.gas_limit_error?(nil)
    end
  end

  describe "simulate_sender/3 and simulate_sponsored/3" do
    test "pass on an eth_call result" do
      stub_eth_call(&Req.Test.json(&1, %{"jsonrpc" => "2.0", "result" => "0x01", "id" => 1}))

      assert :ok = SponsoredSimulation.simulate_sender(client_tx(), @rpc_url, @req_options)
      assert_received {:rpc_call, %{"method" => "eth_call", "params" => [_request, "latest"]}}
      assert :ok = SponsoredSimulation.simulate_sponsored(cosigned(client_tx()), @rpc_url, @req_options)
    end

    test "a gas-limit error rejects the sender simulation but passes the sponsored one" do
      stub_eth_call(rpc_error(%{"code" => -32_000, "message" => "intrinsic gas too low"}))

      assert {:error, :rejected} = SponsoredSimulation.simulate_sender(client_tx(), @rpc_url, @req_options)
      assert :ok = SponsoredSimulation.simulate_sponsored(cosigned(client_tx()), @rpc_url, @req_options)
    end

    test "a revert or fee-balance shortfall rejects both" do
      for error <- [
            %{"code" => 3, "message" => "execution reverted", "data" => "0x"},
            %{"code" => -32_003, "message" => "insufficient fee token balance: required 8929, but only have 0"}
          ] do
        stub_eth_call(rpc_error(error))
        assert {:error, :rejected} = SponsoredSimulation.simulate_sender(client_tx(), @rpc_url, @req_options)
        sponsored = cosigned(client_tx())
        assert {:error, :rejected} = SponsoredSimulation.simulate_sponsored(sponsored, @rpc_url, @req_options)
      end
    end

    test "other node errors, transport failures and malformed answers are unavailable" do
      responses = [
        rpc_error(%{"code" => -32_005, "message" => "rate limited"}),
        &Req.Test.transport_error(&1, :econnrefused),
        &Req.Test.json(&1, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
      ]

      for response <- responses do
        stub_eth_call(response)
        assert {:error, :unavailable} = SponsoredSimulation.simulate_sender(client_tx(), @rpc_url, @req_options)

        assert {:error, :unavailable} =
                 SponsoredSimulation.simulate_sponsored(cosigned(client_tx()), @rpc_url, @req_options)
      end
    end
  end
end
