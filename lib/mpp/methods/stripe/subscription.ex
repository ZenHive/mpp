defmodule MPP.Methods.Stripe.Subscription do
  @moduledoc """
  Stripe Billing activation, renewal accounting, and cancellation for the
  shared subscription intent.

  Implements the constrained fixed-price profile from
  `draft-stripe-subscription-00`: one Customer, one recurring Price, one
  quantity-one Subscription, and synchronously paid invoices mapped onto
  locally persisted canonical periods.
  """

  alias MPP.Errors
  alias MPP.Intents.Subscription
  alias MPP.JCS
  alias MPP.Receipt
  alias MPP.Subscription.Record
  alias MPP.Subscription.Store

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
  @seconds_per_day 86_400
  @days_per_week 7
  # Credential IDs are interpolated into Stripe URLs. Default URI.encode/1 leaves
  # `/` intact, so reject anything that is not a Stripe-style object id.
  @stripe_object_id ~r/\A[a-z]+_[A-Za-z0-9_]+\z/
  @renewal_invoice_error "Stripe renewal invoice does not match the subscription"
  @subscription_store_error "Stripe subscription store unavailable"

  @doc "Validate Stripe subscription configuration at Plug initialization."
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) when is_map(config) do
    validate_non_empty_config!(config, "stripe_secret_key")
    validate_non_empty_config!(config, "network_id")
    validate_payment_method_types!(payment_method_types(config))
    validate_metadata!(config["metadata"] || %{})
    validate_store!(config)

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

  @doc "Validate and durably record a paid Stripe renewal invoice."
  @spec process_invoice(String.t(), String.t(), map()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def process_invoice(event_id, invoice_id, config)
      when is_binary(event_id) and is_binary(invoice_id) and is_map(config) do
    with :ok <- require_stripe_object_id(event_id, "Event"),
         :ok <- require_stripe_object_id(invoice_id, "Invoice"),
         {:ok, secret_key} <- require_config(config, "stripe_secret_key"),
         {:ok, invoice} <- retrieve_invoice(invoice_id, secret_key, config),
         {:ok, record, period, timestamp} <- validate_renewal(invoice, invoice_id, config),
         {:ok, updated} <- record_renewal(record, period, invoice_id, event_id, timestamp, config) do
      {:ok, receipt(updated, Map.fetch!(updated.payments, period))}
    end
  end

  def process_invoice(_event_id, _invoice_id, _config) do
    {:error, Errors.new(:invalid_payload, "Stripe renewal requires event, invoice, and configuration values")}
  end

  @doc "Schedule cancellation at the end of the last durably paid billing period."
  @spec cancel(String.t(), map()) :: {:ok, Record.t()} | {:error, Errors.t()}
  def cancel(subscription_id, config) when is_binary(subscription_id) and is_map(config) do
    subscription_store = store(config)

    with {:ok, secret_key} <- require_config(config, "stripe_secret_key"),
         {:ok, record} <- fetch_record(subscription_store, subscription_id),
         :ok <- require_stripe_record(record),
         {:ok, claimed} <- claim_cancellation(subscription_store, record),
         {:ok, effective_at} <- paid_period_end(claimed),
         {:ok, updated} <- schedule_cancellation(subscription_store, claimed, effective_at, secret_key, config) do
      {:ok, updated}
    else
      {:error, :already_canceled, record} -> {:ok, record}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  def cancel(_subscription_id, _config) do
    {:error, Errors.new(:invalid_payload, "Stripe cancellation requires a subscription ID and configuration")}
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
             ),
           {:ok, record} <-
             persist_activation(
               subscription,
               %{
                 stripe_subscription: stripe_subscription,
                 customer: customer,
                 payment_method: payment_method,
                 price: price
               },
               invoice,
               item_period,
               challenge_id,
               paid_at,
               config
             ) do
        {:ok, receipt(record, Map.fetch!(record.payments, 0))}
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

  defp persist_activation(subscription, resources, invoice, {period_start, period_end}, challenge_id, paid_at, config) do
    with {:ok, billing_anchor} <- DateTime.from_unix(period_start),
         :ok <- validate_activation_period(subscription, billing_anchor, period_end) do
      stripe_subscription = resources.stripe_subscription
      subscription_id = subscription_id(challenge_id, stripe_subscription["id"])
      timestamp = DateTime.to_iso8601(paid_at)

      record = %Record{
        subscription_id: subscription_id,
        method: "stripe",
        subscription: %{subscription | method_details: public_method_details(subscription.method_details)},
        method_state: %{
          stripe_subscription_id: stripe_subscription["id"],
          customer_id: resources.customer["id"],
          payment_method_id: resources.payment_method["id"],
          price_id: resources.price["id"]
        },
        billing_anchor: billing_anchor,
        last_charged_period: 0,
        payments: %{0 => payment(0, invoice["id"], timestamp, [])},
        reference: invoice["id"],
        timestamp: timestamp
      }

      put_activation(store(config), record)
    else
      {:error, _reason} -> invalid_invoice()
    end
  end

  defp validate_activation_period(subscription, billing_anchor, period_end) do
    with {:ok, end_at} <- DateTime.from_unix(period_end),
         ^end_at <- shift_from_anchor(billing_anchor, subscription, 1) do
      :ok
    else
      _mismatch -> invalid_invoice()
    end
  end

  defp put_activation(subscription_store, record) do
    case Store.update(subscription_store, record.subscription_id, &put_activation_record(&1, record)) do
      {:ok, stored} -> {:ok, stored}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  defp put_activation_record(:not_found, record), do: {:ok, record}

  defp put_activation_record(%Record{method: "stripe"} = current, record) do
    if activation_matches?(current, record), do: {:ok, current}, else: {:error, activation_conflict()}
  end

  defp put_activation_record(%Record{}, _record), do: {:error, activation_conflict()}

  defp activation_matches?(current, record) do
    current.method_state == record.method_state and
      get_in(current.payments, [0, :reference]) == get_in(record.payments, [0, :reference])
  end

  defp activation_conflict do
    Errors.new(:verification_failed, "Stripe subscription activation conflicts with durable state")
  end

  defp validate_renewal(invoice, invoice_id, config) do
    with {:ok, stripe_subscription_id, challenge_id, item_period} <-
           renewal_identity(invoice, invoice_id),
         subscription_id = subscription_id(challenge_id, stripe_subscription_id),
         {:ok, record} <- fetch_record(store(config), subscription_id),
         :ok <- require_stripe_record(record, stripe_subscription_id),
         {:ok, paid_at} <- validate_renewal_invoice(invoice, record, item_period),
         {:ok, period} <- canonical_period(record, item_period),
         :ok <- require_payable_period(record, period, elem(item_period, 0)) do
      {:ok, record, period, DateTime.to_iso8601(paid_at)}
    end
  end

  defp renewal_identity(
         %{
           "id" => invoice_id,
           "billing_reason" => "subscription_cycle",
           "parent" => %{
             "type" => "subscription_details",
             "subscription_details" => %{
               "subscription" => stripe_subscription_id,
               "metadata" => %{"mpp_challenge_id" => challenge_id}
             }
           },
           "lines" => %{"data" => [%{"period" => %{"start" => period_start, "end" => period_end}}]}
         },
         invoice_id
       )
       when is_binary(stripe_subscription_id) and is_binary(challenge_id) and challenge_id != "" and
              is_integer(period_start) and is_integer(period_end) and period_end > period_start do
    with :ok <- require_stripe_object_id(stripe_subscription_id, "Subscription") do
      {:ok, stripe_subscription_id, challenge_id, {period_start, period_end}}
    end
  end

  defp renewal_identity(_invoice, _invoice_id), do: renewal_error()

  defp validate_renewal_invoice(invoice, record, item_period) do
    state = record.method_state
    stripe_subscription = %{"id" => state.stripe_subscription_id}
    customer = %{"id" => state.customer_id}
    payment_method = %{"id" => state.payment_method_id}
    price = %{"id" => state.price_id}

    with :ok <- validate_invoice_core(invoice, stripe_subscription, customer, record.subscription),
         :ok <- validate_invoice_line(invoice, stripe_subscription, price, record.subscription, item_period),
         {:ok, paid_at} <-
           validate_renewal_invoice_payment(invoice, customer, payment_method, record.subscription) do
      {:ok, paid_at}
    else
      {:error, _reason} -> renewal_error()
    end
  end

  defp validate_renewal_invoice_payment(
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
                     "setup_future_usage" => nil
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
      renewal_error()
    end
  end

  defp validate_renewal_invoice_payment(_invoice, _customer, _payment_method, _subscription), do: renewal_error()

  defp canonical_period(record, {period_start, period_end}) do
    with {:ok, start_at} <- DateTime.from_unix(period_start),
         {:ok, end_at} <- DateTime.from_unix(period_end),
         {:ok, period} <- period_index(record, start_at),
         ^start_at <- shift_period(record, period),
         ^end_at <- shift_period(record, period + 1) do
      {:ok, period}
    else
      _mismatch -> renewal_error()
    end
  end

  defp period_index(%Record{subscription: %{period_unit: :month, period_count: count}, billing_anchor: anchor}, start_at) do
    months = (start_at.year - anchor.year) * 12 + start_at.month - anchor.month
    count = String.to_integer(count)

    if months >= 0 and rem(months, count) == 0,
      do: {:ok, div(months, count)},
      else: renewal_error()
  end

  defp period_index(%Record{subscription: subscription, billing_anchor: anchor}, start_at) do
    seconds = period_seconds(subscription)
    difference = DateTime.diff(start_at, anchor, :second)

    if difference >= 0 and rem(difference, seconds) == 0,
      do: {:ok, div(difference, seconds)},
      else: renewal_error()
  end

  defp shift_period(%Record{subscription: subscription, billing_anchor: anchor}, period) do
    shift_from_anchor(anchor, subscription, period)
  end

  defp shift_from_anchor(anchor, subscription, period) do
    count = String.to_integer(subscription.period_count) * period

    case subscription.period_unit do
      :day -> DateTime.shift(anchor, day: count)
      :week -> DateTime.shift(anchor, week: count)
      :month -> DateTime.shift(anchor, month: count)
    end
  end

  defp period_seconds(%Subscription{period_unit: :day, period_count: count}) do
    String.to_integer(count) * @seconds_per_day
  end

  defp period_seconds(%Subscription{period_unit: :week, period_count: count}) do
    String.to_integer(count) * @days_per_week * @seconds_per_day
  end

  defp require_payable_period(_record, 0, _period_start), do: renewal_error()

  defp require_payable_period(%Record{cancellation_effective_at: nil}, _period, _period_start), do: :ok

  defp require_payable_period(%Record{cancellation_effective_at: effective_at}, _period, period_start) do
    if period_start < DateTime.to_unix(effective_at), do: :ok, else: renewal_error()
  end

  defp record_renewal(record, period, invoice_id, event_id, timestamp, config) do
    case Store.update(store(config), record.subscription_id, fn current ->
           update_renewal(current, period, invoice_id, event_id, timestamp)
         end) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  defp update_renewal(
         %Record{method: "stripe", in_flight_reference: nil} = record,
         period,
         invoice_id,
         event_id,
         timestamp
       ) do
    event_payment = Enum.find_value(record.payments, &payment_for_event(&1, event_id))

    case event_payment do
      %{reference: ^invoice_id, period: ^period} -> {:ok, record}
      nil -> update_renewal_period(record, period, invoice_id, event_id, timestamp)
      _other -> renewal_error()
    end
  end

  defp update_renewal(%Record{}, _period, _invoice_id, _event_id, _timestamp), do: renewal_error()
  defp update_renewal(:not_found, _period, _invoice_id, _event_id, _timestamp), do: renewal_error()

  defp update_renewal_period(record, period, invoice_id, event_id, timestamp) do
    case Map.get(record.payments, period) do
      %{reference: ^invoice_id} = paid -> append_payment_event(record, paid, event_id)
      nil -> insert_renewal_payment(record, period, invoice_id, event_id, timestamp)
      _other -> renewal_error()
    end
  end

  defp append_payment_event(record, paid, event_id) do
    updated = %{paid | event_ids: Enum.uniq(paid.event_ids ++ [event_id])}
    {:ok, %{record | payments: Map.put(record.payments, paid.period, updated)}}
  end

  defp insert_renewal_payment(record, period, invoice_id, event_id, timestamp) do
    invoice_recorded? = Enum.any?(record.payments, fn {_index, paid} -> paid.reference == invoice_id end)

    if invoice_recorded? or period != record.last_charged_period + 1 do
      renewal_error()
    else
      paid = payment(period, invoice_id, timestamp, [event_id])

      {:ok,
       %{
         record
         | payments: Map.put(record.payments, period, paid),
           last_charged_period: period,
           reference: invoice_id,
           timestamp: timestamp
       }}
    end
  end

  defp payment_for_event({_period, payment}, event_id) do
    if event_id in payment.event_ids, do: payment
  end

  defp paid_period_end(record), do: {:ok, shift_period(record, record.last_charged_period + 1)}

  defp claim_cancellation(subscription_store, record) do
    case Store.update(subscription_store, record.subscription_id, fn
           %Record{cancellation_effective_at: %DateTime{}} = current ->
             {:error, {:already_canceled, current}}

           %Record{method: "stripe", in_flight_reference: nil} = current ->
             {:ok, effective_at} = paid_period_end(current)
             reference = "cancel:#{DateTime.to_unix(effective_at)}"
             {:ok, %{current | in_flight_reference: reference}}

           %Record{method: "stripe", in_flight_reference: "cancel:" <> _timestamp} = current ->
             {:ok, current}

           %Record{} ->
             {:error, Errors.new(:verification_failed, "Stripe subscription operation is already in flight")}

           :not_found ->
             {:error, Errors.new(:verification_failed, "Stripe subscription not found")}
         end) do
      {:error, {:already_canceled, current}} -> {:error, :already_canceled, current}
      other -> other
    end
  end

  defp schedule_cancellation(subscription_store, record, effective_at, secret_key, config) do
    stripe_subscription_id = record.method_state.stripe_subscription_id
    cancel_at = DateTime.to_unix(effective_at)
    params = [{"cancel_at", Integer.to_string(cancel_at)}, {"proration_behavior", "none"}]
    key = cancellation_key(record.subscription_id, cancel_at)

    result =
      with {:ok, response} <-
             post_object(
               "/subscriptions/#{URI.encode(stripe_subscription_id)}",
               params,
               secret_key,
               config,
               key,
               "Stripe subscription cancellation failed"
             ),
           :ok <- validate_cancellation(response, stripe_subscription_id, cancel_at) do
        finalize_cancellation(subscription_store, record, effective_at)
      end

    case result do
      {:ok, _record} = ok ->
        ok

      {:error, _reason} = error ->
        _ = release_cancellation(subscription_store, record)
        error
    end
  end

  defp validate_cancellation(%{"id" => id, "cancel_at" => cancel_at}, id, cancel_at), do: :ok

  defp validate_cancellation(_response, _id, _cancel_at) do
    {:error, Errors.new(:verification_failed, "Stripe returned an invalid cancellation state")}
  end

  defp finalize_cancellation(subscription_store, record, effective_at) do
    Store.update(subscription_store, record.subscription_id, fn
      %Record{in_flight_reference: reference} = current when reference == record.in_flight_reference ->
        {:ok, %{current | cancellation_effective_at: effective_at, in_flight_reference: nil}}

      %Record{method: "stripe", cancellation_effective_at: ^effective_at} = current ->
        {:ok, %{current | in_flight_reference: nil}}

      %Record{} ->
        {:error, Errors.new(:verification_failed, @subscription_store_error)}

      :not_found ->
        {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end)
  end

  defp release_cancellation(subscription_store, record) do
    Store.update(subscription_store, record.subscription_id, fn
      %Record{in_flight_reference: reference} = current when reference == record.in_flight_reference ->
        {:ok, %{current | in_flight_reference: nil}}

      %Record{} = current ->
        {:ok, current}

      :not_found ->
        {:error, :subscription_not_found}
    end)
  end

  defp cancellation_key(subscription_id, cancel_at) do
    digest = :crypto.hash(:sha256, [subscription_id, ":", Integer.to_string(cancel_at)])
    "mpp-subscription-schedule-cancel-#{Base.url_encode64(digest, padding: false)}"
  end

  defp fetch_record(subscription_store, subscription_id) do
    case Store.get(subscription_store, subscription_id) do
      {:ok, record} -> {:ok, record}
      :not_found -> {:error, Errors.new(:verification_failed, "Stripe subscription not found")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  defp require_stripe_record(record, expected_stripe_id \\ nil)

  defp require_stripe_record(%Record{method: "stripe", method_state: state}, expected_stripe_id) do
    if is_binary(state[:stripe_subscription_id]) and
         (is_nil(expected_stripe_id) or state.stripe_subscription_id == expected_stripe_id) do
      :ok
    else
      renewal_error()
    end
  end

  defp require_stripe_record(%Record{}, _expected_stripe_id), do: renewal_error()

  defp renewal_error, do: {:error, Errors.new(:verification_failed, @renewal_invoice_error)}

  defp payment(period, reference, timestamp, event_ids) do
    %{period: period, reference: reference, timestamp: timestamp, event_ids: event_ids}
  end

  defp receipt(record, payment) do
    Receipt.new(
      method: "stripe",
      reference: payment.reference,
      external_id: record.subscription.external_id,
      subscription_id: record.subscription_id,
      timestamp: payment.timestamp,
      extensions: %{"stripeSubscription" => record.method_state.stripe_subscription_id}
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

  defp validate_store!(config) do
    subscription_store = store(config)

    if !Enum.all?([:get, :put, :update, :delete], &store_callback?(subscription_store, &1)) do
      raise ArgumentError,
            "MPP.Methods.Stripe subscription_store must implement MPP.Subscription.Store"
    end
  end

  defp public_method_details(details) do
    Map.take(details || %{}, ["network_id", "payment_method_types", "metadata"])
  end

  defp store(config), do: config["subscription_store"] || Store.default_store()

  defp store_callback?({module, _opts}, callback),
    do: function_exported?(module, callback, store_callback_arity(callback) + 1)

  defp store_callback?(module, callback), do: function_exported?(module, callback, store_callback_arity(callback))
  defp store_callback_arity(:get), do: 1
  defp store_callback_arity(:put), do: 1
  defp store_callback_arity(:update), do: 2
  defp store_callback_arity(:delete), do: 1

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
