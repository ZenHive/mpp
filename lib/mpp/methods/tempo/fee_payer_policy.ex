defmodule MPP.Methods.Tempo.FeePayerPolicy do
  @moduledoc """
  Sponsor (fee-payer) gas-economics policy for Tempo transactions.

  When the server acts as fee payer it co-signs and broadcasts a client-signed
  `0x76` envelope, paying the gas from its own wallet. Without bounds, a malicious
  client embeds arbitrary gas parameters and drains that wallet
  (GHSA-vv77-66rf-pm86 — unbounded `max_fee_per_gas`/`max_priority_fee_per_gas`;
  GHSA-qpxh-ff8m-c62v — access-list padding). The same family covers *intrinsic*
  gas: padded/non-canonical calldata or a nonzero call `value` inflate what the
  sponsor pays without changing the decoded payment intent (mppx #602). This
  module bounds the client-supplied gas fields, the total fee budget, the access
  list, per-call value, and calldata canonicality before the server co-signs.

  The model mirrors the mppx (TypeScript) and mpp-rs (Rust) reference SDKs:
  absolute ceilings with per-chain defaults, overridable per server. Checks
  (all comparisons match the references):

    * `gas_limit` in `1..policy.max_gas`
    * `max_fee_per_gas` in `1..policy.max_fee_per_gas`
    * `gas_limit * max_fee_per_gas <= policy.max_total_fee` (worst-case budget cap)
    * `max_priority_fee_per_gas <= max_fee_per_gas` and `<= policy.max_priority_fee_per_gas`
    * expiring nonce key required; `valid_before` present, in the future, and
      within `policy.max_validity_window_seconds` of now (bounds how long a
      sponsorship the server co-signs can sit broadcastable)
    * access list empty (fee-payer call scopes never need one)
    * every call carries zero native `value`
    * calldata for each recognized TIP-20 / DEX call is byte-exact canonical — no
      trailing padding or non-canonical high-order bytes that raise intrinsic gas
      without changing the decoded intent (ports mppx #602; unknown selectors are
      left to `Transaction.validate_call_scope/1`)

  Any field that is not a well-formed RLP scalar (e.g. a list where a number is
  expected, or a truncated envelope) is rejected — the policy fails closed on
  malformed input rather than coercing it to zero.

  The validity window is an absolute `max_validity_window_seconds` cap (matching
  mpp-rs). mppx additionally ties the ceiling to `challengeExpires + 60s`; we do
  not, so a co-signed sponsorship stays broadcastable up to the full window even
  past challenge expiry — lower `max_validity_window_seconds` if you need a
  tighter, challenge-relative bound.

  ## Overrides

  Pass a `"fee_payer_policy"` map in `:method_config` to raise or lower any
  ceiling (`max_validity_window_seconds` is in seconds; the rest are wei). Each
  unset key falls back to the per-chain default:

      "fee_payer_policy" => %{
        "max_gas" => 2_000_000,
        "max_fee_per_gas" => 100_000_000_000,
        "max_priority_fee_per_gas" => 10_000_000_000,
        "max_total_fee" => 50_000_000_000_000_000,
        "max_validity_window_seconds" => 900
      }

  > #### Not a substitute for simulation {: .warning}
  >
  > This policy bounds the *price* the server will pay. It does not catch a
  > `gas_limit` set too low to complete the call (GHSA-vj8p-hp9x-gh47): that
  > requires pre-broadcast simulation of the co-signed transaction.
  """

  alias MPP.Methods.Tempo.EnvelopeFields, as: TxFields
  alias Onchain.Tempo.TIP20
  alias Onchain.Tempo.Transaction

  @moderato_chain_id 42_431
  @mainnet_chain_id 4217
  @path_usd "0x20c0000000000000000000000000000000000000"
  @usdc "0x20C000000000000000000000b9537d11c60E8b50"

  # Expiring nonce key (U256::MAX) — sentinel both reference SDKs require for sponsored txs.
  @expiring_nonce_key Bitwise.bsl(1, 256) - 1

  # Recognized sponsored-call selectors whose calldata must be byte-exact canonical
  # (ports mppx #602). Single source of truth: onchain_tempo's TIP20 constants.
  @transfer_selector TIP20.transfer_selector()
  @approve_selector TIP20.approve_selector()
  @transfer_with_memo_selector TIP20.transfer_with_memo_selector()
  @swap_selector TIP20.swap_exact_amount_out_selector()

  # Defaults match mppx/mpp-rs. Gas/fee ceilings are wei;
  # `max_validity_window_seconds` is seconds. Only the priority-fee ceiling
  # differs per chain — Moderato testnet regularly needs a higher priority fee.
  @max_gas_default 2_000_000
  @max_fee_per_gas_default 100_000_000_000
  @max_priority_fee_per_gas_default 10_000_000_000
  @max_priority_fee_per_gas_moderato 50_000_000_000
  @max_total_fee_default 50_000_000_000_000_000
  @max_validity_window_seconds_default 15 * 60

  @typedoc "Resolved sponsor gas-economics and validity-window ceilings."
  @type t :: %__MODULE__{
          max_gas: non_neg_integer(),
          max_fee_per_gas: non_neg_integer(),
          max_priority_fee_per_gas: non_neg_integer(),
          max_total_fee: non_neg_integer(),
          max_validity_window_seconds: non_neg_integer()
        }

  defstruct [
    :max_gas,
    :max_fee_per_gas,
    :max_priority_fee_per_gas,
    :max_total_fee,
    :max_validity_window_seconds
  ]

  @doc """
  Resolve the policy for `chain_id`, applying optional `overrides`.

  `overrides` is a string-keyed map (`"max_gas"`, `"max_fee_per_gas"`,
  `"max_priority_fee_per_gas"`, `"max_total_fee"`,
  `"max_validity_window_seconds"`); non-integer or negative values are ignored
  in favor of the per-chain default.

  ## Examples

      iex> p = MPP.Methods.Tempo.FeePayerPolicy.resolve(42_431, nil)
      iex> {p.max_fee_per_gas, p.max_priority_fee_per_gas}
      {100_000_000_000, 50_000_000_000}

      iex> p = MPP.Methods.Tempo.FeePayerPolicy.resolve(4217, %{"max_gas" => 500_000})
      iex> {p.max_gas, p.max_priority_fee_per_gas}
      {500_000, 10_000_000_000}
  """
  @spec resolve(non_neg_integer(), map() | nil) :: t()
  def resolve(chain_id, overrides) do
    chain_id |> base_policy() |> apply_overrides(overrides || %{})
  end

  @doc """
  Return the default sponsor fee-token allowlist for `chain_id`.

  Matches mppx `defaultAllowedFeeTokens` / mpp-rs `default_allowed_fee_tokens`:
  pathUSD plus the chain's default currency (USDC on mainnet, pathUSD on Moderato).
  """
  @spec default_allowed_fee_tokens(non_neg_integer()) :: [String.t()]
  def default_allowed_fee_tokens(chain_id) do
    chain_default =
      if chain_id == @mainnet_chain_id,
        do: @usdc,
        else: @path_usd

    Enum.uniq_by([@path_usd, chain_default], &String.downcase/1)
  end

  @doc """
  Return true when `fee_token` is on the allowlist for `chain_id`.

  `overrides` is an optional list of hex addresses replacing the per-chain default.
  """
  @spec fee_token_allowed?(non_neg_integer(), String.t(), [String.t()] | nil) :: boolean()
  def fee_token_allowed?(chain_id, fee_token, overrides \\ nil) do
    allowed = overrides || default_allowed_fee_tokens(chain_id)
    Enum.any?(allowed, &Onchain.Address.equal?(&1, fee_token))
  end

  @spec base_policy(non_neg_integer()) :: t()
  defp base_policy(chain_id) do
    priority =
      if chain_id == @moderato_chain_id,
        do: @max_priority_fee_per_gas_moderato,
        else: @max_priority_fee_per_gas_default

    %__MODULE__{
      max_gas: @max_gas_default,
      max_fee_per_gas: @max_fee_per_gas_default,
      max_priority_fee_per_gas: priority,
      max_total_fee: @max_total_fee_default,
      max_validity_window_seconds: @max_validity_window_seconds_default
    }
  end

  @spec apply_overrides(t(), map()) :: t()
  defp apply_overrides(policy, overrides) do
    %__MODULE__{
      max_gas: override(overrides, "max_gas", policy.max_gas),
      max_fee_per_gas: override(overrides, "max_fee_per_gas", policy.max_fee_per_gas),
      max_priority_fee_per_gas: override(overrides, "max_priority_fee_per_gas", policy.max_priority_fee_per_gas),
      max_total_fee: override(overrides, "max_total_fee", policy.max_total_fee),
      max_validity_window_seconds: override(overrides, "max_validity_window_seconds", policy.max_validity_window_seconds)
    }
  end

  @spec override(map(), String.t(), non_neg_integer()) :: non_neg_integer()
  defp override(overrides, key, default) do
    case Map.get(overrides, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end

  @doc """
  Validate a transaction's gas economics and validity window against `policy`.

  Returns `:ok` or `{:error, reason}` (binary). Fields are read from the parsed
  `0x76` envelope. The validity-window check is evaluated against the current
  system time; pass `validate/3` with an explicit `now` (unix seconds) to make
  the comparison deterministic.
  """
  @spec validate(Transaction.t(), t()) :: :ok | {:error, String.t()}
  def validate(%Transaction{} = tx, %__MODULE__{} = policy) do
    validate(tx, policy, System.os_time(:second))
  end

  @doc """
  Like `validate/2`, but evaluates the validity window against `now`
  (unix seconds) instead of the system clock.
  """
  @spec validate(Transaction.t(), t(), integer()) :: :ok | {:error, String.t()}
  def validate(%Transaction{} = tx, %__MODULE__{} = policy, now) when is_integer(now) do
    with {:ok, gas_limit} <- field_int(tx, TxFields.gas_limit(), "gas_limit"),
         {:ok, max_fee} <- field_int(tx, TxFields.max_fee_per_gas(), "max_fee_per_gas"),
         {:ok, max_priority} <- field_int(tx, TxFields.max_priority_fee_per_gas(), "max_priority_fee_per_gas"),
         :ok <- check_gas(gas_limit, policy),
         :ok <- check_max_fee(max_fee, policy),
         :ok <- check_total_fee(gas_limit, max_fee, policy),
         :ok <- check_priority(max_priority, max_fee, policy),
         :ok <- check_nonce_key(tx),
         :ok <- check_validity_window(tx, policy, now),
         :ok <- check_access_list(tx),
         :ok <- check_call_values(tx) do
      check_canonical_calls(tx)
    end
  end

  @spec check_gas(non_neg_integer(), t()) :: :ok | {:error, String.t()}
  defp check_gas(gas, %{max_gas: max}) when gas > 0 and gas <= max, do: :ok

  defp check_gas(gas, %{max_gas: max}), do: {:error, "fee-payer gas_limit #{gas} outside allowed range (1..#{max})"}

  @spec check_max_fee(non_neg_integer(), t()) :: :ok | {:error, String.t()}
  defp check_max_fee(fee, %{max_fee_per_gas: max}) when fee > 0 and fee <= max, do: :ok

  defp check_max_fee(fee, %{max_fee_per_gas: max}),
    do: {:error, "fee-payer max_fee_per_gas #{fee} outside allowed range (1..#{max})"}

  @spec check_total_fee(non_neg_integer(), non_neg_integer(), t()) :: :ok | {:error, String.t()}
  defp check_total_fee(gas, fee, %{max_total_fee: max}) do
    total = gas * fee

    if total <= max,
      do: :ok,
      else: {:error, "fee-payer total fee budget #{total} exceeds maximum #{max}"}
  end

  @spec check_priority(non_neg_integer(), non_neg_integer(), t()) :: :ok | {:error, String.t()}
  defp check_priority(priority, max_fee, %{max_priority_fee_per_gas: max}) do
    cond do
      priority > max_fee ->
        {:error, "fee-payer max_priority_fee_per_gas #{priority} exceeds max_fee_per_gas #{max_fee}"}

      priority > max ->
        {:error, "fee-payer max_priority_fee_per_gas #{priority} exceeds maximum #{max}"}

      true ->
        :ok
    end
  end

  @spec check_nonce_key(Transaction.t()) :: :ok | {:error, String.t()}
  defp check_nonce_key(tx) do
    with {:ok, key} <- field_int(tx, TxFields.nonce_key(), "nonce_key") do
      if key == @expiring_nonce_key,
        do: :ok,
        else: {:error, "fee-payer transaction must use the expiring nonce key"}
    end
  end

  @spec check_validity_window(Transaction.t(), t(), integer()) :: :ok | {:error, String.t()}
  defp check_validity_window(tx, %{max_validity_window_seconds: max}, now) do
    with {:ok, valid_before} <- field_int(tx, TxFields.valid_before(), "valid_before") do
      cond do
        valid_before == 0 ->
          {:error, "fee-payer transaction must declare valid_before"}

        valid_before <= now ->
          {:error, "fee-payer transaction already expired (valid_before #{valid_before} <= now #{now})"}

        valid_before - now > max ->
          {:error, "fee-payer validity window #{valid_before - now}s exceeds maximum #{max}s"}

        true ->
          :ok
      end
    end
  end

  @spec check_access_list(Transaction.t()) :: :ok | {:error, String.t()}
  defp check_access_list(%Transaction{fields: fields}) do
    case Enum.at(fields, TxFields.access_list()) do
      [] ->
        :ok

      list when is_list(list) ->
        {:error, "fee-payer transaction must not declare an access list (#{length(list)} entries)"}

      _ ->
        {:error, "fee-payer transaction has a malformed access_list field"}
    end
  end

  @spec check_call_values(Transaction.t()) :: :ok | {:error, String.t()}
  defp check_call_values(%Transaction{calls: calls}) do
    case Enum.find_index(calls, fn %{value: value} -> value != 0 end) do
      nil -> :ok
      index -> {:error, "fee-payer transaction call #{index} value is not allowed (must be zero)"}
    end
  end

  @spec check_canonical_calls(Transaction.t()) :: :ok | {:error, String.t()}
  defp check_canonical_calls(%Transaction{calls: calls}) do
    case Enum.find_index(calls, &(not canonical_call?(&1))) do
      nil -> :ok
      index -> {:error, "fee-payer transaction call #{index} calldata is not canonical"}
    end
  end

  # Recognized TIP-20 / stablecoin-DEX calls must carry byte-exact canonical ABI
  # calldata: exact length, zero high-order padding on address/uint128 words. A client
  # cannot append trailing bytes or dirty the padding to inflate the sponsor's intrinsic
  # gas (16 gas/byte) while decoding to the same payment intent. Ports mppx #602
  # (refs/mppx/src/tempo/internal/fee-payer.ts:330-388, changeset fix-fee-payer-intrinsic-gas),
  # reproducing its decode→re-encode-and-compare via fixed bitstring patterns since all four
  # functions take only static ABI args. Unknown selectors pass here — call scope is gated
  # separately by Transaction.validate_call_scope/1 before this policy runs.
  @spec canonical_call?(Transaction.call()) :: boolean()
  defp canonical_call?(%{input: <<@transfer_selector, 0::96, _to::binary-size(20), _amount::binary-size(32)>>}), do: true

  defp canonical_call?(%{input: <<@approve_selector, 0::96, _spender::binary-size(20), _amount::binary-size(32)>>}),
    do: true

  defp canonical_call?(%{
         input:
           <<@transfer_with_memo_selector, 0::96, _to::binary-size(20), _amt::binary-size(32), _memo::binary-size(32)>>
       }), do: true

  defp canonical_call?(%{
         input:
           <<@swap_selector, 0::96, _token_in::binary-size(20), 0::96, _token_out::binary-size(20), 0::128,
             _amount_out::binary-size(16), 0::128, _max_amount_in::binary-size(16)>>
       }), do: true

  defp canonical_call?(%{input: <<selector::binary-size(4), _rest::binary>>})
       when selector not in [@transfer_selector, @approve_selector, @transfer_with_memo_selector, @swap_selector],
       do: true

  defp canonical_call?(_call), do: false

  @spec field_int(Transaction.t(), non_neg_integer(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  defp field_int(%Transaction{fields: fields}, index, name) do
    case Enum.at(fields, index) do
      bin when is_binary(bin) -> {:ok, :binary.decode_unsigned(bin)}
      _ -> {:error, "fee-payer transaction has a malformed #{name} field"}
    end
  end
end
