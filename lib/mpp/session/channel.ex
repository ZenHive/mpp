defmodule MPP.Session.Channel do
  @moduledoc """
  State and legacy contract-backed identity for an MPP payment channel.

  Channel IDs match the Tempo stream-channel contract and the legacy mppx and
  mpp-rs implementations:

      keccak256(abi.encode(payer, payee, token, salt, authorizedSigner,
                           escrowContract, chainId))

  Channel lifecycle is deliberately small: a new channel is `:open`, may be
  activated once, and an active channel may be closed once.
  """

  import Bitwise, only: [<<<: 2]

  alias Cartouche.Hash
  alias Onchain.Address
  alias Onchain.Hex

  @channel_id_types "(address,address,address,bytes32,address,address,uint256)"
  @max_chain_id (1 <<< 256) - 1

  @type status :: :open | :active | :closed
  @type action :: :open | :top_up | :voucher | :close
  @type id_params :: %{
          payer: String.t(),
          payee: String.t(),
          token: String.t(),
          salt: String.t(),
          authorized_signer: String.t(),
          escrow_contract: String.t(),
          chain_id: non_neg_integer()
        }
  @type t :: %__MODULE__{
          channel_id: String.t(),
          payer: String.t(),
          recipient: String.t(),
          token: String.t(),
          deposit: non_neg_integer(),
          cumulative_amount: non_neg_integer(),
          spent: non_neg_integer(),
          units: non_neg_integer(),
          status: status()
        }

  @enforce_keys [:channel_id, :payer, :recipient, :token, :deposit]
  defstruct [
    :channel_id,
    :payer,
    :recipient,
    :token,
    :deposit,
    cumulative_amount: 0,
    spent: 0,
    units: 0,
    status: :open
  ]

  @doc "Create validated channel state in the `:open` status."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    deposit = Keyword.get(opts, :deposit)
    cumulative_amount = Keyword.get(opts, :cumulative_amount, 0)
    spent = Keyword.get(opts, :spent, 0)
    units = Keyword.get(opts, :units, 0)

    with {:ok, channel_id} <- normalize_id(Keyword.get(opts, :channel_id)),
         {:ok, payer} <- normalize_address(Keyword.get(opts, :payer), :payer),
         {:ok, recipient} <- normalize_address(Keyword.get(opts, :recipient), :recipient),
         {:ok, token} <- normalize_address(Keyword.get(opts, :token), :token),
         :ok <- validate_amount(deposit, :deposit),
         :ok <- validate_amount(cumulative_amount, :cumulative_amount),
         :ok <- validate_amount(spent, :spent),
         :ok <- validate_amount(units, :units),
         :ok <- validate_balance(deposit, cumulative_amount, spent) do
      {:ok,
       %__MODULE__{
         channel_id: channel_id,
         payer: payer,
         recipient: recipient,
         token: token,
         deposit: deposit,
         cumulative_amount: cumulative_amount,
         spent: spent,
         units: units
       }}
    end
  end

  @doc "Create validated channel state, raising `ArgumentError` on invalid input."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, channel} -> channel
      {:error, reason} -> raise ArgumentError, "invalid session channel: #{inspect(reason)}"
    end
  end

  @doc "Move an open channel to the active state."
  @spec activate(t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :active}}
  def activate(%__MODULE__{status: :open} = channel), do: {:ok, %{channel | status: :active}}

  def activate(%__MODULE__{status: status}), do: {:error, {:invalid_transition, status, :active}}

  @doc "Move an active channel to the closed state."
  @spec close(t()) :: {:ok, t()} | {:error, {:invalid_transition, status(), :closed}}
  def close(%__MODULE__{status: :active} = channel), do: {:ok, %{channel | status: :closed}}

  def close(%__MODULE__{status: status}), do: {:error, {:invalid_transition, status, :closed}}

  @doc "Authorized-but-unspent voucher balance (`cumulative_amount - spent`)."
  @spec available_balance(t()) :: non_neg_integer()
  def available_balance(%__MODULE__{cumulative_amount: cumulative_amount, spent: spent}) do
    cumulative_amount - spent
  end

  @doc "Unvouchered remainder of the on-channel deposit (`deposit - cumulative_amount`)."
  @spec remaining_deposit(t()) :: non_neg_integer()
  def remaining_deposit(%__MODULE__{deposit: deposit, cumulative_amount: cumulative_amount}) do
    deposit - cumulative_amount
  end

  @doc "Raise the accepted cumulative voucher amount. Equal amounts are idempotent."
  @spec apply_voucher(t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def apply_voucher(%__MODULE__{status: :closed}, _amount), do: {:error, {:invalid_transition, :closed, :active}}

  def apply_voucher(%__MODULE__{} = channel, amount) when is_integer(amount) and amount >= 0 do
    cond do
      amount > channel.deposit ->
        {:error, :amount_exceeds_deposit}

      amount < channel.cumulative_amount ->
        {:error, :voucher_not_monotonic}

      true ->
        channel
        |> Map.put(:cumulative_amount, amount)
        |> maybe_activate()
    end
  end

  def apply_voucher(_channel, _amount), do: {:error, {:invalid_amount, :cumulative_amount}}

  @doc "Increase the channel deposit by a positive additional amount."
  @spec apply_top_up(t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def apply_top_up(%__MODULE__{status: :closed}, _amount), do: {:error, {:invalid_transition, :closed, :active}}

  def apply_top_up(%__MODULE__{} = channel, amount) when is_integer(amount) and amount > 0 do
    {:ok, %{channel | deposit: channel.deposit + amount}}
  end

  def apply_top_up(_channel, _amount), do: {:error, {:invalid_amount, :additional_deposit}}

  @doc "Deduct a per-request spend from the authorized voucher balance."
  @spec apply_spend(t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def apply_spend(%__MODULE__{status: :closed}, _amount), do: {:error, {:invalid_transition, :closed, :active}}

  def apply_spend(%__MODULE__{} = channel, 0), do: {:ok, channel}

  def apply_spend(%__MODULE__{} = channel, amount) when is_integer(amount) and amount > 0 do
    if available_balance(channel) >= amount do
      {:ok, %{channel | spent: channel.spent + amount, units: channel.units + 1}}
    else
      {:error, :insufficient_balance}
    end
  end

  def apply_spend(_channel, _amount), do: {:error, {:invalid_amount, :spent}}

  defp maybe_activate(%__MODULE__{status: :open} = channel), do: activate(channel)
  defp maybe_activate(%__MODULE__{} = channel), do: {:ok, channel}

  @doc "Compute the legacy contract-backed channel ID from its identity fields."
  @spec compute_id(id_params() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def compute_id(params) when is_list(params), do: params |> Map.new() |> compute_id()

  def compute_id(%{
        payer: payer,
        payee: payee,
        token: token,
        salt: salt,
        authorized_signer: authorized_signer,
        escrow_contract: escrow_contract,
        chain_id: chain_id
      }) do
    with {:ok, payer} <- normalize_address_bytes(payer, :payer),
         {:ok, payee} <- normalize_address_bytes(payee, :payee),
         {:ok, token} <- normalize_address_bytes(token, :token),
         {:ok, salt} <- normalize_salt(salt),
         {:ok, authorized_signer} <- normalize_address_bytes(authorized_signer, :authorized_signer),
         {:ok, escrow_contract} <- normalize_address_bytes(escrow_contract, :escrow_contract),
         :ok <- validate_chain_id(chain_id) do
      encoded =
        ABI.encode(@channel_id_types, [
          {payer, payee, token, salt, authorized_signer, escrow_contract, chain_id}
        ])

      {:ok, encoded |> Hash.keccak() |> Hex.encode()}
    end
  end

  def compute_id(_params), do: {:error, :invalid_channel_id_parameters}

  @doc "Compute a channel ID, raising `ArgumentError` on invalid input."
  @spec compute_id!(id_params() | keyword()) :: String.t()
  def compute_id!(params) do
    case compute_id(params) do
      {:ok, channel_id} -> channel_id
      {:error, reason} -> raise ArgumentError, "invalid channel ID parameters: #{inspect(reason)}"
    end
  end

  @doc "Normalize a 32-byte channel ID to lowercase, `0x`-prefixed hex."
  @spec normalize_id(term()) :: {:ok, String.t()} | {:error, {:invalid_channel_id, term()}}
  def normalize_id(channel_id) do
    case decode_fixed_bytes(channel_id, 32) do
      {:ok, bytes} -> {:ok, Hex.encode(bytes)}
      :error -> {:error, {:invalid_channel_id, channel_id}}
    end
  end

  @doc "Return the camelCase JSON value for a session credential action atom."
  @spec action_to_wire(action()) :: String.t()
  def action_to_wire(:open), do: "open"
  def action_to_wire(:top_up), do: "topUp"
  def action_to_wire(:voucher), do: "voucher"
  def action_to_wire(:close), do: "close"

  @doc "Parse a session credential action JSON value into its Elixir atom."
  @spec action_from_wire(term()) :: {:ok, action()} | {:error, :invalid_action}
  def action_from_wire("open"), do: {:ok, :open}
  def action_from_wire("topUp"), do: {:ok, :top_up}
  def action_from_wire("voucher"), do: {:ok, :voucher}
  def action_from_wire("close"), do: {:ok, :close}
  def action_from_wire(_value), do: {:error, :invalid_action}

  defp normalize_address(address, field) do
    case Address.normalize(address) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:invalid_address, field}}
    end
  end

  defp normalize_address_bytes(address, field) do
    case Address.validate(address) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, {:invalid_address, field}}
    end
  end

  defp normalize_salt(salt) do
    case decode_fixed_bytes(salt, 32) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_salt}
    end
  end

  defp decode_fixed_bytes(value, size) when is_binary(value) do
    case Hex.decode(value) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _error -> :error
    end
  end

  defp decode_fixed_bytes(_value, _size), do: :error

  defp validate_amount(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp validate_amount(_value, field), do: {:error, {:invalid_amount, field}}

  defp validate_balance(deposit, cumulative_amount, spent)
       when cumulative_amount <= deposit and spent <= cumulative_amount, do: :ok

  defp validate_balance(deposit, cumulative_amount, _spent) when cumulative_amount > deposit,
    do: {:error, :cumulative_amount_exceeds_deposit}

  defp validate_balance(_deposit, _cumulative_amount, _spent), do: {:error, :spent_exceeds_cumulative}

  defp validate_chain_id(chain_id) when is_integer(chain_id) and chain_id >= 0 and chain_id <= @max_chain_id, do: :ok

  defp validate_chain_id(_chain_id), do: {:error, :invalid_chain_id}
end
