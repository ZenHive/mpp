defmodule MPP.AcceptPaymentTest do
  use ExUnit.Case, async: true

  alias MPP.AcceptPayment
  alias MPP.Challenge

  # Token-size DoS cap (mpp-rs #299) mirrored from MPP.AcceptPayment's @max_token_len.
  @max_token_len 16 * 1024

  defp accept_payment_offer(method, intent),
    do: %Challenge{method: method, intent: intent, id: method, realm: "api.example.com", request: "e30"}

  describe "parse/1" do
    test "parses single and multiple entries with default q=1.0" do
      assert [{"tempo", "charge", 1.0}] = AcceptPayment.parse("tempo/charge")

      assert [{"tempo", "charge", 1.0}, {"stripe", "charge", 0.5}] =
               AcceptPayment.parse("tempo/charge, stripe/charge;q=0.5")
    end

    test "parses wildcards and q=0" do
      assert AcceptPayment.parse("tempo/*, */session;q=0") == [
               {"tempo", "*", 1.0},
               {"*", "session", 0.0}
             ]
    end

    test "parses boundary q-values and duplicate q (last wins)" do
      assert AcceptPayment.parse("a/b;q=0, c/d;q=1, e/f;q=0.001") == [
               {"a", "b", 0.0},
               {"c", "d", 1.0},
               {"e", "f", 0.001}
             ]

      assert [{"tempo", "charge", 0.8}] =
               AcceptPayment.parse("tempo/charge;q=0.5;q=0.8")
    end

    test "tolerates spaces around q equals" do
      assert [{"tempo", "charge", 0.5}] = AcceptPayment.parse("tempo/charge;q = 0.5")
      assert [{"tempo", "charge", 0.5}] = AcceptPayment.parse("tempo/charge; q=0.5")
    end

    test "returns empty list for malformed input" do
      assert AcceptPayment.parse("") == []
      assert AcceptPayment.parse("   ") == []
      assert AcceptPayment.parse("tempo") == []
      assert AcceptPayment.parse("Tempo/charge") == []
      assert AcceptPayment.parse("tempo/charge;q=1.5") == []
      assert AcceptPayment.parse("tempo/charge;q=-0.1") == []
      assert AcceptPayment.parse("tempo/charge;q=0.1234") == []
    end
  end

  describe "Accept-Payment header size cap (DoS, mpp-rs #299)" do
    test "parse ignores an oversized header" do
      oversized = String.duplicate("tempo/charge,", 1300)
      assert byte_size(oversized) > @max_token_len
      assert AcceptPayment.parse(oversized) == []
    end

    test "apply_header is a no-op for an oversized header (server offers unchanged)" do
      offers = [{"tempo", "charge"}, {"stripe", "charge"}]
      method_intent = fn offer -> offer end

      # Valid content that WOULD rank stripe first if parsed — proves the cap
      # short-circuits before ranking, not merely that malformed input is ignored.
      oversized = String.duplicate("stripe/charge,", 1300)
      assert byte_size(oversized) > @max_token_len
      assert AcceptPayment.apply_header(offers, oversized, method_intent) == offers
    end

    test "a large but sub-limit valid header still parses (guard is not over-eager)" do
      valid = String.duplicate("tempo/charge,", 1000) <> "tempo/charge"
      assert byte_size(valid) < @max_token_len

      parsed = AcceptPayment.parse(valid)
      refute parsed == []
      assert hd(parsed) == {"tempo", "charge", 1.0}
    end

    test "an exactly-at-limit header still parses (cap is exclusive)" do
      # "tempo/charge" is 12 bytes; pad with trailing spaces (trimmed by the
      # part parser) to hit byte_size == @max_token_len exactly.
      at_limit = "tempo/charge" <> String.duplicate(" ", @max_token_len - 12)
      assert byte_size(at_limit) == @max_token_len

      assert AcceptPayment.parse(at_limit) == [{"tempo", "charge", 1.0}]
    end
  end

  describe "format/1" do
    test "formats entries and round-trips" do
      header = "tempo/charge, stripe/charge;q=0.5, */session;q=0"
      entries = AcceptPayment.parse(header)
      assert AcceptPayment.format(entries) == header
    end

    test "omits q=1 and strips trailing zeros" do
      assert AcceptPayment.format([{"tempo", "charge", 1.0}]) == "tempo/charge"
      assert AcceptPayment.format([{"a", "b", 0.1}]) == "a/b;q=0.1"
    end
  end

  describe "rank/2" do
    test "orders by q and excludes q=0" do
      offers = [accept_payment_offer("stripe", "charge"), accept_payment_offer("tempo", "charge")]
      prefs = AcceptPayment.parse("tempo/charge, stripe/charge;q=0.5")

      assert [%{method: "tempo"}, %{method: "stripe"}] =
               AcceptPayment.rank(offers, prefs)

      prefs = AcceptPayment.parse("tempo/charge;q=0, stripe/charge")
      assert [%{method: "stripe"}] = AcceptPayment.rank(offers, prefs)
    end

    test "wildcard specificity beats lower q" do
      offers = [accept_payment_offer("stripe", "charge"), accept_payment_offer("tempo", "charge")]
      prefs = AcceptPayment.parse("*/charge;q=0.3, stripe/charge;q=0.8")

      assert [%{method: "stripe"}, %{method: "tempo"}] =
               AcceptPayment.rank(offers, prefs)
    end

    test "tempo/* at q=1 but tempo/charge;q=0 excludes charge intent" do
      offers = [accept_payment_offer("tempo", "charge"), accept_payment_offer("tempo", "session")]
      prefs = AcceptPayment.parse("tempo/*;q=1, tempo/charge;q=0")

      assert [%{method: "tempo", intent: "session"}] =
               AcceptPayment.rank(offers, prefs)
    end

    test "preserves offer order on tie and returns empty when no match" do
      offers = [accept_payment_offer("a", "charge"), accept_payment_offer("b", "charge")]
      prefs = AcceptPayment.parse("*/charge")

      assert [%{method: "a"}, %{method: "b"}] = AcceptPayment.rank(offers, prefs)

      no_match_prefs = AcceptPayment.parse("tempo/charge")
      assert AcceptPayment.rank([accept_payment_offer("lightning", "charge")], no_match_prefs) == []
      assert AcceptPayment.rank(offers, []) == []
    end
  end
end
