defmodule MPP.Method do
  @moduledoc """
  Behaviour for pluggable payment method verification.

  A payment method connects the MPP protocol to a real payment system
  (Stripe, Tempo, x402/EVM, etc.). Each method module implements three
  callbacks that the `MPP.Plug` middleware uses during the 402 handshake:

    1. `method_name/0` — lowercase-ASCII-letters identifier for protocol headers (spec `1*LOWERALPHA`)
    2. `verify/2` — verify a credential payload against a charge intent
    3. `challenge_method_details/1` — (optional) add method-specific fields to challenges

  ## Usage

      defmodule MyApp.Payments.Stripe do
        use MPP.Method

        @impl MPP.Method
        def method_name, do: "stripe"

        @impl MPP.Method
        def verify(payload, charge) do
          # payload is the credential's method-specific proof map
          # charge is the validated MPP.Intents.Charge struct
          spt = Map.fetch!(payload, "spt")
          # ... verify with Stripe API ...
          {:ok, MPP.Receipt.new(method: "stripe", reference: "pi_abc123")}
        end

        @impl MPP.Method
        def challenge_method_details(_charge) do
          %{"networkId" => "...", "paymentMethodTypes" => ["card"]}
        end
      end

  ## Design

  **Intent = Schema, Method = Implementation.** All methods share the same
  `MPP.Intents.Charge` struct — methods only handle verification. The `payload`
  argument is the raw map from the credential (method-specific proof), not the
  full `MPP.Credential` struct. Methods don't need to know about protocol framing.
  """

  alias MPP.Intents.Charge

  @doc """
  Returns the lowercase payment method name (e.g., `"stripe"`, `"tempo"`).

  Used in the challenge `method` field and the receipt `method` field.
  Must be a stable identifier of lowercase ASCII letters only — the spec ABNF
  is `payment-method-id = 1*LOWERALPHA`, so digits, dashes, underscores, and
  colons are rejected by challenge parsing (`:invalid_method`) and by
  `MPP.Plug.init/1` at boot.
  """
  @callback method_name() :: String.t()

  @doc """
  Verifies a payment credential payload against a charge intent.

  ## Arguments

    * `payload` — method-specific proof map from the credential
      (e.g., `%{"spt" => "spt_..."}` for Stripe)
    * `charge` — the `MPP.Intents.Charge` struct from the challenge,
      containing amount, currency, recipient, etc.

  ## Returns

    * `{:ok, MPP.Receipt.t()}` — payment verified successfully
    * `{:error, MPP.Errors.t()}` — verification failed with a typed RFC 9457 error
  """
  @callback verify(payload :: map(), charge :: Charge.t()) ::
              {:ok, MPP.Receipt.t()} | {:error, MPP.Errors.t()}

  @doc """
  Returns method-specific fields to include in the challenge request.

  Called when generating a 402 challenge. The returned map is merged into
  `charge.method_details` so the client knows method-specific requirements
  (e.g., Stripe's `networkId` and `paymentMethodTypes`).

  The default implementation returns `nil` (no extra fields).
  """
  @callback challenge_method_details(charge :: Charge.t()) :: map() | nil

  @doc """
  Validates method_config at init time. Raises on missing required keys.

  Called during `MPP.Plug` init for each method entry. Use this to
  fail fast on misconfiguration (e.g., missing Stripe secret key or
  network ID) rather than discovering it at request time.

  The default implementation is a no-op (all configs accepted).
  """
  @callback validate_config!(config :: map()) :: :ok

  @optional_callbacks [challenge_method_details: 1, validate_config!: 1]

  @doc false
  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      @behaviour MPP.Method

      @spec challenge_method_details(MPP.Intents.Charge.t()) :: map() | nil
      @impl MPP.Method
      def challenge_method_details(_charge), do: nil

      @spec validate_config!(map()) :: :ok
      @impl MPP.Method
      def validate_config!(_config), do: :ok

      defoverridable challenge_method_details: 1, validate_config!: 1
    end
  end
end
