defmodule MPP.Client.Transport.MCP do
  @moduledoc """
  JSON-RPC implementation of `MPP.Client.Transport` for MCP.

  Operates on JSON-RPC request/response maps. Automatic pay-and-retry lives in
  `MPP.Client.MCP`; this transport only detects, parses, and attaches.

  ## Wire format

    * Payment-required response: JSON-RPC error code `-32042`
      (`MPP.Mcp.payment_required_code/0`), or `result._meta` carrying
      `org.paymentauth/payment-required`
    * Challenges: `error.data.challenges` (or the payment-required result
      metadata equivalent), parsed by `MPP.Mcp.extract_challenges/1`
    * Credential attachment: `params._meta["org.paymentauth/credential"]`
      via `MPP.Mcp.attach_credential/2`

  Detection and parsing accept a full JSON-RPC envelope, a bare error object,
  or a result/`_meta` fragment — the same shapes `MPP.Mcp` client helpers
  already unwrap.
  """

  use MPP.Client.Transport
  use Descripex, namespace: "/client"

  alias MPP.Challenge
  alias MPP.Client.Transport
  alias MPP.Credential
  alias MPP.Mcp

  api(:payment_required?, "Return true if the JSON-RPC message signals payment required.",
    params: [
      response: [kind: :value, description: "JSON-RPC response envelope, error object, or result fragment"]
    ],
    returns: %{type: :boolean, description: "true when the error code is -32042 or payment-required metadata is present"}
  )

  @impl Transport
  @spec payment_required?(term()) :: boolean()
  def payment_required?(response) when is_map(response), do: Mcp.payment_required?(response)

  @spec payment_required?(term()) :: false
  def payment_required?(_response), do: false

  api(:get_challenges, "Parse Payment challenges from a JSON-RPC payment-required message.",
    params: [
      response: [kind: :value, description: "JSON-RPC response envelope, error object, or result fragment"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, [challenge]}` on success, `{:error, reason}` otherwise"
    },
    errors: [:malformed_envelope, :no_challenges, :invalid_challenge]
  )

  @impl Transport
  @spec get_challenges(term()) :: {:ok, [Challenge.t()]} | {:error, term()}
  def get_challenges(response) when is_map(response), do: Mcp.extract_challenges(response)

  @spec get_challenges(term()) :: {:error, :malformed_envelope}
  def get_challenges(_response), do: {:error, :malformed_envelope}

  api(:set_credential, "Attach a credential at `params._meta[\"org.paymentauth/credential\"]`.",
    params: [
      request: [kind: :value, description: "JSON-RPC request envelope or MCP tool-params map"],
      credential: [kind: :value, description: "MPP.Credential struct"]
    ],
    returns: %{type: :map, description: "Request with the credential in `_meta`"}
  )

  @impl Transport
  @spec set_credential(map(), Credential.t()) :: map()
  def set_credential(%{} = request, %Credential{} = credential) do
    if json_rpc_request?(request) do
      params =
        case Map.get(request, "params") do
          %{} = map -> map
          _other -> %{}
        end

      Map.put(request, "params", Mcp.attach_credential(params, credential))
    else
      Mcp.attach_credential(request, credential)
    end
  end

  # JSON-RPC envelopes carry `jsonrpc` / `params` / `method`. MCP tool-call
  # params use `name` for the tool and never look like an envelope.
  defp json_rpc_request?(request) do
    Map.has_key?(request, "jsonrpc") or Map.has_key?(request, "params") or
      (is_binary(Map.get(request, "method")) and not Map.has_key?(request, "name"))
  end
end
