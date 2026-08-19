defmodule MPP.Subscription.ETSStore do
  @moduledoc """
  Single-node atomic ETS store for recurring subscriptions.

  Use a shared durable backend implementing `MPP.Subscription.Store` when
  subscriptions must survive node restarts or coordinate across nodes.
  """

  @behaviour MPP.Subscription.Store

  alias MPP.Subscription.Record
  alias MPP.Subscription.Store

  @default_name __MODULE__

  @doc "Start an ETS subscription store."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> :ets.new(__MODULE__, [:set, :private, read_concurrency: true]) end, name: server(opts))
  end

  @impl Store
  @doc "Look up a subscription in the default store."
  @spec get(String.t()) :: {:ok, Record.t()} | :not_found | {:error, term()}
  def get(id), do: get(id, [])

  @doc "Look up a subscription in a configured store instance."
  @spec get(String.t(), keyword()) :: {:ok, Record.t()} | :not_found | {:error, term()}
  def get(id, opts) when is_binary(id) do
    Agent.get(server(opts), fn table ->
      case :ets.lookup(table, id) do
        [{^id, record}] -> {:ok, record}
        [] -> :not_found
      end
    end)
  end

  @doc "Return a child specification for a subscription store."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @impl Store
  @doc "Insert or replace a subscription in the default store."
  @spec put(Record.t()) :: :ok | {:error, term()}
  def put(record), do: put(record, [])

  @doc "Insert or replace a subscription in a configured store instance."
  @spec put(Record.t(), keyword()) :: :ok | {:error, term()}
  def put(%Record{} = record, opts) do
    Agent.update(server(opts), fn table ->
      :ets.insert(table, {record.subscription_id, record})
      table
    end)
  end

  @impl Store
  @doc "Atomically update a subscription in the default store."
  @spec update(String.t(), Store.update_fun()) :: {:ok, Record.t()} | {:error, term()}
  def update(id, fun), do: update(id, fun, [])

  @doc "Atomically update a subscription in a configured store instance."
  @spec update(String.t(), Store.update_fun(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def update(id, fun, opts) when is_binary(id) and is_function(fun, 1) do
    Agent.get_and_update(server(opts), fn table ->
      current = lookup(table, id)

      case fun.(current) do
        {:ok, %Record{subscription_id: ^id} = record} ->
          :ets.insert(table, {id, record})
          {{:ok, record}, table}

        {:ok, %Record{}} ->
          {{:error, :subscription_id_mismatch}, table}

        {:error, _reason} = error ->
          {error, table}

        other ->
          {{:error, {:invalid_update_result, other}}, table}
      end
    end)
  end

  @impl Store
  @doc "Delete a subscription from the default store."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id), do: delete(id, [])

  @doc "Delete a subscription from a configured store instance."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts) when is_binary(id) do
    Agent.update(server(opts), fn table ->
      :ets.delete(table, id)
      table
    end)
  end

  defp lookup(table, id) do
    case :ets.lookup(table, id) do
      [{^id, record}] -> record
      [] -> :not_found
    end
  end

  defp server(opts), do: Keyword.get(opts, :name, @default_name)
end
