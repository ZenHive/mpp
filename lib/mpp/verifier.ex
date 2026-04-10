defmodule MPP.Verifier do
  @moduledoc """
  Transport-neutral payment credential verification.

  Implements the full MPP verification pipeline — HMAC challenge binding,
  realm match, expiration check, request match, and method-specific
  verification — without any HTTP or transport dependency.

  `MPP.Plug` delegates to this module for HTTP transport. `MPP.Mcp` and
  the client SDK (Phase 12) can use it directly for JSON-RPC and other
  transports.

  ## Usage

      opts = [
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MyApp.Payments.Stripe,
        charge: charge,
        method_config: %{"stripe_secret_key" => "sk_..."}
      ]

      case MPP.Verifier.verify(credential, opts) do
        {:ok, receipt} -> # payment verified
        {:error, %MPP.Errors{} = error} -> # verification failed
      end

  ## Options

    * `:secret_key` — (required) HMAC-SHA256 key for challenge verification
    * `:realm` — (required) expected server protection space
    * `:method` — (required) module implementing `MPP.Method`
    * `:charge` — (required) `MPP.Intents.Charge.t()` for this endpoint
    * `:method_config` — (optional) server-only config map, default `%{}`
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Receipt

  api(:verify, "Verify a payment credential against endpoint configuration. Transport-neutral.",
    params: [
      credential: [kind: :value, description: "Parsed MPP credential with echoed challenge and payment payload"],
      opts: [
        kind: :value,
        description:
          "Keyword list: :secret_key (HMAC key), :realm, :method (module), :charge (Charge.t()), :method_config (optional map)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, %Errors{}}` on failure"},
    errors: [
      :invalid_challenge,
      :intent_mismatch,
      :method_mismatch,
      :payment_expired,
      :request_mismatch,
      :verification_failed
    ]
  )

  @spec verify(Credential.t(), keyword()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%Credential{} = credential, opts) when is_list(opts) do
    secret_key = require_opt!(opts, :secret_key)
    realm = require_opt!(opts, :realm)
    method = require_opt!(opts, :method)
    charge = require_opt!(opts, :charge)
    method_config = Keyword.get(opts, :method_config, %{})

    runtime_config =
      method_config
      |> Map.put("challenge_id", credential.challenge.id)
      |> Map.put("realm", realm)

    charge_for_verify = merge_method_config(charge, runtime_config)

    with :ok <- Challenge.verify(credential.challenge, secret_key),
         :ok <- check_intent_match(credential.challenge, "charge"),
         :ok <- check_method_match(credential.challenge, method),
         :ok <- check_realm_match(credential.challenge, realm),
         :ok <- check_expiration(credential.challenge),
         :ok <- check_request_match(credential.challenge, charge),
         {:ok, receipt} <- method.verify(credential.payload, charge_for_verify) do
      {:ok, receipt}
    else
      {:error, :invalid_challenge} ->
        {:error, Errors.new(:invalid_challenge, "Challenge verification failed")}

      {:error, :payment_expired} ->
        {:error, Errors.new(:payment_expired, "Challenge has expired")}

      {:error, :intent_mismatch} ->
        {:error, Errors.new(:invalid_challenge, "Credential intent does not match this endpoint")}

      {:error, :method_mismatch} ->
        {:error, Errors.new(:invalid_challenge, "Credential method does not match this endpoint")}

      {:error, :request_mismatch} ->
        {:error, Errors.new(:invalid_challenge, "Request parameters do not match this endpoint")}

      {:error, %Errors{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Errors.new(:verification_failed, "Payment verification failed: #{inspect(reason)}")}
    end
  end

  # Verifies the credential's intent matches the expected intent type.
  # Prevents cross-intent replay: a "session" credential can't be used on a "charge" endpoint.
  defp check_intent_match(%Challenge{intent: intent}, intent), do: :ok
  defp check_intent_match(_challenge, _expected), do: {:error, :intent_mismatch}

  # Verifies the credential's method matches the configured method module.
  # Prevents cross-method attacks: a credential for "stripe" can't be verified by the "tempo" module.
  # Plug routes by method name before calling Verifier, but MCP/client callers need this guard.
  defp check_method_match(%Challenge{method: method_name}, method_module) do
    if method_module.method_name() == method_name, do: :ok, else: {:error, :method_mismatch}
  end

  # Verifies the credential's realm matches the expected realm.
  # Defense-in-depth: HMAC binding covers realm when secrets are unique per realm,
  # but an explicit check prevents cross-realm replay in shared-secret deployments.
  defp check_realm_match(%Challenge{realm: realm}, realm), do: :ok
  defp check_realm_match(_challenge, _realm), do: {:error, :request_mismatch}

  # Checks whether a challenge has expired based on its `expires` field.
  defp check_expiration(%Challenge{expires: nil}), do: :ok

  defp check_expiration(%Challenge{expires: expires}) do
    case DateTime.from_iso8601(expires) do
      {:ok, expires_dt, _offset} ->
        if DateTime.before?(DateTime.utc_now(), expires_dt) do
          :ok
        else
          {:error, :payment_expired}
        end

      {:error, _} ->
        {:error, :payment_expired}
    end
  end

  # Compares the credential's request against the endpoint's charge using full
  # canonicalized string comparison. Prevents cross-route replay: a credential
  # for one endpoint can't be used on another, even if they share amount/currency.
  defp check_request_match(%Challenge{request: request}, charge) do
    expected =
      charge
      |> Charge.to_request()
      |> JCS.canonicalize()
      |> Base.url_encode64(padding: false)

    if request == expected, do: :ok, else: {:error, :request_mismatch}
  end

  # Merges server-only method_config into charge.method_details for verify/2.
  defp merge_method_config(charge, runtime_config) do
    merged = Map.merge(charge.method_details || %{}, runtime_config)
    %{charge | method_details: merged}
  end

  # Fetches a required option or raises with a clear message.
  defp require_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "MPP.Verifier.verify/2 requires the :#{key} option"
    end
  end
end
