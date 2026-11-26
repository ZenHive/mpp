defmodule MPP.Client.BudgetTest do
  use ExUnit.Case, async: true

  alias MPP.Client.Budget

  @token "0x20c0000000000000000000000000000000000000"
  @network "eip155:4217"

  defp usd(amount, decimals \\ 6) do
    %{
      method: "tempo",
      intent: "charge",
      network: @network,
      asset: @token,
      amount: amount,
      currency: "USD",
      decimals: decimals
    }
  end

  defp asset(amount, overrides \\ %{}) do
    Map.merge(
      %{
        method: "tempo",
        intent: "charge",
        network: @network,
        asset: @token,
        amount: amount,
        currency: nil,
        decimals: nil
      },
      overrides
    )
  end

  describe "start_link/1" do
    test "requires a well-formed total" do
      assert_raise KeyError, fn -> Budget.start_link([]) end
      assert_raise ArgumentError, ~r/non-negative decimal/, fn -> Budget.start_link(total: {"5.", "USD"}) end
      assert_raise ArgumentError, ~r/:total needs/, fn -> Budget.start_link(total: %{asset: @token, amount: 1}) end
    end

    test "registers under a name" do
      name = :"budget_#{System.unique_integer([:positive])}"
      start_supervised!({Budget, total: {"5", "usd"}, name: name})

      assert Budget.total(name) == {"5", "USD"}
    end
  end

  describe "a money budget" do
    setup do
      %{budget: start_supervised!({Budget, total: {"5", "USD"}})}
    end

    # refs/mppx/src/client/Budget.ts: amounts are kept at the finest scale seen.
    test "counts payments at the token's decimals", %{budget: budget} do
      assert {:ok, first} = Budget.reserve(budget, usd(10_000))
      assert Budget.reserved(budget) == {"0.01", "USD"}
      assert Budget.remaining(budget) == {"4.99", "USD"}
      assert Budget.spent(budget) == {"0", "USD"}

      assert :ok = Budget.commit(budget, first)
      assert Budget.spent(budget) == {"0.01", "USD"}
      assert Budget.reserved(budget) == {"0", "USD"}

      # A later payment in a token with more decimals raises the scale of what is held.
      assert {:ok, second} = Budget.reserve(budget, usd(1, 8))
      assert Budget.remaining(budget) == {"4.98999999", "USD"}
      assert Budget.spent(budget) == {"0.01", "USD"}
      assert :ok = Budget.release(budget, second)
      assert Budget.remaining(budget) == {"4.99", "USD"}
      assert Budget.total(budget) == {"5", "USD"}
    end

    test "refuses what does not fit, at the exact boundary", %{budget: budget} do
      assert {:ok, _reservation} = Budget.reserve(budget, usd(4_999_999))
      assert Budget.reserve(budget, usd(2)) == {:error, :amount}
      assert {:ok, _reservation} = Budget.reserve(budget, usd(1))
      assert Budget.reserve(budget, usd(1)) == {:error, :amount}
      assert {:ok, _free} = Budget.reserve(budget, usd(0))
      assert Budget.remaining(budget) == {"0", "USD"}
    end

    test "refuses a payment whose currency and decimals the client does not configure", %{budget: budget} do
      assert Budget.reserve(budget, asset(1)) == {:error, :asset}
      assert Budget.reserve(budget, %{usd(1) | currency: "EUR"}) == {:error, :asset}
      assert Budget.reserve(budget, %{usd(1) | decimals: nil}) == {:error, :asset}
      assert Budget.remaining(budget) == {"5", "USD"}
    end
  end

  describe "an asset budget" do
    setup do
      %{
        budget:
          start_supervised!(
            {Budget, total: %{network: @network, asset: "0x20C0000000000000000000000000000000000000", amount: 100}}
          )
      }
    end

    test "counts atomic units of that asset only", %{budget: budget} do
      assert {:ok, reservation} = Budget.reserve(budget, asset(60))
      assert Budget.reserve(budget, asset(41)) == {:error, :amount}
      assert Budget.reserve(budget, asset(1, %{network: "eip155:42431"})) == {:error, :asset}
      assert Budget.reserve(budget, asset(1, %{asset: "0x20c000000000000000000000f37de3740ADec032"})) == {:error, :asset}

      assert :ok = Budget.commit(budget, reservation)
      assert %{amount: 60} = Budget.spent(budget)
      assert %{amount: 40, network: @network} = Budget.remaining(budget)
    end

    test "settles a reservation once", %{budget: budget} do
      assert {:ok, reservation} = Budget.reserve(budget, asset(60))
      assert :ok = Budget.release(budget, reservation)
      assert :ok = Budget.commit(budget, reservation)
      assert :ok = Budget.release(budget, make_ref())

      assert %{amount: 0} = Budget.spent(budget)
      assert %{amount: 100} = Budget.remaining(budget)
    end

    test "counts a reservation whose owner ended before settling it", %{budget: budget} do
      test_pid = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          {:ok, _reservation} = Budget.reserve(budget, asset(30))
          send(test_pid, :reserved)
        end)

      assert_receive :reserved
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

      # A read is handled after the owner's exit signal.
      assert %{amount: 0} = Budget.reserved(budget)
      assert %{amount: 30} = Budget.spent(budget)
    end

    test "concurrent reservations cannot overspend", %{budget: budget} do
      test_pid = self()

      tasks =
        for _n <- 1..50 do
          Task.async(fn ->
            send(test_pid, {:ready, self()})

            receive do
              :go -> Budget.reserve(budget, asset(7))
            end
          end)
        end

      # Barrier: every task is waiting before any may reserve.
      for _task <- tasks, do: assert_receive({:ready, _pid})
      for task <- tasks, do: send(task.pid, :go)
      results = Task.await_many(tasks)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 14
      assert Enum.count(results, &(&1 == {:error, :amount})) == 36
      # The tasks ended holding their reservations, so each one counts.
      assert %{amount: 98} = Budget.spent(budget)
      assert %{amount: 2} = Budget.remaining(budget)
    end
  end
end
