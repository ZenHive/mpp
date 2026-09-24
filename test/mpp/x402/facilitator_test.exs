defmodule MPP.X402.FacilitatorTest do
  use ExUnit.Case, async: true

  alias MPP.X402.Facilitator

  # Transport regression tests only; provider semantics are exercised by
  # facilitator_integration_test.exs against the live facilitator.
  test "HTTP client sends the envelope to each action and parses the response" do
    client = Facilitator.resolve("http://facilitator.test/", req_options: [plug: {Req.Test, __MODULE__}])

    for {action, response} <- [
          {"verify", %{"isValid" => false, "invalidReason" => "declined"}},
          {"settle", %{"success" => false, "network" => "eip155:1", "transaction" => ""}}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/" <> action
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "x402Version" => 2,
                 "paymentPayload" => %{"payload" => "sentinel"},
                 "paymentRequirements" => %{"amount" => "1"}
               }

        Req.Test.json(conn, response)
      end)

      assert {:ok, ^response} =
               apply(Facilitator, String.to_existing_atom(action), [
                 client,
                 %{"payload" => "sentinel"},
                 %{"amount" => "1"}
               ])
    end

    Req.Test.verify!()
  end

  test "HTTP status, non-object success bodies and transport errors propagate without retries" do
    client = Facilitator.http("http://facilitator.test", req_options: [plug: {Req.Test, __MODULE__}])

    for {status, body} <- [{503, %{"error" => "unavailable"}}, {200, ["unexpected"]}] do
      Req.Test.expect(__MODULE__, fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end)
      assert {:error, {:facilitator_http, ^status, ^body}} = Facilitator.verify(client, %{}, %{})
    end

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:facilitator_request, %Req.TransportError{reason: :timeout}}} =
             Facilitator.settle(client, %{}, %{})

    Req.Test.verify!()
  end

  test "function clients preserve errors and response validation" do
    client = %{verify: fn _, _ -> {:error, :offline} end, settle: fn _, _ -> {:ok, %{}} end}
    assert Facilitator.resolve(client) == client
    assert {:error, :offline} = Facilitator.verify(client, %{}, %{})
    assert {:error, :invalid_settle_response} = Facilitator.settle(client, %{}, %{})

    for invalid <- [nil, "", %{}, %{verify: fn _ -> :ok end, settle: fn _ -> :ok end}] do
      assert_raise ArgumentError, fn -> Facilitator.resolve(invalid) end
    end
  end
end
