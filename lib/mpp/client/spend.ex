defmodule MPP.Client.Spend do
  @moduledoc """
  Client spending limits, checked after a challenge is selected and before any
  provider creates a credential (mppx `client/internal/SpendGate.ts`).

  `MPP.Client.Req.attach/2` and `MPP.Client.MCP.new/1` take the options and run
  the checks; `new/1`, `check/2` and `pay/4` are the same steps for a caller
  that drives a transport itself.

  ## Options

    * `:max_payment` — most one payment may cost. Either money,
      `{"0.50", "USD"}`, or per-asset limits in atomic units,
      `[%{network: "eip155:4217", asset: "0x20c0…", amount: 500_000}]`
    * `:budget` — a running `MPP.Client.Budget` (pid or registered name) that
      caps what payments spend in total
    * `:tokens` — the assets a money limit or money budget may count, with the
      currency and decimals the client vouches for:
      `[%{network: "eip155:4217", asset: "0x20c0…", currency: "USD", decimals: 6}]`

  ## What is compared

  A payment is the selected challenge's `amount` (atomic units, splits
  included) of its `currency` on a network. The network is
  `eip155:<methodDetails.chainId>` when the challenge names a chain, the
  network of an x402 offer, and the method name otherwise (`"stripe"`,
  `"solana"`).

  A money limit converts with the decimals from `:tokens` only. The challenge
  is server data: a server that names another currency or sends other decimals
  cannot change what a limit counts. A payment in an asset `:tokens` does not
  list is refused. Digits of a money value beyond a token's decimals are
  dropped, which only lowers the limit.

  While any limit or budget is set, only `charge` challenges are paid, and the
  provider is paid with `spend_checked: true` in its config: it must debit the
  challenge's currency and nothing else. `MPP.Client.Providers.Tempo` then pays
  a `machineTokenEnabled` charge as a plain transfer, never through the MACH
  route (mppx `tempo/client/Charge.ts`), and refuses a charge that names no
  chain. An expired challenge is refused as `{:error, :challenge_expired}`.

  A provider that moves funds while it creates the credential and then cannot
  finish returns `{:error, %MPP.Client.PaymentOutcomeUnknownError{}}`; the
  budget counts that payment as spent. Any other provider error frees the
  reservation.
  """

  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.Budget
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentLimitExceededError
  alias MPP.Client.PaymentOutcomeUnknownError
  alias MPP.Client.Spend.Units
  alias MPP.Codec
  alias MPP.X402

  @charge_intent "charge"
  @max_decimal_length 1_024

  @typedoc ~s(Money in a reference currency: `{"0.50", "USD"}`.)
  @type money :: {String.t(), String.t()}

  @typedoc "An amount of one asset on one network, in atomic units."
  @type asset_limit :: %{network: String.t(), asset: String.t(), amount: non_neg_integer()}

  @typedoc "An asset whose currency and decimals the client vouches for."
  @type token :: %{network: String.t(), asset: String.t(), currency: String.t(), decimals: 0..255}

  @typedoc """
  What a selected challenge asks for. `:currency` and `:decimals` are set only
  when `:tokens` lists the asset.
  """
  @type requirement :: %{
          method: String.t(),
          intent: String.t(),
          network: String.t(),
          asset: String.t(),
          amount: non_neg_integer(),
          currency: String.t() | nil,
          decimals: 0..255 | nil
        }

  @type t :: %__MODULE__{
          max_payment: nil | {:money, String.t(), String.t()} | {:assets, %{optional(term()) => non_neg_integer()}},
          budget: GenServer.server() | nil,
          tokens: %{optional(term()) => {String.t(), 0..255}}
        }

  defstruct max_payment: nil, budget: nil, tokens: %{}

  api(:new, "Validate client spending options into a spend gate, or nil when none is set.",
    params: [opts: [kind: :value, description: "Keyword list with `:max_payment`, `:budget`, `:tokens`"]],
    returns: %{type: :struct, description: "MPP.Client.Spend struct, or nil without a limit or budget"}
  )

  @doc """
  Build the spend gate from `:max_payment`, `:budget` and `:tokens`; other keys
  are ignored. Returns `nil` when neither a limit nor a budget is set. Raises
  `ArgumentError` on a malformed option.
  """
  @spec new(keyword()) :: t() | nil
  def new(opts) when is_list(opts) do
    max_payment = max_payment!(Keyword.get(opts, :max_payment))
    budget = budget!(Keyword.get(opts, :budget))
    tokens = tokens!(Keyword.get(opts, :tokens, []))

    if max_payment || budget do
      %__MODULE__{max_payment: max_payment, budget: budget, tokens: tokens}
    end
  end

  api(:check, "Check a selected challenge against the per-payment limit before approval and payment.",
    params: [
      spend: [kind: :value, description: "MPP.Client.Spend struct or nil"],
      challenge: [kind: :value, description: "Selected MPP.Challenge"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, requirement | nil}`, `{:error, PaymentLimitExceededError}` or `{:error, :challenge_expired}`"
    },
    errors: [:challenge_expired],
    composes_with: [:pay]
  )

  @doc """
  Check `challenge` against the gate: it must be a `charge` that has not
  expired, its terms must be readable, and it must fit `:max_payment`. Returns
  what the challenge asks for; `{:ok, nil}` when `spend` is `nil`. Run it
  before asking anyone to approve the payment; `pay/4` checks again.
  """
  @spec check(t() | nil, Challenge.t()) ::
          {:ok, requirement() | nil} | {:error, PaymentLimitExceededError.t() | :challenge_expired}
  def check(nil, %Challenge{}), do: {:ok, nil}

  def check(%__MODULE__{} = spend, %Challenge{} = challenge) do
    limit = if spend.max_payment, do: :max_payment, else: :budget

    with :ok <- charge_only(challenge),
         :ok <- unexpired(challenge.expires),
         {:ok, requirement} <- requirement(challenge, spend.tokens),
         :ok <- within(requirement, spend.max_payment) do
      {:ok, requirement}
    else
      {:error, :challenge_expired} -> {:error, :challenge_expired}
      {:error, reason} -> {:error, %PaymentLimitExceededError{limit: limit, reason: reason}}
    end
  end

  api(:pay, "Check a challenge and pay it through a MultiProvider, reserving and settling the budget around it.",
    params: [
      spend: [kind: :value, description: "MPP.Client.Spend struct or nil"],
      multi: [kind: :value, description: "MPP.Client.MultiProvider struct"],
      challenge: [kind: :value, description: "Selected MPP.Challenge"],
      context: [kind: :value, description: "Transport context map passed to MultiProvider.pay/3"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, credential}` or `{:error, reason}`"},
    errors: [:challenge_expired],
    composes_with: [:check]
  )

  @doc """
  Pay `challenge` through `multi`. The challenge is checked again here, so what
  is counted is always what this gate reads from this challenge. With a budget,
  its amount is reserved first; the reservation is committed once the provider
  returns a credential and released when the provider returns an error. It
  stays committed when the provider raises, exits or throws, or returns
  `{:error, %MPP.Client.PaymentOutcomeUnknownError{}}`: a budget never
  undercounts.
  """
  @spec pay(t() | nil, MultiProvider.t(), Challenge.t(), map()) :: {:ok, MPP.Credential.t()} | {:error, term()}
  def pay(nil, %MultiProvider{} = multi, %Challenge{} = challenge, context) when is_map(context) do
    MultiProvider.pay(multi, challenge, context)
  end

  def pay(%__MODULE__{} = spend, %MultiProvider{} = multi, %Challenge{} = challenge, context) when is_map(context) do
    # Checked again here: waiting for the budget may have outlasted the challenge.
    pay = fn ->
      with :ok <- unexpired(challenge.expires) do
        MultiProvider.pay(multi, challenge, Map.put(context, :spend_checked, true))
      end
    end

    with {:ok, requirement} <- check(spend, challenge) do
      reserve_and_pay(spend.budget, requirement, pay)
    end
  end

  defp reserve_and_pay(nil, _requirement, pay), do: pay.()

  defp reserve_and_pay(budget, requirement, pay) do
    case Budget.reserve(budget, requirement) do
      {:ok, reservation} -> settle(budget, reservation, pay)
      {:error, reason} -> {:error, %PaymentLimitExceededError{limit: :budget, reason: reason}}
    end
  end

  defp settle(budget, reservation, pay) do
    result = pay.()

    case result do
      {:ok, _credential} -> settled(budget, reservation, :commit)
      # Funds may have moved although no credential came back.
      {:error, %PaymentOutcomeUnknownError{}} -> settled(budget, reservation, :commit)
      _error -> settled(budget, reservation, :release)
    end

    result
  catch
    kind, value ->
      settled(budget, reservation, :commit)
      :erlang.raise(kind, value, __STACKTRACE__)
  end

  # A budget that ended has nothing left to count; the payment's own result stands.
  defp settled(budget, reservation, how) do
    apply(Budget, how, [budget, reservation])
  catch
    :exit, _reason -> :ok
  end

  defp charge_only(%Challenge{intent: @charge_intent}), do: :ok
  defp charge_only(%Challenge{}), do: {:error, :intent}

  # An expired challenge cannot be paid, so nothing is approved or reserved for it.
  defp unexpired(nil), do: :ok

  defp unexpired(expires) when is_binary(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, at, _offset} -> if DateTime.after?(at, DateTime.utc_now()), do: :ok, else: {:error, :challenge_expired}
      {:error, _reason} -> {:error, :challenge}
    end
  end

  defp unexpired(_other), do: {:error, :challenge}

  defp within(_requirement, nil), do: :ok

  defp within(requirement, {:assets, limits}) do
    case Map.fetch(limits, Units.asset_key(requirement.network, requirement.asset)) do
      {:ok, limit} when requirement.amount <= limit -> :ok
      {:ok, _limit} -> {:error, :amount}
      :error -> {:error, :asset}
    end
  end

  defp within(%{currency: nil}, {:money, _value, _currency}), do: {:error, :asset}

  defp within(requirement, {:money, value, currency}) do
    cond do
      requirement.currency != currency -> {:error, :asset}
      requirement.amount > Units.parse_units(value, requirement.decimals) -> {:error, :amount}
      true -> :ok
    end
  end

  # mppx SpendGate.ts `requirement`: currency and decimals come from `:tokens` only.
  defp requirement(challenge, tokens) do
    with {:ok, fields} <- fields(challenge) do
      {currency, decimals} = Map.get(tokens, Units.asset_key(fields.network, fields.asset), {nil, nil})

      {:ok,
       Map.merge(fields, %{
         method: challenge.method,
         intent: challenge.intent,
         currency: currency,
         decimals: decimals
       })}
    end
  end

  defp fields(challenge) do
    if X402.synthetic?(challenge), do: x402_fields(challenge), else: mpp_fields(challenge)
  end

  defp x402_fields(challenge) do
    with {:ok, %{"network" => network, "asset" => asset, "amount" => amount}} <- X402.exact_request(challenge),
         {:ok, amount} <- atomic_amount(amount) do
      {:ok, %{network: network, asset: asset, amount: amount}}
    else
      _unreadable -> {:error, :challenge}
    end
  end

  # mppx SpendGate.ts `mppFields`. Methods sign on `methodDetails.chainId`; a
  # top-level `chainId` it does not match could mean another chain.
  defp mpp_fields(challenge) do
    with {:ok, %{} = request} <- Codec.decode_base64_json(challenge.request),
         details = method_details(request),
         {:ok, chain_id} <- chain_id(Map.fetch(details, "chainId")),
         true <- not Map.has_key?(request, "chainId") or request["chainId"] == chain_id,
         # Stripe pays by currency alone, so a chain would only pick another limit.
         true <- is_nil(chain_id) or challenge.method != "stripe",
         asset when is_binary(asset) and asset != "" <- request["currency"],
         {:ok, amount} <- atomic_amount(request["amount"]) do
      network = if chain_id, do: "eip155:#{chain_id}", else: challenge.method
      {:ok, %{network: network, asset: asset, amount: amount}}
    else
      _unreadable -> {:error, :challenge}
    end
  end

  defp method_details(%{"methodDetails" => %{} = details}), do: details
  defp method_details(_request), do: %{}

  defp chain_id(:error), do: {:ok, nil}
  defp chain_id({:ok, chain_id}) when is_integer(chain_id) and chain_id > 0, do: {:ok, chain_id}
  defp chain_id({:ok, _other}), do: :error

  # As the signers read it: any string of digits, leading zeroes included.
  defp atomic_amount(value) when is_binary(value) and byte_size(value) in 1..@max_decimal_length do
    if value =~ ~r/\A\d+\z/, do: {:ok, String.to_integer(value)}, else: :error
  end

  defp atomic_amount(_value), do: :error

  defp max_payment!(nil), do: nil

  defp max_payment!(limits) when is_list(limits) do
    assets =
      Enum.reduce(limits, %{}, fn limit, acc ->
        %{network: network, asset: asset, amount: amount} = Units.asset_limit!(limit, ":max_payment limit")
        key = Units.asset_key(network, asset)
        if Map.has_key?(acc, key), do: raise(ArgumentError, "duplicate :max_payment limit for #{asset}")
        Map.put(acc, key, amount)
      end)

    {:assets, assets}
  end

  defp max_payment!(money) do
    {value, currency} = Units.money!(money, ":max_payment")
    {:money, value, currency}
  end

  defp budget!(nil), do: nil
  defp budget!(budget) when is_pid(budget) or is_atom(budget), do: budget
  defp budget!({:via, _module, _name} = budget), do: budget
  defp budget!({:global, _name} = budget), do: budget

  defp budget!(other) do
    raise ArgumentError, ":budget must be a running MPP.Client.Budget (pid or name), got: #{inspect(other)}"
  end

  defp tokens!(tokens) when is_list(tokens) do
    Enum.reduce(tokens, %{}, fn token, acc ->
      {key, metadata} = token!(token)

      case acc do
        %{^key => other} when other != metadata ->
          raise ArgumentError, ":tokens configure conflicting metadata for #{token.asset}"

        _free ->
          Map.put(acc, key, metadata)
      end
    end)
  end

  defp tokens!(other), do: raise(ArgumentError, ":tokens must be a list, got: #{inspect(other)}")

  defp token!(%{network: network, asset: asset, currency: currency, decimals: decimals})
       when is_binary(network) and network != "" and is_binary(asset) and asset != "" and is_binary(currency) and
              is_integer(decimals) and decimals in 0..255 do
    if String.trim(currency) == "", do: raise(ArgumentError, "each token needs a currency, such as USD")
    {Units.asset_key(network, asset), {String.upcase(currency), decimals}}
  end

  defp token!(other) do
    raise ArgumentError,
          "each token needs :network, :asset, :currency and :decimals (0..255), got: #{inspect(other)}"
  end
end
