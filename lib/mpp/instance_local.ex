defmodule MPP.InstanceLocal do
  @moduledoc false
  # Guards the fall-back to an application-started, in-node store.
  #
  # Those stores (MPP.Tempo.ConCacheStore, MPP.Session.ETSStore,
  # MPP.Subscription.ETSStore) keep their state in one node's memory. When the
  # server runs as several instances, a payment accepted by one instance is
  # unknown to the others. So the fall-back refuses to hand out the default
  # when the runtime looks multi-instance, and a route that wants in-node state
  # there has to name the store explicitly (mppx #1249, `fallbackStore`).
  #
  # The check runs where the default is selected, on the node serving the
  # request. `MPP.Plug.init/1` is no place for it: `plug` macros run init at
  # compile time, on the build machine.

  # The platform variables mppx reads in `src/internal/env.ts` (`sharedPlatforms`),
  # limited to hosts that run BEAM releases.
  @platform_variables ~w(AWS_LAMBDA_FUNCTION_NAME DYNO FLY_APP_NAME K_SERVICE RAILWAY_ENVIRONMENT RENDER)

  @doc """
  Describes why the runtime looks multi-instance, or returns `nil`.

  Signals: the node is connected to other visible nodes (hidden nodes such as an
  attached remote shell do not count), or a multi-instance platform variable is
  set to a non-empty value.
  """
  @spec shared_runtime() :: String.t() | nil
  def shared_runtime, do: shared_runtime(Node.list(), &System.get_env/1)

  @doc false
  @spec shared_runtime([node()], (String.t() -> String.t() | nil)) :: String.t() | nil
  def shared_runtime([], getenv) do
    Enum.find_value(@platform_variables, fn name ->
      if getenv.(name) not in [nil, ""], do: "#{name} is set"
    end)
  end

  def shared_runtime(nodes, _getenv) when is_list(nodes) do
    "this node is connected to #{length(nodes)} other node(s)"
  end

  @doc """
  Returns `default` on a single-instance runtime and raises otherwise.

  Options name the route for the error message: `:method` (payment method
  name), `:option` (the configuration key that selects the store) and
  `:behaviour` (the store behaviour a shared backend implements).
  """
  @spec default!(module(), keyword()) :: module()
  def default!(default, opts) when is_atom(default) and is_list(opts) do
    case shared_runtime() do
      nil -> default
      signal -> raise ArgumentError, message(default, signal, opts)
    end
  end

  defp message(default, signal, opts) do
    option = Keyword.fetch!(opts, :option)
    behaviour = Keyword.fetch!(opts, :behaviour)

    "MPP: the #{Keyword.fetch!(opts, :method)} route has no #{option} configured and #{signal}, " <>
      "so this server may run as several instances. The default #{inspect(default)} keeps its state " <>
      "in this node's memory, so a payment accepted by one instance could be accepted again by another. " <>
      "Configure a shared #{inspect(behaviour)} backend (Redis, Postgres, ...) as #{option}, " <>
      "or pass #{inspect(default)} explicitly as #{option} to accept state scoped to this instance."
  end
end
