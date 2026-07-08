defmodule MPP.Methods.Stripe do
  @moduledoc """
  Stripe payment method — verifies payment via Stripe PaymentIntent with SPT.

  The client creates a Shared Payment Granted Token (SPT) via Stripe, includes
  it in the credential payload, and the server creates a PaymentIntent with
  `confirm: true` to charge it immediately.

  ## Configuration

  Pass Stripe-specific config via `:method_config` in `MPP.Plug` opts:

      plug MPP.Plug,
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MPP.Methods.Stripe,
        amount: "5000",
        currency: "usd",
        method_config: %{
          "stripe_secret_key" => "sk_test_...",
          "network_id" => "profile_1Mqx...",
          "payment_method_types" => ["card"]
        }

  ## Config Keys

    * `"stripe_secret_key"` — (required) Stripe secret key for PaymentIntent creation
    * `"network_id"` — (required) Stripe Business Network profile ID
    * `"payment_method_types"` — (optional) accepted payment methods, defaults to `["card"]`
    * `"realm"` — (optional, injected by Plug) server realm for analytics metadata

  ## Credential Payload

  The credential `payload` map must contain:

    * `"spt"` — (required) Stripe Shared Payment Granted Token (e.g., `"spt_1N4..."`)
    * `"externalId"` — (optional) caller-provided correlation ID, echoed in receipt
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Receipt

  @stripe_api_url "https://api.stripe.com/v1/payment_intents"

  @required_config_keys ~w(stripe_secret_key network_id)

  api(:method_name, "Return the payment method identifier for Stripe.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "stripe"

  api(
    :validate_config!,
    "Validate Stripe method_config at init time. Raises on missing `stripe_secret_key` or `network_id`.",
    params: [
      config: [kind: :value, description: "method_config map to validate"]
    ],
    returns: %{type: :atom, description: "`:ok` on success, raises `ArgumentError` on missing keys"}
  )

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    missing = Enum.filter(@required_config_keys, &is_nil(config[&1]))

    if missing != [] do
      raise ArgumentError,
            "MPP.Methods.Stripe requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end

    :ok
  end

  api(:verify, "Verify a Stripe SPT credential by creating a PaymentIntent with `confirm: true`.",
    params: [
      payload: [
        kind: :value,
        description: "Credential payload map containing `\"spt\"` (Stripe Shared Payment Granted Token)"
      ],
      charge: [
        kind: :value,
        description: "Charge intent struct with amount, currency, and method_details (including `stripe_secret_key`)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, error}` on failure"},
    errors: [:invalid_payload, :verification_failed]
  )

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- check_external_id_binding(payload, charge),
         {:ok, spt} <- extract_spt(payload),
         {:ok, stripe_secret_key} <- Shared.require_config(config, "stripe_secret_key", "Stripe"),
         {:ok, pi} <- create_payment_intent(spt, charge, stripe_secret_key, config) do
      check_status(pi, charge)
    end
  end

  api(
    :challenge_method_details,
    "Return Stripe-specific fields (`networkId`, `paymentMethodTypes`) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details containing `network_id` and optionally `payment_method_types`"
      ]
    ],
    returns: %{
      type: :map_or_nil,
      description: "Map with `networkId` and `paymentMethodTypes` keys, or `nil` if no `network_id` configured"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map() | nil
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    case config["network_id"] do
      nil ->
        nil

      network_id ->
        types = config["payment_method_types"] || ["card"]
        %{"networkId" => network_id, "paymentMethodTypes" => types}
    end
  end

  # Extracts the SPT from the credential payload.
  defp extract_spt(%{"spt" => spt}) when is_binary(spt) and byte_size(spt) > 0, do: {:ok, spt}
  defp extract_spt(_), do: {:error, Errors.new(:invalid_payload, "Missing or invalid 'spt' field in credential payload")}

  # Rejects credentials whose externalId disagrees with the route request (mppx #537).
  defp check_external_id_binding(_payload, %Charge{external_id: nil}), do: :ok

  defp check_external_id_binding(payload, %Charge{external_id: request_id}) do
    case payload["externalId"] do
      cred_id when cred_id == request_id -> :ok
      _ -> {:error, Errors.new(:invalid_challenge, "credential externalId does not match this route request")}
    end
  end

  # Creates a Stripe PaymentIntent with the SPT and returns the response body.
  defp create_payment_intent(spt, charge, stripe_secret_key, config) do
    body = build_request_body(spt, charge, config)
    auth = Base.encode64(stripe_secret_key <> ":")

    idempotency_key =
      case config["challenge_id"] do
        nil -> "mpp_#{spt}"
        challenge_id -> "mpp_#{challenge_id}_#{spt}"
      end

    req_options = config["req_options"] || []

    result =
      Req.request(
        [
          url: @stripe_api_url,
          method: :post,
          headers: [
            {"authorization", "Basic #{auth}"},
            {"idempotency-key", idempotency_key},
            {"content-type", "application/x-www-form-urlencoded"}
          ],
          body: URI.encode_query(body, :www_form)
        ],
        req_options
      )

    case result do
      {:ok, %Req.Response{status: status, body: body} = response} when status in 200..299 ->
        if idempotent_replayed?(response) do
          {:error, Errors.new(:verification_failed, "Payment has already been processed.")}
        else
          {:ok, body}
        end

      {:ok, %Req.Response{}} ->
        {:error, Errors.new(:verification_failed, "Stripe PaymentIntent creation failed")}

      {:error, _exception} ->
        {:error, Errors.new(:verification_failed, "Stripe API request failed")}
    end
  end

  # Builds the form-encoded body for PaymentIntent creation.
  defp build_request_body(spt, charge, config) do
    base = [
      {"amount", charge.amount},
      {"currency", charge.currency},
      {"confirm", "true"},
      {"shared_payment_granted_token", spt},
      {"automatic_payment_methods[enabled]", "true"},
      {"automatic_payment_methods[allow_redirects]", "never"}
    ]

    metadata = build_metadata(config)
    base ++ metadata
  end

  # Builds analytics metadata key-value pairs for Stripe PaymentIntent.
  defp build_metadata(config) do
    metadata = [
      {"metadata[mpp_version]", "1"},
      {"metadata[mpp_is_mpp]", "true"}
    ]

    metadata =
      case config["challenge_id"] do
        nil -> metadata
        id -> metadata ++ [{"metadata[mpp_challenge_id]", id}]
      end

    case config["realm"] do
      nil -> metadata
      realm -> metadata ++ [{"metadata[mpp_server_id]", realm}]
    end
  end

  # Stripe marks replayed idempotency keys with Idempotent-Replayed: true.
  # https://docs.stripe.com/error-low-level#idempotency
  defp idempotent_replayed?(response) do
    match?(["true" | _], Req.Response.get_header(response, "idempotent-replayed"))
  end

  # Checks the PaymentIntent status and returns a receipt or error.
  defp check_status(%{"status" => "succeeded", "id" => pi_id}, %Charge{} = charge) do
    receipt =
      Receipt.new(
        method: method_name(),
        reference: pi_id,
        external_id: charge.external_id
      )

    {:ok, receipt}
  end

  defp check_status(%{"status" => "requires_action"}, _charge) do
    {:error, Errors.new(:verification_failed, "PaymentIntent requires action (e.g., 3DS)")}
  end

  defp check_status(%{"status" => status}, _charge) do
    {:error, Errors.new(:verification_failed, "PaymentIntent status: #{status}")}
  end

  defp check_status(_body, _charge) do
    {:error, Errors.new(:verification_failed, "Unexpected Stripe response: missing status field")}
  end
end
