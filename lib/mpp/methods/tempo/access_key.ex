defmodule MPP.Methods.Tempo.AccessKey do
  @moduledoc false

  alias Onchain.Address
  alias Onchain.Contract

  @account_keychain "0xaAAAaaAA00000000000000000000000000000000"

  @doc """
  Returns whether `access_key` is an active (non-revoked, unexpired) key for `account`.

  Reads the AccountKeychain precompile via `getKey`, matching
  `isActiveAccessKey` in `refs/mppx/src/tempo/server/Charge.ts`.
  """
  @spec active?(String.t(), String.t(), keyword()) :: boolean()
  def active?(account, access_key, opts) when is_binary(account) and is_binary(access_key) do
    with {:ok, account_bin} <- Address.validate(account),
         {:ok, access_key_bin} <- Address.validate(access_key),
         {:ok, [_signature_type, _key_id, expiry, _enforce_limits, is_revoked]} <-
           Contract.call(
             @account_keychain,
             "getKey(address,address)",
             [account_bin, access_key_bin],
             "(uint8,address,uint64,bool,bool)",
             opts
           ) do
      now = System.os_time(:second)
      not is_revoked and expiry > now
    else
      {:error, _} -> false
    end
  end
end
