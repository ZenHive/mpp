defmodule MPP.Application do
  @moduledoc false

  # Starts the default replay-dedup store so replay protection is on by default
  # (issue #7), and the default session-channel store. A method or plug
  # configured without an explicit `:store` uses this app-started ConCache
  # instance (`MPP.Tempo.Store.default_store/0`). Operators wanting a
  # shared/multi-node backend configure their own `:store`; `store: false` opts
  # a route out entirely. Session channels use `MPP.Session.ETSStore` by default.

  use Application

  alias MPP.Session.ETSStore
  alias MPP.Tempo.ConCacheStore

  @impl true
  def start(_type, _args) do
    children = [
      ConCacheStore.child_spec([]),
      ETSStore.child_spec([])
    ]

    opts = [strategy: :one_for_one, name: MPP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
