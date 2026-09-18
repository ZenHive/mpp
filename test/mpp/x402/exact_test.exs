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

    nonce = payload["payload"]["authorization"]["nonce"]
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

  defp synthetic_challenge do
    {:ok, header} =
      Headers.encode_payment_required(%{
        "x402Version" => 2,
        "resource" => %{"url" => "https://api.example.com/resource"},
        "accepts" => [@accept]
      })

    assert {:ok, [challenge]} = X402.challenges_from_header(header, "https://api.example.com/resource")
    challenge
  end
end
