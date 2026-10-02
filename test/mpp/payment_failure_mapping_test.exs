defmodule MPP.PaymentFailureMappingTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Mcp
  alias MPP.Methods.EVM
  alias MPP.Methods.Tempo
  alias MPP.Plug, as: PaymentPlug

  defmodule FailingStore do
    @moduledoc false
    @behaviour MPP.Tempo.Store

    @impl true
    @spec get(String.t()) :: {:error, String.t()}
    def get(_key), do: {:error, "private store path"}
    @impl true
    @spec put(String.t(), term()) :: {:error, String.t()}
    def put(_key, _value), do: {:error, "private store path"}
    @impl true
    @spec check_and_mark(String.t(), term()) :: {:error, String.t()}
    def check_and_mark(_key, _value), do: {:error, "private store path"}
  end

  for method <- [EVM, Tempo], failure <- [:rpc, :store] do
    test "#{inspect(method)} #{failure} failure returns 500 without a fresh challenge" do
      method = unquote(method)

      Req.Test.stub(method, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "error" => %{"code" => -32_000, "message" => "private RPC endpoint and credentials"}
        })
      end)

      config =
        PaymentPlug.init(
          secret_key: String.duplicate("s", 32),
          realm: "api.example.com",
          method: method,
          amount: "1000000",
          currency: "0x" <> String.duplicate("11", 20),
          recipient: "0x" <> String.duplicate("22", 20),
          method_config: %{
            "rpc_url" => "https://rpc.example.com",
            "chain_id" => 1,
            "store" => unquote(if(failure == :store, do: FailingStore, else: false)),
            "req_options" => [plug: {Req.Test, method}]
          }
        )

      initial = PaymentPlug.call(Plug.Test.conn(:get, "/"), config)
      [header] = Plug.Conn.get_resp_header(initial, "www-authenticate")
      assert {:ok, challenge} = Headers.parse_challenge(header)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "hash", "hash" => "0x" <> String.duplicate("ab", 32)}
      }

      conn =
        :get
        |> Plug.Test.conn("/")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> PaymentPlug.call(config)

      assert conn.status == 500
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []

      assert %{
               "type" => "https://paymentauth.org/problems/internal-payment-error",
               "status" => 500,
               "detail" => "An internal payment error occurred."
             } = Jason.decode!(conn.resp_body)
    end
  end

  test "both parse paths reject malformed bound fields with distinct errors" do
    fields = [
      {:intent, "charge|extra", :invalid_intent},
      {:intent, "charge_now", :invalid_intent},
      {:intent, "", :invalid_intent},
      {:opaque, "a|b", :invalid_opaque},
      {:opaque, "%%%", :invalid_opaque},
      {:digest, "sha-256=", :invalid_digest},
      {:digest, "sha-256=:abc|def:", :invalid_digest},
      {:header, "Cookie", :invalid_header},
      {:header, "Authorization", :invalid_header}
    ]

    base = Challenge.create([realm: "api.example.com", method: "tempo", intent: "charge", request: "e30"], "secret")

    for {field, value, reason} <- fields do
      challenge = Map.put(base, field, value)
      params = base |> Map.from_struct() |> Map.put(field, value) |> Enum.reject(fn {_key, v} -> is_nil(v) end)
      header = "Payment " <> Enum.map_join(params, ", ", fn {key, v} -> ~s(#{key}="#{v}") end)
      assert {:error, ^reason} = Headers.parse_challenge(header)

      assert {:error, ^reason} =
               %Credential{challenge: challenge, payload: %{}} |> Credential.encode() |> Credential.decode()
    end
  end

  test "valid bound field spellings parse and problem codes stay consistent" do
    for digest <- ["sha-256=YWJj", "sha-256=:YWJj:"] do
      challenge =
        Challenge.create(
          [
            realm: "api.example.com",
            method: "tempo",
            intent: "Custom-123",
            request: "e30",
            opaque: "e30",
            digest: digest,
            header: "payment-authorization"
          ],
          "secret"
        )

      assert {:ok, ^challenge} = challenge |> Headers.format_challenge() |> Headers.parse_challenge()
    end

    for {kind, code} <- [internal_payment_error: -32_603, invalid_challenge: -32_043, payment_action_required: -32_043] do
      assert Mcp.error_code(MPP.Errors.new(kind, "detail")) == code
    end

    assert MPP.Errors.new(:credential_mismatch, "detail") == MPP.Errors.new(:invalid_challenge, "detail")
  end
end
