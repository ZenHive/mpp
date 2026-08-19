defmodule MPP.Intent do
  @moduledoc """
  Shared contract implemented by payment-intent schemas.

  Intent modules validate construction and translate between their Elixir
  structs and the method-neutral request maps embedded in challenges.
  """

  @callback new(keyword()) :: {:ok, struct()} | {:error, atom()}
  @callback to_request(struct()) :: map()
  @callback from_request(term()) :: {:ok, struct()} | {:error, atom()}
end
