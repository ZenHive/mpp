defmodule MPP.Client.SpendTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.Budget
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentLimitExceededError
  alias MPP.Client.PaymentOutcomeUnknownError
  alias MPP.Client.PaymentProvider
  alias MPP.Client.Spend
  alias MPP.Credential

  @token "0x20C0000000000000000000000000000000000000"
  @network "eip155:4217"
  @tokens [%{network: @network, asset: @token, currency: "usd", decimals: 6}]

  defmodule Provider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(_method, _intent, _config), do: true

    @impl PaymentProvider
    def pay(challenge, %{outcome: :ok} = config) do
      if pid = config[:test_pid], do: send(pid, {:paid_with, Map.take(config, [:spend_checked, :request_url])})
      if budget = config[:stop], do: GenServer.stop(budget)
      {:ok, %Credential{challenge: challenge, payload: %{}, source: nil}}
    end

    def pay(_challenge, %{outcome: :error}), do: {:error, :insufficient_funds}
    def pay(_challenge, %{outcome: :unknown}), do: {:error, %PaymentOutcomeUnknownError{}}
    def pay(_challenge, %{outcome: :raise}), do: raise("signer crashed")
    def pay(_challenge, %{outcome: :exit}), do: exit(:signer_down)
  end

  defp challenge(request, opts \\ []) do
    %Challenge{
      id: Keyword.get(opts, :id, "challenge-1"),
      realm: "api.example.com",
      method: Keyword.get(opts, :method, "tempo"),
      intent: Keyword.get(opts, :intent, "charge"),
      request: request |> Jason.encode!() |> Base.url_encode64(padding: false)
    }
  end

  defp tempo_charge(amount, extra \\ %{}) do
    challenge(Map.merge(%{"amount" => amount, "currency" => @token, "methodDetails" => %{"chainId" => 4217}}, extra))
  end

  defp refused(limit, reason), do: {:error, %PaymentLimitExceededError{limit: limit, reason: reason}}

  describe "new/1" do
    test "is nil without a limit or a budget" do
      assert Spend.new([]) == nil
      assert Spend.new(provider: :ignored, tokens: @tokens) == nil
      assert %Spend{} = Spend.new(max_payment: {"1", "USD"})
      assert %Spend{budget: :some_budget} = Spend.new(budget: :some_budget)
    end

    test "rejects malformed options" do
      for {opts, message} <- [
            {[max_payment: {"-1", "USD"}], ~r/non-negative decimal/},
            {[max_payment: {"1e3", "USD"}], ~r/non-negative decimal/},
            {[max_payment: {"1", " "}], ~r/currency/},
            {[max_payment: "1 USD"], ~r/:max_payment must be/},
            {[max_payment: [%{network: @network, asset: @token, amount: -1}]], ~r/non-negative integer :amount/},
            {[max_payment: [%{network: @network, asset: @token, amount: 1.5}]], ~r/non-negative integer :amount/},
            {[
               max_payment: [
                 %{network: @network, asset: @token, amount: 1},
                 %{network: @network, asset: String.downcase(@token), amount: 2}
               ]
             ], ~r/duplicate :max_payment limit/},
            {[budget: "name"], ~r/:budget must be/},
            {[max_payment: {"1", "USD"}, tokens: :all], ~r/:tokens must be a list/},
            {[max_payment: {"1", "USD"}, tokens: [%{network: @network, asset: @token, currency: "USD"}]],
             ~r/each token needs/},
            {[max_payment: {"1", "USD"}, tokens: [%{network: @network, asset: @token, currency: "USD", decimals: 256}]],
             ~r/each token needs/},
            {[
               max_payment: {"1", "USD"},
               tokens: @tokens ++ [%{network: @network, asset: String.downcase(@token), currency: "USD", decimals: 18}]
             ], ~r/conflicting metadata/}
          ] do
        assert_raise ArgumentError, message, fn -> Spend.new(opts) end
      end
    end
  end

  describe "check/2 with per-asset limits" do
    setup do
      %{spend: Spend.new(max_payment: [%{network: @network, asset: String.downcase(@token), amount: 500_000}])}
    end

    test "passes at the limit and refuses above it", %{spend: spend} do
      assert {:ok, %{network: @network, asset: @token, amount: 500_000, method: "tempo", intent: "charge"}} =
               Spend.check(spend, tempo_charge("500000"))

      assert Spend.check(spend, tempo_charge("500001")) == refused(:max_payment, :amount)
      # As the signers read it: leading zeroes included.
      assert {:ok, %{amount: 7}} = Spend.check(spend, tempo_charge("007"))
    end

    test "refuses an asset or a network no limit names", %{spend: spend} do
      other_chain = challenge(%{"amount" => "1", "currency" => @token, "methodDetails" => %{"chainId" => 42_431}})
      other_asset = tempo_charge("1", %{"currency" => "0x20c000000000000000000000f37de3740ADec032"})
      no_chain = challenge(%{"amount" => "1", "currency" => @token})

      for challenge <- [other_chain, other_asset, no_chain] do
        assert Spend.check(spend, challenge) == refused(:max_payment, :asset)
      end
    end

    test "names the network after the method when the challenge names no chain" do
      spend = Spend.new(max_payment: [%{network: "stripe", asset: "USD", amount: 1_000}])
      stripe = challenge(%{"amount" => "1000", "currency" => "usd"}, method: "stripe")

      assert {:ok, %{network: "stripe", asset: "usd", amount: 1_000}} = Spend.check(spend, stripe)
      assert Spend.check(spend, challenge(%{"amount" => "1000", "currency" => "usd"})) == refused(:max_payment, :asset)
    end
  end

  describe "check/2 with a money limit" do
    setup do
      %{spend: Spend.new(max_payment: {"0.50", "usd"}, tokens: @tokens)}
    end

    test "converts with the configured decimals", %{spend: spend} do
      assert {:ok, %{currency: "USD", decimals: 6}} = Spend.check(spend, tempo_charge("500000"))
      assert Spend.check(spend, tempo_charge("500001")) == refused(:max_payment, :amount)
    end

    # refs/mppx/src/client/internal/SpendGate.ts `requirement`: a server cannot
    # change what a limit counts.
    test "ignores the currency and decimals a challenge claims", %{spend: spend} do
      claims = %{"decimals" => 18, "methodDetails" => %{"chainId" => 4217, "decimals" => 18, "currency" => "JPY"}}

      assert Spend.check(spend, tempo_charge("500001", claims)) == refused(:max_payment, :amount)
      assert {:ok, %{decimals: 6, currency: "USD"}} = Spend.check(spend, tempo_charge("500000", claims))
    end

    test "refuses an asset the client does not configure, and one in another currency", %{spend: spend} do
      unlisted = tempo_charge("1", %{"currency" => "0x20c000000000000000000000f37de3740ADec032"})
      assert Spend.check(spend, unlisted) == refused(:max_payment, :asset)
      assert Spend.check(spend, tempo_charge("0", %{"currency" => "usd"})) == refused(:max_payment, :asset)

      euros = Spend.new(max_payment: {"0.50", "EUR"}, tokens: @tokens)
      assert Spend.check(euros, tempo_charge("1")) == refused(:max_payment, :asset)
    end

    test "drops digits beyond the token's decimals, which lowers the limit" do
      spend = Spend.new(max_payment: {"0.0000019", "USD"}, tokens: @tokens)

      assert {:ok, _requirement} = Spend.check(spend, tempo_charge("1"))
      assert Spend.check(spend, tempo_charge("2")) == refused(:max_payment, :amount)
    end
  end

  describe "check/2" do
    test "passes everything without a gate" do
      assert Spend.check(nil, challenge(%{"amount" => "x"}, intent: "session")) == {:ok, nil}
    end

    test "refuses intents whose total is not known up front" do
      for intent <- ["session", "subscription"] do
        session = challenge(%{"amount" => "1", "currency" => @token}, intent: intent)

        assert Spend.check(Spend.new(max_payment: {"1", "USD"}, tokens: @tokens), session) ==
                 refused(:max_payment, :intent)

        assert Spend.check(Spend.new(budget: :unused), session) == refused(:budget, :intent)
      end
    end

    # refs/mppx/src/client/internal/SpendGate.ts `mppFields` / `atomicAmount`.
    test "refuses a challenge whose terms cannot be read" do
      spend = Spend.new(max_payment: [%{network: @network, asset: @token, amount: 10}])

      unreadable = [
        tempo_charge("1.5"),
        tempo_charge("-1"),
        tempo_charge(""),
        tempo_charge(1),
        tempo_charge("1", %{"currency" => ""}),
        tempo_charge("1", %{"currency" => nil}),
        tempo_charge("1", %{"chainId" => 1}),
        tempo_charge("1", %{"methodDetails" => %{"chainId" => "4217"}}),
        tempo_charge("1", %{"methodDetails" => %{"chainId" => 0}}),
        tempo_charge("1", %{"methodDetails" => %{"chainId" => nil}}),
        challenge(%{"amount" => "1", "currency" => @token, "methodDetails" => %{"chainId" => 4217}}, method: "stripe"),
        %{tempo_charge("1") | request: "not-base64-json"},
        %{tempo_charge("1") | request: Base.url_encode64(~s(["amount"]), padding: false)}
      ]

      for challenge <- unreadable do
        assert Spend.check(spend, challenge) == refused(:max_payment, :challenge)
      end

      # A top-level chain that agrees with the one the method signs on is fine.
      assert {:ok, _requirement} = Spend.check(spend, tempo_charge("1", %{"chainId" => 4217}))
    end

    test "reads an x402 offer's own network, asset and amount" do
      offer =
        challenge(
          %{
            "scheme" => "exact",
            "network" => "eip155:8453",
            "amount" => "2500",
            "asset" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
            "payTo" => "0x1111111111111111111111111111111111111111",
            "maxTimeoutSeconds" => 60
          },
          id: "x402:0",
          method: "evm"
        )

      spend =
        Spend.new(
          max_payment: {"0.0025", "USD"},
          tokens: [
            %{
              network: "eip155:8453",
              asset: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
              currency: "USD",
              decimals: 6
            }
          ]
        )

      assert {:ok, %{network: "eip155:8453", amount: 2500, decimals: 6}} = Spend.check(spend, offer)

      assert Spend.check(
               Spend.new(max_payment: {"0.0024", "USD"}, tokens: spend.tokens |> Map.to_list() |> tokens()),
               offer
             ) ==
               refused(:max_payment, :amount)
    end
  end

  defp tokens(entries) do
    for {{network, asset}, {currency, decimals}} <- entries,
        do: %{network: network, asset: asset, currency: currency, decimals: decimals}
  end

  describe "pay/4" do
    setup do
      budget = start_supervised!({Budget, total: %{network: @network, asset: @token, amount: 1_000}})
      %{budget: budget, spend: Spend.new(budget: budget)}
    end

    defp pay(context, outcome, amount \\ "400") do
      multi = MultiProvider.new([{Provider, %{outcome: outcome}}])
      Spend.pay(context.spend, multi, tempo_charge(amount), %{request_url: nil})
    end

    defp amounts(budget), do: {Budget.spent(budget).amount, Budget.reserved(budget).amount}

    test "commits once the provider returns a credential", %{budget: budget} = context do
      assert {:ok, %Credential{}} = pay(context, :ok)
      assert amounts(budget) == {400, 0}
    end

    test "releases when the provider returns an error", %{budget: budget} = context do
      assert pay(context, :error) == {:error, :insufficient_funds}
      assert amounts(budget) == {0, 0}
    end

    test "stays committed when the provider raises or exits", %{budget: budget} = context do
      assert_raise RuntimeError, "signer crashed", fn -> pay(context, :raise) end
      assert amounts(budget) == {400, 0}

      assert catch_exit(pay(context, :exit)) == :signer_down
      assert amounts(budget) == {800, 0}
    end

    # refs/mppx/src/client/internal/SpendGate.ts `track`: an error after which
    # funds may have moved commits.
    test "stays committed when the provider reports an unknown outcome", %{budget: budget} = context do
      assert {:error, %PaymentOutcomeUnknownError{}} = pay(context, :unknown)
      assert amounts(budget) == {400, 0}
    end

    test "refuses what the budget cannot hold or count, before the provider runs", %{budget: budget} = context do
      assert {:ok, _credential} = pay(context, :ok)
      assert {:ok, _credential} = pay(context, :ok)
      # 200 remain; the provider would raise if it were asked.
      assert pay(context, :raise) == refused(:budget, :amount)

      other = tempo_charge("1", %{"currency" => "0x20c000000000000000000000f37de3740ADec032"})
      multi = MultiProvider.new([{Provider, %{outcome: :raise}}])
      assert Spend.pay(context.spend, multi, other, %{}) == refused(:budget, :asset)
      assert amounts(budget) == {800, 0}
    end

    test "checks the challenge it pays against its own limit", %{budget: budget} do
      spend = Spend.new(max_payment: [%{network: @network, asset: @token, amount: 300}], budget: budget)
      multi = MultiProvider.new([{Provider, %{outcome: :raise}}])

      assert Spend.pay(spend, multi, tempo_charge("301"), %{}) == refused(:max_payment, :amount)
      assert Spend.pay(spend, multi, tempo_charge("1", %{"chainId" => 1}), %{}) == refused(:max_payment, :challenge)

      session = challenge(%{"amount" => "1", "currency" => @token}, intent: "session")
      assert Spend.pay(spend, multi, session, %{}) == refused(:max_payment, :intent)
      assert amounts(budget) == {0, 0}
    end

    test "refuses an expired challenge before anything is reserved", %{budget: budget} = context do
      multi = MultiProvider.new([{Provider, %{outcome: :raise}}])
      past = DateTime.utc_now() |> DateTime.shift(second: -1) |> DateTime.to_iso8601()
      future = DateTime.utc_now() |> DateTime.shift(minute: 1) |> DateTime.to_iso8601()

      assert Spend.check(context.spend, %{tempo_charge("400") | expires: past}) == {:error, :challenge_expired}
      assert Spend.pay(context.spend, multi, %{tempo_charge("400") | expires: past}, %{}) == {:error, :challenge_expired}

      assert Spend.pay(context.spend, multi, %{tempo_charge("400") | expires: "soon"}, %{}) ==
               refused(:budget, :challenge)

      assert amounts(budget) == {0, 0}

      ok = MultiProvider.new([{Provider, %{outcome: :ok}}])
      assert {:ok, %Credential{}} = Spend.pay(context.spend, ok, %{tempo_charge("400") | expires: future}, %{})
    end

    test "releases when the challenge expired while the reservation was awaited", %{budget: budget} = context do
      multi = MultiProvider.new([{Provider, %{outcome: :raise}}])
      expires = DateTime.utc_now() |> DateTime.add(300, :millisecond) |> DateTime.to_iso8601()
      charge = %{tempo_charge("400") | expires: expires}

      # The budget answers only after the challenge has expired.
      :sys.suspend(budget)
      task = Task.async(fn -> Spend.pay(context.spend, multi, charge, %{}) end)
      Process.sleep(400)
      :sys.resume(budget)

      assert Task.await(task) == {:error, :challenge_expired}
      assert amounts(budget) == {0, 0}
    end

    test "pays straight through without a gate, and tells the provider when a gate checked" do
      multi = MultiProvider.new([{Provider, %{outcome: :ok, test_pid: self()}}])

      assert {:ok, %Credential{}} = Spend.pay(nil, multi, tempo_charge("400"), %{request_url: "u"})
      assert_received {:paid_with, %{request_url: "u"} = config}
      refute Map.has_key?(config, :spend_checked)

      limit = Spend.new(max_payment: [%{network: @network, asset: @token, amount: 400}])
      assert {:ok, %Credential{}} = Spend.pay(limit, multi, tempo_charge("400"), %{})
      assert_received {:paid_with, %{spend_checked: true}}
    end

    test "keeps the credential when the budget ended during the payment" do
      {:ok, budget} = Budget.start_link(total: %{network: @network, asset: @token, amount: 1_000})
      Process.unlink(budget)
      multi = MultiProvider.new([{Provider, %{outcome: :ok, stop: budget}}])

      assert {:ok, %Credential{}} = Spend.pay(Spend.new(budget: budget), multi, tempo_charge("400"), %{})
      refute Process.alive?(budget)
    end
  end
end
