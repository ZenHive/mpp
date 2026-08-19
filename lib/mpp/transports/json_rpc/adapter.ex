defmodule MPP.Transports.JsonRpc.Adapter do
  @moduledoc false
  # Shared JSON-RPC payment verification used by the generic JSON-RPC transport
  # (`MPP.Transports.JsonRpc`, root-level `_meta`) and MCP (`MPP.Mcp`, nested
  # `params`/`result._meta`). One authorize path so replay, telemetry, and error
  # codes stay byte-identical across placements.
  #
  # Spec: paymentauth.org draft-payment-transport-mcp-00 § Metadata Placement —
  # servers MUST check both root-level `_meta` and nested `params._meta`.

  alias MPP.Errors
  alias MPP.Mcp
  alias MPP.Plug.Config
  alias MPP.Receipt
  alias MPP.Replay
  alias MPP.Telemetry
  alias MPP.Transports.JsonRpc
  alias MPP.Verifier

  @payment_required_code -32_042
  @verification_failed_code -32_043
  @invalid_params_code -32_602

  @type receipt_at :: :root | :nested

  @doc """
  Verify a JSON-RPC request and invoke `handler`, attaching the receipt at
  `:root` (generic JSON-RPC) or `:nested` (MCP `result._meta`).
  """
  @spec call(map(), Config.t(), (map() -> term()), receipt_at()) :: map()
  def call(%{} = request, %Config{} = config, handler, receipt_at)
      when is_function(handler, 1) and receipt_at in [:root, :nested] do
    case authorize(request, config) do
      {:ok, receipt, challenge_id} ->
        request
        |> handler.()
        |> wrap_handler_response(request)
        |> attach_response_receipt(receipt, challenge_id, receipt_at)

      {:error, response} ->
        response
    end
  end

  defp authorize(request, config) do
    case JsonRpc.extract_credential(request) do
      {:ok, credential} -> verify_credential(request, config, credential)
      {:error, :no_credential} -> missing_credential_response(request, config)
      {:error, reason} -> malformed_credential_response(request, config, reason)
    end
  end

  defp missing_credential_response(request, config) do
    error = Errors.new(:payment_required, "No payment credential provided")
    challenges = generate_challenges(config)

    {:error, error_response(request, @payment_required_code, "Payment Required", challenges, error)}
  end

  defp malformed_credential_response(request, config, reason) do
    error = Errors.new(:malformed_credential, "#{reason}")
    challenges = generate_challenges(config)

    {:error, error_response(request, @invalid_params_code, error.title, challenges, error)}
  end

  defp verify_credential(request, config, credential) do
    case find_method_entry(config, credential.challenge.method) do
      nil ->
        error = Errors.new(:method_unsupported, "Unknown payment method: #{credential.challenge.method}")
        challenges = generate_challenges(config)

        {:error, error_response(request, @verification_failed_code, error.title, challenges, error)}

      entry ->
        verify_with_entry(request, config, credential, entry)
    end
  end

  defp verify_with_entry(request, config, credential, entry) do
    store = Replay.store_for(config, entry)

    opts = [
      secret_key: config.secret_key,
      realm: config.realm,
      method: entry.method,
      charge: entry.charge,
      method_config: entry.method_config,
      digest: config.digest,
      opaque: config.opaque
    ]

    case Replay.check_unused(store, credential) do
      {:error, %Errors{} = error} ->
        start_time = Telemetry.verify_start(credential, entry.charge, %{realm: config.realm})
        Telemetry.verify_fail(credential, entry.charge, start_time, error, %{realm: config.realm})
        {:error, error_response(request, error_code(error), error.title, generate_challenges(config), error)}

      :ok ->
        with {:ok, receipt} <- Verifier.verify(credential, opts),
             :ok <- Replay.mark_used(store, credential) do
          {:ok, receipt, credential.challenge.id}
        else
          {:error, %Errors{} = error} ->
            challenges = generate_challenges(config)
            {:error, error_response(request, error_code(error), error.title, challenges, error)}
        end
    end
  end

  defp find_method_entry(%Config{} = config, method_name) do
    Enum.find(config.method_entries, fn entry ->
      entry.method.method_name() == method_name
    end)
  end

  defp generate_challenges(%Config{} = config) do
    Enum.map(config.method_entries, &MPP.Plug.generate_challenge(config, &1))
  end

  defp error_response(request, code, message, challenges, %Errors{} = error) do
    data = %{
      "httpStatus" => error.status,
      "challenges" => Mcp.payment_required_error(challenges)["data"]["challenges"],
      "problem" => Errors.to_map(error)
    }

    data =
      case error.retry_after do
        seconds when is_integer(seconds) -> Map.put(data, "retryAfter", seconds)
        nil -> data
      end

    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id"),
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      }
    }
  end

  defp error_code(%Errors{type: "https://paymentauth.org/problems/payment-required"}), do: @payment_required_code

  defp error_code(%Errors{type: "https://zenhive.github.io/mpp/problems/sponsor-capacity-exhausted"}),
    do: @payment_required_code

  defp error_code(%Errors{type: "https://paymentauth.org/problems/malformed-credential"}), do: @invalid_params_code
  defp error_code(%Errors{}), do: @verification_failed_code

  @doc false
  @spec wrap_handler_response(term(), map()) :: map()
  def wrap_handler_response({:ok, response}, request) when is_map(response), do: wrap_handler_response(response, request)

  def wrap_handler_response({:error, response}, request) when is_map(response),
    do: wrap_handler_response(response, request)

  def wrap_handler_response(%{"jsonrpc" => _, "result" => _} = response, _request), do: response
  def wrap_handler_response(%{"jsonrpc" => _, "error" => _} = response, _request), do: response

  def wrap_handler_response(%{"result" => _} = response, request) do
    response
    |> Map.put_new("jsonrpc", "2.0")
    |> Map.put_new("id", Map.get(request, "id"))
  end

  def wrap_handler_response(%{"error" => _} = response, request) do
    response
    |> Map.put_new("jsonrpc", "2.0")
    |> Map.put_new("id", Map.get(request, "id"))
  end

  def wrap_handler_response(result, request) when is_map(result) do
    %{"jsonrpc" => "2.0", "id" => Map.get(request, "id"), "result" => result}
  end

  def wrap_handler_response(result, request)
      when is_binary(result) or is_list(result) or is_number(result) or is_boolean(result) or is_nil(result) do
    %{"jsonrpc" => "2.0", "id" => Map.get(request, "id"), "result" => result}
  end

  defp attach_response_receipt(%{"error" => _} = response, _receipt, _challenge_id, _receipt_at), do: response

  defp attach_response_receipt(%{"result" => result} = response, %Receipt{} = receipt, challenge_id, :nested)
       when is_map(result) do
    Map.put(response, "result", Mcp.attach_receipt(result, receipt, challenge_id))
  end

  defp attach_response_receipt(response, %Receipt{} = receipt, challenge_id, :root) do
    Mcp.attach_receipt(response, receipt, challenge_id)
  end
end
