defmodule MPP.Test.SessionChainState do
  @moduledoc false

  alias MPP.Session.Channel

  @doc "A channel-state verifier whose escrow agrees with the stored channel."
  @spec mirror(Channel.t(), keyword()) :: {:ok, map()}
  def mirror(%Channel{} = channel, _opts) do
    {:ok, %{deposit: channel.deposit, settled: channel.settled, close_requested: false, finalized: false}}
  end
end
