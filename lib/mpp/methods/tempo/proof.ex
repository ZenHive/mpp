defmodule MPP.Methods.Tempo.Proof do
  @moduledoc """
  EIP-712 proof credentials for zero-amount Tempo charge flows.

  Wallet-bound MPP domain version `3`: the signed `account` field binds the
  proof to a specific payer so it cannot be replayed against another wallet for
  the same challenge. Matches `refs/mppx/src/tempo/internal/proof.ts`.
  """

  use Cartouche.Hex

  alias Cartouche.Hash
  alias Cartouche.Recover
  alias Cartouche.Typed
  alias Cartouche.Typed.Domain
  alias Cartouche.Typed.Type
  alias Curvy.Signature, as: CurvySignature

  @domain_name "MPP"
  @domain_version "3"
  @primary_type "Proof"

  @type params :: %{
          account: String.t(),
          chain_id: non_neg_integer(),
          challenge_id: String.t(),
          realm: String.t()
        }

  @doc """
  Build the EIP-712 typed-data map for a Tempo proof credential.
  """
  @spec typed_data(params()) :: Typed.t()
  def typed_data(%{account: account, chain_id: chain_id, challenge_id: challenge_id, realm: realm}) do
    %Typed{
      domain: %Domain{name: @domain_name, version: @domain_version, chain_id: chain_id},
      types: proof_types(),
      value: %{
        "account" => decode_address!(account),
        "challengeId" => challenge_id,
        "realm" => realm
      }
    }
  end

  @doc """
  Compute the EIP-712 signing digest (32-byte binary) for a proof credential.
  """
  @spec hash(params()) :: <<_::256>>
  def hash(params) do
    params
    |> typed_data()
    |> Typed.encode()
    |> Hash.keccak()
  end

  @doc """
  Verify a proof signature recovers to `expected_account`.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec verify_signature(params(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def verify_signature(params, signature_hex, expected_account) do
    digest = hash(params)

    with {:ok, signature} <- decode_signature(signature_hex),
         {:ok, recovered} <- recover_address(digest, signature, expected_account) do
      if Onchain.Address.equal?(recovered, expected_account),
        do: :ok,
        else: {:error, "Proof signature does not match source"}
    end
  end

  @spec proof_types() :: %{String.t() => Type.t()}
  defp proof_types do
    %{
      @primary_type => %Type{
        fields: [
          {"account", :address},
          {"challengeId", :string},
          {"realm", :string}
        ]
      }
    }
  end

  @spec decode_address!(String.t()) :: <<_::160>>
  defp decode_address!(address) do
    hex = strip_0x(address)

    case Base.decode16(hex, case: :mixed) do
      {:ok, <<addr::binary-size(20)>>} -> addr
      _ -> raise ArgumentError, "invalid proof account address"
    end
  end

  @spec decode_signature(String.t()) :: {:ok, CurvySignature.t()} | {:error, String.t()}
  defp decode_signature(signature_hex) when is_binary(signature_hex) do
    hex = strip_0x(signature_hex)

    with {:ok, <<r::binary-size(32), s::binary-size(32), _v>> = bytes} <- Base.decode16(hex, case: :mixed),
         true <- byte_size(bytes) == 65 do
      {:ok,
       %CurvySignature{
         crv: :secp256k1,
         r: :binary.decode_unsigned(r),
         s: :binary.decode_unsigned(s),
         recid: nil
       }}
    else
      _ -> {:error, "invalid proof signature"}
    end
  end

  @spec recover_address(<<_::256>>, CurvySignature.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp recover_address(digest, signature, expected_account) do
    expected = decode_address!(expected_account)

    case Recover.find_recid_from_digest(digest, signature, expected) do
      {:ok, recid} ->
        recovered = Recover.recover_eth_from_digest(digest, %{signature | recid: recid})
        {:ok, to_hex(recovered)}

      {:error, _} ->
        {:error, "proof signature recovery failed"}
    end
  rescue
    ArgumentError -> {:error, "invalid proof account address"}
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(hex), do: hex
end
