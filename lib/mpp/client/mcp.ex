defmodule MPP.Client.MCP do
  @moduledoc """
  Payment-aware MCP client orchestration.

  Wraps a JSON-RPC send function: if the response is payment-required
  (`-32042` or payment-required result metadata), or a `-32043` re-challenge
  carrying a non-empty challenge list, selects a challenge through
  `MPP.Client.SelectionPolicy`, asks `on_payment_required` for approval, pays
  via `MPP.Client.MultiProvider`, and retries the original request with the
  credential attached.

  Total payment attempts per `call/4` are bounded at **two**: the initial
  `-32042` payment plus at most one re-payment on a `-32043` that carries
  challenges. A `-32043` without challenges surfaces immediately. This is a
  deliberate divergence from mppx `maxPaymentAttempts = 3`
  (`refs/mppx/src/mcp/client/McpClient.ts`) so a malicious server cannot drain
  a client wallet through repeated re-challenges.

  Approval runs **after** challenge selection and **before** each payment —
  matching `refs/mppx/src/mcp/client/McpClient.ts`. A declined approval neither
  pays nor retries.

      client = MPP.Client.MCP.new(provider: my_provider)
      MPP.Client.MCP.call(client, request, &MyTransport.send/1)
  """

  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.SelectionPolicy
  alias MPP.Client.Transport
  alias MPP.Client.Transport.MCP, as: MCPTransport

  # Initial `-32042` payment + at most one `-32043` re-challenge. mppx uses 3
  # (`maxPaymentAttempts` in refs/mppx/src/mcp/client/McpClient.ts); we stay at 2.
  @max_payment_attempts 2

  @type approval :: (Challenge.t() -> boolean())

  @type t :: %__MODULE__{
          provider: MultiProvider.t(),
          selection: SelectionPolicy.t(),
          on_payment_required: approval() | nil
        }

  @enforce_keys [:provider]
  defstruct provider: nil, selection: SelectionPolicy.default(), on_payment_required: nil

  api(:new, "Build a payment-aware MCP client from provider and policy options.",
    params: [
      opts: [
        kind: :value,
        description: "Keyword options. Required: `:provider`. See new/1."
      ]
    ],
    returns: %{type: :struct, description: "MPP.Client.MCP struct"}
  )

  @doc """
  Build a payment-aware MCP client.

  ## Options

    * `:provider` — required. An `MPP.Client.MultiProvider`, a `{module, config}`
      tuple, or a provider module
    * `:selection` — `MPP.Client.SelectionPolicy.t()`. Defaults to
      `:server_order`, or `{:accept_payment, entries}` when `:accept_payment` is
      set
    * `:accept_payment` — preference entries used as the default ranking policy
    * `:on_payment_required` — `(MPP.Challenge.t() -> boolean())` invoked after
      challenge selection and before payment. Omitted or `nil` auto-approves.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      provider: normalize_provider!(Keyword.get(opts, :provider)),
      selection: selection_from_opts(opts),
      on_payment_required: approval_from_opts(opts, :new)
    }
  end

  api(:call, "Send a JSON-RPC request, paying at most twice (`-32042` plus one `-32043` re-challenge).",
    params: [
      client: [kind: :value, description: "MPP.Client.MCP struct from new/1"],
      request: [kind: :value, description: "JSON-RPC request map"],
      send_fun: [
        kind: :value,
        description: "Arity-1 function that sends the request and returns a JSON-RPC response map"
      ],
      opts: [
        kind: :value,
        description: "Optional `:on_payment_required` override; pass `nil` to bypass the configured hook"
      ]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, response}` or `{:error, reason}`"
    },
    errors: [:payment_declined, :no_supported_challenge, :malformed_envelope, :no_challenges, :invalid_challenge]
  )

  @doc """
  Send `request` through `send_fun`, paying on `-32042` and at most once more
  on a `-32043` that carries challenges.

  `send_fun` receives the JSON-RPC request map and must return a JSON-RPC
  response map. Per-call `:on_payment_required` overrides the client hook;
  pass `nil` to bypass it (mppx `onPaymentRequired: null`). The approval hook
  fires on every payment. After two payment attempts the terminal response is
  returned as-is.
  """
  @spec call(t(), map(), (map() -> term()), keyword()) :: {:ok, map()} | {:error, term()}
  def call(%__MODULE__{} = client, %{} = request, send_fun, opts \\ []) when is_function(send_fun, 1) and is_list(opts) do
    hook = approval_for_call(client, opts)

    case send_fun.(request) do
      response when is_map(response) ->
        handle_response(client, request, response, send_fun, hook, 0)

      _other ->
        {:error, :malformed_envelope}
    end
  end

  defp handle_response(client, request, response, send_fun, hook, payments_made) do
    if payments_made < @max_payment_attempts and payable?(response, payments_made) do
      pay_and_continue(client, request, response, send_fun, hook, payments_made)
    else
      {:ok, response}
    end
  end

  defp payable?(response, 0) do
    MCPTransport.payment_required?(response) or MCPTransport.rechallenge?(response)
  end

  defp payable?(response, _payments_made), do: MCPTransport.rechallenge?(response)

  defp pay_and_continue(client, request, response, send_fun, hook, payments_made) do
    with {:ok, challenges} <- MCPTransport.get_challenges(response),
         {:ok, challenge} <- Transport.select_challenge(challenges, client.provider, selection: client.selection),
         :ok <- approve(challenge, hook),
         {:ok, credential} <- MultiProvider.pay(client.provider, challenge) do
      case request |> MCPTransport.set_credential(credential) |> send_fun.() do
        next when is_map(next) ->
          handle_response(client, request, next, send_fun, hook, payments_made + 1)

        _other ->
          {:error, :malformed_envelope}
      end
    end
  end

  defp approve(_challenge, nil), do: :ok

  defp approve(challenge, hook) when is_function(hook, 1) do
    case hook.(challenge) do
      true -> :ok
      false -> {:error, :payment_declined}
      other -> raise ArgumentError, "on_payment_required must return a boolean, got: #{inspect(other)}"
    end
  end

  defp approval_for_call(client, opts) do
    if Keyword.has_key?(opts, :on_payment_required) do
      approval_from_opts(opts, :call)
    else
      client.on_payment_required
    end
  end

  defp approval_from_opts(opts, context) do
    case Keyword.get(opts, :on_payment_required) do
      nil ->
        nil

      fun when is_function(fun, 1) ->
        fun

      other ->
        where = if context == :new, do: "new/1", else: "call/4"

        raise ArgumentError,
              "MPP.Client.MCP.#{where} :on_payment_required must be an arity-1 function or nil, got: #{inspect(other)}"
    end
  end

  defp normalize_provider!(%MultiProvider{} = multi), do: multi

  defp normalize_provider!({module, config}) when is_atom(module) and is_map(config) do
    MultiProvider.new([{module, config}])
  end

  defp normalize_provider!(module) when is_atom(module) and not is_nil(module) do
    MultiProvider.new([{module, %{}}])
  end

  defp normalize_provider!(_other) do
    raise ArgumentError,
          "MPP.Client.MCP.new/1 requires :provider (MultiProvider, {module, config}, or module)"
  end

  defp selection_from_opts(opts) do
    case Keyword.get(opts, :selection) do
      nil ->
        case Keyword.get(opts, :accept_payment, []) do
          [] -> SelectionPolicy.default()
          entries when is_list(entries) -> {:accept_payment, entries}
        end

      :server_order ->
        :server_order

      {:accept_payment, entries} = policy when is_list(entries) ->
        policy

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError, "MPP.Client.MCP.new/1 :selection is invalid, got: #{inspect(other)}"
    end
  end
end
