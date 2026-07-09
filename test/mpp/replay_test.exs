defmodule MPP.ReplayTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Replay
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  defmodule TempoMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "tempo"

    @impl MPP.Method
    def verify(_payload, _charge), do: {:ok, nil}
  end

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(_payload, _charge), do: {:ok, nil}
  end

  # Store whose get/check_and_mark both return an unexpected error, to exercise
  # the `{:error, _}` -> "Dedup store error" branches.
  defmodule ErroringStore do
    @moduledoc false
    @behaviour Store

    @impl Store
    def get(_key), do: {:error, :boom}

    @impl Store
    def put(_key, _value), do: {:error, :boom}

    @impl Store
    def check_and_mark(_key, _value), do: {:error, :boom}
  end

  @credential %Credential{
    challenge: %Challenge{id: "ch_replay_1", realm: "api.example.com", method: "mock", intent: "charge", request: "e30"},
    payload: %{"proof" => "valid"}
  }

  describe "store_for/2" do
    test "returns nil when the config store is disabled" do
      assert Replay.store_for(%{store: nil}, %{method: MockMethod}) == nil
    end

    test "returns the configured store for a non-tempo method" do
      assert Replay.store_for(%{store: ConCacheStore}, %{method: MockMethod}) == ConCacheStore
    end

    test "carves out tempo (method self-manages dedup)" do
      assert Replay.store_for(%{store: ConCacheStore}, %{method: TempoMethod}) == nil
    end
  end

  describe "check_unused/2 and mark_used/2 with a live store" do
    setup do
      name = :"replay_unit_#{System.unique_integer([:positive])}"
      start_supervised!({ConCacheStore, name: name})
      %{store: {ConCacheStore, name: name}}
    end

    test "a nil store is always :ok (dedup disabled)" do
      assert Replay.check_unused(nil, @credential) == :ok
      assert Replay.mark_used(nil, @credential) == :ok
    end

    test "an unseen credential passes, is claimed, then rejected on replay", %{store: store} do
      assert Replay.check_unused(store, @credential) == :ok
      assert Replay.mark_used(store, @credential) == :ok

      assert {:error, error} = Replay.check_unused(store, @credential)
      assert error.detail == "Payment credential already used"
    end

    test "mark_used rejects a double-claim of the same credential", %{store: store} do
      assert Replay.mark_used(store, @credential) == :ok
      assert {:error, error} = Replay.mark_used(store, @credential)
      assert error.detail == "Payment credential already used"
    end
  end

  describe "store error paths" do
    test "check_unused surfaces a store get error as a generic dedup error" do
      assert {:error, error} = Replay.check_unused(ErroringStore, @credential)
      assert error.detail == "Dedup store error"
    end

    test "mark_used surfaces an unexpected store error as a generic dedup error" do
      assert {:error, error} = Replay.mark_used(ErroringStore, @credential)
      assert error.detail == "Dedup store error"
    end
  end

  describe "payloads the JCS subset cannot canonicalize" do
    # A float in the attacker-supplied payload must reject the credential as
    # malformed, not leak the JCS raise. Using ErroringStore proves the key
    # failure short-circuits before any store access (a store hit would surface
    # "Dedup store error" instead).
    @float_credential %Credential{
      challenge: %Challenge{id: "ch_replay_2", realm: "api.example.com", method: "mock", intent: "charge", request: "e30"},
      payload: %{"proof" => "valid", "x" => 1.5}
    }

    test "check_unused rejects a float-bearing payload as a malformed credential" do
      assert {:error, error} = Replay.check_unused(ErroringStore, @float_credential)
      assert error.type == "https://paymentauth.org/problems/malformed-credential"
      assert error.detail == "Credential payload contains an unsupported JSON value"
    end

    test "mark_used rejects a float-bearing payload as a malformed credential" do
      assert {:error, error} = Replay.mark_used(ErroringStore, @float_credential)
      assert error.type == "https://paymentauth.org/problems/malformed-credential"
      assert error.detail == "Credential payload contains an unsupported JSON value"
    end
  end
end
