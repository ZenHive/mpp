defmodule Mix.Tasks.Mpp.ManifestTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mpp.Manifest

  setup do
    path = Path.join(System.tmp_dir!(), "mpp_test_manifest_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, output: path}
  end

  describe "mix mpp.manifest" do
    test "generates a valid JSON manifest file", %{output: path} do
      Manifest.run([path])

      assert File.exists?(path)
      json = File.read!(path)
      assert {:ok, manifest} = Jason.decode(json)

      assert manifest["version"] == "1.0"
      assert is_binary(manifest["generated_at"])
    end

    test "includes all annotated modules", %{output: path} do
      manifest = generate_manifest(path)
      module_names = Enum.map(manifest["modules"], & &1["module"])

      expected_modules = Enum.map(MPP.__descripex_modules__(), &inspect/1)

      for mod <- expected_modules do
        assert mod in module_names, "#{mod} missing from manifest"
      end
    end

    test "each module has functions with hints metadata", %{output: path} do
      manifest = generate_manifest(path)

      for mod <- manifest["modules"] do
        assert is_list(mod["functions"]), "#{mod["module"]} missing functions list"
        assert mod["functions"] != [], "#{mod["module"]} has empty functions list"

        for func <- mod["functions"] do
          assert is_map(func["hints"]), "#{mod["module"]}.#{func["name"]} missing hints"
          assert is_binary(func["hints"]["description"]), "#{mod["module"]}.#{func["name"]} missing hints.description"
        end
      end
    end

    test "modules have correct namespaces", %{output: path} do
      manifest = generate_manifest(path)
      namespaces = Map.new(manifest["modules"], fn m -> {m["module"], m["namespace"]} end)

      assert namespaces["MPP.Challenge"] == "/protocol"
      assert namespaces["MPP.Headers"] == "/protocol"
      assert namespaces["MPP.Intents.Charge"] == "/intents"
      assert namespaces["MPP.Methods.Stripe"] == "/methods"
    end
  end

  defp generate_manifest(path) do
    Manifest.run([path])
    path |> File.read!() |> Jason.decode!()
  end
end
