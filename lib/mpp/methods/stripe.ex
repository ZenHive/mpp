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
    * `"connect"` — (optional) server-side Stripe Connect settlement policy (see below)
    * `"realm"` — (optional, injected by Plug) server realm for analytics metadata

  ## Stripe Connect settlement

  Pass a `"connect"` map in `method_config` to route the resulting PaymentIntent
  to a connected account (destination charge, direct charge, or application-fee
  split). Connect settlement is a **server-only credential** — it is merged into
  the charge at verify time and is **never serialized into the public 402
  challenge**, matching the mppx reference (`src/stripe/server/Charge.ts`, where
  `connect` is documented as "Not included in MPP challenges").

      method_config: %{
        "stripe_secret_key" => "sk_test_...",
        "network_id" => "profile_1Mqx...",
        "connect" => %{
          # Destination charge: platform is merchant of record, funds routed on.
          "transfer_data" => %{"destination" => "acct_seller", "amount" => 4000},
          "application_fee_amount" => 500,
          "on_behalf_of" => "acct_seller",
          "transfer_group" => "order_42",
          # Direct charge: run the PaymentIntent on the connected account itself.
          "stripe_account" => "acct_seller"
        }
      }

  Wire mapping applied to the PaymentIntent (form-encoded), per the mppx reference:

    * `"application_fee_amount"` (integer) → `application_fee_amount`
    * `"on_behalf_of"` (string) → `on_behalf_of`
    * `"transfer_data"` `%{"destination" => ..., "amount" => ...}` →
      `transfer_data[destination]` / `transfer_data[amount]`
    * `"transfer_group"` (string) → `transfer_group`
    * `"stripe_account"` (string) → `Stripe-Account` request header

  Settlement is validated against the charge amount before the PaymentIntent is
  created: account ids must be non-empty, fee/transfer amounts must be
  non-negative integers not exceeding the payment amount.

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

  # Stripe API version with `.preview` suffix — required for
  # `shared_payment_granted_token` (SPTs are in private preview). Keep in sync
  # with mppx's `stripePreviewVersion` (refs/mppx/src/stripe/internal/constants.ts).
  @stripe_preview_version "2026-02-25.preview"

  @required_config_keys ~w(stripe_secret_key network_id)

  api(:method_name, "Return the payment method identifier for Stripe.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "stripe"

  api(:credential_types, "Return the Stripe charge payload types. Stripe uses SPT tokens, not typed hash payloads.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: []

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
         {:ok, settlement} <- resolve_connect_settlement(config, charge),
         {:ok, pi} <- create_payment_intent(spt, charge, stripe_secret_key, config, settlement) do
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

  # Resolves the optional Stripe Connect settlement policy from server-only
  # method_config. Returns {:ok, nil} when no `connect` map is configured, or an
  # error when the configured settlement is invalid for this charge amount.
  # Connect settlement is never carried in the public challenge — it is merged
  # into method_details at verify time (see MPP.Plug / MPP.Verifier).
  defp resolve_connect_settlement(config, %Charge{} = charge) do
    case config["connect"] do
      nil -> {:ok, nil}
      settlement when is_map(settlement) -> validate_connect_settlement(settlement, charge.amount)
      _ -> {:error, connect_error("Stripe Connect settlement must be a map.")}
    end
  end

  # Validates Connect settlement fields against the payment amount, mirroring the
  # mppx reference (`validateConnectSettlement` in src/stripe/server/Charge.ts):
  # account ids non-empty; fee/transfer amounts non-negative integers ≤ amount.
  defp validate_connect_settlement(settlement, amount) do
    with {:ok, payment_amount} <- parse_amount(amount),
         :ok <- validate_account(settlement["stripe_account"], "stripe_account"),
         :ok <- validate_account(settlement["on_behalf_of"], "on_behalf_of"),
         :ok <- validate_settlement_amount(settlement["application_fee_amount"], payment_amount, "application_fee_amount"),
         :ok <- validate_transfer_group(settlement["transfer_group"]),
         :ok <- validate_transfer_data(settlement["transfer_data"], payment_amount) do
      {:ok, settlement}
    end
  end

  # mppx enforces `transferGroup: string` via its TS types; the runtime
  # equivalent here keeps a misconfigured non-string value from raising in
  # URI.encode_query at request time.
  defp validate_transfer_group(nil), do: :ok
  defp validate_transfer_group(value) when is_binary(value), do: :ok
  defp validate_transfer_group(_value), do: {:error, connect_error("Stripe Connect transfer_group must be a string.")}

  defp parse_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, connect_error("Stripe amount must be a non-negative integer.")}
    end
  end

  defp parse_amount(_), do: {:error, connect_error("Stripe amount must be a non-negative integer.")}

  defp validate_account(nil, _name), do: :ok
  defp validate_account(value, _name) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_account(_value, name), do: {:error, connect_error("Stripe Connect #{name} must be non-empty.")}

  defp validate_settlement_amount(nil, _payment_amount, _name), do: :ok

  defp validate_settlement_amount(value, payment_amount, name) when is_integer(value) and value >= 0 do
    if value <= payment_amount do
      :ok
    else
      {:error, connect_error("Stripe Connect #{name} must be less than or equal to the PaymentIntent amount.")}
    end
  end

  defp validate_settlement_amount(_value, _payment_amount, name) do
    {:error, connect_error("Stripe Connect #{name} must be a non-negative integer.")}
  end

  defp validate_transfer_data(nil, _payment_amount), do: :ok

  defp validate_transfer_data(%{"destination" => dest} = transfer_data, payment_amount)
       when is_binary(dest) and byte_size(dest) > 0 do
    validate_settlement_amount(transfer_data["amount"], payment_amount, "transfer_data.amount")
  end

  defp validate_transfer_data(transfer_data, _payment_amount) when is_map(transfer_data) do
    {:error, connect_error("Stripe Connect transfer_data.destination must be non-empty.")}
  end

  defp validate_transfer_data(_transfer_data, _payment_amount) do
    {:error, connect_error("Stripe Connect transfer_data must be a map.")}
  end

  defp connect_error(detail), do: Errors.new(:verification_failed, detail)

  # Creates a Stripe PaymentIntent with the SPT and returns the response body.
  defp create_payment_intent(spt, charge, stripe_secret_key, config, settlement) do
    body = build_request_body(spt, charge, config, settlement)
    auth = Base.encode64(stripe_secret_key <> ":")

    idempotency_key =
      case config["challenge_id"] do
        nil -> "mpp_#{spt}"
        challenge_id -> "mpp_#{challenge_id}_#{spt}"
      end

    req_options = config["req_options"] || []

    headers =
      [
        {"authorization", "Basic #{auth}"},
        {"idempotency-key", idempotency_key},
        {"content-type", "application/x-www-form-urlencoded"},
        {"stripe-version", @stripe_preview_version}
      ] ++ stripe_account_header(settlement)

    result =
      Req.request(
        [
          url: @stripe_api_url,
          method: :post,
          headers: headers,
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
  defp build_request_body(spt, charge, config, settlement) do
    base = [
      {"amount", charge.amount},
      # Stripe's API documents a lowercase ISO 4217 code. The intent layer keeps
      # the operator's string verbatim (wire parity with mpp-rs/mppx), so the
      # normalization belongs here, at the provider boundary.
      {"currency", String.downcase(charge.currency)},
      {"confirm", "true"},
      {"shared_payment_granted_token", spt},
      {"automatic_payment_methods[enabled]", "true"},
      {"automatic_payment_methods[allow_redirects]", "never"}
    ]

    base ++ build_metadata(config) ++ connect_body_params(settlement)
  end

  # Maps the Connect settlement policy to form-encoded PaymentIntent params, in
  # the same field order as the mppx reference (`createWithSecretKey`).
  defp connect_body_params(nil), do: []

  defp connect_body_params(settlement) do
    []
    |> put_int_param("application_fee_amount", settlement["application_fee_amount"])
    |> put_str_param("on_behalf_of", settlement["on_behalf_of"])
    |> put_transfer_data_params(settlement["transfer_data"])
    |> put_str_param("transfer_group", settlement["transfer_group"])
  end

  defp put_str_param(params, _key, nil), do: params
  defp put_str_param(params, key, value), do: params ++ [{key, value}]

  defp put_int_param(params, _key, nil), do: params
  defp put_int_param(params, key, value), do: params ++ [{key, Integer.to_string(value)}]

  defp put_transfer_data_params(params, nil), do: params

  defp put_transfer_data_params(params, %{"destination" => destination} = transfer_data) do
    put_int_param(
      params ++ [{"transfer_data[destination]", destination}],
      "transfer_data[amount]",
      transfer_data["amount"]
    )
  end

  # Routes a direct charge onto the connected account via the Stripe-Account header.
  defp stripe_account_header(nil), do: []

  defp stripe_account_header(settlement) do
    case settlement["stripe_account"] do
      nil -> []
      account -> [{"stripe-account", account}]
    end
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
