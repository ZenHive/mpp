defmodule MPP.AcceptPayment do
  @moduledoc """
  Parse, format, and rank the `Accept-Payment` client-preference header.

  The `Accept-Payment` header lets a client advertise which `method/intent`
  pairs it can pay with, optionally weighted by an RFC 9110 `qvalue`
  (`0`/`1` with up to three fraction digits), so a server can filter and
  reorder its offers to match. The syntax mirrors HTTP content negotiation:
  `method/intent[;q=value]`, comma-separated. The `q` parameter name is
  case-insensitive (`Q=0` is an opt-out).

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

  # RFC 9110 qvalue: 0 or 1, optional `.` and up to three digits (only zeros
  # after 1). ASCII `[0-9]` — Elixir `\d` is Unicode. Cited: mpp-rs #488
  # `parse_q_value` and mppx `parseHeaderQ` (`src/internal/AcceptPayment.ts`).
  @qvalue ~r/\A(0(\.[0-9]{0,3})?|1(\.0{0,3})?)\z/
  @intent_token ~r/\A[a-z0-9-]+\z/
  @param_name ~r/\A[A-Za-z0-9_-]+\z/

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

  Each entry is `{method, intent, q}` where `method` is `*` or a challenge
  method name (`[a-z][a-z0-9:_-]*`), `intent` is `*` or `[a-z0-9-]+`, and `q`
  is an RFC 9110 qvalue (default `1.0`).

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
        with :ok <- validate_accept_payment_token(method, :method),
             :ok <- validate_accept_payment_token(intent, :intent),
             {:ok, q} <- parse_accept_payment_q(params_str) do
          {:ok, %{method: method, intent: intent, q: q, index: index}}
        else
          _ -> {:error, :malformed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  defp validate_accept_payment_token("*", _kind), do: :ok

  # Method tokens follow the challenge method grammar (`:`, `_` included);
  # intent tokens stay `[a-z0-9-]+` (mpp-rs #488 `validate_token`).
  defp validate_accept_payment_token(token, :method) do
    if Challenge.valid_method_name?(token), do: :ok, else: {:error, :malformed}
  end

  defp validate_accept_payment_token(token, :intent) do
    if token =~ @intent_token, do: :ok, else: {:error, :malformed}
  end

  defp parse_accept_payment_q(nil), do: {:ok, 1.0}
  defp parse_accept_payment_q(""), do: {:ok, 1.0}

  defp parse_accept_payment_q(params_str) do
    params_str
    |> String.split(";")
    |> Enum.reduce_while({:ok, 1.0}, &parse_accept_payment_q_param/2)
  end

  defp parse_accept_payment_q_param(param, {:ok, acc}) do
    case String.trim(param) do
      "" -> {:cont, {:ok, acc}}
      trimmed -> parse_accept_payment_q_pair(trimmed, acc)
    end
  end

  defp parse_accept_payment_q_pair(param, acc) do
    case String.split(param, "=", parts: 2) do
      [name, value] ->
        name = String.trim(name)
        value = String.trim(value)

        if name =~ @param_name and value != "" and value =~ ~r/\A\S+\z/ do
          parse_accept_payment_named_q(name, value, acc)
        else
          {:halt, {:error, :malformed}}
        end

      _ ->
        {:halt, {:error, :malformed}}
    end
  end

  defp parse_accept_payment_named_q(name, value, acc) do
    if String.downcase(name, :ascii) == "q" do
      continue_accept_payment_q(parse_accept_payment_q_value(value))
    else
      {:cont, {:ok, acc}}
    end
  end

  defp continue_accept_payment_q({:ok, q}), do: {:cont, {:ok, q}}
  defp continue_accept_payment_q(error), do: {:halt, error}

  defp parse_accept_payment_q_value(value) do
    if value =~ @qvalue do
      {:ok, qvalue_to_float(value)}
    else
      {:error, :malformed}
    end
  end

  # Do not use Float.parse/1: it accepts `1e-1` / `+0.5` and leaves `.` as rest
  # on `0.` / `1.`. The regex already pinned RFC 9110, so 1.* is 1.0 and 0*
  # is thousandths (mpp-rs #488 `parse_q_value`).
  defp qvalue_to_float("1" <> _rest), do: 1.0
  defp qvalue_to_float("0"), do: 0.0

  defp qvalue_to_float("0." <> frac) do
    frac
    |> String.pad_trailing(3, "0")
    |> String.to_integer()
    |> Kernel./(1000)
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
