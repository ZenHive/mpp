defmodule MPP.Headers do
  @moduledoc """
  Parse and format the three MPP protocol headers.

  ## Headers

    * `WWW-Authenticate: Payment` — challenge header using RFC 9110 auth-param syntax
    * `Authorization: Payment` — credential header (scheme + base64url JSON blob)
    * `Payment-Receipt` — receipt header (bare base64url JSON blob)

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

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Receipt

  @payment_scheme "Payment"

  @required_params ~w(id realm method intent request)
  @optional_params ~w(expires digest description opaque)
  @all_params @required_params ++ @optional_params

  # --- Challenge (WWW-Authenticate: Payment) ---

  @doc """
  Formats a challenge as a `WWW-Authenticate: Payment` header value.

  Produces RFC 9110 auth-param syntax with quoted string values.
  Optional fields are omitted when nil.

  ## Examples

      challenge = MPP.Challenge.create(
        [realm: "api.example.com", method: "stripe", intent: "charge", request: "eyJhbW91bnQiOiIxMDAifQ"],
        "secret"
      )
      MPP.Headers.format_challenge(challenge)
      ~s(Payment id="...", realm="api.example.com", method="stripe", intent="charge", request="eyJhbW91bnQiOiIxMDAifQ")
  """
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

  @doc """
  Parses a `WWW-Authenticate: Payment` header value into a challenge struct.

  Handles case-insensitive scheme matching, quoted string values with
  escape sequences, and validates that all required params are present.

  Returns `{:error, :invalid_scheme}` if the scheme is not "Payment",
  `{:error, :missing_required_params}` if required auth-params are missing,
  `{:error, :duplicate_param}` if a param appears more than once,
  or `{:error, :invalid_auth_params}` for malformed syntax.

  ## Examples

      {:ok, challenge} = MPP.Headers.parse_challenge(~s(Payment id="abc", realm="api.example.com", method="stripe", intent="charge", request="eyJ..."))
      challenge.realm
      "api.example.com"
  """
  @spec parse_challenge(String.t()) :: {:ok, Challenge.t()} | {:error, atom()}
  def parse_challenge(header) when is_binary(header) do
    with {:ok, rest} <- strip_scheme(header),
         {:ok, params} <- parse_auth_params(rest),
         :ok <- validate_required_params(params) do
      {:ok, params_to_challenge(params)}
    end
  end

  # --- Credential (Authorization: Payment) ---

  @doc """
  Formats a credential as an `Authorization: Payment` header value.

  Encodes the credential as base64url JSON and prepends the Payment scheme.

  ## Examples

      header = MPP.Headers.format_credential(credential)
      String.starts_with?(header, "Payment ")
      true
  """
  @spec format_credential(Credential.t()) :: String.t()
  def format_credential(%Credential{} = credential) do
    "#{@payment_scheme} #{Credential.encode(credential)}"
  end

  @doc """
  Parses an `Authorization: Payment` header value into a credential struct.

  Strips the case-insensitive "Payment " scheme prefix and delegates
  to `MPP.Credential.decode/1`.

  ## Examples

      {:ok, credential} = MPP.Headers.parse_credential("Payment eyJjaGFsbGVuZ2...")
      credential.payload
      %{"spt" => "spt_abc123"}
  """
  @spec parse_credential(String.t()) :: {:ok, Credential.t()} | {:error, atom()}
  def parse_credential(header) when is_binary(header) do
    with {:ok, rest} <- strip_scheme(header) do
      Credential.decode(String.trim(rest))
    end
  end

  # --- Receipt (Payment-Receipt) ---

  @doc """
  Formats a receipt as a `Payment-Receipt` header value.

  Returns bare base64url-encoded JSON (no scheme prefix).

  ## Examples

      header = MPP.Headers.format_receipt(receipt)
      {:ok, _} = Base.url_decode64(header, padding: false)
  """
  @spec format_receipt(Receipt.t()) :: String.t()
  def format_receipt(%Receipt{} = receipt) do
    Receipt.encode(receipt)
  end

  @doc """
  Parses a `Payment-Receipt` header value into a receipt struct.

  The header value is bare base64url-encoded JSON (no scheme prefix).

  ## Examples

      {:ok, receipt} = MPP.Headers.parse_receipt(header_value)
      receipt.status
      "success"
  """
  @spec parse_receipt(String.t()) :: {:ok, Receipt.t()} | {:error, atom()}
  def parse_receipt(header) when is_binary(header) do
    Receipt.decode(String.trim(header))
  end

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
  defp escape_quoted(value) do
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

  # Extracts the parameter key up to the "=" sign.
  defp parse_key(input) do
    case String.split(input, "=", parts: 2) do
      [key, rest] ->
        key = String.trim(key)

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
