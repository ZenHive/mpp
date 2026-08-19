defmodule MPP.Methods.Stripe.Subscription do
  @moduledoc """
  Stripe Billing activation for the shared subscription intent.

  Implements the constrained fixed-price profile from
  `draft-stripe-subscription-00`: one Customer, one recurring Price, one
  quantity-one Subscription, and a synchronously paid first invoice.
  """

  alias MPP.Errors
  alias MPP.Intents.Subscription
  alias MPP.JCS
  alias MPP.Receipt

  @stripe_api_url "https://api.stripe.com/v1"
  @stripe_api_version "2026-02-25.clover"
  @default_payment_method_types ["card"]
  @supported_payment_method_types ~w(card link)
  @interval_count_max %{day: 1_095, week: 156, month: 36}
  @subscription_id_bytes 18
  @metadata_max_entries 50
  @reserved_metadata_entries 2
  @metadata_key_max_bytes 40
  @metadata_value_max_bytes 500
  # Credential IDs are interpolated into Stripe URLs. Default URI.encode/1 leaves
  # `/` intact, so reject anything that is not a Stripe-style object id.
  @stripe_object_id ~r/\A[a-z]+_[A-Za-z0-9_]+\z/

  @doc "Validate Stripe subscription configuration at Plug initialization."
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) when is_map(config) do
    validate_non_empty_config!(config, "stripe_secret_key")
    validate_non_empty_config!(config, "network_id")
    validate_payment_method_types!(payment_method_types(config))
    validate_metadata!(config["metadata"] || %{})

    if Map.has_key?(config, "connect") do
      raise ArgumentError, "MPP.Methods.Stripe subscription does not support Stripe Connect settlement"
    end

    :ok
  end

  @doc "Return the public Stripe subscription challenge fields."
  @spec challenge_method_details(Subscription.t()) :: map()
  def challenge_method_details(%Subscription{} = subscription) do
    validate_profile!(subscription)
    config = subscription.method_details || %{}

    maybe_put(
      %{"networkId" => config["network_id"], "paymentMethodTypes" => payment_method_types(config)},
      "metadata",
      config["metadata"]
    )
  end

  @doc "Activate a Stripe subscription and verify its synchronously paid first invoice."
  @spec verify(map(), Subscription.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Subscription{} = subscription) when is_map(payload) do
    config = subscription.method_details || %{}

    with :ok <- validate_profile(subscription),
         {:ok, secret_key} <- require_config(config, "stripe_secret_key"),
         {:ok, challenge_id} <- require_config(config, "challenge_id"),
         {:ok, payment_method_input, customer_input} <- parse_payload(payload),
         {:ok, payment_method} <- retrieve_payment_method(payment_method_input, secret_key, config),
         :ok <- validate_payment_method(payment_method, payment_method_types(config)),
         {:ok, customer} <- resolve_customer(customer_input, payment_method, subscription, secret_key, config),
         {:ok, payment_method} <- attach_payment_method(payment_method, customer, subscription, secret_key, config),
         {:ok, product} <- create_product(subscription, customer, payment_method, secret_key, config),
         :ok <- validate_product(product),
         {:ok, price} <- create_price(subscription, customer, payment_method, product, secret_key, config),
         :ok <- validate_price(price, subscription, product),
         {:ok, stripe_subscription} <-
           create_subscription(subscription, customer, payment_method, price, secret_key, config) do
      confirm_activation(
        stripe_subscription,
        customer,
        payment_method,
        price,
        subscription,
        secret_key,
        config,
        challenge_id
      )
    end
  end

  def verify(_payload, %Subscription{}) do
    {:error, Errors.new(:invalid_payload, "Stripe subscription credential payload must be an object")}
  end

  defp confirm_activation(
         stripe_subscription,
         customer,
         payment_method,
         price,
         subscription,
         secret_key,
         config,
         challenge_id
       ) do
    result =
      with {:ok, invoice_id, item_period} <-
             validate_subscription(stripe_subscription, customer, payment_method, price),
           {:ok, invoice} <- retrieve_invoice(invoice_id, secret_key, config),
           {:ok, paid_at} <-
             validate_invoice(
               invoice,
               stripe_subscription,
               customer,
               payment_method,
               price,
               subscription,
               item_period
             ) do
        {:ok, receipt(subscription, stripe_subscription, invoice, challenge_id, paid_at)}
      end

    case result do
      {:ok, _receipt} = ok ->
        ok

      {:error, _reason} = error ->
        cancel_created_subscription(stripe_subscription, subscription, customer, payment_method, secret_key, config)
        error
    end
  end

  defp cancel_created_subscription(stripe_subscription, subscription, customer, payment_method, secret_key, config) do
    case stripe_subscription do
      %{"id" => id} ->
        if stripe_object_id?(id) do
          key = idempotency_key("cancel", subscription, customer["id"], payment_method["id"], config)
          _ = stripe_request(:delete, "/subscriptions/#{id}", [], secret_key, config, key)
        end

        :ok

      _invalid ->
        :ok
    end
  end

  defp validate_profile!(subscription) do
    case validate_profile(subscription) do
      :ok -> :ok
      {:error, %Errors{detail: detail}} -> raise ArgumentError, detail
    end
  end

  defp validate_profile(%Subscription{recipient: recipient}) when not is_nil(recipient) do
    profile_error("Stripe subscription request must not include recipient")
  end

  defp validate_profile(%Subscription{subscription_expires: expires}) when not is_nil(expires) do
    profile_error("Stripe subscription request must not include subscriptionExpires")
  end

  defp validate_profile(%Subscription{currency: currency}) when not is_binary(currency) do
    profile_error("Stripe subscription currency must be a lowercase ISO 4217 code")
  end

  defp validate_profile(%Subscription{currency: currency} = subscription) do
    if Regex.match?(~r/\A[a-z]{3}\z/, currency) do
      validate_interval_count(subscription)
    else
      profile_error("Stripe subscription currency must be a lowercase ISO 4217 code")
    end
  end

  defp validate_interval_count(%Subscription{period_unit: unit, period_count: count}) do
    max_count = @interval_count_max[unit]

    case Integer.parse(count) do
      {value, ""} when is_integer(max_count) and value <= max_count -> :ok
      _ -> profile_error("Stripe subscription periodCount exceeds the supported #{unit} cadence")
    end
  end

  defp profile_error(detail), do: {:error, Errors.new(:verification_failed, detail)}

  defp parse_payload(%{"paymentMethod" => payment_method} = payload)
       when is_binary(payment_method) and payment_method != "" do
    cond do
      Map.keys(payload) -- ["paymentMethod", "customer"] != [] ->
        {:error, Errors.new(:invalid_payload, "Stripe subscription credential contains unsupported fields")}

      not stripe_object_id?(payment_method) ->
        {:error, Errors.new(:invalid_payload, "Stripe subscription paymentMethod must be a Stripe object id")}

      is_nil(payload["customer"]) ->
        {:ok, payment_method, nil}

      stripe_object_id?(payload["customer"]) ->
        {:ok, payment_method, payload["customer"]}

      true ->
        {:error, Errors.new(:invalid_payload, "Stripe subscription customer must be a Stripe object id")}
    end
  end

  defp parse_payload(_payload) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'paymentMethod' field in credential payload")}
  end

  defp retrieve_payment_method(payment_method, secret_key, config) do
    get_object(
      "/payment_methods/#{URI.encode(payment_method)}",
      secret_key,
      config,
      "Stripe PaymentMethod verification failed"
    )
  end

  defp validate_payment_method(%{"id" => id, "type" => type, "customer" => customer}, allowed_types)
       when is_binary(id) and is_binary(type) and (is_nil(customer) or is_binary(customer)) do
    if type in allowed_types do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Stripe PaymentMethod type is not allowed by this challenge")}
    end
  end

  defp validate_payment_method(_payment_method, _allowed_types) do
    {:error, Errors.new(:verification_failed, "Stripe returned an invalid PaymentMethod")}
  end

  defp resolve_customer(nil, payment_method, subscription, secret_key, config) do
    params =
      [{"description", "MPP subscription payer"}] ++
        metadata_params(metadata(subscription, config))

    key = idempotency_key("customer", subscription, "new", payment_method["id"], config)

    with {:ok, customer} <-
           post_object("/customers", params, secret_key, config, key, "Stripe Customer creation failed"),
         :ok <- validate_customer(customer) do
      {:ok, customer}
    end
  end

  defp resolve_customer(customer_id, _payment_method, _subscription, secret_key, config) do
    with {:ok, customer} <-
           get_object(
             "/customers/#{URI.encode(customer_id)}",
             secret_key,
             config,
             "Stripe Customer verification failed"
           ),
         :ok <- validate_customer(customer, customer_id) do
      {:ok, customer}
    end
  end

  defp validate_customer(customer, expected_id \\ nil)

  defp validate_customer(%{"id" => id} = customer, expected_id) when is_binary(id) do
    if customer["deleted"] != true and (is_nil(expected_id) or id == expected_id) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Stripe returned an invalid Customer")}
    end
  end

  defp validate_customer(_customer, _expected_id) do
    {:error, Errors.new(:verification_failed, "Stripe returned an invalid Customer")}
  end

  defp attach_payment_method(
         %{"customer" => customer_id} = payment_method,
         %{"id" => customer_id},
         _subscription,
         _key,
         _config
       ), do: {:ok, payment_method}

  defp attach_payment_method(%{"customer" => nil} = payment_method, customer, subscription, secret_key, config) do
    key = idempotency_key("attach", subscription, customer["id"], payment_method["id"], config)

    with {:ok, attached} <-
           post_object(
             "/payment_methods/#{URI.encode(payment_method["id"])}/attach",
             [{"customer", customer["id"]}],
             secret_key,
             config,
             key,
             "Stripe PaymentMethod attachment failed"
           ),
         :ok <- validate_attached_payment_method(attached, customer, payment_method) do
      {:ok, attached}
    end
  end

  defp attach_payment_method(_payment_method, _customer, _subscription, _secret_key, _config) do
    {:error, Errors.new(:verification_failed, "Stripe PaymentMethod belongs to a different Customer")}
  end

  defp validate_attached_payment_method(
         %{"id" => id, "type" => type, "customer" => customer_id},
         %{"id" => customer_id},
         %{"id" => id, "type" => type}
       ), do: :ok

  defp validate_attached_payment_method(_attached, _customer, _payment_method) do
    {:error, Errors.new(:verification_failed, "Stripe returned an invalid attached PaymentMethod")}
  end

  defp create_product(subscription, customer, payment_method, secret_key, config) do
    name = subscription.description || "MPP subscription"
    params = [{"name", name}] ++ metadata_params(metadata(subscription, config))
    key = idempotency_key("product", subscription, customer["id"], payment_method["id"], config)

    post_object("/products", params, secret_key, config, key, "Stripe Product creation failed")
  end

  defp validate_product(%{"id" => id, "active" => true}) when is_binary(id), do: :ok

  defp validate_product(_product) do
    {:error, Errors.new(:verification_failed, "Stripe returned an invalid Product")}
  end

  defp create_price(subscription, customer, payment_method, product, secret_key, config) do
    params = [
      {"product", product["id"]},
      {"currency", subscription.currency},
      {"unit_amount", subscription.amount},
      {"recurring[interval]", Atom.to_string(subscription.period_unit)},
      {"recurring[interval_count]", subscription.period_count}
    ]

    key = idempotency_key("price", subscription, customer["id"], payment_method["id"], config)
    post_object("/prices", params, secret_key, config, key, "Stripe Price creation failed")
  end

  defp validate_price(
         %{
           "id" => id,
           "active" => true,
           "billing_scheme" => "per_unit",
           "currency" => currency,
           "product" => product_id,
           "recurring" => %{"interval" => interval, "interval_count" => interval_count, "usage_type" => "licensed"},
           "type" => "recurring",
           "unit_amount" => unit_amount
         },
         subscription,
         %{"id" => product_id}
       )
       when is_binary(id) do
    expected_amount = String.to_integer(subscription.amount)

    if unit_amount == expected_amount and currency == subscription.currency and
         interval == Atom.to_string(subscription.period_unit) and
         interval_count == String.to_integer(subscription.period_count) do
      :ok
    else
      invalid_price()
    end
  end

  defp validate_price(_price, _subscription, _product), do: invalid_price()

  defp invalid_price,
    do: {:error, Errors.new(:verification_failed, "Stripe Price does not match the subscription request")}

  defp create_subscription(subscription, customer, payment_method, price, secret_key, config) do
    params =
      [
        {"customer", customer["id"]},
        {"items[0][price]", price["id"]},
        {"items[0][quantity]", "1"},
        {"default_payment_method", payment_method["id"]},
        {"collection_method", "charge_automatically"},
        {"payment_behavior", "error_if_incomplete"},
        {"proration_behavior", "none"},
        {"automatic_tax[enabled]", "false"}
      ] ++ metadata_params(metadata(subscription, config))

    key = idempotency_key("subscription", subscription, customer["id"], payment_method["id"], config)

    case stripe_request(:post, "/subscriptions", params, secret_key, config, key) do
      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:error, {:stripe, 402, %{"error" => %{"code" => "subscription_payment_intent_requires_action"}}}} ->
        {:error, Errors.new(:verification_failed, "Stripe subscription first invoice requires customer action")}

      {:error, _reason} ->
        {:error, Errors.new(:verification_failed, "Stripe subscription activation failed")}

      {:ok, _body} ->
        {:error, Errors.new(:verification_failed, "Stripe returned an invalid Subscription")}
    end
  end

  defp validate_subscription(
         %{
           "id" => id,
           "status" => "active",
           "customer" => customer_id,
           "default_payment_method" => payment_method_id,
           "collection_method" => "charge_automatically",
           "latest_invoice" => invoice_id,
           "items" => %{"data" => [item]},
           "cancel_at" => nil,
           "cancel_at_period_end" => false,
           "discounts" => [],
           "pending_invoice_item_interval" => nil,
           "schedule" => nil,
           "trial_end" => nil,
           "trial_start" => nil
         } = stripe_subscription,
         %{"id" => customer_id},
         %{"id" => payment_method_id},
         %{"id" => price_id}
       )
       when is_binary(id) and is_binary(invoice_id) do
    with :ok <- require_stripe_object_id(id, "Subscription"),
         :ok <- require_stripe_object_id(invoice_id, "Invoice"),
         :ok <- validate_subscription_item(item, id, price_id),
         :ok <- validate_automatic_tax(stripe_subscription) do
      {:ok, invoice_id, {item["current_period_start"], item["current_period_end"]}}
    end
  end

  defp validate_subscription(_subscription, _customer, _payment_method, _price) do
    {:error, Errors.new(:verification_failed, "Stripe Subscription does not match the constrained billing profile")}
  end

  defp validate_subscription_item(
         %{
           "subscription" => subscription_id,
           "quantity" => 1,
           "discounts" => [],
           "price" => %{"id" => price_id},
           "current_period_start" => period_start,
           "current_period_end" => period_end
         },
         subscription_id,
         price_id
       )
       when is_integer(period_start) and is_integer(period_end) and period_end > period_start, do: :ok

  defp validate_subscription_item(_item, _subscription_id, _price_id) do
    {:error, Errors.new(:verification_failed, "Stripe Subscription item does not match the constrained billing profile")}
  end

  defp validate_automatic_tax(%{"automatic_tax" => %{"enabled" => false}}), do: :ok

  defp validate_automatic_tax(_subscription) do
    {:error, Errors.new(:verification_failed, "Stripe Subscription must not enable automatic tax")}
  end

  defp retrieve_invoice(invoice_id, secret_key, config) do
    query = URI.encode_query([{"expand[]", "payments.data.payment.payment_intent"}])
    get_object("/invoices/#{URI.encode(invoice_id)}?#{query}", secret_key, config, "Stripe Invoice retrieval failed")
  end

  defp validate_invoice(invoice, stripe_subscription, customer, payment_method, price, subscription, item_period) do
    with :ok <- validate_invoice_core(invoice, stripe_subscription, customer, subscription),
         :ok <- validate_invoice_line(invoice, stripe_subscription, price, subscription, item_period) do
      validate_invoice_payment(invoice, customer, payment_method, subscription)
    end
  end

  defp validate_invoice_core(
         %{
           "id" => id,
           "status" => "paid",
           "customer" => customer_id,
           "currency" => currency,
           "amount_paid" => amount,
           "amount_remaining" => 0,
           "total" => amount,
           "discounts" => [],
           "total_discount_amounts" => [],
           "total_taxes" => [],
           "total_pretax_credit_amounts" => [],
           "pre_payment_credit_notes_amount" => 0,
           "post_payment_credit_notes_amount" => 0,
           "starting_balance" => 0,
           "ending_balance" => 0,
           "automatic_tax" => %{"enabled" => false},
           "parent" => %{
             "type" => "subscription_details",
             "subscription_details" => %{"subscription" => stripe_subscription_id}
           }
         },
         %{"id" => stripe_subscription_id},
         %{"id" => customer_id},
         subscription
       )
       when is_binary(id) do
    if amount == String.to_integer(subscription.amount) and currency == subscription.currency do
      :ok
    else
      invalid_invoice()
    end
  end

  defp validate_invoice_core(_invoice, _stripe_subscription, _customer, _subscription), do: invalid_invoice()

  defp validate_invoice_line(
         %{"lines" => %{"data" => [line]}},
         %{"id" => stripe_subscription_id},
         %{"id" => price_id},
         subscription,
         item_period
       ) do
    expected_amount = String.to_integer(subscription.amount)

    case line do
      %{
        "amount" => ^expected_amount,
        "currency" => currency,
        "quantity" => 1,
        "discount_amounts" => [],
        "discounts" => [],
        "taxes" => [],
        "period" => %{"start" => period_start, "end" => period_end},
        "pricing" => %{"type" => "price_details", "price_details" => %{"price" => ^price_id}},
        "parent" => %{
          "type" => "subscription_item_details",
          "subscription_item_details" => %{"subscription" => ^stripe_subscription_id, "proration" => false}
        }
      }
      when currency == subscription.currency and {period_start, period_end} == item_period ->
        :ok

      _other ->
        invalid_invoice()
    end
  end

  defp validate_invoice_line(_invoice, _stripe_subscription, _price, _subscription, _period), do: invalid_invoice()

  defp validate_invoice_payment(
         %{
           "payments" => %{
             "data" => [
               %{
                 "status" => "paid",
                 "amount_paid" => amount,
                 "currency" => currency,
                 "status_transitions" => %{"paid_at" => paid_at},
                 "payment" => %{
                   "type" => "payment_intent",
                   "payment_intent" => %{
                     "status" => "succeeded",
                     "amount_received" => amount,
                     "currency" => currency,
                     "customer" => customer_id,
                     "payment_method" => payment_method_id,
                     "setup_future_usage" => "off_session"
                   }
                 }
               }
             ]
           }
         },
         %{"id" => customer_id},
         %{"id" => payment_method_id},
         subscription
       )
       when is_integer(paid_at) do
    if amount == String.to_integer(subscription.amount) and currency == subscription.currency do
      paid_at_datetime(paid_at)
    else
      invalid_invoice()
    end
  end

  defp validate_invoice_payment(_invoice, _customer, _payment_method, _subscription), do: invalid_invoice()

  defp invalid_invoice do
    {:error, Errors.new(:verification_failed, "Stripe first invoice does not match the subscription request")}
  end

  defp paid_at_datetime(paid_at) do
    case DateTime.from_unix(paid_at) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> invalid_invoice()
    end
  end

  defp receipt(subscription, stripe_subscription, invoice, challenge_id, paid_at) do
    stripe_subscription_id = stripe_subscription["id"]

    Receipt.new(
      method: "stripe",
      reference: invoice["id"],
      external_id: subscription.external_id,
      subscription_id: subscription_id(challenge_id, stripe_subscription_id),
      timestamp: DateTime.to_iso8601(paid_at),
      extensions: %{"stripeSubscription" => stripe_subscription_id}
    )
  end

  defp subscription_id(challenge_id, stripe_subscription_id) do
    :sha256
    |> :crypto.hash(["mpp:stripe:subscription:", challenge_id, ":", stripe_subscription_id])
    |> binary_part(0, @subscription_id_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp metadata(subscription, config) do
    (config["metadata"] || %{})
    |> Map.put("mpp_challenge_id", config["challenge_id"])
    |> maybe_put("mpp_external_id", subscription.external_id)
  end

  defp metadata_params(metadata) do
    metadata
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {"metadata[#{key}]", value} end)
  end

  defp idempotency_key(operation, subscription, customer, payment_method, config) do
    fingerprint = %{
      "amount" => subscription.amount,
      "challenge" => config["challenge_id"],
      "currency" => subscription.currency,
      "customer" => customer,
      "paymentMethod" => payment_method,
      "periodCount" => subscription.period_count,
      "periodUnit" => Atom.to_string(subscription.period_unit)
    }

    digest =
      :sha256
      |> :crypto.hash(JCS.canonicalize(fingerprint))
      |> Base.url_encode64(padding: false)

    "mpp-subscription-#{operation}-#{digest}"
  end

  defp get_object(path, secret_key, config, detail) do
    case stripe_request(:get, path, [], secret_key, config, nil) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _result -> {:error, Errors.new(:verification_failed, detail)}
    end
  end

  defp post_object(path, params, secret_key, config, idempotency_key, detail) do
    case stripe_request(:post, path, params, secret_key, config, idempotency_key) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _result -> {:error, Errors.new(:verification_failed, detail)}
    end
  end

  defp stripe_request(method, path, params, secret_key, config, idempotency_key) do
    headers =
      [
        {"authorization", "Basic #{Base.encode64(secret_key <> ":")}"},
        {"stripe-version", @stripe_api_version}
      ]
      |> maybe_add_header("idempotency-key", idempotency_key)
      |> maybe_add_content_type(method)

    request = maybe_add_body([url: @stripe_api_url <> path, method: method, headers: headers], method, params)

    case Req.request(request, config["req_options"] || []) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:stripe, status, body}}
      {:error, reason} -> {:error, {:request, reason}}
    end
  end

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, name, value), do: headers ++ [{name, value}]

  defp maybe_add_content_type(headers, :post), do: headers ++ [{"content-type", "application/x-www-form-urlencoded"}]

  defp maybe_add_content_type(headers, _method), do: headers

  defp maybe_add_body(request, :post, params), do: Keyword.put(request, :body, URI.encode_query(params, :www_form))
  defp maybe_add_body(request, _method, _params), do: request

  defp require_config(config, key) do
    case config[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, Errors.new(:verification_failed, "Stripe subscription requires #{key} configuration")}
    end
  end

  defp require_stripe_object_id(id, kind) do
    if stripe_object_id?(id) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "Stripe returned an invalid #{kind}")}
    end
  end

  defp stripe_object_id?(id) when is_binary(id), do: Regex.match?(@stripe_object_id, id)
  defp stripe_object_id?(_id), do: false

  defp validate_non_empty_config!(config, key) do
    if not (is_binary(config[key]) and config[key] != "") do
      raise ArgumentError, "MPP.Methods.Stripe subscription requires non-empty #{key} in method_config"
    end
  end

  defp payment_method_types(config), do: config["payment_method_types"] || @default_payment_method_types

  defp validate_payment_method_types!(types) do
    valid? =
      is_list(types) and types != [] and Enum.uniq(types) == types and
        Enum.all?(types, &(&1 in @supported_payment_method_types))

    if not valid? do
      raise ArgumentError,
            "MPP.Methods.Stripe subscription payment_method_types must be a unique non-empty list of card/link"
    end
  end

  defp validate_metadata!(metadata)
       when is_map(metadata) and map_size(metadata) <= @metadata_max_entries - @reserved_metadata_entries do
    valid? =
      Enum.all?(metadata, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          key != "" and byte_size(key) <= @metadata_key_max_bytes and
            byte_size(value) <= @metadata_value_max_bytes and not String.contains?(key, ["[", "]"])

        _entry ->
          false
      end)

    if not valid?, do: raise(ArgumentError, "MPP.Methods.Stripe subscription metadata violates Stripe limits")
  end

  defp validate_metadata!(_metadata) do
    raise ArgumentError, "MPP.Methods.Stripe subscription metadata violates Stripe limits"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
