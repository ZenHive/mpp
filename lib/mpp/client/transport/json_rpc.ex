defmodule MPP.Client.Transport.JsonRpc do
  @moduledoc """
  JSON-RPC implementation of `MPP.Client.Transport` for generic (non-MCP) RPC.

  Operates on JSON-RPC request/response maps. Challenges arrive in
  `error.data.challenges` on error code `-32042`; credentials are attached at
  the request's **root-level** `_meta["org.paymentauth/credential"]` so `params`
  may be an array (e.g. `eth_getBlockByNumber`).

  MCP's nested `params._meta` placement is `MPP.Client.Transport.MCP`.
  """

  use MPP.Client.Transport
  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.Transport
  alias MPP.Credential
  alias MPP.Transports.JsonRpc

  api(:payment_required?, "Return true if the JSON-RPC message signals payment required.",
    params: [
      response: [kind: :value, description: "JSON-RPC response envelope or error object"]
    ],
    returns: %{type: :boolean, description: "true when the error code is -32042"}
  )

  @impl Transport
  @spec payment_required?(term()) :: boolean()
  def payment_required?(response) when is_map(response), do: JsonRpc.payment_required?(response)

  @spec payment_required?(term()) :: false
  def payment_required?(_response), do: false

  api(:get_challenges, "Parse Payment challenges from a JSON-RPC payment-required message.",
    params: [
      response: [kind: :value, description: "JSON-RPC response envelope or error object"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, [challenge]}` on success, `{:error, reason}` otherwise"
    },
    errors: [:malformed_envelope, :no_challenges, :invalid_challenge]
  )

  @impl Transport
  @spec get_challenges(term()) :: {:ok, [Challenge.t()]} | {:error, term()}
  def get_challenges(response) when is_map(response), do: JsonRpc.extract_challenges(response)

  @spec get_challenges(term()) :: {:error, :malformed_envelope}
  def get_challenges(_response), do: {:error, :malformed_envelope}

  api(:set_credential, "Attach a credential at the JSON-RPC request's root `_meta`.",
    params: [
      request: [kind: :value, description: "JSON-RPC request envelope"],
      credential: [kind: :value, description: "MPP.Credential struct"]
    ],
    returns: %{type: :map, description: "Request with the credential in root `_meta`"}
  )

  @impl Transport
  @spec set_credential(map(), Credential.t()) :: map()
  def set_credential(%{} = request, %Credential{} = credential) do
    JsonRpc.attach_credential(request, credential)
  end
end
