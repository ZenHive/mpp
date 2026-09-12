defmodule MPP.Methods.XRPL.RedeemLockTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.XRPL.RedeemLock

  test "with_account serializes callers for one Destination" do
    address = "rLock#{System.unique_integer([:positive])}"
    order = :atomics.new(1, [])
    parent = self()

    task = fn tag ->
      Task.async(fn ->
        RedeemLock.with_account(address, fn ->
          n = :atomics.add_get(order, 1, 1)
          send(parent, {:entered, tag, n})

          receive do
            :release -> tag
          end
        end)
      end)
    end

    first = task.(:a)
    second = task.(:b)
    assert_receive {:entered, first_tag, 1}

    receive do
    after
      20 -> :ok
    end

    refute_received {:entered, _, _}
    send(if(first_tag == :a, do: first.pid, else: second.pid), :release)
    assert_receive {:entered, second_tag, 2}
    send(if(second_tag == :a, do: first.pid, else: second.pid), :release)
    assert Enum.sort([Task.await(first), Task.await(second)]) == [:a, :b]
    refute first_tag == second_tag
  end

  test "a crashed holder unblocks the next waiter" do
    address = "rCrash#{System.unique_integer([:positive])}"
    parent = self()

    holder =
      spawn(fn ->
        RedeemLock.with_account(address, fn ->
          send(parent, :held)

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive :held
    Process.exit(holder, :kill)
    assert :released = RedeemLock.with_account(address, fn -> :released end)
  end
end
