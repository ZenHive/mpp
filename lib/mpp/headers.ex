defmodule MPP.Headers do
  @moduledoc """
  Parse and format the three MPP protocol headers.

  ## Headers

    * `WWW-Authenticate: Payment` — challenge header using RFC 9110 auth-param syntax
    * `Authorization: Payment` — credential header (scheme + base64url JSON blob)
    * `Payment-Receipt` — receipt header (bare base64url JSON blob)
    * `Accept-Payment` — client preference header (`method/intent[;q=value]`)

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
  alias MPP.Receipt

  @payment_scheme "Payment"

  @type accept_payment_entry :: {String.t(), String.t(), float()}

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
    errors: [:invalid_scheme, :missing_required_params, :duplicate_param, :invalid_auth_params, :request_too_large],
    composes_with: [:format_challenge]
  )

  @spec parse_challenge(String.t()) :: {:ok, Challenge.t()} | {:error, atom()}
  def parse_challenge(header) when is_binary(header) do
    with {:ok, rest} <- strip_scheme(header),
         {:ok, params} <- parse_auth_params(rest),
         :ok <- check_request_size(params),
         :ok <- validate_required_params(params) do
      {:ok, params_to_challenge(params)}
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
      :request_too_large
    ],
    composes_with: [:parse_challenge, :format_challenge]
  )

  @spec parse_challenges(String.t()) :: {:ok, [Challenge.t()]} | {:error, atom()}
  def parse_challenges(header) when is_binary(header) do
    segments = split_payment_challenges(header)

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
    errors: [:invalid_base64, :invalid_json, :missing_required_fields, :token_too_large],
    composes_with: [:format_receipt]
  )

  @spec parse_receipt(String.t()) :: {:ok, Receipt.t()} | {:error, atom()}
  def parse_receipt(header) when is_binary(header) do
    token = String.trim(header)

    with :ok <- check_token_size(token) do
      Receipt.decode(token)
    end
  end

  # --- Accept-Payment (client preference) ---

  api(
    :parse_accept_payment,
    "Parse an `Accept-Payment` header into client preference entries. Malformed input returns `[]` (spec MAY-ignore).",
    params: [
      header: [kind: :value, description: "Raw Accept-Payment header value"]
    ],
    returns: %{
      type: :list,
      description: "Ranked preference list as `{method, intent, q}` tuples in declaration order"
    },
    composes_with: [:format_accept_payment, :rank_by_accept_payment]
  )

  @doc """
  Parse an `Accept-Payment` header value into preference entries.

  Each entry is `{method, intent, q}` where `method` and `intent` are lowercase
  tokens or `*`, and `q` is `0.0..1.0` (default `1.0`).

  Returns `[]` for empty, whitespace-only, or malformed input (spec MAY-ignore).
  Headers larger than 16 KiB are ignored the same way (DoS cap, applied before parsing).
  """
  @spec parse_accept_payment(String.t()) :: [accept_payment_entry()]
  def parse_accept_payment(header) when is_binary(header) do
    header
    |> parse_accept_payment_entries()
    |> accept_payment_entries_or_empty()
    |> Enum.map(&entry_to_tuple/1)
  end

  api(
    :apply_accept_payment_header,
    "Filter and reorder server offers using a request `Accept-Payment` header. Malformed or no-match headers are a no-op.",
    params: [
      offers: [kind: :value, description: "Server offers (method entries, challenges, etc.)"],
      header: [kind: :value, description: "Raw Accept-Payment header value, or nil when absent"],
      method_intent: [
        kind: :value,
        description: "Arity-1 function returning `{method, intent}` for each offer"
      ]
    ],
    returns: %{type: :list, description: "Filtered offers in client preference order"},
    composes_with: [:parse_accept_payment, :rank_by_accept_payment]
  )

  @doc """
  Filter and reorder server offers using an `Accept-Payment` header.

  Returns `offers` unchanged when `header` is `nil`, malformed, oversized
  (> 16 KiB), or matches no offers (spec MAY-ignore).
  """
  @spec apply_accept_payment_header([term()], String.t() | nil, (term() -> {String.t(), String.t()})) ::
          [term()]
  def apply_accept_payment_header(offers, nil, _method_intent), do: offers

  def apply_accept_payment_header(offers, header, method_intent)
      when is_binary(header) and is_function(method_intent, 1) do
    case parse_accept_payment_entries(header) do
      {:error, :malformed} ->
        offers

      {:ok, preferences} ->
        tuples = Enum.map(preferences, &entry_to_tuple/1)

        case rank_by_accept_payment(offers, tuples, method_intent) do
          [] -> offers
          ranked -> ranked
        end
    end
  end

  api(
    :format_accept_payment,
    "Format preference entries into an `Accept-Payment` header value.",
    params: [
      entries: [
        kind: :value,
        description: "List of `{method, intent, q}` tuples (or maps with `:method`, `:intent`, `:q`)"
      ]
    ],
    returns: %{type: :string, description: "Accept-Payment header value"},
    composes_with: [:parse_accept_payment]
  )

  @doc """
  Format preference entries into an `Accept-Payment` header value.

  Omits `;q=` when `q` is `1.0`. Entries may be `{method, intent, q}` tuples
  or maps with `:method`, `:intent`, and `:q` keys.
  """
  @spec format_accept_payment([accept_payment_entry() | map()]) :: String.t()
  def format_accept_payment(entries) when is_list(entries) do
    entries
    |> Enum.map(&normalize_accept_payment_entry/1)
    |> Enum.map_join(", ", fn {method, intent, q} ->
      base = "#{method}/#{intent}"

      if q == 1.0 do
        base
      else
        "#{base};q=#{format_accept_payment_q(q)}"
      end
    end)
  end

  api(
    :rank_by_accept_payment,
    "Reorder server offers by client `Accept-Payment` preferences. Excludes `q=0` matches.",
    params: [
      offers: [kind: :value, description: "List of offers (challenges, method entries, etc.)"],
      preferences: [
        kind: :value,
        description: "Parsed `Accept-Payment` entries as `{method, intent, q}` tuples"
      ],
      method_intent: [
        kind: :value,
        description: "Arity-1 function returning `{method, intent}` for each offer"
      ]
    ],
    returns: %{
      type: :list,
      description: "Filtered offers sorted by best client preference (q DESC, offer order ASC)"
    },
    composes_with: [:parse_accept_payment]
  )

  @doc """
  Reorder server offers by client `Accept-Payment` preferences.

  Offers with no matching preference or only `q=0` matches are excluded.
  Sorting matches mpp-rs / mppx: highest effective `q`, then original offer order.

  `method_intent` extracts `{method, intent}` from each offer (defaults to
  challenge fields when omitted).
  """
  @spec rank_by_accept_payment([term()], [accept_payment_entry() | map()], (term() -> {String.t(), String.t()})) ::
          [term()]
  def rank_by_accept_payment(offers, preferences, method_intent \\ &default_method_intent/1)
      when is_list(offers) and is_list(preferences) and is_function(method_intent, 1) do
    prefs_internal =
      preferences
      |> Enum.with_index()
      |> Enum.map(fn {pref, index} ->
        {method, intent, q} = normalize_accept_payment_entry(pref)
        %{method: method, intent: intent, q: q, index: index}
      end)

    rank_accept_payment_offers(offers, prefs_internal, method_intent)
  end

  # --- Private: Accept-Payment ---

  @typep accept_payment_entry_internal :: %{
           method: String.t(),
           intent: String.t(),
           q: float(),
           index: non_neg_integer()
         }

  defp entry_to_tuple(entry), do: accept_payment_entry_to_tuple(entry)

  defp normalize_accept_payment_entry({method, intent, q}) when is_float(q), do: {method, intent, q}

  defp normalize_accept_payment_entry(entry) when is_map(entry), do: accept_payment_entry_to_tuple(entry)

  defp accept_payment_entry_to_tuple(%{method: method, intent: intent, q: q}), do: {method, intent, q}

  @spec parse_accept_payment_entries(String.t()) ::
          {:ok, [accept_payment_entry_internal()]} | {:error, :malformed}
  # DoS guard: an oversized client-supplied Accept-Payment header is ignored
  # (advisory, spec MAY-ignore) before String.split allocates a parts list,
  # mirroring the @max_token_len credential/receipt guards (mpp-rs #299). At-limit passes.
  defp parse_accept_payment_entries(header) when byte_size(header) > @max_token_len do
    {:error, :malformed}
  end

  defp parse_accept_payment_entries(header) when is_binary(header) do
    parts =
      header
      |> String.split(",", trim: true)
      |> Enum.reject(&(&1 == ""))

    parse_accept_payment_parts(parts)
  end

  defp accept_payment_entries_or_empty({:ok, entries}), do: entries
  defp accept_payment_entries_or_empty({:error, :malformed}), do: []

  defp parse_accept_payment_parts([]), do: {:error, :malformed}

  defp parse_accept_payment_parts(parts) do
    parts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &parse_accept_payment_reduce_part/2)
    |> reverse_accept_payment_entries()
  end

  defp parse_accept_payment_reduce_part({part, index}, {:ok, acc}) do
    case parse_accept_payment_part(part, index) do
      {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
      {:error, _} -> {:halt, {:error, :malformed}}
    end
  end

  defp reverse_accept_payment_entries({:ok, entries}), do: {:ok, Enum.reverse(entries)}
  defp reverse_accept_payment_entries(other), do: other

  defp parse_accept_payment_part(part, index) do
    {token, params_str} =
      case String.split(part, ";", parts: 2) do
        [token, params] -> {String.trim(token), String.trim(params)}
        [token] -> {String.trim(token), nil}
      end

    case String.split(token, "/", parts: 2) do
      [method, intent] when method != "" and intent != "" ->
        with :ok <- validate_accept_payment_token(method, part),
             :ok <- validate_accept_payment_token(intent, part),
             {:ok, q} <- parse_accept_payment_q(params_str, part) do
          {:ok, %{method: method, intent: intent, q: q, index: index}}
        else
          _ -> {:error, :malformed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  defp validate_accept_payment_token("*", _part), do: :ok

  defp validate_accept_payment_token(token, _part) do
    if Regex.match?(~r/^[a-z0-9-]+$/, token) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp parse_accept_payment_q(nil, _part), do: {:ok, 1.0}
  defp parse_accept_payment_q("", _part), do: {:ok, 1.0}

  defp parse_accept_payment_q(params_str, part) do
    params_str
    |> String.split(";")
    |> Enum.reduce_while({:ok, 1.0}, &parse_accept_payment_q_param(&1, &2, part))
  end

  defp parse_accept_payment_q_param(param, {:ok, acc}, part) do
    param
    |> String.trim()
    |> String.split("=", parts: 2)
    |> parse_accept_payment_q_param_parts(acc, part)
  end

  defp parse_accept_payment_q_param_parts([name, value], acc, part) do
    if String.trim(name) == "q" do
      value |> String.trim() |> parse_accept_payment_q_value(part) |> continue_accept_payment_q()
    else
      {:cont, {:ok, acc}}
    end
  end

  defp parse_accept_payment_q_param_parts(_parts, acc, _part), do: {:cont, {:ok, acc}}

  defp continue_accept_payment_q({:ok, q}), do: {:cont, {:ok, q}}
  defp continue_accept_payment_q(error), do: {:halt, error}

  defp parse_accept_payment_q_value(value, _part) do
    with {q, ""} <- Float.parse(value),
         true <- q >= 0.0 and q <= 1.0,
         true <- accept_payment_q_decimals_ok?(value) do
      {:ok, q}
    else
      _ -> {:error, :malformed}
    end
  end

  defp accept_payment_q_decimals_ok?(value) do
    case String.split(value, ".", parts: 2) do
      [_int, decimals] -> String.length(decimals) <= 3
      [_int] -> true
    end
  end

  defp format_accept_payment_q(q) do
    q
    |> :erlang.float_to_binary([{:decimals, 3}])
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp default_method_intent(%Challenge{method: method, intent: intent}), do: {method, intent}

  defp default_method_intent(%{method: method, intent: intent}) when is_binary(method) and is_binary(intent),
    do: {method, intent}

  defp rank_accept_payment_offers(_offers, [], _method_intent), do: []

  defp rank_accept_payment_offers(offers, prefs_internal, method_intent) do
    offers
    |> Enum.with_index()
    |> Enum.flat_map(&rank_accept_payment_offer(&1, prefs_internal, method_intent))
    |> Enum.sort_by(fn {offer_idx, q, _offer} -> {-q, offer_idx} end)
    |> Enum.map(fn {_idx, _q, offer} -> offer end)
  end

  defp rank_accept_payment_offer({offer, offer_idx}, preferences, method_intent) do
    case best_accept_payment_match(method_intent.(offer), preferences) do
      %{q: q} when q > 0.0 -> [{offer_idx, q, offer}]
      _ -> []
    end
  end

  defp best_accept_payment_match({offer_method, offer_intent}, preferences) do
    Enum.reduce(preferences, nil, &maybe_better_accept_payment_match(&1, &2, offer_method, offer_intent))
  end

  defp maybe_better_accept_payment_match(pref, best, offer_method, offer_intent) do
    if accept_payment_matches?(offer_method, offer_intent, pref) do
      pref |> accept_payment_candidate() |> choose_accept_payment_match(best)
    else
      best
    end
  end

  defp accept_payment_candidate(pref) do
    %{
      q: pref.q,
      specificity: accept_payment_specificity(pref),
      index: pref.index
    }
  end

  defp choose_accept_payment_match(candidate, best),
    do: if(better_accept_payment_match?(candidate, best), do: candidate, else: best)

  defp accept_payment_matches?(offer_method, offer_intent, %{method: method, intent: intent}) do
    (method == "*" or method == offer_method) and (intent == "*" or intent == offer_intent)
  end

  defp accept_payment_specificity(%{method: method, intent: intent}) do
    if(method == "*", do: 0, else: 1) + if(intent == "*", do: 0, else: 1)
  end

  defp better_accept_payment_match?(_candidate, nil), do: true

  defp better_accept_payment_match?(candidate, best) do
    candidate.specificity > best.specificity or
      (candidate.specificity == best.specificity and candidate.q > best.q) or
      (candidate.specificity == best.specificity and candidate.q == best.q and candidate.index < best.index)
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
  @spec check_request_size(%{optional(String.t()) => String.t()}) :: :ok | {:error, :request_too_large}
  defp check_request_size(%{"request" => request}) when byte_size(request) > @max_token_len,
    do: {:error, :request_too_large}

  defp check_request_size(_params), do: :ok

  # --- Private: Multi-challenge splitting ---

  # Splits a WWW-Authenticate header into individual "Payment ..." segments.
  # Uses a character-by-character state machine to find scheme boundaries while
  # correctly ignoring content inside quoted auth-param values. Then extracts
  # only the Payment segments using boundary positions.
  defp split_payment_challenges(header) do
    all_starts = find_scheme_boundaries(header)

    # Identify which boundaries are Payment schemes (exact match, not prefix)
    all_starts
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.filter(fn [pos, _next] -> payment_scheme_at?(header, pos) end)
    |> Enum.map(fn [start, next_boundary] ->
      # Segment ends at the next scheme boundary (any scheme, not just Payment)
      segment_end = next_boundary || byte_size(header)

      header
      |> binary_part(start, segment_end - start)
      |> String.trim_trailing()
      |> String.trim_trailing(",")
      |> String.trim_trailing()
    end)
  end

  # Walks the header byte-by-byte, tracking quoted-string state to find scheme
  # boundary positions. A boundary is a token followed by whitespace, occurring
  # at position 0 or immediately after a comma (outside quotes).
  defp find_scheme_boundaries(header), do: find_boundaries(header, 0, false, true, [])

  # Base case: end of input
  defp find_boundaries(<<>>, _pos, _in_q, _after_sep, acc), do: Enum.reverse(acc)

  # Inside a quoted string: handle escapes, closing quote
  defp find_boundaries(<<"\\", _, rest::binary>>, pos, true, after_sep, acc),
    do: find_boundaries(rest, pos + 2, true, after_sep, acc)

  defp find_boundaries(<<"\"", rest::binary>>, pos, true, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, false, false, acc)

  defp find_boundaries(<<_, rest::binary>>, pos, true, after_sep, acc),
    do: find_boundaries(rest, pos + 1, true, after_sep, acc)

  # Outside quotes: opening quote
  defp find_boundaries(<<"\"", rest::binary>>, pos, false, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, true, false, acc)

  # Comma sets the "after separator" flag
  defp find_boundaries(<<",", rest::binary>>, pos, false, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, false, true, acc)

  # Whitespace after separator is still "after separator"
  defp find_boundaries(<<c, rest::binary>>, pos, false, true, acc) when c in [?\s, ?\t],
    do: find_boundaries(rest, pos + 1, false, true, acc)

  # Non-whitespace after separator (or at start): potential scheme boundary
  defp find_boundaries(<<c, _::binary>> = bin, pos, false, true, acc) when c in ?A..?Z or c in ?a..?z do
    case extract_scheme_token(bin) do
      {:ok, _token, len} ->
        find_boundaries(binary_part(bin, len, byte_size(bin) - len), pos + len, false, false, [pos | acc])

      :not_scheme ->
        find_boundaries(binary_part(bin, 1, byte_size(bin) - 1), pos + 1, false, false, acc)
    end
  end

  # Any other character resets "after separator" flag
  defp find_boundaries(<<_, rest::binary>>, pos, false, _after_sep, acc),
    do: find_boundaries(rest, pos + 1, false, false, acc)

  # Extracts a scheme token (RFC 9110: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ))
  # followed by at least one whitespace character. Returns {:ok, token, total_len}
  # where total_len includes the token + first whitespace char.
  defp extract_scheme_token(bin), do: extract_scheme_token(bin, 0)

  defp extract_scheme_token(bin, len) when len < byte_size(bin) do
    c = :binary.at(bin, len)

    cond do
      c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?+, ?-, ?.] ->
        extract_scheme_token(bin, len + 1)

      len > 0 and c in [?\s, ?\t] ->
        {:ok, binary_part(bin, 0, len), len + 1}

      true ->
        :not_scheme
    end
  end

  defp extract_scheme_token(_bin, _len), do: :not_scheme

  # Checks if the scheme token at `pos` is exactly "Payment" (case-insensitive).
  # Requires that the character after "Payment" is whitespace, preventing prefix
  # matches like "Payments" or "PaymentX".
  defp payment_scheme_at?(header, pos) do
    case binary_part(header, pos, min(8, byte_size(header) - pos)) do
      <<token::binary-size(7), c>> when c in [?\s, ?\t] ->
        String.downcase(token) == "payment"

      _ ->
        false
    end
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
