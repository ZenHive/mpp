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
  an MCP JSON-RPC client, etc.) is actually issuing requests. HTTP is
  `MPP.Client.Transport.HTTP`; MCP is `MPP.Client.Transport.MCP`; generic
  JSON-RPC (root-level `_meta`) is `MPP.Client.Transport.JsonRpc`.
  WebSocket (typed MPP frames) is `MPP.Client.Transport.WebSocket`.

  ## Callbacks

    * `c:payment_required?/1` — plain boolean check on a response
    * `c:get_challenges/1` — parse the response into a challenge list
    * `c:set_credential/2` — return a new request with the credential attached
      in a transport-specific way

  ## Selection

  `select_challenge/2` delegates to `MPP.Client.SelectionPolicy` — the
  transport-neutral policy surface shared with HTTP (`MPP.Client.Req`) and MCP
  client orchestration. The default preserves server-advertised order; pass
  `:selection` or `:accept_payment` to `select_challenge/3` to configure it.
  """

  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.SelectionPolicy
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

  api(:select_challenge, "Pick a MultiProvider-supported challenge via MPP.Client.SelectionPolicy.",
    params: [
      challenges: [kind: :value, description: "List of MPP.Challenge structs in server offer order"],
      multi: [kind: :value, description: "MPP.Client.MultiProvider struct"],
      opts: [
        kind: :value,
        description: "Optional `:selection` policy or `:accept_payment` preference list (`{method, intent, q}` tuples)"
      ]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, challenge}` on success, `{:error, :no_supported_challenge}` if none matches"
    },
    errors: [:no_supported_challenge]
  )

  @doc """
  Pick a supported challenge via `MPP.Client.SelectionPolicy`.

  Options:

    * `:selection` — a `SelectionPolicy.t()` (default `:server_order`)
    * `:accept_payment` — preference entries; used when `:selection` is omitted

  Returns `{:error, :no_supported_challenge}` if no challenge matches any
  provider, including the empty-list case.
  """
  @spec select_challenge([Challenge.t()], MultiProvider.t(), keyword()) ::
          {:ok, Challenge.t()} | {:error, :no_supported_challenge}
  def select_challenge(challenges, %MultiProvider{} = multi, opts \\ []) when is_list(challenges) do
    SelectionPolicy.select(challenges, multi, policy_from_opts(opts))
  end

  defp policy_from_opts(opts) do
    case Keyword.get(opts, :selection) do
      nil ->
        case Keyword.get(opts, :accept_payment, []) do
          [] -> SelectionPolicy.default()
          preferences -> {:accept_payment, preferences}
        end

      policy ->
        policy
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour MPP.Client.Transport
    end
  end
end
