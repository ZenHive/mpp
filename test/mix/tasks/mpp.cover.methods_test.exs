defmodule Mix.Tasks.Mpp.Cover.MethodsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mpp.Cover.Methods

  setup do
    path = Path.join(System.tmp_dir!(), "mpp_cover_methods_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "evaluate/1" do
    test "fails a methods module below 95% with more than two uncovered lines" do
      document =
        coverage_document([
          module("MPP.Methods.XRPL.Wallet", "lib/mpp/methods/xrpl/wallet.ex", 82.35, [64, 81, 88, 94, 97, 101])
        ])

      assert {:error, message} = Methods.evaluate(document)
      assert message =~ "lib/mpp/methods/ coverage floor 95% failed"
      assert message =~ "MPP.Methods.XRPL.Wallet 82.35% (6 uncovered lines)"
    end

    test "allows a methods module below 95% with at most two uncovered lines" do
      document =
        coverage_document([
          module("MPP.Methods.Tiny", "lib/mpp/methods/tiny.ex", 77.78, [1, 120])
        ])

      assert Methods.evaluate(document) == :ok
    end

    test "ignores modules outside lib/mpp/methods/" do
      document =
        coverage_document([
          module("MPP.Client.Transport", "lib/mpp/client/transport.ex", 77.78, [1, 120, 121, 122])
        ])

      assert Methods.evaluate(document) == :ok
    end

    test "passes methods modules at or above the floor" do
      document =
        coverage_document([
          module("MPP.Methods.Stripe", "lib/mpp/methods/stripe.ex", 95.0, [10]),
          module("MPP.Methods.EVM", "lib/mpp/methods/evm.ex", 100, [])
        ])

      assert Methods.evaluate(document) == :ok
    end

    test "treats a methods module missing percentage as 0%" do
      document =
        coverage_document([
          %{
            "module" => "MPP.Methods.Unknown",
            "file" => "lib/mpp/methods/unknown.ex",
            "uncovered_lines" => [1, 2, 3]
          }
        ])

      assert {:error, message} = Methods.evaluate(document)
      assert message =~ "MPP.Methods.Unknown 0% (3 uncovered lines)"
    end

    test "fails a methods module whose entry has no uncovered_lines key" do
      document =
        coverage_document([
          %{"module" => "MPP.Methods.Schema", "file" => "lib/mpp/methods/schema.ex", "percentage" => 50.0}
        ])

      assert {:error, message} = Methods.evaluate(document)
      assert message =~ "MPP.Methods.Schema 50.0%"
    end

    test "fails loudly when the document carries no coverage.modules" do
      assert {:error, message} = Methods.evaluate(%{"summary" => %{"result" => "passed"}})
      assert message =~ "missing coverage.modules"

      assert {:error, _} = Methods.evaluate(%{"coverage" => %{"total_percentage" => 97.5}})
    end

    test "ignores entries without a file path" do
      document =
        coverage_document([%{"module" => "MPP.Methods.Ghost", "percentage" => 10, "uncovered_lines" => [1, 2, 3]}])

      assert Methods.evaluate(document) == :ok
    end
  end

  describe "run/1" do
    test "raises with the module name and percentage for a lowered methods module", %{path: path} do
      write_coverage!(path, [
        module("MPP.Methods.Tempo.HostedFeePayer", "lib/mpp/methods/tempo/hosted_fee_payer.ex", 89.74, [
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
          Methods.run([path])
        end
      end)
    end

    test "succeeds when every methods module meets the floor", %{path: path} do
      write_coverage!(path, [module("MPP.Methods.Stripe", "lib/mpp/methods/stripe.ex", 97.5, [])])

      output = capture_io(fn -> assert Methods.run([path]) == :ok end)
      assert output =~ "lib/mpp/methods/ modules at or above 95%"
      # --output sends the suite JSON to a file, so the gate echoes the headline
      # numbers and the path that holds the per-test failure detail.
      assert output =~ "10 passed, 0 failed, 2 excluded"
      assert output =~ "aggregate 95.98%"
      assert output =~ "suite JSON: #{path}"
    end

    test "raises when the coverage file is missing" do
      missing = Path.join(System.tmp_dir!(), "mpp_cover_methods_missing_#{System.unique_integer([:positive])}.json")

      assert_raise Mix.Error, ~r/cannot read/, fn ->
        Methods.run([missing])
      end
    end

    test "raises when the coverage file is not JSON", %{path: path} do
      File.write!(path, "not-json")

      assert_raise Mix.Error, ~r/not valid JSON/, fn ->
        Methods.run([path])
      end
    end

    test "raises when the coverage file is a JSON array", %{path: path} do
      File.write!(path, "[]")

      assert_raise Mix.Error, ~r/not a JSON object/, fn ->
        Methods.run([path])
      end
    end
  end

  describe "precommit alias" do
    test "reuses the test.json coverage file and does not run a second suite" do
      precommit = Mix.Project.config()[:aliases][:precommit]
      test_steps = Enum.filter(precommit, &(is_binary(&1) and String.contains?(&1, "test.json")))

      assert [_test_json] = test_steps
      assert hd(test_steps) =~ "--output _build/test/cover.json"
      assert "mpp.cover.methods" in precommit

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

  defp module(name, file, percentage, uncovered_lines) do
    %{
      "module" => name,
      "file" => file,
      "percentage" => percentage,
      "uncovered_lines" => uncovered_lines
    }
  end
end
