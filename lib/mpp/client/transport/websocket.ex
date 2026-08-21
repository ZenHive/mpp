defmodule MPP.Client.Transport.WebSocket do
  @moduledoc """
  WebSocket implementation of `MPP.Client.Transport`.

  Operates on decoded MPP WebSocket frame maps (the same JSON objects
  `MPP.Transports.WebSocket` produces). Payment required is a `challenge`
  frame; credentials are attached as a `credential` frame whose payload is
  `Payment <base64url>` — matching mpp-rs `client::ws::WsTransport`
  (`refs/mpp-rs/src/client/ws.rs`).

  Reconnect / payment-retry policy lives in
  `MPP.Client.Transport.WebSocket.Retry`. A dropped socket after a credential
  was sent but before the receipt is fatal: it must not pay again.

  JSON-RPC `-32042` envelopes are also recognized so a caller that unwraps a
  `message` frame can reuse this transport for per-call payment-required.
  """

  use MPP.Client.Transport
  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.Transport
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Transports.JsonRpc
  alias MPP.Transports.WebSocket.Frame

  api(:payment_required?, "Return true if the frame or JSON-RPC envelope signals payment required.",
    params: [
      response: [kind: :value, description: "Decoded WS frame or JSON-RPC response"]
    ],
    returns: %{type: :boolean, description: "true for a `challenge` frame or `-32042`"}
  )

  @impl Transport
  @spec payment_required?(term()) :: boolean()
  def payment_required?(%{"type" => "challenge"}), do: true

  def payment_required?(response) when is_map(response), do: JsonRpc.payment_required?(response)

  @spec payment_required?(term()) :: false
  def payment_required?(_response), do: false

  api(:get_challenges, "Parse Payment challenges from a `challenge` frame or JSON-RPC payment-required message.",
    params: [
      response: [kind: :value, description: "Decoded WS frame or JSON-RPC response"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, [challenge]}` on success, `{:error, reason}` otherwise"
    },
    errors: [:malformed_envelope, :no_challenges, :invalid_challenge]
  )

  @impl Transport
  @spec get_challenges(term()) :: {:ok, [Challenge.t()]} | {:error, term()}
  def get_challenges(%{"type" => "challenge", "challenge" => challenge}) do
    case Frame.challenge_from_wire(challenge) do
      {:ok, parsed} -> {:ok, [parsed]}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_challenges(%{"type" => "challenge"}), do: {:error, :no_challenges}

  def get_challenges(response) when is_map(response), do: JsonRpc.extract_challenges(response)

  @spec get_challenges(term()) :: {:error, :malformed_envelope}
  def get_challenges(_response), do: {:error, :malformed_envelope}

  api(:set_credential, "Replace the request with a WS `credential` frame (`Payment <base64url>`).",
    params: [
      request: [kind: :value, description: "Prior request or frame; discarded, matching mpp-rs WsTransport"],
      credential: [kind: :value, description: "MPP.Credential struct"]
    ],
    returns: %{type: :map, description: "Credential frame"}
  )

  @impl Transport
  @spec set_credential(term(), Credential.t()) :: map()
  def set_credential(_request, %Credential{} = credential) do
    Frame.credential_frame(Headers.format_credential(credential))
  end

  api(:receipt?, "Return true if the frame is a server `receipt`.",
    params: [
      response: [kind: :value, description: "Decoded WS frame"]
    ],
    returns: %{type: :boolean, description: "true for a `receipt` frame"}
  )

  @spec receipt?(term()) :: boolean()
  def receipt?(%{"type" => "receipt"}), do: true
  def receipt?(_response), do: false

  api(:error?, "Return true if the frame is a server protocol `error`.",
    params: [
      response: [kind: :value, description: "Decoded WS frame"]
    ],
    returns: %{type: :boolean, description: "true for an `error` frame"}
  )

  @spec error?(term()) :: boolean()
  def error?(%{"type" => "error"}), do: true
  def error?(_response), do: false

  api(:need_voucher?, "Return true if the frame is a server `needVoucher` top-up request.",
    params: [
      response: [kind: :value, description: "Decoded WS frame"]
    ],
    returns: %{type: :boolean, description: "true for a `needVoucher` frame"}
  )

  @spec need_voucher?(term()) :: boolean()
  def need_voucher?(%{"type" => "needVoucher"}), do: true
  def need_voucher?(_response), do: false

  api(:voucher_request, "Parse channel and cumulative fields from a `needVoucher` frame.",
    params: [
      response: [kind: :value, description: "Decoded WS `needVoucher` frame"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, request}` or `{:error, :invalid_need_voucher}`"
    },
    errors: [:invalid_need_voucher]
  )

  @spec voucher_request(term()) :: {:ok, map()} | {:error, :invalid_need_voucher}
  def voucher_request(%{
        "type" => "needVoucher",
        "channelId" => channel_id,
        "requiredCumulative" => required,
        "acceptedCumulative" => accepted,
        "deposit" => deposit
      })
      when is_binary(channel_id) and is_binary(required) and is_binary(accepted) and is_binary(deposit) do
    {:ok,
     %{
       channel_id: channel_id,
       required_cumulative: required,
       accepted_cumulative: accepted,
       deposit: deposit
     }}
  end

  def voucher_request(_response), do: {:error, :invalid_need_voucher}
end
