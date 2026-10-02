defmodule MPP.Methods.Tempo.MachineToken do
  @moduledoc """
  Canonical MACH and machineUSD charge routes.

  A machine-token payment does not send the challenge currency from the payer.
  The payer approves the canonical swapper and calls `swapTo`; the swapper
  pulls and burns the credit token, then `transferWithMemo`s the challenge
  currency to the merchant. Merchant-facing verification is therefore a TIP-20
  `TransferWithMemo` whose `from` is the swapper, not the payer.

  On-chain authority: the machineUSD `MppcSwapper` source and live Moderato
  receipts for both deployments. MACH's `swapTo` selector and settlement event
  are pinned by `tempo_mach_integration_test.exs` (transaction `0xce5ea421…9725b`).
  Reference SDKs are compatibility evidence only:

    * mppx `src/tempo/internal/machine-token-charge.ts` / `defaults.ts`
    * mpp-rs `refs/mpp-rs/src/protocol/methods/tempo/machine_token.rs`

  Calldata/event parsers for this route belong in `onchain_tempo`. Until that
  library ships them, this module holds the MPP-side constants and exact
  `[approve, swapTo]` match the verifier needs.
  """

  alias MPP.Hex
  alias Onchain.Address
  alias Onchain.Tempo.TIP20

  @mainnet_chain_id 4217
  @moderato_chain_id 42_431

  # machineUSD: mpp-rs machine_token.rs; MACH: mppx defaults.ts (ba6f7a2).
  @token_mainnet "0x20C0000000000000000000003793c39601711f19"
  @swapper_mainnet "0xC6D32f013E0fA3e83B63Dc680E99826761595732"
  @token_moderato "0x20c000000000000000000000f85bbCa724044De0"
  @swapper_moderato "0x07f1FE0467Ae01DE340024aa4b7DD9729b1c169b"

  @mach_token "0x20c000000000000000000000f37de3740ADec032"
  @mach_swapper_mainnet "0xF72E5107c32C655ffA7539a3C8e97B7C3cE16A3F"
  @mach_swapper_moderato "0xd05f8EdFBB54Da0d765C9fE9b2B3f7d2E3a8C466"

  @type deployment_name :: :mach | :machine_usd
  @type deployment :: %{token: String.t(), swapper: String.t()}

  @doc "Returns both canonical deployments, preferring MACH."
  @spec deployments(non_neg_integer()) :: [deployment()]
  def deployments(chain_id) do
    for name <- [:mach, :machine_usd], {:ok, deployment} <- [deployment(chain_id, name)], do: deployment
  end

  @doc "Returns whether the address is a machine token on this chain."
  @spec machine_token?(non_neg_integer(), term()) :: boolean()
  def machine_token?(chain_id, address) when is_binary(address) do
    Enum.any?(deployments(chain_id), &Address.equal?(&1.token, address))
  end

  def machine_token?(_chain_id, _address), do: false

  @doc "Returns the funding token associated with a canonical settlement sender."
  @spec funding_token(non_neg_integer(), binary()) :: String.t() | nil
  def funding_token(chain_id, sender) do
    Enum.find_value(deployments(chain_id), fn deployment ->
      if Address.equal?(deployment.swapper, sender), do: deployment.token
    end)
  end

  # keccak256("swapTo(address,uint256,address,address,bytes32)")[:4]
  # Live Moderato calldata starts 0x34189fed (tx 0x6b1cdd67…c2f0).
  @swap_to_selector binary_part(Onchain.Hash.keccak("swapTo(address,uint256,address,address,bytes32)"), 0, 4)

  @type call :: %{to: binary(), value: non_neg_integer(), input: binary()}

  @type route :: %{
          settlement_sender: String.t(),
          memo: String.t()
        }

  @doc """
  Return whether a first-party machine-token deployment exists on `chain_id`.
  """
  @spec supported?(non_neg_integer()) :: boolean()
  def supported?(chain_id), do: match?({:ok, _}, deployment(chain_id))

  @doc """
  Return the machineUSD swapper address, or nil. Use `deployments/1` for both routes.
  """
  @spec settlement_sender(non_neg_integer()) :: String.t() | nil
  def settlement_sender(chain_id) do
    case deployment(chain_id) do
      {:ok, %{swapper: swapper}} -> swapper
      :error -> nil
    end
  end

  @doc """
  Return the machineUSD token address on `chain_id`, or nil.
  """
  @spec token(non_neg_integer()) :: String.t() | nil
  def token(chain_id) do
    case deployment(chain_id) do
      {:ok, %{token: token}} -> token
      :error -> nil
    end
  end

  @doc """
  ABI-encode `swapTo(address,uint256,address,address,bytes32)` calldata.
  """
  @spec swap_to_calldata(binary(), non_neg_integer(), binary(), binary(), binary()) :: binary()
  def swap_to_calldata(input_token, amount, target_token, recipient, memo)
      when byte_size(input_token) == 20 and is_integer(amount) and amount >= 0 and byte_size(target_token) == 20 and
             byte_size(recipient) == 20 and byte_size(memo) == 32 do
    @swap_to_selector <>
      <<0::96, input_token::binary-size(20)>> <>
      <<amount::unsigned-big-size(256)>> <>
      <<0::96, target_token::binary-size(20)>> <>
      <<0::96, recipient::binary-size(20)>> <>
      <<memo::binary-size(32)>>
  end

  @doc """
  Build the canonical `[approve, swapTo]` calls for a charge.

  The five-argument form retains the machineUSD route. Pass `:mach` as the
  sixth argument for the MACH deployment used by current mppx clients.

  Returns `:error` when the chain has no first-party deployment or any
  address, amount, or memo is invalid.
  """
  @spec settlement_calls(non_neg_integer(), String.t(), non_neg_integer() | String.t(), String.t(), binary()) ::
          {:ok, [call()]} | :error
  @spec settlement_calls(
          non_neg_integer(),
          String.t(),
          non_neg_integer() | String.t(),
          String.t(),
          binary(),
          deployment_name()
        ) ::
          {:ok, [call()]} | :error
  def settlement_calls(chain_id, currency, amount, recipient, memo, name \\ :machine_usd)

  def settlement_calls(chain_id, currency, amount, recipient, memo, name) when byte_size(memo) == 32 do
    with {:ok, deployment} <- deployment(chain_id, name),
         {:ok, amount_int} <- parse_amount(amount),
         {:ok, currency_bin} <- decode_addr(currency),
         {:ok, recipient_bin} <- decode_addr(recipient),
         {:ok, token_bin} <- decode_addr(deployment.token),
         {:ok, swapper_bin} <- decode_addr(deployment.swapper) do
      {:ok,
       [
         zero_value_call(token_bin, TIP20.approve_calldata(swapper_bin, amount_int)),
         zero_value_call(swapper_bin, swap_to_calldata(token_bin, amount_int, currency_bin, recipient_bin, memo))
       ]}
    else
      _ -> :error
    end
  end

  def settlement_calls(_chain_id, _currency, _amount, _recipient, _memo, _name), do: :error

  defp zero_value_call(to, input), do: %{to: to, value: 0, input: input}

  @doc """
  Match the exact canonical `[approve, swapTo]` route for a charge.

  When `memo` is nil, the memo is taken from the `swapTo` calldata (mppx
  `matchRoute` / mpp-rs `match_route`). Any other call shape returns `:error`.
  """
  @spec match_route([call()], non_neg_integer(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, route()} | :error
  def match_route(calls, chain_id, currency, amount, recipient, memo)

  def match_route([approve_call, swap_call], chain_id, currency, amount, recipient, memo) do
    Enum.find_value(deployments(chain_id), :error, fn deployment ->
      case match_deployment(approve_call, swap_call, deployment, currency, amount, recipient, memo) do
        {:ok, route} -> {:ok, route}
        :error -> nil
      end
    end)
  end

  def match_route(_calls, _chain_id, _currency, _amount, _recipient, _memo), do: :error

  defp match_deployment(approve_call, swap_call, deployment, currency, amount, recipient, memo) do
    with {:ok, amount_int} <- parse_amount(amount),
         {:ok, currency_bin} <- decode_addr(currency),
         {:ok, recipient_bin} <- decode_addr(recipient),
         {:ok, token_bin} <- decode_addr(deployment.token),
         {:ok, swapper_bin} <- decode_addr(deployment.swapper),
         {:ok, decoded} <- decode_swap_to(Map.get(swap_call, :input)),
         {:ok, memo_bin} <- resolve_memo(memo, decoded.memo),
         expected_approve = TIP20.approve_calldata(swapper_bin, amount_int),
         expected_swap = swap_to_calldata(token_bin, amount_int, currency_bin, recipient_bin, memo_bin),
         true <- same_call?(approve_call, token_bin, expected_approve),
         true <- same_call?(swap_call, swapper_bin, expected_swap) do
      {:ok,
       %{
         settlement_sender: deployment.swapper,
         memo: "0x" <> Base.encode16(memo_bin, case: :lower)
       }}
    else
      _ -> :error
    end
  end

  defp deployment(chain_id), do: deployment(chain_id, :machine_usd)

  defp deployment(@mainnet_chain_id, :machine_usd), do: {:ok, %{token: @token_mainnet, swapper: @swapper_mainnet}}
  defp deployment(@moderato_chain_id, :machine_usd), do: {:ok, %{token: @token_moderato, swapper: @swapper_moderato}}
  defp deployment(@mainnet_chain_id, :mach), do: {:ok, %{token: @mach_token, swapper: @mach_swapper_mainnet}}
  defp deployment(@moderato_chain_id, :mach), do: {:ok, %{token: @mach_token, swapper: @mach_swapper_moderato}}
  defp deployment(_chain_id, _name), do: :error

  defp decode_swap_to(
         <<@swap_to_selector, 0::96, input::binary-size(20), amount::unsigned-big-size(256), 0::96,
           target::binary-size(20), 0::96, recipient::binary-size(20), memo::binary-size(32)>>
       ) do
    {:ok, %{input_token: input, amount: amount, target_token: target, recipient: recipient, memo: memo}}
  end

  defp decode_swap_to(_input), do: :error

  defp resolve_memo(nil, swap_memo), do: {:ok, swap_memo}

  defp resolve_memo(hex, _swap_memo) when is_binary(hex) do
    decode_memo(hex)
  end

  defp resolve_memo(_memo, _swap_memo), do: :error

  defp decode_memo(hex) when is_binary(hex) do
    case Base.decode16(Hex.strip_0x(hex), case: :mixed) do
      {:ok, <<_::binary-size(32)>> = bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode_addr(hex) do
    case Address.validate(hex) do
      {:ok, bin} -> {:ok, bin}
      {:error, _} -> :error
    end
  end

  defp parse_amount(amount) when is_integer(amount) and amount >= 0, do: {:ok, amount}

  defp parse_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_amount(_amount), do: :error

  defp same_call?(%{to: to, value: value, input: input}, expected_to, expected_input) do
    value == 0 and Address.equal?(to, expected_to) and input == expected_input
  end

  defp same_call?(_call, _expected_to, _expected_input), do: false
end
