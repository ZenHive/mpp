defmodule MPP.Methods.Shared do
  @moduledoc """
  Verification helpers shared by the payment-method modules
  (`MPP.Methods.EVM`, `MPP.Methods.Tempo`, `MPP.Methods.Stripe`,
   `MPP.Methods.Solana`, `MPP.Methods.USDC`, `MPP.Methods.Stellar`,
   `MPP.Methods.XRPL`, `MPP.Methods.NearIntents`).

  These are small, method-agnostic building blocks. `require_config/3` takes a
  human-readable method `label` so its error message names the calling method.
  """

  alias MPP.Errors

  @doc """
  Fetch a required key from a method's config map.

  Returns `{:ok, value}`, or a `:verification_failed` error naming the method via
  `label` (e.g. `"EVM"`, `"Tempo"`, `"Stripe"`) and the missing `key`.
  """
  @spec require_config(map(), term(), String.t()) :: {:ok, term()} | {:error, Errors.t()}
  def require_config(config, key, label) do
    case config[key] do
      nil -> {:error, Errors.new(:verification_failed, "#{label} method missing required config: #{key}")}
      value -> {:ok, value}
    end
  end

  @doc """
  Assert an on-chain transaction receipt succeeded (`status == 1`).

  Returns `:ok`, or a `:verification_failed` error when the transaction reverted.
  """
  @spec check_receipt_status(map()) :: :ok | {:error, Errors.t()}
  def check_receipt_status(%{status: 1}), do: :ok

  def check_receipt_status(%{status: _}) do
    {:error, Errors.new(:verification_failed, "Transaction failed on-chain (reverted)")}
  end

  @doc """
  Parse a charge amount string into an integer.

  Returns `{:ok, integer}`, or a `:verification_failed` error when `amount` is
  not a valid integer string.
  """
  @spec parse_charge_amount(String.t()) :: {:ok, integer()} | {:error, Errors.t()}
  def parse_charge_amount(amount) do
    case Integer.parse(amount) do
      {int, ""} -> {:ok, int}
      _ -> {:error, Errors.new(:verification_failed, "Invalid charge amount: not a valid integer")}
    end
  end

  @doc """
  True when `url` is HTTPS without userinfo, or HTTP to loopback.
  """
  @spec valid_rpc_url?(term()) :: boolean()
  def valid_rpc_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  def valid_rpc_url?(_), do: false

  @doc """
  Poll timeout in milliseconds, defaulting to 60_000.
  """
  @spec poll_timeout_ms(map()) :: pos_integer()
  def poll_timeout_ms(config) when is_map(config), do: Map.get(config, "poll_timeout_ms", 60_000)
end
