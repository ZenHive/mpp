defmodule MPP.Client.Req.PaidSend do
  @moduledoc false
  # Req adapter around the adapter of a request that carries a credential.
  # A send that ends without a verdict ends the request: no later step may
  # turn it into something that is paid again or reads as an answer.

  alias MPP.Client.PaymentOutcomeUnknownError

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    adapter = Req.Request.get_private(request, :mpp_adapter)
    answered = {__MODULE__, make_ref()}

    {request, result} =
      try do
        send_with(adapter, watch_into(request, answered))
      rescue
        # A failure before the server answered leaves the payment outcome open.
        # reach:disable-next-line bare_rescue
        error -> if Process.get(answered), do: reraise(error, __STACKTRACE__), else: {request, error}
      catch
        kind, value ->
          if Process.get(answered), do: :erlang.raise(kind, value, __STACKTRACE__), else: {request, {kind, value}}
      after
        Process.delete(answered)
      end

    case result do
      %Req.Response{status: status} = response when status >= 500 -> unknown(request, response: response)
      %Req.Response{} = response -> {request, response}
      cause -> unknown(request, cause: cause)
    end
  end

  # A streaming callback runs inside the adapter, in this process. Once it was
  # handed an answer below 500, a failure is the consumer's, not the send's.
  defp watch_into(%Req.Request{into: into} = request, answered) when is_function(into, 2) do
    watched = fn chunk, {_request, response} = acc ->
      if match?(%Req.Response{status: status} when status < 500, response), do: Process.put(answered, true)
      into.(chunk, acc)
    end

    %{request | into: watched}
  end

  defp watch_into(request, _answered), do: request

  defp send_with(adapter, request) when is_atom(adapter), do: adapter.run(request)
  defp send_with(adapter, request) when is_function(adapter, 1), do: adapter.(request)

  defp unknown(request, fields) do
    {provider, credential} = Req.Request.get_private(request, :mpp_paid_send)
    error = PaymentOutcomeUnknownError.new(provider, credential, fields)
    {%{request | response_steps: [], error_steps: []}, error}
  end
end

defmodule MPP.Client.Req.RecordSend do
  @moduledoc false
  # Req adapter that records the Accept-Payment header of the request as it is
  # handed to the adapter that sends it, after every request step ran.

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    sent = {:sent, header(request)}
    adapter = Req.Request.get_private(request, :mpp_send_adapter)

    # Recorded on the request the adapter returns, which response steps receive.
    {request, result} = send_with(adapter, request)
    {Req.Request.put_private(request, :mpp_sent_accept_payment, sent), result}
  end

  # Repeated field lines combine into one list (RFC 9110 §5.3).
  @doc false
  @spec header(Req.Request.t()) :: String.t() | nil
  def header(%Req.Request{} = request) do
    case Req.Request.get_header(request, "accept-payment") do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp send_with(adapter, request) when is_atom(adapter), do: adapter.run(request)
  defp send_with(adapter, request) when is_function(adapter, 1), do: adapter.(request)
end

