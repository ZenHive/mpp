defmodule MPP.Test.MppRsHmacOracle do
  @moduledoc """
  Builds a tiny path-dep binary against `refs/mpp-rs` and asks
  `compute_challenge_id_with_header` for a challenge ID.

  Used only by `:cross_validation` tests. Cached under `_build/test`.
  """

  @crate_dir "_build/test/mpp_rs_hmac_oracle"
  @bin_name "mpp_rs_hmac_oracle"
  @challenge_src "refs/mpp-rs/src/protocol/core/challenge.rs"

  @doc """
  Return the mpp-rs HMAC challenge id for the given slots.

  `opts` keys: `:secret`, `:realm`, `:method`, `:intent`, `:request` (required
  binaries) and `:expires`, `:digest`, `:opaque`, `:header` (optional).
  """
  @spec compute_id!(keyword()) :: String.t()
  def compute_id!(opts) when is_list(opts) do
    bin = ensure_built!()

    args = [
      Keyword.fetch!(opts, :secret),
      Keyword.fetch!(opts, :realm),
      Keyword.fetch!(opts, :method),
      Keyword.fetch!(opts, :intent),
      Keyword.fetch!(opts, :request),
      Keyword.get(opts, :expires, ""),
      Keyword.get(opts, :digest, ""),
      Keyword.get(opts, :opaque, ""),
      Keyword.get(opts, :header, "")
    ]

    {output, status} = System.cmd(bin, args, stderr_to_stdout: true)

    if status != 0 do
      raise "mpp-rs HMAC oracle exited #{status}: #{output}"
    end

    String.trim(output)
  end

  defp ensure_built! do
    cargo =
      System.find_executable("cargo") ||
        raise "Missing cargo: install a Rust toolchain to run mpp-rs cross-validation"

    mpp_rs = Path.expand("refs/mpp-rs")

    if !File.dir?(mpp_rs) do
      raise "Missing #{mpp_rs}: clone tempoxyz/mpp-rs into refs/mpp-rs to run mpp-rs cross-validation"
    end

    File.mkdir_p!(@crate_dir)
    write_if_changed!(Path.join(@crate_dir, "Cargo.toml"), cargo_toml(mpp_rs))
    File.mkdir_p!(Path.join(@crate_dir, "src"))
    write_if_changed!(Path.join(@crate_dir, "src/main.rs"), main_rs())

    bin = Path.expand(Path.join([@crate_dir, "target", "release", @bin_name]))

    if stale?(bin) do
      {output, status} =
        System.cmd(cargo, ["build", "--release", "--offline"], cd: @crate_dir, stderr_to_stdout: true)

      {output, status} =
        if status == 0 do
          {output, status}
        else
          System.cmd(cargo, ["build", "--release"], cd: @crate_dir, stderr_to_stdout: true)
        end

      if status != 0 do
        raise "Failed to build mpp-rs HMAC oracle (exit #{status}):\n#{output}"
      end
    end

    if !File.regular?(bin) do
      raise "mpp-rs HMAC oracle binary missing at #{bin}"
    end

    bin
  end

  defp stale?(bin) do
    not File.exists?(bin) or mtime(@challenge_src) > mtime(bin) or
      mtime(Path.join(@crate_dir, "src/main.rs")) > mtime(bin)
  end

  defp write_if_changed!(path, contents) do
    if File.exists?(path) and File.read!(path) == contents do
      :ok
    else
      File.write!(path, contents)
    end
  end

  defp mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _missing -> {{1970, 1, 1}, {0, 0, 0}}
    end
  end

  defp cargo_toml(mpp_rs) do
    """
    [package]
    name = "#{@bin_name}"
    version = "0.0.0"
    edition = "2021"
    publish = false

    [dependencies]
    mpp = { path = #{inspect(mpp_rs)}, default-features = false }
    """
  end

  defp main_rs do
    """
    fn main() {
        let a: Vec<String> = std::env::args().skip(1).collect();
        if a.len() != 9 {
            eprintln!("usage: secret realm method intent request expires digest opaque header");
            std::process::exit(2);
        }
        let id = mpp::compute_challenge_id_with_header(
            &a[0],
            &a[1],
            &a[2],
            &a[3],
            &a[4],
            nonempty(&a[5]),
            nonempty(&a[6]),
            nonempty(&a[7]),
            nonempty(&a[8]),
        );
        println!("{id}");
    }

    fn nonempty(s: &str) -> Option<&str> {
        if s.is_empty() { None } else { Some(s) }
    }
    """
  end
end
