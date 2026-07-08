defmodule MPP.AcceptPayment do
  @moduledoc """
  Parse, format, and rank the `Accept-Payment` client-preference header.

  The `Accept-Payment` header lets a client advertise which `method/intent`
  pairs it can pay with, optionally weighted by a `q` value (`0.0..1.0`), so a
  server can filter and reorder its offers to match. The syntax mirrors HTTP
  content negotiation: `method/intent[;q=value]`, comma-separated.

      # Client: build a preference header
      MPP.AcceptPayment.format([{"stripe", "charge", 1.0}, {"tempo", "charge", 0.5}])
      # → "stripe/charge, tempo/charge;q=0.5"

      # Server: parse a request header
      MPP.AcceptPayment.parse("stripe/charge, tempo/charge;q=0.5")
      # → [{"stripe", "charge", 1.0}, {"tempo", "charge", 0.5}]

      # Server: reorder offers by client preference
      MPP.AcceptPayment.apply_header(offers, header, &offer_method_intent/1)

  Malformed input is ignored (returns `[]` or a no-op) per the spec's MAY-ignore
  rule; oversized headers (> 16 KiB) are ignored the same way as a DoS guard.
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Challenge

  @type entry :: {String.t(), String.t(), float()}

  # 16 KiB cap on the client-supplied Accept-Payment header, enforced before the
  # header is split into parts, mirroring the credential/receipt token guards
  # (mpp-rs #299). At-limit input still parses; only over-limit is ignored.
  @max_token_len 16 * 1024

  api(
    :parse,
    "Parse an `Accept-Payment` header into client preference entries. Malformed input returns `[]` (spec MAY-ignore).",
    params: [
      header: [kind: :value, description: "Raw Accept-Payment header value"]
    ],
    returns: %{
      type: :list,
      description: "Ranked preference list as `{method, intent, q}` tuples in declaration order"
    },
    composes_with: [:format, :rank]
  )

  @doc """
  Parse an `Accept-Payment` header value into preference entries.

  Each entry is `{method, intent, q}` where `method` and `intent` are lowercase
  tokens or `*`, and `q` is `0.0..1.0` (default `1.0`).

  Returns `[]` for empty, whitespace-only, or malformed input (spec MAY-ignore).
  Headers larger than 16 KiB are ignored the same way (DoS cap, applied before parsing).
  """
  @spec parse(String.t()) :: [entry()]
  def parse(header) when is_binary(header) do
    header
    |> parse_accept_payment_entries()
    |> accept_payment_entries_or_empty()
    |> Enum.map(&entry_to_tuple/1)
  end

  api(
    :apply_header,
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
    composes_with: [:parse, :rank]
  )

  @doc """
  Filter and reorder server offers using an `Accept-Payment` header.

  Returns `offers` unchanged when `header` is `nil`, malformed, oversized
  (> 16 KiB), or matches no offers (spec MAY-ignore).
  """
  @spec apply_header([term()], String.t() | nil, (term() -> {String.t(), String.t()})) ::
          [term()]
  def apply_header(offers, nil, _method_intent), do: offers

  def apply_header(offers, header, method_intent) when is_binary(header) and is_function(method_intent, 1) do
    case parse_accept_payment_entries(header) do
      {:error, :malformed} ->
        offers

      {:ok, preferences} ->
        tuples = Enum.map(preferences, &entry_to_tuple/1)

        case rank(offers, tuples, method_intent) do
          [] -> offers
          ranked -> ranked
        end
    end
  end

  api(
    :format,
    "Format preference entries into an `Accept-Payment` header value.",
    params: [
      entries: [
        kind: :value,
        description: "List of `{method, intent, q}` tuples (or maps with `:method`, `:intent`, `:q`)"
      ]
    ],
    returns: %{type: :string, description: "Accept-Payment header value"},
    composes_with: [:parse]
  )

  @doc """
  Format preference entries into an `Accept-Payment` header value.

  Omits `;q=` when `q` is `1.0`. Entries may be `{method, intent, q}` tuples
  or maps with `:method`, `:intent`, and `:q` keys.
  """
  @spec format([entry() | map()]) :: String.t()
  def format(entries) when is_list(entries) do
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
    :rank,
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
    composes_with: [:parse]
  )

  @doc """
  Reorder server offers by client `Accept-Payment` preferences.

  Offers with no matching preference or only `q=0` matches are excluded.
  Sorting matches mpp-rs / mppx: highest effective `q`, then original offer order.

  `method_intent` extracts `{method, intent}` from each offer (defaults to
  challenge fields when omitted).
  """
  @spec rank([term()], [entry() | map()], (term() -> {String.t(), String.t()})) ::
          [term()]
  def rank(offers, preferences, method_intent \\ &default_method_intent/1)
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

  # --- Private ---

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
end
