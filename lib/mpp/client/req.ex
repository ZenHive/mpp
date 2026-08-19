defmodule MPP.Client.Req do
  @moduledoc """
  Payment-aware Req plugin.

  Intercepts HTTP 402 responses, selects a challenge through
  `MPP.Client.SelectionPolicy`, pays via `MPP.Client.MultiProvider`, and retries
  with `Authorization: Payment`. Non-402 responses pass through unchanged.

      Req.new()
      |> MPP.Client.Req.attach(provider: my_provider)
      |> Req.get(url: "https://api.example.com/resource")

  This is the Elixir counterpart of mpp-rs `PaymentExt` and mppx `Fetch.from()`.
  """

  use Descripex, namespace: "/client"

  alias MPP.Client.AcceptPolicy
  alias MPP.Client.MultiProvider
  alias MPP.Client.SelectionPolicy
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
      used as the default ranking policy
    * `:accept_policy` — `MPP.Client.AcceptPolicy.t()` gating header injection
      (default `:always`)
    * `:max_payment_retries` — payment attempts after a 402 (default 3)
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, opts) when is_list(opts) do
    config = build_config(opts)

    request
    |> Req.Request.put_private(:mpp_client, config)
    |> Req.Request.append_request_steps(mpp_accept_payment: &put_accept_payment/1)
    |> Req.Request.append_response_steps(mpp_payment: &handle_payment/1)
  end

  defp build_config(opts) do
    accept_payment = Keyword.get(opts, :accept_payment, [])
    max_retries = Keyword.get(opts, :max_payment_retries, @default_max_payment_retries)

    if !(is_integer(max_retries) and max_retries >= 0) do
      raise ArgumentError, "MPP.Client.Req.attach/2 :max_payment_retries must be a non-negative integer"
    end

    %{
      provider: normalize_provider(Keyword.get(opts, :provider)),
      selection: selection_from_opts(opts, accept_payment),
      accept_payment: accept_payment,
      accept_policy: Keyword.get(opts, :accept_policy, AcceptPolicy.default()),
      max_retries: max_retries
    }
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

      policy ->
        policy
    end
  end

  defp put_accept_payment(request) do
    config = Req.Request.get_private(request, :mpp_client)

    HTTP.set_accept_payment_from_providers(
      request,
      accept_payment_pairs(config.accept_payment),
      config.accept_policy
    )
  end

  defp accept_payment_pairs(entries) when is_list(entries) do
    Enum.map(entries, fn
      {method, intent, _q} -> {method, intent}
      %{method: method, intent: intent} -> {method, intent}
    end)
  end

  defp handle_payment({request, response}) do
    config = Req.Request.get_private(request, :mpp_client)
    retries = Req.Request.get_private(request, :mpp_payment_retries, 0)

    cond do
      not HTTP.payment_required?(response) ->
        {request, response}

      retries >= config.max_retries ->
        {request, response}

      true ->
        pay_and_retry(request, response, config, retries)
    end
  end

  defp pay_and_retry(request, response, config, retries) do
    with {:ok, challenges} <- fetch_challenges(response, retries),
         {:ok, challenge} <- select_or_passthrough(challenges, config, retries, response),
         {:ok, credential} <- MultiProvider.pay(config.provider, challenge) do
      request
      |> HTTP.set_credential(credential)
      |> Req.Request.put_private(:mpp_payment_retries, retries + 1)
      |> then(fn paid -> Req.Request.run_request(%{paid | halted: false}) end)
      |> then(fn {paid, result} -> Req.Request.halt(paid, result) end)
    else
      {:passthrough, passthrough_response} ->
        {request, passthrough_response}

      {:error, reason} ->
        Req.Request.halt(request, %Error{reason: reason, message: error_message(reason)})
    end
  end

  defp fetch_challenges(response, retries) do
    case HTTP.get_challenges(response) do
      {:ok, challenges} -> {:ok, challenges}
      {:error, _reason} when retries > 0 -> {:passthrough, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_or_passthrough(challenges, config, retries, response) do
    case SelectionPolicy.select(challenges, config.provider, config.selection) do
      {:ok, challenge} -> {:ok, challenge}
      {:error, :no_supported_challenge} when retries > 0 -> {:passthrough, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_message(:no_supported_challenge), do: "no configured provider supports the offered payment challenges"

  defp error_message(reason), do: "MPP payment failed: #{inspect(reason)}"
end
