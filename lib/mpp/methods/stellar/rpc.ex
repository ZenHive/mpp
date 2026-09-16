defmodule MPP.Methods.Stellar.RPC do
  @moduledoc false

  alias MPP.Errors
  alias MPP.Methods.Shared
  alias StellarBase.XDR.AccountEntry
  alias StellarBase.XDR.LedgerEntry
  alias StellarBase.XDR.LedgerEntryData
  alias StellarBase.XDR.LedgerEntryType
  alias StellarBase.XDR.LedgerKey
  alias StellarBase.XDR.SequenceNumber

  @passphrases %{
    "stellar:pubnet" => "Public Global Stellar Network ; September 2015",
    "stellar:testnet" => "Test SDF Network ; September 2015"
  }

  @xdr_errors [
    ArgumentError,
    FunctionClauseError,
    ErlangError,
    MatchError,
    Elixir.XDR.EnumError,
    Elixir.XDR.UnionError,
    Elixir.XDR.FixedArrayError,
    Elixir.XDR.VariableArrayError,
    Elixir.XDR.FixedOpaqueError,
    Elixir.XDR.VariableOpaqueError
  ]

  @doc false
  @spec passphrases() :: %{String.t() => String.t()}
  def passphrases, do: @passphrases

  @doc false
  @spec passphrase(String.t()) :: String.t() | nil
  def passphrase(network), do: Map.get(@passphrases, network)

  @doc false
  @spec valid_url?(term()) :: boolean()
  def valid_url?(url), do: Shared.valid_rpc_url?(url)

  @doc false
  @spec timeout(map()) :: pos_integer()
  def timeout(config) when is_map(config), do: Shared.poll_timeout_ms(config)

  @doc false
  @spec interval(map()) :: pos_integer()
  def interval(config) when is_map(config), do: Map.get(config, "poll_interval_ms", 1_000)

  @doc false
  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def call(config, method, params) when is_map(config) and is_binary(method) and is_map(params) do
    opts =
      Keyword.merge(Map.get(config, "req_options", []),
        json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        retry: false,
        receive_timeout: timeout(config)
      )

    case Req.post(config["rpc_url"], opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} when is_map(result) -> {:ok, result}
      {:ok, %{status: 200, body: %{"error" => error}}} -> rpc_error(error)
      {:error, _} -> unavailable()
      _ -> unavailable()
    end
  end

  @doc false
  @spec get_latest_ledger(map()) :: {:ok, pos_integer()} | {:error, Errors.t()}
  def get_latest_ledger(config) do
    case call(config, "getLatestLedger", %{}) do
      {:ok, %{"sequence" => sequence}} when is_integer(sequence) and sequence > 0 -> {:ok, sequence}
      {:error, %Errors{}} = error -> error
      _ -> unavailable()
    end
  end

  @doc false
  @spec simulate(String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def simulate(transaction, config) when is_binary(transaction) do
    case call(config, "simulateTransaction", %{"transaction" => transaction}) do
      {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
        {:error, Errors.new(:verification_failed, "Stellar simulation failed")}

      {:ok, result} ->
        {:ok, result}

      {:error, %Errors{}} = error ->
        error
    end
  end

  @doc false
  @spec send_transaction(String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def send_transaction(transaction, config) when is_binary(transaction) do
    case call(config, "sendTransaction", %{"transaction" => transaction}) do
      {:ok, %{"status" => status} = result} when status in ["PENDING", "DUPLICATE"] -> {:ok, result}
      {:ok, %{"status" => "ERROR"}} -> {:error, Errors.new(:settlement_failed, "Stellar sendTransaction returned ERROR")}
      {:ok, %{"status" => "TRY_AGAIN_LATER"}} -> unavailable()
      {:error, %Errors{}} = error -> error
      _ -> unavailable()
    end
  end

  @doc false
  @spec get_transaction(String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def get_transaction(hash, config) when is_binary(hash) do
    case call(config, "getTransaction", %{"hash" => String.downcase(hash)}) do
      {:ok, result} -> {:ok, result}
      {:error, %Errors{}} = error -> error
    end
  end

  @doc false
  @spec await_transaction(String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def await_transaction(hash, config) when is_binary(hash) do
    deadline = System.monotonic_time(:millisecond) + timeout(config)
    poll_transaction(hash, config, deadline, :infinity)
  end

  @doc false
  @spec await_existing(String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def await_existing(hash, config) when is_binary(hash) do
    deadline = System.monotonic_time(:millisecond) + timeout(config)
    poll_transaction(hash, config, deadline, 2)
  end

  @doc false
  @spec account_sequence(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, Errors.t()}
  def account_sequence(account, config) when is_binary(account) do
    case ledger_sequence(account, config) do
      {:ok, sequence} ->
        {:ok, sequence}

      _ ->
        horizon_sequence(account, config)
    end
  end

  defp ledger_sequence(account, config) do
    with {:ok, key} <- account_ledger_key(account),
         {:ok, %{"entries" => [%{"xdr" => xdr} | _]}} <- call(config, "getLedgerEntries", %{"keys" => [key]}),
         {:ok, sequence} <- decode_sequence(xdr) do
      {:ok, sequence}
    else
      {:error, %Errors{}} = error -> error
      _ -> :error
    end
  end

  defp horizon_sequence(account, config) do
    url = horizon_url(config) <> "/accounts/" <> account
    opts = Keyword.merge(Map.get(config, "req_options", []), retry: false, receive_timeout: timeout(config))

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: %{"sequence" => sequence}}} when is_binary(sequence) ->
        case Integer.parse(sequence) do
          {int, ""} -> {:ok, int}
          _ -> unavailable()
        end

      {:ok, %{status: 200, body: %{"sequence" => sequence}}} when is_integer(sequence) ->
        {:ok, sequence}

      {:error, _} ->
        unavailable()

      _ ->
        unavailable()
    end
  end

  defp horizon_url(%{"horizon_url" => url}) when is_binary(url), do: String.trim_trailing(url, "/")
  defp horizon_url(%{"network" => "stellar:pubnet"}), do: "https://horizon.stellar.org"
  defp horizon_url(_), do: "https://horizon-testnet.stellar.org"

  defp poll_transaction(hash, config, deadline, misses) do
    case get_transaction(hash, config) do
      {:ok, result} -> poll_result(result, hash, config, deadline, misses)
      {:error, %Errors{}} = error -> error
    end
  end

  defp poll_result(%{"status" => "SUCCESS"} = result, _hash, _config, _deadline, _misses), do: {:ok, result}
  defp poll_result(%{"status" => "FAILED"} = result, _hash, _config, _deadline, _misses), do: {:ok, result}

  defp poll_result(%{"status" => "NOT_FOUND"}, hash, config, deadline, misses) do
    cond do
      misses == 0 -> {:error, Errors.new(:verification_failed, "Stellar transaction was not found")}
      System.monotonic_time(:millisecond) >= deadline -> timeout()
      true -> sleep_and_poll(hash, config, deadline, next_misses(misses))
    end
  end

  defp poll_result(result, _hash, _config, _deadline, _misses) when is_map(result), do: {:ok, result}

  defp sleep_and_poll(hash, config, deadline, misses) do
    Process.sleep(interval(config))
    poll_transaction(hash, config, deadline, misses)
  end

  defp next_misses(:infinity), do: :infinity
  defp next_misses(misses) when is_integer(misses), do: misses - 1

  defp account_ledger_key(account) do
    case StellarBase.StrKey.decode(account, :ed25519_public_key) do
      {:ok, raw} ->
        key =
          raw
          |> StellarBase.XDR.UInt256.new()
          |> StellarBase.XDR.PublicKey.new(StellarBase.XDR.PublicKeyType.new())
          |> StellarBase.XDR.AccountID.new()
          |> StellarBase.XDR.Account.new()
          |> LedgerKey.new(LedgerEntryType.new(:ACCOUNT))
          |> LedgerKey.encode_xdr!()
          |> Base.encode64()

        {:ok, key}

      _ ->
        {:error, Errors.new(:verification_failed, "Invalid Stellar account")}
    end
  end

  # Stellar RPC documents getLedgerEntries[].xdr as LedgerEntryData
  # (https://developers.stellar.org/docs/data/apis/rpc/api-reference/methods/getLedgerEntries).
  # A full LedgerEntry is accepted as a fallback for older nodes.
  defp decode_sequence(xdr) when is_binary(xdr) do
    case Base.decode64(xdr) do
      {:ok, bytes} -> sequence_from_bytes(bytes)
      :error -> :error
    end
  end

  defp decode_sequence(_), do: :error

  defp sequence_from_bytes(bytes) do
    case ledger_entry_data_sequence(bytes) do
      {:ok, sequence} -> {:ok, sequence}
      _ -> full_ledger_entry_sequence(bytes)
    end
  end

  defp ledger_entry_data_sequence(bytes) do
    case LedgerEntryData.decode_xdr(bytes) do
      {:ok, {data, ""}} -> account_sequence(data)
      _ -> :error
    end
  rescue
    _ in @xdr_errors -> :error
  end

  defp full_ledger_entry_sequence(bytes) do
    case LedgerEntry.decode_xdr(bytes) do
      {:ok, {%LedgerEntry{data: data}, ""}} -> account_sequence(data)
      _ -> :error
    end
  rescue
    _ in @xdr_errors -> :error
  end

  defp account_sequence(%LedgerEntryData{
         type: %LedgerEntryType{identifier: :ACCOUNT},
         value: %AccountEntry{seq_num: %SequenceNumber{sequence_number: sequence}}
       })
       when is_integer(sequence) do
    {:ok, sequence}
  end

  defp account_sequence(_), do: :error

  defp rpc_error(_error), do: unavailable()

  defp unavailable, do: {:error, Errors.new(:settlement_unavailable, "Stellar RPC is unavailable")}
  defp timeout, do: {:error, Errors.new(:settlement_timeout, "Stellar transaction did not reach a terminal state")}
end
