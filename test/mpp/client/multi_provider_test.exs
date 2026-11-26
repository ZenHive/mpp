defmodule MPP.Client.MultiProviderTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider
  alias MPP.Credential

  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defmodule ConfigProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, config) do
      method == config.required_method and intent == config.required_intent
    end

    @impl PaymentProvider
    def pay(challenge, config) do
      {:ok,
       %Credential{
         challenge: challenge,
         payload: %{
           "provider" => config.provider_id,
           "config_value" => config.config_value
         },
         source: nil
       }}
    end
  end

  defmodule AlwaysProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(_method, _intent, _config), do: true

    @impl PaymentProvider
    def pay(challenge, config) do
      {:ok,
       %Credential{
         challenge: challenge,
         payload: %{"provider" => config.provider_id},
         source: nil
       }}
    end
  end

  defmodule HashingProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, _intent, _config), do: method == "tempo"

    @impl PaymentProvider
    def pay(challenge, _config), do: {:ok, %Credential{challenge: challenge, payload: %{}, source: nil}}

    @impl PaymentProvider
    def transaction_hash(_credential, %{hash: hash}) when is_function(hash, 0), do: hash.()
    def transaction_hash(_credential, %{hash: hash}), do: hash
  end

  describe "transaction_hash/2" do
    test "asks the provider that pays the credential's challenge" do
      credential = %Credential{challenge: challenge(), payload: %{}, source: nil}
      multi = MultiProvider.new([{HashingProvider, %{hash: "0xabc"}}])

      assert MultiProvider.transaction_hash(multi, credential) == "0xabc"
    end

    test "is nil without the callback, without a provider, and when the provider fails" do
      credential = %Credential{challenge: challenge(), payload: %{}, source: nil}

      assert MultiProvider.transaction_hash(MultiProvider.new([{AlwaysProvider, %{provider_id: "a"}}]), credential) == nil
      assert MultiProvider.transaction_hash(MultiProvider.new([]), credential) == nil

      for hash <- [nil, 42, fn -> raise "boom" end, fn -> throw(:boom) end, fn -> exit(:boom) end] do
        multi = MultiProvider.new([{HashingProvider, %{hash: hash}}])
        assert MultiProvider.transaction_hash(multi, credential) == nil
      end
    end
  end

  describe "new/1 and add/3" do
    test "creates an empty provider list by default" do
      assert %MultiProvider{providers: []} = MultiProvider.new()
    end

    test "appends providers after existing entries" do
      multi =
        [{AlwaysProvider, %{provider_id: "first"}}]
        |> MultiProvider.new()
        |> MultiProvider.add(ConfigProvider, %{
          required_method: "tempo",
          required_intent: "charge",
          provider_id: "second",
          config_value: "value"
        })

      assert [{AlwaysProvider, _first_config}, {ConfigProvider, _second_config}] = multi.providers
    end
  end

  describe "supports?/3" do
    test "returns true when any provider supports the method and intent" do
      multi =
        MultiProvider.new([
          {ConfigProvider,
           %{
             required_method: "tempo",
             required_intent: "charge",
             provider_id: "tempo",
             config_value: "value"
           }}
        ])

      assert MultiProvider.supports?(multi, "tempo", "charge")
    end

    test "returns false for an empty provider list or no match" do
      refute MultiProvider.supports?(MultiProvider.new(), "tempo", "charge")

      multi =
        MultiProvider.new([
          {ConfigProvider,
           %{
             required_method: "stripe",
             required_intent: "charge",
             provider_id: "stripe",
             config_value: "value"
           }}
        ])

      refute MultiProvider.supports?(multi, "tempo", "charge")
    end
  end

  describe "pay/2" do
    test "routes to the first matching provider" do
      multi =
        MultiProvider.new([
          {AlwaysProvider, %{provider_id: "first"}},
          {AlwaysProvider, %{provider_id: "second"}}
        ])

      assert {:ok, credential} = MultiProvider.pay(multi, challenge())
      assert credential.payload == %{"provider" => "first"}
    end

    test "refuses a legacy-escaped challenge before any provider runs" do
      multi = MultiProvider.new([{AlwaysProvider, %{provider_id: "first"}}])
      legacy = %{challenge() | legacy_unicode_escape: true}

      assert {:error, :legacy_unicode_escape} = MultiProvider.pay(multi, legacy)
      assert {:error, :legacy_unicode_escape} = MultiProvider.pay(multi, legacy, %{request_url: nil})
    end

    test "returns unsupported_payment_method when no provider matches" do
      multi =
        MultiProvider.new([
          {ConfigProvider,
           %{
             required_method: "stripe",
             required_intent: "charge",
             provider_id: "stripe",
             config_value: "unused"
           }}
        ])

      assert {:error, :unsupported_payment_method} = MultiProvider.pay(multi, challenge(method: "tempo"))
    end

    test "passes the matched provider config through to supports and pay" do
      multi =
        MultiProvider.new([
          {ConfigProvider,
           %{
             required_method: "tempo",
             required_intent: "charge",
             provider_id: "tempo",
             config_value: "chosen-config"
           }}
        ])

      assert {:ok, credential} = MultiProvider.pay(multi, challenge(method: "tempo"))

      assert credential.payload == %{
               "provider" => "tempo",
               "config_value" => "chosen-config"
             }
    end
  end

  describe "pay/3" do
    test "merges the transport context over the selected provider config" do
      multi =
        MultiProvider.new([
          {ConfigProvider,
           %{required_method: "tempo", required_intent: "charge", provider_id: "tempo", config_value: "from-config"}}
        ])

      assert {:ok, credential} = MultiProvider.pay(multi, challenge(method: "tempo"), %{config_value: "from-context"})
      assert credential.payload == %{"provider" => "tempo", "config_value" => "from-context"}
    end
  end

  defp challenge(opts \\ []) do
    %Challenge{
      realm: "api.example.com",
      method: Keyword.get(opts, :method, "tempo"),
      intent: Keyword.get(opts, :intent, "charge"),
      request: @request
    }
  end
end
