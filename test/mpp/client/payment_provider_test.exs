defmodule MPP.Client.PaymentProviderTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  # -- Mock providers for testing -------------------------------------------------

  defmodule TempoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config) do
      method == "tempo" and intent == "charge"
    end

    @impl PaymentProvider
    def pay(challenge, _config) do
      {:ok,
       %MPP.Credential{
         challenge: challenge,
         payload: %{"type" => "hash", "hash" => "0xabc123"},
         source: nil
       }}
    end
  end

  defmodule StripeProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config) do
      method == "stripe" and intent == "charge"
    end

    @impl PaymentProvider
    def pay(challenge, config) do
      {:ok,
       %MPP.Credential{
         challenge: challenge,
         payload: %{"spt" => "spt_#{config[:token_suffix] || "test"}"},
         source: nil
       }}
    end
  end

  defmodule FailingProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(_method, _intent, _config), do: true

    @impl PaymentProvider
    def pay(_challenge, _config) do
      {:error, :payment_failed}
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp make_challenge(opts \\ []) do
    defaults = [
      realm: "api.example.com",
      method: opts[:method] || "tempo",
      intent: opts[:intent] || "charge",
      request: @request
    ]

    Challenge.create(defaults, @secret_key)
  end

  # -- PaymentProvider behaviour -------------------------------------------------

  describe "PaymentProvider.supports?/4" do
    test "delegates to module's supports?/3" do
      assert PaymentProvider.supports?(TempoProvider, "tempo", "charge", %{})
      refute PaymentProvider.supports?(TempoProvider, "stripe", "charge", %{})
      refute PaymentProvider.supports?(TempoProvider, "tempo", "session", %{})
    end
  end

  describe "PaymentProvider.pay/3" do
    test "delegates to module's pay/2 and returns credential" do
      challenge = make_challenge()
      assert {:ok, credential} = PaymentProvider.pay(TempoProvider, challenge, %{})
      assert credential.challenge == challenge
      assert credential.payload == %{"type" => "hash", "hash" => "0xabc123"}
    end

    test "passes config to provider" do
      challenge = make_challenge(method: "stripe")
      assert {:ok, credential} = PaymentProvider.pay(StripeProvider, challenge, %{token_suffix: "abc"})
      assert credential.payload == %{"spt" => "spt_abc"}
    end

    test "returns error from provider" do
      challenge = make_challenge()
      assert {:error, :payment_failed} = PaymentProvider.pay(FailingProvider, challenge, %{})
    end
  end

  # -- MultiProvider -------------------------------------------------------------

  describe "MultiProvider.new/1" do
    test "creates empty provider" do
      multi = MultiProvider.new()
      assert multi.providers == []
    end

    test "creates provider with list of entries" do
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])
      assert length(multi.providers) == 2
    end
  end

  describe "MultiProvider.add/3" do
    test "appends provider to the end" do
      multi =
        MultiProvider.new()
        |> MultiProvider.add(TempoProvider, %{})
        |> MultiProvider.add(StripeProvider, %{api_key: "sk_test"})

      assert [{TempoProvider, %{}}, {StripeProvider, %{api_key: "sk_test"}}] = multi.providers
    end
  end

  describe "MultiProvider.supports?/3" do
    test "returns true if any provider supports the method+intent" do
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      assert MultiProvider.supports?(multi, "tempo", "charge")
      assert MultiProvider.supports?(multi, "stripe", "charge")
    end

    test "returns false if no provider supports the method+intent" do
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      refute MultiProvider.supports?(multi, "bitcoin", "charge")
      refute MultiProvider.supports?(multi, "tempo", "session")
    end

    test "returns false for empty provider" do
      multi = MultiProvider.new()
      refute MultiProvider.supports?(multi, "tempo", "charge")
    end
  end

  describe "MultiProvider.pay/2" do
    test "dispatches to the correct provider" do
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      # Tempo challenge → TempoProvider
      tempo_challenge = make_challenge(method: "tempo")
      assert {:ok, credential} = MultiProvider.pay(multi, tempo_challenge)
      assert credential.payload["type"] == "hash"

      # Stripe challenge → StripeProvider
      stripe_challenge = make_challenge(method: "stripe")
      assert {:ok, credential} = MultiProvider.pay(multi, stripe_challenge)
      assert credential.payload["spt"] == "spt_test"
    end

    test "returns error when no provider matches" do
      multi = MultiProvider.new([{TempoProvider, %{}}])
      challenge = make_challenge(method: "bitcoin")

      assert {:error, :unsupported_payment_method} = MultiProvider.pay(multi, challenge)
    end

    test "returns error for empty provider" do
      multi = MultiProvider.new()
      challenge = make_challenge()

      assert {:error, :unsupported_payment_method} = MultiProvider.pay(multi, challenge)
    end

    test "first matching provider wins (priority ordering)" do
      # Both FailingProvider and TempoProvider support "tempo"+"charge"
      # FailingProvider is first → it wins (and returns error)
      multi = MultiProvider.new([{FailingProvider, %{}}, {TempoProvider, %{}}])
      challenge = make_challenge(method: "tempo")

      assert {:error, :payment_failed} = MultiProvider.pay(multi, challenge)
    end

    test "skips non-matching providers and finds the right one" do
      multi = MultiProvider.new([{StripeProvider, %{}}, {TempoProvider, %{}}])
      challenge = make_challenge(method: "tempo")

      # StripeProvider doesn't support "tempo", so TempoProvider handles it
      assert {:ok, credential} = MultiProvider.pay(multi, challenge)
      assert credential.payload["type"] == "hash"
    end

    test "passes provider-specific config to the matched provider" do
      multi =
        MultiProvider.new([
          {TempoProvider, %{rpc_url: "https://rpc.tempo.xyz"}},
          {StripeProvider, %{token_suffix: "custom"}}
        ])

      challenge = make_challenge(method: "stripe")
      assert {:ok, credential} = MultiProvider.pay(multi, challenge)
      assert credential.payload["spt"] == "spt_custom"
    end
  end
end
