defmodule MPP.Methods.NearIntents.Origin do
  @moduledoc false

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.NearIntents.OneClick
  alias MPP.Methods.Shared

  require Logger

  @doc false
  @spec verify(String.t(), Charge.t(), map()) :: :ok | {:error, Errors.t()}
  def verify(hash, %Charge{} = charge, config) do
    case config["origin_rpc_url"] do
      nil -> verify_with_status(hash, config)
      rpc_url -> verify_with_rpc(hash, charge, config, rpc_url)
    end
  end

  @doc false
  @spec observed_hash?(map(), String.t(), String.t()) :: boolean()
  def observed_hash?(status, hash, network) do
    observed = get_in(status, ["swapDetails", "originChainTxHashes"]) || []

    Enum.any?(observed, fn
      %{"hash" => observed_hash} -> same_hash?(observed_hash, hash, network)
      _other -> false
    end)
  end

  @doc false
  @spec canonical_hash(String.t(), String.t()) :: String.t()
  def canonical_hash(hash, network) do
    if hex_hash_network?(network), do: normalize_hex(hash), else: hash
  end

  defp verify_with_status(hash, config) do
    case OneClick.status(config, config["deposit_address"], config["deposit_memo"]) do
      {:ok, %{"status" => status} = result} when is_binary(status) ->
        verify_observed_status(result, hash, config)

      {:ok, _response} ->
        {:error, Errors.new(:settlement_unavailable, "1Click returned an invalid status response")}

      {:error, :unavailable} ->
        {:error, Errors.new(:settlement_unavailable, "1Click status endpoint is unavailable")}

      {:error, {:rejected, status, _body}} ->
        {:error, Errors.new(:verification_failed, "1Click rejected the deposit status request (HTTP #{status})")}
    end
  end

  defp verify_observed_status(status, hash, config) do
    cond do
      !observed_hash?(status, hash, config["origin_network"]) ->
        {:error, Errors.new(:verification_failed, "Presented hash was not observed for this deposit address")}

      status["status"] == "INCOMPLETE_DEPOSIT" ->
        :ok

      sufficient_deposit?(status, config) ->
        :ok

      true ->
        {:error, Errors.new(:payment_insufficient, "Observed deposit is below minAmountIn")}
    end
  end

  defp sufficient_deposit?(status, config) do
    deposited = get_in(status, ["swapDetails", "depositedAmount"])

    with {actual, ""} <- Integer.parse(deposited || ""),
         {:ok, minimum} <- parse_minimum(config) do
      actual >= minimum
    else
      _other -> false
    end
  end

  defp verify_with_rpc(hash, charge, %{"origin_network" => "eip155:" <> _} = config, rpc_url) do
    with {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
         :ok <- Shared.check_receipt_status(receipt),
         {:ok, minimum} <- parse_minimum(config) do
      verify_evm_transfer(receipt, hash, charge, minimum, rpc_url, config)
    end
  end

  defp verify_with_rpc(_hash, _charge, _config, _rpc_url) do
    {:error, Errors.new(:settlement_unavailable, "Direct origin RPC verification supports eip155 origins")}
  end

  defp verify_evm_transfer(receipt, hash, charge, minimum, rpc_url, config) do
    case parse_evm_asset(charge.currency, config["origin_network"]) do
      {:ok, {:erc20, token}} -> verify_erc20(receipt, charge.recipient, token, minimum)
      {:ok, :native} -> verify_native(hash, charge.recipient, minimum, rpc_url, config)
      :error -> {:error, Errors.new(:verification_failed, "Invalid origin asset for configured network")}
    end
  end

  defp verify_erc20(%{logs: logs}, recipient, token, minimum) when is_binary(recipient) do
    with {:ok, transfers} <- Onchain.Transfer.parse_logs(logs) do
      if Enum.any?(transfers, &matching_transfer?(&1, token, recipient, minimum)) do
        :ok
      else
        {:error, Errors.new(:verification_failed, "Origin transaction does not contain the required deposit")}
      end
    end
  end

  defp verify_erc20(_receipt, _recipient, _token, _minimum) do
    {:error, Errors.new(:verification_failed, "Origin transaction does not contain the required deposit")}
  end

  defp matching_transfer?(transfer, token, recipient, minimum) do
    Onchain.Address.equal?(transfer.token, token) and
      Onchain.Address.equal?(transfer.to, recipient) and transfer.amount >= minimum
  end

  defp verify_native(hash, recipient, minimum, rpc_url, config) when is_binary(recipient) do
    case Onchain.RPC.get_transaction_by_hash(hash, rpc_opts(rpc_url, config)) do
      {:ok, %{to: to, value: value}} when is_integer(value) ->
        if Onchain.Address.equal?(to, recipient) and value >= minimum do
          :ok
        else
          {:error, Errors.new(:verification_failed, "Origin transaction does not contain the required deposit")}
        end

      {:ok, _transaction} ->
        {:error, Errors.new(:verification_failed, "Origin transaction does not contain the required deposit")}

      {:error, reason} ->
        Logger.warning("MPP.Methods.NearIntents: origin transaction RPC failed: #{inspect(reason)}")
        {:error, Errors.new(:settlement_unavailable, "Origin RPC request failed")}
    end
  end

  defp verify_native(_hash, _recipient, _minimum, _rpc_url, _config) do
    {:error, Errors.new(:verification_failed, "Near Intents method requires a deposit address")}
  end

  defp fetch_receipt(hash, rpc_url, config) do
    case Onchain.RPC.get_transaction_receipt(hash, rpc_opts(rpc_url, config)) do
      {:ok, nil} ->
        {:error, Errors.new(:verification_failed, "Origin transaction was not found")}

      {:ok, receipt} ->
        {:ok, receipt}

      {:error, reason} ->
        Logger.warning("MPP.Methods.NearIntents: origin receipt RPC failed: #{inspect(reason)}")
        {:error, Errors.new(:settlement_unavailable, "Origin RPC request failed")}
    end
  end

  defp parse_minimum(config) do
    case Integer.parse(config["min_amount_in"] || "") do
      {minimum, ""} when minimum >= 0 -> {:ok, minimum}
      _ -> {:error, Errors.new(:verification_failed, "Invalid minAmountIn")}
    end
  end

  defp parse_evm_asset(currency, network) do
    prefix = network <> "/"

    case currency do
      ^prefix <> "erc20:" <> token -> {:ok, {:erc20, token}}
      ^prefix <> "slip44:60" -> {:ok, :native}
      _ -> :error
    end
  end

  defp rpc_opts(rpc_url, config) do
    case config["origin_req_options"] do
      nil -> [rpc_url: rpc_url]
      req_options -> [rpc_url: rpc_url, req_options: req_options]
    end
  end

  defp same_hash?(left, right, network) when is_binary(left) and is_binary(right) do
    canonical_hash(left, network) == canonical_hash(right, network)
  end

  defp same_hash?(_left, _right, _network), do: false

  defp hex_hash_network?("eip155:" <> _reference), do: true
  defp hex_hash_network?("bip122:" <> _reference), do: true
  defp hex_hash_network?(_network), do: false

  defp normalize_hex(hash), do: hash |> String.trim_leading("0x") |> String.downcase()
end
