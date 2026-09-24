defmodule MPP.X402.LocalnetTest do
  use ExUnit.Case, async: false

  alias MPP.Client.Providers.X402Exact
  alias MPP.Client.Req, as: ClientReq
  alias MPP.Errors
  alias MPP.Method
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Test.EVMAuthorization
  alias MPP.X402.Headers

  @moduletag timeout: 30_000

  @url "http://example.com/resource"
  @accept %{
    "scheme" => "exact",
    "network" => "eip155:84532",
    "amount" => "10000",
    "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    "payTo" => "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "maxTimeoutSeconds" => 300,
    "extra" => %{"name" => "USDC", "version" => "2"}
  }

  defmodule MockMethod do
    @moduledoc false
    use Method

    @impl Method
    def method_name, do: "mock"

    @impl Method
    def verify(%{"proof" => "valid"}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof")}
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> MapSet.new() end)
    {:ok, agent: agent, opts: plug_opts(agent)}
  end

  test "pay-and-retry settles x402 exact and invokes the approval hook", %{opts: opts} do
    parent = self()

    req =
      [plug: endpoint(opts)]
      |> Req.new()
      |> ClientReq.attach(
        provider: {X402Exact, %{private_key: EVMAuthorization.private_key(), networks: [84_532]}},
        on_payment_required: fn challenge ->
          send(parent, {:approved, challenge.id})
          true
        end
      )

    assert {:ok, %Req.Response{status: 200} = response} = Req.get(req, url: @url)
    assert_received {:approved, "x402:0"}
    refute_received {:approved, _}

    [header] = Req.Response.get_header(response, "payment-response")
    assert {:ok, settled} = Headers.decode_payment_response(header)
    assert settled["success"] == true
    assert settled["network"] == "eip155:84532"
    assert settled["transaction"] != ""
  end

  test "replays of a settled PAYMENT-SIGNATURE are rejected", %{opts: opts} do
    parent = self()

    req =
      [plug: endpoint(opts)]
      |> Req.new()
      |> ClientReq.attach(
        provider: {X402Exact, %{private_key: EVMAuthorization.private_key(), networks: [84_532]}},
        on_payment_required: fn challenge ->
          send(parent, {:approved, challenge.id})
          true
        end
      )

    assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: @url)
    assert_received {:approved, "x402:0"}

    signature =
      receive do
        {:payment_signature, header} -> header
      after
        1_000 -> flunk("expected the localnet plug to record PAYMENT-SIGNATURE")
      end

    replay =
      [plug: endpoint(opts)]
      |> Req.new()
      |> Req.Request.put_header("payment-signature", signature)

    assert {:ok, %Req.Response{status: 402}} = Req.get(replay, url: @url)
  end

  test "native Payment-auth still works on the same endpoint", %{opts: opts} do
    bare = Req.new(plug: endpoint(opts))
    assert {:ok, %Req.Response{status: 402} = unpaid} = Req.get(bare, url: @url)
    assert Req.Response.get_header(unpaid, "www-authenticate") != []
    assert Req.Response.get_header(unpaid, "payment-required") != []

    challenge =
      unpaid
      |> Req.Response.get_header("www-authenticate")
      |> hd()
      |> then(&elem(MPP.Headers.parse_challenge(&1), 1))

    credential = %MPP.Credential{challenge: challenge, payload: %{"proof" => "valid"}, source: nil}
    paid = MPP.Client.Transport.HTTP.set_credential(bare, credential)
    assert {:ok, %Req.Response{status: 200}} = Req.get(paid, url: @url)
  end

  test "native challengeHash nonce is rejected on the x402 path", %{opts: opts} do
    {:ok, %Req.Response{status: 402} = unpaid} = Req.get(Req.new(plug: endpoint(opts)), url: @url)
    [required] = Req.Response.get_header(unpaid, "payment-required")
    assert {:ok, [challenge]} = MPP.X402.challenges_from_header(required)
    native_nonce = MPP.Methods.EVM.Authorization.challenge_hash(challenge.id, challenge.realm)

    payload = %{
      "x402Version" => 2,
      "accepted" => @accept,
      "resource" => %{"url" => @url},
      "payload" => %{
        "signature" => "0x" <> String.duplicate("11", 65),
        "authorization" => %{
          "from" => EVMAuthorization.signer_address(),
          "to" => @accept["payTo"],
          "value" => @accept["amount"],
          "validAfter" => "1",
          "validBefore" => Integer.to_string(System.system_time(:second) + 300),
          "nonce" => native_nonce
        }
      }
    }

    {:ok, header} = Headers.encode_payment_signature(payload)

    request =
      [plug: endpoint(opts)]
      |> Req.new()
      |> Req.Request.put_header("payment-signature", header)

    assert {:ok, %Req.Response{status: 402} = rejected} = Req.get(request, url: @url)
    assert problem_detail(rejected) =~ "native_nonce"
  end

  defp problem_detail(%Req.Response{body: body}) when is_map(body), do: body["detail"] || ""
  defp problem_detail(%Req.Response{body: body}) when is_binary(body), do: Jason.decode!(body)["detail"] || ""

  defp endpoint(opts) do
    parent = self()

    fn conn ->
      conn =
        case Plug.Conn.get_req_header(conn, "payment-signature") do
          [header | _] ->
            send(parent, {:payment_signature, header})
            conn

          [] ->
            conn
        end

      conn = PaymentPlug.call(conn, opts)
      if conn.halted, do: conn, else: Plug.Conn.send_resp(conn, 200, "ok")
    end
  end

  defp plug_opts(agent) do
    PaymentPlug.init(
      secret_key: "x402-localnet-secret",
      realm: "example.com",
      method: MockMethod,
      amount: "1000",
      currency: "usd",
      store: false,
      x402: [
        facilitator: facilitator(agent),
        accepts: [@accept],
        resource: %{"url" => @url}
      ]
    )
  end

  defp facilitator(agent) do
    %{
      verify: fn payload, _requirements ->
        payer = get_in(payload, ["payload", "authorization", "from"])
        {:ok, %{"isValid" => true, "payer" => payer}}
      end,
      settle: fn payload, requirements ->
        nonce = get_in(payload, ["payload", "authorization", "nonce"])
        payer = get_in(payload, ["payload", "authorization", "from"])

        duplicate? =
          Agent.get_and_update(agent, fn used ->
            {MapSet.member?(used, nonce), MapSet.put(used, nonce)}
          end)

        if duplicate? do
          {:ok,
           %{
             "success" => false,
             "errorReason" => "invalid_exact_evm_payload",
             "transaction" => "",
             "network" => requirements["network"],
             "payer" => payer
           }}
        else
          {:ok,
           %{
             "success" => true,
             "transaction" => "0x" <> String.duplicate("ab", 32),
             "network" => requirements["network"],
             "payer" => payer
           }}
        end
      end
    }
  end
end
