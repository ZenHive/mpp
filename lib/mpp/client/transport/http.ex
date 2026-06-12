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
  """

  use MPP.Client.Transport
  use Descripex, namespace: "/client"

  alias MPP.Challenge
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
end
