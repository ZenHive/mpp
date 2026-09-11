defmodule MPP.Methods.XRPLTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.XRPL
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  @fixture "test/fixtures/xrpl/payment.json" |> File.read!() |> Jason.decode!()
  @hash @fixture["signed"]["hash"]
  @blob @fixture["signed"]["tx_blob"]
  @ledger @fixture["ledger"]

  defmodule UnavailableStore do
    @moduledoc false
    @behaviour Store

    @impl true
    @spec get(String.t()) :: {:error, :unavailable}
    def get(_), do: {:error, :unavailable}
    @impl true
    @spec put(String.t(), term()) :: {:error, :unavailable}
    def put(_, _), do: {:error, :unavailable}
    @impl true
    @spec check_and_mark(String.t(), term()) :: {:error, :unavailable}
    def check_and_mark(_, _), do: {:error, :unavailable}
  end

  defmodule FailingCommitStore do
    @moduledoc false
    @behaviour Store

    @impl true
    @spec get(String.t()) :: :not_found
    def get(_), do: :not_found
    @impl true
    @spec put(String.t(), term()) :: {:error, :unavailable}
    def put(_, _), do: {:error, :unavailable}
    @impl true
    @spec check_and_mark(String.t(), term()) :: {:error, atom()}
    def check_and_mark(_key, _), do: {:error, Process.get(:xrpl_commit_error, :unavailable)}
  end

  setup do
    name = String.to_atom("xrpl_#{System.unique_integer([:positive])}")
    start_supervised!({ConCacheStore, name: name, ttl: 600_000})
    {:ok, charge} = Charge.from_request(@fixture["request"])

    expires = DateTime.shift(DateTime.utc_now(), minute: 1)
    close_time = DateTime.shift(~U[2000-01-01 00:00:00Z], second: @ledger["date"])

    config =
      Map.merge(charge.method_details, %{
        "rpc_url" => "https://xrpl.test",
        "store" => {ConCacheStore, name: name},
        "store_retention_ms" => 600_000,
        "allow_process_local_store" => true,
        "poll_interval_ms" => 1,
        "poll_timeout_ms" => 100,
        "challenge_expires" => DateTime.to_iso8601(expires),
        # Keep the captured ledger timestamp inside this regression test's challenge window.
        "expires_in" => DateTime.diff(expires, close_time, :second) + 1,
        "req_options" => [plug: {Req.Test, __MODULE__}]
      })

    {:ok, charge: %{charge | method_details: config}, owner: self()}
  end

  test "wire names and advertised fields match the pinned draft", context do
    assert XRPL.method_name() == "xrpl"
    assert XRPL.credential_types() == ~w(transaction hash)
    assert :ok = XRPL.validate_config!(context.charge.method_details)

    details = XRPL.challenge_method_details(context.charge)

    assert details ==
             context.charge.method_details
             |> Map.take(~w(network reference invoiceId destinationTag sourceTag memos))
             |> Map.put("credentialTypes", ~w(transaction hash))

    refute Map.has_key?(details, "rpc_url")
    refute Map.has_key?(details, "store")

    assert XRPL.challenge_method_details(%{context.charge | method_details: nil}) == %{
             "credentialTypes" => ~w(transaction hash)
           }

    assert Enum.all?(~w(malformed_credential invalid_challenge verification_failed)a, &(&1 in Errors.types()))
  end

  for type <- ~w(hash transaction) do
    @credential_type type
    test "#{type} verifies recorded validated Payment and returns draft receipt fields", context do
      stub(context, @ledger)
      assert {:ok, receipt} = XRPL.verify(payload(@credential_type), context.charge)
      assert receipt.method == "xrpl"
      assert receipt.reference == @hash
      assert receipt.extensions == %{"txHash" => @hash, "ledgerIndex" => @ledger["ledger_index"]}

      assert {:error, %Errors{type: "https://paymentauth.org/problems/invalid-challenge"}} =
               XRPL.verify(payload(@credential_type), context.charge)
    end
  end

  test "malformed credentials, fields and oversized blobs do not call RPC", context do
    for payload <- [
          %{},
          nil,
          [],
          %{"type" => "signature", "signature" => @hash},
          %{"type" => "hash"},
          %{"type" => "hash", "hash" => 5},
          %{"type" => "hash", "hash" => String.duplicate("Z", 64)},
          %{"type" => "transaction", "transaction" => @blob},
          %{"type" => "transaction", "blob" => "00"}
        ] do
      assert_error(XRPL.verify(payload, context.charge), :malformed_credential)
    end

    refute_received {:rpc, _}
  end

  test "missing, malformed, expired and under-retained challenges fail before RPC", context do
    for config <- [
          %{"challenge_id" => nil},
          %{"challenge_expires" => nil},
          %{"challenge_id" => ""},
          %{"challenge_expires" => 4},
          %{"challenge_expires" => "invalid"},
          %{"challenge_expires" => "2000-01-01T00:00:00Z"},
          %{"store_retention_ms" => 10},
          %{"poll_timeout_ms" => "bad"},
          %{"store_retention_ms" => nil}
        ] do
      assert_error(XRPL.verify(payload("hash"), config_charge(context, config)), :invalid_challenge)
    end

    refute_received {:rpc, _}
  end

  test "invalid endpoint amounts, assets and recipients fail locally", context do
    for changes <- [
          %{amount: "0"},
          %{amount: "-1"},
          %{amount: "1e3"},
          %{amount: "1.1"},
          %{amount: nil},
          %{amount: String.duplicate("1", 161)},
          %{currency: "xrp"},
          %{currency: "{}"},
          %{currency: nil},
          %{currency: "[]"},
          %{currency: ~s({"currency":"XRP","issuer":"invalid"})},
          %{currency: ~s({"mpt_issuance_id":"bad"})},
          %{recipient: "invalid"},
          %{recipient: nil}
        ] do
      assert_error(XRPL.verify(payload("hash"), struct(context.charge, changes)), :verification_failed)
    end

    refute_received {:rpc, _}
  end

  test "configuration rejects unsafe RPCs, stores, networks, tags and memo shapes", context do
    for config <- [
          %{"rpc_url" => nil},
          %{"rpc_url" => "http://example.com"},
          %{"rpc_url" => "https://"},
          %{"rpc_url" => "https://secret@example.com"},
          %{"network" => "wrong"},
          %{"store" => false},
          %{"store" => nil},
          %{"store" => String},
          %{"store_retention_ms" => -1},
          %{"poll_timeout_ms" => 0},
          %{"poll_interval_ms" => 0},
          %{"expires_in" => 0},
          %{"expires_in" => nil},
          %{"expires_in" => "300"},
          %{"sourceTag" => -1},
          %{"destinationTag" => 4_294_967_296},
          %{"invoiceId" => "123"},
          %{"memos" => false},
          %{"memos" => [%{"data" => 5}]},
          %{"memos" => [%{"extra" => "bad"}]},
          %{"memos" => [%{}]},
          %{"memos" => [%{"data" => <<255>>}]},
          %{"network" => "mainnet"},
          %{"allow_process_local_store" => false}
        ] do
      assert_raise ArgumentError, fn -> XRPL.validate_config!(Map.merge(context.charge.method_details, config)) end
    end

    assert :ok =
             XRPL.validate_config!(
               Map.merge(context.charge.method_details, %{"rpc_url" => "http://localhost:51234", "store" => ConCacheStore})
             )

    assert :ok =
             XRPL.validate_config!(
               Map.merge(context.charge.method_details, %{"store" => UnavailableStore, "network" => "mainnet"})
             )

    assert_raise ArgumentError, fn -> XRPL.validate_config!(%{}) end
  end

  test "source DID must exist, identify XRPL and match configured network", context do
    for source <- [
          nil,
          1,
          "did:pkh:xrpl:0:" <> @ledger["Account"],
          "did:pkh:eip155:1:" <> @ledger["Account"],
          "did:pkh:xrpl:1:bad"
        ] do
      assert_error(
        XRPL.verify(payload("hash"), config_charge(context, %{"credential_source" => source})),
        :verification_failed
      )
    end

    refute_received {:rpc, _}
  end

  test "push rejects wrong payer, tags, binding, amount, type, metadata and finality", context do
    for tx <- [
          Map.put(@ledger, "Account", @ledger["Destination"]),
          Map.put(@ledger, "Destination", @ledger["Account"]),
          Map.put(@ledger, "TransactionType", "EscrowCreate"),
          Map.put(@ledger, "Flags", 131_072),
          Map.put(@ledger, "Flags", "0"),
          Map.delete(@ledger, "DestinationTag"),
          Map.put(@ledger, "SourceTag", 1),
          Map.delete(@ledger, "InvoiceID"),
          Map.put(@ledger, "InvoiceID", String.duplicate("0", 64)),
          Map.delete(@ledger, "Memos"),
          Map.put(@ledger, "ledger_index", nil),
          Map.put(@ledger, "hash", String.duplicate("0", 64)),
          Map.delete(@ledger, "meta"),
          put_in(@ledger, ["meta", "TransactionResult"], "tecPATH_DRY"),
          put_in(@ledger, ["meta", "delivered_amount"], "999"),
          put_in(@ledger, ["meta", "delivered_amount"], "unavailable"),
          put_in(@ledger, ["meta", "delivered_amount"], 1000)
        ] do
      stub(context, tx)
      assert_error(XRPL.verify(payload("hash"), context.charge), :verification_failed)
    end
  end

  test "captured settlement before issuance fails even with a matching explicit invoice", context do
    stub(context, @ledger)
    charge = config_charge(context, %{"expires_in" => 60, "invoiceId" => @ledger["InvoiceID"]})
    assert_error(XRPL.verify(payload("hash"), charge), :verification_failed)
    assert {:ok, _} = XRPL.verify(payload("hash"), context.charge)
  end

  for representation <- [:date, :iso] do
    @representation representation
    test "#{representation} close time accepts equality and rejects one second before issuance", context do
      close_time = DateTime.truncate(DateTime.utc_now(), :second)

      charge =
        config_charge(context, %{
          "challenge_expires" => DateTime.to_iso8601(DateTime.shift(close_time, minute: 1)),
          "expires_in" => 60
        })

      tx =
        case @representation do
          :date -> Map.put(@ledger, "date", DateTime.diff(close_time, ~U[2000-01-01 00:00:00Z], :second))
          :iso -> Map.put(@ledger, "close_time_iso", DateTime.to_iso8601(close_time))
        end

      stub(context, tx)
      later = config_charge(%{context | charge: charge}, %{"expires_in" => 59})
      assert_error(XRPL.verify(payload("hash"), later), :verification_failed)
      assert {:ok, _} = XRPL.verify(payload("hash"), charge)
    end
  end

  test "missing or malformed ledger times fail closed", context do
    for tx <- [
          Map.delete(@ledger, "date"),
          Map.put(@ledger, "date", -1),
          Map.put(@ledger, "date", "842437420"),
          Map.put(@ledger, "close_time_iso", "bad"),
          Map.put(@ledger, "close_time_iso", nil),
          Map.put(@ledger, "close_time_iso", 1)
        ] do
      stub(context, tx)
      assert_error(XRPL.verify(payload("hash"), context.charge), :verification_failed)
    end
  end

  test "default challenge lifetime is 300 seconds", context do
    stub(context, Map.put(@ledger, "date", DateTime.diff(DateTime.utc_now(), ~U[2000-01-01 00:00:00Z], :second)))
    charge = %{context.charge | method_details: Map.delete(context.charge.method_details, "expires_in")}
    assert {:ok, _} = XRPL.verify(payload("hash"), charge)
  end

  test "strict pull binding rejects a blob with no invoice before submission", context do
    bytes = Base.decode16!(@blob)
    invoice = Base.decode16!(@ledger["InvoiceID"])
    blob = bytes |> :binary.replace(<<0x50, 17, invoice::binary>>, "") |> Base.encode16()
    assert {:ok, tx} = MPP.Methods.XRPL.Codec.decode(blob)
    refute Map.has_key?(tx, "InvoiceID")
    assert_error(XRPL.verify(%{"type" => "transaction", "blob" => blob}, context.charge), :verification_failed)
    refute_received {:rpc, _}
  end

  test "explicit per-challenge invoice accepts either casing", context do
    stub(context, Map.put(@ledger, "InvoiceID", String.downcase(@ledger["InvoiceID"])))
    charge = config_charge(context, %{"invoiceId" => String.downcase(@ledger["InvoiceID"])})
    assert {:ok, _} = XRPL.verify(payload("hash"), charge)
  end

  test "delivered_amount takes precedence over Amount and cannot silently fall back", context do
    stub(context, put_in(@ledger, ["meta", "delivered_amount"], "2"))
    assert_error(XRPL.verify(payload("hash"), context.charge), :verification_failed)
    stub(context, update_in(@ledger, ["meta"], &Map.delete(&1, "delivered_amount")))
    assert {:ok, _} = XRPL.verify(payload("hash"), context.charge)
  end

  test "issued currency matches exact decimal and exact issuer, never a float", context do
    asset = %{"currency" => "USD", "issuer" => @ledger["Account"]}
    charge = %{context.charge | amount: "1.2500", currency: Jason.encode!(asset)}

    for delivered <- [
          Map.put(asset, "value", "1.2500000000000001"),
          Map.merge(asset, %{"issuer" => @ledger["Destination"], "value" => "1.25"}),
          Map.put(asset, "value", 1.25),
          "1.25",
          Map.put(asset, "value", "-1.25")
        ] do
      stub(context, put_in(@ledger, ["meta", "delivered_amount"], delivered))
      assert_error(XRPL.verify(payload("hash"), charge), :verification_failed)
    end

    stub(context, put_in(@ledger, ["meta", "delivered_amount"], Map.put(asset, "value", "125e-2")))
    assert {:ok, _} = XRPL.verify(payload("hash"), charge)
  end

  test "MPT issuance is part of the exact settled asset", context do
    asset = %{"mpt_issuance_id" => String.duplicate("AB", 24)}
    charge = %{context.charge | amount: "123", currency: Jason.encode!(asset)}

    stub(
      context,
      put_in(@ledger, ["meta", "delivered_amount"], %{"mpt_issuance_id" => String.duplicate("CD", 24), "value" => "123"})
    )

    assert_error(XRPL.verify(payload("hash"), charge), :verification_failed)
    stub(context, put_in(@ledger, ["meta", "delivered_amount"], Map.put(asset, "value", "123")))
    assert {:ok, _} = XRPL.verify(payload("hash"), charge)
  end

  test "pull verifies before broadcast and checks the ledger again afterwards", context do
    charge = %{context.charge | recipient: @ledger["Account"]}
    assert_error(XRPL.verify(payload("transaction"), charge), :verification_failed)
    refute_received {:rpc, _}
    stub(context, Map.put(@ledger, "Destination", @ledger["Account"]))
    assert_error(XRPL.verify(payload("transaction"), context.charge), :verification_failed)
    assert_received {:rpc, "submit"}
  end

  test "pull requires a signed bounded transaction", context do
    # Removing complete fields yields decodable but unsigned/unbounded Payment objects.
    {:ok, bytes} = Base.decode16(@blob)
    signature = Base.decode16!(@ledger["TxnSignature"])
    without_signature = :binary.replace(bytes, <<0x74, 64, signature::binary>>, "")

    assert_error(
      XRPL.verify(%{"type" => "transaction", "blob" => Base.encode16(without_signature)}, context.charge),
      :verification_failed
    )

    without_bound = :binary.replace(bytes, <<0x20, 27, @ledger["LastLedgerSequence"]::32>>, "")

    assert_error(
      XRPL.verify(%{"type" => "transaction", "blob" => Base.encode16(without_bound)}, context.charge),
      :verification_failed
    )

    refute_received {:rpc, _}
  end

  test "network mismatch and unavailable or malformed RPC responses fail closed", context do
    for response <- [%{"info" => %{"network_id" => 0}}, %{}, %{"error" => "noNetwork"}] do
      stub(context, @ledger, network: response)
      assert_error(XRPL.verify(payload("hash"), context.charge), :verification_failed)
    end

    for response <- [
          fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end,
          fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end,
          fn conn -> Req.Test.transport_error(conn, :timeout) end
        ] do
      Req.Test.stub(__MODULE__, response)
      assert_error(XRPL.verify(payload("hash"), context.charge), :verification_failed)
    end
  end

  test "submission failures expose no raw ledger codes", context do
    for result <- [
          %{"engine_result" => "tefPAST_SEQ"},
          %{"engine_result" => "tecUNFUNDED_PAYMENT"},
          %{"engine_result" => "tesSUCCESS"},
          %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => "bad"}}
        ] do
      stub(context, @ledger, submit: result)
      assert_error(XRPL.verify(payload("transaction"), context.charge), :verification_failed)
    end
  end

  test "unknown hashes have a bounded retry budget", context do
    stub(context, %{"error" => "txnNotFound"})
    assert_error(XRPL.verify(payload("hash"), context.charge), :verification_failed)
    assert_received {:rpc, "tx"}
    assert_received {:rpc, "tx"}
    assert_received {:rpc, "tx"}
    refute_received {:rpc, "tx"}
  end

  test "unvalidated ledger cannot produce a receipt, but subsequent validation can", context do
    stub(context, Map.put(@ledger, "validated", false))
    assert_error(XRPL.verify(payload("hash"), config_charge(context, %{"poll_timeout_ms" => 1})), :verification_failed)
    counter = start_supervised!({Agent, fn -> 0 end})

    stub(context, fn ->
      if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0, do: %{"validated" => false}, else: @ledger
    end)

    assert {:ok, _} = XRPL.verify(payload("hash"), context.charge)
  end

  test "store failures and atomic conflicts prevent success", context do
    assert_error(
      XRPL.verify(payload("hash"), config_charge(context, %{"store" => UnavailableStore})),
      :verification_failed
    )

    stub(context, @ledger)
    charge = config_charge(context, %{"store" => FailingCommitStore})
    assert_error(XRPL.verify(payload("hash"), charge), :verification_failed)
    Process.put(:xrpl_commit_error, :already_exists)
    assert_error(XRPL.verify(payload("hash"), charge), :invalid_challenge)
  end

  test "changing hash casing cannot bypass transaction dedup on another challenge", context do
    stub(context, @ledger)
    assert {:ok, _} = XRPL.verify(payload("hash"), context.charge)
    charge = config_charge(context, %{"challenge_id" => "another-challenge", "invoiceId" => @ledger["InvoiceID"]})
    assert_error(XRPL.verify(%{"type" => "hash", "hash" => String.downcase(@hash)}, charge), :invalid_challenge)
  end

  test "concurrent presenters cannot answer the same challenge twice", context do
    owner = self()

    tasks =
      for _n <- 1..2 do
        Task.async(fn ->
          Req.Test.allow(__MODULE__, owner, self())
          send(owner, {:ready, self()})

          receive do
            :go -> XRPL.verify(payload("hash"), context.charge)
          end
        end)
      end

    stub(context, @ledger)

    for task <- tasks do
      assert_receive {:ready, pid}
      assert is_pid(pid)
      send(task.pid, :go)
    end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &match?({:error, %Errors{type: "https://paymentauth.org/problems/invalid-challenge"}}, &1)) ==
             1
  end

  defp config_charge(context, config),
    do: %{context.charge | method_details: Map.merge(context.charge.method_details, config)}

  defp payload("hash"), do: %{"type" => "hash", "hash" => @hash}
  defp payload("transaction"), do: %{"type" => "transaction", "blob" => String.downcase(@blob)}

  defp assert_error(result, type) do
    assert {:error, error} = result
    assert error.type == Errors.new(type, "").type
    refute error.detail =~ "tec"
  end

  defp tx_response(tx) when is_function(tx), do: tx.()
  defp tx_response(tx), do: tx

  defp stub(context, tx, opts \\ []) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => method, "params" => [%{"api_version" => 1}]} = Jason.decode!(body)
      send(context.owner, {:rpc, method})

      result =
        case method do
          "server_info" -> Keyword.get(opts, :network, %{"info" => %{"network_id" => 1}})
          "submit" -> Keyword.get(opts, :submit, %{"engine_result" => "tesSUCCESS", "tx_json" => %{"hash" => @hash}})
          "tx" -> tx_response(tx)
        end

      Req.Test.json(conn, %{"result" => result})
    end)
  end
end
