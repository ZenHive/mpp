defmodule MPP.Client.Transport do
  @moduledoc """
  Behaviour for client-side transports that bridge a protocol response/request pair
  and the MPP payment flow.

  A `Transport` implementation knows how to:

    1. Detect whether a response signals "payment required" (HTTP 402, JSON-RPC
       error code `-32042`, etc.)
    2. Extract the challenges carried on that response
    3. Attach a decoded credential to a new request for retry

  This is the transport-shaped glue that sits between the provider-side
  `MPP.Client.PaymentProvider` abstraction and whatever concrete client (Req,
  an MCP JSON-RPC client, etc.) is actually issuing requests.

  ## Callbacks

    * `c:payment_required?/1` — plain boolean check on a response
    * `c:get_challenges/1` — parse the response into a challenge list
    * `c:set_credential/2` — return a new request with the credential attached
      in a transport-specific way

  ## Selection

  `select_challenge/2` is a small helper (not a callback) that picks the first
  challenge whose `method`/`intent` is supported by a `MPP.Client.MultiProvider`.
  This matches the baseline "first supported in server offer order" behaviour
  shared with the reference SDKs; ranking via `Accept-Payment` is layered on top
  later and is out of scope for the transport itself.
  """

  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Credential

  @doc """
  Return `true` if the response signals that a payment is required.

  For HTTP, this is `status == 402`. For MCP/JSON-RPC, this is
  `error.code == -32042`.
  """
  @callback payment_required?(response :: term()) :: boolean()

  @doc """
  Extract the `MPP.Challenge` list carried on a payment-required response.

  Returning `{:ok, []}` is not a valid outcome — an empty or unparseable
  challenge set should surface as `{:error, reason}` so callers can distinguish
  "402 with no Payment challenges" from "402 with N challenges".
  """
  @callback get_challenges(response :: term()) ::
              {:ok, [Challenge.t()]} | {:error, term()}

  @doc """
  Return a new request with the given credential attached in transport-specific
  form.

  For HTTP, this sets `Authorization: Payment <base64url>`. For MCP, this
  injects the credential into `params._meta["org.paymentauth/credential"]`.
  Each transport owns its wire format — the credential struct is passed in
  decoded form so the transport is free to serialise it however it needs to.
  """
  @callback set_credential(request :: term(), credential :: Credential.t()) :: term()

  api(:select_challenge, "Pick the first challenge whose method+intent is supported by a MultiProvider.",
    params: [
      challenges: [kind: :value, description: "List of MPP.Challenge structs in server offer order"],
      multi: [kind: :value, description: "MPP.Client.MultiProvider struct"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, challenge}` on success, `{:error, :no_supported_challenge}` if none matches"
    },
    errors: [:no_supported_challenge]
  )

  @doc """
  Pick the first challenge whose `method`/`intent` is supported by the
  `MultiProvider`.

  Preserves server offer order — the first supported challenge wins, matching
  `MPP.Client.MultiProvider.pay/2`'s dispatch order. Callers that need
  preference-based ranking (via `Accept-Payment`) should layer that on top.

  Returns `{:error, :no_supported_challenge}` if no challenge matches any
  provider, including the empty-list case.
  """
  @spec select_challenge([Challenge.t()], MultiProvider.t()) ::
          {:ok, Challenge.t()} | {:error, :no_supported_challenge}
  def select_challenge(challenges, %MultiProvider{} = multi) when is_list(challenges) do
    case Enum.find(challenges, fn %Challenge{method: m, intent: i} ->
           MultiProvider.supports?(multi, m, i)
         end) do
      %Challenge{} = c -> {:ok, c}
      nil -> {:error, :no_supported_challenge}
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour MPP.Client.Transport
    end
  end
end
