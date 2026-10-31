defmodule MPP.Session.Voucher do
  @moduledoc """
  TIP-1034 Tempo Channel Reserve voucher and EIP-712 signature verification.

  The signed type is `Voucher(bytes32 channelId,uint96 cumulativeAmount)`
  under the `TIP20 Channel Reserve` version `1` domain. Signatures are canonical
  65-byte secp256k1 signatures, matching the contract-backed mppx voucher path.

  A cooperative close is authorized by a second signature over the distinct
  type `CloseAuthorization(bytes32 channelId,uint96 cumulativeAmount)` under the
  same domain, so a voucher signature never authorizes a close (mppx
  `Voucher.ts` `closeAuthorizationTypes`, mpp-rs `precompile_voucher.rs`
  `CloseAuthorization`). The struct's `signature` then holds the close
  authorization signature.
  """

  import Bitwise, only: [<<<: 2]

  alias MPP.Session.Channel
  alias Onchain.Address
  alias Onchain.Hash
  alias Onchain.Hex
  alias Onchain.Recover
  alias Onchain.Signature
  alias Onchain.Typed
  alias Onchain.Typed.Domain
  alias Onchain.Typed.Type

  @domain_name "TIP20 Channel Reserve"
  @domain_version "1"
  @primary_type "Voucher"
  @close_primary_type "CloseAuthorization"
  @max_cumulative_amount (1 <<< 96) - 1
  @max_chain_id (1 <<< 256) - 1

  @type t :: %__MODULE__{
          channel_id: String.t(),
          cumulative_amount: non_neg_integer(),
          signature: String.t()
        }

  @enforce_keys [:channel_id, :cumulative_amount, :signature]
  defstruct [:channel_id, :cumulative_amount, :signature]

  @doc "Create a validated signed voucher."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    cumulative_amount = Keyword.get(opts, :cumulative_amount)

    with {:ok, channel_id} <- Channel.normalize_id(Keyword.get(opts, :channel_id)),
         :ok <- validate_cumulative_amount(cumulative_amount),
         {:ok, signature, _decoded} <- decode_signature(Keyword.get(opts, :signature)) do
      {:ok,
       %__MODULE__{
         channel_id: channel_id,
         cumulative_amount: cumulative_amount,
         signature: signature
       }}
    end
  end

  @doc "Create a signed voucher, raising `ArgumentError` on invalid input."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, voucher} -> voucher
      {:error, reason} -> raise ArgumentError, "invalid session voucher: #{inspect(reason)}"
    end
  end

  @doc "Build the EIP-712 typed data for a voucher."
  @spec typed_data(t(), String.t(), non_neg_integer()) :: {:ok, Typed.t()} | {:error, term()}
  def typed_data(%__MODULE__{} = voucher, escrow_contract, chain_id),
    do: build_typed_data(voucher, escrow_contract, chain_id, @primary_type)

  @doc "Build the EIP-712 typed data for a cooperative close authorization."
  @spec close_authorization_typed_data(t(), String.t(), non_neg_integer()) :: {:ok, Typed.t()} | {:error, term()}
  def close_authorization_typed_data(%__MODULE__{} = authorization, escrow_contract, chain_id),
    do: build_typed_data(authorization, escrow_contract, chain_id, @close_primary_type)

  @doc "Compute the 32-byte EIP-712 close authorization signing digest."
  @spec close_authorization_hash(t(), String.t(), non_neg_integer()) :: {:ok, <<_::256>>} | {:error, term()}
  def close_authorization_hash(%__MODULE__{} = authorization, escrow_contract, chain_id) do
    with {:ok, typed_data} <- close_authorization_typed_data(authorization, escrow_contract, chain_id) do
      {:ok, typed_data |> Typed.encode() |> Hash.keccak()}
    end
  end

  @doc """
  Verify that a close authorization signature recovers to one of the
  expected signers (the channel payer or its authorized signer).
  """
  @spec verify_close_authorization(t(), String.t(), non_neg_integer(), [String.t()]) :: :ok | {:error, term()}
  def verify_close_authorization(%__MODULE__{} = authorization, escrow_contract, chain_id, expected_signers)
      when is_list(expected_signers) do
    with {:ok, digest} <- close_authorization_hash(authorization, escrow_contract, chain_id),
         {:ok, _signature_hex, signature} <- decode_signature(authorization.signature),
         {:ok, expected} <- validate_expected_signers(expected_signers),
         {:ok, recovered} <- recover_address(digest, signature) do
      if recovered in expected,
        do: :ok,
        else: {:error, :signature_mismatch}
    end
  end

  defp build_typed_data(%__MODULE__{} = voucher, escrow_contract, chain_id, primary_type) do
    with {:ok, channel_id} <- decode_channel_id(voucher.channel_id),
         :ok <- validate_cumulative_amount(voucher.cumulative_amount),
         {:ok, escrow_contract} <- validate_escrow_contract(escrow_contract),
         :ok <- validate_chain_id(chain_id) do
      {:ok,
       %Typed{
         domain: %Domain{
           name: @domain_name,
           version: @domain_version,
           chain_id: chain_id,
           verifying_contract: escrow_contract
         },
         types: signed_types(primary_type),
         value: %{
           "channelId" => channel_id,
           "cumulativeAmount" => voucher.cumulative_amount
         }
       }}
    end
  end

  @doc "Build voucher typed data, raising `ArgumentError` on invalid input."
  @spec typed_data!(t(), String.t(), non_neg_integer()) :: Typed.t()
  def typed_data!(%__MODULE__{} = voucher, escrow_contract, chain_id) do
    case typed_data(voucher, escrow_contract, chain_id) do
      {:ok, typed_data} -> typed_data
      {:error, reason} -> raise ArgumentError, "invalid voucher typed data: #{inspect(reason)}"
    end
  end

  @doc "Compute the 32-byte EIP-712 voucher signing digest."
  @spec hash(t(), String.t(), non_neg_integer()) :: {:ok, <<_::256>>} | {:error, term()}
  def hash(%__MODULE__{} = voucher, escrow_contract, chain_id) do
    with {:ok, typed_data} <- typed_data(voucher, escrow_contract, chain_id) do
      {:ok, typed_data |> Typed.encode() |> Hash.keccak()}
    end
  end

  @doc "Compute the voucher signing digest, raising `ArgumentError` on invalid input."
  @spec hash!(t(), String.t(), non_neg_integer()) :: <<_::256>>
  def hash!(%__MODULE__{} = voucher, escrow_contract, chain_id) do
    case hash(voucher, escrow_contract, chain_id) do
      {:ok, digest} -> digest
      {:error, reason} -> raise ArgumentError, "invalid voucher signing data: #{inspect(reason)}"
    end
  end

  @doc "Verify that a voucher signature recovers to the expected signer."
  @spec verify_signature(t(), String.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, term()}
  def verify_signature(%__MODULE__{} = voucher, escrow_contract, chain_id, expected_signer) do
    with {:ok, digest} <- hash(voucher, escrow_contract, chain_id),
         {:ok, _signature_hex, signature} <- decode_signature(voucher.signature),
         {:ok, expected_signer} <- validate_expected_signer(expected_signer),
         {:ok, recovered} <- recover_address(digest, signature) do
      if recovered == expected_signer,
        do: :ok,
        else: {:error, :signature_mismatch}
    end
  end

  @spec signed_types(String.t()) :: %{String.t() => Type.t()}
  defp signed_types(primary_type) do
    %{
      primary_type => %Type{
        fields: [
          {"channelId", {:bytes, 32}},
          {"cumulativeAmount", {:uint, 96}}
        ]
      }
    }
  end

  defp decode_channel_id(channel_id) do
    with {:ok, normalized} <- Channel.normalize_id(channel_id) do
      Hex.decode(normalized)
    end
  end

  defp validate_escrow_contract(escrow_contract) do
    case Address.validate(escrow_contract) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> {:error, :invalid_escrow_contract}
    end
  end

  defp validate_expected_signer(expected_signer) do
    case Address.validate(expected_signer) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> {:error, :invalid_expected_signer}
    end
  end

  defp validate_expected_signers([_ | _] = signers) do
    Enum.reduce_while(signers, {:ok, []}, fn signer, {:ok, acc} ->
      case validate_expected_signer(signer) do
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_expected_signers(_signers), do: {:error, :invalid_expected_signer}

  defp validate_cumulative_amount(amount) when is_integer(amount) and amount >= 0 and amount <= @max_cumulative_amount,
    do: :ok

  defp validate_cumulative_amount(_amount), do: {:error, :invalid_cumulative_amount}

  defp validate_chain_id(chain_id) when is_integer(chain_id) and chain_id >= 0 and chain_id <= @max_chain_id, do: :ok
  defp validate_chain_id(_chain_id), do: {:error, :invalid_chain_id}

  # Only low-s signatures are accepted: the escrow settles canonical signatures
  # only (mpp-rs voucher.rs `canonical_voucher_signature`).
  defp decode_signature(signature_hex) when is_binary(signature_hex) do
    with {:ok, <<r::binary-size(32), s::binary-size(32), v>> = signature} <- Hex.decode(signature_hex),
         true <- v in [27, 28],
         %Signature{} = decoded <- signature_struct(r, s, v),
         true <- decoded.s > 0 and Signature.normalize(decoded) == decoded do
      {:ok, Hex.encode(signature), decoded}
    else
      _error -> {:error, :invalid_signature}
    end
  end

  defp decode_signature(_signature_hex), do: {:error, :invalid_signature}

  defp signature_struct(r, s, v) do
    %Signature{
      r: :binary.decode_unsigned(r),
      s: :binary.decode_unsigned(s),
      recid: v - 27
    }
  end

  defp recover_address(digest, signature) do
    {:ok, Recover.recover_eth_from_digest(digest, signature)}
  rescue
    _error in [ArgumentError, FunctionClauseError] -> {:error, :signature_recovery_failed}
  end
end
