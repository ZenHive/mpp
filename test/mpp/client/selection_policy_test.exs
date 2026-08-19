defmodule MPP.Client.SelectionPolicyTest do
  use ExUnit.Case, async: true

  alias MPP.AcceptPayment
  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider
  alias MPP.Client.SelectionPolicy
  alias MPP.Client.Transport
  alias MPP.Credential

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defmodule TempoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "tempo" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, _config), do: {:ok, %Credential{challenge: challenge, payload: %{}, source: nil}}
  end

  defmodule StripeProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "stripe" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, _config), do: {:ok, %Credential{challenge: challenge, payload: %{}, source: nil}}
  end

  defp make_challenge(method) do
    Challenge.create(
      [realm: "api.example.com", method: method, intent: "charge", request: @request],
      @secret_key
    )
  end

  describe "default/0" do
    test "is server-advertised order" do
      assert SelectionPolicy.default() == :server_order
    end
  end

  describe "select/3" do
    test "server_order picks the first supported challenge" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      assert {:ok, challenge} = SelectionPolicy.select(challenges, multi, :server_order)
      assert challenge.method == "tempo"
    end

    test "skips unsupported offers and keeps server order" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{StripeProvider, %{}}])

      assert {:ok, challenge} = SelectionPolicy.select(challenges, multi)
      assert challenge.method == "stripe"
    end

    test "accept_payment ranks before picking" do
      challenges = [make_challenge("stripe"), make_challenge("tempo")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])
      prefs = AcceptPayment.parse("tempo/charge, stripe/charge;q=0.1")

      assert {:ok, challenge} =
               SelectionPolicy.select(challenges, multi, {:accept_payment, prefs})

      assert challenge.method == "tempo"
    end

    test "empty accept_payment preferences keep server order" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      assert {:ok, challenge} = SelectionPolicy.select(challenges, multi, {:accept_payment, []})
      assert challenge.method == "tempo"
    end

    test "custom function reorders supported challenges" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      assert {:ok, challenge} =
               SelectionPolicy.select(challenges, multi, fn supported -> Enum.reverse(supported) end)

      assert challenge.method == "stripe"
    end

    test "custom function can reject every candidate" do
      challenges = [make_challenge("tempo")]
      multi = MultiProvider.new([{TempoProvider, %{}}])

      assert {:error, :no_supported_challenge} =
               SelectionPolicy.select(challenges, multi, fn _supported -> [] end)
    end

    test "non-list function result is treated as no match" do
      challenges = [make_challenge("tempo")]
      multi = MultiProvider.new([{TempoProvider, %{}}])

      assert {:error, :no_supported_challenge} =
               SelectionPolicy.select(challenges, multi, fn _supported -> :drop end)
    end

    test "returns error when no challenge is supported" do
      assert {:error, :no_supported_challenge} =
               SelectionPolicy.select([make_challenge("tempo")], MultiProvider.new([]))
    end

    test "returns error on an empty challenge list" do
      assert {:error, :no_supported_challenge} =
               SelectionPolicy.select([], MultiProvider.new([{TempoProvider, %{}}]))
    end
  end

  describe "Transport.select_challenge/3" do
    test "delegates a custom :selection policy" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      assert {:ok, challenge} =
               Transport.select_challenge(challenges, multi, selection: fn supported -> Enum.reverse(supported) end)

      assert challenge.method == "stripe"
    end
  end
end
