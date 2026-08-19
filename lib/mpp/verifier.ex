defmodule MPP.Verifier do
  @moduledoc """
  Transport-neutral payment credential verification.

  Implements the full MPP verification pipeline — Tier-1 HMAC challenge binding
  (server-realm provenance + expiry), Tier-2 pinned-field safety net, and
  method-specific verification — without any HTTP or transport dependency.

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
    * `:digest` — (optional) expected endpoint digest value
    * `:opaque` — (optional) expected endpoint opaque value

  ## Verification tiers

  **Tier 1** — HMAC provenance using the server's configured realm (not the echoed
  realm) plus expiry. Failures return `:invalid_challenge` or `:payment_expired`.

  **Tier 2** — Field-by-field pinning of the credential's echoed challenge against
  this endpoint's configuration (realm, method, intent, request, digest, opaque).
  Failures return `:credential_mismatch` so callers can distinguish replay attacks
  from corrupt credentials.
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Receipt
  alias MPP.Telemetry

  require Logger

  @verification_failed_detail "Payment verification failed"

  @expected_intent "charge"

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
      :credential_mismatch,
      :intent_mismatch,
      :method_mismatch,
      :payment_expired,
      :realm_mismatch,
      :request_mismatch,
      :invalid_payload,
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
    digest = Keyword.get(opts, :digest)
    opaque = Keyword.get(opts, :opaque)

    runtime_config =
      method_config
      |> Map.put("challenge_id", credential.challenge.id)
      |> Map.put("realm", realm)
      |> Map.put("credential_source", credential.source)

    charge_for_verify = merge_method_config(charge, runtime_config)
    start_time = Telemetry.verify_start(credential, charge, %{realm: realm})

    result =
      with :ok <- verify_tier1(credential.challenge, secret_key, realm),
           :ok <- verify_pinned_fields(credential.challenge, method, realm, charge, digest, opaque),
           :ok <- check_credential_type(credential, method),
           {:ok, receipt} <- method.verify(credential.payload, charge_for_verify) do
        {:ok, receipt}
      else
        {:error, :invalid_challenge} ->
          {:error, Errors.new(:invalid_challenge, "Challenge verification failed")}

        {:error, :payment_expired} ->
          {:error, Errors.new(:payment_expired, "Challenge has expired")}

        {:error, :missing_expires} ->
          {:error, Errors.new(:credential_mismatch, "Challenge missing required expires field")}

        {:error, :invalid_expires} ->
          {:error, Errors.new(:credential_mismatch, "Challenge expires is not a valid ISO 8601 timestamp")}

        {:error, reason}
        when reason in [
               :intent_mismatch,
               :method_mismatch,
               :realm_mismatch,
               :request_mismatch,
               :digest_mismatch,
               :opaque_mismatch,
               :currency_mismatch,
               :recipient_mismatch,
               :chain_id_mismatch
             ] ->
          {:error, Errors.new(:credential_mismatch, pinning_detail(reason, credential.challenge, charge))}

        {:error, %Errors{} = error} ->
          {:error, error}

        {:error, reason} ->
          Logger.warning("MPP.Verifier: payment verification failed: #{inspect(reason)}")
          {:error, Errors.new(:verification_failed, @verification_failed_detail)}
      end

    case result do
      {:ok, receipt} ->
        Telemetry.verify_ok(credential, charge, start_time, %{realm: realm})
        Telemetry.receipt(credential, receipt, charge, %{realm: realm})
        {:ok, receipt}

      {:error, error} ->
        Telemetry.verify_fail(credential, charge, start_time, error, %{realm: realm})
        {:error, error}
    end
  end

  # Tier 1: HMAC provenance (server realm) + expiry.
  defp verify_tier1(challenge, secret_key, server_realm) do
    with :ok <- Challenge.verify_server_binding(challenge, secret_key, server_realm) do
      check_expiration(challenge)
    end
  end

  # Tier 2: pinned field safety net — explicit field-by-field comparison against
  # endpoint configuration. Matches mpp-rs `verify_pinned_fields/2` semantics.
  defp verify_pinned_fields(challenge, method_module, expected_realm, charge, expected_digest, expected_opaque) do
    with :ok <- check_method_match(challenge, method_module),
         :ok <- check_intent_match(challenge, @expected_intent),
         :ok <- check_realm_match(challenge, expected_realm),
         :ok <- check_opaque_match(challenge, expected_opaque),
         {:ok, request} <- decode_credential_request(challenge),
         :ok <- check_request_currency(request, charge),
         :ok <- check_request_recipient(request, charge),
         :ok <- check_request_chain_id(request, charge),
         :ok <- check_request_match(challenge, charge) do
      check_digest_match(challenge, expected_digest)
    end
  end

  defp pinning_detail(:intent_mismatch, challenge, _charge) do
    "Credential intent '#{challenge.intent}' does not match this route's requirements (expected '#{@expected_intent}')"
  end

  defp pinning_detail(:method_mismatch, challenge, _charge) do
    "Credential method '#{challenge.method}' does not match this route's requirements"
  end

  defp pinning_detail(:realm_mismatch, challenge, _charge) do
    "Credential realm '#{challenge.realm}' does not match this route's requirements"
  end

  defp pinning_detail(:request_mismatch, _challenge, _charge) do
    "Request parameters do not match this endpoint"
  end

  defp pinning_detail(:digest_mismatch, _challenge, _charge) do
    "Credential digest does not match this endpoint"
  end

  defp pinning_detail(:opaque_mismatch, _challenge, _charge) do
    "Credential opaque data does not match this route's requirements"
  end

  defp pinning_detail(:currency_mismatch, _challenge, charge) do
    "Credential currency does not match this route's requirements (expected '#{charge.currency}')"
  end

  defp pinning_detail(:recipient_mismatch, _challenge, _charge) do
    "Credential recipient does not match this route's requirements"
  end

  defp pinning_detail(:chain_id_mismatch, _challenge, charge) do
    expected = get_in(charge.method_details || %{}, ["chainId"])

    "Credential chainId does not match this route's requirements (expected '#{expected}')"
  end

  # `payload.type` names a first-class payload type (EVM spec §1.3 / Tempo
  # §5.2 / mpp-rs `PayloadType`). Any typed payload is gated on the method's
  # `credential_types/0` before `method.verify/2`; `type="hash"` additionally
  # requires the structural hash payload (parse lives on Credential). Untyped
  # payloads are not gated.
  defp check_credential_type(%Credential{payload: %{"type" => type} = payload}, method) when is_binary(type) do
    cond do
      type not in method.credential_types() ->
        {:error, Errors.new(:invalid_payload, ~s(type="#{type}" is not accepted by this payment method))}

      type == "hash" ->
        case Credential.parse_hash_payload(payload) do
          {:ok, _hash} -> :ok
          {:error, _reason} -> {:error, Errors.new(:invalid_payload, "hash payload requires 'hash' field")}
        end

      true ->
        :ok
    end
  end

  defp check_credential_type(%Credential{payload: %{"type" => _type}}, _method) do
    {:error, Errors.new(:invalid_payload, "credential payload 'type' must be a string")}
  end

  defp check_credential_type(_credential, _method), do: :ok

  defp check_intent_match(%Challenge{intent: intent}, intent), do: :ok
  defp check_intent_match(_challenge, _expected), do: {:error, :intent_mismatch}

  defp check_method_match(%Challenge{method: method_name}, method_module) do
    if method_module.method_name() == method_name, do: :ok, else: {:error, :method_mismatch}
  end

  defp check_realm_match(%Challenge{realm: realm}, realm), do: :ok
  defp check_realm_match(_challenge, _realm), do: {:error, :realm_mismatch}

  defp check_expiration(%Challenge{expires: nil}), do: {:error, :missing_expires}

  defp check_expiration(%Challenge{expires: expires}) do
    case DateTime.from_iso8601(expires) do
      {:ok, expires_dt, _offset} ->
        if DateTime.before?(DateTime.utc_now(), expires_dt) do
          :ok
        else
          {:error, :payment_expired}
        end

      {:error, _} ->
        {:error, :invalid_expires}
    end
  end

  defp check_request_match(%Challenge{request: request}, charge) do
    expected =
      charge
      |> Charge.to_request()
      |> JCS.canonicalize()
      |> Base.url_encode64(padding: false)

    if request == expected, do: :ok, else: {:error, :request_mismatch}
  end

  defp check_request_currency(%{"currency" => currency}, %Charge{currency: expected}) do
    if currency == expected, do: :ok, else: {:error, :currency_mismatch}
  end

  defp check_request_currency(_request, _charge), do: {:error, :currency_mismatch}

  defp check_request_recipient(%{"recipient" => recipient}, %Charge{recipient: expected}) when is_binary(expected) do
    if recipient == expected, do: :ok, else: {:error, :recipient_mismatch}
  end

  defp check_request_recipient(_request, %Charge{recipient: nil}), do: :ok

  defp check_request_recipient(_request, %Charge{recipient: _}), do: {:error, :recipient_mismatch}

  defp check_request_chain_id(request, %Charge{method_details: %{"chainId" => expected}}) do
    actual = get_in(request, ["methodDetails", "chainId"])
    actual_str = chain_id_string(actual)

    if actual_str == chain_id_string(expected) do
      :ok
    else
      {:error, :chain_id_mismatch}
    end
  end

  defp check_request_chain_id(_request, _charge), do: :ok

  defp chain_id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp chain_id_string(value) when is_binary(value), do: value
  defp chain_id_string(_), do: nil

  defp check_digest_match(%Challenge{digest: digest}, digest), do: :ok
  defp check_digest_match(_challenge, _expected), do: {:error, :digest_mismatch}

  defp check_opaque_match(%Challenge{opaque: opaque}, opaque), do: :ok
  defp check_opaque_match(_challenge, _expected), do: {:error, :opaque_mismatch}

  defp decode_credential_request(%Challenge{request: request}) do
    with {:ok, json} <- Base.url_decode64(request, padding: false),
         {:ok, map} <- Jason.decode(json),
         true <- is_map(map) do
      {:ok, map}
    else
      _ -> {:error, :request_mismatch}
    end
  end

  defp merge_method_config(charge, runtime_config) do
    merged = Map.merge(charge.method_details || %{}, runtime_config)
    %{charge | method_details: merged}
  end

  defp require_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "MPP.Verifier.verify/2 requires the :#{key} option"
    end
  end
end
