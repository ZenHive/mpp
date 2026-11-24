defmodule MPP.Challenge.Meta do
  @moduledoc false
  # Reserved members of a challenge's `opaque` JSON object, with the wire shape of the
  # reference SDKs (refs/mppx/src/internal/challengeMeta.ts,
  # refs/mppx/src/server/internal/scope.ts, refs/mpp-rs/src/server/mpp/issue.rs and
  # verify.rs):
  #
  #   * `_mpp_nonce` — 16 random bytes, base64url without padding, fresh per issued
  #     challenge. `_mppx_nonce` is the key of earlier mppx releases.
  #   * `_mppx_scope` — the route a challenge is bound to.
  #   * `_mppx_identity`, `_mppx_expiry_grace` — issuance-only markers of the reference
  #     SDKs. They are not issued here and are ignored when a route is matched, as
  #     both SDKs do, so a challenge of an mppx or mpp-rs instance holding the same
  #     secret matches its route.
  #
  # The nonce lives inside `opaque`, which the challenge HMAC already covers, so the
  # HMAC input layout is the one every SDK computes.

  alias MPP.JCS

  @nonce_key "_mpp_nonce"
  @legacy_nonce_key "_mppx_nonce"
  @scope_key "_mppx_scope"
  @issuance_keys [@nonce_key, @legacy_nonce_key, "_mppx_identity", "_mppx_expiry_grace"]
  @nonce_bytes 16

  @typedoc "An `opaque` in the form routes are matched in."
  @type route_form :: nil | {:json, term()} | {:raw, String.t()}

  @doc """
  Adds a fresh `_mpp_nonce` to an `opaque`, keeping its other members.

  An `opaque` that is not a JSON object, or an object that repeats a member name, has
  nowhere to put a nonce and is returned as given.
  """
  @spec with_nonce(String.t() | nil) :: String.t() | nil
  def with_nonce(opaque) do
    case members(opaque) do
      {:ok, members} ->
        nonce = @nonce_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        encode(Map.put(members, @nonce_key, nonce))

      :error ->
        opaque
    end
  end

  @doc "Whether an `opaque` carries an issuance nonce."
  @spec nonce?(String.t() | nil) :: boolean()
  def nonce?(opaque) do
    case decode(opaque) do
      {:ok, %{} = members} -> is_binary(members[@nonce_key]) or is_binary(members[@legacy_nonce_key])
      _other -> false
    end
  end

  @doc """
  Reduces an `opaque` to what a route is matched on: a JSON object without its
  issuance-only members (left empty, it counts as absent), any other JSON value as is,
  and text that is not base64url JSON, or JSON that repeats a member name, as the raw
  string. Compare two forms with `same_route?/2`.
  """
  @spec route_form(String.t() | nil) :: route_form()
  def route_form(nil), do: nil

  def route_form(opaque) when is_binary(opaque) do
    case decode(opaque) do
      {:ok, %{} = members} ->
        stable = Map.drop(members, @issuance_keys)
        if map_size(stable) == 0, do: nil, else: {:json, stable}

      {:ok, other} ->
        {:json, other}

      :error ->
        {:raw, opaque}
    end
  end

  @doc """
  Whether two `opaque` values name the same route. JSON values are compared strictly,
  so `1` and `1.0` differ as they do on the wire.
  """
  @spec same_route?(String.t() | nil, String.t() | nil) :: boolean()
  def same_route?(opaque, expected), do: route_form(opaque) === route_form(expected)

  @doc """
  Binds a route's `opaque` to `scope` under `_mppx_scope`.

  Raises `ArgumentError` when the `opaque` cannot carry members or already names a
  different scope.
  """
  @spec with_scope!(String.t() | nil, String.t() | nil) :: String.t() | nil
  def with_scope!(opaque, nil), do: opaque

  def with_scope!(opaque, scope) when is_binary(scope) and scope != "" do
    case members(opaque) do
      {:ok, %{@scope_key => other}} when other != scope ->
        raise ArgumentError,
              "MPP.Plug :scope (#{inspect(scope)}) conflicts with the opaque's #{@scope_key} (#{inspect(other)})"

      {:ok, members} ->
        encode(Map.put(members, @scope_key, scope))

      :error ->
        raise ArgumentError,
              "MPP.Plug :scope needs an :opaque that is a base64url JSON object without repeated member names"
    end
  end

  def with_scope!(_opaque, scope) do
    raise ArgumentError, "MPP.Plug :scope must be a non-empty string, got: #{inspect(scope)}"
  end

  @doc "Raises `ArgumentError` when a configured `opaque` sets a member reserved for issuance."
  @spec validate_configured!(String.t() | nil) :: :ok
  def validate_configured!(opaque) do
    case decode(opaque) do
      {:ok, %{} = members} ->
        case Enum.find(@issuance_keys, &is_map_key(members, &1)) do
          nil -> :ok
          key -> raise ArgumentError, "a route's :opaque must not set #{key}; it is reserved for issued challenges"
        end

      _other ->
        :ok
    end
  end

  # The members a nonce or scope can be added to: none for an absent opaque, an
  # object's own otherwise.
  defp members(nil), do: {:ok, %{}}

  defp members(opaque) do
    case decode(opaque) do
      {:ok, %{} = members} -> {:ok, members}
      _other -> :error
    end
  end

  # Accepts the alphabets `MPP.Challenge.validate/1` accepts for `opaque`: base64url,
  # and standard base64 with or without padding (mpp-rs `base64url_decode`).
  defp decode(opaque) when is_binary(opaque) do
    normalized = opaque |> String.replace("=", "") |> String.replace("+", "-") |> String.replace("/", "_")

    with {:ok, json} <- Base.url_decode64(normalized, padding: false),
         {:ok, value} <- Jason.decode(json, objects: :ordered_objects) do
      plain(value)
    else
      _error -> :error
    end
  end

  defp decode(_opaque), do: :error

  # JSON parsers disagree on which of two members with one name wins, so such a
  # document has no single reading and is matched as text.
  defp plain(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if Enum.uniq(keys) == keys do
      plain_members(pairs)
    else
      :error
    end
  end

  defp plain(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case plain(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp plain(scalar), do: {:ok, scalar}

  defp plain_members(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case plain(item) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # Canonical JSON (RFC 8785) wherever `MPP.JCS` covers the members, which is the
  # string metadata both SDKs issue. `MPP.JCS` has no float serialization, so an opaque
  # holding a float is written as plain JSON: it is matched by value, never by bytes.
  defp encode(members) do
    json = if float?(members), do: Jason.encode!(members), else: JCS.canonicalize(members)
    Base.url_encode64(json, padding: false)
  end

  defp float?(%{} = map), do: Enum.any?(map, fn {_key, value} -> float?(value) end)
  defp float?(list) when is_list(list), do: Enum.any?(list, &float?/1)
  defp float?(value), do: is_float(value)
end
