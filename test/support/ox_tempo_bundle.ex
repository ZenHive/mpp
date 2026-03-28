defmodule MPP.Test.OxTempoBundle do
  @moduledoc """
  Bundles ox/tempo TxEnvelopeTempo into a QuickBEAM-loadable IIFE via esbuild.

  OXC's bundler can't produce a clean IIFE for ox because it mixes ESM and CJS
  resolution for `@noble/*` dependencies, causing `let`/`const` redefinition
  errors in QuickJS's strict mode. esbuild resolves everything via ESM export
  conditions, producing a clean IIFE with proper nested scoping.

  The bundle is cached to `_build/test/ox_tempo_bundle.js` and only rebuilt
  when the entry point or ox package version changes.
  """

  @entry_point "test/support/ox_tempo_entry.mjs"
  @cache_path "_build/test/ox_tempo_bundle.js"

  @doc """
  Returns the bundled JS source, building it if needed.

  Requires `npx` and `esbuild` to be available (esbuild is auto-installed
  by npx on first run).
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
  Loads the ox/tempo bundle into a QuickBEAM runtime.

  Sets up browser globals (`self`, `window`) and loads the IIFE bundle.
  After this call, `TxET.deserialize(hex)` and `TxET.serialize(envelope)`
  are available in the runtime.

  Note: The bundle is an IIFE that assigns to `globalThis.TxET`. Loading it
  via `QuickBEAM.call(rt, "eval", [bundle])` is safe here because the bundle
  is generated from our own entry point by esbuild — not arbitrary user input.
  """
  @spec load!(pid()) :: :ok
  def load!(rt) do
    bundle = get_bundle!()
    {:ok, _} = QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
    # Load the esbuild IIFE bundle — assigns TxET to globalThis.
    # This is a trusted, locally-generated bundle, not user input.
    {:ok, _} = QuickBEAM.call(rt, "eval", [bundle])
    :ok
  end

  # Checks if the cached bundle exists and is newer than the entry point
  # and the ox package.json (proxy for version changes).
  defp stale? do
    not File.exists?(@cache_path) or
      mtime(@entry_point) > mtime(@cache_path) or
      mtime("node_modules/ox/package.json") > mtime(@cache_path)
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
      Failed to bundle ox/tempo with esbuild (exit #{exit_code}):

      #{output}

      Ensure npx is available and node_modules/ox is installed:
        mix npm.install
      """
    end

    File.read!(@cache_path)
  end
end
