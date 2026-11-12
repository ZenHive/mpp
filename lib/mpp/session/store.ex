defmodule MPP.Session.Store do
  @moduledoc """
  Behaviour and dispatch helpers for pluggable session-channel persistence.

  Updates are atomic read-modify-write operations. A backend must invoke the
  callback and persist its successful result without another update to the
  same channel interleaving between those steps.

  `MPP.Session.ETSStore` is the application-started single-node default.

  Channels read through `get/2` and `update/3` pass through
  `MPP.Session.Channel.upgrade/1`, so a channel persisted by an earlier release
  gains the defaults of fields added since.
  """

  alias MPP.InstanceLocal
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore

  @type store_ref :: module() | {module(), keyword()}
  @type update_fun :: (Channel.t() | :not_found -> {:ok, Channel.t()} | {:error, term()})

  @doc "Return the application-started ETS store."
  @spec default_store() :: module()
  def default_store, do: ETSStore

  @doc """
  Resolve a route's configured session store at verification time.

  `nil` falls back to `default_store/0`, except on a multi-instance runtime
  (see `MPP.Tempo.Store.for_method/2`), where it raises `ArgumentError`:
  channel balances kept per node would let one voucher be spent on each
  instance. Naming the store, `MPP.Session.ETSStore` included, never raises.
  """
  @spec for_method(store_ref() | nil, String.t()) :: store_ref()
  def for_method(nil, method) when is_binary(method) do
    InstanceLocal.default!(ETSStore, method: method, option: "session_store", behaviour: __MODULE__)
  end

  def for_method(store, method) when is_binary(method), do: store

  @doc "Look up a channel by ID."
  @callback get(channel_id :: String.t()) ::
              {:ok, Channel.t()} | :not_found | {:error, term()}

  @doc "Insert or replace channel state."
  @callback put(channel :: Channel.t()) :: :ok | {:error, term()}

  @doc "Atomically update channel state."
  @callback update(channel_id :: String.t(), fun :: update_fun()) ::
              {:ok, Channel.t()} | {:error, term()}

  @doc "Delete channel state."
  @callback delete(channel_id :: String.t()) :: :ok | {:error, term()}

  @doc "Look up a channel through a store reference."
  @spec get(store_ref(), String.t()) ::
          {:ok, Channel.t()} | :not_found | {:error, term()}
  def get(store, channel_id), do: store |> raw_get(channel_id) |> upgrade_result()

  @doc "Insert or replace a channel through a store reference."
  @spec put(store_ref(), Channel.t()) :: :ok | {:error, term()}
  def put({ETSStore, opts}, channel), do: ETSStore.put(channel, opts)
  def put(store, channel), do: store.put(channel)

  @doc "Atomically update a channel through a store reference."
  @spec update(store_ref(), String.t(), update_fun()) ::
          {:ok, Channel.t()} | {:error, term()}
  def update(store, channel_id, fun) do
    store
    |> raw_update(channel_id, fn current -> current |> upgrade_current() |> fun.() end)
    |> upgrade_result()
  end

  @doc "Delete a channel through a store reference."
  @spec delete(store_ref(), String.t()) :: :ok | {:error, term()}
  def delete({ETSStore, opts}, channel_id), do: ETSStore.delete(channel_id, opts)
  def delete(store, channel_id), do: store.delete(channel_id)

  defp raw_get({ETSStore, opts}, channel_id), do: ETSStore.get(channel_id, opts)
  defp raw_get(store, channel_id), do: store.get(channel_id)

  defp raw_update({ETSStore, opts}, channel_id, fun), do: ETSStore.update(channel_id, fun, opts)
  defp raw_update(store, channel_id, fun), do: store.update(channel_id, fun)

  defp upgrade_current(%Channel{} = channel), do: Channel.upgrade(channel)
  defp upgrade_current(other), do: other

  defp upgrade_result({:ok, %Channel{} = channel}), do: {:ok, Channel.upgrade(channel)}
  defp upgrade_result(other), do: other
end
