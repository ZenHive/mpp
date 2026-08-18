defmodule MPP.TelemetryTest do
  use ExUnit.Case, async: false

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Telemetry
  alias MPP.Tempo.ConCacheStore
  alias MPP.Test.TelemetryCollector
  alias MPP.Verifier

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(%{"proof" => "valid"}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    @impl MPP.Method
    def verify(%{"proof" => "invalid"}, _charge) do
      {:error, Errors.new(:verification_failed, "Invalid proof")}
    end

    @impl MPP.Method
    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof field")}
    end
  end

  defmodule MockMethodAtomError do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(_payload, _charge), do: {:error, :some_unknown_reason}
  end

  @secret_key "telemetry-test-secret"
  @realm "api.telemetry.test"

  setup do
    # Supervised rather than `start_link` + a manual stop in `on_exit`: the agent
    # is linked to the test process, so by the time `on_exit` runs it is already
    # dying, and `Process.whereis` could still return a pid whose name had not been
    # unregistered yet — `GenServer.stop` then exited `:noproc` and failed the test.
    start_supervised!(%{id: TelemetryCollector, start: {TelemetryCollector, :start_link, [[]]}})
    :ok = TelemetryCollector.attach()

    on_exit(fn -> TelemetryCollector.detach() end)

    :ok
  end

  defp build_charge(overrides \\ []) do
    {:ok, charge} = Charge.new(Keyword.merge([amount: "1000", currency: "usd"], overrides))
    charge
  end

  defp encode_request(charge) do
    charge
    |> Charge.to_request()
    |> JCS.canonicalize()
    |> Base.url_encode64(padding: false)
  end

  defp future_expires do
    DateTime.utc_now()
    |> DateTime.shift(minute: 5)
    |> DateTime.to_iso8601()
  end

  defp build_credential(opts \\ []) do
    charge = Keyword.get(opts, :charge, build_charge())
    payload = Keyword.get(opts, :payload, %{"proof" => "valid"})

    params = [
      realm: Keyword.get(opts, :realm, @realm),
      method: Keyword.get(opts, :method_name, "mock"),
      intent: "charge",
      request: encode_request(charge),
      expires: Keyword.get(opts, :expires, future_expires())
    ]

    challenge = Challenge.create(params, Keyword.get(opts, :secret_key, @secret_key))
    %Credential{challenge: challenge, payload: payload, source: "did:example:payer"}
  end

  defp verify_opts(overrides \\ []) do
    Keyword.merge(
      [secret_key: @secret_key, realm: @realm, method: MockMethod, charge: build_charge()],
      overrides
    )
  end

  defp plug_config(overrides \\ []) do
    PaymentPlug.init(
      Keyword.merge(
        [
          secret_key: @secret_key,
          realm: @realm,
          method: MockMethod,
          amount: "1000",
          currency: "usd"
        ],
        overrides
      )
    )
  end

  defp assert_event_counts(expected) do
    counts = TelemetryCollector.counts()

    for {event, expected_count} <- expected do
      assert counts[event] == expected_count,
             "expected #{inspect(event)} to fire #{expected_count} time(s), got #{counts[event]}"
    end
  end

  defp refute_sensitive_metadata(event) do
    for {_event, _measurements, metadata} <- TelemetryCollector.metadata_for(event) do
      refute Map.has_key?(metadata, :payload)
      refute Map.has_key?(metadata, :credential)
      refute Map.has_key?(metadata, "payload")
      refute Map.has_key?(metadata, "credential")

      encoded = Jason.encode!(metadata)
      refute String.contains?(encoded, "proof")
      refute String.contains?(encoded, @secret_key)
    end
  end

  describe "verifier happy path telemetry" do
    test "emits verify-start, verify-ok, and receipt exactly once" do
      credential = build_credential()

      assert {:ok, %Receipt{}} = Verifier.verify(credential, verify_opts())

      assert_event_counts([
        {[:mpp, :challenge], 0},
        {[:mpp, :verify, :start], 1},
        {[:mpp, :verify, :ok], 1},
        {[:mpp, :verify, :fail], 0},
        {[:mpp, :receipt], 1}
      ])

      refute_sensitive_metadata([:mpp, :verify, :start])
      refute_sensitive_metadata([:mpp, :verify, :ok])
      refute_sensitive_metadata([:mpp, :receipt])

      [{_event, measurements, metadata}] = TelemetryCollector.metadata_for([:mpp, :verify, :ok])
      assert is_integer(measurements[:duration])
      assert metadata[:challenge_id]
      assert metadata[:method] == "mock"
      assert metadata[:amount] == "1000"
      assert metadata[:payer_source] == "did:example:payer"
    end
  end

  describe "verifier sad path telemetry" do
    test "emits verify-start and verify-fail exactly once" do
      credential = build_credential(payload: %{"proof" => "invalid"})

      assert {:error, %Errors{}} = Verifier.verify(credential, verify_opts())

      assert_event_counts([
        {[:mpp, :challenge], 0},
        {[:mpp, :verify, :start], 1},
        {[:mpp, :verify, :ok], 0},
        {[:mpp, :verify, :fail], 1},
        {[:mpp, :receipt], 0}
      ])

      refute_sensitive_metadata([:mpp, :verify, :fail])

      [{_event, measurements, metadata}] = TelemetryCollector.metadata_for([:mpp, :verify, :fail])
      assert is_integer(measurements[:duration])
      assert metadata[:error_type] =~ "verification-failed"
    end
  end

  describe "plug happy path telemetry" do
    test "emits verify-start, verify-ok, and receipt exactly once" do
      config = plug_config()
      auth_header = build_plug_auth_header(config)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> PaymentPlug.call(config)

      refute conn.halted

      assert_event_counts([
        {[:mpp, :challenge], 0},
        {[:mpp, :verify, :start], 1},
        {[:mpp, :verify, :ok], 1},
        {[:mpp, :verify, :fail], 0},
        {[:mpp, :receipt], 1}
      ])
    end
  end

  describe "plug sad path telemetry" do
    test "emits verify-start, verify-fail, and challenge exactly once" do
      config = plug_config()
      entry = hd(config.method_entries)

      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: "mock",
            intent: "charge",
            request: entry.request,
            expires: future_expires()
          ],
          "wrong-secret"
        )

      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      auth_header = Headers.format_credential(credential)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> PaymentPlug.call(config)

      assert conn.status == 402

      assert_event_counts([
        {[:mpp, :challenge], 1},
        {[:mpp, :verify, :start], 1},
        {[:mpp, :verify, :ok], 0},
        {[:mpp, :verify, :fail], 1},
        {[:mpp, :receipt], 0}
      ])

      refute_sensitive_metadata([:mpp, :challenge])
    end

    test "no credential emits challenge only" do
      config = plug_config()

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> PaymentPlug.call(config)

      assert conn.status == 402

      assert_event_counts([
        {[:mpp, :challenge], 1},
        {[:mpp, :verify, :start], 0},
        {[:mpp, :verify, :ok], 0},
        {[:mpp, :verify, :fail], 0},
        {[:mpp, :receipt], 0}
      ])
    end
  end

  describe "charge_from_challenge/1" do
    test "decodes amount and currency from challenge request" do
      charge = build_charge(amount: "2500", currency: "eur")
      credential = build_credential(charge: charge)

      assert %Charge{amount: "2500", currency: "eur"} =
               Telemetry.charge_from_challenge(credential.challenge)
    end

    test "returns nil for malformed request blobs" do
      challenge = %Challenge{
        id: "ch-bad",
        realm: @realm,
        method: "mock",
        intent: "charge",
        request: "not-valid-base64url"
      }

      assert Telemetry.charge_from_challenge(challenge) == nil
    end
  end

  describe "telemetry helpers" do
    test "event_names lists all lifecycle events" do
      assert Telemetry.event_names() == [
               [:mpp, :challenge],
               [:mpp, :verify, :start],
               [:mpp, :verify, :ok],
               [:mpp, :verify, :fail],
               [:mpp, :receipt]
             ]
    end

    test "challenge and receipt helpers accept default charge and extra args" do
      credential = build_credential()
      charge = build_charge()
      receipt = Receipt.new(method: "mock", reference: "ref_direct")

      assert :ok = Telemetry.challenge(credential.challenge)
      assert :ok = Telemetry.challenge(credential.challenge, charge, %{source: :test})

      bad_challenge = %Challenge{
        id: "ch-bad",
        realm: @realm,
        method: "mock",
        intent: "charge",
        request: "not-valid-base64url"
      }

      assert :ok = Telemetry.challenge(bad_challenge)

      start_time = Telemetry.verify_start(credential)
      assert :ok = Telemetry.verify_ok(credential, charge, start_time)
      assert :ok = Telemetry.receipt(credential, receipt)
      assert :ok = Telemetry.receipt(credential, receipt, charge, %{tag: :direct})
    end

    test "verify_fail records atom error reasons" do
      credential = build_credential()

      start_time = Telemetry.verify_start(credential, build_charge())
      assert :ok = Telemetry.verify_fail(credential, build_charge(), start_time, :some_unknown_reason)

      [{_event, _measurements, metadata}] = TelemetryCollector.metadata_for([:mpp, :verify, :fail])
      assert metadata[:error_reason] == :some_unknown_reason
    end
  end

  describe "verifier atom error telemetry" do
    test "maps unexpected method errors to verify-fail metadata" do
      credential = build_credential()

      assert {:error, %Errors{}} =
               Verifier.verify(credential, verify_opts(method: MockMethodAtomError))

      [{_event, _measurements, metadata}] = TelemetryCollector.metadata_for([:mpp, :verify, :fail])
      assert metadata[:error_type] =~ "verification-failed"
    end
  end

  describe "plug method unsupported telemetry" do
    test "emits verify-start and verify-fail without verifier" do
      config = plug_config()
      entry = hd(config.method_entries)

      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: "unknownmethod",
            intent: "charge",
            request: entry.request,
            expires: future_expires()
          ],
          config.secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      auth_header = Headers.format_credential(credential)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> PaymentPlug.call(config)

      assert conn.status == 400

      assert_event_counts([
        {[:mpp, :challenge], 0},
        {[:mpp, :verify, :start], 1},
        {[:mpp, :verify, :fail], 1}
      ])
    end
  end

  describe "plug replay dedup telemetry" do
    test "emits verify-start and verify-fail before verifier on replay" do
      cache_name = :"telemetry_replay_#{System.unique_integer([:positive])}"
      start_supervised!({ConCacheStore, name: cache_name})
      config = plug_config(store: {ConCacheStore, name: cache_name})
      auth_header = build_plug_auth_header(config)

      first_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> PaymentPlug.call(config)

      refute first_conn.halted

      second_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> PaymentPlug.call(config)

      assert second_conn.status == 402

      assert TelemetryCollector.count([:mpp, :verify, :start]) == 2
      assert TelemetryCollector.count([:mpp, :verify, :fail]) == 1
      assert TelemetryCollector.count([:mpp, :verify, :ok]) == 1
    end
  end

  defp build_plug_auth_header(config) do
    entry = hd(config.method_entries)

    challenge =
      Challenge.create(
        [
          realm: config.realm,
          method: entry.method.method_name(),
          intent: "charge",
          request: entry.request,
          expires: future_expires()
        ],
        config.secret_key
      )

    credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
    Headers.format_credential(credential)
  end
end
