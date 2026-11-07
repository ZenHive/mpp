defmodule MPP.Methods.Tempo.Broadcast do
  @moduledoc false

  # Sends a signed 0x76 transaction and settles an ambiguous send by its
  # receipt (mppx `isAmbiguousBroadcastError` and the bounded receipt wait,
  # refs/mppx/src/tempo/server/Charge.ts:931-1015,1704-1735; mpp-rs
  # `recover_broadcast_receipt`,
  # refs/mpp-rs/src/protocol/methods/tempo/method/transaction_credential.rs:316-330,531-559).
  #
  # A send is ambiguous when the node may have taken the transaction: a
  # transport failure, an HTTP 5xx, a success answer without a usable result,
  # JSON-RPC code 4 (the EIP-7966 timeout for a pooled transaction), or a
  # message saying the node already holds it. Moderato (tempo/v1.18.2, probed
  # 2026-11-07) answers a resend of an included expiring-nonce transaction with
  # -32000 "expiring nonce transaction already included", and answered a sync
  # send with an HTTP 502 for a transaction it went on to mine. "nonce too low"
  # says some transaction used the nonce, so one receipt lookup tells whether
  # it was this one. Every other answer is a definitive rejection.
  #
  # The sync send gets at most two thirds of the confirmation budget; receipt
  # polling runs until the budget ends, or until 2 s after `validBefore` and
  # then one final lookup, because an expired transaction can no longer be
  # included (mppx `confirmationTimeoutMs`).

  alias Onchain.Tempo.RPC

  @ambiguous_message ~r/\balready ?known\b|\bknown transaction\b|\bExpiringNonceReplay\b|\balready included\b/i
  @nonce_used_message ~r/\bnonce too low\b/i
  @eip7966_timeout 4
  @validity_grace_ms 2_000

  @type option ::
          {:req_options, keyword()}
          | {:timeout_ms, pos_integer()}
          | {:interval_ms, pos_integer()}
          | {:valid_before, non_neg_integer() | nil}
          | {:clock, (-> integer()) | nil}

  @doc false
  @spec send_sync(String.t(), String.t(), String.t(), [option()]) ::
          {:ok, String.t(), map()} | {:error, :rejected | :unresolved}
  def send_sync(raw_hex, tx_hash, rpc_url, opts) do
    start = System.monotonic_time(:millisecond)
    timeout = Keyword.fetch!(opts, :timeout_ms)

    case rpc("eth_sendRawTransactionSync", raw_hex, rpc_url, opts[:req_options] || [], div(timeout * 2, 3)) do
      {:ok, %{} = receipt} -> {:ok, receipt["transactionHash"] || tx_hash, RPC.parse_receipt(receipt)}
      {:ok, _malformed} -> poll(tx_hash, rpc_url, opts, start + timeout)
      {:error, :ambiguous} -> poll(tx_hash, rpc_url, opts, start + timeout)
      {:error, :nonce_used} -> lookup_once(tx_hash, rpc_url, opts, :rejected)
      {:error, :rejected} -> {:error, :rejected}
    end
  end

  # Without a receipt wait an ambiguous send is not polled; one lookup still
  # settles a resend of a transaction that is already included.
  @doc false
  @spec send_async(String.t(), String.t(), String.t(), [option()]) ::
          {:ok, String.t()} | {:ok, String.t(), map()} | {:error, :rejected | :unresolved}
  def send_async(raw_hex, tx_hash, rpc_url, opts) do
    case rpc("eth_sendRawTransaction", raw_hex, rpc_url, opts[:req_options] || [], Keyword.fetch!(opts, :timeout_ms)) do
      {:ok, hash} when is_binary(hash) -> {:ok, hash}
      {:ok, _malformed} -> lookup_once(tx_hash, rpc_url, opts, :unresolved)
      {:error, :ambiguous} -> lookup_once(tx_hash, rpc_url, opts, :unresolved)
      {:error, :nonce_used} -> lookup_once(tx_hash, rpc_url, opts, :rejected)
      {:error, :rejected} -> {:error, :rejected}
    end
  end

  # One receipt lookup, bounded by a third of the confirmation budget: the
  # share the sync send leaves for receipt polling.
  @doc false
  @spec lookup(String.t(), String.t(), [option()]) :: {:ok, map()} | :not_found
  def lookup(tx_hash, rpc_url, opts) do
    fetch_receipt(tx_hash, rpc_url, opts, max(div(Keyword.fetch!(opts, :timeout_ms), 3), 1))
  end

  # Whether a node error message says the node already holds the transaction.
  @doc false
  @spec already_held?(String.t()) :: boolean()
  def already_held?(message) when is_binary(message), do: Regex.match?(@ambiguous_message, message)

  defp poll(tx_hash, rpc_url, opts, deadline) do
    valid_until = valid_until(opts)
    stop = min(deadline, monotonic_at(valid_until, opts))
    do_poll(tx_hash, rpc_url, opts, stop, stop < deadline)
  end

  defp do_poll(tx_hash, rpc_url, opts, stop, capped_by_validity?) do
    lookup_budget = max(stop - System.monotonic_time(:millisecond), 1)

    case fetch_receipt(tx_hash, rpc_url, opts, lookup_budget) do
      {:ok, receipt} ->
        {:ok, tx_hash, receipt}

      :not_found ->
        remaining = stop - System.monotonic_time(:millisecond)

        cond do
          remaining > 0 ->
            Process.sleep(min(Keyword.fetch!(opts, :interval_ms), remaining))
            do_poll(tx_hash, rpc_url, opts, stop, capped_by_validity?)

          # A transaction mined just before `validBefore` may only now be visible.
          capped_by_validity? ->
            lookup_once(tx_hash, rpc_url, opts, :unresolved)

          true ->
            {:error, :unresolved}
        end
    end
  end

  # A single lookup outside the polling window gets one poll interval.
  defp lookup_once(tx_hash, rpc_url, opts, miss) do
    case fetch_receipt(tx_hash, rpc_url, opts, Keyword.fetch!(opts, :interval_ms)) do
      {:ok, receipt} -> {:ok, tx_hash, receipt}
      :not_found -> {:error, miss}
    end
  end

  # A lookup failure or overrun is treated like a missing receipt: the outcome
  # stays open.
  defp fetch_receipt(tx_hash, rpc_url, opts, budget_ms) do
    req_options = Keyword.put(opts[:req_options] || [], :receive_timeout, budget_ms)

    case within(budget_ms, fn -> RPC.fetch_receipt(tx_hash, rpc_url, req_options: req_options) end) do
      {:ok, {:ok, receipt}} -> {:ok, receipt}
      _failed_or_late -> :not_found
    end
  end

  # Bounds a whole RPC call, connect and retries included, which a socket
  # receive timeout alone does not (mppx Charge.ts:943-970 `withDeadline`).
  # The call runs in a task, so `$callers` keeps Req.Test stubs reachable; a
  # raise inside it counts as a failed call rather than taking the caller down.
  defp within(budget_ms, fun) do
    task = Task.async(fn -> safely(fun) end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      _raised_or_late -> :timeout
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    # reach:disable-next-line bare_rescue
    exception -> {:raised, exception}
  end

  defp valid_until(opts) do
    case opts[:valid_before] do
      valid_before when is_integer(valid_before) and valid_before > 0 -> valid_before * 1_000 + @validity_grace_ms
      _none -> :infinity
    end
  end

  # Converts a wall-clock deadline (unix ms, on the injected clock) to the
  # monotonic clock the poll loop runs on.
  defp monotonic_at(:infinity, _opts), do: :infinity

  defp monotonic_at(unix_ms, opts) do
    now = if is_function(opts[:clock], 0), do: opts[:clock].(), else: System.os_time(:millisecond)
    System.monotonic_time(:millisecond) + (unix_ms - now)
  end

  # The send is never retried: a resend after a lost answer is the caller's
  # receipt recovery, not a transport retry.
  defp rpc(method, raw_hex, rpc_url, req_options, budget_ms) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => [raw_hex], "id" => 1})
    http = [url: rpc_url, method: :post, headers: [{"content-type", "application/json"}], body: body]
    req_options = Keyword.merge(req_options, receive_timeout: budget_ms, retry: false)

    case within(budget_ms, fn -> Req.request(http, req_options) end) do
      {:ok, response} -> classify_response(response)
      :timeout -> {:error, :ambiguous}
    end
  end

  defp classify_response(response) do
    case response do
      {:ok, %Req.Response{status: status, body: %{"result" => result}}} when status in 200..299 -> {:ok, result}
      {:ok, %Req.Response{status: status}} when status >= 500 -> {:error, :ambiguous}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, classify(error)}
      {:ok, %Req.Response{status: status}} when status in 200..299 -> {:error, :ambiguous}
      {:ok, %Req.Response{}} -> {:error, :rejected}
      {:error, _exception} -> {:error, :ambiguous}
    end
  end

  defp classify(%{"code" => @eip7966_timeout}), do: :ambiguous

  defp classify(%{"message" => message}) when is_binary(message) do
    cond do
      already_held?(message) -> :ambiguous
      Regex.match?(@nonce_used_message, message) -> :nonce_used
      true -> :rejected
    end
  end

  defp classify(_error), do: :rejected
end
