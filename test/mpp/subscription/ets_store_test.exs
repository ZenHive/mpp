defmodule MPP.Subscription.ETSStoreTest do
  use ExUnit.Case, async: true

  alias MPP.Subscription.ETSStore
  alias MPP.Subscription.Record
  alias MPP.Subscription.Store
  alias MPP.Test.SubscriptionHelpers

  setup do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!(ETSStore.child_spec(name: name))
    {:ok, store: {ETSStore, [name: name]}}
  end

  test "stores, updates, and deletes subscription records", %{store: store} do
    record = record("sub_1")

    assert :not_found = Store.get(store, record.subscription_id)
    assert :ok = Store.put(store, record)
    assert {:ok, ^record} = Store.get(store, record.subscription_id)

    assert {:ok, updated} =
             Store.update(store, record.subscription_id, fn current ->
               {:ok, %{current | last_charged_period: 1}}
             end)

    assert updated.last_charged_period == 1
    assert :ok = Store.delete(store, record.subscription_id)
    assert :not_found = Store.get(store, record.subscription_id)
  end

  test "serializes concurrent updates atomically", %{store: store} do
    record = record("sub_atomic")
    assert :ok = Store.put(store, record)

    tasks =
      for _index <- 1..20 do
        Task.async(fn ->
          Store.update(store, record.subscription_id, fn current ->
            {:ok, %{current | last_charged_period: current.last_charged_period + 1}}
          end)
        end)
      end

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, %Record{}}, &1))
    assert {:ok, %{last_charged_period: 20}} = Store.get(store, record.subscription_id)
  end

  test "rejects invalid update results and changed identifiers", %{store: store} do
    record = record("sub_errors")
    assert :ok = Store.put(store, record)

    assert {:error, :subscription_id_mismatch} =
             Store.update(store, record.subscription_id, fn current ->
               {:ok, %{current | subscription_id: "different"}}
             end)

    assert {:error, {:invalid_update_result, :ok}} =
             Store.update(store, record.subscription_id, fn _current -> :ok end)

    assert {:error, :not_allowed} =
             Store.update(store, "missing", fn :not_found -> {:error, :not_allowed} end)
  end

  test "default store wrappers dispatch through the application-started store" do
    assert Store.default_store() == ETSStore
    assert %{start: {ETSStore, :start_link, [[]]}} = ETSStore.child_spec()
    assert {:error, {:already_started, pid}} = ETSStore.start_link()
    assert Process.alive?(pid)

    direct = record("default_direct_#{System.unique_integer([:positive])}")
    assert :not_found = ETSStore.get(direct.subscription_id)
    assert :ok = ETSStore.put(direct)

    assert {:ok, updated} =
             ETSStore.update(direct.subscription_id, fn current ->
               {:ok, %{current | last_charged_period: 1}}
             end)

    assert updated.last_charged_period == 1
    assert :ok = ETSStore.delete(direct.subscription_id)

    dispatched = record("default_dispatched_#{System.unique_integer([:positive])}")
    assert :not_found = Store.get(ETSStore, dispatched.subscription_id)
    assert :ok = Store.put(ETSStore, dispatched)

    assert {:ok, _updated} =
             Store.update(ETSStore, dispatched.subscription_id, fn current ->
               {:ok, %{current | last_charged_period: 1}}
             end)

    assert :ok = Store.delete(ETSStore, dispatched.subscription_id)
  end

  defp record(id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %Record{
      subscription_id: id,
      method: "tempo",
      subscription: SubscriptionHelpers.subscription(),
      method_state: %{
        source: SubscriptionHelpers.root_address(),
        access_key: SubscriptionHelpers.access_address(),
        access_key_type: :secp256k1,
        key_authorization: "0x01"
      },
      billing_anchor: now,
      reference: "0x" <> String.duplicate("11", 32),
      timestamp: DateTime.to_iso8601(now)
    }
  end
end
