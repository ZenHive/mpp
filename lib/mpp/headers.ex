defmodule MPP.Headers do
  @moduledoc """
  Parse and format the three MPP protocol wire-format headers.

  ## Headers

    * `WWW-Authenticate: Payment` — challenge header using RFC 9110 auth-param syntax
    * `Authorization: Payment` — credential header (scheme + base64url JSON blob)
    * `Payment-Receipt` — receipt header (bare base64url JSON blob)

  The `Accept-Payment` client-preference header lives in `MPP.AcceptPayment`.

  ## Usage

      # Server: format a 402 challenge response header
      header_value = MPP.Headers.format_challenge(challenge)
      # → ~s(Payment id="x7Tg...", realm="api.example.com", method="stripe", ...)

      # Client: parse a 402 challenge from response
      {:ok, challenge} = MPP.Headers.parse_challenge(header_value)

      # Client: format credential for request
      header_value = MPP.Headers.format_credential(credential)
      # → "Payment eyJjaGFsbGVuZ2..."

      # Server: parse credential from request
      {:ok, credential} = MPP.Headers.parse_credential(header_value)

      # Server: format receipt for response
      header_value = MPP.Headers.format_receipt(receipt)

      # Client: parse receipt from response
      {:ok, receipt} = MPP.Headers.parse_receipt(header_value)
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Headers.SchemeSplitter
  alias MPP.Receipt

  @payment_scheme "Payment"

  @required_params ~w(id realm method intent request)
  @optional_params ~w(expires digest description opaque)
  @all_params @required_params ++ @optional_params

  # 16 KiB cap on client-supplied header tokens, enforced BEFORE any base64url
  # decode to prevent a memory-exhaustion DoS (an oversized token would force
  # unbounded allocation in Base.url_decode64 + Jason.decode). Ported from the
  # mpp-rs #299 security fix. Matches mpp-rs MAX_TOKEN_LEN
  # (refs/mpp-rs/src/protocol/core/headers.rs:18) and mppx maxRequestParameterLength
  # (refs/mppx/src/Challenge.ts:10) — both `16 * 1024`. At-limit input still parses;
  # only over-limit is rejected.
  @max_token_len 16 * 1024

  # --- Challenge (WWW-Authenticate: Payment) ---

  api(
    :format_challenge,
    "Format a challenge as a `WWW-Authenticate: Payment` header value with RFC 9110 auth-param syntax.",
    params: [
      challenge: [kind: :value, description: "Challenge struct to format"]
    ],
    returns: %{type: :string, description: "Header value string with quoted auth-params"},
    composes_with: [:parse_challenge]
  )

  @spec format_challenge(Challenge.t()) :: String.t()
  def format_challenge(%Challenge{} = challenge) do
    params =
      Enum.reject(
        [
          {"id", challenge.id},
          {"realm", challenge.realm},
          {"method", challenge.method},
          {"intent", challenge.intent},
          {"request", challenge.request},
          {"expires", challenge.expires},
          {"digest", challenge.digest},
          {"description", challenge.description},
          {"opaque", challenge.opaque}
        ],
        fn {_k, v} -> is_nil(v) end
      )

    formatted =
      Enum.map_join(params, ", ", fn {key, value} -> ~s(#{key}="#{escape_quoted(value)}") end)

    "#{@payment_scheme} #{formatted}"
  end

  api(:parse_challenge, "Parse a `WWW-Authenticate: Payment` header value into a challenge struct.",
    params: [
      header: [kind: :value, description: "Raw WWW-Authenticate header value string"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, challenge}` on success, `{:error, reason}` on failure"},
    errors: [
      :invalid_scheme,
      :missing_required_params,
      :duplicate_param,
      :invalid_auth_params,
      :request_too_large,
      :empty_id,
      :invalid_method,
      :invalid_request,
      :invalid_digest,
      :invalid_expires
    ],
    composes_with: [:format_challenge]
  )

  @spec parse_challenge(String.t()) :: {:ok, Challenge.t()} | {:error, atom()}
  def parse_challenge(header) when is_binary(header) do
    with {:ok, rest} <- strip_scheme(header),
         {:ok, params} <- parse_auth_params(rest),
         :ok <- check_request_size(params),
         :ok <- validate_required_params(params),
         challenge = params_to_challenge(params),
         :ok <- Challenge.validate_fields(challenge) do
      {:ok, challenge}
    end
  end

  api(
    :parse_challenges,
    "Parse a `WWW-Authenticate` header containing one or more `Payment` challenges. Splits on scheme boundaries, skips non-Payment schemes. Partial failures are tolerated: if some challenges parse and others fail, only the successful ones are returned (matching mppx `deserializeList` semantics).",
    params: [
      header: [kind: :value, description: "Raw WWW-Authenticate header value, possibly containing multiple challenges"]
    ],
    returns: %{
      type: :tagged_tuple,
      description:
        "`{:ok, [challenge]}` on success, `{:error, reason}` if no Payment challenges found or all fail to parse"
    },
    errors: [
      :no_payment_challenges,
      :invalid_scheme,
      :missing_required_params,
      :duplicate_param,
      :invalid_auth_params,
      :request_too_large,
      :empty_id,
      :invalid_method,
      :invalid_request,
      :invalid_digest,
      :invalid_expires
    ],
    composes_with: [:parse_challenge, :format_challenge]
  )

  @spec parse_challenges(String.t()) :: {:ok, [Challenge.t()]} | {:error, atom()}
  def parse_challenges(header) when is_binary(header) do
    segments = SchemeSplitter.split(header)

    case segments do
      [] ->
        {:error, :no_payment_challenges}

      segments ->
        # Partial failures are intentional: a multi-challenge header may contain
        # challenges for methods the client doesn't support or that have malformed
        # optional fields. We return all successfully parsed challenges and only
        # error if every segment fails. This matches mppx deserializeList behavior.
        results = Enum.map(segments, &parse_challenge/1)
        challenges = for {:ok, c} <- results, do: c

        if challenges == [] do
          # All segments failed — return the first error for diagnostics
          Enum.find(results, &match?({:error, _}, &1))
        else
          {:ok, challenges}
        end
    end
  end

  # --- Credential (Authorization: Payment) ---

  api(:format_credential, "Format a credential as an `Authorization: Payment` header value.",
    params: [
      credential: [kind: :value, description: "Credential struct to format"]
    ],
    returns: %{type: :string, description: "Header value with Payment scheme prefix and base64url JSON blob"},
    composes_with: [:parse_credential]
  )

  @spec format_credential(Credential.t()) :: String.t()
  def format_credential(%Credential{} = credential) do
    "#{@payment_scheme} #{Credential.encode(credential)}"
  end

  api(:parse_credential, "Parse an `Authorization: Payment` header value into a credential struct.",
    params: [
      header: [kind: :value, description: "Raw Authorization header value string"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, credential}` on success, `{:error, reason}` on failure"},
    errors: [:invalid_scheme, :invalid_base64, :invalid_json, :missing_required_fields, :token_too_large],
    composes_with: [:format_credential]
  )

  @spec parse_credential(String.t()) :: {:ok, Credential.t()} | {:error, atom()}
  def parse_credential(header) when is_binary(header) do
    with {:ok, rest} <- strip_scheme(header),
         token = String.trim(rest),
         :ok <- check_token_size(token) do
      Credential.decode(token)
    end
  end

  # --- Receipt (Payment-Receipt) ---

  api(:format_receipt, "Format a receipt as a `Payment-Receipt` header value (bare base64url JSON, no scheme prefix).",
    params: [
      receipt: [kind: :value, description: "Receipt struct to format"]
    ],
    returns: %{type: :string, description: "Base64url-encoded JSON string"},
    composes_with: [:parse_receipt]
  )

  @spec format_receipt(Receipt.t()) :: String.t()
  def format_receipt(%Receipt{} = receipt) do
    Receipt.encode(receipt)
  end

  api(:parse_receipt, "Parse a `Payment-Receipt` header value into a receipt struct.",
    params: [
      header: [kind: :value, description: "Raw Payment-Receipt header value (bare base64url JSON)"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, reason}` on failure"},
    errors: [:invalid_base64, :invalid_json, :missing_required_fields, :invalid_field_type, :token_too_large],
    composes_with: [:format_receipt]
  )

  @spec parse_receipt(String.t()) :: {:ok, Receipt.t()} | {:error, atom()}
  def parse_receipt(header) when is_binary(header) do
    token = String.trim(header)

    with :ok <- check_token_size(token) do
      Receipt.decode(token)
    end
  end

  # --- Private: token-size DoS guards (mpp-rs #299) ---

  # Rejects a base64url credential/receipt token that exceeds @max_token_len
  # BEFORE it reaches Base.url_decode64 + Jason.decode. At-limit passes.
  @spec check_token_size(binary()) :: :ok | {:error, :token_too_large}
  defp check_token_size(token) when byte_size(token) > @max_token_len, do: {:error, :token_too_large}
  defp check_token_size(_token), do: :ok

  # Rejects an oversized WWW-Authenticate `request` auth-param before the
  # challenge is built (the request payload is base64url/JCS-decoded downstream
  # during verification). Other params are small by construction.
  #
  # Boundary: `>` (at-limit passes, over-limit rejected). This matches mpp-rs's
  # quoted-value path (`refs/mpp-rs/src/protocol/core/headers.rs:161`): its `>=`
  # is tested against the running accumulator *before* the current byte is pushed,
  # so it only fires on the (MAX+1)th content byte — a net `> MAX_TOKEN_LEN`,
  # identical to this guard and to mppx `request.length > maxRequestParameterLength`
  # (`refs/mppx/src/Challenge.ts:352`). All three accept exactly 16 KiB, reject 16 KiB + 1.
  @spec check_request_size(%{optional(String.t()) => String.t()}) :: :ok | {:error, :request_too_large}
  defp check_request_size(%{"request" => request}) when byte_size(request) > @max_token_len,
    do: {:error, :request_too_large}

  defp check_request_size(_params), do: :ok

  # --- Private: Scheme handling ---

  # Strips the "Payment" scheme prefix (case-insensitive), returning the rest.
  defp strip_scheme(header) do
    trimmed = String.trim_leading(header)

    case String.split(trimmed, ~r/\s+/, parts: 2) do
      [scheme, rest] ->
        if String.downcase(scheme) == "payment" do
          {:ok, rest}
        else
          {:error, :invalid_scheme}
        end

      _ ->
        {:error, :invalid_scheme}
    end
  end

  # --- Private: Auth-param formatting ---

  # Escapes a value for use inside a quoted-string (RFC 9110 Section 5.6.4).
  # Rejects CR/LF which would produce invalid header text or break HMAC binding.
  defp escape_quoted(value) do
    if String.contains?(value, ["\r", "\n"]) do
      raise ArgumentError,
            "MPP challenge field contains CR/LF which is invalid in HTTP headers: #{inspect(value)}"
    end

    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # --- Private: Auth-param parsing ---

  # Parses comma-separated auth-params into a map.
  # Handles both quoted ("value") and unquoted (token) values.
  defp parse_auth_params(input) do
    input
    |> String.trim()
    |> do_parse_params(%{})
  end

  # Base case: empty input, parsing complete.
  defp do_parse_params("", acc), do: {:ok, acc}

  # Recursive parser: extract key=value pairs.
  defp do_parse_params(input, acc) do
    input = skip_separators(input)

    if input == "" do
      {:ok, acc}
    else
      with {:ok, key, rest} <- parse_key(input),
           :ok <- validate_param_name(key),
           :ok <- check_duplicate(acc, key),
           {:ok, value, rest} <- parse_value(rest) do
        do_parse_params(rest, Map.put(acc, key, value))
      end
    end
  end

  # Skips commas and optional whitespace between params.
  defp skip_separators(input) do
    input
    |> String.trim_leading()
    |> String.trim_leading(",")
    |> String.trim_leading()
  end

  # Extracts the parameter key up to the "=" sign. Names are lowercased so
  # `ID=` / `Id=` map to `"id"` and `id=` + `ID=` collide as `:duplicate_param`.
  #
  # Authority: RFC 9110 §11.2 ("the name token is matched case-insensitively").
  # mppx lowercases at parse (`refs/mppx/src/Challenge.ts:388`); mpp-rs keeps the
  # raw token (`refs/mpp-rs/src/protocol/core/headers.rs:150`) — the RFC breaks
  # that disagreement toward case-insensitivity (mppx #788).
  defp parse_key(input) do
    case String.split(input, "=", parts: 2) do
      [key, rest] ->
        key = key |> String.trim() |> String.downcase(:ascii)

        if key == "" do
          {:error, :invalid_auth_params}
        else
          {:ok, key, rest}
        end

      _ ->
        {:error, :invalid_auth_params}
    end
  end

  # Rejects unknown auth-params for security. If the spec adds new optional
  # params, add them to @all_params. Prefer strict rejection over silent ignore.
  defp validate_param_name(key) do
    if key in @all_params do
      :ok
    else
      {:error, :invalid_auth_params}
    end
  end

  # Checks for duplicate parameters.
  defp check_duplicate(acc, key) do
    if Map.has_key?(acc, key) do
      {:error, :duplicate_param}
    else
      :ok
    end
  end

  # Parses a value — either a quoted string or an unquoted token.
  defp parse_value("\"" <> rest), do: parse_quoted_string(rest, [])

  defp parse_value(input) do
    {token, rest} = take_token(input)

    if token == "" do
      {:error, :invalid_auth_params}
    else
      {:ok, token, rest}
    end
  end

  # State machine for parsing a quoted string with escape handling.
  # Rejects CRLF to prevent header injection.
  defp parse_quoted_string("", _acc), do: {:error, :invalid_auth_params}

  defp parse_quoted_string("\"" <> rest, acc) do
    value = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, value, rest}
  end

  defp parse_quoted_string("\\\\" <> rest, acc), do: parse_quoted_string(rest, ["\\" | acc])
  defp parse_quoted_string("\\\"" <> rest, acc), do: parse_quoted_string(rest, ["\"" | acc])
  defp parse_quoted_string("\\" <> <<char, rest::binary>>, acc), do: parse_quoted_string(rest, [<<char>> | acc])
  defp parse_quoted_string("\r" <> _rest, _acc), do: {:error, :invalid_auth_params}
  defp parse_quoted_string("\n" <> _rest, _acc), do: {:error, :invalid_auth_params}

  defp parse_quoted_string(<<char, rest::binary>>, acc) do
    parse_quoted_string(rest, [<<char>> | acc])
  end

  # Takes characters until a comma, whitespace, or end of input (unquoted token).
  defp take_token(input), do: take_token(input, [])
  defp take_token("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  defp take_token("," <> _ = rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp take_token(" " <> _ = rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp take_token("\t" <> _ = rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_token(<<char, rest::binary>>, acc) do
    take_token(rest, [<<char>> | acc])
  end

  # Validates that all required auth-params are present.
  defp validate_required_params(params) do
    missing = Enum.reject(@required_params, &Map.has_key?(params, &1))

    if Enum.empty?(missing) do
      :ok
    else
      {:error, :missing_required_params}
    end
  end

  # Builds a Challenge struct from parsed auth-params.
  defp params_to_challenge(params) do
    %Challenge{
      id: params["id"],
      realm: params["realm"],
      method: params["method"],
      intent: params["intent"],
      request: params["request"],
      expires: params["expires"],
      digest: params["digest"],
      description: params["description"],
      opaque: params["opaque"]
    }
  end
end
