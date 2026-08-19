defmodule MPP.Session.StoreTest do
  use ExUnit.Case, async: true

  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Store

  @update_count 12

  setup do
    name = unique_store_name()
    start_supervised!(ETSStore.child_spec(name: name))
    {:ok, store: {ETSStore, [name: name]}}
  end

  describe "default and custom stores" do
    test "exposes the ETS-backed default" do
      assert Store.default_store() == ETSStore
    end

    test "dispatches get, put, update, and delete", %{store: store} do
      channel = channel()

      assert :not_found = Store.get(store, channel.channel_id)
      assert :ok = Store.put(store, channel)
      assert {:ok, ^channel} = Store.get(store, channel.channel_id)

      assert {:ok, active} = Store.update(store, channel.channel_id, &Channel.activate/1)
      assert active.status == :active
      assert {:ok, ^active} = Store.get(store, channel.channel_id)

      assert :ok = Store.delete(store, channel.channel_id)
      assert :not_found = Store.get(store, channel.channel_id)
    end

    test "dispatches bare store modules through their default instance" do
      channel = %{channel() | channel_id: "0x" <> String.duplicate("44", 32)}

      assert :ok = Store.delete(ETSStore, channel.channel_id)
      assert :not_found = Store.get(ETSStore, channel.channel_id)
      assert :ok = Store.put(ETSStore, channel)

      assert {:ok, active} =
               Store.update(ETSStore, channel.channel_id, &Channel.activate/1)

      assert active.status == :active
      assert {:ok, ^active} = ETSStore.get(channel.channel_id)
      assert :ok = ETSStore.delete(channel.channel_id)
      assert :not_found = ETSStore.get(channel.channel_id)
    end
  end

  describe "atomic updates" do
    test "serializes concurrent read-modify-write callbacks", %{store: store} do
      channel = channel()
      assert :ok = Store.put(store, channel)

      results =
        1..@update_count
        |> Enum.map(fn _attempt ->
          Task.async(fn ->
            Store.update(store, channel.channel_id, fn current ->
              {:ok, %{current | deposit: current.deposit + 1}}
            end)
          end)
        end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %Channel{}}, &1))
      assert {:ok, updated} = Store.get(store, channel.channel_id)
      assert updated.deposit == channel.deposit + @update_count
    end

    test "does not persist failed or mismatched updates", %{store: store} do
      channel = channel()
      assert :ok = Store.put(store, channel)

      assert {:error, :rejected} =
               Store.update(store, channel.channel_id, fn _current -> {:error, :rejected} end)

      other_channel = %{channel | channel_id: "0x" <> String.duplicate("22", 32)}

      assert {:error, :channel_id_mismatch} =
               Store.update(store, channel.channel_id, fn _current -> {:ok, other_channel} end)

      assert {:error, {:invalid_update_result, :bad}} =
               Store.update(store, channel.channel_id, fn _current -> :bad end)

      assert {:ok, ^channel} = Store.get(store, channel.channel_id)
    end

    test "passes :not_found to updates for absent channels", %{store: store} do
      channel = channel()

      assert {:ok, ^channel} =
               Store.update(store, channel.channel_id, fn :not_found -> {:ok, channel} end)

      assert {:ok, ^channel} = Store.get(store, channel.channel_id)
    end
  end

  describe "ETSStore" do
    test "normalizes channel IDs and rejects malformed keys", %{store: store} do
      channel = channel()
      assert :ok = Store.put(store, channel)

      assert {:ok, ^channel} = Store.get(store, uppercase_hex(channel.channel_id))
      assert {:error, {:invalid_channel_id, "0xdead"}} = Store.get(store, "0xdead")
      assert {:error, {:invalid_channel_id, "0xdead"}} = Store.delete(store, "0xdead")
    end

    test "builds distinct child specs for named instances" do
      assert ETSStore.child_spec().id == {ETSStore, ETSStore}
      assert ETSStore.child_spec(name: :custom_session_store).id == {ETSStore, :custom_session_store}
    end
  end

  defp channel do
    Channel.new!(
      channel_id: "0x" <> String.duplicate("11", 32),
      payer: "0x1111111111111111111111111111111111111111",
      recipient: "0x2222222222222222222222222222222222222222",
      token: "0x3333333333333333333333333333333333333333",
      deposit: 1_000
    )
  end

  defp unique_store_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end

  defp uppercase_hex("0x" <> hex), do: "0x" <> String.upcase(hex)
end
