defmodule MPP.Transports.WebSocket do
  @moduledoc """
  Server-side WebSocket adapter for JSON-RPC plus MPP payment challenges.

  Consumers bring their own WebSocket library (Bandit, Cowboy, …). This
  module speaks decoded text frames — `open/1` and `handle_text/2` return
  JSON strings ready to push.

  Payment challenges ride on the subscription handshake: `open/1` emits a
  `challenge` frame before application traffic. The client answers with a
  `credential` frame (`Payment <base64url>`). A successful verify yields a
  `receipt` frame; JSON-RPC then travels in `message` frames.

  Wire format matches mpp-rs `server::ws` / `alloy-transport-mpp`
  (`refs/mpp-rs/src/server/ws.rs`,
  `refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs`):

    * Client → server: `credential`, `message`
    * Server → client: `challenge`, `message`, `needVoucher`, `receipt`, `error`
  """

  use Descripex, namespace: "/transports"

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Plug
  alias MPP.Plug.Config
  alias MPP.Transports.JsonRpc
  alias MPP.Transports.JsonRpc.Adapter
  alias MPP.Transports.WebSocket.Frame

  @type status :: :open | :authorized

  @type t :: %__MODULE__{
          config: Config.t(),
          handler: (map() -> term()),
          status: status(),
          challenge: Challenge.t() | nil
        }

  @enforce_keys [:config, :handler]
  defstruct [:config, :handler, status: :open, challenge: nil]

  api(:init, "Build a WebSocket session from the same endpoint options as `MPP.Plug`, plus a JSON-RPC `:handler`.",
    params: [
      opts: [
        kind: :value,
        description: "Keyword options including :handler, :secret_key, :realm, and one or more payment methods"
      ]
    ],
    returns: %{type: :struct, description: "`MPP.Transports.WebSocket` session"}
  )

  @spec init(keyword()) :: t()
  def init(opts) when is_list(opts) do
    {handler, plug_opts} = Keyword.pop(opts, :handler)

    if !is_function(handler, 1) do
      raise ArgumentError, "MPP.Transports.WebSocket requires :handler (arity-1 function)"
    end

    %__MODULE__{config: JsonRpc.init(plug_opts), handler: handler}
  end

  api(:open, "Emit the subscription-handshake challenge frame for a newly accepted socket.",
    params: [
      session: [kind: :value, description: "Session from init/1"]
    ],
    returns: %{type: :tuple, description: "`{session, [json_text]}` — push the texts as WebSocket text frames"}
  )

  @spec open(t()) :: {t(), [String.t()]}
  def open(%__MODULE__{} = session) do
    challenge = handshake_challenge(session)
    frame = Frame.challenge_frame(challenge)
    {%{session | challenge: challenge, status: :open}, [Frame.encode(frame)]}
  end

  api(:handle_text, "Handle one inbound WebSocket text frame and return outbound frames to push.",
    params: [
      text: [kind: :value, description: "Raw WebSocket text payload"],
      session: [kind: :value, description: "Current session"]
    ],
    returns: %{type: :tuple, description: "`{session, [json_text]}`"}
  )

  @spec handle_text(String.t(), t()) :: {t(), [String.t()]}
  def handle_text(text, %__MODULE__{} = session) when is_binary(text) do
    case Frame.decode(text) do
      {:ok, frame} ->
        {session, replies} = handle_frame(frame, session)
        {session, Enum.map(replies, &Frame.encode/1)}

      {:error, :malformed_frame} ->
        {session, [Frame.encode(Frame.error_frame("malformed MPP frame"))]}

      {:error, :unknown_frame} ->
        {session, [Frame.encode(Frame.error_frame("unknown MPP frame"))]}
    end
  end

  api(:handle_frame, "Handle one already-decoded MPP frame map.",
    params: [
      frame: [kind: :value, description: "Decoded frame map with a `type` discriminator"],
      session: [kind: :value, description: "Current session"]
    ],
    returns: %{type: :tuple, description: "`{session, [frame_map]}`"}
  )

  @spec handle_frame(map(), t()) :: {t(), [map()]}
  def handle_frame(%{"type" => "credential"} = frame, %__MODULE__{} = session) do
    handle_credential(frame, session)
  end

  def handle_frame(%{"type" => "message"} = frame, %__MODULE__{} = session) do
    handle_message(frame, session)
  end

  def handle_frame(%{"type" => _other}, %__MODULE__{} = session) do
    {session, [Frame.error_frame("unexpected MPP frame")]}
  end

  api(:decode_frame, "Parse a WebSocket text payload into an MPP frame map.",
    params: [
      text: [kind: :value, description: "Raw WebSocket text payload"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, frame}` or `{:error, :malformed_frame | :unknown_frame}`"
    },
    errors: [:malformed_frame, :unknown_frame]
  )

  @spec decode_frame(String.t()) :: {:ok, map()} | {:error, :malformed_frame | :unknown_frame}
  def decode_frame(text) when is_binary(text), do: Frame.decode(text)

  api(:encode_frame, "Serialize an MPP frame map to a WebSocket text payload.",
    params: [
      frame: [kind: :value, description: "Frame map with a `type` discriminator"]
    ],
    returns: %{type: :string, description: "JSON text"}
  )

  @spec encode_frame(map()) :: String.t()
  def encode_frame(%{} = frame), do: Frame.encode(frame)

  api(:challenge_frame, "Build a server `challenge` frame from an `MPP.Challenge`.",
    params: [
      challenge: [kind: :value, description: "Challenge struct"],
      error: [kind: :value, description: "Optional error string carried next to the challenge"]
    ],
    returns: %{type: :map, description: "Frame map"}
  )

  @spec challenge_frame(Challenge.t(), String.t() | nil) :: map()
  def challenge_frame(%Challenge{} = challenge, error \\ nil), do: Frame.challenge_frame(challenge, error)

  api(:need_voucher_frame, "Build a server `needVoucher` frame for a session top-up.",
    params: [
      attrs: [kind: :value, description: "Map or keyword with channelId/requiredCumulative/acceptedCumulative/deposit"]
    ],
    returns: %{type: :map, description: "Frame map"}
  )

  @spec need_voucher_frame(keyword() | map()) :: map()
  def need_voucher_frame(attrs), do: Frame.need_voucher_frame(attrs)

  api(:receipt_frame, "Build a server `receipt` frame.",
    params: [
      receipt: [kind: :value, description: "Receipt map as sent on the wire"]
    ],
    returns: %{type: :map, description: "Frame map"}
  )

  @spec receipt_frame(map()) :: map()
  def receipt_frame(%{} = receipt), do: Frame.receipt_frame(receipt)

  api(:error_frame, "Build a server `error` frame.",
    params: [
      error: [kind: :value, description: "Error message"]
    ],
    returns: %{type: :map, description: "Frame map"}
  )

  @spec error_frame(String.t()) :: map()
  def error_frame(error) when is_binary(error), do: Frame.error_frame(error)

  api(:message_frame, "Build a server `message` frame wrapping a JSON-RPC payload as a JSON string.",
    params: [
      data: [kind: :value, description: "JSON-RPC envelope, or an already-encoded JSON string"]
    ],
    returns: %{type: :map, description: "Frame map"}
  )

  @spec message_frame(term()) :: map()
  def message_frame(data), do: Frame.message_frame(data)

  defp handle_credential(%{"credential" => authorization}, session) when is_binary(authorization) do
    case Headers.parse_credential(authorization) do
      {:ok, %Credential{} = credential} ->
        verify_and_receipt(session, credential)

      {:error, reason} ->
        {session, [Frame.error_frame("malformed credential: #{reason}")]}
    end
  end

  defp handle_credential(_frame, session) do
    {session, [Frame.error_frame("malformed credential")]}
  end

  defp handle_message(frame, %{status: :authorized} = session) do
    case Frame.unwrap_message_data(frame) do
      {:ok, request} when is_map(request) ->
        response = dispatch_rpc(session, request)
        {session, [Frame.message_frame(response)]}

      {:ok, _other} ->
        {session, [Frame.error_frame("malformed JSON-RPC payload")]}

      {:error, :malformed_frame} ->
        {session, [Frame.error_frame("malformed MPP frame")]}
    end
  end

  defp handle_message(_frame, session) do
    {challenge, session} = ensure_challenge(session)
    {session, [Frame.challenge_frame(challenge)]}
  end

  defp verify_and_receipt(session, credential) do
    request =
      JsonRpc.attach_credential(
        %{
          "jsonrpc" => "2.0",
          "id" => "mpp.ws.handshake",
          "method" => "mpp.ws.handshake",
          "params" => []
        },
        credential
      )

    case JsonRpc.call(request, session.config, fn _req -> %{"ok" => true} end) do
      %{"error" => error} ->
        {session, [Frame.error_frame(error["message"] || "payment verification failed")]}

      %{"_meta" => meta} ->
        receipt = Map.get(meta, JsonRpc.receipt_meta_key(), %{})
        {%{session | status: :authorized}, [Frame.receipt_frame(receipt)]}
    end
  end

  defp dispatch_rpc(%{handler: handler}, request) do
    request
    |> handler.()
    |> Adapter.wrap_handler_response(request)
  end

  defp ensure_challenge(%{challenge: %Challenge{} = challenge} = session), do: {challenge, session}

  defp ensure_challenge(session) do
    challenge = handshake_challenge(session)
    {challenge, %{session | challenge: challenge}}
  end

  defp handshake_challenge(%{config: %Config{} = config}) do
    [entry | _] = config.method_entries
    Plug.generate_challenge(config, entry)
  end
end
