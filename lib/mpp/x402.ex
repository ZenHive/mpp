defmodule MPP.X402 do
  @moduledoc """
  x402 v2 exact interoperability (HTTP transport, EVM EIP-3009 only).

  Protocol authority is the [x402 v2 specification](https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md)
  and live facilitator traffic. `refs/mppx/src/x402` is the SDK compatibility
  target (`scheme` `"exact"` only; `refs/mppx/src/x402/Types.ts`).

  `challenges_from_header/1` does not take a request URL and does not require
  `resource.url` to equal the response URL. mppx #908 (0.11.0) dropped that
  client check: query strings, redirects, proxies, and port rewriting made the
  two URLs differ, and the exact match turned a payable offer into a silent
  miss. Binding the paid resource stays on `MPP.X402.Plug`
  (`:resource_mismatch` when the echoed credential resource does not match).

  Out of scope: MCP, x402 v1 (`X-PAYMENT`), non-EVM CAIP-2 families, schemes
  other than `exact`, and Permit2 client signing.
  """

  use Descripex, namespace: "/x402"

  alias MPP.Challenge
  alias MPP.Codec
  alias MPP.JCS
  alias MPP.X402.Headers

  @payment_method "evm"
  @exact_intent "charge"
  @synthetic_id_prefix "x402:"
  @evm_network_prefix "eip155:"

  api(:version, "Return the x402 protocol version.", returns: %{type: :integer, description: "`2`"})

  @doc "x402 v2 protocol version."
  @spec version() :: 2
  def version, do: 2

  api(:payment_method, "Return the MPP method name used for synthetic x402 exact challenges.",
    returns: %{type: :string, description: "`evm`"}
  )

  @doc "MPP method name used for synthetic x402 exact challenges."
  @spec payment_method() :: String.t()
  def payment_method, do: @payment_method

  api(:exact_intent, "Return the MPP intent name used for synthetic x402 exact challenges.",
    returns: %{type: :string, description: "`charge`"}
  )

  @doc "MPP intent name used for synthetic x402 exact challenges."
  @spec exact_intent() :: String.t()
  def exact_intent, do: @exact_intent

  api(:synthetic_id_prefix, "Return the synthetic challenge-id prefix for x402 accepts.",
    returns: %{type: :string, description: "`x402:`"}
  )

  @doc "Prefix for synthetic challenge IDs derived from `PAYMENT-REQUIRED` accepts."
  @spec synthetic_id_prefix() :: String.t()
  def synthetic_id_prefix, do: @synthetic_id_prefix

  api(:synthetic?, "Return true when a challenge was synthesized from a PAYMENT-REQUIRED offer.",
    params: [challenge: [kind: :value, description: "Challenge or other term"]],
    returns: %{type: :boolean, description: "true for synthetic x402 exact challenges"}
  )

  @doc "Return true when a challenge was synthesized from an x402 `PAYMENT-REQUIRED` offer."
  @spec synthetic?(term()) :: boolean()
  def synthetic?(%Challenge{id: id} = challenge) when is_binary(id) do
    String.starts_with?(id, @synthetic_id_prefix) and match?({:ok, _}, exact_request(challenge))
  end

  def synthetic?(_other), do: false

  api(
    :challenges_from_header,
    "Parse PAYMENT-REQUIRED into synthetic challenges. No request_url argument: " <>
      "resource.url is not matched to the response URL, because that equality " <>
      "dropped payable offers when query strings, redirects, proxies, or port " <>
      "rewriting made the URLs differ (mppx #908). MPP.X402.Plug still binds the paid resource.",
    params: [
      header: [kind: :value, description: "Base64 JSON PAYMENT-REQUIRED value"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, challenges}` or `{:error, reason}`"}
  )

  @doc """
  Parse a `PAYMENT-REQUIRED` header into synthetic `MPP.Challenge` structs.

  Unsupported accepts (non-`exact`, non-EVM, Permit2) are dropped. An empty
  remainder is `{:ok, []}`. There is no `request_url` argument: `resource.url`
  is not compared to the response URL. That equality check dropped payable
  offers when query strings, redirects, proxies, or port rewriting made the
  two URLs differ (mppx #908). `MPP.X402.Plug` still rejects a credential
  whose echoed resource does not match the server-bound URL.
  """
  @spec challenges_from_header(String.t()) :: {:ok, [Challenge.t()]} | {:error, atom()}
  def challenges_from_header(header) when is_binary(header) do
    case Headers.decode_payment_required_envelope(header) do
      {:ok, envelope} -> {:ok, challenges_from_envelope(envelope)}
      {:error, reason} -> {:error, reason}
    end
  end

  api(:exact_request, "Decode the Exact request object stored on a synthetic challenge.",
    params: [challenge: [kind: :value, description: "Synthetic x402 challenge"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, map}` or `{:error, reason}`"}
  )

  @doc "Decode the Exact request object stored on a synthetic challenge."
  @spec exact_request(Challenge.t()) :: {:ok, map()} | {:error, atom()}
  def exact_request(%Challenge{} = challenge) do
    with {:ok, request} <- Codec.decode_base64_json(challenge.request),
         true <- is_map(request),
         {:ok, accepted} <- Headers.parse_requirements(request) do
      {:ok, attach_request_context(accepted, request)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_request}
    end
  end

  api(:chain_id, "Parse eip155:<id> into a positive chain id.",
    params: [network: [kind: :value, description: "CAIP-2 network string"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, id}` or `{:error, :invalid_network}`"}
  )

  @doc "Parse `eip155:<id>` into a positive chain id."
  @spec chain_id(String.t()) :: {:ok, pos_integer()} | {:error, atom()}
  def chain_id(@evm_network_prefix <> rest) do
    case Integer.parse(rest) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_network}
    end
  end

  def chain_id(_other), do: {:error, :invalid_network}

  defp challenges_from_envelope(envelope) do
    envelope
    |> Map.get("accepts", [])
    |> Enum.with_index()
    |> Enum.flat_map(&challenge_or_empty(&1, envelope))
  end

  defp challenge_or_empty({raw, index}, envelope) do
    case accept_to_challenge(raw, envelope, index) do
      {:ok, challenge} -> [challenge]
      :skip -> []
    end
  end

  defp accept_to_challenge(raw, envelope, index) when is_map(raw) do
    case accepted_challenge(raw, envelope, index) do
      {:ok, challenge} -> {:ok, challenge}
      _other -> :skip
    end
  end

  defp accept_to_challenge(_raw, _envelope, _index), do: :skip

  defp accepted_challenge(raw, envelope, index) do
    with {:ok, accepted} <- Headers.parse_requirements(raw),
         :ok <- Headers.reject_permit2(accepted) do
      resource = envelope["resource"]
      request = request_blob(accepted, resource, envelope["extensions"])

      {:ok,
       %Challenge{
         id: @synthetic_id_prefix <> Integer.to_string(index),
         realm: realm_for(resource),
         method: @payment_method,
         intent: @exact_intent,
         request: request
       }}
    end
  end

  defp request_blob(accepted, resource, extensions) do
    accepted
    |> attach_request_context(%{"resource" => resource, "extensions" => extensions})
    |> JCS.canonicalize()
    |> Base.url_encode64(padding: false)
  end

  defp realm_for(%{"url" => url}) when is_binary(url), do: uri_host(url)
  defp realm_for(_resource), do: "x402"

  defp attach_request_context(accepted, request) do
    accepted
    |> maybe_put("resource", request["resource"])
    |> maybe_put("extensions", request["extensions"])
  end

  defp uri_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> "x402"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
