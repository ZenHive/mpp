defmodule MPP.Transports.JsonRpc do
  @moduledoc """
  Bare JSON-RPC 2.0 payment transport (non-MCP).

  Payment challenges ride on the same JSON-RPC channel as the method call:
  a `-32042` error carries `error.data.challenges`, the client retries with
  `org.paymentauth/credential` on the **root-level** `_meta` field (so `params`
  may be an array), and a successful result returns `org.paymentauth/receipt`
  on the response's root `_meta`.

  This is the generic JSON-RPC placement from the MPP transport spec
  (paymentauth.org `draft-payment-transport-mcp-00` § Metadata Placement).
  MCP's nested `params._meta` / `result._meta` lives in `MPP.Mcp`. Servers
  accept credentials in **either** location.

  ## Server adapter

      config = MPP.Transports.JsonRpc.init(
        secret_key: secret,
        realm: "rpc.example.com",
        method: MyMethod,
        amount: "1000",
        currency: "usd"
      )

      MPP.Transports.JsonRpc.call(request, config, fn request ->
        dispatch(request)
      end)

  Mount on Plug with `MPP.Transports.JsonRpc.Plug`.
  """

  use Descripex, namespace: "/transports"

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Mcp
  alias MPP.Plug.Config
  alias MPP.Receipt
  alias MPP.Transports.JsonRpc.Adapter

  api(:init, "Build server-side JSON-RPC transport configuration from the same endpoint options as `MPP.Plug`.",
    params: [
      opts: [
        kind: :value,
        description: "Keyword options including :secret_key, :realm, and one or more payment methods"
      ]
    ],
    returns: %{type: :struct, description: "`MPP.Plug.Config` reused by the JSON-RPC server adapter"}
  )

  @spec init(keyword()) :: Config.t()
  def init(opts) when is_list(opts), do: MPP.Plug.init(opts)

  api(
    :call,
    "Run a JSON-RPC request through payment verification and attach a root-level `_meta` receipt on success.",
    params: [
      request: [kind: :value, description: "JSON-RPC request map; credential may be on root `_meta` or params._meta"],
      config: [kind: :value, description: "Transport config from init/1"],
      handler: [
        kind: :value,
        description: "Function receiving the request after verification and returning a JSON-RPC response or result"
      ]
    ],
    returns: %{
      type: :map,
      description: "JSON-RPC response with payment-required/verification error, or successful root `_meta` receipt"
    }
  )

  @spec call(map(), Config.t(), (map() -> term())) :: map()
  def call(%{} = request, %Config{} = config, handler) when is_function(handler, 1) do
    Adapter.call(request, config, handler, :root)
  end

  api(:extract_credential, "Extract a payment credential from root `_meta`, falling back to `params._meta`.",
    params: [
      request: [kind: :value, description: "JSON-RPC request map"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, credential}` or `{:error, :no_credential | :invalid_credential | :invalid_challenge}`"
    },
    errors: [:no_credential, :invalid_credential, :invalid_challenge]
  )

  @spec extract_credential(map()) ::
          {:ok, Credential.t()} | {:error, :no_credential | :invalid_credential | :invalid_challenge}
  def extract_credential(%{} = request) do
    case Mcp.extract_credential(request) do
      {:error, :no_credential} ->
        case Map.get(request, "params") do
          %{} = params -> Mcp.extract_credential(params)
          _other -> {:error, :no_credential}
        end

      other ->
        other
    end
  end

  api(:attach_credential, "Attach a payment credential at the JSON-RPC request's root `_meta`.",
    params: [
      request: [kind: :value, description: "JSON-RPC request map"],
      credential: [kind: :value, description: "An `MPP.Credential.t()` struct"]
    ],
    returns: %{type: :map, description: "Request with root `_meta` containing the credential"}
  )

  @spec attach_credential(map(), Credential.t()) :: map()
  def attach_credential(%{} = request, %Credential{} = credential) do
    Mcp.attach_credential(request, credential)
  end

  api(:attach_receipt, "Attach a payment receipt at the JSON-RPC response's root `_meta`.",
    params: [
      response: [kind: :value, description: "JSON-RPC response envelope"],
      receipt: [kind: :value, description: "An `MPP.Receipt.t()` struct"],
      challenge_id: [kind: :value, description: "The challenge ID this receipt fulfills"]
    ],
    returns: %{type: :map, description: "Response envelope with root `_meta` containing the receipt"}
  )

  @spec attach_receipt(map(), Receipt.t(), String.t()) :: map()
  def attach_receipt(%{} = response, %Receipt{} = receipt, challenge_id) when is_binary(challenge_id) do
    Mcp.attach_receipt(response, receipt, challenge_id)
  end

  api(:payment_required?, "Return true if a JSON-RPC error or envelope signals payment required (`-32042`).",
    params: [
      response: [kind: :value, description: "JSON-RPC error map or full response envelope"]
    ],
    returns: %{type: :boolean, description: "`true` if the error code is `-32042`"}
  )

  @spec payment_required?(map()) :: boolean()
  def payment_required?(%{} = response), do: Mcp.payment_required?(response)

  api(:extract_challenges, "Parse payment challenges from a JSON-RPC error map or full response envelope.",
    params: [
      response: [kind: :value, description: "JSON-RPC error map with `data.challenges`, or a full response envelope"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, [challenge]}` or `{:error, :no_challenges | :invalid_challenge}`"
    },
    errors: [:no_challenges, :invalid_challenge]
  )

  @spec extract_challenges(map()) :: {:ok, [Challenge.t()]} | {:error, :no_challenges | :invalid_challenge}
  def extract_challenges(%{} = response), do: Mcp.extract_challenges(response)

  api(:payment_required_code, "JSON-RPC error code for payment required (`-32042`).",
    returns: %{type: :integer, description: "Error code `-32042`"}
  )

  @spec payment_required_code :: integer()
  def payment_required_code, do: Mcp.payment_required_code()

  api(:verification_failed_code, "JSON-RPC error code for verification failed (`-32043`).",
    returns: %{type: :integer, description: "Error code `-32043`"}
  )

  @spec verification_failed_code :: integer()
  def verification_failed_code, do: Mcp.verification_failed_code()

  api(:credential_meta_key, "Metadata key for credentials in `_meta`.",
    returns: %{type: :string, description: ~s(Key `"org.paymentauth/credential"`)}
  )

  @spec credential_meta_key :: String.t()
  def credential_meta_key, do: Mcp.credential_meta_key()

  api(:receipt_meta_key, "Metadata key for receipts in `_meta`.",
    returns: %{type: :string, description: ~s(Key `"org.paymentauth/receipt"`)}
  )

  @spec receipt_meta_key :: String.t()
  def receipt_meta_key, do: Mcp.receipt_meta_key()
end
