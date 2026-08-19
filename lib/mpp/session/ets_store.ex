defmodule MPP.Session.ETSStore do
  @moduledoc """
  ETS-backed default implementation of `MPP.Session.Store`.

  A GenServer owns the ETS table and serializes read-modify-write callbacks,
  making `update/2` atomic within one BEAM node. Use a shared custom backend for
  channel state that must be consistent across multiple nodes.
  """

  @behaviour MPP.Session.Store

  use GenServer

  alias MPP.Session.Channel
  alias MPP.Session.Store

  @default_name __MODULE__

  @doc "Start an ETS session store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, @default_name))
  end

  @doc "Return a child specification for an ETS session store."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl Store
  @doc "Look up a channel in the default store."
  @spec get(String.t()) :: {:ok, Channel.t()} | :not_found | {:error, term()}
  def get(channel_id), do: get(channel_id, [])

  @doc "Look up a channel in a configured store instance."
  @spec get(String.t(), keyword()) :: {:ok, Channel.t()} | :not_found | {:error, term()}
  def get(channel_id, opts) do
    with {:ok, channel_id} <- Channel.normalize_id(channel_id) do
      GenServer.call(server(opts), {:get, channel_id})
    end
  end

  @impl Store
  @doc "Insert or replace channel state in the default store."
  @spec put(Channel.t()) :: :ok | {:error, term()}
  def put(channel), do: put(channel, [])

  @doc "Insert or replace channel state in a configured store instance."
  @spec put(Channel.t(), keyword()) :: :ok | {:error, term()}
  def put(%Channel{} = channel, opts) do
    with {:ok, channel_id} <- Channel.normalize_id(channel.channel_id) do
      GenServer.call(server(opts), {:put, %{channel | channel_id: channel_id}})
    end
  end

  @impl Store
  @doc "Atomically update channel state in the default store."
  @spec update(String.t(), Store.update_fun()) ::
          {:ok, Channel.t()} | {:error, term()}
  def update(channel_id, fun), do: update(channel_id, fun, [])

  @doc "Atomically update channel state in a configured store instance."
  @spec update(String.t(), Store.update_fun(), keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def update(channel_id, fun, opts) when is_function(fun, 1) do
    with {:ok, channel_id} <- Channel.normalize_id(channel_id) do
      GenServer.call(server(opts), {:update, channel_id, fun})
    end
  end

  @impl Store
  @doc "Delete channel state from the default store."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(channel_id), do: delete(channel_id, [])

  @doc "Delete channel state from a configured store instance."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(channel_id, opts) do
    with {:ok, channel_id} <- Channel.normalize_id(channel_id) do
      GenServer.call(server(opts), {:delete, channel_id})
    end
  end

  @impl GenServer
  def init(:ok) do
    {:ok, :ets.new(__MODULE__, [:set, :private, read_concurrency: true])}
  end

  @impl GenServer
  def handle_call({:get, channel_id}, _from, table) do
    reply =
      case :ets.lookup(table, channel_id) do
        [{^channel_id, channel}] -> {:ok, channel}
        [] -> :not_found
      end

    {:reply, reply, table}
  end

  def handle_call({:put, %Channel{} = channel}, _from, table) do
    :ets.insert(table, {channel.channel_id, channel})
    {:reply, :ok, table}
  end

  def handle_call({:update, channel_id, fun}, _from, table) do
    current =
      case :ets.lookup(table, channel_id) do
        [{^channel_id, channel}] -> channel
        [] -> :not_found
      end

    case fun.(current) do
      {:ok, %Channel{} = channel} ->
        case Channel.normalize_id(channel.channel_id) do
          {:ok, ^channel_id} ->
            channel = %{channel | channel_id: channel_id}
            :ets.insert(table, {channel_id, channel})
            {:reply, {:ok, channel}, table}

          _error ->
            {:reply, {:error, :channel_id_mismatch}, table}
        end

      {:error, _reason} = error ->
        {:reply, error, table}

      other ->
        {:reply, {:error, {:invalid_update_result, other}}, table}
    end
  end

  def handle_call({:delete, channel_id}, _from, table) do
    :ets.delete(table, channel_id)
    {:reply, :ok, table}
  end

  defp server(opts), do: Keyword.get(opts, :name, @default_name)
end
