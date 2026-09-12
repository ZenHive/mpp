defmodule MPP.Methods.XRPL.RedeemLock do
  @moduledoc """
  Single-node exclusive lease for XRPL `PaymentChannelClaim` submits.

  `Sequence` is an account-wide nonce: a transaction is only valid when it
  equals the sending account's current Sequence
  ([Transaction Common Fields](https://xrpl.org/docs/references/protocol/transactions/common-fields)).
  Two claims from the same Destination that pick the same Sequence collide;
  the loser fails `tefPAST_SEQ`
  ([tef codes](https://xrpl.org/docs/references/protocol/transactions/transaction-results/tef-codes)).

  `with_account/2` takes an ETS lease keyed by Destination address so
  concurrent `redeem/2` calls on one BEAM node cannot share a Sequence. The
  lease is not visible to other nodes.
  """

  use GenServer

  @table __MODULE__
  @wait_ms 5

  @doc "Start the ETS table owner for Destination-account leases."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` while holding the exclusive lease for `address`.

  Not re-entrant. A crashed holder is unblocked by the next waiter.
  """
  @spec with_account(String.t(), (-> result)) :: result when result: var
  def with_account(address, fun) when is_binary(address) and is_function(fun, 0) do
    acquire(address)

    try do
      fun.()
    after
      release(address)
    end
  end

  @impl GenServer
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  defp acquire(address) do
    if :ets.insert_new(@table, {address, self()}) do
      :ok
    else
      wait_and_retry(address)
    end
  end

  defp wait_and_retry(address) do
    case :ets.lookup(@table, address) do
      [{^address, owner}] ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, _} ->
            :ets.delete_object(@table, {address, owner})
            acquire(address)
        after
          @wait_ms ->
            Process.demonitor(ref, [:flush])
            acquire(address)
        end

      [] ->
        acquire(address)
    end
  end

  defp release(address) do
    :ets.delete_object(@table, {address, self()})
    :ok
  end
end
