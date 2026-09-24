defmodule MPP.X402.ExactTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.Providers.X402Exact
  alias MPP.Client.SelectionPolicy
  alias MPP.Methods.EVM.Authorization
  alias MPP.Test.EVMAuthorization
  alias MPP.X402
  alias MPP.X402.Exact
  alias MPP.X402.Headers
  alias MPP.X402.Nonce

  @accept %{
    "scheme" => "exact",
    "network" => "eip155:84532",
    "amount" => "10000",
    "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    "payTo" => "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "maxTimeoutSeconds" => 300,
    "extra" => %{"name" => "USDC", "version" => "2"}
  }

  @config %{private_key: EVMAuthorization.private_key(), networks: [84_532]}

  test "signs a synthetic challenge with a random nonce, not challengeHash" do
    challenge = synthetic_challenge()
    assert Exact.can_handle?(challenge, @config)
    assert {:ok, payload} = Exact.sign(challenge, @config)

    authorization = payload["payload"]["authorization"]
    assert authorization["from"] == EVMAuthorization.signer_address()
    assert String.to_integer(authorization["validBefore"]) - String.to_integer(authorization["validAfter"]) == 900

    assert {:ok, parsed} =
             Authorization.parse_payload(
               Map.merge(authorization, %{"type" => "authorization", "signature" => payload["payload"]["signature"]})
             )

    assert {:ok, recovered} =
             Authorization.recover_authorization(parsed, @accept["asset"], 84_532, "USDC", "2")

    assert Onchain.Address.equal?(recovered, authorization["from"])

    nonce = authorization["nonce"]
    refute Nonce.challenge_hash?(nonce, challenge.id, challenge.realm)
    refute nonce == Authorization.challenge_hash(challenge.id, challenge.realm)
    assert byte_size(Base.decode16!(String.trim_leading(nonce, "0x"), case: :mixed)) == 32
  end

  test "refuses a native Payment-auth EVM challenge" do
    native =
      Challenge.create(
        [realm: "api.example.com", method: "evm", intent: "charge", request: "eyJhbW91bnQiOiIxIn0"],
        "test-secret-key"
      )

    refute Exact.can_handle?(native, @config)
    assert {:error, :not_x402_challenge} = Exact.sign(native, @config)
    refute X402Exact.supports_challenge?(native, @config)
  end

  test "selection policy keeps x402 exact off native EVM-shaped offers" do
    native =
      Challenge.create(
        [realm: "api.example.com", method: "evm", intent: "charge", request: "eyJhbW91bnQiOiIxIn0"],
        "test-secret-key"
      )

    multi = MultiProvider.new([{X402Exact, @config}])
    assert {:error, :no_supported_challenge} = SelectionPolicy.select([native], multi)
    assert {:ok, selected} = SelectionPolicy.select([synthetic_challenge()], multi)
    assert X402.synthetic?(selected)
  end

  test "sign_transfer/2 is the shared primitive and does not enforce a nonce contract" do
    nonce = Nonce.random()

    assert {:ok, signature} =
             Authorization.sign_transfer(
               %{
                 currency: @accept["asset"],
                 name: "USDC",
                 version: "2",
                 chain_id: 84_532,
                 from: EVMAuthorization.signer_address(),
                 to: @accept["payTo"],
                 value: 10_000,
                 valid_after: 1,
                 valid_before: System.system_time(:second) + 300,
                 nonce: nonce
               },
               EVMAuthorization.private_key()
             )

    assert String.starts_with?(signature, "0x")
  end

  test "signing policies enforce boundaries and reject malformed limits" do
    challenge = synthetic_challenge()

    for {override, reason} <- [
          {%{networks: []}, :network_not_allowed},
          {%{networks: "84532"}, :network_not_allowed},
          {%{max_atomic_amount: 9999}, :amount_exceeds_max},
          {%{max_atomic_amount: "bad"}, :invalid_amount},
          {%{max_atomic_amount: -1}, :invalid_amount},
          {%{currencies: []}, :currency_not_allowed},
          {%{currencies: "USDC"}, :currency_not_allowed},
          {%{assets: ["invalid"]}, :currency_not_allowed},
          {%{private_key: nil}, :missing_private_key}
        ] do
      assert {:error, ^reason} = Exact.sign(challenge, Map.merge(@config, override))
    end

    for max <- [10_000, "10000"] do
      assert {:ok, payload} =
               Exact.sign(challenge, %{
                 private_key: @config.private_key,
                 max_atomic_amount: max,
                 assets: ["invalid", String.downcase(@accept["asset"])]
               })

      assert payload["payload"]["authorization"]["value"] == "10000"
    end
  end

  test "signing requires resource and domain and refuses unsupported transfer methods" do
    for {change, reason} <- [
          {%{"resource" => nil}, :missing_resource},
          {%{"extra" => nil}, :missing_eip3009_domain},
          {%{"extra" => %{"name" => "", "version" => "2"}}, :missing_eip3009_domain},
          {%{"extra" => %{"assetTransferMethod" => "permit2"}}, :unsupported_transfer_method},
          {%{"network" => "eip155:0"}, :invalid_network}
        ] do
      assert {:error, ^reason} = Exact.sign(challenge_with(change), @config)
    end
  end

  test "unrelated extensions survive signing and route-bound signatures use a fresh salt" do
    assert {:ok, plain} = Exact.sign(challenge_with(%{"extensions" => %{"other" => %{}}}), @config)
    assert plain["extensions"] == %{"other" => %{}}

    challenge = challenge_with(%{"extensions" => %{"mppx" => %{"info" => "invalid"}}})
    assert {:ok, first} = Exact.sign(challenge, @config)
    assert {:ok, second} = Exact.sign(challenge, @config)
    refute first["extensions"] == second["extensions"]

    assert first["payload"]["authorization"]["nonce"] ==
             Nonce.extension_bound(first["accepted"], first["resource"], first["extensions"])
  end

  defp challenge_with(changes) do
    challenge = synthetic_challenge()
    {:ok, request} = X402.exact_request(challenge)
    encoded = request |> Map.merge(changes) |> Jason.encode!() |> Base.url_encode64(padding: false)
    %{challenge | request: encoded}
  end

  defp synthetic_challenge do
    {:ok, header} =
      Headers.encode_payment_required(%{
        "x402Version" => 2,
        "resource" => %{"url" => "https://api.example.com/resource"},
        "accepts" => [@accept]
      })

    assert {:ok, [challenge]} = X402.challenges_from_header(header)
    challenge
  end
end
