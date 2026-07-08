defmodule MPP.Client.Transport.HTTP do
  @moduledoc """
  HTTP implementation of `MPP.Client.Transport` over `Req`.

  Operates on `Req.Response` / `Req.Request` structs — this module does not
  construct Req clients itself. Callers (e.g. the payment-aware Req plugin)
  feed responses in and receive modified requests out.

  ## Wire format

    * Payment-required response: HTTP status `402`
    * Challenges: one or more `WWW-Authenticate` headers carrying the `Payment`
      scheme. Multiple challenges may appear as repeated header values or as a
      single comma-separated header value; both forms are handled.
    * Credential attachment: `Authorization: Payment <base64url-json>`,
      produced via `MPP.Headers.format_credential/1`.
    * Optional `Accept-Payment` advertisement via `set_accept_payment/2` or
      `set_accept_payment_from_providers/3` (gated by `MPP.Client.AcceptPolicy`).
  """

  use MPP.Client.Transport
  use Descripex, namespace: "/client"

  alias MPP.AcceptPayment
  alias MPP.Challenge
  alias MPP.Client.AcceptPolicy
  alias MPP.Client.Transport
  alias MPP.Credential
  alias MPP.Headers

  api(:payment_required?, "Return true if the HTTP response is a 402 Payment Required.",
    params: [
      response: [kind: :value, description: "Req.Response struct"]
    ],
    returns: %{type: :boolean, description: "true if status is 402"}
  )

  @impl Transport
  @spec payment_required?(Req.Response.t()) :: boolean()
  def payment_required?(%Req.Response{status: 402}), do: true

  @spec payment_required?(Req.Response.t()) :: false
  def payment_required?(%Req.Response{}), do: false

  api(:get_challenges, "Parse the Payment challenges from a 402 response's WWW-Authenticate headers.",
    params: [
      response: [kind: :value, description: "Req.Response struct"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, [challenge]}` on success, `{:error, reason}` otherwise"
    },
    errors: [
      :no_payment_challenges,
      :missing_www_authenticate,
      :invalid_scheme,
      :missing_required_params,
      :duplicate_param,
      :invalid_auth_params
    ]
  )

  @impl Transport
  @spec get_challenges(Req.Response.t()) :: {:ok, [Challenge.t()]} | {:error, term()}
  def get_challenges(%Req.Response{} = response) do
    case Req.Response.get_header(response, "www-authenticate") do
      [] -> {:error, :missing_www_authenticate}
      values -> values |> Enum.join(", ") |> Headers.parse_challenges()
    end
  end

  api(:set_credential, "Attach a credential to a Req.Request as `Authorization: Payment <...>`.",
    params: [
      request: [kind: :value, description: "Req.Request struct"],
      credential: [kind: :value, description: "MPP.Credential struct"]
    ],
    returns: %{type: :struct, description: "Req.Request with the Authorization header set"}
  )

  @impl Transport
  @spec set_credential(Req.Request.t(), Credential.t()) :: Req.Request.t()
  def set_credential(%Req.Request{} = request, %Credential{} = credential) do
    Req.Request.put_header(request, "authorization", Headers.format_credential(credential))
  end

  api(
    :set_accept_payment,
    "Attach an `Accept-Payment` header built from preference entries.",
    params: [
      request: [kind: :value, description: "Req.Request struct"],
      entries: [
        kind: :value,
        description: "List of `{method, intent, q}` tuples advertising client capabilities"
      ]
    ],
    returns: %{type: :struct, description: "Req.Request with Accept-Payment header set"}
  )

  @doc """
  Attach an `Accept-Payment` header from preference entries.

  Does not overwrite an existing `Accept-Payment` header on the request.
  """
  @spec set_accept_payment(Req.Request.t(), [AcceptPayment.entry() | map()]) ::
          Req.Request.t()
  def set_accept_payment(%Req.Request{} = request, entries) when is_list(entries) do
    if entries == [] or has_accept_payment_header?(request) do
      request
    else
      Req.Request.put_header(request, "accept-payment", AcceptPayment.format(entries))
    end
  end

  api(
    :set_accept_payment_from_providers,
    "Attach `Accept-Payment` from supported `(method, intent)` pairs when policy allows.",
    params: [
      request: [kind: :value, description: "Req.Request struct"],
      providers: [
        kind: :value,
        description: "List of `{method, intent}` tuples the client can pay with"
      ],
      policy: [
        kind: :value,
        description: "MPP.Client.AcceptPolicy gate (defaults to `:always`)"
      ]
    ],
    returns: %{type: :struct, description: "Req.Request, unchanged when policy blocks injection"}
  )

  @doc """
  Attach `Accept-Payment` from a list of supported `{method, intent}` pairs.

  Respects `MPP.Client.AcceptPolicy` — when `allows?/2` is false the request is
  returned unchanged. Caller-set `Accept-Payment` headers are never overwritten.
  """
  @spec set_accept_payment_from_providers(
          Req.Request.t(),
          [{String.t(), String.t()}],
          AcceptPolicy.t()
        ) :: Req.Request.t()
  def set_accept_payment_from_providers(%Req.Request{} = request, providers, policy \\ :always) when is_list(providers) do
    url = request_url(request)

    if providers == [] or has_accept_payment_header?(request) or not AcceptPolicy.allows?(policy, url) do
      request
    else
      entries = Enum.map(providers, fn {method, intent} -> {method, intent, 1.0} end)
      set_accept_payment(request, entries)
    end
  end

  defp has_accept_payment_header?(request) do
    Req.Request.get_header(request, "accept-payment") != []
  end

  defp request_url(%Req.Request{url: %URI{} = uri}), do: URI.to_string(uri)
  defp request_url(%Req.Request{url: url}) when is_binary(url), do: url
  defp request_url(%Req.Request{}), do: ""
end
