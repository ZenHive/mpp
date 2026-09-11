defmodule MPP.Methods.XRPLIntegrationTest do
  @moduledoc """
  Live testnet oracle, using XRPL-owned Payment, tx, submit and currency-format docs:
  https://xrpl.org/docs/references/protocol/transactions/types/payment
  https://xrpl.org/docs/references/protocol/data-types/currency-formats
  https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/transaction-methods/tx

  Generates funded, disposable testnet wallets; never uses mainnet funds.
  The XRPL-owned JavaScript SDK only signs test transactions.
  """
  use ExUnit.Case, async: false

  alias MPP.Intents.Charge
  alias MPP.Methods.XRPL
  alias MPP.Tempo.ConCacheStore

  @moduletag :integration
  @moduletag timeout: 180_000

  setup_all do
    url = System.get_env("XRPL_TESTNET_RPC_URL")

    if is_nil(url) or System.find_executable("node") == nil or
         not File.dir?(System.get_env("XRPL_JS_PATH") || "tmp/xrpl/node_modules/xrpl") do
      flunk("""
      Missing XRPL testnet setup. Run from the repository root:
        npm install --prefix tmp/xrpl --no-audit --no-fund xrpl@4.6.0
        export XRPL_TESTNET_RPC_URL="https://s.altnet.rippletest.net:51234/"
        export XRPL_JS_PATH="$PWD/tmp/xrpl/node_modules/xrpl"
        mix test test/mpp/methods/xrpl_integration_test.exs --include integration
      Wallets are generated and funded through https://faucet.altnet.rippletest.net/accounts.
      Setup: https://xrpl.org/resources/dev-tools/xrp-faucets
      No wallet secret is sent to the RPC or written to a fixture.
      """)
    end

    assert %{"info" => %{"network_id" => 1}} = rpc!(url, "server_info", %{})
    payer = funded_wallet!()
    recipient = funded_wallet!()
    {:ok, url: url, payer: payer, recipient: recipient}
  end

  setup do
    name = :xrpl_integration_store
    start_supervised!({ConCacheStore, name: name, ttl: 600_000})
    {:ok, store: {ConCacheStore, name: name}}
  end

  for type <- ~w(transaction hash) do
    @credential_type type
    test "#{type}: real XRP settlement, attribution, amount, finality and single use", context do
      charge = charge(context)
      tx = payment(context, charge)
      signed = sign!(context, tx)
      payload = credential!(context, @credential_type, signed)

      assert {:ok, receipt} = XRPL.verify(payload, charge)
      assert receipt.reference == signed["hash"]
      assert receipt.extensions["txHash"] == signed["hash"]
      assert is_integer(receipt.extensions["ledgerIndex"])

      ledger = rpc!(context.url, "tx", %{"transaction" => signed["hash"]})
      assert ledger["validated"] == true
      assert ledger["meta"]["TransactionResult"] == "tesSUCCESS"
      assert ledger["meta"]["delivered_amount"] == "1000"
      assert ledger["DestinationTag"] == tx["DestinationTag"]
      assert ledger["Memos"] == tx["Memos"]
      assert ledger["InvoiceID"] == tx["InvoiceID"]
      File.mkdir_p!("tmp/xrpl")

      File.write!(
        "tmp/xrpl/#{@credential_type}_xrp.json",
        Jason.encode!(%{
          "signed" => signed,
          "ledger" => ledger,
          "request" =>
            Charge.to_request(%{
              charge
              | method_details:
                  Map.take(
                    charge.method_details,
                    ~w(challenge_id challenge_expires credential_source network destinationTag sourceTag memos)
                  )
            })
        })
      )

      assert {:error, error} = XRPL.verify(payload, charge)
      assert error.type == "https://paymentauth.org/problems/invalid-challenge"
    end

    test "#{type}: rejects a real signed payment to a different destination", context do
      charge = charge(context)
      wrong = funded_wallet!()
      tx = Map.put(payment(context, charge), "Destination", wrong["address"])
      signed = sign!(context, tx)
      payload = credential!(context, @credential_type, signed)
      assert {:error, error} = XRPL.verify(payload, charge)
      assert error.type == "https://paymentauth.org/problems/verification-failed"

      if @credential_type == "transaction" do
        assert %{"error" => "txnNotFound"} = rpc!(context.url, "tx", %{"transaction" => signed["hash"]})
      end
    end

    test "#{type}: real issued-currency settlement and wrong issuer rejection", context do
      issuer = context.payer

      trust = %{
        "TransactionType" => "TrustSet",
        "Account" => context.recipient["address"],
        "LimitAmount" => %{"currency" => "USD", "issuer" => issuer["address"], "value" => "100"}
      }

      trust_signed = sign!(%{context | payer: context.recipient}, trust)
      submit!(context, trust_signed)
      asset = %{"currency" => "USD", "issuer" => issuer["address"]}
      charge = %{charge(context) | amount: "1.25", currency: Jason.encode!(asset)}
      tx = Map.put(payment(context, charge), "Amount", Map.put(asset, "value", "1.25"))
      signed = sign!(context, tx)
      payload = credential!(context, @credential_type, signed)
      wrong = %{charge | currency: Jason.encode!(%{asset | "issuer" => context.recipient["address"]})}
      assert {:error, error} = XRPL.verify(payload, wrong)
      assert error.type == "https://paymentauth.org/problems/verification-failed"
      assert {:ok, _receipt} = XRPL.verify(payload, charge)
      ledger = rpc!(context.url, "tx", %{"transaction" => signed["hash"]})
      assert ledger["validated"] == true
      assert ledger["meta"]["delivered_amount"] == Map.put(asset, "value", "1.25")
      redeem!(context, Map.put(asset, "value", "1.25"))
      cleanup = sign!(%{context | payer: context.recipient}, put_in(trust, ["LimitAmount", "value"], "0"))
      submit!(context, cleanup)
    end
  end

  test "settlement before challenge issuance is rejected even with an explicit invoice", context do
    charge = charge(context)
    signed = sign!(context, payment(context, charge))
    ledger = submit!(context, signed)
    close_time = DateTime.shift(~U[2000-01-01 00:00:00Z], second: ledger["date"])

    config =
      Map.merge(charge.method_details, %{
        "invoiceId" => ledger["InvoiceID"],
        "challenge_expires" => DateTime.to_iso8601(DateTime.shift(close_time, second: 181))
      })

    payload = %{"type" => "hash", "hash" => signed["hash"]}

    assert {:error, %MPP.Errors{type: "https://paymentauth.org/problems/verification-failed"}} =
             XRPL.verify(payload, %{charge | method_details: config})

    assert {:ok, _} = XRPL.verify(payload, charge)
  end

  test "real MPT charge settles only the challenged issuance", context do
    # https://xrpl.org/docs/references/protocol/transactions/types/mptokenissuancecreate
    create =
      sign!(context, %{"TransactionType" => "MPTokenIssuanceCreate", "Account" => context.payer["address"], "Flags" => 32})

    result = submit!(context, create)

    issuance = result["meta"]["mpt_issuance_id"]

    assert is_binary(issuance), "MPTokenIssuanceCreate returned no issuance ID: #{inspect(result)}"

    authorize =
      sign!(%{context | payer: context.recipient}, %{
        "TransactionType" => "MPTokenAuthorize",
        "Account" => context.recipient["address"],
        "MPTokenIssuanceID" => issuance
      })

    submit!(context, authorize)

    for type <- ~w(transaction hash) do
      asset = %{"mpt_issuance_id" => issuance}
      charge = %{charge(context) | amount: "123", currency: Jason.encode!(asset)}
      signed = sign!(context, Map.put(payment(context, charge), "Amount", Map.put(asset, "value", "123")))
      payload = credential!(context, type, signed)
      assert_error = XRPL.verify(payload, %{charge | amount: "124"})
      assert {:error, %MPP.Errors{type: "https://paymentauth.org/problems/verification-failed"}} = assert_error
      assert {:ok, _} = XRPL.verify(payload, charge)
      ledger = rpc!(context.url, "tx", %{"transaction" => signed["hash"]})
      assert ledger["meta"]["delivered_amount"] == Map.put(asset, "value", "123")
    end

    redeem!(context, %{"mpt_issuance_id" => issuance, "value" => "246"})

    unauthorize =
      sign!(%{context | payer: context.recipient}, %{
        "TransactionType" => "MPTokenAuthorize",
        "Account" => context.recipient["address"],
        "MPTokenIssuanceID" => issuance,
        "Flags" => 1
      })

    submit!(context, unauthorize)

    destroy =
      sign!(context, %{
        "TransactionType" => "MPTokenIssuanceDestroy",
        "Account" => context.payer["address"],
        "MPTokenIssuanceID" => issuance
      })

    submit!(context, destroy)
  end

  defp redeem!(context, amount) do
    signed =
      sign!(%{context | payer: context.recipient}, %{
        "TransactionType" => "Payment",
        "Account" => context.recipient["address"],
        "Destination" => context.payer["address"],
        "Amount" => amount
      })

    result = submit!(context, signed)
    assert result["meta"]["delivered_amount"] == amount
  end

  defp charge(context) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    %Charge{
      amount: "1000",
      currency: "XRP",
      recipient: context.recipient["address"],
      method_details: %{
        "rpc_url" => context.url,
        "network" => "testnet",
        "challenge_id" => id,
        "expires_in" => 180,
        "challenge_expires" => DateTime.to_iso8601(DateTime.shift(DateTime.utc_now(), minute: 3)),
        "credential_source" => "did:pkh:xrpl:1:" <> context.payer["address"],
        "destinationTag" => :binary.decode_unsigned(:crypto.strong_rand_bytes(4)),
        "sourceTag" => 593_184_257,
        "memos" => [%{"data" => id}],
        "store" => context.store,
        "allow_process_local_store" => true,
        "store_retention_ms" => 600_000
      }
    }
  end

  defp payment(context, charge) do
    <<invoice::binary-32, _::binary>> = :crypto.hash(:sha512, charge.method_details["challenge_id"])

    %{
      "TransactionType" => "Payment",
      "Account" => context.payer["address"],
      "Destination" => charge.recipient,
      "Amount" => charge.amount,
      "InvoiceID" => Base.encode16(invoice),
      "DestinationTag" => charge.method_details["destinationTag"],
      "SourceTag" => charge.method_details["sourceTag"],
      "Memos" => [%{"Memo" => %{"MemoData" => Base.encode16(charge.method_details["challenge_id"])}}]
    }
  end

  defp credential!(_context, "transaction", signed), do: %{"type" => "transaction", "blob" => signed["tx_blob"]}

  defp credential!(context, "hash", signed) do
    submit!(context, signed)
    %{"type" => "hash", "hash" => String.downcase(signed["hash"])}
  end

  defp sign!(context, tx) do
    info = account!(context.url, context.payer["address"], System.monotonic_time(:millisecond) + 30_000)
    ledger = rpc!(context.url, "ledger_current", %{})

    tx =
      Map.merge(tx, %{
        "Fee" => "12",
        "Sequence" => info["account_data"]["Sequence"],
        "LastLedgerSequence" => ledger["ledger_current_index"] + 20
      })

    js!(%{"seed" => context.payer["seed"], "tx" => tx})
  end

  defp account!(url, address, deadline) do
    result = rpc!(url, "account_info", %{"account" => address, "ledger_index" => "validated"})

    case result do
      %{"account_data" => %{"Sequence" => sequence}} when is_integer(sequence) ->
        result

      %{"error" => "actNotFound"} ->
        assert System.monotonic_time(:millisecond) < deadline, "Faucet account did not reach a validated ledger"

        receive do
        after
          1000 -> :ok
        end

        account!(url, address, deadline)

      other ->
        flunk("XRPL account_info failed: #{inspect(other)}")
    end
  end

  defp submit!(context, signed) do
    result = rpc!(context.url, "submit", %{"tx_blob" => signed["tx_blob"]})
    assert result["engine_result"] in ["tesSUCCESS", "terQUEUED"], inspect(result)
    poll!(context.url, signed["hash"], System.monotonic_time(:millisecond) + 60_000)
  end

  defp poll!(url, hash, deadline) do
    result = rpc!(url, "tx", %{"transaction" => hash})

    if result["validated"] == true do
      assert result["meta"]["TransactionResult"] == "tesSUCCESS"
      result
    else
      assert System.monotonic_time(:millisecond) < deadline, "XRPL transaction did not validate: #{hash}"

      receive do
      after
        1000 -> :ok
      end

      poll!(url, hash, deadline)
    end
  end

  defp funded_wallet! do
    wallet = js!(%{})

    assert {:ok, %{status: 200, body: body}} =
             Req.post("https://faucet.altnet.rippletest.net/accounts",
               json: %{"destination" => wallet["address"]},
               retry: false,
               receive_timeout: 60_000
             )

    assert body["account"]["address"] == wallet["address"]
    wallet
  end

  defp js!(input) do
    {output, status} = System.cmd("node", ["test/support/xrpl/sign.cjs", Jason.encode!(input)], stderr_to_stdout: true)
    assert status == 0, "XRPL signing helper failed; install xrpl@4.6.0 and set XRPL_JS_PATH"
    Jason.decode!(output)
  end

  defp rpc!(url, method, params) do
    assert {:ok, %{status: 200, body: %{"result" => result}}} =
             Req.post(url, json: %{"method" => method, "params" => [Map.put(params, "api_version", 1)]}, retry: false)

    result
  end
end
