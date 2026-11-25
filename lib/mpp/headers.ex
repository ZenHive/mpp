defmodule MPP.Headers do
  @moduledoc """
  Parse and format MPP challenge, credential, and receipt headers.

  ## Headers

    * `WWW-Authenticate: Payment` — challenge header using RFC 9110 auth-param syntax
    * `Authorization: Payment` — default credential header (scheme + base64url JSON blob)
    * `Payment-Authorization: Payment` — alternate credential header when the
      challenge advertises `header="Payment-Authorization"`
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
  alias MPP.Methods.Tempo.SessionReceipt
  alias MPP.Receipt

  @payment_scheme "Payment"

  @required_params ~w(id realm method intent request)
  @optional_params ~w(expires digest description header opaque)
  @all_params @required_params ++ @optional_params

  # Auth-params the challenge id binds or the credential echoes: everything
  # except the display-only `description` (mpp-rs `read_challenge_flagged`,
  # refs/mpp-rs/src/protocol/core/headers.rs; mppx `boundParams`,
  # refs/mppx/src/Challenge.ts, which leaves `id` out).
  @bound_params @all_params -- ["description"]

  # 16 KiB cap on client-supplied header tokens, enforced BEFORE any base64url
  # decode to prevent a memory-exhaustion DoS (an oversized token would force
  # unbounded allocation in Base.url_decode64 + Jason.decode). Ported from the
  # mpp-rs #299 security fix. Matches mpp-rs MAX_TOKEN_LEN
  # (refs/mpp-rs/src/protocol/core/headers.rs:18) and mppx maxRequestParameterLength
  # (refs/mppx/src/Challenge.ts:10) — both `16 * 1024`. At-limit input still parses;
  # only over-limit is rejected.
  # mpp-rs #669 dropped its receipt cap to match mppx; we keep it for receipts too.
  @max_token_len 16 * 1024

  # Limits on the credential field values scanned for Payment credentials
  # (mpp-rs MAX_AUTHORIZATION_LEN / MAX_AUTHORIZATION_VALUES /
  # MAX_SCANNED_AUTHORIZATION_LEN, refs/mpp-rs/src/protocol/core/headers.rs:29-37).
  @max_credential_value_len 64 * 1024
  @max_credential_values 32
  @max_scanned_credential_len 128 * 1024

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

  @doc """
  Format a challenge as a `WWW-Authenticate: Payment` header value.

  Raises `ArgumentError` when the method is not lowercase letters a-z, when a
  value holds CR or LF, when a value other than
  `description` holds a character outside HTAB and printable ASCII, or when the
  challenge was parsed from a header that carried a legacy backslash-u escape
  in such a value. `description` is display-only, so other characters are
  written there as backslash-u escapes; a receiver shows the escape text.
  """
  @spec format_challenge(Challenge.t()) :: String.t()
  def format_challenge(%Challenge{} = challenge) do
    Challenge.refuse_legacy!(challenge)

    if !Challenge.valid_method_name?(challenge.method) do
      raise ArgumentError,
            "MPP challenge method must be lowercase letters a-z: #{inspect(challenge.method)}"
    end

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
          {"header", Challenge.bound_header(challenge.header)},
          {"opaque", challenge.opaque}
        ],
        fn {_k, v} -> is_nil(v) end
      )

    formatted =
      Enum.map_join(params, ", ", fn {key, value} -> ~s(#{key}="#{quote_param(key, value)}") end)

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
      :invalid_intent,
      :invalid_opaque,
      :invalid_header,
      :invalid_request,
      :invalid_digest,
      :invalid_expires
    ],
    composes_with: [:format_challenge]
  )

  @spec parse_challenge(String.t()) :: {:ok, Challenge.t()} | {:error, atom()}
  def parse_challenge(header) when is_binary(header) do
    with {:ok, rest} <- strip_scheme(header),
         {:ok, all_params, legacy?} <- parse_auth_params(rest),
         # Unknown auth-params are ignored (core draft: "implementations MUST
         # ignore unknown parameters"; both SDKs keep the known fields).
         params = Map.take(all_params, @all_params),
         :ok <- check_request_size(params),
         :ok <- validate_required_params(params),
         :ok <- validate_explicit_header(params),
         challenge = %{params_to_challenge(params) | legacy_unicode_escape: legacy?},
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
      :invalid_intent,
      :invalid_opaque,
      :invalid_header,
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

  api(
    :select_payment_credential,
    "Find the one Payment credential a request carries, across every `Authorization` and `Payment-Authorization` field value. More than one is an error; a credential outside the selected field counts as absent.",
    params: [
      authorization: [kind: :value, description: "All `Authorization` field values of the request"],
      payment_authorization: [kind: :value, description: "All `Payment-Authorization` field values of the request"],
      selected: [kind: :value, description: "Field the challenge selects: `Authorization` or `Payment-Authorization`"]
    ],
    returns: %{
      type: :tagged_tuple,
      description:
        "`{:ok, \"Payment <token>\"}`, `{:ok, nil}` when the selected field carries none, or `{:error, reason}`"
    },
    errors: [:multiple_credentials, :too_many_credential_values],
    composes_with: [:parse_credential]
  )

  @doc """
  Find the one Payment credential a request carries.

  Counts `Payment <token>` credentials across every value of both credential
  fields, including comma-joined values; commas inside another scheme's quoted
  parameters do not separate credentials. More than one is
  `{:error, :multiple_credentials}`, which a server answers with 400 and no
  challenge. Otherwise the credential is returned when it is in the `selected`
  field, ready for `parse_credential/1`; a credential in the other field, or a
  bare `Payment` without a token, counts as absent.

  `Authorization` values are scanned before `Payment-Authorization` values,
  each in the order given, and the scan stops at the first error.
  A value longer than 64 KiB carries no credential. More than 32 values, or
  more than 128 KiB of values at or under that length, is
  `{:error, :too_many_credential_values}`
  (mpp-rs `select_payment_credential`, refs/mpp-rs/src/protocol/core/headers.rs;
  mppx `countPaymentCredentials`, refs/mppx/src/server/Transport.ts).
  """
  @spec select_payment_credential([String.t()], [String.t()], String.t()) ::
          {:ok, String.t() | nil} | {:error, :multiple_credentials | :too_many_credential_values}
  def select_payment_credential(authorization, payment_authorization, selected)
      when is_list(authorization) and is_list(payment_authorization) and is_binary(selected) do
    fields = Stream.concat(Stream.map(authorization, &{false, &1}), Stream.map(payment_authorization, &{true, &1}))

    case Enum.reduce_while(fields, {0, 0, nil}, &scan_credential_field/2) do
      {:error, _reason} = error ->
        error

      {_count, _scanned, {alternate?, credential}} ->
        if alternate? == (String.downcase(selected, :ascii) == "payment-authorization"),
          do: {:ok, credential},
          else: {:ok, nil}

      {_count, _scanned, nil} ->
        {:ok, nil}
    end
  end

  # One field value, in request order: the scan stops at the first decisive
  # condition, as mpp-rs does (refs/mpp-rs/src/protocol/core/headers.rs:138-165).
  defp scan_credential_field(_field, {count, _scanned, _found}) when count >= @max_credential_values,
    do: {:halt, {:error, :too_many_credential_values}}

  defp scan_credential_field({_alternate?, value}, {count, scanned, found})
       when byte_size(value) > @max_credential_value_len, do: {:cont, {count + 1, scanned, found}}

  defp scan_credential_field({_alternate?, value}, {_count, scanned, _found})
       when scanned + byte_size(value) > @max_scanned_credential_len, do: {:halt, {:error, :too_many_credential_values}}

  defp scan_credential_field({alternate?, value}, {count, scanned, found}) do
    case {found, payment_credentials(value, true, [])} do
      {found, []} -> {:cont, {count + 1, scanned + byte_size(value), found}}
      {nil, [credential]} -> {:cont, {count + 1, scanned + byte_size(value), {alternate?, credential}}}
      _several -> {:halt, {:error, :multiple_credentials}}
    end
  end

  # The `Payment <token>` credentials of one field value. An element whose
  # first word is the scheme runs to the next comma, since a token68 may end in
  # `=` (mpp-rs `Tokenizer::credentials`, refs/mpp-rs/src/protocol/core/auth_params.rs:112).
  # `Payment` followed by `=` is an auth-param of the scheme before it. Other
  # elements are skipped to their comma; an unterminated quoted parameter
  # value ends the scan of the value.
  defp payment_credentials(value, first?, acc) do
    case skip_list_separators(value) do
      <<>> -> Enum.reverse(acc)
      element -> list_element(element, split_word(element, <<>>), first?, acc)
    end
  end

  defp list_element(element, {word, rest}, first?, acc) do
    if payment_scheme?(word, rest, first?) do
      {text, tail} = split_at_comma(rest, <<>>)
      credential = String.replace(word <> text, ~r/[ \t]+\z/, "")
      acc = if byte_size(credential) > byte_size(word), do: [credential | acc], else: acc
      payment_credentials(tail, false, acc)
    else
      case skip_element(element) do
        {:ok, tail} -> payment_credentials(tail, false, acc)
        :error -> Enum.reverse(acc)
      end
    end
  end

  defp payment_scheme?(word, rest, first?) do
    String.downcase(word, :ascii) == "payment" and separator_next?(rest) and
      (first? or not String.starts_with?(skip_whitespace(rest), "="))
  end

  defp separator_next?(<<>>), do: true
  defp separator_next?(<<c, _rest::binary>>), do: c in [?\s, ?\t, ?,]

  defp skip_list_separators(<<c, rest::binary>>) when c in [?\s, ?\t, ?,], do: skip_list_separators(rest)
  defp skip_list_separators(rest), do: rest

  defp split_word(<<c, _rest::binary>> = rest, word) when c in [?\s, ?\t, ?,, ?=], do: {word, rest}
  defp split_word(<<c, rest::binary>>, word), do: split_word(rest, <<word::binary, c>>)
  defp split_word(<<>>, word), do: {word, <<>>}

  defp split_at_comma(<<",", rest::binary>>, text), do: {text, rest}
  defp split_at_comma(<<c, rest::binary>>, text), do: split_at_comma(rest, <<text::binary, c>>)
  defp split_at_comma(<<>>, text), do: {text, <<>>}

  # The rest of the value after the element's comma. Words and auth-params are
  # read as mpp-rs reads them: only a parameter value that starts with a quote
  # is a quoted string (refs/mpp-rs/src/protocol/core/auth_params.rs:131-135).
  defp skip_element(input) do
    case skip_whitespace(input) do
      <<>> -> {:ok, <<>>}
      <<",", rest::binary>> -> {:ok, rest}
      rest -> rest |> split_word(<<>>) |> skip_token()
    end
  end

  defp skip_token({_word, rest}) do
    case skip_whitespace(rest) do
      <<"=", value::binary>> -> value |> skip_whitespace() |> skip_param_value()
      rest -> skip_element(rest)
    end
  end

  defp skip_param_value(<<"\"", rest::binary>>), do: skip_quoted(rest)

  defp skip_param_value(value) do
    {_text, rest} = split_word(value, <<>>)
    # An `=` ends a word but belongs to an unquoted value such as a token68.
    rest |> skip_equals() |> skip_element()
  end

  defp skip_equals(<<"=", rest::binary>>), do: skip_equals(rest)
  defp skip_equals(rest), do: rest

  defp skip_quoted(<<>>), do: :error
  defp skip_quoted(<<"\\", _c, rest::binary>>), do: skip_quoted(rest)
  defp skip_quoted(<<"\"", rest::binary>>), do: skip_element(rest)
  defp skip_quoted(<<_c, rest::binary>>), do: skip_quoted(rest)

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
    with :ok <- check_credential_size(header),
         {:ok, rest} <- strip_scheme(header) do
      rest |> String.trim() |> Credential.decode()
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

  @spec format_receipt(Receipt.t() | SessionReceipt.t()) :: String.t()
  def format_receipt(%Receipt{} = receipt) do
    Receipt.encode(receipt)
  end

  def format_receipt(%SessionReceipt{} = receipt) do
    SessionReceipt.to_header(receipt)
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
  # A credential echoes its challenge, whose `request` alone may reach
  # @max_token_len, so the whole field value is bounded instead (mpp-rs
  # MAX_AUTHORIZATION_LEN, refs/mpp-rs/src/protocol/core/headers.rs:29,761;
  # mppx refs/mppx/src/Credential.ts).
  defp check_credential_size(header) when byte_size(header) > @max_credential_value_len, do: {:error, :token_too_large}
  defp check_credential_size(_header), do: :ok

  @spec check_token_size(binary()) :: :ok | {:error, :token_too_large}
  defp check_token_size(token) when byte_size(token) > @max_token_len, do: {:error, :token_too_large}
  defp check_token_size(_token), do: :ok

  # Rejects an oversized WWW-Authenticate `request` auth-param before the
  # challenge is built (the request payload is base64url/JCS-decoded downstream
  # during verification). Other params are small by construction.
  #
  # Boundary: `>` (at-limit passes, over-limit rejected). mppx uses
  # `request.length > maxRequestParameterLength` (`refs/mppx/src/Challenge.ts`).
  # mpp-rs's quoted-value accumulator compared with `>=` and rejected a `request`
  # of exactly 16 KiB — that check did not behave like `>`. mpp-rs #540 changed
  # it to `>` so quoted and unquoted values share this boundary. Our guard was
  # already `>`; that is the behavior all three share: accept exactly 16 KiB,
  # reject 16 KiB + 1.
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

  # Writes a value into a quoted-string (RFC 9110 §5.6.4). A quoted-pair escapes
  # one character, so only HTAB and printable ASCII round-trip; a receiver reads
  # `—` as the text `u2014`. A bound value holding anything else is refused
  # (mpp-rs `escape_quoted_value`, refs/mpp-rs/src/protocol/core/auth_params.rs;
  # mppx `authParam` refuses above U+00FF, refs/mppx/src/Challenge.ts — the
  # ASCII rule is what both accept). CR/LF are refused everywhere.
  defp quote_param(key, value) do
    if String.contains?(value, ["\r", "\n"]) do
      raise ArgumentError,
            "MPP challenge field contains CR/LF which is invalid in HTTP headers: #{inspect(value)}"
    end

    cond do
      key == "description" ->
        value |> String.to_charlist() |> Enum.map(&escape_codepoint/1) |> IO.iodata_to_binary()

      Challenge.header_text?(value) ->
        value |> :binary.bin_to_list() |> Enum.map(&escape_byte/1) |> IO.iodata_to_binary()

      true ->
        raise ArgumentError,
              "MPP challenge #{key} must be printable ASCII, since a challenge header " <>
                "cannot carry other characters: #{inspect(value)}"
    end
  end

  defp escape_byte(?\\), do: "\\\\"
  defp escape_byte(?"), do: "\\\""
  defp escape_byte(byte), do: <<byte>>

  # `description` only: every code point outside HTAB and 0x20-0x7E is written
  # as `\uXXXX` per UTF-16 code unit (lowercase hex, 4 digits), so a code point
  # outside the Basic Multilingual Plane becomes a surrogate pair (mppx
  # `authParam` with `escapeUnicode`; mpp-rs `escape_quoted_description`).
  defp escape_codepoint(?\\), do: "\\\\"
  defp escape_codepoint(?"), do: "\\\""
  defp escape_codepoint(0x09), do: "\t"
  defp escape_codepoint(codepoint) when codepoint in 0x20..0x7E, do: <<codepoint>>

  defp escape_codepoint(codepoint) when codepoint <= 0xFFFF do
    "\\u" <> (codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp escape_codepoint(codepoint) do
    adjusted = codepoint - 0x10000
    high = 0xD800 + div(adjusted, 0x400)
    low = 0xDC00 + rem(adjusted, 0x400)
    [escape_codepoint(high), escape_codepoint(low)]
  end

  # --- Private: Auth-param parsing ---

  defguardp whitespace?(c) when c in [?\s, ?\t, ?\r, ?\n, ?\f, ?\v]
  defguardp hex_digit?(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # RFC 9110 §5.6.2 tchar.
  defguardp tchar?(c)
            when c in ?0..?9 or c in ?a..?z or c in ?A..?Z or
                   c in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]

  # auth-params = auth-param *( OWS "," OWS auth-param ), with empty list
  # elements allowed (RFC 9110 §5.6.1). Returns the params and whether a quoted
  # value of a bound param held a legacy `\uXXXX` escape.
  #
  # Both reference parsers require the comma and a token or quoted-string value
  # (mppx `parseAuthParams`, refs/mppx/src/Challenge.ts; mpp-rs
  # `read_challenge_flagged`, refs/mpp-rs/src/protocol/core/headers.rs).
  defp parse_auth_params(input), do: do_parse_params(input, %{}, false)

  defp do_parse_params(input, acc, legacy?) do
    {input, comma?} = skip_separators(input, false)

    cond do
      input == "" ->
        {:ok, acc, legacy?}

      map_size(acc) > 0 and not comma? ->
        {:error, :invalid_auth_params}

      true ->
        with {:ok, key, rest} <- parse_key(input),
             :ok <- check_duplicate(acc, key),
             {:ok, value, rest, escaped?} <- parse_value(rest) do
          do_parse_params(rest, Map.put(acc, key, value), legacy? or (escaped? and key in @bound_params))
        end
    end
  end

  # Skips whitespace and commas, reporting whether a comma was among them.
  defp skip_separators(<<c, rest::binary>>, comma?) when whitespace?(c), do: skip_separators(rest, comma?)
  defp skip_separators("," <> rest, _comma?), do: skip_separators(rest, true)
  defp skip_separators(input, comma?), do: {input, comma?}

  defp skip_whitespace(<<c, rest::binary>>) when whitespace?(c), do: skip_whitespace(rest)
  defp skip_whitespace(input), do: input

  # Extracts the parameter key up to the "=" sign. Names are lowercased so
  # `ID=` / `Id=` map to `"id"` and `id=` + `ID=` collide as `:duplicate_param`
  # (RFC 9110 §11.2: the name is matched case-insensitively).
  defp parse_key(input) do
    case String.split(input, "=", parts: 2) do
      [key, rest] ->
        key = key |> String.trim() |> String.downcase(:ascii)

        # A parameter name is a token, known or not (mppx `parseAuthParams`,
        # mpp-rs `read_challenge_flagged`).
        if token?(key), do: {:ok, key, rest}, else: {:error, :invalid_auth_params}

      _ ->
        {:error, :invalid_auth_params}
    end
  end

  defp token?(<<c, rest::binary>>) when tchar?(c), do: rest == "" or token?(rest)
  defp token?(_other), do: false

  # Checks for duplicate parameters.
  defp check_duplicate(acc, key) do
    if Map.has_key?(acc, key) do
      {:error, :duplicate_param}
    else
      :ok
    end
  end

  # auth-param = token BWS "=" BWS ( token / quoted-string ). An unquoted value
  # is 1*tchar; an empty one is rejected, as mppx does (mpp-rs still reads it
  # as the empty string).
  defp parse_value(input) do
    case skip_whitespace(input) do
      "\"" <> rest -> parse_quoted_string(rest, [], false)
      rest -> parse_token(rest, [])
    end
  end

  defp parse_token(<<c, rest::binary>>, acc) when tchar?(c), do: parse_token(rest, [c | acc])
  defp parse_token(_rest, []), do: {:error, :invalid_auth_params}
  defp parse_token(rest, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, false}

  # Reads a quoted-string. A quoted-pair stands for the character after the
  # backslash, so `—` is the text `u2014` (RFC 9110 §5.6.4; mppx
  # `readQuotedAuthParamValue`, mpp-rs `Tokenizer::value`). The third element
  # of the result reports a `\u` followed by four hex digits: the escape older
  # servers wrote for characters outside ASCII. CR and LF are rejected.
  defp parse_quoted_string("\"" <> rest, acc, escaped?) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, escaped?}
  end

  defp parse_quoted_string(<<"\\u", a, b, c, d, _::binary>> = input, acc, _escaped?)
       when hex_digit?(a) and hex_digit?(b) and hex_digit?(c) and hex_digit?(d) do
    "\\" <> rest = input
    parse_quoted_string(rest, acc, true)
  end

  defp parse_quoted_string(<<"\\", char, rest::binary>>, acc, escaped?) when char not in [?\r, ?\n] do
    parse_quoted_string(rest, [char | acc], escaped?)
  end

  defp parse_quoted_string(<<char, rest::binary>>, acc, escaped?) when char not in [?\\, ?\r, ?\n] do
    parse_quoted_string(rest, [char | acc], escaped?)
  end

  # Unterminated, a trailing backslash, or a line break.
  defp parse_quoted_string(_input, _acc, _escaped?), do: {:error, :invalid_auth_params}

  # Validates that all required auth-params are present.
  defp validate_required_params(params) do
    missing = Enum.reject(@required_params, &Map.has_key?(params, &1))

    if Enum.empty?(missing) do
      :ok
    else
      {:error, :missing_required_params}
    end
  end

  # A received challenge selects the default by leaving `header` out; a written
  # `header` may only be `Payment-Authorization` (mppx `deserialize`, mpp-rs
  # `test_parse_www_authenticate_rejects_unsupported_credential_header`). The
  # other values reach `Challenge.validate_fields/1`; these two would otherwise
  # be folded into the default.
  defp validate_explicit_header(%{"header" => header}) do
    if String.downcase(header) in ["", "authorization"], do: {:error, :invalid_header}, else: :ok
  end

  defp validate_explicit_header(_params), do: :ok

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
      header: Challenge.advertised_header(params["header"]),
      opaque: params["opaque"]
    }
  end
end
