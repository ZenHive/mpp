defmodule MPP.DescripexTest do
  use ExUnit.Case, async: true

  alias MPP.Intents.Charge
  alias MPP.Methods.Stripe

  @annotated_modules [
    MPP.Challenge,
    MPP.Credential,
    MPP.Receipt,
    MPP.Headers,
    MPP.Errors,
    Charge,
    Stripe
  ]

  describe "api() annotations" do
    for mod <- @annotated_modules do
      test "#{inspect(mod)} has __api__/0 with hints for all declared functions" do
        mod = unquote(mod)
        entries = mod.__api__()

        assert is_list(entries), "#{inspect(mod)}.__api__() should return a list"
        assert entries != [], "#{inspect(mod)}.__api__() should not be empty"

        for entry <- entries do
          assert is_map(entry.hints), "#{inspect(mod)}.#{entry.name}/#{entry.arity} missing :hints"

          assert is_binary(entry.hints.description),
                 "#{inspect(mod)}.#{entry.name}/#{entry.arity} missing hints.description"
        end
      end
    end

    test "all public functions in annotated modules have hints metadata" do
      for mod <- @annotated_modules do
        api_entries = mod.__api__()
        api_names = MapSet.new(api_entries, & &1.name)

        # Get all public functions excluding __api__, describe, and __descripex_modules__
        {_, exported} =
          :exports
          |> mod.module_info()
          |> Enum.split_with(fn {name, _} ->
            name in [:module_info, :__info__, :__api__, :__struct__, :describe, :__descripex_modules__, :behaviour_info]
          end)

        for {func_name, _arity} <- exported do
          assert MapSet.member?(api_names, func_name),
                 "#{inspect(mod)}.#{func_name} is exported but not declared with api()"
        end
      end
    end
  end

  describe "Discoverable (MPP.describe/0-2)" do
    test "describe/0 returns overview of all annotated modules" do
      overview = MPP.describe()

      assert is_list(overview)
      assert length(overview) == length(@annotated_modules)

      module_names = Enum.map(overview, & &1.module)

      for mod <- @annotated_modules do
        assert mod in module_names, "#{inspect(mod)} missing from MPP.describe()"
      end
    end

    test "describe/1 with short name returns function list" do
      functions = MPP.describe(:challenge)

      assert is_list(functions)
      func_names = Enum.map(functions, & &1.name)
      assert :create in func_names
      assert :verify in func_names
    end

    test "describe/1 with full module name works" do
      functions = MPP.describe(MPP.Challenge)

      assert is_list(functions)
      func_names = Enum.map(functions, & &1.name)
      assert :create in func_names
    end

    test "describe/2 returns full function detail" do
      detail = MPP.describe(:challenge, :create)

      assert is_map(detail)
      assert detail.name == :create
      assert detail.arity == 2
      assert is_binary(detail.description)
      assert is_map(detail.params)
      assert Map.has_key?(detail.params, :params)
      assert Map.has_key?(detail.params, :secret_key)
    end

    test "describe/2 returns nil for unknown function" do
      assert MPP.describe(:challenge, :nonexistent) == nil
    end

    test "__descripex_modules__/0 returns the module list" do
      modules = MPP.__descripex_modules__()
      assert modules == @annotated_modules
    end
  end

  describe "namespace assignment" do
    test "protocol modules have /protocol namespace" do
      for mod <- [MPP.Challenge, MPP.Credential, MPP.Receipt, MPP.Headers, MPP.Errors] do
        {:docs_v1, _, _, _, _moduledoc, meta, _} = Code.fetch_docs(mod)

        assert meta[:namespace] == "/protocol",
               "#{inspect(mod)} should have namespace /protocol, got #{inspect(meta[:namespace])}"
      end
    end

    test "intent modules have /intents namespace" do
      {:docs_v1, _, _, _, _, meta, _} = Code.fetch_docs(Charge)
      assert meta[:namespace] == "/intents"
    end

    test "method modules have /methods namespace" do
      {:docs_v1, _, _, _, _, meta, _} = Code.fetch_docs(Stripe)
      assert meta[:namespace] == "/methods"
    end
  end
end
