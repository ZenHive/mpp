defmodule MPP.Session.ActionsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.Session.Actions
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Store

  @channel_id "0x5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"
  @payer "0x1111111111111111111111111111111111111111"
  @recipient "0x2222222222222222222222222222222222222222"
  @token "0x3333333333333333333333333333333333333333"
  @signer "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @signature "0x" <> String.duplicate("ab", 65)
  @transaction "0x76abcd"
  @tx_hash "0x" <> String.duplicate("cd", 32)

  setup do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!(ETSStore.child_spec(name: name))
    {:ok, store: {ETSStore, [name: name]}}
  end

  # `finalized` in the mpp-rs channel model is `status: :closed` here. A topUp
  # may raise `spent` to the escrow's settled total; that catch-up is not a
  # request deduction and is not required to fit in the previous authorization.
  property "random action sequences keep session channel invariants", %{store: store} do
    check all(steps <- StreamData.list_of(step(), min_length: 1, max_length: 24), max_runs: 100) do
      :ok = Store.delete(store, @channel_id)

      Enum.reduce(steps, nil, fn step, before ->
        result = apply_step(store, step)
        now = snapshot(store)

        cond do
          match?(%Channel{status: :closed}, before) ->
            assert {:error, _} = result
            assert now == before
            before

          match?({:error, _}, result) ->
            assert now == before
            before

          true ->
            assert {:ok, _} = result
            assert_step(step, before, now)
            assert_monotonic(before, now)
            now
        end
      end)
    end
  end

  defp step do
    amount = StreamData.integer(0..300)

    StreamData.one_of([
      StreamData.tuple({StreamData.constant(:open), amount, amount, amount, StreamData.integer(0..300)}),
      StreamData.tuple({StreamData.constant(:voucher), amount, StreamData.integer(0..40), StreamData.integer(0..300)}),
      StreamData.tuple({StreamData.constant(:top_up), amount, amount, amount}),
      StreamData.tuple({StreamData.constant(:close), amount}),
      StreamData.tuple({StreamData.constant(:spend), amount})
    ])
  end

  defp apply_step(store, {:open, deposit, settled, cumulative, request}) do
    opts =
      store
      |> base_opts(request)
      |> Keyword.put(:verify_open, fn _payload, _opts -> escrow(deposit, settled) end)

    Actions.dispatch(open_payload(cumulative), opts)
  end

  defp apply_step(store, {:voucher, amount, min_delta, request}) do
    opts =
      store
      |> base_opts(request)
      |> Keyword.put(:min_voucher_delta, min_delta)

    Actions.dispatch(voucher_payload(amount), opts)
  end

  defp apply_step(store, {:top_up, deposit, settled, additional}) do
    opts =
      store
      |> base_opts(0)
      |> Keyword.put(:verify_top_up, fn _payload, _channel, _opts -> escrow(deposit, settled) end)

    Actions.dispatch(top_up_payload(additional), opts)
  end

  defp apply_step(store, {:close, amount}) do
    Actions.dispatch(close_payload(amount), base_opts(store, 0))
  end

  defp apply_step(store, {:spend, amount}) do
    Store.update(store, @channel_id, fn
      :not_found -> {:error, :channel_not_found}
      %Channel{} = channel -> Channel.apply_spend(channel, amount)
    end)
  end

  defp assert_step({:open, deposit, settled, cumulative, request}, nil, channel) do
    assert channel.deposit == deposit
    assert channel.settled == settled
    assert channel.cumulative_amount == cumulative
    assert channel.spent == settled + request
    assert channel.status == :active
    refute channel.closing
    assert request <= cumulative - settled

    if request > 0 do
      assert channel.status != :closed
      assert request <= channel.cumulative_amount - settled
    end
  end

  defp assert_step({:voucher, amount, min_delta, request}, %Channel{} = before, channel) do
    assert before.status in [:open, :active]
    refute before.closing
    delta = channel.cumulative_amount - before.cumulative_amount
    assert channel.cumulative_amount == amount
    assert delta > 0
    assert delta >= min_delta
    assert channel.spent == before.spent + request
    assert request <= amount - before.spent
    assert channel.deposit == before.deposit
    assert channel.settled == before.settled

    if request > 0, do: assert(channel.status != :closed)
  end

  defp assert_step({:top_up, deposit, settled, _additional}, %Channel{} = before, channel) do
    assert before.status in [:open, :active]
    refute before.closing
    assert channel.deposit == deposit
    assert channel.deposit > before.deposit
    assert channel.settled == max(before.settled, settled)
    assert channel.spent == max(before.spent, channel.settled)
    assert channel.cumulative_amount == max(before.cumulative_amount, channel.settled)
    assert channel.units == before.units
  end

  defp assert_step({:close, amount}, %Channel{} = before, channel) do
    assert before.status == :active
    refute before.closing
    assert amount >= before.spent
    assert channel.status == :closed
    refute channel.closing
    assert channel.spent == before.spent
    assert channel.deposit == before.deposit
    assert channel.settled == before.settled
    assert channel.cumulative_amount == max(before.cumulative_amount, amount)
    assert channel.cumulative_amount >= channel.spent
  end

  defp assert_step({:spend, 0}, %Channel{} = before, channel) do
    assert channel == before
  end

  defp assert_step({:spend, amount}, %Channel{} = before, channel) when amount > 0 do
    assert before.status in [:open, :active]
    refute before.closing
    assert amount <= before.cumulative_amount - before.spent
    assert channel.spent == before.spent + amount
    assert channel.units == before.units + 1
    assert channel.deposit == before.deposit
    assert channel.settled == before.settled
    assert channel.cumulative_amount == before.cumulative_amount
    assert channel.status == before.status
    refute channel.closing
  end

  defp assert_step(step, before, channel) do
    flunk(
      "unexpected success #{inspect(step)} before=#{inspect(before && before.status)} now=#{inspect(channel && channel.status)}"
    )
  end

  defp assert_monotonic(nil, channel), do: assert_bounds(channel)

  defp assert_monotonic(%Channel{} = before, channel) do
    assert channel.spent >= before.spent
    assert channel.settled >= before.settled
    assert channel.deposit >= before.deposit
    assert before.status != :closed or channel.status == :closed
    assert_bounds(channel)
  end

  defp assert_bounds(channel) do
    assert channel.spent >= channel.settled
    assert channel.spent <= channel.cumulative_amount
    assert channel.cumulative_amount <= channel.deposit
    assert channel.deposit >= 0
  end

  defp snapshot(store) do
    case Store.get(store, @channel_id) do
      {:ok, %Channel{} = channel} -> channel
      :not_found -> nil
    end
  end

  defp escrow(deposit, settled) do
    {:ok, %{deposit: deposit, settled: settled, close_requested: false, finalized: false}}
  end

  defp base_opts(store, request) do
    [
      store: store,
      payer: @payer,
      recipient: @recipient,
      token: @token,
      authorized_signer: @signer,
      escrow_contract: "0x4d50500000000000000000000000000000000000",
      chain_id: 42_431,
      request_amount: request,
      verify_signature: :already_verified,
      method_name: "session",
      challenge_id: "property-challenge",
      settle_close: fn _payload, _channel, _opts -> {:ok, %{tx_hash: @tx_hash}} end
    ]
  end

  defp open_payload(amount) do
    %{
      "action" => "open",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => @transaction,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => @signature
    }
  end

  defp voucher_payload(amount) do
    %{
      "action" => "voucher",
      "channelId" => @channel_id,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => @signature
    }
  end

  defp top_up_payload(amount) do
    %{
      "action" => "topUp",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => @transaction,
      "additionalDeposit" => Integer.to_string(amount)
    }
  end

  defp close_payload(amount) do
    %{
      "action" => "close",
      "channelId" => @channel_id,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => @signature
    }
  end
end
