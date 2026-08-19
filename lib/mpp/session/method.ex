defmodule MPP.Session.Method do
  @moduledoc """
  Convenience `use` wrapper that implements `MPP.Method.verify/2` by dispatching
  session credential actions through `MPP.Session.Actions`.

  Methods that `use MPP.Session.Method` still implement `method_name/0`.
  `verify/2` accepts a session intent and routes on `payload["action"]`.
  """

  @doc false
  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      use MPP.Method

      @doc "Session credentials use a `type=transaction` proof on open/topUp."
      @spec credential_types() :: [String.t()]
      @impl MPP.Method
      def credential_types, do: ["transaction"]

      @doc "Dispatch a session credential payload through `MPP.Session.Actions`."
      @spec verify(map(), MPP.Method.intent()) :: {:ok, MPP.Receipt.t()} | {:error, MPP.Errors.t()}
      @impl MPP.Method
      def verify(payload, %MPP.Intents.Session{} = session) when is_map(payload) do
        details = Map.put(session.method_details || %{}, "method", method_name())
        MPP.Session.Actions.verify(payload, %{session | method_details: details})
      end

      def verify(_payload, _intent) do
        {:error, MPP.Errors.new(:invalid_payload, "session method requires a session intent")}
      end

      defoverridable credential_types: 0, verify: 2
    end
  end
end
