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
    * Reconnect is allowed only before the first payment or voucher. Once
      either has started, any socket-level failure is fatal
      (`:dropped_after_payment`): a new socket would authorize a new
      challenge for work that may already be paid for. Renewed payment
      needs a new `Retry` state, created by the caller deliberately.
    * At most `:max_payments` challenges (default 3, mpp-rs
      `DEFAULT_MAX_PAYMENT_RETRIES`) are paid per connection; the next
      `:pay_started` latches `:payment_limit`.
    * The wait for a receipt is bounded (mpp-rs #756, `ReceiptDeadline` in
      `refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs`). Sending a payment
      credential returns `{:arm_receipt_deadline, ms}`; the first `:data` or
      `:need_voucher` disarms the deadline, because a server may stream data
      and send the receipt at the end. A receipt that does not acknowledge
      the pending payment keeps the payment pending and arms the deadline
      for good: once more from now when it was disarmed, never extending
      one that is running. `:receipt_timeout` while the deadline is armed
      latches `:receipt_timeout`.

  ## Timers are the caller's

  This module holds no timer. On `{:arm_receipt_deadline, ms}` the caller
  starts a timer of `ms` and feeds `:receipt_timeout` when it fires. A caller
  that never does can be held open by a server that stays silent or sends
  receipts for something else.

  The deadline can be armed a second time, so the caller keeps the reference
  of the timer it started last, cancels the earlier one, and feeds
  `:receipt_timeout` only for a message carrying that reference
  (`Process.send_after(self(), {:receipt_timeout, ref}, ms)` with a fresh
  `ref`). A timeout from an earlier timer that is already in the mailbox
  would otherwise end the attempt early. A timeout while no deadline is armed
  is ignored.

  Writes that block while `receipt_deadline_armed?/1` is true are the
  caller's to bound by the same timer.

  ## Receipts

  Feed a receipt frame as `{:receipt, body, challenge}` with the frame's
  decoded `receipt` member and the challenge the pending payment answers.
  A bare `:receipt` settles the credential without a check and is for a
  caller that ran `acknowledges_payment?/2` itself.
  """

  use Descripex, namespace: "/client"

  # refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs:336-339
  @default_max_retries 10
  @default_retry_interval_ms 3_000
  @default_handshake_timeout_ms 30_000

  # refs/mpp-rs/src/client/mod.rs:61 DEFAULT_MAX_PAYMENT_RETRIES
  @default_max_payments 3

  # alloy-pubsub PubSubService::MAX_RECONNECT_RETRY_INTERVAL
  @max_retry_interval_ms 30_000

  # refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs:831-833
  # tungstenite CloseCode::Restart / CloseCode::Again
  @transient_close_codes [1012, 1013]

  @type event ::
          :pay_started
          | :credential_sent
          | :receipt
          | {:receipt, MPP.Receipt.t() | map(), MPP.Challenge.t()}
          | :unacknowledged_receipt
          | :data
          | :receipt_timeout
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

  @type disposition ::
          :continue | {:arm_receipt_deadline, pos_integer()} | {:retry, non_neg_integer()} | {:fatal, atom()}

  @typedoc """
  Where the receipt deadline stands: `:off` (no payment pending),
  `:awaiting_progress` (armed at send), `:progressing` (disarmed by data or
  a voucher request), `:final` (armed by a receipt that acknowledged nothing).
  """
  @type receipt_deadline :: :off | :awaiting_progress | :progressing | :final

  @type t :: %__MODULE__{
          max_retries: pos_integer(),
          max_payments: pos_integer(),
          retry_interval_ms: pos_integer(),
          handshake_timeout_ms: pos_integer(),
          attempts: non_neg_integer(),
          pay_count: non_neg_integer(),
          vouchers_started?: boolean(),
          fatal?: boolean(),
          fatal_reason: atom() | nil,
          payment_in_flight?: boolean(),
          voucher_in_flight?: boolean(),
          awaiting_receipt?: boolean(),
          receipt_deadline: receipt_deadline()
        }

  defstruct max_retries: @default_max_retries,
            max_payments: @default_max_payments,
            retry_interval_ms: @default_retry_interval_ms,
            handshake_timeout_ms: @default_handshake_timeout_ms,
            attempts: 0,
            pay_count: 0,
            vouchers_started?: false,
            fatal?: false,
            fatal_reason: nil,
            payment_in_flight?: false,
            voucher_in_flight?: false,
            awaiting_receipt?: false,
            receipt_deadline: :off

  api(:new, "Build a retry state with mpp-rs / alloy-transport-mpp defaults.",
    params: [
      opts: [
        kind: :value,
        description: "Optional :max_retries, :max_payments, :retry_interval_ms, :handshake_timeout_ms"
      ]
    ],
    returns: %{type: :struct, description: "`MPP.Client.Transport.WebSocket.Retry` state"}
  )

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    struct!(__MODULE__,
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      max_payments: Keyword.get(opts, :max_payments, @default_max_payments),
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

  def transition(%__MODULE__{pay_count: count, max_payments: max} = state, :pay_started) when count >= max do
    latch(state, :payment_limit)
  end

  def transition(%__MODULE__{} = state, :pay_started) do
    if should_pay?(state) do
      {:continue, %{state | payment_in_flight?: true, pay_count: state.pay_count + 1}}
    else
      latch(state, :payment_retry_refused)
    end
  end

  # A payment credential arms the deadline; a voucher leaves it as it stands
  # (mpp-rs resets it only where the payment becomes pending).
  def transition(%__MODULE__{payment_in_flight?: true} = state, :credential_sent) do
    {{:arm_receipt_deadline, state.handshake_timeout_ms},
     %{
       state
       | payment_in_flight?: false,
         voucher_in_flight?: false,
         awaiting_receipt?: true,
         receipt_deadline: :awaiting_progress
     }}
  end

  def transition(%__MODULE__{} = state, :credential_sent) do
    {:continue, %{state | payment_in_flight?: false, voucher_in_flight?: false, awaiting_receipt?: true}}
  end

  # A receipt frame whose body is not an object is a protocol error
  # (refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs handle_text Receipt).
  def transition(%__MODULE__{} = state, {:receipt, receipt, _challenge}) when not is_map(receipt) do
    latch(state, :malformed_frame)
  end

  # Only a pending payment needs an acknowledgement; the deadline is off
  # exactly when none is pending, and then any receipt settles the credential.
  def transition(%__MODULE__{receipt_deadline: :off} = state, {:receipt, _receipt, _challenge}) do
    transition(state, :receipt)
  end

  def transition(%__MODULE__{} = state, {:receipt, receipt, challenge}) do
    if acknowledges_payment?(receipt, challenge),
      do: transition(state, :receipt),
      else: transition(state, :unacknowledged_receipt)
  end

  # A receipt settles the sent credential. Provider work still running keeps
  # its in-flight flag, so it cannot be started a second time.
  def transition(%__MODULE__{} = state, :receipt) do
    {:continue, %{state | awaiting_receipt?: false, receipt_deadline: :off}}
  end

  def transition(%__MODULE__{receipt_deadline: :progressing} = state, :unacknowledged_receipt) do
    {{:arm_receipt_deadline, state.handshake_timeout_ms}, %{state | receipt_deadline: :final}}
  end

  def transition(%__MODULE__{receipt_deadline: :awaiting_progress} = state, :unacknowledged_receipt) do
    {:continue, %{state | receipt_deadline: :final}}
  end

  def transition(%__MODULE__{} = state, :unacknowledged_receipt), do: {:continue, state}

  def transition(%__MODULE__{} = state, :data), do: {:continue, progress(state)}

  def transition(%__MODULE__{receipt_deadline: deadline} = state, :receipt_timeout)
      when deadline in [:awaiting_progress, :final] do
    latch(state, :receipt_timeout)
  end

  def transition(%__MODULE__{} = state, :receipt_timeout), do: {:continue, state}

  def transition(%__MODULE__{voucher_in_flight?: true} = state, :need_voucher) do
    latch(state, :second_voucher_in_flight)
  end

  def transition(%__MODULE__{} = state, :need_voucher) do
    {:continue, progress(%{state | voucher_in_flight?: true, vouchers_started?: true})}
  end

  def transition(%__MODULE__{payment_in_flight?: true} = state, :challenge) do
    latch(state, :second_challenge_in_flight)
  end

  def transition(%__MODULE__{awaiting_receipt?: true} = state, :challenge) do
    {:continue, %{state | awaiting_receipt?: false, receipt_deadline: :off}}
  end

  def transition(%__MODULE__{} = state, :challenge), do: {:continue, state}

  def transition(%__MODULE__{} = state, :handshake_timeout), do: latch(state, :handshake_timeout)
  def transition(%__MODULE__{} = state, :provider_error), do: latch(state, :provider_error)
  # The server rejected whatever was pending.
  def transition(%__MODULE__{} = state, :server_error) do
    latch(%{state | awaiting_receipt?: false, receipt_deadline: :off}, :server_error)
  end

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
      description:
        "false when fatal, a pay or voucher is in flight, a receipt is outstanding, or the per-connection payment cap is reached"
    }
  )

  @spec should_pay?(t()) :: boolean()
  def should_pay?(%__MODULE__{} = state) do
    not state.fatal? and not state.payment_in_flight? and not state.voucher_in_flight? and
      not state.awaiting_receipt? and state.pay_count < state.max_payments
  end

  api(:receipt_deadline_armed?, "Return true while the receipt deadline can fire.",
    params: [
      state: [kind: :value, description: "Retry state"]
    ],
    returns: %{
      type: :boolean,
      description:
        "true from a sent payment credential until data or a voucher request, and after a receipt that acknowledged nothing"
    }
  )

  @spec receipt_deadline_armed?(t()) :: boolean()
  def receipt_deadline_armed?(%__MODULE__{fatal?: false, receipt_deadline: deadline}),
    do: deadline in [:awaiting_progress, :final]

  def receipt_deadline_armed?(%__MODULE__{}), do: false

  api(
    :acknowledges_payment?,
    "Return true if a receipt is the server's acceptance of the payment made for a challenge: status `success`, a `reference`, and the challenge's method.",
    params: [
      receipt: [kind: :value, description: "`MPP.Receipt` or the receipt frame's decoded JSON object"],
      challenge: [kind: :value, description: "The challenge the pending payment answers"]
    ],
    returns: %{
      type: :boolean,
      description: "false for a failed status, another method, or anything that is not a receipt"
    }
  )

  # refs/mpp-rs/crates/alloy-transport-mpp/src/ws.rs acknowledges_payment
  @spec acknowledges_payment?(term(), MPP.Challenge.t()) :: boolean()
  def acknowledges_payment?(%MPP.Receipt{} = receipt, challenge) do
    acknowledges_payment?(
      %{"status" => receipt.status, "reference" => receipt.reference, "method" => receipt.method},
      challenge
    )
  end

  def acknowledges_payment?(
        %{"status" => "success", "reference" => reference, "method" => method},
        %MPP.Challenge{} = challenge
      )
      when is_binary(reference) and is_binary(method) and is_binary(challenge.method) do
    String.downcase(method, :ascii) == String.downcase(challenge.method, :ascii)
  end

  def acknowledges_payment?(_receipt, _challenge), do: false

  api(:reconnect?, "Return true if a socket-level reconnect is still allowed.",
    params: [
      state: [kind: :value, description: "Retry state"]
    ],
    returns: %{
      type: :boolean,
      description: "false when fatal, the retry budget is exhausted, or a payment or voucher has started"
    }
  )

  @spec reconnect?(t()) :: boolean()
  def reconnect?(%__MODULE__{} = state) do
    not state.fatal? and state.attempts < state.max_retries and state.pay_count == 0 and
      not state.vouchers_started?
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

  defp progress(%__MODULE__{receipt_deadline: :awaiting_progress} = state), do: %{state | receipt_deadline: :progressing}
  defp progress(state), do: state

  defp latch(state, reason) do
    {{:fatal, reason},
     %{state | fatal?: true, fatal_reason: reason, payment_in_flight?: false, voucher_in_flight?: false}}
  end

  defp transient(%__MODULE__{pay_count: count, vouchers_started?: vouchers?} = state) when count > 0 or vouchers? do
    latch(state, :dropped_after_payment)
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
