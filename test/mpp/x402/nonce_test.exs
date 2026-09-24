defmodule MPP.X402.NonceTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.EVM.Authorization
  alias MPP.X402.Nonce

  @id "aB3cDeF4gHiJkLmN"
  @realm "api.example.com"

  test "native nonce contract remains challenge_hash" do
    assert Authorization.nonce_contract() == :challenge_hash
  end

  test "x402 random nonce is 32 bytes and is not the native challengeHash" do
    nonce = Nonce.random()
    assert String.starts_with?(nonce, "0x")
    assert byte_size(Base.decode16!(String.trim_leading(nonce, "0x"), case: :mixed)) == 32
    refute Nonce.challenge_hash?(nonce, @id, @realm)
    refute nonce == Authorization.challenge_hash(@id, @realm)
  end

  test "challenge_hash?/3 recognizes only the native contract" do
    native = Authorization.challenge_hash(@id, @realm)
    assert Nonce.challenge_hash?(native, @id, @realm)
    refute Nonce.challenge_hash?(Nonce.random(), @id, @realm)
  end

  test "extension-bound nonce is SHA-256 of JCS|JCS|JCS and not challengeHash" do
    accepted = %{"amount" => "1", "scheme" => "exact"}
    resource = %{"url" => "https://api.example.com/resource"}
    extensions = Nonce.with_nonce_salt(%{"mppx" => %{"info" => %{"method" => "GET"}}})

    nonce = Nonce.extension_bound(accepted, resource, extensions)
    assert String.starts_with?(nonce, "0x")
    refute Nonce.challenge_hash?(nonce, @id, @realm)
    assert Nonce.contract(extensions) == :extension_bound
    assert Nonce.contract(%{}) == :random
  end

  test "salt preserves unrelated extensions and repairs non-map info" do
    assert Nonce.with_nonce_salt(%{"other" => %{}}) == %{"other" => %{}}
    salted = Nonce.with_nonce_salt(%{"mppx" => %{"info" => nil, "schema" => %{}}})
    assert byte_size(salted["mppx"]["info"]["nonce"]) == 64
    assert salted["mppx"]["schema"] == %{}
  end
end