defmodule MPP.Client.Req do
  @moduledoc """
  Payment-aware Req plugin.

  Intercepts HTTP 402 responses, selects a challenge through
  `MPP.Client.SelectionPolicy`, pays via `MPP.Client.MultiProvider`, and retries
  with `Authorization: Payment` (or `Payment-Authorization` when the challenge
  advertised `header`). Non-402 responses pass through unchanged.

      Req.new()
      |> MPP.Client.Req.attach(provider: my_provider)
      |> Req.get(url: "https://api.example.com/resource")

  This is the Elixir counterpart of mpp-rs `PaymentExt` and mppx `Fetch.from()`.

  A 402 that arrives after a redirect changed the request origin is refused
  (`:cross_origin_redirect`) so a payment credential is never attached to a
  different host, scheme, or port than the caller asked for (mpp-rs #379).
  A request whose method is not GET or HEAD is not paid once Req followed a
  redirect for it, even back to the same URL: it is refused
  (`:redirected_request`) before any payment (mppx `Fetch.ts` `response.redirected`, mpp-rs `flow.rs`).

  The request that carries the payment credential never follows redirects: a
  3xx answer to the paid retry is returned to the caller as-is, whichever header
  holds the credential (mppx `redirect: 'manual'`, mpp-rs redirect-safe client).

  When the request that carries the credential is answered 5xx, or fails
  without a response, the result is `{:error, %MPP.Client.PaymentOutcomeUnknownError{}}`
  with the challenge, the credential, the transaction hash when the provider
  can derive it, and the response or the cause. The payment may have settled,
  and the plugin does not pay again. Req's `:retry` is off for that request,
  and no response or error step runs on such a result: the response is the
  one the adapter returned. mppx reports the
  same condition to `payment.failed` observers and hands the caller the 5xx
  response.

  An `Accept-Payment` header the caller set on the request is sent as is and
  chooses the challenge: it ranks the offers and excludes those it matches only
  with `q=0`, in place of `:accept_payment` and an `:accept_payment` or
  `:server_order` `:selection`. A `:selection` function then orders the offers
  the header left. A request whose own header is empty or malformed is not paid:
  the result is `{:error, %MPP.Client.Req.Error{reason: :invalid_accept_payment}}`
  (as mpp-rs, which refuses to pay; mppx would select by the attach/2 config
  instead).

  The header that counts is the one handed to the adapter, after every request
  step ran; a response step that changes it afterwards does not. A request
  step appended after this plugin's that replaces the adapter hides that
  header, and the 402 is not paid:
  `{:error, %MPP.Client.Req.Error{reason: :unrecorded_accept_payment}}`.
  `:accept_payment` entries that do not format to a header `MPP.AcceptPayment.parse/1`
  reads back raise `ArgumentError` in `attach/2`. A header
  equal to the one this plugin injected from `:accept_payment` is read as the
  injection: the `:selection` orders the offers, but an offer that header does
  not accept (unlisted or `q=0`) is never paid, also under `:server_order` or
  a `:selection` function. With no header sent, selection uses the attach/2
  config.

  The request URL is passed to the provider as `:request_url` (see
  `MPP.Client.MultiProvider.pay/3`), so a zero-amount Tempo proof is signed
  only for a realm the requested server owns
  (`MPP.Client.Providers.Tempo`, `:trusted_tempo_proof_realms`).
  """

  use Descripex, namespace: "/client"

  alias MPP.AcceptPayment
  alias MPP.Client.AcceptPolicy
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentLimitExceededError
  alias MPP.Client.Req.PaidSend
  alias MPP.Client.Req.RecordSend
  alias MPP.Client.SelectionPolicy
  alias MPP.Client.Spend
  alias MPP.Client.Transport
  alias MPP.Client.Transport.HTTP

  @default_max_payment_retries 3

  defmodule Error do
    @moduledoc """
    Returned when payment-aware retry cannot complete a 402 challenge.
    """

    defexception [:reason, :message]

    @type t :: %__MODULE__{reason: term(), message: String.t() | nil}

    @impl Exception
    @spec message(t()) :: String.t()
    def message(%__MODULE__{message: message}) when is_binary(message), do: message

    def message(%__MODULE__{reason: reason}) do
      "MPP payment failed: #{inspect(reason)}"
    end
  end

  api(:attach, "Attach payment-aware 402 handling to a Req pipeline.",
    params: [
      request: [kind: :value, description: "Req.Request struct"],
      opts: [
        kind: :value,
        description: "Keyword options. Required: `:provider`. See attach/2."
      ]
    ],
    returns: %{type: :struct, description: "Req.Request with payment steps attached"}
  )

  @doc """
  Attach payment-aware 402 handling to a Req pipeline.

  ## Options

    * `:provider` — required. An `MPP.Client.MultiProvider`, a `{module, config}`
      tuple, or a provider module
    * `:selection` — `MPP.Client.SelectionPolicy.t()`. Defaults to
      `:server_order`, or `{:accept_payment, entries}` when `:accept_payment` is
      set
    * `:accept_payment` — preference entries advertised on outgoing requests and
      used as the default ranking policy. `q` values are preserved on the wire
    * `:accept_policy` — `MPP.Client.AcceptPolicy.t()` gating header injection
      (default `:always`)
    * `:max_payment_retries` — payment attempts after a 402 (default 3)
      A 402 of problem type `invalid-challenge` that answers a request carrying
      a credential, one this plugin sent or one the caller attached, is returned
      as final: the payment behind the credential may already be settled
    * `:on_payment_required` — `(MPP.Challenge.t() -> boolean())` invoked after
      a challenge is selected and before `pay/2`. The hook fires on every
      payment. `nil` (default) skips approval.
    * `:max_payment`, `:budget`, `:tokens` — spending limits, see
      `MPP.Client.Spend`. A selected challenge is checked against
      `:max_payment` before the approval hook runs, and its amount is reserved
      in the `:budget` before the provider is asked for a credential. A
      refused payment is `{:error, %MPP.Client.PaymentLimitExceededError{}}`.
      While either is set, only `charge` challenges are paid.
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, opts) when is_list(opts) do
    config = build_config(opts)

    request
    |> Req.Request.put_private(:mpp_client, config)
    |> Req.Request.append_request_steps(
      mpp_origin: &snapshot_origin/1,
      mpp_accept_payment: &put_accept_payment/1,
      mpp_record_send: &record_send/1
    )
    |> Req.Request.append_response_steps(mpp_payment: &handle_payment/1)
  end

  defp build_config(opts) do
    accept_payment = opts |> Keyword.get(:accept_payment, []) |> validate_accept_payment()
    max_retries = Keyword.get(opts, :max_payment_retries, @default_max_payment_retries)

    if !(is_integer(max_retries) and max_retries >= 0) do
      raise ArgumentError, "MPP.Client.Req.attach/2 :max_payment_retries must be a non-negative integer"
    end

    %{
      provider: normalize_provider(Keyword.get(opts, :provider)),
      selection: selection_from_opts(opts, accept_payment),
      accept_payment: accept_payment,
      accept_policy: Keyword.get(opts, :accept_policy, AcceptPolicy.default()),
      max_retries: max_retries,
      on_payment_required: approval_from_opts(opts),
      spend: Spend.new(opts)
    }
  end

  # The injected header is read back at selection time, so it must parse: an
  # entry outside the token grammar or a header over the parse limit would
  # otherwise be sent and then refuse every payment.
  defp validate_accept_payment([]), do: []

  defp validate_accept_payment(entries) when is_list(entries) do
    if AcceptPayment.parse(AcceptPayment.format(entries)) == [] do
      raise ArgumentError,
            "MPP.Client.Req.attach/2 :accept_payment does not format to a parseable Accept-Payment header " <>
              "(lowercase method and intent tokens, at most 16 KiB)"
    end

    entries
  end

  defp normalize_provider(%MultiProvider{} = multi), do: multi

  defp normalize_provider({module, config}) when is_atom(module) and is_map(config) do
    MultiProvider.new([{module, config}])
  end

  defp normalize_provider(module) when is_atom(module) and not is_nil(module) do
    MultiProvider.new([{module, %{}}])
  end

  defp normalize_provider(_other) do
    raise ArgumentError,
          "MPP.Client.Req.attach/2 requires :provider (MultiProvider, {module, config}, or module)"
  end

  defp selection_from_opts(opts, accept_payment) do
    case Keyword.get(opts, :selection) do
      nil ->
        case accept_payment do
          [] -> SelectionPolicy.default()
          entries -> {:accept_payment, entries}
        end

      :server_order ->
        :server_order

      {:accept_payment, entries} = policy when is_list(entries) ->
        policy

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError, "MPP.Client.Req.attach/2 :selection is invalid, got: #{inspect(other)}"
    end
  end

  # Request steps rerun on every redirect hop, so only the first run records
  # the caller's request.
  defp snapshot_origin(request) do
    case Req.Request.get_private(request, :mpp_request_origin) do
      nil ->
        request
        |> Req.Request.put_private(:mpp_request_origin, origin(request.url))
        |> Req.Request.put_private(:mpp_request_target, {request.method, redirect_count(request)})

      _existing ->
        request
    end
  end

  # A later request step can still change the header, or replace it on a
  # reused request, and a response step can change it after the answer, so
  # selection reads what `RecordSend` saw at the adapter. A later step that
  # replaced the adapter leaves no record, and then what the server was sent is
  # unknown: nothing is paid.
  defp sent_accept_payment(request) do
    case Req.Request.get_private(request, :mpp_sent_accept_payment) do
      {:sent, header} -> {:ok, header}
      nil -> {:error, :unrecorded_accept_payment}
    end
  end

  # Whatever header was sent, its exclusions bind: the server read it. A header
  # other than the one this plugin injected is the caller's and also orders the
  # offers in place of the attach/2 config, as in
  # refs/mpp-rs/src/client/flow.rs:207 and
  # refs/mppx/src/client/internal/Fetch.ts:1377-1395. An empty or malformed one
  # refuses payment, as mpp-rs does (flow.rs:181-189 `payment_allowed`); mppx
  # falls back to the config (Fetch.ts:1391), which could pay an offer the
  # caller's broken header was meant to exclude.
  defp selection_for(request, config) do
    case sent_accept_payment(request) do
      {:ok, nil} ->
        {:ok, config.selection}

      {:ok, sent} ->
        injected? = sent == Req.Request.get_private(request, :mpp_injected_accept_payment)

        case AcceptPayment.parse(sent) do
          [] -> {:error, :invalid_accept_payment}
          entries -> {:ok, header_selection(entries, config.selection, injected?)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp header_selection(entries, selection, injected?) do
    fn supported ->
      ranked = AcceptPayment.rank(supported, entries)
      left = if injected?, do: Enum.filter(supported, &(&1 in ranked)), else: ranked
      order_left(left, selection, injected?)
    end
  end

  # A function sees only what the header left, and may return only that.
  defp order_left(left, fun, _injected?) when is_function(fun, 1) do
    case fun.(left) do
      ordered when is_list(ordered) -> Enum.filter(ordered, &(&1 in left))
      _other -> []
    end
  end

  defp order_left(left, {:accept_payment, [_ | _] = entries}, true), do: AcceptPayment.rank(left, entries)
  defp order_left(left, _selection, _injected?), do: left

  defp put_accept_payment(request) do
    config = Req.Request.get_private(request, :mpp_client)

    if config.accept_payment == [] or RecordSend.header(request) != nil or
         not AcceptPolicy.allows?(config.accept_policy, request.url) do
      request
    else
      value = AcceptPayment.format(config.accept_payment)

      request
      |> Req.Request.put_header("accept-payment", value)
      |> Req.Request.put_private(:mpp_injected_accept_payment, value)
    end
  end

  # Request steps rerun on redirect hops and on the paid retry; the adapter is
  # wrapped once, and `PaidSend` wraps this wrapper.
  defp record_send(%Req.Request{adapter: adapter} = request) when adapter in [RecordSend, PaidSend] do
    Req.Request.put_private(request, :mpp_sent_accept_payment, nil)
  end

  defp record_send(%Req.Request{adapter: adapter} = request) do
    recording =
      request
      |> Req.Request.put_private(:mpp_send_adapter, adapter)
      |> Req.Request.put_private(:mpp_sent_accept_payment, nil)

    %{recording | adapter: RecordSend}
  end

  defp handle_payment({request, response}) do
    config = Req.Request.get_private(request, :mpp_client)
    retries = Req.Request.get_private(request, :mpp_payment_retries, 0)

    cond do
      not HTTP.payment_required?(response) ->
        {request, response}

      # The payment behind a sent credential may already be settled; paying the
      # fresh challenge would pay twice (mppx client/internal/Fetch.ts).
      (retries > 0 or HTTP.credential?(request)) and HTTP.invalid_challenge?(response) ->
        {request, response}

      retries >= config.max_retries ->
        {request, response}

      true ->
        pay_and_retry(request, response, config, retries)
    end
  end

  defp pay_and_retry(request, response, config, retries) do
    with :ok <- ensure_same_origin(request),
         :ok <- ensure_not_redirected(request),
         {:ok, selection} <- selection_for(request, config),
         {:ok, challenges} <- fetch_challenges(request, response, retries),
         {:ok, challenge} <- select_or_passthrough(challenges, config.provider, selection, retries, response),
         {:ok, _requirement} <- Spend.check(config.spend, challenge),
         :ok <- Transport.approve(challenge, config.on_payment_required),
         {:ok, credential} <- Spend.pay(config.spend, config.provider, challenge, %{request_url: request.url}) do
      paid =
        request
        |> HTTP.set_credential(credential)
        |> disable_redirects()
        # A resend could be answered with a fresh challenge and be paid again.
        |> Req.Request.put_option(:retry, false)
        |> Req.Request.put_private(:mpp_payment_retries, retries + 1)
        |> Req.Request.put_private(:mpp_paid_send, {config.provider, credential})
        |> observe_paid_send_last()

      {paid, result} = Req.Request.run_request(%{paid | halted: false})
      Req.Request.halt(paid, result)
    else
      {:passthrough, passthrough_response} ->
        {request, passthrough_response}

      {:error, %PaymentLimitExceededError{} = refused} ->
        Req.Request.halt(request, refused)

      {:error, reason} ->
        Req.Request.halt(request, %Error{reason: reason, message: error_message(reason)})
    end
  end

  # After every other request step, so that it wraps the adapter they chose.
  defp observe_paid_send_last(%Req.Request{request_steps: steps} = request) do
    %{request | request_steps: Keyword.delete(steps, :mpp_paid_send) ++ [mpp_paid_send: &observe_paid_send/1]}
  end

  defp observe_paid_send(%Req.Request{adapter: PaidSend} = request), do: request

  defp observe_paid_send(%Req.Request{adapter: adapter} = request) do
    %{Req.Request.put_private(request, :mpp_adapter, adapter) | adapter: PaidSend}
  end

  # Req's redirect step lets the legacy `:follow_redirects` option override
  # `:redirect`, so both must be cleared.
  defp disable_redirects(request) do
    request
    |> Req.Request.delete_option(:follow_redirects)
    |> Req.Request.put_option(:redirect, false)
  end

  defp ensure_same_origin(request) do
    original = Req.Request.get_private(request, :mpp_request_origin)
    current = origin(request.url)

    if is_nil(original) or original == current do
      :ok
    else
      {:error, :cross_origin_redirect}
    end
  end

  # Req rewrites a redirected POST (301/302) or any non-GET/HEAD (303) to a
  # bodyless GET, also on a redirect back to the same URL. Req counts every hop
  # in `:req_redirect_count` (mppx checks `response.redirected`, `Fetch.ts`).
  # The paid retry never follows redirects, so only the first 402 can get here
  # redirected.
  defp ensure_not_redirected(request) do
    case Req.Request.get_private(request, :mpp_request_target) do
      {method, hops} ->
        if safe_method?(method) or redirect_count(request) == hops, do: :ok, else: {:error, :redirected_request}

      nil ->
        :ok
    end
  end

  defp redirect_count(request), do: Req.Request.get_private(request, :req_redirect_count, 0)

  # Req keeps `method:` as given, so `"POST"` and `:POST` reach here too.
  defp safe_method?(method), do: Enum.member?(["get", "head"], String.downcase(to_string(method)))

  defp origin(%URI{} = uri) do
    host = if is_binary(uri.host), do: String.downcase(uri.host)
    port = uri.port
    scheme = uri.scheme

    default_port? =
      is_nil(port) or
        (scheme == "https" and port == 443) or
        (scheme == "http" and port == 80)

    if default_port? do
      {scheme, host}
    else
      {scheme, host, port}
    end
  end

  defp fetch_challenges(request, response, retries) do
    case HTTP.get_challenges(response, URI.to_string(request.url)) do
      {:ok, challenges} -> {:ok, challenges}
      {:error, _reason} when retries > 0 -> {:passthrough, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approval_from_opts(opts) do
    case Keyword.get(opts, :on_payment_required) do
      nil ->
        nil

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError,
              "MPP.Client.Req.attach/2 :on_payment_required must be an arity-1 function or nil, got: #{inspect(other)}"
    end
  end

  defp select_or_passthrough(challenges, provider, selection, retries, response) do
    case SelectionPolicy.select(challenges, provider, selection) do
      {:ok, challenge} -> {:ok, challenge}
      {:error, :no_supported_challenge} when retries > 0 -> {:passthrough, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_message(:no_supported_challenge), do: "no configured provider supports the offered payment challenges"

  defp error_message(:legacy_unicode_escape),
    do: "refusing to pay: the server escaped a bound challenge parameter as \\uXXXX; upgrade the server"

  defp error_message(:cross_origin_redirect), do: "refusing to send payment credential across a cross-origin redirect"

  defp error_message(:redirected_request),
    do: "refusing to pay for a non-GET/HEAD request after Req followed a redirect for it"

  defp error_message(:invalid_accept_payment),
    do: "refusing to pay: the request's Accept-Payment header is empty or malformed"

  defp error_message(:unrecorded_accept_payment),
    do: "refusing to pay: the Accept-Payment header sent is unknown because a later request step replaced the adapter"

  defp error_message(:payment_declined), do: "payment was declined by on_payment_required"

  defp error_message(:challenge_expired), do: "refusing to pay an expired challenge under a spending limit"

  defp error_message({:untrusted_proof_realm, realm, origin}) do
    "refusing to sign a Tempo proof for realm #{inspect(realm)} from #{origin}; " <>
      "pin it with :trusted_tempo_proof_realms if this server issues it"
  end

  defp error_message(reason), do: "MPP payment failed: #{inspect(reason)}"
end
