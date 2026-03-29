defmodule MPP.Demo.Method do
  @moduledoc """
  Demo payment method — accepts a magic token for local testing.

  Used by `mix mpp.demo` to demonstrate the full 402 handshake without
  requiring real payment credentials. The only accepted token is `"demo-token"`.

  ## Credential Payload

  The credential `payload` map must contain:

    * `"token"` — (required) must be `"demo-token"`
    * `"externalId"` — (optional) caller-provided correlation ID, echoed in receipt
  """

  use MPP.Method

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Receipt

  @accepted_token "demo-token"

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "demo"

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"token" => @accepted_token} = payload, %Charge{} = _charge) do
    receipt =
      Receipt.new(
        method: method_name(),
        reference: "demo_#{System.unique_integer([:positive])}",
        external_id: payload["externalId"]
      )

    {:ok, receipt}
  end

  def verify(%{"token" => _invalid}, %Charge{}) do
    {:error, Errors.new(:verification_failed, "Invalid demo token — use \"demo-token\"")}
  end

  def verify(_payload, %Charge{}) do
    {:error, Errors.new(:invalid_payload, "Missing 'token' field in credential payload")}
  end

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{}) do
    %{"acceptedTokens" => [@accepted_token]}
  end
end
