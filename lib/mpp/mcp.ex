defmodule MPP.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) payment transport helpers.

  Provides constants and helper functions for embedding MPP payment flows
  in JSON-RPC messages. Where `MPP.Plug` handles HTTP 402 challenges via
  headers, this module handles the equivalent over MCP's `_meta` convention.

  ## Constants

  Five constants defined by the MPP transport spec for MCP:

    * `payment_required_code/0` — JSON-RPC error code `-32042`
    * `verification_failed_code/0` — JSON-RPC error code `-32043`
    * `credential_meta_key/0` — `"org.paymentauth/credential"`
    * `payment_required_meta_key/0` — `"org.paymentauth/payment-required"`
    * `receipt_meta_key/0` — `"org.paymentauth/receipt"`

  ## Server Transport Adapter

  A full server-side transport: run JSON-RPC requests through payment
  verification (including the default credential replay dedup shared with
  `MPP.Plug`) before invoking your handler:

    * `init/1` — build transport config from the same options as `MPP.Plug`
    * `call/3` — verify the request's credential, invoke the handler, attach
      the receipt (or return a `-32042`/`-32602`/`-32043` error with challenges)

  ## Server Helpers

  Build JSON-RPC error responses and extract/attach payment data:

    * `extract_credential/1` — pull credential from `params._meta`
    * `payment_required_error/1` — build `-32042` error with challenges
    * `verification_failed_error/2` — build `-32043` error with problem details
    * `attach_receipt/3` — add receipt + challengeId to `result._meta`

  ## Client Helpers

  Detect payment-required errors and manage credentials:

    * `payment_required?/1` — check if error is `-32042`
    * `extract_challenges/1` — parse challenges from error data
    * `attach_credential/2` — insert credential into `params._meta`
  """

  use Descripex, namespace: "/mcp"

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.JCS
  alias MPP.Plug.Config
  alias MPP.Receipt
  alias MPP.Replay
  alias MPP.Telemetry
  alias MPP.Verifier

  # JSON-RPC error code: payment required (no credential provided)
  @payment_required_code -32_042

  # JSON-RPC error code: credential verification failed
  @verification_failed_code -32_043

  # JSON-RPC error code: invalid params (malformed MCP credential)
  @invalid_params_code -32_602

  # Metadata key for credentials in params._meta
  @credential_meta_key "org.paymentauth/credential"

  # Metadata key for payment-required data in result._meta
  @payment_required_meta_key "org.paymentauth/payment-required"

  # Metadata key for receipts in result._meta
  @receipt_meta_key "org.paymentauth/receipt"

  # -------------------------------------------------------------------
  # Constants
  # -------------------------------------------------------------------

  api(:payment_required_code, "JSON-RPC error code for payment required (`-32042`).",
    returns: %{type: :integer, description: "Error code `-32042`"}
  )

  @spec payment_required_code :: integer()
  def payment_required_code, do: @payment_required_code

  api(:verification_failed_code, "JSON-RPC error code for verification failed (`-32043`).",
    returns: %{type: :integer, description: "Error code `-32043`"}
  )

  @spec verification_failed_code :: integer()
  def verification_failed_code, do: @verification_failed_code

  api(:credential_meta_key, "Metadata key for credentials in `params._meta`.",
    returns: %{type: :string, description: ~s(Key `"org.paymentauth/credential"`)}
  )

  @spec credential_meta_key :: String.t()
  def credential_meta_key, do: @credential_meta_key

  api(:payment_required_meta_key, "Metadata key for payment-required results in `result._meta`.",
    returns: %{type: :string, description: ~s(Key `"org.paymentauth/payment-required"`)}
  )

  @spec payment_required_meta_key :: String.t()
  def payment_required_meta_key, do: @payment_required_meta_key

  api(:receipt_meta_key, "Metadata key for receipts in `result._meta`.",
    returns: %{type: :string, description: ~s(Key `"org.paymentauth/receipt"`)}
  )

  @spec receipt_meta_key :: String.t()
  def receipt_meta_key, do: @receipt_meta_key

  # -------------------------------------------------------------------
  # Server Helpers
  # -------------------------------------------------------------------

  api(
    :init,
    "Build server-side MCP transport configuration from the same endpoint options accepted by `MPP.Plug`.",
    params: [
      opts: [
        kind: :value,
        description: "Keyword options including :secret_key, :realm, and one or more payment methods"
      ]
    ],
    returns: %{type: :struct, description: "`MPP.Plug.Config` reused by the MCP server adapter"},
    composes_with: [:call]
  )

  @spec init(keyword()) :: Config.t()
  def init(opts) when is_list(opts), do: MPP.Plug.init(opts)

  api(
    :call,
    "Run a JSON-RPC request through MPP server-side payment verification before invoking a handler.",
    params: [
      request: [kind: :value, description: "JSON-RPC request map with params._meta payment credential"],
      config: [kind: :value, description: "MCP transport config from init/1"],
      handler: [
        kind: :value,
        description: "Function receiving the request after verification and returning a JSON-RPC response or result map"
      ]
    ],
    returns: %{
      type: :map,
      description: "JSON-RPC response with payment-required/verification error, or successful result._meta receipt"
    },
    composes_with: [:extract_credential, :payment_required_error, :attach_receipt]
  )

  @spec call(map(), Config.t(), (map() -> map() | {:ok, map()} | {:error, map()})) :: map()
  def call(%{} = request, %Config{} = config, handler) when is_function(handler, 1) do
    case authorize_request(request, config) do
      {:ok, receipt, challenge_id} ->
        request
        |> handler.()
        |> normalize_handler_response(request)
        |> attach_response_receipt(receipt, challenge_id)

      {:error, response} ->
        response
    end
  end

  api(
    :extract_credential,
    "Extract a payment credential from JSON-RPC request params `_meta`.",
    params: [
      params: [
        kind: :value,
        description: "JSON-RPC request params map with optional `_meta` containing a credential"
      ]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, credential}` or `{:error, :no_credential | :invalid_credential | :invalid_challenge}`"
    },
    errors: [:no_credential, :invalid_credential, :invalid_challenge],
    composes_with: [:attach_credential, :attach_receipt]
  )

  @spec extract_credential(map()) ::
          {:ok, Credential.t()} | {:error, :no_credential | :invalid_credential | :invalid_challenge}
  def extract_credential(%{"_meta" => %{@credential_meta_key => cred_map}}) when is_map(cred_map) do
    credential_from_map(cred_map)
  end

  @spec extract_credential(map()) :: {:error, :invalid_credential}
  def extract_credential(%{"_meta" => %{@credential_meta_key => _}}), do: {:error, :invalid_credential}

  @spec extract_credential(map()) :: {:error, :no_credential}
  def extract_credential(%{}), do: {:error, :no_credential}

  api(
    :payment_required_error,
    "Build a JSON-RPC error map for payment required (`-32042`) with one or more challenges.",
    params: [
      challenges: [
        kind: :value,
        description: "A single `MPP.Challenge` struct or a list of challenges"
      ]
    ],
    returns: %{
      type: :map,
      description:
        "JSON-RPC error map with `code`, `message`, and `data` containing `httpStatus`, `challenges`, and `problem`"
    },
    composes_with: [:extract_challenges, :verification_failed_error]
  )

  @spec payment_required_error(Challenge.t() | [Challenge.t()]) :: map()
  def payment_required_error(%Challenge{} = challenge) do
    payment_required_error([challenge])
  end

  @spec payment_required_error([Challenge.t()]) :: map()
  def payment_required_error(challenges) when is_list(challenges) do
    %{
      "code" => @payment_required_code,
      "message" => "Payment Required",
      "data" => %{
        "httpStatus" => 402,
        "challenges" => Enum.map(challenges, &challenge_to_map/1),
        "problem" => nil
      }
    }
  end

  api(
    :verification_failed_error,
    "Build a JSON-RPC error map for verification failed (`-32043`) with problem details.",
    params: [
      challenges: [
        kind: :value,
        description: "A single `MPP.Challenge` struct or a list of challenges"
      ],
      problem: [
        kind: :value,
        description: "An `MPP.Errors.t()` struct with RFC 9457 problem details"
      ]
    ],
    returns: %{
      type: :map,
      description: "JSON-RPC error map with `code`, `message`, and `data` including problem details"
    },
    composes_with: [:payment_required_error, :extract_challenges]
  )

  @spec verification_failed_error(Challenge.t() | [Challenge.t()], Errors.t()) :: map()
  def verification_failed_error(%Challenge{} = challenge, %Errors{} = problem) do
    verification_failed_error([challenge], problem)
  end

  @spec verification_failed_error([Challenge.t()], Errors.t()) :: map()
  def verification_failed_error(challenges, %Errors{} = problem) when is_list(challenges) do
    %{
      "code" => @verification_failed_code,
      "message" => "Payment Verification Failed",
      "data" => %{
        "httpStatus" => problem.status,
        "challenges" => Enum.map(challenges, &challenge_to_map/1),
        "problem" => Errors.to_map(problem)
      }
    }
  end

  api(
    :attach_receipt,
    "Attach a payment receipt to a JSON-RPC result map via `_meta`.",
    params: [
      result: [kind: :value, description: "JSON-RPC result map"],
      receipt: [kind: :value, description: "An `MPP.Receipt.t()` struct"],
      challenge_id: [kind: :value, description: "The challenge ID this receipt fulfills"]
    ],
    returns: %{
      type: :map,
      description: "Result map with `_meta` containing the receipt and `challengeId`"
    },
    composes_with: [:extract_credential, :payment_required_error]
  )

  @spec attach_receipt(map(), Receipt.t(), String.t()) :: map()
  def attach_receipt(result, %Receipt{} = receipt, challenge_id) when is_map(result) and is_binary(challenge_id) do
    mcp_receipt = receipt_to_mcp_map(receipt, challenge_id)
    existing_meta = Map.get(result, "_meta", %{})
    Map.put(result, "_meta", Map.put(existing_meta, @receipt_meta_key, mcp_receipt))
  end

  # -------------------------------------------------------------------
  # Client Helpers
  # -------------------------------------------------------------------

  api(
    :payment_required?,
    "Check whether a JSON-RPC error map (or full JSON-RPC response) indicates payment is required.",
    params: [
      error: [kind: :value, description: "JSON-RPC error map with `code` field, or a full response envelope"]
    ],
    returns: %{type: :boolean, description: "`true` if error code is `-32042`"}
  )

  @spec payment_required?(map()) :: boolean()
  def payment_required?(%{"code" => @payment_required_code}), do: true

  # Full JSON-RPC envelopes unwrap to their error/result member, so a response
  # from `call/3` can be fed back in directly (mppx's `paymentRequiredData`
  # accepts the full message the same way).
  @spec payment_required?(map()) :: boolean()
  def payment_required?(%{"error" => error}) when is_map(error), do: payment_required?(error)

  @spec payment_required?(map()) :: boolean()
  def payment_required?(%{"result" => result}) when is_map(result), do: payment_required?(result)

  @spec payment_required?(map()) :: boolean()
  def payment_required?(%{"_meta" => %{@payment_required_meta_key => data}}) when is_map(data) do
    match?({:ok, [_ | _]}, extract_challenges_from_data(data))
  end

  @spec payment_required?(map()) :: false
  def payment_required?(%{}), do: false

  api(
    :extract_challenges,
    "Extract and parse payment challenges from a JSON-RPC error map or full JSON-RPC response.",
    params: [
      error: [kind: :value, description: "JSON-RPC error map with `data.challenges`, or a full response envelope"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, [challenge]}` or `{:error, :no_challenges | :invalid_challenge}`"
    },
    errors: [:no_challenges, :invalid_challenge],
    composes_with: [:payment_required?, :payment_required_error]
  )

  @spec extract_challenges(map()) :: {:ok, [Challenge.t()]} | {:error, :no_challenges | :invalid_challenge}
  def extract_challenges(%{"data" => %{"challenges" => challenges}}) when is_list(challenges) and challenges != [] do
    extract_challenges_from_list(challenges)
  end

  @spec extract_challenges(map()) :: {:error, :no_challenges}
  def extract_challenges(%{"data" => %{"challenges" => []}}), do: {:error, :no_challenges}

  @spec extract_challenges(map()) :: {:error, :invalid_challenge}
  def extract_challenges(%{"data" => %{"challenges" => _}}), do: {:error, :invalid_challenge}

  @spec extract_challenges(map()) :: {:ok, [Challenge.t()]} | {:error, :no_challenges | :invalid_challenge}
  def extract_challenges(%{"error" => error}) when is_map(error), do: extract_challenges(error)

  @spec extract_challenges(map()) :: {:ok, [Challenge.t()]} | {:error, :no_challenges | :invalid_challenge}
  def extract_challenges(%{"result" => result}) when is_map(result), do: extract_challenges(result)

  @spec extract_challenges(map()) :: {:ok, [Challenge.t()]} | {:error, :no_challenges | :invalid_challenge}
  def extract_challenges(%{"_meta" => %{@payment_required_meta_key => data}}) when is_map(data) do
    extract_challenges_from_data(data)
  end

  @spec extract_challenges(map()) :: {:error, :no_challenges}
  def extract_challenges(%{}), do: {:error, :no_challenges}

  api(
    :attach_credential,
    "Attach a payment credential to JSON-RPC request params via `_meta`.",
    params: [
      params: [kind: :value, description: "JSON-RPC request params map"],
      credential: [kind: :value, description: "An `MPP.Credential.t()` struct"]
    ],
    returns: %{
      type: :map,
      description: "Params map with `_meta` containing the credential"
    },
    composes_with: [:extract_credential, :extract_challenges]
  )

  @spec attach_credential(map(), Credential.t()) :: map()
  def attach_credential(params, %Credential{} = credential) when is_map(params) do
    cred_map = credential_to_map(credential)
    existing_meta = Map.get(params, "_meta", %{})
    Map.put(params, "_meta", Map.put(existing_meta, @credential_meta_key, cred_map))
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp authorize_request(request, config) do
    # JSON-RPC params may legally be an array (or an explicit null) — treat any
    # non-map shape as carrying no credential, mirroring mppx's optional-chained
    # `request.params?._meta` (refs/mppx/src/server/Transport.ts `getCredential`).
    params =
      case Map.get(request, "params", %{}) do
        %{} = map -> map
        _other -> %{}
      end

    case extract_credential(params) do
      {:ok, credential} -> verify_mcp_credential(request, config, credential)
      {:error, :no_credential} -> missing_credential_response(request, config)
      {:error, reason} -> malformed_credential_response(request, config, reason)
    end
  end

  defp missing_credential_response(request, config) do
    error = Errors.new(:payment_required, "No payment credential provided")
    challenges = generate_challenges(config)

    {:error, error_response(request, @payment_required_code, "Payment Required", challenges, error)}
  end

  defp malformed_credential_response(request, config, reason) do
    error = Errors.new(:malformed_credential, "#{reason}")
    challenges = generate_challenges(config)

    {:error, error_response(request, @invalid_params_code, error.title, challenges, error)}
  end

  defp verify_mcp_credential(request, config, credential) do
    case find_method_entry(config, credential.challenge.method) do
      nil ->
        error = Errors.new(:method_unsupported, "Unknown payment method: #{credential.challenge.method}")
        challenges = generate_challenges(config)

        {:error, error_response(request, @verification_failed_code, error.title, challenges, error)}

      entry ->
        verify_with_entry(request, config, credential, entry)
    end
  end

  defp verify_with_entry(request, config, credential, entry) do
    store = Replay.store_for(config, entry)

    opts = [
      secret_key: config.secret_key,
      realm: config.realm,
      method: entry.method,
      charge: entry.charge,
      method_config: entry.method_config,
      digest: config.digest,
      opaque: config.opaque
    ]

    # Same default replay dedup MPP.Plug applies — check before verify, claim
    # after — so a verified MCP credential cannot be replayed across JSON-RPC
    # requests for store-backed methods. A replay rejection never reaches
    # Verifier.verify, so emit the same verify start/fail telemetry MPP.Plug
    # emits for that branch (lib/mpp/plug.ex verify_credential).
    case Replay.check_unused(store, credential) do
      {:error, %Errors{} = error} ->
        start_time = Telemetry.verify_start(credential, entry.charge, %{realm: config.realm})
        Telemetry.verify_fail(credential, entry.charge, start_time, error, %{realm: config.realm})
        {:error, error_response(request, mcp_error_code(error), error.title, generate_challenges(config), error)}

      :ok ->
        with {:ok, receipt} <- Verifier.verify(credential, opts),
             :ok <- Replay.mark_used(store, credential) do
          {:ok, receipt, credential.challenge.id}
        else
          {:error, %Errors{} = error} ->
            challenges = generate_challenges(config)
            {:error, error_response(request, mcp_error_code(error), error.title, challenges, error)}
        end
    end
  end

  defp find_method_entry(%Config{} = config, method_name) do
    Enum.find(config.method_entries, fn entry ->
      entry.method.method_name() == method_name
    end)
  end

  # Reuses `MPP.Plug`'s challenge generation so the MCP and HTTP transports emit
  # byte-identical challenges from the same config.
  defp generate_challenges(%Config{} = config) do
    Enum.map(config.method_entries, &MPP.Plug.generate_challenge(config, &1))
  end

  defp error_response(request, code, message, challenges, %Errors{} = error) do
    data = %{
      "httpStatus" => error.status,
      "challenges" => Enum.map(challenges, &challenge_to_map/1),
      "problem" => Errors.to_map(error)
    }

    data =
      case error.retry_after do
        seconds when is_integer(seconds) -> Map.put(data, "retryAfter", seconds)
        nil -> data
      end

    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id"),
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      }
    }
  end

  defp mcp_error_code(%Errors{type: "https://paymentauth.org/problems/payment-required"}), do: @payment_required_code

  defp mcp_error_code(%Errors{type: "https://zenhive.github.io/mpp/problems/sponsor-capacity-exhausted"}),
    do: @payment_required_code

  defp mcp_error_code(%Errors{type: "https://paymentauth.org/problems/malformed-credential"}), do: @invalid_params_code
  defp mcp_error_code(%Errors{}), do: @verification_failed_code

  defp normalize_handler_response({:ok, response}, request) when is_map(response),
    do: normalize_handler_response(response, request)

  defp normalize_handler_response({:error, response}, request) when is_map(response),
    do: normalize_handler_response(response, request)

  defp normalize_handler_response(%{"jsonrpc" => _, "result" => _} = response, _request), do: response
  defp normalize_handler_response(%{"jsonrpc" => _, "error" => _} = response, _request), do: response

  defp normalize_handler_response(%{"result" => _} = response, request) do
    response
    |> Map.put_new("jsonrpc", "2.0")
    |> Map.put_new("id", Map.get(request, "id"))
  end

  defp normalize_handler_response(%{"error" => _} = response, request) do
    response
    |> Map.put_new("jsonrpc", "2.0")
    |> Map.put_new("id", Map.get(request, "id"))
  end

  defp normalize_handler_response(result, request) when is_map(result) do
    %{"jsonrpc" => "2.0", "id" => Map.get(request, "id"), "result" => result}
  end

  defp attach_response_receipt(%{"error" => _} = response, _receipt, _challenge_id), do: response

  defp attach_response_receipt(%{"result" => result} = response, %Receipt{} = receipt, challenge_id) do
    Map.put(response, "result", attach_receipt(result, receipt, challenge_id))
  end

  # Converts a Challenge struct to a string-keyed map for MCP wire format.
  # Decodes `request` from base64url to a native JSON object per the MCP transport spec:
  # "Servers MUST NOT base64url-encode the request when using JSON-RPC transport."
  defp challenge_to_map(%Challenge{} = challenge) do
    %{
      "id" => challenge.id,
      "realm" => challenge.realm,
      "method" => challenge.method,
      "intent" => challenge.intent,
      "request" => decode_request(challenge.request)
    }
    |> maybe_put("description", challenge.description)
    |> maybe_put("digest", challenge.digest)
    |> maybe_put("expires", challenge.expires)
    |> maybe_put("opaque", challenge.opaque)
  end

  # Converts a string-keyed MCP challenge map to a Challenge struct.
  # Encodes `request` from native JSON object back to base64url for internal use.
  defp challenge_from_map(
         %{"id" => id, "realm" => realm, "method" => method, "intent" => intent, "request" => request} = map
       )
       when is_binary(id) and is_binary(realm) and is_binary(method) and is_binary(intent) do
    encoded = encode_request(request)

    with :ok <- if(encoded == :invalid, do: {:error, :invalid_challenge}, else: :ok),
         :ok <- validate_optional_strings(map) do
      challenge = %Challenge{
        id: id,
        realm: realm,
        method: method,
        intent: intent,
        request: encoded,
        description: Map.get(map, "description"),
        digest: Map.get(map, "digest"),
        expires: Map.get(map, "expires"),
        opaque: Map.get(map, "opaque")
      }

      # Parse-time field-shape rejection (Task 72). MCP's transport error
      # vocabulary is coarse (JSON-RPC-shaped), so a malformed field collapses to
      # the existing `:invalid_challenge` rather than surfacing the distinct atom
      # the header/credential parse paths return.
      case Challenge.validate_fields(challenge) do
        :ok -> {:ok, challenge}
        {:error, _reason} -> {:error, :invalid_challenge}
      end
    end
  end

  defp challenge_from_map(_), do: {:error, :invalid_challenge}

  # Validates that optional challenge fields, when present, are strings.
  # Rejects malformed values (e.g., "expires": %{}) that would crash HMAC verification.
  @optional_string_fields ~w(description digest expires opaque)
  defp validate_optional_strings(map) do
    Enum.find_value(@optional_string_fields, :ok, fn field ->
      case Map.get(map, field) do
        nil -> nil
        value when is_binary(value) -> nil
        _bad -> {:error, :invalid_challenge}
      end
    end)
  end

  # Converts a Credential struct to a string-keyed map for _meta embedding.
  defp credential_to_map(%Credential{} = credential) do
    map = %{
      "challenge" => challenge_to_map(credential.challenge),
      "payload" => credential.payload
    }

    maybe_put(map, "source", credential.source)
  end

  # Converts a string-keyed credential map from _meta into a Credential struct.
  defp credential_from_map(%{"challenge" => challenge_map, "payload" => payload} = map)
       when is_map(challenge_map) and is_map(payload) do
    with {:ok, challenge} <- challenge_from_map(challenge_map) do
      {:ok,
       %Credential{
         challenge: challenge,
         payload: payload,
         source: Map.get(map, "source")
       }}
    end
  end

  defp credential_from_map(_), do: {:error, :invalid_credential}

  defp extract_challenges_from_data(%{"challenges" => challenges}) when is_list(challenges) and challenges != [] do
    extract_challenges_from_list(challenges)
  end

  defp extract_challenges_from_data(%{"challenges" => []}), do: {:error, :no_challenges}
  defp extract_challenges_from_data(%{"challenges" => _}), do: {:error, :invalid_challenge}
  defp extract_challenges_from_data(%{}), do: {:error, :no_challenges}

  defp extract_challenges_from_list(challenges) do
    results = Enum.map(challenges, &challenge_from_map/1)

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, c} -> c end)}
      {_, [{:error, reason} | _]} -> {:error, reason}
    end
  end

  # Converts a Receipt struct + challenge_id to an MCP receipt map (adds challengeId).
  defp receipt_to_mcp_map(%Receipt{} = receipt, challenge_id) do
    core = %{
      "status" => receipt.status,
      "method" => receipt.method,
      "timestamp" => receipt.timestamp,
      "reference" => receipt.reference,
      "challengeId" => challenge_id
    }

    receipt.extensions
    |> Map.drop(["status", "method", "timestamp", "reference", "externalId", "subscriptionId", "challengeId"])
    |> Map.merge(core)
    |> maybe_put("externalId", receipt.external_id)
    |> maybe_put("subscriptionId", receipt.subscription_id)
  end

  # Decodes base64url-encoded request to a native JSON map for MCP wire format.
  # Challenge.request is always base64url-encoded JSON (enforced at creation).
  # Both decode failures indicate data corruption — raise instead of silently
  # passing a raw string where the MCP spec requires a JSON object.
  defp decode_request(request) when is_binary(request) do
    {:ok, json} = Base.url_decode64(request, padding: false)
    Jason.decode!(json)
  end

  # RFC 8785 JCS ensures cross-SDK HMAC interop (matching mppx/mpp-rs canonicalization).
  # Rejects maps containing floats — MPP amounts are strings in base units, floats are
  # a protocol violation. Returns :invalid (same as non-map/non-binary clause below).
  defp encode_request(request) when is_map(request) do
    if jcs_compatible?(request) do
      request |> JCS.canonicalize() |> Base.url_encode64(padding: false)
    else
      :invalid
    end
  end

  defp encode_request(request) when is_binary(request), do: request
  defp encode_request(_request), do: :invalid

  # Checks that a term contains only JCS-supported types (no floats).
  # Mirrors JCS.canonicalize/1 clause coverage: map, list, binary, integer, boolean, nil.
  # Keys must be strings: `JCS.canonicalize/1` raises on non-string map keys
  # (RFC 8785 contract), so a non-binary key must fail this pre-check and
  # surface as `:invalid` / `{:error, :invalid_challenge}` instead of raising.
  defp jcs_compatible?(term) when is_map(term), do: Enum.all?(term, fn {k, v} -> is_binary(k) and jcs_compatible?(v) end)
  defp jcs_compatible?(term) when is_list(term), do: Enum.all?(term, &jcs_compatible?/1)
  defp jcs_compatible?(term) when is_binary(term), do: true
  defp jcs_compatible?(term) when is_integer(term), do: true
  defp jcs_compatible?(term) when is_boolean(term), do: true
  defp jcs_compatible?(nil), do: true
  defp jcs_compatible?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
