defmodule MPP.Client.Budget do
  @moduledoc """
  A spending cap shared by concurrent payments (mppx `client/Budget.ts`).

  A budget is a process. Start it under a supervisor and pass it as `:budget`
  to `MPP.Client.Req.attach/2` or `MPP.Client.MCP.new/1`:

      children = [{MPP.Client.Budget, total: {"5", "USD"}, name: MyApp.AgentBudget}]

      MPP.Client.Req.attach(req,
        provider: provider,
        budget: MyApp.AgentBudget,
        tokens: [%{network: "eip155:4217", asset: "0x20c0…", currency: "USD", decimals: 6}]
      )

  Each payment reserves its amount before a provider creates the credential.
  The reservation is committed once the credential exists, whether or not the
  server then accepts it, and released when no credential was created. One
  process handles every reservation, so concurrent payments cannot overspend.
  A reservation whose owner process ends before settling it is committed.

  The total is money, `{"5", "USD"}`, or an amount of one asset,
  `%{network: "eip155:4217", asset: "0x20c0…", amount: 5_000_000}`. A money
  budget counts payments in assets the client lists under `:tokens` with that
  currency; an asset budget counts payments in that asset. Any other payment
  is refused.

  A budget lives as long as its process: it is not persisted.
  """

  use Descripex, namespace: "/client"

  alias MPP.Client.Budget.Server
  alias MPP.Client.Spend

  @type amount :: Spend.money() | Spend.asset_limit()
  @type reservation :: reference()

  api(:start_link, "Start a budget process with a money or single-asset total.",
    params: [opts: [kind: :value, description: "Keyword list. Required: `:total`. Optional: `:name`."]],
    returns: %{type: :tagged_tuple, description: "`{:ok, pid}` or a GenServer start error"}
  )

  @doc """
  Start a budget.

  ## Options

    * `:total` — required. `{"5", "USD"}` or
      `%{network: network, asset: asset, amount: atomic_units}`
    * `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    state = Server.state!(Keyword.fetch!(opts, :total))
    GenServer.start_link(Server, state, Keyword.take(opts, [:name]))
  end

  api(:child_spec, "Supervisor child spec for a budget; the id is the `:name` option, or the module.",
    params: [opts: [kind: :value, description: "Options for start_link/1"]],
    returns: %{type: :map, description: "Supervisor child specification"}
  )

  @doc "Child spec for a supervisor. The id is `:name` when given, so several budgets fit under one supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  api(:reserve, "Reserve a payment's amount, or refuse it when it does not fit or cannot be counted.",
    params: [
      budget: [kind: :value, description: "Budget pid or name"],
      requirement: [kind: :value, description: "Requirement map from MPP.Client.Spend.check/2"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, reservation}`, `{:error, :amount}` or `{:error, :asset}`"},
    errors: [:amount, :asset],
    composes_with: [:commit, :release]
  )

  @doc """
  Reserve `requirement`'s amount for the calling process. `requirement` is
  what `MPP.Client.Spend.check/2` read from a challenge; `MPP.Client.Spend.pay/4`
  makes this call. `{:error, :amount}`
  when it does not fit what remains, `{:error, :asset}` when the budget cannot
  count its asset.
  """
  @spec reserve(GenServer.server(), Spend.requirement()) :: {:ok, reservation()} | {:error, :amount | :asset}
  def reserve(budget, %{network: _, asset: _, amount: amount} = requirement) when is_integer(amount) and amount >= 0 do
    # No time limit: a caller that gave up would leave a reservation nobody holds.
    GenServer.call(
      budget,
      {:reserve, Map.take(requirement, [:network, :asset, :amount, :currency, :decimals])},
      :infinity
    )
  end

  api(:commit, "Count a reservation as spent.",
    params: [
      budget: [kind: :value, description: "Budget pid or name"],
      reservation: [kind: :value, description: "Reservation from reserve/2"]
    ],
    returns: %{type: :atom, description: "`:ok`; settling a reservation twice changes nothing"}
  )

  @doc "Count `reservation` as spent. A reservation settles once."
  @spec commit(GenServer.server(), reservation()) :: :ok
  def commit(budget, reservation) when is_reference(reservation),
    do: GenServer.call(budget, {:settle, reservation, :commit}, :infinity)

  api(:release, "Free a reservation for which no credential was created.",
    params: [
      budget: [kind: :value, description: "Budget pid or name"],
      reservation: [kind: :value, description: "Reservation from reserve/2"]
    ],
    returns: %{type: :atom, description: "`:ok`; settling a reservation twice changes nothing"}
  )

  @doc "Free `reservation`. A reservation settles once."
  @spec release(GenServer.server(), reservation()) :: :ok
  def release(budget, reservation) when is_reference(reservation),
    do: GenServer.call(budget, {:settle, reservation, :release}, :infinity)

  api(:total, "The configured total.",
    params: [budget: [kind: :value, description: "Budget pid or name"]],
    returns: %{type: :term, description: "Money tuple or asset amount map"}
  )

  @doc "The configured total."
  @spec total(GenServer.server()) :: amount()
  def total(budget), do: GenServer.call(budget, {:read, :limit})

  api(:remaining, "Total minus spent and reserved amounts.",
    params: [budget: [kind: :value, description: "Budget pid or name"]],
    returns: %{type: :term, description: "Money tuple or asset amount map"}
  )

  @doc "Total minus spent and reserved amounts."
  @spec remaining(GenServer.server()) :: amount()
  def remaining(budget), do: GenServer.call(budget, {:read, :remaining})

  api(:spent, "Amounts of payments whose credential was created.",
    params: [budget: [kind: :value, description: "Budget pid or name"]],
    returns: %{type: :term, description: "Money tuple or asset amount map"}
  )

  @doc "Amounts of payments whose credential was created."
  @spec spent(GenServer.server()) :: amount()
  def spent(budget), do: GenServer.call(budget, {:read, :spent})

  api(:reserved, "Amounts held by payments in flight.",
    params: [budget: [kind: :value, description: "Budget pid or name"]],
    returns: %{type: :term, description: "Money tuple or asset amount map"}
  )

  @doc "Amounts held by payments in flight."
  @spec reserved(GenServer.server()) :: amount()
  def reserved(budget), do: GenServer.call(budget, {:read, :reserved})
end
