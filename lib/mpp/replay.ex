defmodule MPP.Replay do
  @moduledoc false
  # Shared credential-replay dedup used by BOTH transports — `MPP.Plug` (HTTP)
  # and `MPP.Mcp` (JSON-RPC) — so they enforce identical single-use protection.
  # Extracted from `MPP.Plug` so the MCP transport can't silently skip the
  # replay guard the Plug applies by default (the two must stay byte-identical:
  # same key prefix, same carve-out, same error text). Keep this the single
  # owner of the dedup step; do not re-inline it into either transport.

  alias MPP.Errors
  alias MPP.JCS
  alias MPP.Tempo.Store

  @store_key_prefix "mpp:credential:"
  @store_error_detail "Dedup store error"

  @doc """
  Selects the plug-level credential store for a method entry, honoring the
  Tempo carve-out.

  Tempo self-manages its own dedup (mpp:charge:/mpp:proof: + attribution
  binding), which already covers credential replay, so it resolves to `nil`.
  Every other method gets the shared store. EVM deliberately runs BOTH layers
  (plug credential store + its own mpp:evm: hash store) — disjoint keys,
  complementary guarantees; do not "fix" this by extending the carve-out.
  """
  @spec store_for(map(), map()) :: module() | {module(), keyword()} | nil
  def store_for(%{store: nil}, _entry), do: nil

  def store_for(%{store: store}, %{method: method}) do
    if method.method_name() == "tempo", do: nil, else: store
  end

  @doc """
  Rejects a credential whose challenge-bound key is already present in the store.

  Returns `:ok` when the store is `nil` (dedup disabled) or the key is unseen.
  """
  @spec check_unused(module() | {module(), keyword()} | nil, MPP.Credential.t()) :: :ok | {:error, Errors.t()}
  def check_unused(nil, _credential), do: :ok

  def check_unused(store, credential) do
    case Store.get(store, key(credential)) do
      :not_found -> :ok
      {:ok, _value} -> {:error, Errors.new(:verification_failed, "Payment credential already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @store_error_detail)}
    end
  end

  @doc """
  Atomically claims a credential as used (single-use).

  Stores are validated to implement `check_and_mark/2` at config time, so there
  is no non-atomic fallback (GHSA-w8j7-7qc3-5f24). Returns `:ok` when the store
  is `nil` (dedup disabled) or the claim succeeds.
  """
  @spec mark_used(module() | {module(), keyword()} | nil, MPP.Credential.t()) :: :ok | {:error, Errors.t()}
  def mark_used(nil, _credential), do: :ok

  def mark_used(store, credential) do
    value = System.system_time(:millisecond)

    case Store.check_and_mark(store, key(credential), value) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Payment credential already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @store_error_detail)}
    end
  end

  defp key(credential) do
    @store_key_prefix <> credential.challenge.id <> ":" <> payload_hash(credential.payload)
  end

  defp payload_hash(payload) do
    :sha256
    |> :crypto.hash(JCS.canonicalize(payload))
    |> Base.url_encode64(padding: false)
  end
end
