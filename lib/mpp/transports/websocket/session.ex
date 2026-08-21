defmodule MPP.Transports.WebSocket.Session do
  @moduledoc false
  # Metered WebSocket session loop matching mpp-rs `server::ws_session`
  # (`refs/mpp-rs/src/server/ws_session.rs`): deduct per tick, emit needVoucher
  # when the channel is exhausted, wait for a voucher credential, resume, then
  # emit a session receipt when the generator is drained.

  alias MPP.Intents.Session, as: SessionIntent
  alias MPP.Plug.Config
  alias MPP.Session.Channel
  alias MPP.Session.Store
  alias MPP.Transports.WebSocket
  alias MPP.Transports.WebSocket.Frame

  defmodule Meter do
    @moduledoc false

    @type t :: %__MODULE__{
            channel_id: String.t() | nil,
            tick_cost: pos_integer(),
            remaining: [term()],
            store: Store.store_ref()
          }

    defstruct [:channel_id, :tick_cost, :remaining, :store]
  end

  @type ws :: WebSocket.t()

  @doc "Pull `:generate` / `:tick_cost` off Plug opts and build a meter when present."
  @spec parse_opts(keyword(), Config.t()) :: {Meter.t() | nil, keyword()}
  def parse_opts(opts, %Config{} = config) when is_list(opts) do
    {generate, opts} = Keyword.pop(opts, :generate)
    {tick_cost, opts} = Keyword.pop(opts, :tick_cost)

    case generate do
      nil ->
        {nil, opts}

      remaining when is_list(remaining) ->
        if config.intent != "session" do
          raise ArgumentError, ~s(MPP.Transports.WebSocket :generate requires intent: "session")
        end

        meter = %Meter{
          remaining: remaining,
          tick_cost: tick_cost(tick_cost, config),
          store: config.session_store
        }

        {meter, opts}

      _other ->
        raise ArgumentError, "MPP.Transports.WebSocket :generate must be a list"
    end
  end

  @doc "Bind a channel and drain until needVoucher, a session receipt, or an error."
  @spec start(ws(), keyword()) :: {ws(), [map()]}
  def start(%WebSocket{status: :authorized} = session, opts) when is_list(opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    remaining = Keyword.get(opts, :generate, [])
    tick_cost = Keyword.get(opts, :tick_cost, default_tick_cost(session.config))

    session = %{
      session
      | meter: %Meter{
          channel_id: channel_id,
          tick_cost: tick_cost(tick_cost, session.config),
          remaining: remaining,
          store: session.config.session_store
        }
    }

    drain(session)
  end

  def start(%WebSocket{}, _opts) do
    raise ArgumentError, "start_metering/2 requires an authorized WebSocket session"
  end

  @doc "Copy `channelId` from a verified session credential onto an unbound meter."
  @spec bind_channel(ws(), map()) :: ws()
  def bind_channel(%WebSocket{meter: %Meter{channel_id: nil} = meter} = session, payload) when is_map(payload) do
    case Map.get(payload, "channelId") do
      channel_id when is_binary(channel_id) ->
        %{session | meter: %{meter | channel_id: channel_id}}

      _other ->
        session
    end
  end

  def bind_channel(session, _payload), do: session

  @doc "Deduct and emit remaining generator items until blocked or complete."
  @spec drain(ws()) :: {ws(), [map()]}
  def drain(%WebSocket{} = session), do: drain_acc(session, [])

  defp drain_acc(%WebSocket{meter: nil} = session, acc), do: {session, acc}
  defp drain_acc(%WebSocket{status: :awaiting_voucher} = session, acc), do: {session, acc}
  defp drain_acc(%WebSocket{status: :complete} = session, acc), do: {session, acc}

  defp drain_acc(%WebSocket{meter: %Meter{channel_id: nil}} = session, acc) do
    {session, acc ++ [Frame.error_frame("session channel is not bound")]}
  end

  defp drain_acc(%WebSocket{meter: %Meter{remaining: []}} = session, acc) do
    {session, frames} = finish(session)
    {session, acc ++ frames}
  end

  defp drain_acc(%WebSocket{} = session, acc) do
    case deduct(session) do
      {:ok, session} ->
        {session, data} = emit_next(session)
        drain_acc(session, acc ++ data)

      {:need_voucher, session, frame} ->
        {%{session | status: :awaiting_voucher}, acc ++ [frame]}

      {:error, session, frame} ->
        {session, acc ++ [frame]}
    end
  end

  @doc "Emit the final session receipt and mark the socket complete."
  @spec finish(ws()) :: {ws(), [map()]}
  def finish(%WebSocket{meter: %Meter{} = meter, challenge: challenge} = session) do
    session = %{session | status: :complete, meter: %{meter | remaining: []}}

    case Store.get(meter.store, meter.channel_id) do
      {:ok, channel} ->
        {session, [session_receipt_frame(session, channel, challenge && challenge.id)]}

      :not_found ->
        {session, [Frame.error_frame("session channel not found")]}

      {:error, reason} ->
        {session, [Frame.error_frame("session store error: #{inspect(reason)}")]}
    end
  end

  defp deduct(%WebSocket{meter: %Meter{} = meter} = session) do
    result =
      Store.update(meter.store, meter.channel_id, fn
        :not_found ->
          {:error, :channel_not_found}

        %Channel{} = channel ->
          Channel.apply_spend(channel, meter.tick_cost)
      end)

    case result do
      {:ok, _channel} ->
        {:ok, session}

      {:error, :insufficient_balance} ->
        {:need_voucher, session, need_voucher_frame(meter)}

      {:error, {:invalid_transition, :closed, _to}} ->
        {:error, %{session | status: :complete}, Frame.error_frame("session channel is closed")}

      {:error, :channel_not_found} ->
        {:error, session, Frame.error_frame("session channel not found")}

      {:error, reason} ->
        {:error, session, Frame.error_frame("session deduct failed: #{inspect(reason)}")}
    end
  end

  defp emit_next(%WebSocket{meter: %Meter{remaining: [item | rest]} = meter} = session) do
    {%{session | meter: %{meter | remaining: rest}}, [Frame.message_frame(item)]}
  end

  defp need_voucher_frame(%Meter{} = meter) do
    case Store.get(meter.store, meter.channel_id) do
      {:ok, channel} ->
        Frame.need_voucher_frame(
          channel_id: channel.channel_id,
          required_cumulative: Integer.to_string(channel.spent + meter.tick_cost),
          accepted_cumulative: Integer.to_string(channel.cumulative_amount),
          deposit: Integer.to_string(channel.deposit)
        )

      _other ->
        Frame.error_frame("session channel not found")
    end
  end

  defp session_receipt_frame(%WebSocket{config: %Config{} = config}, %Channel{} = channel, challenge_id) do
    method = config.method_entries |> hd() |> then(& &1.method.method_name())

    receipt = %{
      "method" => method,
      "intent" => "session",
      "status" => "success",
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "reference" => channel.channel_id,
      "challengeId" => challenge_id,
      "channelId" => channel.channel_id,
      "acceptedCumulative" => Integer.to_string(channel.cumulative_amount),
      "spent" => Integer.to_string(channel.spent),
      "units" => channel.units
    }

    Frame.receipt_frame(receipt)
  end

  defp tick_cost(cost, _config) when is_integer(cost) and cost > 0, do: cost

  defp tick_cost(_cost, %Config{} = config) do
    case default_tick_cost(config) do
      cost when is_integer(cost) and cost > 0 ->
        cost

      _other ->
        raise ArgumentError, "MPP.Transports.WebSocket metering requires a positive :tick_cost"
    end
  end

  defp default_tick_cost(%Config{method_entries: [entry | _]}) do
    case entry.charge do
      %SessionIntent{amount: amount} -> parse_tick_cost(amount)
      _other -> nil
    end
  end

  defp parse_tick_cost(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {cost, ""} when cost > 0 -> cost
      _other -> nil
    end
  end

  defp parse_tick_cost(_amount), do: nil
end
