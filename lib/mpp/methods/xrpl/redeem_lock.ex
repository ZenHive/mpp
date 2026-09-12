defmodule MPP.Methods.XRPL.RedeemLock do
  @moduledoc """
  Single-node exclusive lease for XRPL `PaymentChannelClaim` submits.

  `Sequence` is an account-wide nonce: a transaction is only valid when it
  equals the sending account's current Sequence
  ([Transaction Common Fields](https://xrpl.org/docs/references/protocol/transactions/common-fields)).
  Two claims from the same Destination that pick the same Sequence collide;
  the loser fails `tefPAST_SEQ`
  ([tef codes](https://xrpl.org/docs/references/protocol/transactions/transaction-results/tef-codes)).

  `with_account/3` takes an ETS lease keyed by Destination address so
  concurrent `redeem/2` calls on one BEAM node cannot share a Sequence.
  `MPP.Methods.XRPL.Session` also leases `"channel:" <> channel_id` in the same
  table so one channel is redeemed once at a time. Acquisition is bounded by a
  timeout; the lease is not visible to other nodes.
  """

  use GenServer

  alias MPP.Errors

  @table __MODULE__
  @default_timeout_ms 30_000

  @doc "Start the ETS table owner for Destination-account leases."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` while holding the exclusive lease for `address`.

  Not re-entrant. Acquisition is bounded by `timeout_ms` (default 30,000).
  Waiters monitor a lease process that exits on release or caller death.
  """
  @spec with_account(String.t(), (-> result), non_neg_integer()) :: result | {:error, Errors.t()} when result: var
  def with_account(address, fun, timeout_ms \\ @default_timeout_ms)
      when is_binary(address) and is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms >= 0 do
    caller = self()
    {lease, ref} = spawn_monitor(fn -> lease_lifetime(caller) end)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      with :ok <- acquire(address, lease, deadline), do: fun.()
    after
      :ets.delete_object(@table, {address, lease})
      send(lease, :release)

      receive do
        {:DOWN, ^ref, :process, ^lease, _} -> :ok
      end
    end
  end

  @impl GenServer
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  defp lease_lifetime(caller) do
    ref = Process.monitor(caller)

    receive do
      :release -> :ok
      {:DOWN, ^ref, :process, ^caller, _} -> :ok
    end
  end

  defp acquire(address, lease, deadline) do
    if :ets.insert_new(@table, {address, lease}) do
      :ok
    else
      wait_for_owner(address, lease, deadline)
    end
  end

  defp wait_for_owner(address, lease, deadline) do
    case :ets.lookup(@table, address) do
      [{^address, owner}] ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, _} ->
            :ets.delete_object(@table, {address, owner})
            retry_acquire(address, lease, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            Process.demonitor(ref, [:flush])
            timeout()
        end

      [] ->
        retry_acquire(address, lease, deadline)
    end
  end

  defp retry_acquire(address, lease, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      acquire(address, lease, deadline)
    else
      timeout()
    end
  end

  defp timeout, do: {:error, Errors.new(:settlement_failed, "XRPL redemption lease acquisition timed out")}
end
