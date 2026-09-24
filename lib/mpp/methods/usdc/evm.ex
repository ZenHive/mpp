defmodule MPP.Methods.USDC.EVM do
  @moduledoc """
  Direct USDC charge on EVM, EIP-3009 `transferWithAuthorization` only.

  Settlement reuses `MPP.Methods.EVM.Authorization`. The nonce is the USDC
  challenge binding from `draft-usdc-charge-00`, not the generic EVM
  `challengeHash`. The server submits the authorization and pays gas.
  """

  @behaviour MPP.Methods.USDC.Profile

  alias Cartouche.Typed
  alias Cartouche.Typed.Domain
  alias Cartouche.Typed.Type
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM.Authorization
  alias MPP.Methods.EVM.RPC, as: EvmRPC
  alias MPP.Methods.Shared
  alias MPP.Methods.USDC.Assets
  alias MPP.Methods.USDC.Binding
  alias MPP.Methods.USDC.Replay
  alias MPP.Receipt
  alias MPP.Tempo.Store
  alias Onchain.Address
  alias Onchain.Contract
  alias Onchain.RPC
  alias Onchain.Transfer

  require Logger

  @domains [{"USDC", "2"}, {"USD Coin", "2"}]
  @credential_type "authorization"

  @impl true
  @doc "Profile name `evm`."
  @spec name() :: String.t()
  def name, do: "evm"

  @impl true
  @doc "EIP-3009 payload type accepted by this profile."
  @spec credential_type() :: String.t()
  def credential_type, do: @credential_type

  @impl true
  @doc "Require an RPC URL, a known chain id, and a settlement key."
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) when is_map(config) do
    chain_id = config["chain_id"]

    cond do
      not Shared.valid_rpc_url?(config["rpc_url"]) ->
        raise ArgumentError, "MPP.Methods.USDC evm profile requires an https method_config rpc_url"

      not is_integer(chain_id) or chain_id <= 0 ->
        raise ArgumentError, "MPP.Methods.USDC evm profile requires method_config chain_id"

      not Assets.known_evm_chain?(chain_id) ->
        raise ArgumentError, "MPP.Methods.USDC has no native USDC deployment for chain_id #{chain_id}"

      not is_binary(config["private_key"]) or config["private_key"] == "" ->
        raise ArgumentError,
              "MPP.Methods.USDC evm profile requires method_config private_key to settle EIP-3009"

      true ->
        :ok
    end
  end

  @impl true
  @doc "Advertise `chainId`, `decimals` 6, and the authorization credential."
  @spec challenge_details(Charge.t()) :: map()
  def challenge_details(%Charge{} = charge) do
    config = charge.method_details || %{}
    chain_id = config["chain_id"]

    case Assets.evm_currency(chain_id) do
      {:ok, expected} ->
        if Assets.evm?(chain_id, charge.currency) do
          %{"chainId" => chain_id, "credentialTypes" => [@credential_type], "decimals" => 6}
        else
          raise ArgumentError,
                "MPP.Methods.USDC evm currency must be native USDC #{expected} for chain #{chain_id}"
        end

      :error ->
        raise ArgumentError, "MPP.Methods.USDC has no native USDC deployment for chain_id #{inspect(chain_id)}"
    end
  end

  @impl true
  @doc "Verify an EIP-3009 USDC authorization and return the USDC receipt."
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- require_recipient(charge),
         {:ok, chain_id} <- require_chain(config),
         {:ok, profile} <- profile_object(config),
         :ok <- profile_chain(profile, chain_id),
         :ok <- profile_decimals(profile),
         :ok <- credential_types(profile),
         :ok <- native_asset(chain_id, charge.currency),
         {:ok, parsed} <- Authorization.parse_payload(payload),
         :ok <- match_fields(parsed, charge),
         :ok <- match_nonce(parsed, charge),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "USDC"),
         rpc_opts = EvmRPC.rpc_opts(rpc_url, config),
         {:ok, domain} <- resolve_domain(charge.currency, chain_id, rpc_opts),
         :ok <- token_controls(charge, parsed, rpc_opts),
         {:ok, hash} <- settle(parsed, charge, chain_id, domain, rpc_opts) do
      {:ok, Binding.receipt(charge, name(), hash, "eip155:#{chain_id}")}
    end
  end

  defp require_recipient(%Charge{recipient: recipient}) when is_binary(recipient) and recipient != "", do: :ok

  defp require_recipient(_charge) do
    {:error, Errors.new(:verification_failed, "USDC charge requires a recipient")}
  end

  defp require_chain(config) do
    case config["chain_id"] do
      chain_id when is_integer(chain_id) and chain_id > 0 -> {:ok, chain_id}
      _chain_id -> {:error, Errors.new(:verification_failed, "USDC evm profile requires chain_id")}
    end
  end

  defp profile_object(config) do
    case config["evm"] do
      profile when is_map(profile) -> {:ok, profile}
      _profile -> {:error, Errors.new(:invalid_payload, "USDC evm profile object is missing")}
    end
  end

  defp profile_chain(%{"chainId" => chain_id}, chain_id) when is_integer(chain_id), do: :ok

  defp profile_chain(_profile, _chain_id) do
    {:error, Errors.new(:verification_failed, "USDC evm chainId does not match method config")}
  end

  defp profile_decimals(%{"decimals" => 6}), do: :ok

  defp profile_decimals(_profile) do
    {:error, Errors.new(:invalid_payload, "USDC decimals must be 6")}
  end

  defp credential_types(profile) when is_map(profile) do
    case Map.get(profile, "credentialTypes") do
      nil -> :ok
      [@credential_type] -> :ok
      _types -> {:error, Errors.new(:invalid_payload, "USDC evm credentialTypes must contain only authorization")}
    end
  end

  defp native_asset(chain_id, currency) do
    if Assets.evm?(chain_id, currency) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Currency is not native USDC for chain #{chain_id}")}
    end
  end

  defp match_fields(parsed, charge) do
    cond do
      parsed.value != charge.amount ->
        {:error, Errors.new(:verification_failed, "Authorization amount does not match charge amount")}

      not Address.equal?(parsed.to, charge.recipient) ->
        {:error, Errors.new(:verification_failed, "Authorization recipient does not match charge recipient")}

      true ->
        :ok
    end
  end

  defp match_nonce(parsed, charge) do
    config = charge.method_details || %{}

    with {:ok, request} <- Binding.public_request(charge),
         true <- present?(config["challenge_id"]),
         true <- present?(config["realm"]) do
      expected = Binding.authorization_nonce(config["challenge_id"], config["realm"], request)

      if String.downcase(parsed.nonce) == String.downcase(expected) do
        :ok
      else
        {:error, Errors.new(:verification_failed, "Authorization nonce does not match the USDC challenge binding")}
      end
    else
      {:error, %Errors{}} = error -> error
      false -> {:error, Errors.new(:verification_failed, "USDC authorization requires challenge_id and realm")}
    end
  end

  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_value), do: false

  defp resolve_domain(currency, chain_id, rpc_opts) do
    with {:ok, [separator]} <- eth_call(currency, "DOMAIN_SEPARATOR()", [], "(bytes32)", rpc_opts),
         {:ok, separator} <- cast_bytes32(separator),
         {:ok, verifying} <- Address.validate(currency) do
      match_domain(verifying, chain_id, separator)
    end
  end

  defp match_domain(verifying, chain_id, separator) do
    case Enum.find(@domains, fn {name, version} ->
           domain_separator(verifying, chain_id, name, version) == separator
         end) do
      {name, version} -> {:ok, {name, version}}
      nil -> {:error, Errors.new(:verification_failed, "EIP-712 domain does not match native USDC")}
    end
  end

  defp domain_separator(verifying, chain_id, name, version) do
    Typed.domain_seperator(%Typed{
      domain: %Domain{name: name, version: version, chain_id: chain_id, verifying_contract: verifying},
      types: %{"TransferWithAuthorization" => %Type{fields: [{"from", :address}]}},
      value: %{"from" => verifying}
    })
  end

  defp cast_bytes32(separator) when is_binary(separator) and byte_size(separator) == 32, do: {:ok, separator}

  defp cast_bytes32(_separator) do
    {:error, Errors.new(:verification_failed, "EIP-712 domain does not match native USDC")}
  end

  defp token_controls(charge, parsed, rpc_opts) do
    with {:ok, [decimals]} <- eth_call(charge.currency, "decimals()", [], "(uint8)", rpc_opts),
         :ok <- onchain_decimals(decimals),
         {:ok, [paused?]} <- eth_call(charge.currency, "paused()", [], "(bool)", rpc_opts),
         :ok <- reject_paused(paused?),
         :ok <- reject_blocklisted(charge.currency, parsed.from, "payer", rpc_opts) do
      reject_blocklisted(charge.currency, parsed.to, "recipient", rpc_opts)
    end
  end

  defp onchain_decimals(6), do: :ok

  defp onchain_decimals(_decimals) do
    {:error, Errors.new(:verification_failed, "USDC decimals must be 6")}
  end

  defp reject_paused(false), do: :ok

  defp reject_paused(true) do
    {:error, Errors.new(:verification_failed, "USDC token is paused")}
  end

  defp reject_blocklisted(currency, address, role, rpc_opts) do
    with {:ok, address_bin} <- Address.validate(address),
         {:ok, [blocked?]} <- eth_call(currency, "isBlacklisted(address)", [address_bin], "(bool)", rpc_opts) do
      if blocked? do
        {:error, Errors.new(:verification_failed, "USDC #{role} is blocklisted")}
      else
        :ok
      end
    end
  end

  defp settle(parsed, charge, chain_id, {name, version}, rpc_opts) do
    config = charge.method_details || %{}
    store = Store.resolve(config["store"])
    settled = settlement_charge(charge, name, version)

    case Replay.with_claims(store, replay_keys(charge, chain_id, parsed), fn ->
           Authorization.settle(payload_of(parsed), settled, expected_nonce: parsed.nonce)
         end) do
      {:ok, hash} ->
        case confirm_transfer(hash, charge, parsed, rpc_opts) do
          :ok -> {:ok, hash}
          {:error, %Errors{}} = error -> error
        end

      {:error, %Errors{}} = error ->
        error
    end
  end

  defp replay_keys(charge, chain_id, parsed) do
    nonce_key =
      "evm:#{chain_id}:#{String.downcase(charge.currency)}:#{String.downcase(parsed.from)}:#{String.downcase(parsed.nonce)}"

    extra = [{nonce_key, "Authorization already used"}]

    case Replay.order_key(charge) do
      {:ok, key} -> [{key, "USDC merchant order already settled"} | extra]
      :none -> extra
    end
  end

  defp payload_of(parsed) do
    %{
      "type" => @credential_type,
      "from" => parsed.from,
      "to" => parsed.to,
      "value" => parsed.value,
      "validAfter" => Integer.to_string(parsed.valid_after),
      "validBefore" => Integer.to_string(parsed.valid_before),
      "nonce" => parsed.nonce,
      "signature" => parsed.signature
    }
  end

  defp settlement_charge(charge, name, version) do
    config = charge.method_details || %{}

    details =
      %{
        "authorization" => %{"name" => name, "version" => version},
        "chain_id" => config["chain_id"],
        "challenge_id" => config["challenge_id"],
        "credential_source" => config["credential_source"],
        "max_fee_per_gas" => config["max_fee_per_gas"],
        "max_priority_fee_per_gas" => config["max_priority_fee_per_gas"],
        "private_key" => config["private_key"],
        "realm" => config["realm"],
        "req_options" => config["req_options"],
        "rpc_url" => config["rpc_url"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{charge | method_details: details}
  end

  defp confirm_transfer(hash, charge, parsed, rpc_opts) do
    case RPC.get_transaction_receipt(hash, rpc_opts) do
      {:ok, receipt} -> match_transfer(Map.get(receipt, :logs) || [], charge, parsed)
      {:error, reason} -> rpc_failure(reason)
    end
  end

  defp match_transfer(logs, charge, parsed) do
    with {:ok, amount} <- Shared.parse_charge_amount(charge.amount),
         {:ok, transfers} <- Transfer.parse_logs(logs) do
      matched =
        Enum.any?(transfers, fn transfer ->
          Address.equal?(transfer.token, charge.currency) and
            Address.equal?(transfer.to, charge.recipient) and
            Address.equal?(transfer.from, parsed.from) and
            transfer.amount == amount
        end)

      if matched do
        :ok
      else
        {:error, Errors.new(:verification_failed, "No matching Transfer event found in transaction")}
      end
    end
  end

  defp eth_call(address, signature, args, return_type, rpc_opts) do
    case Contract.call(address, signature, args, return_type, rpc_opts) do
      {:ok, values} -> {:ok, values}
      {:error, reason} -> rpc_failure(reason)
    end
  end

  defp rpc_failure(reason) do
    Logger.warning("MPP.Methods.USDC.EVM: RPC request failed: #{inspect(reason)}")
    {:error, Errors.new(:verification_failed, "EVM RPC request failed")}
  end
end
