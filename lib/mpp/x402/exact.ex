defmodule MPP.X402.Exact do
  @moduledoc """
  Client-side x402 exact EIP-3009 credential construction.

  Signs with `MPP.Methods.EVM.Authorization.sign_transfer/2` using x402 nonce
  rules (`MPP.X402.Nonce`). Native challengeHash nonces are never selected.
  Permit2 and non-EIP-3009 transfer methods are refused.
  """

  alias MPP.Challenge
  alias MPP.Methods.EVM.Authorization
  alias MPP.X402
  alias MPP.X402.Headers
  alias MPP.X402.Nonce
  alias Onchain.Address

  @doc "Return true when this client can sign the synthetic x402 exact challenge."
  @spec can_handle?(Challenge.t(), map()) :: boolean()
  def can_handle?(%Challenge{} = challenge, config) when is_map(config) do
    match?({:ok, _}, prepare(challenge, config))
  end

  @doc """
  Sign an x402 exact PAYMENT-SIGNATURE payload for a synthetic challenge.

  Uses Task 40's `Authorization.sign_transfer/2` with a random nonce, or an
  extension-bound nonce when the offer advertised `extensions.mppx`.
  """
  @spec sign(Challenge.t(), map()) :: {:ok, map()} | {:error, term()}
  def sign(%Challenge{} = challenge, config) when is_map(config) do
    with {:ok, prepared} <- prepare(challenge, config),
         {:ok, from} <- payer(config),
         {:ok, to} <- Address.normalize(prepared.accepted["payTo"]),
         {:ok, chain_id} <- X402.chain_id(prepared.accepted["network"]),
         {:ok, value} <- parse_amount(prepared.accepted["amount"]),
         now = System.system_time(:second),
         authorization = %{
           "from" => from,
           "to" => to,
           "value" => prepared.accepted["amount"],
           "validAfter" => Integer.to_string(now - 600),
           "validBefore" => Integer.to_string(now + prepared.accepted["maxTimeoutSeconds"]),
           "nonce" => prepared.nonce
         },
         {:ok, signature} <-
           Authorization.sign_transfer(
             %{
               currency: prepared.accepted["asset"],
               name: prepared.name,
               version: prepared.version,
               chain_id: chain_id,
               from: from,
               to: to,
               value: value,
               valid_after: now - 600,
               valid_before: now + prepared.accepted["maxTimeoutSeconds"],
               nonce: prepared.nonce
             },
             Map.fetch!(config, :private_key)
           ) do
      payload = %{
        "x402Version" => X402.version(),
        "accepted" => prepared.accepted,
        "payload" => %{"signature" => signature, "authorization" => authorization}
      }

      payload =
        payload
        |> maybe_put("resource", prepared.resource)
        |> maybe_put("extensions", prepared.extensions)

      {:ok, payload}
    end
  end

  defp prepare(%Challenge{} = challenge, config) do
    with true <- X402.synthetic?(challenge),
         {:ok, request} <- X402.exact_request(challenge),
         {:ok, accepted} <- Headers.parse_requirements(request),
         :ok <- Headers.reject_permit2(accepted),
         {:ok, resource} <- require_resource(request),
         :ok <- assert_policy(config, accepted),
         {:ok, name, version} <- eip3009_domain(accepted) do
      extensions = prepare_extensions(request["extensions"])
      nonce = nonce_for(accepted, resource, extensions)

      {:ok,
       %{
         accepted: accepted,
         resource: resource,
         extensions: extensions,
         name: name,
         version: version,
         nonce: nonce
       }}
    else
      false -> {:error, :not_x402_challenge}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_extensions(extensions) when is_map(extensions) do
    if is_map(extensions["mppx"]), do: Nonce.with_nonce_salt(extensions), else: extensions
  end

  defp prepare_extensions(_extensions), do: nil

  defp nonce_for(accepted, resource, %{"mppx" => _} = extensions) do
    Nonce.extension_bound(accepted, resource, extensions)
  end

  defp nonce_for(_accepted, _resource, _extensions), do: Nonce.random()

  defp require_resource(%{"resource" => %{"url" => url} = resource}) when is_binary(url) and url != "" do
    {:ok, resource}
  end

  defp require_resource(_request), do: {:error, :missing_resource}

  defp eip3009_domain(%{"extra" => extra}) when is_map(extra) do
    name = extra["name"]
    version = extra["version"]

    if is_binary(name) and name != "" and is_binary(version) and version != "" do
      {:ok, name, version}
    else
      {:error, :missing_eip3009_domain}
    end
  end

  defp eip3009_domain(_accepted), do: {:error, :missing_eip3009_domain}

  defp assert_policy(config, accepted) do
    with {:ok, chain_id} <- X402.chain_id(accepted["network"]),
         :ok <- allowed_network(config, chain_id),
         :ok <- allowed_amount(config, accepted) do
      allowed_currency(config, accepted)
    end
  end

  defp allowed_network(config, chain_id) do
    case Map.get(config, :networks) do
      nil -> :ok
      networks when is_list(networks) -> if(chain_id in networks, do: :ok, else: {:error, :network_not_allowed})
      _other -> {:error, :network_not_allowed}
    end
  end

  defp allowed_amount(config, accepted) do
    case Map.get(config, :max_atomic_amount) do
      nil -> :ok
      max -> amount_within_max?(accepted["amount"], max)
    end
  end

  defp amount_within_max?(amount, max) do
    with {:ok, amount_int} <- parse_amount(amount),
         {:ok, max_int} <- parse_amount(max),
         true <- amount_int <= max_int do
      :ok
    else
      false -> {:error, :amount_exceeds_max}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed_currency(config, accepted) do
    currencies = Map.get(config, :currencies) || Map.get(config, :assets)

    case currencies do
      nil -> :ok
      list when is_list(list) -> currency_allowed?(accepted["asset"], list)
      _other -> {:error, :currency_not_allowed}
    end
  end

  defp currency_allowed?(asset, currencies) do
    with {:ok, normalized} <- Address.normalize(asset),
         true <- Enum.any?(currencies, &address_eq?(&1, normalized)) do
      :ok
    else
      _other -> {:error, :currency_not_allowed}
    end
  end

  defp address_eq?(currency, expected) do
    case Address.normalize(currency) do
      {:ok, allowed} -> allowed == expected
      _other -> false
    end
  end

  defp payer(config) do
    case Map.get(config, :private_key) do
      key when is_binary(key) and key != "" -> Onchain.Signer.address_from_key(key)
      _other -> {:error, :missing_private_key}
    end
  end

  defp parse_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> {:error, :invalid_amount}
    end
  end

  defp parse_amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_amount(_other), do: {:error, :invalid_amount}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
