defmodule MPP.Client.Budget.Server do
  @moduledoc false
  # The process behind MPP.Client.Budget: one mailbox orders every reservation.

  use GenServer

  alias MPP.Client.Spend.Units

  # Money amounts are integers at `scale` decimal places, raised to fit each payment.
  @doc "Validate a total into the initial process state."
  @spec state!(term()) :: map()
  def state!(%{} = total) do
    %{network: network, asset: asset, amount: amount} = Units.asset_limit!(total, ":total")
    base_state(%{kind: {:asset, network, asset}, scale: 0, limit: amount})
  end

  def state!(total) do
    {value, currency} = Units.money!(total, ":total")

    scale =
      case String.split(value, ".", parts: 2) do
        [_integer, fraction] -> byte_size(fraction)
        [_integer] -> 0
      end

    base_state(%{kind: {:money, currency}, scale: scale, limit: Units.parse_units(value, scale)})
  end

  defp base_state(fields), do: Map.merge(%{spent: 0, reserved: 0, open: %{}}, fields)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:reserve, requirement}, {owner, _tag}, state) do
    with {:ok, decimals} <- countable(state.kind, requirement),
         state = rescale(state, decimals),
         cost = requirement.amount * Integer.pow(10, state.scale - decimals),
         true <- cost <= state.limit - state.spent - state.reserved do
      reservation = make_ref()
      open = Map.put(state.open, reservation, {cost, Process.monitor(owner)})
      {:reply, {:ok, reservation}, %{state | reserved: state.reserved + cost, open: open}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :amount}, state}
    end
  end

  def handle_call({:settle, reservation, how}, _from, state) do
    {:reply, :ok, settle(state, reservation, how)}
  end

  def handle_call({:read, what}, _from, state) do
    value =
      case what do
        :remaining -> state.limit - state.spent - state.reserved
        field -> Map.fetch!(state, field)
      end

    {:reply, format(state, value), state}
  end

  # The owner ended without settling: a credential may exist, so it counts.
  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      state.open
      |> Enum.filter(fn {_reservation, {_cost, owner}} -> owner == monitor end)
      |> Enum.reduce(state, fn {reservation, _entry}, acc -> settle(acc, reservation, :commit) end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp settle(state, reservation, how) do
    case Map.pop(state.open, reservation) do
      {nil, _open} ->
        state

      {{cost, monitor}, open} ->
        Process.demonitor(monitor, [:flush])
        spent = if how == :commit, do: state.spent + cost, else: state.spent
        %{state | open: open, reserved: state.reserved - cost, spent: spent}
    end
  end

  # Currency and decimals are set only from client configuration (`:tokens`).
  defp countable({:money, currency}, %{currency: currency, decimals: decimals}) when is_integer(decimals),
    do: {:ok, decimals}

  defp countable({:asset, network, asset}, requirement) do
    if Units.asset_key(network, asset) == Units.asset_key(requirement.network, requirement.asset),
      do: {:ok, 0},
      else: {:error, :asset}
  end

  defp countable(_kind, _requirement), do: {:error, :asset}

  defp rescale(%{scale: scale} = state, decimals) when decimals <= scale, do: state

  defp rescale(%{scale: scale} = state, decimals) do
    factor = Integer.pow(10, decimals - scale)
    open = Map.new(state.open, fn {reservation, {cost, monitor}} -> {reservation, {cost * factor, monitor}} end)

    %{
      state
      | scale: decimals,
        limit: state.limit * factor,
        spent: state.spent * factor,
        reserved: state.reserved * factor,
        open: open
    }
  end

  defp format(%{kind: {:asset, network, asset}}, value), do: %{network: network, asset: asset, amount: value}
  defp format(%{kind: {:money, currency}, scale: scale}, value), do: {format_units(value, scale), currency}

  # An integer at `decimals` places as a decimal string without trailing zeros.
  defp format_units(value, 0), do: Integer.to_string(value)

  defp format_units(value, decimals) do
    digits = value |> Integer.to_string() |> String.pad_leading(decimals + 1, "0")
    {integer, fraction} = String.split_at(digits, byte_size(digits) - decimals)

    case String.trim_trailing(fraction, "0") do
      "" -> integer
      fraction -> integer <> "." <> fraction
    end
  end
end
