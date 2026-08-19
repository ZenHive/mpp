defmodule MPP.Client.SelectionPolicy do
  @moduledoc """
  Transport-neutral challenge selection and ordering.

  HTTP (`MPP.Client.Req`) and MCP client orchestration share this policy so
  challenge ranking is not owned by any one wire transport. The default
  preserves server-advertised order — first `MultiProvider`-supported challenge
  wins — matching mppx client orchestration and the mpp-rs provider default
  (`select_challenge` keeps caller order).

  ## Policies

    * `:server_order` — keep the server's offer order (default)
    * `{:accept_payment, entries}` — reorder by `Accept-Payment` preferences
    * an arity-1 function — receives the supported challenges and returns them
      filtered/reordered; the first remaining challenge is selected
  """

  use Descripex, namespace: "/client"

  alias MPP.AcceptPayment
  alias MPP.Challenge
  alias MPP.Client.MultiProvider

  @type t ::
          :server_order
          | {:accept_payment, [AcceptPayment.entry()]}
          | ([Challenge.t()] -> [Challenge.t()])

  api(:default, "Return the default policy (`:server_order`).", returns: %{type: :atom, description: "`:server_order`"})

  @doc "Return the default policy (`:server_order`)."
  @spec default() :: :server_order
  def default, do: :server_order

  api(:select, "Pick a challenge using a selection policy and MultiProvider support.",
    params: [
      challenges: [kind: :value, description: "Challenges in server offer order"],
      multi: [kind: :value, description: "MPP.Client.MultiProvider struct"],
      policy: [kind: :value, description: "Selection policy (defaults to `:server_order`)"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, challenge}` or `{:error, :no_supported_challenge}`"
    },
    errors: [:no_supported_challenge]
  )

  @doc """
  Pick one supported challenge according to `policy`.

  Unsupported challenges are dropped first. The policy then orders what remains
  and the first entry is selected. Returns `{:error, :no_supported_challenge}`
  when nothing is left, including the empty-list case.
  """
  @spec select([Challenge.t()], MultiProvider.t(), t()) ::
          {:ok, Challenge.t()} | {:error, :no_supported_challenge}
  def select(challenges, %MultiProvider{} = multi, policy \\ default()) when is_list(challenges) do
    challenges
    |> Enum.filter(&supported?(&1, multi))
    |> order(policy)
    |> case do
      [%Challenge{} = challenge | _rest] -> {:ok, challenge}
      _empty -> {:error, :no_supported_challenge}
    end
  end

  defp supported?(%Challenge{method: method, intent: intent}, multi) do
    MultiProvider.supports?(multi, method, intent)
  end

  defp order(challenges, :server_order), do: challenges

  defp order(challenges, {:accept_payment, []}), do: challenges

  defp order(challenges, {:accept_payment, preferences}) when is_list(preferences) do
    AcceptPayment.rank(challenges, preferences)
  end

  defp order(challenges, fun) when is_function(fun, 1) do
    case fun.(challenges) do
      ordered when is_list(ordered) -> ordered
      _other -> []
    end
  end
end
