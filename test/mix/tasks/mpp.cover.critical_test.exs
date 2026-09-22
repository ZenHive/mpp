defmodule Mix.Tasks.Mpp.Cover.CriticalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mpp.Cover.Critical

  setup do
    path = Path.join(System.tmp_dir!(), "mpp_cover_critical_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "evaluate/1" do
    test "fails a methods module below 95%" do
      document =
        coverage_document([
          module("MPP.Methods.XRPL.Wallet", "lib/mpp/methods/xrpl/wallet.ex", 82.35, 28, [64, 81, 88, 94, 97, 101])
        ])

      assert {:error, message} = Critical.evaluate(document)
      assert message =~ "money-critical coverage floor 95% failed"
      assert message =~ "MPP.Methods.XRPL.Wallet 82.35% (6 uncovered lines)"
    end

    test "fails a verification-core module below 95%" do
      for {name, file} <- [
            {"MPP.Verifier", "lib/mpp/verifier.ex"},
            {"MPP.Challenge", "lib/mpp/challenge.ex"},
            {"MPP.Credential", "lib/mpp/credential.ex"},
            {"MPP.Headers", "lib/mpp/headers.ex"},
            {"MPP.Headers.SchemeSplitter", "lib/mpp/headers/scheme_splitter.ex"},
            {"MPP.Replay", "lib/mpp/replay.ex"},
            {"MPP.JCS", "lib/mpp/jcs.ex"},
            {"MPP.BodyDigest", "lib/mpp/body_digest.ex"},
            {"MPP.Session.Channel", "lib/mpp/session/channel.ex"}
          ] do
        document = coverage_document([module(name, file, 93.1, 27, [47, 102])])

        assert {:error, message} = Critical.evaluate(document)
        assert message =~ "#{name} 93.1% (2 uncovered lines)"
      end
    end

    test "exempts a behaviour-sized module below 95%" do
      document =
        coverage_document([
          module("MPP.Methods.Tiny", "lib/mpp/methods/tiny.ex", 77.78, 7, [1, 120])
        ])

      assert Critical.evaluate(document) == :ok
    end

    test "does not exempt a larger module just because few lines are uncovered" do
      document =
        coverage_document([
          module("MPP.Methods.Tempo.SignatureEnvelope", "lib/mpp/methods/tempo/signature_envelope.ex", 94.29, 33, [
            49,
            109
          ])
        ])

      assert {:error, message} = Critical.evaluate(document)
      assert message =~ "MPP.Methods.Tempo.SignatureEnvelope 94.29% (2 uncovered lines)"
    end

    test "ignores modules outside the money-critical tier" do
      document =
        coverage_document([
          module("MPP.Client.Transport", "lib/mpp/client/transport.ex", 77.78, 7, [1, 120, 121, 122]),
          module("MPP.Discovery.OpenApi", "lib/mpp/discovery/open_api.ex", 60.0, 60, Enum.to_list(1..40)),
          module("MPP.Demo.Router", "lib/mpp/demo/router.ex", 90.91, 20, [5, 9])
        ])

      assert Critical.evaluate(document) == :ok
    end

    test "passes critical modules at or above the floor" do
      document =
        coverage_document([
          module("MPP.Methods.Stripe", "lib/mpp/methods/stripe.ex", 95.0, 19, [10]),
          module("MPP.Methods.EVM", "lib/mpp/methods/evm.ex", 100, 300, []),
          module("MPP.Verifier", "lib/mpp/verifier.ex", 97.12, 101, [12, 40, 77])
        ])

      assert Critical.evaluate(document) == :ok
    end

    test "treats a critical module missing percentage as 0%" do
      document =
        coverage_document([
          %{
            "module" => "MPP.Methods.Unknown",
            "file" => "lib/mpp/methods/unknown.ex",
            "covered_lines" => 40,
            "uncovered_lines" => [1, 2, 3]
          }
        ])

      assert {:error, message} = Critical.evaluate(document)
      assert message =~ "MPP.Methods.Unknown 0% (3 uncovered lines)"
    end

    test "fails a below-floor critical module whose entry lacks the line counts" do
      for entry <- [
            %{"module" => "MPP.Methods.Schema", "file" => "lib/mpp/methods/schema.ex", "percentage" => 50.0},
            %{
              "module" => "MPP.Methods.Schema",
              "file" => "lib/mpp/methods/schema.ex",
              "percentage" => 50.0,
              "uncovered_lines" => [1]
            },
            %{
              "module" => "MPP.Methods.Schema",
              "file" => "lib/mpp/methods/schema.ex",
              "percentage" => 50.0,
              "covered_lines" => "1",
              "uncovered_lines" => [1]
            }
          ] do
        assert {:error, message} = Critical.evaluate(coverage_document([entry]))
        assert message =~ "MPP.Methods.Schema 50.0%"
      end
    end

    test "fails loudly when the document carries no coverage.modules" do
      assert {:error, message} = Critical.evaluate(%{"summary" => %{"result" => "passed"}})
      assert message =~ "missing coverage.modules"

      assert {:error, _} = Critical.evaluate(%{"coverage" => %{"total_percentage" => 97.5}})
    end

    test "ignores entries without a file path" do
      document =
        coverage_document([
          %{"module" => "MPP.Methods.Ghost", "percentage" => 10, "covered_lines" => 1, "uncovered_lines" => [1, 2, 3]}
        ])

      assert Critical.evaluate(document) == :ok
    end
  end

  describe "critical_prefixes/0" do
    test "every prefix resolves to real source under lib/" do
      for prefix <- Critical.critical_prefixes() do
        assert File.exists?(prefix), "#{prefix} does not exist under lib/"
      end
    end
  end

  describe "run/1" do
    setup do
      previous_shell = Mix.shell()
      Mix.shell(Mix.Shell.IO)
      on_exit(fn -> Mix.shell(previous_shell) end)
      :ok
    end

    test "raises with the module name and percentage for a lowered critical module", %{path: path} do
      write_coverage!(path, [
        module("MPP.Methods.Tempo.HostedFeePayer", "lib/mpp/methods/tempo/hosted_fee_payer.ex", 89.74, 70, [
          29,
          87,
          94,
          95,
          182,
          209,
          212,
          226
        ])
      ])

      capture_io(fn ->
        assert_raise Mix.Error, ~r/MPP.Methods.Tempo.HostedFeePayer 89.74% \(8 uncovered lines\)/, fn ->
          Critical.run([path])
        end
      end)
    end

    test "succeeds when every critical module meets the floor", %{path: path} do
      write_coverage!(path, [module("MPP.Methods.Stripe", "lib/mpp/methods/stripe.ex", 97.5, 39, [])])

      output = capture_io(fn -> assert Critical.run([path]) == :ok end)
      assert output =~ "money-critical modules at or above 95%"
      # --output sends the suite JSON to a file, so the gate echoes the headline
      # numbers and the path that holds the per-test failure detail.
      assert output =~ "10 passed, 0 failed, 2 excluded"
      assert output =~ "aggregate 95.98%"
      assert output =~ "suite JSON: #{path}"
    end

    test "raises when the coverage file is missing" do
      missing = Path.join(System.tmp_dir!(), "mpp_cover_critical_missing_#{System.unique_integer([:positive])}.json")

      assert_raise Mix.Error, ~r/cannot read/, fn ->
        Critical.run([missing])
      end
    end

    test "raises when the coverage file is not JSON", %{path: path} do
      File.write!(path, "not-json")

      assert_raise Mix.Error, ~r/not valid JSON/, fn ->
        Critical.run([path])
      end
    end

    test "raises when the coverage file is a JSON array", %{path: path} do
      File.write!(path, "[]")

      assert_raise Mix.Error, ~r/not a JSON object/, fn ->
        Critical.run([path])
      end
    end
  end

  describe "precommit alias" do
    test "reuses the test.json coverage file and does not run a second suite" do
      precommit = Mix.Project.config()[:aliases][:precommit]
      test_steps = Enum.filter(precommit, &(is_binary(&1) and String.contains?(&1, "test.json")))

      assert [_test_json] = test_steps
      assert hd(test_steps) =~ "--output _build/test/cover.json"
      assert "mpp.cover.critical" in precommit

      refute Enum.any?(
               precommit,
               &(is_binary(&1) and String.contains?(&1, "test.json") and String.contains?(&1, "mpp.cover"))
             )
    end

    test "is folded into mix ci via precommit.full" do
      aliases = Mix.Project.config()[:aliases]
      assert aliases[:ci] == ["precommit.full"]
      assert List.first(aliases[:"precommit.full"]) == "precommit"
    end
  end

  defp write_coverage!(path, modules) do
    File.write!(path, Jason.encode!(coverage_document(modules)))
  end

  defp coverage_document(modules) do
    %{
      "summary" => %{"result" => "passed", "passed" => 10, "failed" => 0, "excluded" => 2},
      "coverage" => %{
        "total_percentage" => 95.98,
        "threshold_met" => true,
        "modules" => modules
      }
    }
  end

  defp module(name, file, percentage, covered_lines, uncovered_lines) do
    %{
      "module" => name,
      "file" => file,
      "percentage" => percentage,
      "covered_lines" => covered_lines,
      "uncovered_lines" => uncovered_lines
    }
  end
end
