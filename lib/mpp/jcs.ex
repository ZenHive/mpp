defmodule MPP.JCS do
  @moduledoc """
  RFC 8785 JSON Canonicalization Scheme (JCS) — MPP subset.

  Produces deterministic JSON output by sorting object keys lexicographically
  and using minimal whitespace. This ensures two implementations serializing
  the same logical data produce byte-identical JSON — critical for HMAC
  reproducibility across SDKs.

  Used by `MPP.Plug` and `MPP.Mcp` when encoding the `request` field before
  base64url encoding and HMAC computation. Matches the canonicalization in
  mppx (`ox.Json.canonicalize`) and mpp-rs (`serde_json_canonicalizer`) for
  all MPP protocol data.

  ## Scope

  This implements the subset of RFC 8785 needed by MPP:

    * **Keys**: ASCII-only (all MPP protocol fields). Sorted by Elixir binary
      comparison, which matches UTF-16 code-unit ordering for ASCII.
    * **Values**: strings, integers, booleans, nil, maps, lists.
    * **Not supported**: floats. MPP amounts are strings in base units
      (never floats). Passing a float raises `FunctionClauseError`.

  For a general-purpose RFC 8785 implementation (non-ASCII keys, IEEE 754
  float serialization), use a dedicated library.

  ## Examples

      iex> MPP.JCS.canonicalize(%{"currency" => "usd", "amount" => "1000"})
      ~S({"amount":"1000","currency":"usd"})

      iex> MPP.JCS.canonicalize(%{"b" => %{"d" => 1, "c" => 2}, "a" => 3})
      ~S({"a":3,"b":{"c":2,"d":1}})
  """

  use Descripex, namespace: "/protocol"

  api(:canonicalize, "Serialize a term to canonical JSON per RFC 8785 (MPP subset: ASCII keys, no floats).",
    params: [
      term: [kind: :value, description: "Elixir term (map, list, string, integer, boolean, or nil)"]
    ],
    returns: %{type: :string, description: "Canonical JSON string"}
  )

  @type canonicalizable :: map() | list() | String.t() | integer() | boolean() | nil

  @spec canonicalize(canonicalizable()) :: String.t()
  def canonicalize(term) when is_map(term) do
    pairs =
      term
      |> Map.to_list()
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_intersperse(",", fn {k, v} -> [Jason.encode!(k), ":", canonicalize(v)] end)

    IO.iodata_to_binary(["{", pairs, "}"])
  end

  def canonicalize(term) when is_list(term) do
    elements = Enum.map_join(term, ",", &canonicalize/1)
    "[" <> elements <> "]"
  end

  def canonicalize(term) when is_binary(term), do: Jason.encode!(term)
  def canonicalize(term) when is_integer(term), do: Integer.to_string(term)
  def canonicalize(true), do: "true"
  def canonicalize(false), do: "false"
  def canonicalize(nil), do: "null"
end
