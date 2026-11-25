defmodule MPP.Challenge.MetaTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Challenge.Meta

  defp b64(json), do: Base.url_encode64(json, padding: false)
  defp decode!(opaque), do: opaque |> Base.url_decode64!(padding: false) |> Jason.decode!()

  describe "with_nonce/1" do
    test "adds 16 random bytes as unpadded base64url under _mpp_nonce" do
      assert %{"_mpp_nonce" => nonce} = members = decode!(Meta.with_nonce(nil))
      assert map_size(members) == 1
      assert nonce =~ ~r/\A[A-Za-z0-9_-]{22}\z/
      assert byte_size(Base.url_decode64!(nonce, padding: false)) == 16
    end

    test "keeps the opaque's own members and writes canonical JSON" do
      opaque = Meta.with_nonce(b64(~S({"pi":"pi_1","deposit":"dep_2"})))
      assert %{"pi" => "pi_1", "deposit" => "dep_2", "_mpp_nonce" => nonce} = decode!(opaque)

      assert Base.url_decode64!(opaque, padding: false) ==
               ~s({"_mpp_nonce":"#{nonce}","deposit":"dep_2","pi":"pi_1"})
    end

    test "draws a different nonce on every call" do
      nonces = for _ <- 1..200, do: decode!(Meta.with_nonce(nil))["_mpp_nonce"]
      assert MapSet.size(MapSet.new(nonces)) == 200
    end

    test "returns an opaque with nowhere to carry a nonce as given" do
      opaques = [b64(~S(["a"])), b64(~S("text")), b64("not json"), "not base64!", b64(~S({"a":"1","a":"2"}))]

      for opaque <- opaques do
        assert Meta.with_nonce(opaque) == opaque
        refute Meta.nonce?(opaque)
      end
    end

    # refs/mpp-rs/src/server/mpp/tests/core_spec.rs: a route opaque holding `0.5` still
    # gets a nonce.
    test "adds a nonce beside a float and beside a non-ASCII member name" do
      assert %{"rate" => 0.5, "_mpp_nonce" => _} = decode!(Meta.with_nonce(b64(~S({"rate":0.5}))))
      assert %{"ключ" => "v", "_mpp_nonce" => _} = decode!(Meta.with_nonce(b64(~S({"ключ":"v"}))))
    end

    test "reads an opaque in standard base64 with padding" do
      opaque = Base.encode64(~S({"note":"a?b>c"}))
      assert opaque =~ ~r/[+\/=]/
      assert %{"note" => "a?b>c", "_mpp_nonce" => _} = decode!(Meta.with_nonce(opaque))
    end
  end

  describe "nonce?/1" do
    test "is true for _mpp_nonce and for the earlier _mppx_nonce" do
      assert Meta.nonce?(Meta.with_nonce(nil))
      assert Meta.nonce?(b64(~S({"_mppx_nonce":"legacy"})))
    end

    test "is false without a string nonce member" do
      opaques = [nil, b64(~S({"order":"one"})), b64(~S({"_mpp_nonce":1})), b64(~S(["_mpp_nonce"])), "not base64!"]

      for opaque <- opaques do
        refute Meta.nonce?(opaque)
      end
    end
  end

  describe "route_form/1" do
    test "ignores both nonce keys and the member order" do
      plain = b64(~S({"order":"one","route":"a"}))
      assert Meta.route_form(Meta.with_nonce(plain)) == Meta.route_form(plain)
      assert Meta.route_form(b64(~S({"route":"a","_mppx_nonce":"x","order":"one"}))) == Meta.route_form(plain)
    end

    test "an object holding only a nonce counts as no opaque" do
      assert Meta.route_form(Meta.with_nonce(nil)) == nil
      assert Meta.route_form(b64("{}")) == nil
      assert Meta.route_form(nil) == nil
    end

    test "keeps other members apart" do
      refute Meta.route_form(b64(~S({"route":"a"}))) == Meta.route_form(b64(~S({"route":"b"})))
      refute Meta.route_form(b64(~S({"route":"a"}))) == Meta.route_form(nil)
    end

    test "matches a non-object as its JSON value and non-JSON as raw text" do
      assert Meta.route_form(b64(~S(["a"]))) == {:json, ["a"]}
      assert Meta.route_form("not base64!") == {:raw, "not base64!"}
    end

    test "ignores the issuance-only markers of the reference SDKs" do
      plain = b64(~S({"route":"a"}))

      for key <- ["_mppx_identity", "_mppx_expiry_grace"] do
        assert Meta.route_form(b64(~s({"route":"a","#{key}":"1"}))) == Meta.route_form(plain)
      end
    end

    test "matches a document that repeats a member name as text" do
      repeated = b64(~S({"route":"a","route":"b"}))
      assert Meta.route_form(repeated) == {:raw, repeated}
      assert Meta.route_form(b64(~S({"outer":{"k":"1","k":"2"}}))) == {:raw, b64(~S({"outer":{"k":"1","k":"2"}}))}
    end
  end

  describe "same_route?/2" do
    test "holds for one route with and without its nonce" do
      plain = b64(~S({"order":"one"}))
      assert Meta.same_route?(Meta.with_nonce(plain), plain)
      assert Meta.same_route?(Meta.with_nonce(nil), nil)
    end

    test "keeps 1 and 1.0 apart, also when nested" do
      refute Meta.same_route?(b64(~S({"n":1})), b64(~S({"n":1.0})))
      refute Meta.same_route?(b64(~S({"n":[1]})), b64(~S({"n":[1.0]})))
      refute Meta.same_route?(b64(~S([1])), b64(~S([1.0])))
    end

    test "keeps a repeated member name apart from either single reading" do
      repeated = b64(~S({"route":"a","route":"b"}))
      refute Meta.same_route?(repeated, b64(~S({"route":"a"})))
      refute Meta.same_route?(repeated, b64(~S({"route":"b"})))
      assert Meta.same_route?(repeated, repeated)
    end
  end

  describe "with_scope!/2" do
    test "returns the opaque unchanged without a scope" do
      assert Meta.with_scope!(nil, nil) == nil
      assert Meta.with_scope!("eyJhIjoiYiJ9", nil) == "eyJhIjoiYiJ9"
    end

    test "adds _mppx_scope beside the opaque's members" do
      assert decode!(Meta.with_scope!(nil, "GET /premium")) == %{"_mppx_scope" => "GET /premium"}

      assert decode!(Meta.with_scope!(b64(~S({"order":"one"})), "GET /premium")) ==
               %{"order" => "one", "_mppx_scope" => "GET /premium"}
    end

    test "accepts an opaque that already names the same scope" do
      opaque = b64(~S({"_mppx_scope":"GET /premium"}))
      assert decode!(Meta.with_scope!(opaque, "GET /premium")) == %{"_mppx_scope" => "GET /premium"}
    end

    test "raises on a conflicting scope, an opaque without members, and a non-string scope" do
      assert_raise ArgumentError, ~r/conflicts/, fn ->
        Meta.with_scope!(b64(~S({"_mppx_scope":"GET /other"})), "GET /premium")
      end

      assert_raise ArgumentError, ~r/JSON object/, fn -> Meta.with_scope!(b64(~S(["a"])), "GET /premium") end
      assert_raise ArgumentError, ~r/non-empty string/, fn -> Meta.with_scope!(nil, "") end
      assert_raise ArgumentError, ~r/non-empty string/, fn -> Meta.with_scope!(nil, :premium) end
    end
  end

  describe "validate_configured!/1" do
    test "rejects a configured opaque that sets a member reserved for issued challenges" do
      for key <- ["_mpp_nonce", "_mppx_nonce", "_mppx_identity", "_mppx_expiry_grace"] do
        assert_raise ArgumentError, ~r/must not set #{key}/, fn ->
          Meta.validate_configured!(b64(~s({"#{key}":"fixed"})))
        end
      end
    end

    test "accepts any other opaque" do
      for opaque <- [nil, b64(~S({"order":"one"})), b64(~S(["a"])), "not base64!"] do
        assert Meta.validate_configured!(opaque) == :ok
      end
    end
  end

  describe "Challenge.create/2 with nonce: true" do
    @params [realm: "api.example.com", method: "tempo", intent: "charge", request: "eyJhbW91bnQiOiIxIn0"]

    test "issues a different id for identical parameters and binds the nonce into the id" do
      first = Challenge.create([nonce: true] ++ @params, "secret-padded-to-32-bytes-xxxxxxxxxxxxxxxx")
      second = Challenge.create([nonce: true] ++ @params, "secret-padded-to-32-bytes-xxxxxxxxxxxxxxxx")

      assert Meta.nonce?(first.opaque)
      refute first.id == second.id
      assert Challenge.verify(first, "secret-padded-to-32-bytes-xxxxxxxxxxxxxxxx") == :ok

      assert Challenge.verify(%{first | opaque: second.opaque}, "secret-padded-to-32-bytes-xxxxxxxxxxxxxxxx") ==
               {:error, :invalid_challenge}
    end

    test "leaves the challenge as before without the option" do
      challenge = Challenge.create(@params, "secret-padded-to-32-bytes-xxxxxxxxxxxxxxxx")
      assert challenge.opaque == nil
      assert challenge.id == Challenge.create(@params, "secret-padded-to-32-bytes-xxxxxxxxxxxxxxxx").id
    end
  end
end
