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
    assert_receive {:entered, first_tag, 1}

    second =
      Task.async(fn ->
        receive do
          :go ->
            RedeemLock.with_account(address, fn ->
              send(parent, {:entered, :b, :atomics.add_get(order, 1, 1)})

              receive do
                :release -> :b
              end
            end)
        end
      end)

    :erlang.trace_pattern({RedeemLock, :acquire, 3}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({RedeemLock, :acquire, 3}, false, [:local]) end)
    :erlang.trace(second.pid, true, [:running, :call])
    send(second.pid, :go)
    waiter = second.pid
    assert_receive {:trace, ^waiter, :call, {RedeemLock, :acquire, [^address, _, _]}}
    assert_receive {:trace, ^waiter, :out, {RedeemLock, :wait_for_owner, 3}}
    refute_receive {:trace, ^waiter, :call, {RedeemLock, :acquire, _}}, 50
    refute_received {:entered, _, _}
    :erlang.trace(waiter, false, [:running, :call])
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
    [{^address, lease}] = :ets.lookup(RedeemLock, address)
    lease_ref = Process.monitor(lease)
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :normal}
    assert {:error, %MPP.Errors{}} = RedeemLock.with_account(address, fn -> flunk("expired lease acquired") end, 0)
    assert :released = RedeemLock.with_account(address, fn -> :released end)
  end

  test "acquisition times out without running the callback and can be retried" do
    address = "rTimeout#{System.unique_integer([:positive])}"
    parent = self()

    holder =
      Task.async(fn ->
        RedeemLock.with_account(address, fn ->
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held
    started = System.monotonic_time(:millisecond)
    assert {:error, %MPP.Errors{type: type}} = RedeemLock.with_account(address, fn -> flunk("lease acquired") end, 30)
    assert type == MPP.Errors.new(:settlement_failed, "").type
    assert System.monotonic_time(:millisecond) - started >= 30
    assert Process.alive?(holder.pid)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert :retried = RedeemLock.with_account(address, fn -> :retried end, 0)
  end

  test "release wakes waiters even while the caller remains alive" do
    address = "rAlive#{System.unique_integer([:positive])}"
    parent = self()

    holder =
      Task.async(fn ->
        RedeemLock.with_account(address, fn ->
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)

        send(parent, :released)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :held
    waiter = Task.async(fn -> RedeemLock.with_account(address, fn -> :acquired end) end)
    send(holder.pid, :release)
    assert_receive :released
    assert :acquired = Task.await(waiter)
    assert Process.alive?(holder.pid)
    send(holder.pid, :finish)
    assert :ok = Task.await(holder)
  end

  test "callback exceptions release the lease" do
    address = "rRaise#{System.unique_integer([:positive])}"

    assert_raise RuntimeError, "boom", fn ->
      RedeemLock.with_account(address, fn -> raise "boom" end)
    end

    assert :ok = RedeemLock.with_account(address, fn -> :ok end)
  end

  test "a release does not renew an expired acquisition deadline" do
    address = "rDeadline#{System.unique_integer([:positive])}"
    parent = self()

    holder =
      Task.async(fn ->
        RedeemLock.with_account(address, fn ->
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held

    waiter =
      Task.async(fn ->
        receive do
          :go -> RedeemLock.with_account(address, fn -> send(parent, :acquired) end, 100)
        end
      end)

    pid = waiter.pid
    :erlang.trace(pid, true, [:running])
    send(pid, :go)
    assert_receive {:trace, ^pid, :out, {RedeemLock, :wait_for_owner, 3}}
    :erlang.suspend_process(pid)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    refute_receive :acquired, 110
    :erlang.resume_process(pid)
    assert {:error, %MPP.Errors{}} = Task.await(waiter)
  end
end
