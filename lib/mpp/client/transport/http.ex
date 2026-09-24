defmodule MPP.Client.Transport.HTTP do
  @moduledoc """
  HTTP implementation of `MPP.Client.Transport` over `Req`.

  Operates on `Req.Response` / `Req.Request` structs — this module does not
  construct Req clients itself. Automatic 402 pay-and-retry lives in
  `MPP.Client.Req`; this transport only detects, parses, and attaches.

  ## Cross-origin redirects

  This transport is passive: `set_credential/2` attaches whatever credential
  the caller supplies. A payment credential must never be created or attached
  after a redirect changed the request origin (scheme/host/port). `Req` follows
  redirects by default, so callers that drive this transport themselves must
  refuse that path — the same guard as mpp-rs `HttpError::CrossOriginRedirect`
  (`refs/mpp-rs/src/client/fetch.rs:256-272`, #379). `MPP.Client.Req.attach/2`
  enforces this; this module documents the contract for hand-rolled transports.

  ## Wire format

    * Payment-required response: HTTP status `402`
    * Challenges: one or more `WWW-Authenticate` headers carrying the `Payment`
      scheme. Multiple challenges may appear as repeated header values or as a
      single comma-separated header value; both forms are handled.
    * Credential attachment: `Authorization: Payment <base64url-json>` by default,
      or `Payment-Authorization` when the selected challenge advertised `header`.
      Produced via `MPP.Headers.format_credential/1`.
    * Sponsor-capacity responses remain payable 402 challenges. Call
      `retry_after/1` to consume their delta-seconds backoff signal; retry policy
      remains with the caller.
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
  alias MPP.X402
  alias MPP.X402.Headers, as: X402Headers

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

  api(:retry_after, "Read a Retry-After delta-seconds value from an HTTP response.",
    params: [response: [kind: :value, description: "Req.Response struct"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, seconds}` or `:error`"}
  )

  @doc "Read a positive `Retry-After` delta-seconds header from a response."
  @spec retry_after(Req.Response.t()) :: {:ok, pos_integer()} | :error
  def retry_after(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] -> parse_retry_after(value)
      _values -> :error
    end
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 -> {:ok, seconds}
      _other -> :error
    end
  end

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
      :invalid_auth_params,
      :invalid_expires
    ]
  )

  @impl Transport
  @spec get_challenges(Req.Response.t()) :: {:ok, [Challenge.t()]} | {:error, term()}
  def get_challenges(%Req.Response{} = response), do: get_challenges(response, nil)

  @doc """
  Parse native Payment challenges and x402 `PAYMENT-REQUIRED` offers together.

  `request_url` is accepted for existing callers and is not compared to an
  x402 `resource.url`. `MPP.X402.challenges_from_header/1` no longer takes a
  request URL (mppx #908): exact equality dropped payable offers when query
  strings, redirects, proxies, or port rewriting made the URLs differ.
  `MPP.X402.Plug` still binds the paid resource.
  """
  @spec get_challenges(Req.Response.t(), String.t() | nil) :: {:ok, [Challenge.t()]} | {:error, term()}
  def get_challenges(%Req.Response{} = response, _request_url) do
    merge_challenges(native_challenges(response), x402_challenges(response))
  end

  defp native_challenges(response) do
    case Req.Response.get_header(response, "www-authenticate") do
      [] -> {:error, :missing_www_authenticate}
      values -> values |> Enum.join(", ") |> Headers.parse_challenges()
    end
  end

  defp x402_challenges(response) do
    case Req.Response.get_header(response, "payment-required") do
      [] -> {:ok, []}
      [header | _rest] -> parse_x402_offers(header)
    end
  end

  defp parse_x402_offers(header) do
    case X402.challenges_from_header(header) do
      {:ok, challenges} -> {:ok, challenges}
      {:error, _reason} -> {:ok, []}
    end
  end

  defp merge_challenges({:ok, native}, {:ok, x402}), do: nonempty(native ++ x402)
  defp merge_challenges({:error, :missing_www_authenticate}, {:ok, []}), do: {:error, :missing_www_authenticate}
  defp merge_challenges({:error, :missing_www_authenticate}, {:ok, x402}), do: nonempty(x402)
  defp merge_challenges({:error, :no_payment_challenges}, {:ok, x402}), do: nonempty(x402)
  defp merge_challenges({:error, _reason}, {:ok, x402}) when x402 != [], do: {:ok, x402}
  defp merge_challenges({:error, reason}, _x402), do: {:error, reason}

  defp nonempty([]), do: {:error, :no_payment_challenges}
  defp nonempty(challenges), do: {:ok, challenges}

  api(:set_credential, "Attach a credential to a Req.Request on the challenge's advertised field.",
    params: [
      request: [kind: :value, description: "Req.Request struct"],
      credential: [kind: :value, description: "MPP.Credential struct"]
    ],
    returns: %{
      type: :struct,
      description: "Req.Request with the credential header set (`Authorization` or `Payment-Authorization`)"
    }
  )

  @impl Transport
  @spec set_credential(Req.Request.t(), Credential.t()) :: Req.Request.t()
  def set_credential(%Req.Request{} = request, %Credential{} = credential) do
    if X402.synthetic?(credential.challenge) do
      put_x402_signature(request, credential)
    else
      header_name = credential.challenge |> Challenge.credential_header() |> String.downcase(:ascii)
      value = Headers.format_credential(credential)

      request
      |> clear_stale_payment_headers(header_name)
      |> Req.Request.put_header(header_name, value)
    end
  end

  defp put_x402_signature(request, credential) do
    case X402Headers.encode_payment_signature(credential.payload) do
      {:ok, header} ->
        request
        |> Req.Request.delete_header("payment-signature")
        |> Req.Request.put_header("payment-signature", header)

      {:error, reason} ->
        raise ArgumentError, "invalid x402 PAYMENT-SIGNATURE payload: #{inspect(reason)}"
    end
  end

  # Never erase ordinary application credentials from Authorization. A stale
  # `Payment` scheme on Authorization is cleared when attaching to
  # Payment-Authorization (mppx `setCredentialHeader`). The unused alternate
  # field is always dropped so a retry cannot present credentials in both.
  defp clear_stale_payment_headers(request, "payment-authorization") do
    request
    |> delete_payment_scheme("authorization")
    |> Req.Request.delete_header("payment-authorization")
  end

  defp clear_stale_payment_headers(request, _authorization) do
    Req.Request.delete_header(request, "payment-authorization")
  end

  defp delete_payment_scheme(request, name) do
    case Req.Request.get_header(request, name) do
      [header | _] ->
        case Headers.parse_credential(header) do
          {:error, :invalid_scheme} -> request
          _payment -> Req.Request.delete_header(request, name)
        end

      [] ->
        request
    end
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
