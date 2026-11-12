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
  alias Onchain.ERC20
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

  # Tempo Wallet page that sells MACH, on Tempo mainnet only. Same constant in
  # refs/mppx/src/tempo/internal/defaults.ts (`machineTokenFundingBaseUrl`) and
  # refs/mpp-rs/src/protocol/methods/tempo/machine_token.rs (`MACH_FUNDING_URL`).
  @funding_base_url "https://wallet.tempo.xyz/agent?action=fund&intent=mach&chainId=4217"
  # MACH has 6 decimals and is worth 1 USD: 10^(6 - 2) base units per cent.
  @mach_decimals 6
  @units_per_cent 10_000
  @funding_url_shape ~r/\A#{Regex.escape(@funding_base_url)}(&address=0x[0-9a-fA-F]{40})?(&amount=[0-9]+\.[0-9]{2})?\z/

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

  @doc "Returns whether the address is MACH on this chain."
  @spec mach?(term(), term()) :: boolean()
  def mach?(chain_id, address) when is_binary(address) do
    match?({:ok, _}, deployment(chain_id, :mach)) and Address.equal?(@mach_token, address)
  end

  def mach?(_chain_id, _address), do: false

  @doc """
  Builds the Tempo Wallet link where a payer buys MACH.

  Returns `nil` on any chain other than Tempo mainnet (4217), the only chain
  the wallet sells MACH on. `address` is the payer and is left out when it is
  not a valid address. `amount` is the MACH to buy in base units (6 decimals),
  rounded up to whole cents; zero and `nil` are left out.

  The base URL, the two parameters and the round-up match mppx
  `Tempo.machineTokenFundingUrl` and mpp-rs `machine_token::funding_url`. The
  amount is written with two decimals, as mpp-rs does.

      iex> MPP.Methods.Tempo.MachineToken.funding_url(4217, nil, 1_250_001)
      "https://wallet.tempo.xyz/agent?action=fund&intent=mach&chainId=4217&amount=1.26"

      iex> MPP.Methods.Tempo.MachineToken.funding_url(42_431, nil, 1)
      nil
  """
  @spec funding_url(term(), term(), term()) :: String.t() | nil
  def funding_url(chain_id, address \\ nil, amount \\ nil)

  def funding_url(@mainnet_chain_id, address, amount) do
    @funding_base_url <> funding_address(address) <> funding_amount(amount)
  end

  def funding_url(_chain_id, _address, _amount), do: nil

  defp funding_address(address) when is_binary(address) do
    case Address.checksum(address) do
      {:ok, checksummed} -> "&address=" <> checksummed
      {:error, _reason} -> ""
    end
  end

  defp funding_address(_address), do: ""

  defp funding_amount(amount) when is_integer(amount) and amount > 0 do
    cents = div(amount + @units_per_cent - 1, @units_per_cent)
    fraction = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "&amount=#{div(cents, 100)}.#{fraction}"
  end

  defp funding_amount(_amount), do: ""

  @doc """
  Returns whether `url` is a link `funding_url/3` writes: the base URL, then an
  optional `address` of 40 hex digits, then an optional `amount` in dollars
  and cents, and nothing else.
  """
  @spec funding_url?(term()) :: boolean()
  def funding_url?(url) when is_binary(url), do: Regex.match?(@funding_url_shape, url)
  def funding_url?(_url), do: false

  @doc """
  Formats MACH base units as a decimal amount with at least two places, such
  as `"0.25"` or `"1.000001"` (mpp-rs `machine_token::format_amount`).
  """
  @spec format_amount(non_neg_integer()) :: String.t()
  def format_amount(amount) when is_integer(amount) and amount >= 0 do
    scale = Integer.pow(10, @mach_decimals)

    fraction =
      amount
      |> rem(scale)
      |> Integer.to_string()
      |> String.pad_leading(@mach_decimals, "0")
      |> String.trim_trailing("0")
      |> String.pad_trailing(2, "0")

    "#{div(amount, scale)}.#{fraction}"
  end

  @doc """
  Reports how far `payer`'s MACH balance falls short of `amount` (base units).

  Returns `{:ok, %{reason: text, funding_url: url, shortfall: units}}` when the
  payer holds less MACH than `amount` on Tempo mainnet, and `:none` otherwise:
  on another chain, when the balance covers the amount, or when the balance
  cannot be read. `rpc_opts` are the `Onchain.ERC20.balance_of/3` options
  (`:rpc_url`, `:req_options`).
  """
  @spec shortfall(term(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, %{reason: String.t(), funding_url: String.t(), shortfall: pos_integer()}} | :none
  def shortfall(@mainnet_chain_id, payer, amount, rpc_opts)
      when is_binary(payer) and is_integer(amount) and is_list(rpc_opts) do
    case ERC20.balance_of(@mach_token, payer, rpc_opts) do
      {:ok, balance} when is_integer(balance) and balance < amount ->
        shortfall = amount - balance

        {:ok,
         %{
           reason: "requested #{format_amount(amount)} MACH, available #{format_amount(balance)} MACH",
           funding_url: funding_url(@mainnet_chain_id, payer, shortfall),
           shortfall: shortfall
         }}

      _enough_or_unreadable ->
        :none
    end
  end

  def shortfall(_chain_id, _payer, _amount, _rpc_opts), do: :none

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
