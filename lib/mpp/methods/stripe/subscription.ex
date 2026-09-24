defmodule MPP.Methods.Stripe.Subscription do
  @moduledoc """
  Stripe Billing activation, renewal accounting, and cancellation for the
  shared subscription intent.

  Implements the constrained fixed-price profile from
  `draft-stripe-subscription-00`: one Customer, one recurring Price, one
  quantity-one Subscription, and synchronously paid invoices mapped onto
  locally persisted canonical periods.

  A PaymentMethod holds at most one live activation per plan (amount,
  currency, cadence, description, `externalId`, metadata, and network).
  Activating the same plan again under a different challenge is rejected
  until the earlier subscription's cancellation has taken effect; use
  distinct `externalId` values for plans that may legitimately coexist.

  Every Subscription created during activation carries `mpp_activation_claim`
  and `mpp_activation_generation` metadata. These two keys count against
  Stripe's metadata limit alongside `mpp_challenge_id` and `mpp_external_id`.

  An activation owns its claim for a 900-second lease and re-checks the claim
  before every Stripe write, starting a write only while at least 300 seconds
  of the lease remain. Write requests run without retries under bounded
  timeouts, so a claim is taken over only after every write of its previous
  owner has finished. Operator `req_options` cannot widen those write bounds.

  When an activation's Stripe outcome is unknown (lost response, store failure,
  interrupted worker), the payment method and plan stay blocked. A later
  activation lists the Customer's live Subscriptions and adopts the tagged one
  only when it is the single candidate and passes full validation, including
  its paid first invoice. Every other outcome (a Stripe error, several
  candidates, a candidate that does not validate) leaves the claim in
  `:needs_reconciliation`; reconciliation never cancels anything on Stripe.
  Resolve such a claim with `inspect_activation/2` and `resolve_activation/3`.
  An activation cancels only the Subscription it created itself, and only when
  it lost its claim or that Subscription definitively failed validation.
  Before that cancel it records the Subscription on the claim as `cancelling`
  in the same compare-and-set store write that adoption uses, so a cancel and
  an adoption of one Subscription never both happen: adoption refuses a
  Subscription marked `cancelling`, and the cancel is skipped once the claim
  names it as adopted. A cancel that cannot record its mark leaves the
  Subscription to the operator instead.
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
  @reserved_metadata_entries 4
  @metadata_key_max_bytes 40
  @metadata_value_max_bytes 500
  @seconds_per_day 86_400
  @days_per_week 7
  # Credential IDs are interpolated into Stripe URLs. Default URI.encode/1 leaves
  # `/` intact, so reject anything that is not a Stripe-style object id.
  @stripe_object_id ~r/\A[a-z]+_[A-Za-z0-9_]+\z/
  @renewal_invoice_error "Stripe renewal invoice does not match the subscription"
  @lifecycle_event_error "Stripe subscription lifecycle event does not match the subscription"
  @subscription_store_error "Stripe subscription store unavailable"
  @activation_claim_method "stripe_activation"
  # An activation owns its claim for this lease. A Stripe write may only start
  # with at least the write budget left, and the budget far exceeds the bounded
  # duration of one write request (see @write_request_options), so every write
  # of a generation has finished before that generation can be taken over.
  @activation_lease_seconds 900
  @activation_write_budget_seconds 300
  @write_request_options [retry: false, receive_timeout: 30_000, request_timeout: 30_000]
  @write_connect_timeout 10_000
  @ended_subscription_statuses ~w(canceled incomplete_expired)
  @stripe_list_limit "100"
  @stripe_list_max_pages 20

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
         {:ok, claim} <- claim_activation(subscription, payment_method, challenge_id, secret_key, config) do
      case claim do
        {:existing, receipt} -> {:ok, receipt}
        {:claimed, attempt} -> activate(subscription, payment_method, customer_input, secret_key, config, attempt)
      end
    end
  end

  def verify(_payload, %Subscription{}) do
    {:error, Errors.new(:invalid_payload, "Stripe subscription credential payload must be an object")}
  end

  defp activate(subscription, payment_method, customer_input, secret_key, config, attempt) do
    with :ok <- ensure_lease(attempt),
         {:ok, customer} <- resolve_customer(customer_input, payment_method, subscription, secret_key, config),
         :ok <- ensure_lease(attempt),
         {:ok, payment_method} <- attach_payment_method(payment_method, customer, subscription, secret_key, config),
         :ok <- ensure_lease(attempt),
         {:ok, product} <- create_product(subscription, customer, payment_method, secret_key, config),
         :ok <- validate_product(product),
         :ok <- ensure_lease(attempt),
         {:ok, price} <- create_price(subscription, customer, payment_method, product, secret_key, config),
         :ok <- validate_price(price, subscription, product),
         :ok <- fence_activation_claim(attempt, customer["id"]) do
      resources = %{customer: customer, payment_method: payment_method, price: price}

      case create_subscription(subscription, resources, secret_key, config, attempt) do
        {:ok, stripe_subscription} ->
          confirm_activation(stripe_subscription, resources, subscription, secret_key, config, attempt)

        {:absent, error} ->
          release_activation_claim(attempt)
          {:error, error}

        {:uncertain, error} ->
          hold_activation_claim(attempt, customer["id"])
          {:error, error}
      end
    else
      {:error, _reason} = error ->
        release_activation_claim(attempt)
        error
    end
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

  @doc "Process a Stripe subscription event after its webhook signature has been verified."
  @spec process_event(map(), map()) :: {:ok, Record.t()} | {:error, Errors.t()}
  def process_event(%{"id" => event_id} = event, config) when is_binary(event_id) and is_map(config) do
    with :ok <- require_stripe_object_id(event_id, "Event") do
      apply_lifecycle_event(event, config)
    end
  end

  def process_event(_event, _config) do
    {:error, Errors.new(:invalid_payload, "Stripe lifecycle processing requires an event and configuration")}
  end

  @doc "Stop Stripe collection for an unpaid invoice after its canonical period closes."
  @spec void_stale_invoice(String.t(), String.t(), DateTime.t(), map()) ::
          {:ok, Record.t()} | {:error, Errors.t()}
  def void_stale_invoice(subscription_id, invoice_id, %DateTime{} = as_of, config)
      when is_binary(subscription_id) and is_binary(invoice_id) and is_map(config) do
    with :ok <- require_stripe_object_id(invoice_id, "Invoice"),
         {:ok, record} <- fetch_record(store(config), subscription_id),
         :ok <- require_stripe_record(record) do
      case Map.get(closed_invoices(record), invoice_id) do
        nil -> do_void_stale_invoice(record, invoice_id, as_of, config)
        %{status: "closing"} -> do_void_stale_invoice(record, invoice_id, as_of, config)
        _closed -> {:ok, record}
      end
    end
  end

  def void_stale_invoice(_subscription_id, _invoice_id, _as_of, _config) do
    {:error,
     Errors.new(:invalid_payload, "Stripe stale invoice closure requires subscription, invoice, time, and configuration")}
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

  @doc """
  Report the activation claim for a payment method and plan, and the live Stripe
  Subscriptions tagged with it.

  Pass the same `MPP.Intents.Subscription` (including `method_details`) the
  route verifies with, and the Stripe PaymentMethod id (`pm_...`) the payer
  activated with. A `:needs_reconciliation` status means automatic
  reconciliation could not prove a single valid subscription; resolve it with
  `resolve_activation/3`.
  """
  @spec inspect_activation(Subscription.t(), String.t()) :: {:ok, map()} | {:error, Errors.t()}
  def inspect_activation(%Subscription{} = subscription, payment_method_id) when is_binary(payment_method_id) do
    with {:ok, context} <- operator_context(subscription, payment_method_id),
         {:ok, current} <- get_activation_claim(context.store, context.claim_id) do
      describe_activation_claim(current, context)
    end
  end

  def inspect_activation(_subscription, _payment_method_id), do: {:error, invalid_operator_arguments()}

  @doc """
  Resolve an activation claim that is waiting for reconciliation.

  `{:adopt, stripe_subscription_id}` records that live, claim-tagged Stripe
  Subscription as the activation after the same validation an activation runs,
  including its paid first invoice. `:release` reopens the claim, but only
  after its lease has expired and only while no live Subscription tagged with
  the claim remains; cancel unwanted ones in Stripe first. Nothing here cancels
  anything on Stripe.
  """
  @spec resolve_activation(Subscription.t(), String.t(), {:adopt, String.t()} | :release) ::
          {:ok, Record.t()} | {:error, Errors.t()}
  def resolve_activation(%Subscription{} = subscription, payment_method_id, resolution)
      when is_binary(payment_method_id) do
    with {:ok, context} <- operator_context(subscription, payment_method_id),
         {:ok, current} <- held_activation_claim(context) do
      apply_resolution(resolution, current, context)
    end
  end

  def resolve_activation(_subscription, _payment_method_id, _resolution), do: {:error, invalid_operator_arguments()}

  defp invalid_operator_arguments do
    Errors.new(:invalid_payload, "Stripe activation reconciliation requires a subscription intent and a PaymentMethod ID")
  end

  defp confirm_activation(stripe_subscription, resources, subscription, secret_key, config, attempt) do
    resources = Map.put(resources, :stripe_subscription, stripe_subscription)
    customer_id = resources.customer["id"]

    case activation_record(subscription, resources, secret_key, config, attempt.challenge_id) do
      {:ok, record} ->
        record_activation(record, stripe_subscription, customer_id, secret_key, config, attempt)

      {:unverified, error} ->
        hold_activation_claim(attempt, customer_id)
        {:error, error}

      {:error, _reason} = error ->
        abandon_subscription(stripe_subscription, customer_id, secret_key, config, attempt)
        error
    end
  end

  defp record_activation(record, stripe_subscription, customer_id, secret_key, config, attempt) do
    case finalize_activation_claim(attempt, record.subscription_id) do
      :ok ->
        persist_activation(record, attempt)

      :lost ->
        abandon_subscription(stripe_subscription, customer_id, secret_key, config, attempt)
        {:error, activation_in_progress()}

      :store_error ->
        hold_activation_claim(attempt, customer_id)
        store_unavailable()
    end
  end

  defp persist_activation(record, attempt) do
    case put_activation(attempt.store, record) do
      {:ok, stored} ->
        {:ok, receipt(stored, Map.fetch!(stored.payments, 0))}

      {:error, _reason} = error ->
        hold_finalized_claim(attempt)
        error
    end
  end

  defp activation_record(subscription, resources, secret_key, config, challenge_id) do
    %{stripe_subscription: stripe_subscription, customer: customer, payment_method: payment_method, price: price} =
      resources

    with {:ok, invoice_id, item_period} <-
           validate_subscription(stripe_subscription, customer, payment_method, price),
         {:ok, invoice} <- activation_invoice(invoice_id, secret_key, config),
         {:ok, paid_at} <-
           validate_invoice(invoice, stripe_subscription, customer, payment_method, price, subscription, item_period) do
      build_activation_record(subscription, resources, invoice, item_period, challenge_id, paid_at)
    end
  end

  # A failed invoice read says nothing about the subscription itself, so it must
  # never be treated as a definitive validation failure.
  defp activation_invoice(invoice_id, secret_key, config) do
    case retrieve_invoice(invoice_id, secret_key, config) do
      {:ok, invoice} -> {:ok, invoice}
      {:error, error} -> {:unverified, error}
    end
  end

  # Only the attempt that created a subscription ever cancels it on Stripe, and
  # its claim reopens only once Stripe confirms the cancellation. The cancel is
  # fenced by marking the subscription on the claim first: the mark and every
  # adoption are compare-and-set writes of the same claim record, so either the
  # adoption lands first and the mark sees it (no cancel), or the mark lands
  # first and no adoption of that subscription can follow.
  defp abandon_subscription(stripe_subscription, customer_id, secret_key, config, attempt) do
    case mark_cancelling(attempt, stripe_subscription, customer_id) do
      :adopted ->
        :ok

      :marked ->
        if cancel_confirmed?(stripe_subscription, secret_key, config),
          do: release_activation_claim(attempt),
          else: hold_activation_claim(attempt, customer_id)

      :unfenced ->
        hold_activation_claim(attempt, customer_id)
    end
  end

  defp mark_cancelling(attempt, %{"id" => stripe_id}, customer_id) when is_binary(stripe_id) do
    adopted_id = subscription_id(attempt.challenge_id, stripe_id)

    result =
      Store.update(attempt.store, attempt.claim_id, fn
        %Record{method: @activation_claim_method, method_state: %{subscription_id: ^adopted_id}} ->
          {:error, :activation_adopted}

        %Record{method: @activation_claim_method, method_state: %{customers: customers} = state} = claim ->
          marks = Enum.uniq(cancelling_marks(state) ++ [stripe_id])
          customers = Enum.uniq(customers ++ [customer_id])
          {:ok, %{claim | method_state: Map.merge(state, %{cancelling: marks, customers: customers})}}

        _other ->
          {:error, :activation_claim_lost}
      end)

    case result do
      {:ok, _claim} -> :marked
      {:error, :activation_adopted} -> :adopted
      {:error, _reason} -> :unfenced
    end
  end

  defp mark_cancelling(_attempt, _stripe_subscription, _customer_id), do: :unfenced

  defp cancelling_marks(state), do: Map.get(state, :cancelling, [])

  defp marked_for_cancel?(%Record{method_state: state}, stripe_id), do: stripe_id in cancelling_marks(state)

  defp claim_adopted?(attempt, subscription_id) do
    generation = attempt.generation

    match?(
      {:ok,
       %Record{
         method: @activation_claim_method,
         method_state: %{status: :active, generation: ^generation, subscription_id: ^subscription_id}
       }},
      Store.get(attempt.store, attempt.claim_id)
    )
  end

  defp cancel_confirmed?(%{"id" => id}, secret_key, config) when is_binary(id) do
    if stripe_object_id?(id) do
      case stripe_request(:delete, "/subscriptions/#{id}", [], secret_key, config, subscription_cancel_key(id)) do
        {:ok, %{"id" => ^id, "status" => status}} when status in @ended_subscription_statuses -> true
        _unconfirmed -> ended_on_stripe?(id, secret_key, config)
      end
    else
      false
    end
  end

  defp cancel_confirmed?(_stripe_subscription, _secret_key, _config), do: false

  defp ended_on_stripe?(id, secret_key, config) do
    match?(
      {:ok, %{"id" => ^id, "status" => status}} when status in @ended_subscription_statuses,
      stripe_request(:get, "/subscriptions/#{id}", [], secret_key, config, nil)
    )
  end

  defp subscription_cancel_key(stripe_subscription_id) do
    digest = :crypto.hash(:sha256, ["mpp:stripe:activation-cancel:", stripe_subscription_id])
    "mpp-subscription-cancel-#{Base.url_encode64(digest, padding: false)}"
  end

  defp claim_activation(subscription, payment_method, challenge_id, secret_key, config) do
    context = %{
      store: store(config),
      claim_id: activation_claim_id(subscription, payment_method["id"], config),
      challenge_id: challenge_id,
      subscription: subscription,
      payment_method: payment_method,
      secret_key: secret_key,
      config: config,
      now: DateTime.utc_now()
    }

    with {:ok, current} <- get_activation_claim(context.store, context.claim_id) do
      case activation_claim_decision(current, context) do
        :take -> take_activation_claim(current, context)
        :reconcile -> reconcile_activation_claim(current, context)
        {:existing, receipt} -> {:ok, {:existing, receipt}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp get_activation_claim(subscription_store, claim_id) do
    case Store.get(subscription_store, claim_id) do
      {:ok, %Record{} = claim} -> {:ok, claim}
      :not_found -> {:ok, :not_found}
      {:error, _reason} -> store_unavailable()
    end
  end

  defp activation_claim_decision(:not_found, _context), do: :take

  defp activation_claim_decision(%Record{method: @activation_claim_method, method_state: state}, context) do
    case state do
      %{status: :released} ->
        :take

      %{status: :pending} ->
        if lease_expired?(state, context.now), do: :reconcile, else: {:error, activation_in_progress()}

      %{status: :needs_reconciliation} ->
        :reconcile

      %{status: :active, subscription_id: subscription_id} ->
        active_claim_decision(subscription_id, state, context)

      _malformed ->
        {:error, activation_conflict()}
    end
  end

  defp activation_claim_decision(_claim, _context), do: {:error, activation_conflict()}

  defp lease_expired?(%{claimed_at: %DateTime{} = claimed_at}, now),
    do: DateTime.diff(now, claimed_at, :second) >= @activation_lease_seconds

  defp lease_expired?(_state, _now), do: false

  defp active_claim_decision(subscription_id, state, context) do
    case Store.get(context.store, subscription_id) do
      {:ok, %Record{method: "stripe"} = record} ->
        cond do
          subscription_ended?(record, context.now) -> :take
          state.challenge_id == context.challenge_id -> {:existing, receipt(record, Map.fetch!(record.payments, 0))}
          true -> {:error, already_active()}
        end

      {:ok, %Record{}} ->
        {:error, activation_conflict()}

      :not_found ->
        :reconcile

      {:error, _reason} ->
        store_unavailable()
    end
  end

  defp subscription_ended?(%Record{cancellation_effective_at: nil}, _now), do: false

  defp subscription_ended?(%Record{cancellation_effective_at: %DateTime{} = effective_at}, now),
    do: DateTime.compare(effective_at, now) != :gt

  defp take_activation_claim(current, context) do
    generation = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    claim = activation_claim(context, generation, watched_customers(current))
    claim = put_in(claim.method_state[:cancelling], carried_marks(current))

    with {:ok, _claim} <- replace_activation_claim(context, current, claim) do
      {:ok,
       {:claimed,
        %{store: context.store, claim_id: context.claim_id, challenge_id: context.challenge_id, generation: generation}}}
    end
  end

  # Customers stay watched across generations so a later reconciliation still
  # sees any subscription an earlier generation created.
  defp watched_customers(%Record{method_state: %{customers: customers}}) when is_list(customers), do: customers
  defp watched_customers(_claim), do: []

  defp carried_marks(%Record{method_state: state}) when is_map(state), do: cancelling_marks(state)
  defp carried_marks(_claim), do: []

  defp replace_activation_claim(context, expected, claim) do
    result =
      Store.update(context.store, context.claim_id, fn current ->
        if current == expected, do: {:ok, claim}, else: {:error, activation_in_progress()}
      end)

    case result do
      {:ok, stored} -> {:ok, stored}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> store_unavailable()
    end
  end

  # Reconciliation never cancels anything on Stripe. It adopts the single live
  # subscription tagged with this claim when that subscription fully validates,
  # reopens the claim only when nothing is live and the lease has run out, and
  # otherwise leaves the claim for resolve_activation/3.
  defp reconcile_activation_claim(%Record{method_state: state} = current, context) do
    case claimed_live_subscriptions(state.customers, context) do
      {:ok, []} ->
        if lease_expired?(state, context.now),
          do: take_activation_claim(current, context),
          else: {:error, activation_in_progress()}

      {:ok, [stripe_subscription]} ->
        adopt_or_hold(current, stripe_subscription, context)

      _ambiguous_or_unknown ->
        hold_for_operator(current, context)
    end
  end

  # A subscription its creator started cancelling is never adopted.
  defp adopt_or_hold(current, stripe_subscription, context) do
    with false <- marked_for_cancel?(current, stripe_subscription["id"]),
         {:ok, adoptable} <- adoptable_activation(stripe_subscription, context) do
      adopt_activation(current, adoptable, context)
    else
      _marked_or_invalid -> hold_for_operator(current, context)
    end
  end

  defp hold_for_operator(%Record{method_state: state} = current, context) do
    held = %{current | method_state: %{state | status: :needs_reconciliation}}

    with {:ok, _claim} <- replace_activation_claim(context, current, held) do
      {:error, reconciliation_failed()}
    end
  end

  defp claimed_live_subscriptions(customers, context) do
    Enum.reduce_while(customers, {:ok, []}, fn customer_id, {:ok, acc} ->
      case list_customer_subscriptions(customer_id, context, nil, 1, []) do
        {:ok, subscriptions} -> {:cont, {:ok, acc ++ Enum.filter(subscriptions, &claimed_live?(&1, context.claim_id))}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp list_customer_subscriptions(customer_id, context, starting_after, page, acc) when page <= @stripe_list_max_pages do
    query =
      URI.encode_query(
        maybe_put_param([{"customer", customer_id}, {"limit", @stripe_list_limit}], "starting_after", starting_after)
      )

    case stripe_request(:get, "/subscriptions?#{query}", [], context.secret_key, context.config, nil) do
      {:ok, %{"data" => subscriptions, "has_more" => false}} when is_list(subscriptions) ->
        {:ok, acc ++ subscriptions}

      {:ok, %{"data" => [_ | _] = subscriptions, "has_more" => true}} ->
        next_subscriptions_page(customer_id, context, subscriptions, page, acc)

      _unknown ->
        {:error, reconciliation_failed()}
    end
  end

  defp list_customer_subscriptions(_customer_id, _context, _starting_after, _page, _acc),
    do: {:error, reconciliation_failed()}

  defp next_subscriptions_page(customer_id, context, subscriptions, page, acc) do
    case List.last(subscriptions) do
      %{"id" => last_id} when is_binary(last_id) ->
        list_customer_subscriptions(customer_id, context, last_id, page + 1, acc ++ subscriptions)

      _malformed ->
        {:error, reconciliation_failed()}
    end
  end

  defp maybe_put_param(params, _name, nil), do: params
  defp maybe_put_param(params, name, value), do: params ++ [{name, value}]

  defp claimed_live?(
         %{
           "status" => status,
           "metadata" => %{"mpp_activation_claim" => claim_id, "mpp_activation_generation" => generation}
         },
         claim_id
       )
       when is_binary(generation), do: status not in @ended_subscription_statuses

  defp claimed_live?(_subscription, _claim_id), do: false

  defp adoptable_activation(
         %{
           "customer" => customer_id,
           "items" => %{"data" => [%{"price" => %{"id" => price_id}}]},
           "metadata" => %{"mpp_challenge_id" => challenge_id, "mpp_activation_generation" => generation}
         } = stripe_subscription,
         context
       )
       when is_binary(customer_id) and is_binary(price_id) and is_binary(challenge_id) do
    resources = %{
      stripe_subscription: stripe_subscription,
      customer: %{"id" => customer_id},
      payment_method: context.payment_method,
      price: %{"id" => price_id}
    }

    case activation_record(context.subscription, resources, context.secret_key, context.config, challenge_id) do
      {:ok, record} -> {:ok, {record, generation, challenge_id}}
      _unverified_or_invalid -> :error
    end
  end

  defp adoptable_activation(_stripe_subscription, _context), do: :error

  defp adopt_activation(current, {_record, _generation, challenge_id} = adoptable, context) do
    with {:ok, stored} <- adopt_claim(current, adoptable, context) do
      if challenge_id == context.challenge_id,
        do: {:ok, {:existing, receipt(stored, Map.fetch!(stored.payments, 0))}},
        else: {:error, already_active()}
    end
  end

  defp adopt_claim(current, {record, generation, challenge_id}, context) do
    if marked_for_cancel?(current, record.method_state.stripe_subscription_id),
      do: {:error, Errors.new(:verification_failed, "Stripe Subscription is being canceled by its activation")},
      else: replace_with_adoption(current, {record, generation, challenge_id}, context)
  end

  defp replace_with_adoption(current, {record, generation, challenge_id}, context) do
    adopted = %{
      current
      | method_state: %{
          current.method_state
          | status: :active,
            generation: generation,
            challenge_id: challenge_id,
            subscription_id: record.subscription_id,
            customers: Enum.uniq(current.method_state.customers ++ [record.method_state.customer_id])
        }
    }

    with {:ok, _claim} <- replace_activation_claim(context, current, adopted) do
      put_activation(context.store, record)
    end
  end

  # Every Stripe write starts only while this attempt still owns its pending
  # claim with the write budget left on the lease, so no request of a superseded
  # generation can still be in flight when another attempt may take over.
  defp ensure_lease(attempt) do
    generation = attempt.generation

    case Store.get(attempt.store, attempt.claim_id) do
      {:ok,
       %Record{
         method: @activation_claim_method,
         method_state: %{status: :pending, generation: ^generation, claimed_at: claimed_at}
       }} ->
        if DateTime.diff(DateTime.utc_now(), claimed_at, :second) <=
             @activation_lease_seconds - @activation_write_budget_seconds,
           do: :ok,
           else: {:error, lease_expired()}

      {:error, _reason} ->
        store_unavailable()

      _lost ->
        {:error, activation_in_progress()}
    end
  end

  # Records the customer before the subscription write so reconciliation knows
  # where to look.
  defp fence_activation_claim(attempt, customer_id) do
    with :ok <- ensure_lease(attempt) do
      attempt
      |> update_owned_claim(:pending, &%{&1 | customers: Enum.uniq(&1.customers ++ [customer_id])})
      |> owned_claim_result()
    end
  end

  # A reconciler that adopted this attempt's own subscription has already
  # finalized the claim and recorded the activation on its behalf.
  defp finalize_activation_claim(attempt, subscription_id) do
    case update_owned_claim(attempt, :pending, &%{&1 | status: :active, subscription_id: subscription_id}) do
      :lost -> if claim_adopted?(attempt, subscription_id), do: :ok, else: :lost
      result -> result
    end
  end

  defp release_activation_claim(attempt) do
    update_owned_claim(attempt, :pending, &%{&1 | status: :released, customers: []})
    :ok
  end

  defp hold_activation_claim(attempt, customer_id) do
    if update_owned_claim(attempt, :pending, &%{&1 | status: :needs_reconciliation}) != :ok,
      do: force_reconciliation(attempt, customer_id)

    :ok
  end

  defp hold_finalized_claim(attempt) do
    update_owned_claim(attempt, :active, &%{&1 | status: :needs_reconciliation})
    :ok
  end

  # An attempt that lost its claim and cannot prove its subscription gone
  # reopens reconciliation for whoever holds the claim now.
  defp force_reconciliation(attempt, customer_id) do
    Store.update(attempt.store, attempt.claim_id, fn
      %Record{method: @activation_claim_method, method_state: %{customers: customers} = state} = claim ->
        customers = Enum.uniq(customers ++ [customer_id])
        {:ok, %{claim | method_state: %{state | status: :needs_reconciliation, customers: customers}}}

      _other ->
        {:error, :activation_claim_lost}
    end)
  end

  defp update_owned_claim(attempt, status, transform) do
    generation = attempt.generation

    result =
      Store.update(attempt.store, attempt.claim_id, fn
        %Record{method: @activation_claim_method, method_state: %{generation: ^generation, status: ^status} = state} =
            claim ->
          {:ok, %{claim | method_state: transform.(state)}}

        _other ->
          {:error, :activation_claim_lost}
      end)

    case result do
      {:ok, _claim} -> :ok
      {:error, :activation_claim_lost} -> :lost
      {:error, _reason} -> :store_error
    end
  end

  defp owned_claim_result(:ok), do: :ok
  defp owned_claim_result(:lost), do: {:error, activation_in_progress()}
  defp owned_claim_result(:store_error), do: store_unavailable()

  defp operator_context(subscription, payment_method_id) do
    config = subscription.method_details || %{}

    with :ok <- validate_profile(subscription),
         {:ok, secret_key} <- require_config(config, "stripe_secret_key"),
         :ok <- require_stripe_object_id(payment_method_id, "PaymentMethod") do
      {:ok,
       %{
         store: store(config),
         claim_id: activation_claim_id(subscription, payment_method_id, config),
         challenge_id: nil,
         subscription: subscription,
         payment_method: %{"id" => payment_method_id},
         secret_key: secret_key,
         config: config,
         now: DateTime.utc_now()
       }}
    end
  end

  defp describe_activation_claim(:not_found, context),
    do: {:ok, %{claim_id: context.claim_id, status: :none, tagged_subscriptions: []}}

  defp describe_activation_claim(
         %Record{method: @activation_claim_method, method_state: %{status: status, customers: customers} = state},
         context
       ) do
    with {:ok, live} <- claimed_live_subscriptions(customers, context) do
      {:ok,
       %{
         claim_id: context.claim_id,
         status: status,
         challenge_id: state[:challenge_id],
         generation: state[:generation],
         claimed_at: state[:claimed_at],
         lease_expired: lease_expired?(state, context.now),
         subscription_id: state[:subscription_id],
         cancelling: cancelling_marks(state),
         tagged_subscriptions: Enum.map(live, &tagged_subscription_summary/1)
       }}
    end
  end

  defp describe_activation_claim(_claim, _context), do: {:error, activation_conflict()}

  defp tagged_subscription_summary(stripe_subscription) do
    metadata = stripe_subscription["metadata"]

    %{
      id: stripe_subscription["id"],
      status: stripe_subscription["status"],
      customer: stripe_subscription["customer"],
      challenge_id: metadata["mpp_challenge_id"],
      generation: metadata["mpp_activation_generation"]
    }
  end

  defp held_activation_claim(context) do
    case get_activation_claim(context.store, context.claim_id) do
      {:ok, %Record{method: @activation_claim_method, method_state: %{status: :needs_reconciliation}} = claim} ->
        {:ok, claim}

      {:ok, %Record{method: @activation_claim_method, method_state: %{status: :pending} = state} = claim} ->
        if lease_expired?(state, context.now), do: {:ok, claim}, else: {:error, activation_in_progress()}

      {:ok, _claim} ->
        {:error, not_held()}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_resolution({:adopt, stripe_subscription_id}, current, context) when is_binary(stripe_subscription_id) do
    with :ok <- require_stripe_object_id(stripe_subscription_id, "Subscription"),
         {:ok, stripe_subscription} <-
           get_object(
             "/subscriptions/#{stripe_subscription_id}",
             context.secret_key,
             context.config,
             "Stripe Subscription retrieval failed"
           ),
         :ok <- require_claimed(stripe_subscription, stripe_subscription_id, context),
         {:ok, adoptable} <- operator_adoptable(stripe_subscription, context) do
      adopt_claim(current, adoptable, context)
    end
  end

  defp apply_resolution(:release, %Record{method_state: state} = current, context) do
    if lease_expired?(state, context.now),
      do: release_unless_live(current, context),
      else: {:error, activation_in_progress()}
  end

  defp apply_resolution(_resolution, _current, _context) do
    {:error, Errors.new(:invalid_payload, "Stripe activation resolution must be {:adopt, subscription_id} or :release")}
  end

  defp release_unless_live(%Record{method_state: state} = current, context) do
    case claimed_live_subscriptions(state.customers, context) do
      {:ok, []} ->
        released = %{current | method_state: %{state | status: :released, customers: []}}
        replace_activation_claim(context, current, released)

      {:ok, _live} ->
        {:error, Errors.new(:verification_failed, "Stripe subscription activation still has a live tagged subscription")}

      {:error, _reason} = error ->
        error
    end
  end

  defp require_claimed(%{"id" => id} = stripe_subscription, id, context) do
    if claimed_live?(stripe_subscription, context.claim_id),
      do: :ok,
      else:
        {:error, Errors.new(:verification_failed, "Stripe Subscription is not a live subscription of this activation")}
  end

  defp require_claimed(_stripe_subscription, _id, _context) do
    {:error, Errors.new(:verification_failed, "Stripe Subscription is not a live subscription of this activation")}
  end

  defp operator_adoptable(stripe_subscription, context) do
    case adoptable_activation(stripe_subscription, context) do
      {:ok, adoptable} -> {:ok, adoptable}
      :error -> {:error, reconciliation_failed()}
    end
  end

  defp activation_claim(context, generation, customers) do
    subscription = context.subscription

    %Record{
      subscription_id: context.claim_id,
      method: @activation_claim_method,
      subscription: %{subscription | method_details: public_method_details(subscription.method_details)},
      method_state: %{
        status: :pending,
        challenge_id: context.challenge_id,
        generation: generation,
        claimed_at: context.now,
        customers: customers,
        subscription_id: nil
      },
      billing_anchor: context.now,
      reference: context.challenge_id,
      timestamp: DateTime.to_iso8601(context.now)
    }
  end

  # One live activation per payment method and plan: the key deliberately omits
  # the challenge so a fresh challenge cannot mint a second Stripe subscription.
  defp activation_claim_id(subscription, payment_method_id, config) do
    fingerprint = %{
      "amount" => subscription.amount,
      "currency" => subscription.currency,
      "description" => subscription.description,
      "externalId" => subscription.external_id,
      "metadata" => config["metadata"] || %{},
      "networkId" => config["network_id"],
      "paymentMethod" => payment_method_id,
      "periodCount" => subscription.period_count,
      "periodUnit" => Atom.to_string(subscription.period_unit)
    }

    digest =
      :sha256
      |> :crypto.hash(JCS.canonicalize(fingerprint))
      |> Base.url_encode64(padding: false)

    "stripe-activation:" <> digest
  end

  defp store_unavailable, do: {:error, Errors.new(:verification_failed, @subscription_store_error)}

  defp activation_in_progress do
    Errors.new(:verification_failed, "Stripe subscription activation is already in progress for this payment method")
  end

  defp already_active do
    Errors.new(:verification_failed, "Stripe subscription is already active for this payment method")
  end

  defp reconciliation_failed do
    Errors.new(:verification_failed, "Stripe subscription activation could not be reconciled with Stripe")
  end

  defp lease_expired do
    Errors.new(:verification_failed, "Stripe subscription activation lease expired before Stripe was updated")
  end

  defp not_held do
    Errors.new(:verification_failed, "Stripe subscription activation does not need reconciliation")
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

  defp create_subscription(subscription, resources, secret_key, config, attempt) do
    %{customer: customer, payment_method: payment_method, price: price} = resources

    metadata =
      subscription
      |> metadata(config)
      |> Map.put("mpp_activation_claim", attempt.claim_id)
      |> Map.put("mpp_activation_generation", attempt.generation)

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
      ] ++ metadata_params(metadata)

    key =
      idempotency_key("subscription", subscription, customer["id"], payment_method["id"], config, attempt.generation)

    case stripe_request(:post, "/subscriptions", params, secret_key, config, key) do
      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:error, {:stripe, 402, %{"error" => %{"code" => "subscription_payment_intent_requires_action"}}}} ->
        {:absent, Errors.new(:verification_failed, "Stripe subscription first invoice requires customer action")}

      # Stripe rejects these before creating anything; a 409 is a concurrent
      # request on the same idempotency key whose outcome is still unknown.
      {:error, {:stripe, status, _body}} when status in 400..499 and status != 409 ->
        {:absent, Errors.new(:verification_failed, "Stripe subscription activation failed")}

      {:error, _reason} ->
        {:uncertain, Errors.new(:verification_failed, "Stripe subscription activation failed")}

      {:ok, _body} ->
        {:uncertain, Errors.new(:verification_failed, "Stripe returned an invalid Subscription")}
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

  defp build_activation_record(subscription, resources, invoice, {period_start, period_end}, challenge_id, paid_at) do
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

      {:ok, record}
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

  defp apply_lifecycle_event(
         %{
           "id" => event_id,
           "type" => "customer.subscription.deleted",
           "created" => created,
           "data" => %{"object" => subscription}
         },
         config
       ) do
    record_revocation(event_id, subscription, created, ["canceled"], config)
  end

  defp apply_lifecycle_event(
         %{
           "id" => event_id,
           "type" => "customer.subscription.updated",
           "created" => created,
           "data" => %{"object" => subscription}
         },
         config
       ) do
    record_revocation(event_id, subscription, created, ["canceled", "unpaid"], config)
  end

  defp apply_lifecycle_event(_event, _config), do: lifecycle_error()

  defp record_revocation(event_id, subscription, created, statuses, config) do
    with {:ok, stripe_id, challenge_id, effective_at} <-
           revocation_identity(subscription, created, statuses),
         subscription_id = subscription_id(challenge_id, stripe_id),
         {:ok, record} <- fetch_record(store(config), subscription_id),
         :ok <- require_stripe_record(record, stripe_id) do
      update_revocation(record, event_id, effective_at, config)
    end
  end

  defp revocation_identity(
         %{"id" => stripe_id, "status" => status, "metadata" => %{"mpp_challenge_id" => challenge_id}} = subscription,
         created,
         statuses
       )
       when is_binary(challenge_id) and challenge_id != "" and is_integer(created) do
    effective_at = subscription["canceled_at"] || subscription["ended_at"] || created

    with true <- status in statuses and is_integer(effective_at),
         :ok <- require_stripe_object_id(stripe_id, "Subscription"),
         {:ok, datetime} <- DateTime.from_unix(effective_at) do
      {:ok, stripe_id, challenge_id, datetime}
    else
      _error -> lifecycle_error()
    end
  end

  defp revocation_identity(_subscription, _created, _statuses), do: lifecycle_error()

  defp update_revocation(record, event_id, effective_at, config) do
    case Store.update(store(config), record.subscription_id, fn current ->
           mark_revoked(current, record.method_state.stripe_subscription_id, event_id, effective_at)
         end) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  defp mark_revoked(%Record{method: "stripe"} = record, stripe_id, event_id, effective_at) do
    with :ok <- require_stripe_record(record, stripe_id) do
      event_ids = Enum.uniq((record.method_state[:revocation_event_ids] || []) ++ [event_id])
      method_state = Map.put(record.method_state, :revocation_event_ids, event_ids)

      {:ok,
       %{
         record
         | cancellation_effective_at: earliest_effective_at(record.cancellation_effective_at, effective_at),
           method_state: method_state
       }}
    end
  end

  defp mark_revoked(%Record{}, _stripe_id, _event_id, _effective_at), do: lifecycle_error()
  defp mark_revoked(:not_found, _stripe_id, _event_id, _effective_at), do: lifecycle_error()

  defp earliest_effective_at(nil, effective_at), do: effective_at

  defp earliest_effective_at(current, effective_at) do
    if DateTime.before?(effective_at, current), do: effective_at, else: current
  end

  defp do_void_stale_invoice(record, invoice_id, as_of, config) do
    with {:ok, secret_key} <- require_config(config, "stripe_secret_key"),
         {:ok, invoice, period} <- prepare_stale_invoice(record, invoice_id, as_of, secret_key, config),
         {:ok, claimed} <- claim_stale_invoice(record, invoice_id, period, as_of, config) do
      case stop_invoice_collection(invoice, claimed, invoice_id, secret_key, config) do
        {:ok, status} -> finalize_stale_invoice(claimed, invoice_id, period, status, config)
        {:error, %Errors{} = error} -> release_stale_invoice(claimed, invoice_id, config, error)
      end
    else
      {:error, :already_closed, current} -> {:ok, current}
      {:error, %Errors{} = error} -> {:error, error}
    end
  end

  defp prepare_stale_invoice(record, invoice_id, as_of, secret_key, config) do
    with {:ok, invoice} <- retrieve_invoice(invoice_id, secret_key, config),
         {:ok, stripe_id, _challenge_id, item_period} <- renewal_identity(invoice, invoice_id),
         :ok <- require_stripe_record(record, stripe_id),
         {:ok, period} <- canonical_period(record, item_period),
         true <- period > record.last_charged_period,
         true <- DateTime.to_unix(as_of) >= elem(item_period, 1),
         :ok <- validate_unpaid_invoice(invoice, record, item_period) do
      {:ok, invoice, period}
    else
      {:error, %Errors{} = error} -> {:error, error}
      _mismatch -> lifecycle_error()
    end
  end

  defp validate_unpaid_invoice(
         %{
           "status" => status,
           "customer" => customer_id,
           "currency" => currency,
           "amount_paid" => 0,
           "total" => amount,
           "discounts" => [],
           "total_discount_amounts" => [],
           "total_taxes" => [],
           "automatic_tax" => %{"enabled" => false}
         } = invoice,
         record,
         item_period
       )
       when status in ["draft", "open", "void", "uncollectible"] do
    state = record.method_state
    stripe_subscription = %{"id" => state.stripe_subscription_id}
    price = %{"id" => state.price_id}
    expected_amount = String.to_integer(record.subscription.amount)

    if customer_id == state.customer_id and currency == record.subscription.currency and
         amount == expected_amount do
      validate_invoice_line(invoice, stripe_subscription, price, record.subscription, item_period)
    else
      lifecycle_error()
    end
  end

  defp validate_unpaid_invoice(_invoice, _record, _item_period), do: lifecycle_error()

  defp claim_stale_invoice(record, invoice_id, period, as_of, config) do
    case Store.update(store(config), record.subscription_id, fn
           %Record{method: "stripe"} = current ->
             claim_stale_invoice_record(current, invoice_id, period, as_of)

           %Record{} ->
             lifecycle_error()

           :not_found ->
             lifecycle_error()
         end) do
      {:error, {:already_closed, current}} -> {:error, :already_closed, current}
      {:ok, claimed} -> {:ok, claimed}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  defp claim_stale_invoice_record(record, invoice_id, period, as_of) do
    if period <= record.last_charged_period do
      lifecycle_error()
    else
      case Map.get(closed_invoices(record), invoice_id) do
        nil ->
          closure = %{period: period, status: "closing", timestamp: DateTime.to_iso8601(as_of)}
          {:ok, put_closed_invoice(record, invoice_id, closure)}

        %{period: ^period, status: "closing"} ->
          {:ok, record}

        %{period: ^period} ->
          {:error, {:already_closed, record}}

        _other ->
          lifecycle_error()
      end
    end
  end

  defp stop_invoice_collection(%{"status" => "open"}, record, invoice_id, secret_key, config) do
    key = invoice_closure_key("void", record.subscription_id, invoice_id)

    with {:ok, response} <-
           post_object(
             "/invoices/#{URI.encode(invoice_id)}/void",
             [],
             secret_key,
             config,
             key,
             "Stripe stale invoice voiding failed"
           ),
         :ok <- validate_stopped_invoice(response, invoice_id, "void") do
      {:ok, "void"}
    end
  end

  defp stop_invoice_collection(%{"status" => "draft"}, record, invoice_id, secret_key, config) do
    key = invoice_closure_key("disable", record.subscription_id, invoice_id)

    with {:ok, response} <-
           post_object(
             "/invoices/#{URI.encode(invoice_id)}",
             [{"auto_advance", "false"}],
             secret_key,
             config,
             key,
             "Stripe stale invoice collection disabling failed"
           ),
         :ok <- validate_stopped_invoice(response, invoice_id, "draft") do
      {:ok, "collection_disabled"}
    end
  end

  defp stop_invoice_collection(%{"status" => status}, _record, _invoice_id, _secret_key, _config)
       when status in ["void", "uncollectible"], do: {:ok, status}

  defp stop_invoice_collection(_invoice, _record, _invoice_id, _secret_key, _config), do: lifecycle_error()

  defp validate_stopped_invoice(%{"id" => id, "status" => status, "auto_advance" => false}, id, status), do: :ok

  defp validate_stopped_invoice(_invoice, _id, _status), do: lifecycle_error()

  defp finalize_stale_invoice(record, invoice_id, period, status, config) do
    update = &finalize_stale_invoice_record(&1, invoice_id, period, status)

    case Store.update(store(config), record.subscription_id, update) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Errors{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @subscription_store_error)}
    end
  end

  defp finalize_stale_invoice_record(%Record{} = record, invoice_id, period, status) do
    case Map.get(closed_invoices(record), invoice_id) do
      %{period: ^period, status: "closing"} = closure ->
        {:ok, put_closed_invoice(record, invoice_id, %{closure | status: status})}

      %{period: ^period, status: ^status} ->
        {:ok, record}

      _other ->
        lifecycle_error()
    end
  end

  defp finalize_stale_invoice_record(:not_found, _invoice_id, _period, _status), do: lifecycle_error()

  defp release_stale_invoice(record, invoice_id, config, error) do
    _ =
      Store.update(store(config), record.subscription_id, fn
        %Record{} = current ->
          case Map.get(closed_invoices(current), invoice_id) do
            %{status: "closing"} ->
              {:ok, put_closed_invoices(current, Map.delete(closed_invoices(current), invoice_id))}

            _other ->
              {:ok, current}
          end

        :not_found ->
          {:error, :subscription_not_found}
      end)

    {:error, error}
  end

  defp closed_invoices(record), do: record.method_state[:closed_invoices] || %{}

  defp put_closed_invoice(record, invoice_id, closure) do
    put_closed_invoices(record, Map.put(closed_invoices(record), invoice_id, closure))
  end

  defp put_closed_invoices(record, invoices) do
    %{record | method_state: Map.put(record.method_state, :closed_invoices, invoices)}
  end

  defp invoice_closure_key(action, subscription_id, invoice_id) do
    digest = :crypto.hash(:sha256, [subscription_id, ":", invoice_id])
    "mpp-subscription-#{action}-invoice-#{Base.url_encode64(digest, padding: false)}"
  end

  defp validate_renewal(invoice, invoice_id, config) do
    with {:ok, stripe_subscription_id, challenge_id, item_period} <-
           renewal_identity(invoice, invoice_id),
         subscription_id = subscription_id(challenge_id, stripe_subscription_id),
         {:ok, record} <- fetch_record(store(config), subscription_id),
         :ok <- require_stripe_record(record, stripe_subscription_id),
         :ok <- require_recordable_invoice(record, invoice_id),
         {:ok, paid_at} <- validate_renewal_invoice(invoice, record, item_period),
         {:ok, period} <- canonical_period(record, item_period),
         :ok <- require_timely_payment(paid_at, elem(item_period, 1)),
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

  defp require_recordable_invoice(record, invoice_id) do
    if Map.has_key?(closed_invoices(record), invoice_id), do: renewal_error(), else: :ok
  end

  defp require_timely_payment(paid_at, period_end) do
    if DateTime.to_unix(paid_at) < period_end, do: :ok, else: renewal_error()
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
    period_start = record |> shift_period(period) |> DateTime.to_unix()

    with :ok <- require_recordable_invoice(record, invoice_id),
         :ok <- require_payable_period(record, period, period_start) do
      event_payment = Enum.find_value(record.payments, &payment_for_event(&1, event_id))

      case event_payment do
        %{reference: ^invoice_id, period: ^period} -> {:ok, record}
        nil -> update_renewal_period(record, period, invoice_id, event_id, timestamp)
        _other -> renewal_error()
      end
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
        {:ok,
         %{
           current
           | cancellation_effective_at: earliest_effective_at(current.cancellation_effective_at, effective_at),
             in_flight_reference: nil
         }}

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
  defp lifecycle_error, do: {:error, Errors.new(:verification_failed, @lifecycle_event_error)}

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

  defp idempotency_key(operation, subscription, customer, payment_method, config, generation \\ nil) do
    fingerprint =
      maybe_put(
        %{
          "amount" => subscription.amount,
          "challenge" => config["challenge_id"],
          "currency" => subscription.currency,
          "customer" => customer,
          "paymentMethod" => payment_method,
          "periodCount" => subscription.period_count,
          "periodUnit" => Atom.to_string(subscription.period_unit)
        },
        "generation",
        generation
      )

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

    case Req.request(request, request_options(method, config["req_options"] || [])) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:stripe, status, body}}
      {:error, reason} -> {:error, {:request, reason}}
    end
  end

  # Writes get fixed, non-retried timeouts that callers cannot widen: the
  # activation lease depends on a write never outliving the write budget.
  defp request_options(:get, options), do: options

  # Req rejects :connect_options next to :finch; a custom Finch pool keeps its
  # own connect timeout, while request_timeout still bounds the response.
  defp request_options(_write, options) do
    options = Keyword.merge(options, @write_request_options)

    if Keyword.has_key?(options, :finch),
      do: options,
      else:
        Keyword.update(
          options,
          :connect_options,
          [timeout: @write_connect_timeout],
          &Keyword.put(&1, :timeout, @write_connect_timeout)
        )
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
