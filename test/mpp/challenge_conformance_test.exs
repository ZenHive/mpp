defmodule MPP.ChallengeConformanceTest do
  @moduledoc """
  Cross-SDK conformance: pins `MPP.Challenge.create/2`'s HMAC-SHA256 challenge ID
  against the shared canonical golden vectors from both reference SDKs.

  Cross-implementation evidence: `refs/mppx/src/Challenge.test.ts:84-280` and
  `refs/mpp-rs/src/protocol/core/challenge.rs:1318-1800` independently pin the
  same vectors. Provider authority is
  `refs/mpp-specs/specs/core/draft-httpauth-payment-00.md:309-360`. Secret is
  `"test-vector-secret"` throughout.

  These tests guard the wire-format invariant CLAUDE.md calls out: a wrong HMAC
  input layout, JCS canonicalization, or base64url handling on our side would let
  `challenge_test.exs` (which only checks determinism + tamper-rejection against our
  *own* inputs) stay green while diverging from every other SDK. A red here is a real
  divergence — fix `MPP.Challenge` / `MPP.JCS` to match the reference, never the
  pinned expected value.

  The `request` and `opaque` slots are raw base64url strings. The reference's vectors
  use compact, already key-sorted JSON, so base64url'ing the exact literal here
  reproduces the reference's `request.raw()` / `opaque.raw()` bytes (JCS over
  already-sorted compact JSON is the identity).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.Challenge

  @secret "test-vector-secret"
  @property_runs 50

  defp b64(json), do: Base.url_encode64(json, padding: false)

  describe "HMAC challenge-ID golden vectors (refs/mpp-rs test_golden_vectors)" do
    # {label, realm, method, intent, raw_request_json, expires|nil, digest|nil, expected_id}
    @base_vectors [
      {"required fields only", "api.example.com", "tempo", "charge", ~S({"amount":"1000000"}), nil, nil,
       "X6v1eo7fJ76gAxqY0xN9Jd__4lUyDDYmriryOM-5FO4"},
      {"with expires", "api.example.com", "tempo", "charge", ~S({"amount":"1000000"}), "2025-01-06T12:00:00Z", nil,
       "ChPX33RkKSZoSUyZcu8ai4hhkvjZJFkZVnvWs5s0iXI"},
      {"with digest", "api.example.com", "tempo", "charge", ~S({"amount":"1000000"}), nil,
       "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE", "JHB7EFsPVb-xsYCo8LHcOzeX1gfXWVoUSzQsZhKAfKM"},
      {"with expires and digest", "api.example.com", "tempo", "charge", ~S({"amount":"1000000"}), "2025-01-06T12:00:00Z",
       "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE", "m39jbWWCIfmfJZSwCfvKFFtBl0Qwf9X4nOmDb21peLA"},
      {"multi-field request", "api.example.com", "tempo", "charge",
       ~S({"amount":"1000000","currency":"0x1234","recipient":"0xabcd"}), nil, nil,
       "_H5TOnnlW0zduQ5OhQ3EyLVze_TqxLDPda2CGZPZxOc"},
      {"nested methodDetails", "api.example.com", "tempo", "charge",
       ~S({"amount":"1000000","currency":"0x1234","methodDetails":{"chainId":42431}}), nil, nil,
       "TqujwpuDDg_zsWGINAd5XObO2rRe6uYufpqvtDmr6N8"},
      {"empty request", "api.example.com", "tempo", "charge", ~S({}), nil, nil,
       "yLN7yChAejW9WNmb54HpJIWpdb1WWXeA3_aCx4dxmkU"},
      {"different realm", "payments.other.com", "tempo", "charge", ~S({"amount":"1000000"}), nil, nil,
       "3F5bOo2a9RUihdwKk4hGRvBvzQmVPBMDvW0YM-8GD00"},
      {"different method", "api.example.com", "stripe", "charge", ~S({"amount":"1000000"}), nil, nil,
       "o0ra2sd7HcB4Ph0Vns69gRDUhSj5WNOnUopcDqKPLz4"},
      {"different intent", "api.example.com", "tempo", "session", ~S({"amount":"1000000"}), nil, nil,
       "aAY7_IEDzsznNYplhOSE8cERQxvjFcT4Lcn-7FHjLVE"}
    ]

    for {label, realm, method, intent, request_json, expires, digest, expected} <- @base_vectors do
      test "#{label}" do
        params =
          [
            realm: unquote(realm),
            method: unquote(method),
            intent: unquote(intent),
            request: b64(unquote(request_json))
          ]
          |> maybe_put(:expires, unquote(expires))
          |> maybe_put(:digest, unquote(digest))

        challenge = Challenge.create(params, @secret)

        assert challenge.id == unquote(expected),
               "challenge-ID divergence from mpp-rs golden vector #{unquote(label)}"
      end
    end
  end

  describe "HMAC challenge-ID opaque golden vectors (refs/mpp-rs test_opaque_golden_vectors)" do
    @request ~S({"amount":"1000000"})

    # {label, raw_opaque_json, expires|nil, expected_id}
    @opaque_vectors [
      {"with opaque", ~S({"pi":"pi_3abc123XYZ"}), nil, "rxzKZ2qjXvinqCH96RORTZEPs1KXsA-0AUjrCAPFOWc"},
      {"with opaque and expires", ~S({"pi":"pi_3abc123XYZ"}), "2025-01-06T12:00:00Z",
       "KAfoMrA4fnzS1DPWN_cUv_b3_yHxCizdp6OhH7gluMY"},
      {"with empty opaque", ~S({}), nil, "vb4IyH-0LdJ3s7L0QAw8jIzcZkyxksPhIvEfmHmzA9k"},
      # JCS sorts keys: deposit < pi
      {"with multi-key opaque", ~S({"deposit":"dep_456","pi":"pi_3abc123XYZ"}), nil,
       "aKskU8sadR5ZuFbUCsIwhO-ENxuVpTw17FdwHEXsJDk"}
    ]

    for {label, opaque_json, expires, expected} <- @opaque_vectors do
      test "#{label}" do
        params =
          maybe_put(
            [
              realm: "api.example.com",
              method: "tempo",
              intent: "charge",
              request: b64(@request),
              opaque: b64(unquote(opaque_json))
            ],
            :expires,
            unquote(expires)
          )

        challenge = Challenge.create(params, @secret)

        assert challenge.id == unquote(expected),
               "opaque challenge-ID divergence from mpp-rs golden vector #{unquote(label)}"
      end
    end
  end

  describe "property: all seven HMAC slots are binding domains" do
    property "changing any generated slot changes the challenge ID" do
      check all(
              slot <- StreamData.member_of([:realm, :method, :intent, :request, :expires, :digest, :opaque]),
              suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
              max_runs: @property_runs
            ) do
        base = [
          realm: "api.example.com",
          method: "tempo",
          intent: "charge",
          request: b64(~S({"amount":"1000000"})),
          expires: "2030-01-01T00:00:00Z",
          digest: "sha-256=:base:",
          opaque: b64(~S({"route":"base"}))
        ]

        changed = Keyword.update!(base, slot, &mutate_slot(slot, &1, suffix))

        refute Challenge.create(base, @secret).id == Challenge.create(changed, @secret).id
      end
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp mutate_slot(:request, value, suffix), do: b64(~s({"value":"#{value <> suffix}"}))
  defp mutate_slot(:opaque, value, suffix), do: b64(~s({"value":"#{value <> suffix}"}))
  defp mutate_slot(_slot, value, suffix), do: value <> suffix
end
