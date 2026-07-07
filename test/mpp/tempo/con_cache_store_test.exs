defmodule MPP.Tempo.ConCacheStoreTest do
  use ExUnit.Case, async: true

  alias MPP.Tempo.ConCacheStore

  @ttl_ms 25
  @ttl_check_interval_ms 10
  @expiry_timeout_ms 250
  @poll_interval_ms 5
  @atomic_attempts 12
  @task_timeout_ms to_timeout(second: 5)

  setup do
    cache_name = unique_cache_name()

    start_supervised!(
      ConCacheStore.child_spec(
        name: cache_name,
        ttl: @ttl_ms,
        ttl_check_interval: @ttl_check_interval_ms
      )
    )

    {:ok, store_opts: [name: cache_name]}
  end

  describe "child_spec/1" do
    test "uses the default cache id when no name is configured" do
      spec = ConCacheStore.child_spec()

      assert spec.id == {ConCacheStore, :mpp_tempo_dedup}

      assert {ConCache, :start_link, [[name: :mpp_tempo_dedup, ttl_check_interval: _, global_ttl: global_ttl]]} =
               spec.start

      assert global_ttl == to_timeout(minute: 10)
    end

    test "uses a custom cache id when name is configured" do
      cache_name = unique_cache_name()
      spec = ConCacheStore.child_spec(name: cache_name)

      assert spec.id == {ConCacheStore, cache_name}
      assert {ConCache, :start_link, [[name: ^cache_name, ttl_check_interval: _, global_ttl: _]]} = spec.start
    end
  end

  describe "get/2 and put/3" do
    test "stores and retrieves values", %{store_opts: store_opts} do
      key = "mpp:charge:put"
      value = %{tx_hash: "0xabc"}

      assert :not_found = ConCacheStore.get(key, store_opts)
      assert :ok = ConCacheStore.put(key, value, store_opts)
      assert {:ok, ^value} = ConCacheStore.get(key, store_opts)
    end
  end

  describe "TTL expiry" do
    test "expires stored values after the configured TTL", %{store_opts: store_opts} do
      key = "mpp:charge:ttl"

      assert :ok = ConCacheStore.put(key, :seen, store_opts)
      assert {:ok, :seen} = ConCacheStore.get(key, store_opts)

      assert_eventually_not_found(key, store_opts)
    end
  end

  describe "check_and_mark/3" do
    test "marks a new key and rejects an existing key", %{store_opts: store_opts} do
      key = "mpp:charge:single"

      assert :ok = ConCacheStore.check_and_mark(key, :first, store_opts)
      assert {:error, :already_exists} = ConCacheStore.check_and_mark(key, :second, store_opts)
      assert {:ok, :first} = ConCacheStore.get(key, store_opts)
    end

    test "atomically allows only one concurrent mark per key", %{store_opts: store_opts} do
      key = "mpp:charge:atomic"
      parent = self()

      tasks =
        for attempt <- 1..@atomic_attempts do
          Task.async(fn ->
            send(parent, {:ready, attempt})

            receive do
              :go -> ConCacheStore.check_and_mark(key, {:attempt, attempt}, store_opts)
            after
              @task_timeout_ms -> {:error, :not_released}
            end
          end)
        end

      for attempt <- 1..@atomic_attempts do
        assert_receive {:ready, ^attempt}, @task_timeout_ms
      end

      Enum.each(tasks, fn task -> send(task.pid, :go) end)

      results = Task.await_many(tasks, @task_timeout_ms)
      unexpected = Enum.reject(results, &(&1 in [:ok, {:error, :already_exists}]))

      assert unexpected == []
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_exists})) == @atomic_attempts - 1
      assert {:ok, {:attempt, winner}} = ConCacheStore.get(key, store_opts)
      assert winner in 1..@atomic_attempts
    end
  end

  defp assert_eventually_not_found(key, store_opts) do
    deadline = System.monotonic_time(:millisecond) + @expiry_timeout_ms
    wait_until_not_found(key, store_opts, deadline)
  end

  defp wait_until_not_found(key, store_opts, deadline) do
    case ConCacheStore.get(key, store_opts) do
      :not_found ->
        :ok

      {:ok, _value} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("expected #{inspect(key)} to expire within #{@expiry_timeout_ms}ms")
        else
          Process.sleep(@poll_interval_ms)
          wait_until_not_found(key, store_opts, deadline)
        end
    end
  end

  defp unique_cache_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end
end
