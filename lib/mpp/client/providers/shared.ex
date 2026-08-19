defmodule MPP.Client.Providers.Shared do
  @moduledoc false

  alias MPP.Challenge
  alias MPP.Codec
  alias MPP.Intents.Charge

  @doc false
  @spec parse_charge(Challenge.t(), String.t()) :: {:ok, Charge.t()} | {:error, term()}
  def parse_charge(%Challenge{} = challenge, method) when is_binary(method) do
    with :ok <- validate_kind(challenge, method),
         :ok <- Challenge.validate_fields(challenge),
         :ok <- validate_expiration(challenge.expires),
         {:ok, request} <- Codec.decode_base64_json(challenge.request),
         :ok <- validate_method_details(request["methodDetails"]),
         {:ok, charge} <- Charge.from_request(request) do
      {:ok, charge}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec expiration_unix(Challenge.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expiration_unix(%Challenge{expires: nil}, default_ttl_seconds) do
    {:ok, System.os_time(:second) + default_ttl_seconds}
  end

  def expiration_unix(%Challenge{expires: expires}, _default_ttl_seconds) do
    case DateTime.from_iso8601(expires) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime)}
      {:error, _reason} -> {:error, :invalid_expires}
    end
  end

  @doc false
  @spec required_config(map(), atom()) :: {:ok, String.t()} | {:error, {:missing_config | :invalid_config, atom()}}
  def required_config(config, key) do
    case config[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:missing_config, key}}
      _other -> {:error, {:invalid_config, key}}
    end
  end

  defp validate_kind(%Challenge{method: method, intent: "charge"}, method), do: :ok
  defp validate_kind(%Challenge{}, _method), do: {:error, :unsupported_challenge}

  defp validate_method_details(nil), do: :ok
  defp validate_method_details(details) when is_map(details), do: :ok
  defp validate_method_details(_details), do: {:error, :invalid_method_details}

  defp validate_expiration(nil), do: :ok

  defp validate_expiration(expires) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(expires)

    if DateTime.after?(datetime, DateTime.utc_now()),
      do: :ok,
      else: {:error, :payment_expired}
  end
end
