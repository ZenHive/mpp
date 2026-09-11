defmodule MPP.Methods.XRPL.RPC do
  @moduledoc false

  @networks %{"mainnet" => 0, "testnet" => 1, "devnet" => 2}
  @miss_budget 2

  @doc false
  @spec networks() :: %{String.t() => 0 | 1 | 2}
  def networks, do: @networks

  @doc false
  @spec sha512_half(binary()) :: binary()
  def sha512_half(data) when is_binary(data) do
    <<digest::binary-32, _::binary>> = :crypto.hash(:sha512, data)
    digest
  end

  @doc false
  @spec hex?(term(), pos_integer()) :: boolean()
  def hex?(value, size) when is_binary(value) and byte_size(value) == size,
    do: match?({:ok, _}, Base.decode16(value, case: :mixed))

  def hex?(_, _), do: false

  @doc false
  @spec valid_url?(term()) :: boolean()
  def valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  def valid_url?(_), do: false

  @doc false
  @spec timeout(map()) :: pos_integer()
  def timeout(config) when is_map(config), do: Map.get(config, "poll_timeout_ms", 60_000)

  @doc false
  @spec call(map(), String.t(), map()) :: {:ok, map()} | :error
  def call(config, method, params) when is_map(config) and is_binary(method) and is_map(params) do
    opts =
      Keyword.merge(Map.get(config, "req_options", []),
        json: %{"method" => method, "params" => [Map.put(params, "api_version", 1)]},
        retry: false,
        receive_timeout: timeout(config)
      )

    case Req.post(config["rpc_url"], opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} when is_map(result) -> {:ok, result}
      _ -> :error
    end
  end

  @doc false
  @spec blob_hash(String.t()) :: String.t()
  def blob_hash(blob) when is_binary(blob) do
    blob
    |> Base.decode16!(case: :mixed)
    |> then(&sha512_half(<<"TXN", 0>> <> &1))
    |> Base.encode16()
  end

  @doc false
  @spec submit_blob(String.t(), map()) :: {:ok, String.t()} | :error
  def submit_blob(blob, config) when is_binary(blob) and is_map(config) do
    expected = blob_hash(blob)

    with {:ok, result} <- call(config, "submit", %{"tx_blob" => blob}),
         true <- result["engine_result"] in ["tesSUCCESS", "terQUEUED"],
         hash when is_binary(hash) <- get_in(result, ["tx_json", "hash"]),
         true <- hex?(hash, 64) and String.upcase(hash) == expected do
      {:ok, expected}
    else
      _ -> :error
    end
  end

  @doc false
  @spec check_network(map()) :: :ok | :error
  def check_network(config) when is_map(config) do
    with {:ok, %{"info" => %{"network_id" => id}}} <- call(config, "server_info", %{}),
         true <- id == @networks[config["network"]] do
      :ok
    else
      _ -> :error
    end
  end

  # A caller-supplied hash gets a bounded `txnNotFound` budget so a random hash
  # cannot make the server poll for the whole timeout on the caller's behalf.
  # A hash this server just submitted is known to exist, so `submitted: true`
  # lets propagation take the full deadline.
  @doc false
  @spec await_validated(String.t(), map(), keyword()) :: {:ok, map()} | :error
  def await_validated(hash, config, opts \\ []) when is_binary(hash) and is_map(config) and is_list(opts) do
    budget = if Keyword.get(opts, :submitted, false), do: :infinity, else: @miss_budget

    poll(hash, config, System.monotonic_time(:millisecond) + timeout(config), budget)
  end

  defp poll(hash, config, deadline, misses) do
    case call(config, "tx", %{"transaction" => hash, "binary" => false}) do
      {:ok, %{"validated" => true} = result} -> {:ok, result}
      {:ok, %{"error" => "txnNotFound"}} -> miss(hash, config, deadline, misses)
      {:ok, %{"validated" => false}} -> retry(hash, config, deadline, misses)
      _ -> :error
    end
  end

  defp miss(_hash, _config, _deadline, 0), do: :error
  defp miss(hash, config, deadline, :infinity), do: retry(hash, config, deadline, :infinity)
  defp miss(hash, config, deadline, misses), do: retry(hash, config, deadline, misses - 1)

  defp retry(hash, config, deadline, misses) do
    delay = Map.get(config, "poll_interval_ms", 1000)

    if System.monotonic_time(:millisecond) + delay < deadline do
      receive do
      after
        delay -> :ok
      end

      poll(hash, config, deadline, misses)
    else
      :error
    end
  end
end
