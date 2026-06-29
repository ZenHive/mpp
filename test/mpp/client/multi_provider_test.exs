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

  defp challenge(opts \\ []) do
    %Challenge{
      realm: "api.example.com",
      method: Keyword.get(opts, :method, "tempo"),
      intent: Keyword.get(opts, :intent, "charge"),
      request: @request
    }
  end
end
