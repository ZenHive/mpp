defmodule MPP.X402.Nonce do
  @moduledoc """
  x402 exact EIP-3009 nonce rules.

  Native Payment-auth credentials use `MPP.Methods.EVM.Authorization.challenge_hash/2`
  (`keccak256(id <> realm)`). x402 exact uses a random 32-byte nonce, or an
  mppx extension-bound SHA-256 nonce when `extensions.mppx` is present
  (`refs/mppx/src/x402/client/Exact.ts` and `internal/RouteBinding.ts`). The
  two contracts must not accept each other's nonces.
  """

  alias MPP.JCS
  alias MPP.Methods.EVM.Authorization

  @mppx_key "mppx"

  @doc "Return the x402 exact nonce contract for this payload (`:random` or `:extension_bound`)."
  @spec contract(map() | nil) :: :random | :extension_bound
  def contract(%{"mppx" => _mppx}), do: :extension_bound
  def contract(_extensions), do: :random

  @doc "Generate a random 32-byte `0x`-prefixed EIP-3009 nonce."
  @spec random() :: String.t()
  def random do
    "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end

  @doc """
  Compute the mppx extension-bound nonce.

  SHA-256 of `serialize(accepted)|serialize(resource)|serialize(extensions)`
  where `serialize` is JCS then base64url (no padding), matching
  `refs/mppx/src/x402/internal/RouteBinding.ts`.
  """
  @spec extension_bound(map(), map(), map()) :: String.t()
  def extension_bound(accepted, resource, extensions) when is_map(accepted) and is_map(resource) and is_map(extensions) do
    input = Enum.map_join([accepted, resource, extensions], "|", &serialize/1)

    "0x" <> Base.encode16(:crypto.hash(:sha256, input), case: :lower)
  end

  @doc """
  Return true when `nonce` is the native challengeHash for `id`/`realm`.

  Used to prove the shared signing primitive cannot satisfy the x402 contract
  by presenting a native nonce, and vice versa.
  """
  @spec challenge_hash?(String.t(), String.t(), String.t()) :: boolean()
  def challenge_hash?(nonce, id, realm) when is_binary(nonce) and is_binary(id) and is_binary(realm) do
    String.downcase(nonce) == String.downcase(Authorization.challenge_hash(id, realm))
  end

  @doc "Insert a fresh `info.nonce` salt under `extensions.mppx` for extension-bound signing."
  @spec with_nonce_salt(map()) :: map()
  def with_nonce_salt(%{@mppx_key => mppx} = extensions) when is_map(mppx) do
    info = Map.get(mppx, "info", %{})
    info = if is_map(info), do: info, else: %{}
    mppx = Map.put(mppx, "info", Map.put(info, "nonce", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)))
    Map.put(extensions, @mppx_key, mppx)
  end

  def with_nonce_salt(extensions) when is_map(extensions), do: extensions

  defp serialize(term), do: term |> JCS.canonicalize() |> Base.url_encode64(padding: false)
end
