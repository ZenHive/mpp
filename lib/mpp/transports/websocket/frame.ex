defmodule MPP.Transports.WebSocket.Frame do
  @moduledoc false
  # Typed MPP WebSocket frames from mpp-rs `server::ws` / `client::ws`
  # (`refs/mpp-rs/src/server/ws.rs`, `refs/mpp-rs/src/client/ws.rs`) and
  # `alloy-transport-mpp` (`refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs`).
  #
  # Discriminator is `type`. camelCase payload keys. Server→client `message`
  # frames carry `data` as a JSON-encoded string; client→server `message`
  # frames carry `data` as a structured JSON value.

  alias MPP.Challenge

  @known_types ~w(challenge credential message needVoucher receipt error)

  @type t :: map()

  @doc "Parse a WebSocket text payload into an MPP frame map."
  @spec decode(String.t()) :: {:ok, t()} | {:error, :malformed_frame | :unknown_frame}
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = frame} when type in @known_types -> {:ok, frame}
      {:ok, _} -> {:error, :unknown_frame}
      {:error, _} -> {:error, :malformed_frame}
    end
  end

  @doc "Serialize an MPP frame map to JSON, omitting a null `error` field."
  @spec encode(t()) :: String.t()
  def encode(%{"type" => type} = frame) when type in @known_types do
    Jason.encode!(drop_nil_error(frame))
  end

  @doc "Build a server `challenge` frame."
  @spec challenge_frame(Challenge.t(), String.t() | nil) :: t()
  def challenge_frame(%Challenge{} = challenge, error \\ nil) do
    frame = %{"type" => "challenge", "challenge" => challenge_to_wire(challenge)}

    if is_binary(error) do
      Map.put(frame, "error", error)
    else
      frame
    end
  end

  @doc "Build a client `credential` frame."
  @spec credential_frame(String.t()) :: t()
  def credential_frame(authorization) when is_binary(authorization) do
    %{"type" => "credential", "credential" => authorization}
  end

  @doc "Build a server `message` frame, encoding structured data as a JSON string."
  @spec message_frame(term()) :: t()
  def message_frame(data) when is_binary(data), do: %{"type" => "message", "data" => data}

  def message_frame(data) do
    %{"type" => "message", "data" => Jason.encode!(data)}
  end

  @doc "Build a server `receipt` frame."
  @spec receipt_frame(map()) :: t()
  def receipt_frame(%{} = receipt), do: %{"type" => "receipt", "receipt" => receipt}

  @doc "Build a server `error` frame."
  @spec error_frame(String.t()) :: t()
  def error_frame(error) when is_binary(error), do: %{"type" => "error", "error" => error}

  @doc "Build a server `needVoucher` frame with camelCase wire keys."
  @spec need_voucher_frame(keyword() | map()) :: t()
  def need_voucher_frame(attrs) when is_list(attrs) do
    need_voucher_frame(Map.new(attrs, fn {k, v} -> {to_string(k), v} end))
  end

  def need_voucher_frame(%{} = attrs) do
    %{
      "type" => "needVoucher",
      "channelId" => fetch_attr(attrs, "channelId", :channel_id),
      "requiredCumulative" => fetch_attr(attrs, "requiredCumulative", :required_cumulative),
      "acceptedCumulative" => fetch_attr(attrs, "acceptedCumulative", :accepted_cumulative),
      "deposit" => fetch_attr(attrs, "deposit", :deposit)
    }
  end

  @doc "Serialize a challenge with `request` left as its raw base64url string."
  @spec challenge_to_wire(Challenge.t()) :: map()
  def challenge_to_wire(%Challenge{} = challenge) do
    %{
      "id" => challenge.id,
      "realm" => challenge.realm,
      "method" => challenge.method,
      "intent" => challenge.intent,
      "request" => challenge.request
    }
    |> maybe_put("expires", challenge.expires)
    |> maybe_put("description", challenge.description)
    |> maybe_put("digest", challenge.digest)
    |> maybe_put("opaque", challenge.opaque)
  end

  @doc "Parse a wire challenge object into an `MPP.Challenge`."
  @spec challenge_from_wire(term()) :: {:ok, Challenge.t()} | {:error, :invalid_challenge}
  def challenge_from_wire(
        %{"id" => id, "realm" => realm, "method" => method, "intent" => intent, "request" => request} = map
      )
      when is_binary(id) and is_binary(realm) and is_binary(method) and is_binary(intent) and is_binary(request) do
    challenge = %Challenge{
      id: id,
      realm: realm,
      method: method,
      intent: intent,
      request: request,
      description: optional_string(map, "description"),
      digest: optional_string(map, "digest"),
      expires: optional_string(map, "expires"),
      opaque: optional_string(map, "opaque")
    }

    case Challenge.validate_fields(challenge) do
      :ok -> {:ok, challenge}
      {:error, _reason} -> {:error, :invalid_challenge}
    end
  end

  def challenge_from_wire(_other), do: {:error, :invalid_challenge}

  @doc "Unwrap a `message` frame's `data` field, JSON-decoding string payloads."
  @spec unwrap_message_data(t()) :: {:ok, term()} | {:error, :malformed_frame}
  def unwrap_message_data(%{"type" => "message", "data" => data}) when is_map(data) or is_list(data) do
    {:ok, data}
  end

  def unwrap_message_data(%{"type" => "message", "data" => data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, data}
    end
  end

  def unwrap_message_data(_other), do: {:error, :malformed_frame}

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_error(%{"error" => nil} = frame), do: Map.delete(frame, "error")
  defp drop_nil_error(frame), do: frame

  defp fetch_attr(attrs, string_key, atom_key) do
    Map.get(attrs, string_key) || Map.get(attrs, Atom.to_string(atom_key)) || Map.get(attrs, atom_key)
  end
end
