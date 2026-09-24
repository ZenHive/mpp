defmodule MPP.X402Test do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.X402

  @accept %{
    "scheme" => "exact",
    "network" => "eip155:1",
    "amount" => "1",
    "asset" => "asset",
    "payTo" => "recipient",
    "maxTimeoutSeconds" => 60
  }

  test "mixed offers keep supported accepts and their original indexes" do
    envelope = %{
      "x402Version" => 2,
      "resource" => %{"url" => "/relative"},
      "accepts" => [nil, %{}, Map.put(@accept, "scheme", "other"), @accept],
      "extensions" => %{"other" => %{}}
    }

    assert {:ok, [challenge]} = X402.challenges_from_header(encode(envelope))
    assert challenge.id == "x402:3"
    assert challenge.realm == "x402"
    assert challenge.method == X402.payment_method()
    assert challenge.intent == X402.exact_intent()
    assert X402.synthetic?(challenge)
    assert {:ok, request} = X402.exact_request(challenge)
    assert request["extensions"] == envelope["extensions"]
    assert request["resource"] == envelope["resource"]
    assert {:error, :invalid_base64} = X402.challenges_from_header("!")
  end

  test "malformed requests and nonpositive or non-EVM chain ids fail" do
    for request <- ["!", Base.url_encode64("[]", padding: false)] do
      challenge = %Challenge{id: "x402:0", realm: "example.com", method: "evm", intent: "charge", request: request}
      refute X402.synthetic?(challenge)
      assert {:error, _} = X402.exact_request(challenge)
    end

    refute X402.synthetic?(nil)
    assert {:ok, 1} = X402.chain_id("eip155:1")

    for network <- ["eip155:0", "eip155:-1", "eip155:1x", "solana:1", nil] do
      assert {:error, :invalid_network} = X402.chain_id(network)
    end
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.encode64()
end
