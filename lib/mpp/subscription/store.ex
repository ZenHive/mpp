defmodule MPP.Subscription.Store do
  @moduledoc """
  Behaviour and dispatch helpers for method-neutral recurring-subscription
  persistence.

  Updates must be atomic so concurrent renewal attempts cannot charge the same
  billing period twice. `MPP.Subscription.ETSStore` is the single-node default.
  """

  alias MPP.InstanceLocal
  alias MPP.Subscription.ETSStore
  alias MPP.Subscription.Record

  @type store_ref :: module() | {module(), keyword()}
  @type update_fun :: (Record.t() | :not_found -> {:ok, Record.t()} | {:error, term()})

  @doc "Return the application-started subscription store."
  @spec default_store() :: module()
  def default_store, do: ETSStore

  @doc """
  Resolve a route's configured subscription store at runtime.

  `nil` falls back to `default_store/0`, except on a multi-instance runtime
  (see `MPP.Tempo.Store.for_method/2`), where it raises `ArgumentError`:
  records kept per node would let one billing period be charged on each
  instance. Naming the store, `MPP.Subscription.ETSStore` included, never raises.
  """
  @spec for_method(store_ref() | nil, String.t()) :: store_ref()
  def for_method(nil, method) when is_binary(method) do
    InstanceLocal.default!(ETSStore,
      method: method,
      option: ~s(method_config "subscription_store"),
      behaviour: __MODULE__
    )
  end

  def for_method(store, method) when is_binary(method), do: store

  @callback get(String.t()) :: {:ok, Record.t()} | :not_found | {:error, term()}
  @callback put(Record.t()) :: :ok | {:error, term()}
  @callback update(String.t(), update_fun()) :: {:ok, Record.t()} | {:error, term()}
  @callback delete(String.t()) :: :ok | {:error, term()}

  @doc "Look up a subscription through a store reference."
  @spec get(store_ref(), String.t()) :: {:ok, Record.t()} | :not_found | {:error, term()}
  def get({module, opts}, id), do: module.get(id, opts)
  def get(store, id), do: store.get(id)

  @doc "Persist a subscription through a store reference."
  @spec put(store_ref(), Record.t()) :: :ok | {:error, term()}
  def put({module, opts}, record), do: module.put(record, opts)
  def put(store, record), do: store.put(record)

  @doc "Atomically update a subscription through a store reference."
  @spec update(store_ref(), String.t(), update_fun()) :: {:ok, Record.t()} | {:error, term()}
  def update({module, opts}, id, fun), do: module.update(id, fun, opts)
  def update(store, id, fun), do: store.update(id, fun)

  @doc "Delete a subscription through a store reference."
  @spec delete(store_ref(), String.t()) :: :ok | {:error, term()}
  def delete({module, opts}, id), do: module.delete(id, opts)
  def delete(store, id), do: store.delete(id)
end
