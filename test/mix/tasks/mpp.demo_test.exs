defmodule Mix.Tasks.Mpp.DemoTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mpp.Demo

  describe "run/1" do
    test "raises on invalid --port value" do
      assert_raise Mix.Error, ~r/Invalid option: --port foo/, fn ->
        Demo.run(["--port", "foo"])
      end
    end

    test "raises when Bandit is unavailable" do
      # Bandit is only: :dev, not available in :test env
      # run/1 calls check_bandit! first, which should Mix.raise
      assert_raise Mix.Error, ~r/Bandit is required/, fn ->
        Demo.run([])
      end
    end
  end
end
