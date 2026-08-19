defmodule MPP.Client.Providers.Stripe do
  @moduledoc """
  Built-in Stripe charge provider using Shared Payment Tokens (SPTs).

  The provider parses the challenge, creates an SPT through Stripe's API, and
  returns the credential consumed by `MPP.Client.Req` or another transport.

  Configuration is explicit:

    * `:secret_key` — required Stripe secret or restricted key
    * `:payment_method` — required Stripe payment-method ID
    * `:external_id` — optional fallback credential external ID
    * `:spt_url` — optional SPT endpoint override
    * `:req_options` — optional options passed to `Req.request/2`
  """

  use MPP.Client.PaymentProvider

  alias MPP.Challenge
  alias MPP.Client.PaymentProvider
  alias MPP.Client.Providers.Shared
  alias MPP.Credential
  alias MPP.Intents.Charge

  @stripe_test_spt_url "https://api.stripe.com/v1/test_helpers/shared_payment/granted_tokens"
  @stripe_live_spt_url "https://api.stripe.com/v1/shared_payment/issued_tokens"
  @stripe_preview_version "2026-07-29.preview"
  @default_spt_ttl_seconds 3_600

  @doc "Returns true for Stripe charge challenges."
  @impl PaymentProvider
  @spec supports?(String.t(), String.t(), map()) :: boolean()
  def supports?("stripe", "charge", _config), do: true
  def supports?(_method, _intent, _config), do: false

  @doc "Creates a Stripe SPT for a charge challenge and returns its credential."
  @impl PaymentProvider
  @spec pay(Challenge.t(), map()) :: {:ok, Credential.t()} | {:error, term()}
  def pay(%Challenge{} = challenge, config) when is_map(config) do
    with {:ok, charge} <- Shared.parse_charge(challenge, "stripe"),
         {:ok, provider} <- parse_config(config),
         {:ok, details} <- method_details(charge),
         {:ok, network_id} <- required_string(details, "networkId"),
         {:ok, metadata} <- metadata(details["metadata"]),
         {:ok, expires_at} <- Shared.expiration_unix(challenge, @default_spt_ttl_seconds),
         {:ok, spt} <- create_spt(charge, network_id, metadata, expires_at, provider) do
      payload = maybe_put(%{"spt" => spt}, "externalId", charge.external_id || provider.external_id)

      {:ok, %Credential{challenge: challenge, payload: payload}}
    end
  end

  def pay(%Challenge{}, _config), do: {:error, {:invalid_config, :expected_map}}

  defp parse_config(config) do
    with {:ok, secret_key} <- Shared.required_config(config, :secret_key),
         {:ok, payment_method} <- Shared.required_config(config, :payment_method),
         {:ok, external_id} <- optional_string(config[:external_id], :external_id),
         {:ok, spt_url} <- optional_string(config[:spt_url], :spt_url),
         {:ok, req_options} <- req_options(config[:req_options]) do
      test_mode? = test_key?(secret_key)

      {:ok,
       %{
         secret_key: secret_key,
         payment_method: payment_method,
         external_id: external_id,
         spt_url: spt_url || default_spt_url(test_mode?),
         test_mode?: test_mode?,
         req_options: req_options
       }}
    end
  end

  defp create_spt(charge, network_id, metadata, expires_at, provider) do
    params = spt_params(charge, network_id, metadata, expires_at, provider)

    case request_spt(params, provider) do
      {:error, {:stripe_api_error, _status, %{"error" => %{"message" => message}}}} = error
      when provider.test_mode? and (map_size(metadata) > 0 or not is_nil(network_id)) ->
        if String.contains?(message, "Received unknown parameter") do
          charge
          |> spt_params(nil, %{}, expires_at, provider)
          |> request_spt(provider)
        else
          error
        end

      other ->
        other
    end
  end

  defp request_spt(params, provider) do
    headers = [
      {"authorization", "Basic #{Base.encode64(provider.secret_key <> ":")}"},
      {"content-type", "application/x-www-form-urlencoded"},
      {"stripe-version", @stripe_preview_version}
    ]

    result =
      Req.request(
        [
          url: provider.spt_url,
          method: :post,
          headers: headers,
          body: URI.encode_query(params, :www_form)
        ],
        provider.req_options
      )

    case result do
      {:ok, %Req.Response{status: status, body: %{"id" => id}}}
      when status in 200..299 and is_binary(id) and id != "" ->
        {:ok, id}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:stripe_api_error, status, body}}

      {:error, _reason} = error ->
        error
    end
  end

  defp spt_params(charge, network_id, metadata, expires_at, provider) do
    [
      {"payment_method", provider.payment_method},
      {"usage_limits[currency]", charge.currency},
      {"usage_limits[max_amount]", charge.amount},
      {"usage_limits[expires_at]", Integer.to_string(expires_at)}
    ]
    |> put_network_id(network_id, provider.test_mode?)
    |> put_metadata(metadata)
  end

  defp put_network_id(params, nil, _test_mode?), do: params

  defp put_network_id(params, network_id, true) do
    params ++ [{"seller_details[network_id]", network_id}]
  end

  defp put_network_id(params, network_id, false) do
    params ++ [{"seller_details[network_business_profile]", network_id}]
  end

  defp put_metadata(params, metadata) do
    entries = Enum.map(metadata, fn {key, value} -> {"metadata[#{key}]", value} end)
    params ++ entries
  end

  defp method_details(%Charge{method_details: details}) when is_map(details), do: {:ok, details}
  defp method_details(%Charge{}), do: {:error, :invalid_method_details}

  defp metadata(nil), do: {:ok, %{}}

  defp metadata(metadata) when is_map(metadata) do
    cond do
      not Enum.all?(metadata, fn {key, value} -> is_binary(key) and is_binary(value) end) ->
        {:error, :invalid_metadata}

      Map.has_key?(metadata, "externalId") ->
        {:error, :reserved_external_id_metadata}

      true ->
        {:ok, metadata}
    end
  end

  defp metadata(_other), do: {:error, :invalid_metadata}

  defp required_string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:missing_challenge_field, key}}
      _other -> {:error, {:invalid_challenge_field, key}}
    end
  end

  defp optional_string(nil, _key), do: {:ok, nil}
  defp optional_string(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_string(_value, key), do: {:error, {:invalid_config, key}}

  defp req_options(nil), do: {:ok, []}
  defp req_options(value) when is_list(value), do: {:ok, value}
  defp req_options(_value), do: {:error, {:invalid_config, :req_options}}

  defp test_key?(key), do: String.starts_with?(key, ["sk_test_", "rk_test_"])
  defp default_spt_url(true), do: @stripe_test_spt_url
  defp default_spt_url(false), do: @stripe_live_spt_url

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
