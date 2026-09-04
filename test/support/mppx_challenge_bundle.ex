defmodule MPP.Test.MppxChallengeBundle do
  @moduledoc """
  Bundles mppx's `Challenge.serialize`/`deserialize` into a QuickBEAM-loadable
  IIFE via esbuild, for cross-validating the `\\uXXXX` non-Latin-1 auth-param
  escape (mppx #813) against `MPP.Headers`.

  Same esbuild-over-OXC rationale as `MPP.Test.OxTempoBundle`: mppx's
  `Challenge.ts` pulls in `zod` and `ox`, which OXC's bundler can't cleanly
  resolve into an IIFE.

  The bundle is cached to `_build/test/mppx_challenge_bundle.js` and only
  rebuilt when the entry point or the mppx source changes.
  """

  @entry_point "test/support/mppx_challenge_entry.mjs"
  @cache_path "_build/test/mppx_challenge_bundle.js"
  @mppx_source "refs/mppx/src/Challenge.ts"

  @doc """
  Returns the bundled JS source, building it if needed.

  Requires `npx` + `esbuild` (auto-installed by npx on first run) and the
  `zod`/`ox` npm packages the mppx source imports (`mix npm.install`).
  """
  @spec get_bundle!() :: String.t()
  def get_bundle! do
    if stale?() do
      build!()
    else
      File.read!(@cache_path)
    end
  end

  @doc """
  Loads the mppx Challenge bundle into a QuickBEAM runtime.

  After this call, `mppxSerialize(challenge)` and `mppxDeserialize(header)`
  are available as flat globals in the runtime (`QuickBEAM.call/3` resolves a
  bare global name only, not a dotted `MppxChallenge.serialize` path).

  Note: the bundle is generated from our own entry point by esbuild — not
  arbitrary user input — so evaluating it directly is safe here.
  """
  @spec load!(pid()) :: :ok
  def load!(rt) do
    bundle = get_bundle!()
    {:ok, _} = QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
    {:ok, _} = QuickBEAM.call(rt, "eval", [bundle])

    {:ok, _} =
      QuickBEAM.eval(
        rt,
        "globalThis.mppxSerialize = (c) => MppxChallenge.serialize(c); " <>
          "globalThis.mppxDeserialize = (h) => MppxChallenge.deserialize(h); 1"
      )

    :ok
  end

  defp stale? do
    not File.exists?(@cache_path) or
      mtime(@entry_point) > mtime(@cache_path) or
      mtime(@mppx_source) > mtime(@cache_path) or
      mtime("node_modules/zod/package.json") > mtime(@cache_path)
  end

  defp mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> {{2099, 1, 1}, {0, 0, 0}}
    end
  end

  defp build! do
    File.mkdir_p!(Path.dirname(@cache_path))

    {output, exit_code} =
      System.cmd("npx", [
        "esbuild",
        @entry_point,
        "--bundle",
        "--format=iife",
        "--platform=browser",
        "--target=es2020",
        "--outfile=#{@cache_path}"
      ])

    if exit_code != 0 do
      raise """
      Failed to bundle mppx Challenge with esbuild (exit #{exit_code}):

      #{output}

      Ensure npx is available and node_modules/zod + node_modules/ox are installed:
        mix npm.install
      """
    end

    File.read!(@cache_path)
  end
end
