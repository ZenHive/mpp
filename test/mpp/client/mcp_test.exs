defmodule MPP.Client.MCPTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MCP, as: ClientMCP
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Mcp

  @secret_key "test-secret-key-for-mcp-client"
  @realm "api.example.com"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defmodule DemoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "demo" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, config) do
      if pid = config[:test_pid], do: send(pid, {:paid, challenge.method, challenge.id})

      {:ok, %Credential{challenge: challenge, payload: %{"token" => "demo-token"}, source: nil}}
    end
  end

  defmodule TempoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "tempo" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, config) do
      if pid = config[:test_pid], do: send(pid, {:paid, challenge.method})

      {:ok, %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}}
    end
  end

  defmodule StripeProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "stripe" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, config) do
      if pid = config[:test_pid], do: send(pid, {:paid, challenge.method})

      {:ok, %Credential{challenge: challenge, payload: %{"spt" => "spt_test"}, source: nil}}
    end
  end

  defmodule FailingProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(_method, _intent, _config), do: true

    @impl PaymentProvider
    def pay(_challenge, _config), do: {:error, :payment_failed}
  end

  defp make_challenge(method) do
    Challenge.create(
      [realm: @realm, method: method, intent: "charge", request: @request],
      @secret_key
    )
  end

  defp json_rpc_request(id \\ "req-1") do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "premium_lookup", "arguments" => %{"query" => "alpha"}}
    }
  end

  defp server_config(overrides \\ []) do
    [
      secret_key: @secret_key,
      realm: @realm,
      method: DemoMethod,
      amount: "1000",
      currency: "usd",
      store: false
    ]
    |> Keyword.merge(overrides)
    |> Mcp.init()
  end

  defp paid_handler do
    fn request ->
      send(self(), {:handled, request["id"]})
      %{"content" => [%{"type" => "text", "text" => "premium data"}]}
    end
  end

  defp local_server(config \\ server_config()) do
    handler = paid_handler()
    fn request -> Mcp.call(request, config, handler) end
  end

  describe "new/1" do
    test "requires a provider" do
      assert_raise ArgumentError, ~r/:provider/, fn ->
        ClientMCP.new([])
      end
    end

    test "accepts a MultiProvider, a tuple, and a bare module" do
      multi = MultiProvider.new([{DemoProvider, %{}}])

      assert %ClientMCP{} = ClientMCP.new(provider: multi)
      assert %ClientMCP{} = ClientMCP.new(provider: {DemoProvider, %{}})
      assert %ClientMCP{} = ClientMCP.new(provider: DemoProvider)
    end

    test "rejects an invalid selection policy" do
      assert_raise ArgumentError, ~r/:selection/, fn ->
        ClientMCP.new(provider: DemoProvider, selection: :newest)
      end
    end

    test "accepts :server_order, accept-payment, and function selection policies" do
      assert %ClientMCP{selection: :server_order} = ClientMCP.new(provider: DemoProvider, selection: :server_order)

      assert %ClientMCP{selection: {:accept_payment, [{"demo", "charge", 1.0}]}} =
               ClientMCP.new(provider: DemoProvider, selection: {:accept_payment, [{"demo", "charge", 1.0}]})

      fun = fn challenges -> Enum.reverse(challenges) end
      assert %ClientMCP{selection: ^fun} = ClientMCP.new(provider: DemoProvider, selection: fun)
    end

    test "rejects a non-function approval hook" do
      assert_raise ArgumentError, ~r/on_payment_required/, fn ->
        ClientMCP.new(provider: DemoProvider, on_payment_required: :yes)
      end
    end
  end

  describe "passthrough" do
    test "returns a non-payment JSON-RPC result without paying" do
      send_fun = fn request ->
        send(self(), {:sent, request})
        %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"content" => []}}
      end

      client = ClientMCP.new(provider: {DemoProvider, %{test_pid: self()}})

      assert {:ok, %{"result" => %{"content" => []}}} =
               ClientMCP.call(client, json_rpc_request(), send_fun)

      assert_received {:sent, _}
      refute_received {:paid, _, _}
    end

    test "returns a non-payment JSON-RPC error without paying" do
      send_fun = fn request ->
        %{"jsonrpc" => "2.0", "id" => request["id"], "error" => %{"code" => -32_000, "message" => "boom"}}
      end

      client = ClientMCP.new(provider: DemoProvider)

      assert {:ok, %{"error" => %{"code" => -32_000}}} =
               ClientMCP.call(client, json_rpc_request(), send_fun)
    end
  end

  describe "end-to-end against the local MPP MCP server" do
    test "pays the selected challenge and retries the original tool call once" do
      client = ClientMCP.new(provider: {DemoProvider, %{test_pid: self()}})
      request = json_rpc_request()

      assert {:ok, response} = ClientMCP.call(client, request, local_server())

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "req-1"
      assert response["result"]["content"] == [%{"type" => "text", "text" => "premium data"}]
      assert response["result"]["_meta"][Mcp.receipt_meta_key()]["status"] == "success"
      assert response["result"]["_meta"][Mcp.receipt_meta_key()]["method"] == "demo"

      assert_received {:paid, "demo", _id}
      assert_received {:handled, "req-1"}
      refute_received {:paid, _, _}
      refute_received {:handled, _}
    end

    test "decline after selection performs neither payment nor retry" do
      hook = fn challenge ->
        send(self(), {:approval, challenge.method})
        false
      end

      client =
        ClientMCP.new(
          provider: {DemoProvider, %{test_pid: self()}},
          on_payment_required: hook
        )

      assert {:error, :payment_declined} = ClientMCP.call(client, json_rpc_request(), local_server())

      assert_received {:approval, "demo"}
      refute_received {:paid, _, _}
      refute_received {:handled, _}
    end
  end

  describe "approval callback timing" do
    test "invokes approval after selection and before payment with the selected challenge" do
      tempo = make_challenge("tempo")
      stripe = make_challenge("stripe")
      error = Mcp.payment_required_error([tempo, stripe])

      send_fun = fn request ->
        send(self(), {:sent, get_in(request, ["params", "_meta"])})

        if get_in(request, ["params", "_meta", Mcp.credential_meta_key()]) do
          %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"ok" => true}}
        else
          %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error}
        end
      end

      hook = fn challenge ->
        send(self(), {:approval, challenge.method})
        true
      end

      client =
        ClientMCP.new(
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}]),
          accept_payment: [{"stripe", "charge", 1.0}, {"tempo", "charge", 0.1}],
          on_payment_required: hook
        )

      assert {:ok, %{"result" => %{"ok" => true}}} = ClientMCP.call(client, json_rpc_request(), send_fun)

      cred_key = Mcp.credential_meta_key()
      assert_received {:sent, nil}
      assert_received {:approval, "stripe"}
      assert_received {:paid, "stripe"}
      assert_received {:sent, %{^cred_key => _}}
      refute_received {:paid, "tempo"}
      refute_received {:approval, "tempo"}
    end

    test "per-call nil bypasses the configured approval hook" do
      tempo = make_challenge("tempo")

      send_fun = fn request ->
        if get_in(request, ["params", "_meta", Mcp.credential_meta_key()]) do
          %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"ok" => true}}
        else
          %{"jsonrpc" => "2.0", "id" => request["id"], "error" => Mcp.payment_required_error(tempo)}
        end
      end

      hook = fn _challenge ->
        send(self(), :config_hook)
        false
      end

      client = ClientMCP.new(provider: {TempoProvider, %{test_pid: self()}}, on_payment_required: hook)

      assert {:ok, %{"result" => %{"ok" => true}}} =
               ClientMCP.call(client, json_rpc_request(), send_fun, on_payment_required: nil)

      refute_received :config_hook
      assert_received {:paid, "tempo"}
    end

    test "custom selection policy can prefer a later offer" do
      tempo = make_challenge("tempo")
      stripe = make_challenge("stripe")

      send_fun = fn request ->
        if get_in(request, ["params", "_meta", Mcp.credential_meta_key()]) do
          %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"ok" => true}}
        else
          %{"jsonrpc" => "2.0", "id" => request["id"], "error" => Mcp.payment_required_error([tempo, stripe])}
        end
      end

      client =
        ClientMCP.new(
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}]),
          selection: fn challenges -> Enum.reverse(challenges) end
        )

      assert {:ok, %{"result" => %{"ok" => true}}} = ClientMCP.call(client, json_rpc_request(), send_fun)
      assert_received {:paid, "stripe"}
      refute_received {:paid, "tempo"}
    end

    test "does not invoke approval when no provider supports the offers" do
      error = Mcp.payment_required_error(make_challenge("tempo"))

      send_fun = fn request ->
        %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error}
      end

      hook = fn _challenge ->
        send(self(), :approval)
        true
      end

      client = ClientMCP.new(provider: MultiProvider.new([]), on_payment_required: hook)

      assert {:error, :no_supported_challenge} = ClientMCP.call(client, json_rpc_request(), send_fun)
      refute_received :approval
    end
  end

  describe "errors and malformed envelopes" do
    test "returns the provider error when payment fails" do
      error = Mcp.payment_required_error(make_challenge("tempo"))

      send_fun = fn request ->
        %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error}
      end

      client = ClientMCP.new(provider: FailingProvider)

      assert {:error, :payment_failed} = ClientMCP.call(client, json_rpc_request(), send_fun)
    end

    test "returns :no_challenges for a -32042 envelope with no challenge list" do
      send_fun = fn request ->
        %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "error" => %{"code" => Mcp.payment_required_code(), "message" => "Payment Required"}
        }
      end

      client = ClientMCP.new(provider: DemoProvider)

      assert {:error, :no_challenges} = ClientMCP.call(client, json_rpc_request(), send_fun)
    end

    test "returns :malformed_envelope when the first or retry response is not a JSON-RPC map" do
      client = ClientMCP.new(provider: {TempoProvider, %{test_pid: self()}})

      assert {:error, :malformed_envelope} =
               ClientMCP.call(client, json_rpc_request(), fn _request -> "not-json-rpc" end)

      refute_received {:paid, _}

      send_fun = fn request ->
        if get_in(request, ["params", "_meta", Mcp.credential_meta_key()]) do
          :not_a_map
        else
          %{"jsonrpc" => "2.0", "id" => request["id"], "error" => Mcp.payment_required_error(make_challenge("tempo"))}
        end
      end

      assert {:error, :malformed_envelope} = ClientMCP.call(client, json_rpc_request(), send_fun)
      assert_received {:paid, "tempo"}
    end

    test "retries only once and returns a second payment-required response" do
      error = Mcp.payment_required_error(make_challenge("tempo"))

      send_fun = fn request ->
        send(self(), {:sent, Map.has_key?(request["params"]["_meta"] || %{}, Mcp.credential_meta_key())})
        %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error}
      end

      client = ClientMCP.new(provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %{"error" => %{"code" => -32_042}}} = ClientMCP.call(client, json_rpc_request(), send_fun)
      assert_received {:sent, false}
      assert_received {:paid, "tempo"}
      assert_received {:sent, true}
      refute_received {:paid, _}
      refute_received {:sent, _}
    end

    test "pays a payment-required result._meta the same way as a -32042 error" do
      challenge = make_challenge("tempo")
      [wire] = Mcp.payment_required_error(challenge)["data"]["challenges"]

      send_fun = fn request ->
        if get_in(request, ["params", "_meta", Mcp.credential_meta_key()]) do
          %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"ok" => true}}
        else
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "_meta" => %{Mcp.payment_required_meta_key() => %{"challenges" => [wire]}}
            }
          }
        end
      end

      client = ClientMCP.new(provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %{"result" => %{"ok" => true}}} = ClientMCP.call(client, json_rpc_request(), send_fun)
      assert_received {:paid, "tempo"}
    end

    test "rejects a non-function per-call approval hook" do
      client = ClientMCP.new(provider: DemoProvider)

      assert_raise ArgumentError, ~r/on_payment_required/, fn ->
        ClientMCP.call(client, json_rpc_request(), fn _ -> %{} end, on_payment_required: :nope)
      end
    end

    test "raises when the approval hook does not return a boolean" do
      error = Mcp.payment_required_error(make_challenge("tempo"))
      send_fun = fn request -> %{"jsonrpc" => "2.0", "id" => request["id"], "error" => error} end
      client = ClientMCP.new(provider: TempoProvider, on_payment_required: fn _ -> :maybe end)

      assert_raise ArgumentError, ~r/boolean/, fn ->
        ClientMCP.call(client, json_rpc_request(), send_fun)
      end
    end
  end

  test "MCP client module exposes Descripex metadata" do
    names = for f <- ClientMCP.__api__(), do: f.name

    assert :new in names
    assert :call in names
  end
end
