defmodule MPP.Client.Transport.WebSocket.Retry do
  @moduledoc """
  Reconnect and payment-retry policy for MPP-over-WebSocket.

  Matches `alloy-transport-mpp` `MppWsConnect` plus alloy-pubsub's reconnect
  loop (`refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs`,
  alloy `crates/pubsub/src/service.rs`):

    * Socket-level failures are transient and reconnect with capped
      exponential backoff (base 3s, cap 30s, max 10 attempts).
    * Deterministic MPP failures are fatal and latch — later `connect()`
      equivalents must not retry and must not pay again.
    * A drop after a credential was sent and before the receipt is fatal,
      so a rejected or half-open socket cannot amplify payment retries.
    * A second challenge while a payment is in flight is fatal.
    * A second `needVoucher` while a voucher is in flight is fatal
      (`refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs` handle_text
      NeedVoucher). Sending the voucher sets `credential_awaiting_receipt`.
    * Close codes `1012` (Restart) and `1013` (Try Again Later) are the
      only non-fatal close codes, and only when no credential is awaiting
      a receipt.
  """

  use Descripex, namespace: "/client"

  # refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs:336-339
  @default_max_retries 10
  @default_retry_interval_ms 3_000
  @default_handshake_timeout_ms 30_000

  # alloy-pubsub PubSubService::MAX_RECONNECT_RETRY_INTERVAL
  @max_retry_interval_ms 30_000

  # refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs:831-833
  # tungstenite CloseCode::Restart / CloseCode::Again
  @transient_close_codes [1012, 1013]

  @type event ::
          :pay_started
          | :credential_sent
          | :receipt
          | :challenge
          | :need_voucher
          | :handshake_timeout
          | :provider_error
          | :server_error
          | :malformed_frame
          | :binary_frame
          | :connection_dropped
          | :server_gone
          | {:socket_error, term()}
          | {:close, non_neg_integer() | nil}

  @type disposition :: :continue | {:retry, non_neg_integer()} | {:fatal, atom()}

  @type t :: %__MODULE__{
          max_retries: pos_integer(),
          retry_interval_ms: pos_integer(),
          handshake_timeout_ms: pos_integer(),
          attempts: non_neg_integer(),
          pay_count: non_neg_integer(),
          fatal?: boolean(),
          fatal_reason: atom() | nil,
          payment_in_flight?: boolean(),
          voucher_in_flight?: boolean(),
          awaiting_receipt?: boolean()
        }

  defstruct max_retries: @default_max_retries,
            retry_interval_ms: @default_retry_interval_ms,
            handshake_timeout_ms: @default_handshake_timeout_ms,
            attempts: 0,
            pay_count: 0,
            fatal?: false,
            fatal_reason: nil,
            payment_in_flight?: false,
            voucher_in_flight?: false,
            awaiting_receipt?: false

  api(:new, "Build a retry state with mpp-rs / alloy-transport-mpp defaults.",
    params: [
      opts: [
        kind: :value,
        description: "Optional :max_retries, :retry_interval_ms, :handshake_timeout_ms"
      ]
    ],
    returns: %{type: :struct, description: "`MPP.Client.Transport.WebSocket.Retry` state"}
  )

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    struct!(__MODULE__,
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      retry_interval_ms: Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms),
      handshake_timeout_ms: Keyword.get(opts, :handshake_timeout_ms, @default_handshake_timeout_ms)
    )
  end

  api(:transition, "Apply a connection or payment event and return the next disposition plus updated state.",
    params: [
      state: [kind: :value, description: "Retry state"],
      event: [kind: :value, description: "Lifecycle event"]
    ],
    returns: %{type: :tuple, description: "`{disposition, state}`"}
  )

  @spec transition(t(), event()) :: {disposition(), t()}
  def transition(%__MODULE__{fatal?: true, fatal_reason: reason} = state, _event) do
    {{:fatal, reason}, state}
  end

  def transition(%__MODULE__{} = state, :pay_started) do
    if should_pay?(state) do
      {:continue, %{state | payment_in_flight?: true, pay_count: state.pay_count + 1}}
    else
      latch(state, :payment_retry_refused)
    end
  end

  def transition(%__MODULE__{} = state, :credential_sent) do
    {:continue, %{state | payment_in_flight?: false, voucher_in_flight?: false, awaiting_receipt?: true}}
  end

  def transition(%__MODULE__{} = state, :receipt) do
    {:continue, %{state | awaiting_receipt?: false, payment_in_flight?: false, voucher_in_flight?: false}}
  end

  def transition(%__MODULE__{voucher_in_flight?: true} = state, :need_voucher) do
    latch(state, :second_voucher_in_flight)
  end

  def transition(%__MODULE__{} = state, :need_voucher) do
    {:continue, %{state | voucher_in_flight?: true}}
  end

  def transition(%__MODULE__{payment_in_flight?: true} = state, :challenge) do
    latch(state, :second_challenge_in_flight)
  end

  def transition(%__MODULE__{awaiting_receipt?: true} = state, :challenge) do
    {:continue, %{state | awaiting_receipt?: false}}
  end

  def transition(%__MODULE__{} = state, :challenge), do: {:continue, state}

  def transition(%__MODULE__{} = state, :handshake_timeout), do: latch(state, :handshake_timeout)
  def transition(%__MODULE__{} = state, :provider_error), do: latch(state, :provider_error)
  def transition(%__MODULE__{} = state, :server_error), do: latch(state, :server_error)
  def transition(%__MODULE__{} = state, :malformed_frame), do: latch(state, :malformed_frame)
  def transition(%__MODULE__{} = state, :binary_frame), do: latch(state, :binary_frame)

  def transition(%__MODULE__{awaiting_receipt?: true} = state, :connection_dropped) do
    latch(state, :dropped_awaiting_receipt)
  end

  def transition(%__MODULE__{awaiting_receipt?: true} = state, :server_gone) do
    latch(state, :dropped_awaiting_receipt)
  end

  def transition(%__MODULE__{awaiting_receipt?: true} = state, {:socket_error, _reason}) do
    latch(state, :dropped_awaiting_receipt)
  end

  def transition(%__MODULE__{awaiting_receipt?: true} = state, {:close, _code}) do
    latch(state, :dropped_awaiting_receipt)
  end

  def transition(%__MODULE__{} = state, {:close, code}) do
    if transient_close?(code) do
      transient(state)
    else
      latch(state, :fatal_close)
    end
  end

  def transition(%__MODULE__{} = state, :connection_dropped), do: transient(state)
  def transition(%__MODULE__{} = state, :server_gone), do: transient(state)
  def transition(%__MODULE__{} = state, {:socket_error, _reason}), do: transient(state)

  api(:should_pay?, "Return true if a payment may be created for the current socket.",
    params: [
      state: [kind: :value, description: "Retry state"]
    ],
    returns: %{
      type: :boolean,
      description: "false when fatal, a pay or voucher is in flight, or a receipt is outstanding"
    }
  )

  @spec should_pay?(t()) :: boolean()
  def should_pay?(%__MODULE__{} = state) do
    not state.fatal? and not state.payment_in_flight? and not state.voucher_in_flight? and
      not state.awaiting_receipt?
  end

  api(:reconnect?, "Return true if a socket-level reconnect is still allowed.",
    params: [
      state: [kind: :value, description: "Retry state"]
    ],
    returns: %{type: :boolean, description: "false when fatal or the retry budget is exhausted"}
  )

  @spec reconnect?(t()) :: boolean()
  def reconnect?(%__MODULE__{} = state) do
    not state.fatal? and state.attempts < state.max_retries
  end

  api(:delay_ms, "Capped exponential reconnect delay for the current attempt count.",
    params: [
      state: [kind: :value, description: "Retry state after a transient failure has incremented attempts"]
    ],
    returns: %{type: :integer, description: "Delay in milliseconds"}
  )

  @spec delay_ms(t()) :: non_neg_integer()
  def delay_ms(%__MODULE__{retry_interval_ms: base, attempts: attempts}) do
    reconnect_retry_interval(base, max(attempts, 1))
  end

  api(:handshake_timeout_ms, "Per-phase handshake / pay timeout in milliseconds.",
    params: [
      state: [kind: :value, description: "Retry state"]
    ],
    returns: %{type: :integer, description: "Timeout in milliseconds"}
  )

  @spec handshake_timeout_ms(t()) :: pos_integer()
  def handshake_timeout_ms(%__MODULE__{handshake_timeout_ms: timeout}), do: timeout

  @doc "Return true for close codes that may reconnect (`1012` Restart, `1013` Again)."
  @spec transient_close?(non_neg_integer() | nil) :: boolean()
  def transient_close?(code) when code in @transient_close_codes, do: true
  def transient_close?(_code), do: false

  defp latch(state, reason) do
    {{:fatal, reason},
     %{state | fatal?: true, fatal_reason: reason, payment_in_flight?: false, voucher_in_flight?: false}}
  end

  defp transient(state) do
    attempts = state.attempts + 1
    next = %{state | attempts: attempts, payment_in_flight?: false, voucher_in_flight?: false}

    if attempts >= state.max_retries do
      latch(next, :max_retries)
    else
      {{:retry, reconnect_retry_interval(state.retry_interval_ms, attempts)}, next}
    end
  end

  # alloy-pubsub reconnect_retry_interval: 1-based attempt, 2^(n-1) * base, cap 30s
  # unless the configured base is already higher.
  defp reconnect_retry_interval(base, retry_count) do
    multiplier = backoff_multiplier(retry_count)
    max_interval = max(base, @max_retry_interval_ms)
    min(base * multiplier, max_interval)
  end

  defp backoff_multiplier(retry_count) when retry_count <= 1, do: 1
  defp backoff_multiplier(retry_count) when retry_count > 31, do: 0xFFFFFFFF
  defp backoff_multiplier(retry_count), do: Bitwise.bsl(1, retry_count - 1)
end
