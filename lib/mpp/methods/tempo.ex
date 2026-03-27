defmodule MPP.Methods.Tempo do
  @moduledoc """
  Tempo payment method — verifies payment via on-chain TIP-20 token transfer.

  Tempo supports two credential types:

    * `type="hash"` — Client already broadcast the transaction; server verifies
      the receipt via RPC (`eth_getTransactionReceipt`).
    * `type="transaction"` — Client sends a signed Tempo Transaction (0x76);
      server decodes, optionally adds fee payer signature, broadcasts, and verifies.

  ## Configuration

  Pass Tempo-specific config via `:method_config` in `MPP.Plug` opts:

      plug MPP.Plug,
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MPP.Methods.Tempo,
        amount: "1000000",
        currency: "0x20c0000000000000000000000000000000000000",
        method_config: %{
          "rpc_url" => "https://rpc.moderato.tempo.xyz",
          "chain_id" => 42431,
          "fee_payer" => false
        }

  ## Config Keys

    * `"rpc_url"` — (required) Tempo RPC endpoint URL
    * `"chain_id"` — (optional) network chain ID, defaults to `42431` (Moderato testnet)
    * `"fee_payer"` — (optional) enable server-side fee sponsorship, defaults to `false`
    * `"memo"` — (optional) bytes32 hex memo for `transferWithMemo`

  ## Credential Payload

  The credential `payload` map must contain one of:

    * `"type" => "hash"`, `"hash" => "0x..."` — transaction hash for receipt verification
    * `"type" => "transaction"`, `"signature" => "..."` — RLP-serialized signed Tempo Transaction

  ## Dependencies

  Requires the `onchain` package (optional dependency) for RPC calls and transfer
  log parsing. The method checks availability at init time via `validate_config!/1`.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge

  @moderato_chain_id 42_431
  @required_config_keys ~w(rpc_url)

  api(:method_name, "Return the payment method identifier for Tempo.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "tempo"

  api(
    :validate_config!,
    "Validate Tempo method_config at init time. Raises on missing `rpc_url` or unavailable `onchain` dependency.",
    params: [
      config: [kind: :value, description: "method_config map to validate"]
    ],
    returns: %{type: :atom, description: "`:ok` on success, raises `ArgumentError` on missing keys"}
  )

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    missing = Enum.filter(@required_config_keys, &is_nil(config[&1]))

    if missing != [] do
      raise ArgumentError,
            "MPP.Methods.Tempo requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end

    check_onchain_available!()

    :ok
  end

  api(:verify, "Verify a Tempo credential by checking on-chain settlement.",
    params: [
      payload: [
        kind: :value,
        description: ~s{Credential payload map with `"type"` (`"hash"` or `"transaction"`) and corresponding proof field}
      ],
      charge: [
        kind: :value,
        description: "Charge intent struct with amount, currency, and method_details (including `rpc_url`)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, error}` on failure"},
    errors: [:invalid_payload, :verification_failed]
  )

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, MPP.Receipt.t()} | {:error, Errors.t()}
  def verify(_payload, %Charge{}) do
    # TODO(Task 13b): Implement hash credential verification (type="hash")
    # TODO(Task 13c): Implement transaction credential verification (type="transaction")
    {:error, Errors.new(:verification_failed, "Tempo verification not yet implemented")}
  end

  api(
    :challenge_method_details,
    "Return Tempo-specific fields (`chainId`, `feePayer`, `memo`) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details containing `chain_id`, `fee_payer`, and optionally `memo`"
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with `chainId` (default 42431), `feePayer` (default false), and optional `memo`"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    details = %{
      "chainId" => config["chain_id"] || @moderato_chain_id,
      "feePayer" => config["fee_payer"] || false
    }

    case config["memo"] do
      nil -> details
      memo -> Map.put(details, "memo", memo)
    end
  end

  # Checks that the onchain library is available at runtime.
  defp check_onchain_available! do
    if !Code.ensure_loaded?(Onchain) do
      raise ArgumentError, """
      MPP.Methods.Tempo requires the `onchain` package.

      Add it to your mix.exs dependencies:

          {:onchain, "~> 0.4"}
      """
    end
  end
end
