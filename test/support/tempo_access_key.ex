defmodule MPP.Test.TempoAccessKey do
  @moduledoc false

  @viem_version "2.37.1"
  @script Path.expand("tempo_access_key.mjs", __DIR__)

  @type authorize_result :: %{
          root_address: String.t(),
          access_private_key: binary(),
          access_key_address: String.t()
        }

  @doc """
  Authorizes a fresh secp256k1 access key for `root_private_key` on Moderato.

  Shells out to viem/tempo via npx (dev/test only).
  """
  @spec authorize!(binary(), keyword()) :: authorize_result()
  def authorize!(root_private_key, opts \\ []) when is_binary(root_private_key) do
    rpc_url = Keyword.fetch!(opts, :rpc_url)
    root_hex = "0x" <> Base.encode16(root_private_key, case: :lower)

    payload = %{
      "action" => "authorize",
      "rootPrivateKey" => root_hex,
      "rpcUrl" => rpc_url,
      "chainId" => Keyword.get(opts, :chain_id, 42_431)
    }

    decode_result!(run_script!(payload))
  end

  @doc """
  Authorizes then revokes an access key for `root_private_key` on Moderato.
  """
  @spec authorize_and_revoke!(binary(), keyword()) :: authorize_result()
  def authorize_and_revoke!(root_private_key, opts \\ []) when is_binary(root_private_key) do
    rpc_url = Keyword.fetch!(opts, :rpc_url)
    root_hex = "0x" <> Base.encode16(root_private_key, case: :lower)

    payload = %{
      "action" => "revoke",
      "rootPrivateKey" => root_hex,
      "rpcUrl" => rpc_url,
      "chainId" => Keyword.get(opts, :chain_id, 42_431)
    }

    decode_result!(run_script!(payload))
  end

  @doc "Sign a proof digest with an access key (plain secp256k1 envelope)."
  @spec sign_proof!(<<_::256>>, binary(), binary()) :: String.t()
  def sign_proof!(digest, private_key, address_bytes) when is_binary(digest) and byte_size(digest) == 32 do
    {:ok, sig} = Cartouche.Signer.Curvy.sign_payload(digest, private_key)
    sig = Cartouche.Recover.normalize_low_s(sig)
    {:ok, recid} = Cartouche.Recover.find_recid_from_digest(digest, sig, address_bytes)

    r = sig.r |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    s = sig.s |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    "0x" <> r <> s <> Base.encode16(<<27 + recid>>, case: :lower)
  end

  defp run_script!(payload) do
    args = [
      "--yes",
      "-p",
      "viem@#{@viem_version}",
      "node",
      @script,
      Jason.encode!(payload)
    ]

    case System.cmd("npx", args, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, _} ->
        raise """
        Tempo access-key script failed.

        Output:
        #{String.trim(output)}
        """
    end
  end

  defp decode_result!(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"rootAddress" => root, "accessPrivateKey" => access_hex, "accessKeyAddress" => key_addr}} ->
        {:ok, access_private_key} = decode_key_hex(access_hex)

        %{
          root_address: root,
          access_private_key: access_private_key,
          access_key_address: key_addr
        }

      {:ok, %{"error" => message}} ->
        raise "Tempo access-key script error: #{message}"

      _ ->
        raise "Tempo access-key script returned unexpected output: #{inspect(output)}"
    end
  end

  defp decode_key_hex("0x" <> hex), do: Base.decode16(hex, case: :mixed)
  defp decode_key_hex(hex) when is_binary(hex), do: Base.decode16(hex, case: :mixed)
end
