defmodule MPP.Test.TelemetryCollector do
  @moduledoc false

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    events = Keyword.get(opts, :events, MPP.Telemetry.event_names())
    Agent.start_link(fn -> %{counts: init_counts(events), metadata: []} end, name: __MODULE__)
  end

  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    events = Keyword.get(opts, :events, MPP.Telemetry.event_names())

    for event <- events do
      :telemetry.attach({__MODULE__, event}, event, &__MODULE__.handle_event/4, nil)
    end

    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | counts: Map.update!(state.counts, event, &(&1 + 1)),
          metadata: [{event, measurements, metadata} | state.metadata]
      }
    end)

    :ok
  end

  @spec detach() :: :ok
  def detach do
    for event <- MPP.Telemetry.event_names() do
      :telemetry.detach({__MODULE__, event})
    end

    :ok
  end

  @spec counts() :: map()
  def counts do
    Agent.get(__MODULE__, & &1.counts)
  end

  @spec count([atom()]) :: non_neg_integer()
  def count(event) do
    Map.get(counts(), event, 0)
  end

  @spec metadata_for([atom()]) :: [{[atom()], map(), map()}]
  def metadata_for(event) do
    Agent.get(__MODULE__, fn state ->
      Enum.filter(state.metadata, fn {name, _measurements, _metadata} -> name == event end)
    end)
  end

  defp init_counts(events) do
    Map.new(events, fn event -> {event, 0} end)
  end
end
