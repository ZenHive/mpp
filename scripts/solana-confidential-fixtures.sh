#!/usr/bin/env bash
#
# Regenerate the SOLANA_CONFIDENTIAL_* fixtures for the "confidential bundle
# profile" tests in test/mpp/methods/solana_integration_test.exs and run them
# live against Solana devnet.
#
# The heavy lifting (Token-2022 confidential-transfer proof generation) lives in
# the Rust crate next to this script; everything below is plumbing.
#
#   ./scripts/solana-confidential-fixtures.sh setup
#       One-off devnet state: a Token-2022 mint with the ConfidentialTransfer
#       extension, a recipient confidential account, and two funded sender
#       confidential accounts (one per bundle — each bundle's proofs are bound
#       to its sender's balance ciphertext, so they cannot share a sender).
#       Writes the stable exports, including the recipient ElGamal secret, to
#       ~/.config/solana/mpp-confidential/exports.env (mode 600).
#
#   ./scripts/solana-confidential-fixtures.sh secrets
#       Append/refresh those stable exports in ~/.secrets.
#
#   ./scripts/solana-confidential-fixtures.sh bundles
#       Print the two `export …_BUNDLE_JSON=…` lines for the current blockhash.
#       Bundles are only valid while that blockhash is (~60-90 s on devnet), so
#       this must run immediately before the test.
#
#   ./scripts/solana-confidential-fixtures.sh bundles-json
#       The same pair as a JSON object. Point the test at it with
#       SOLANA_CONFIDENTIAL_BUNDLE_CMD so each confidential test mints its own
#       bundles — one `mix test` run of the whole file otherwise outlives the
#       blockhash of whichever test goes second.
#
#   ./scripts/solana-confidential-fixtures.sh confidential [--output-dir DIR]
#       Run the two confidential tests, each against freshly generated bundles,
#       with a cooldown in between. This is the invocation to use: public
#       devnet caps sendTransaction at 10 calls per rate-limit window and one
#       bundle costs five, so running both tests back to back in a single
#       `mix test` reliably 429s on the second one.
#
#   ./scripts/solana-confidential-fixtures.sh test [mix test args…]
#       Regenerate both bundles and hand them to one `mix test.json` run.
#
# Requires SOLANA_RPC_URL and SOLANA_PRIVATE_KEY (`set -a; source ~/.secrets;
# set +a`). Nothing here ever prints the payer key.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
crate="$root/scripts/solana_confidential_fixtures"
bin="$crate/target/release/mpp-solana-confidential-fixtures"
state_dir="${MPP_CONFIDENTIAL_DIR:-$HOME/.config/solana/mpp-confidential}"
exports_env="$state_dir/exports.env"
test_file="test/mpp/methods/solana_integration_test.exs"
# Line numbers are resolved at runtime so the script survives edits above them.
cooldown="${MPP_CONFIDENTIAL_COOLDOWN:-120}"

log() { printf '%s\n' "$*" >&2; }

require_credentials() {
  : "${SOLANA_RPC_URL:?set SOLANA_RPC_URL (set -a; source ~/.secrets; set +a)}"
  : "${SOLANA_PRIVATE_KEY:?set SOLANA_PRIVATE_KEY (set -a; source ~/.secrets; set +a)}"
}

build() {
  if [ ! -x "$bin" ] || [ "$crate/src/main.rs" -nt "$bin" ]; then
    log "• building the fixture generator (cargo build --release)"
    cargo build --release --manifest-path "$crate/Cargo.toml" >&2
  fi
}

load_stable_exports() {
  if [ -z "${SOLANA_CONFIDENTIAL_MINT:-}" ]; then
    [ -f "$exports_env" ] || {
      log "missing $exports_env — run '$0 setup' first"
      exit 1
    }
    set -a
    # shellcheck disable=SC1090
    . "$exports_env"
    set +a
  fi
}

load_bundles() {
  local generated
  generated="$("$bin" bundles)"
  set -a
  eval "$generated"
  set +a
}

test_line() {
  grep -n "$1" "$root/$test_file" | cut -d: -f1
}

case "${1:-confidential}" in
  setup)
    require_credentials
    build
    "$bin" setup
    log ""
    log "Next: ./scripts/solana-confidential-fixtures.sh secrets   # persist the stable exports"
    ;;

  status)
    require_credentials
    build
    "$bin" status
    ;;

  secrets)
    [ -f "$exports_env" ] || {
      log "missing $exports_env — run '$0 setup' first"
      exit 1
    }
    secrets="$HOME/.secrets"
    touch "$secrets"
    chmod 600 "$secrets"
    tmp="$(mktemp)"
    grep -vE '^export SOLANA_CONFIDENTIAL_(MINT|RECIPIENT|ELGAMAL_SECRET_KEY|AMOUNT|DECIMALS)=' \
      "$secrets" >"$tmp" || true
    {
      cat "$tmp"
      printf '\n# MPP Token-2022 confidential-transfer devnet fixtures (scripts/solana-confidential-fixtures.sh)\n'
      cat "$exports_env"
    } >"$secrets"
    rm -f "$tmp"
    chmod 600 "$secrets"
    log "• refreshed the SOLANA_CONFIDENTIAL_* entries in $secrets (values not printed)"
    ;;

  bundles | bundles-json)
    require_credentials
    build
    load_stable_exports
    "$bin" "$1"
    ;;

  test)
    shift || true
    require_credentials
    build
    load_stable_exports
    load_bundles
    cd "$root"
    exec mix test.json "$test_file" --include integration "$@"
    ;;

  confidential)
    shift || true
    output_dir="${1:-/tmp}"
    require_credentials
    build
    load_stable_exports
    cd "$root"

    success_line="$(test_line 'test "settles a real Token-2022 confidential transfer bundle"')"
    wrong_line="$(test_line 'test "rejects a real confidential bundle whose credited amount differs"')"
    status=0

    for pair in "settles:$success_line:$output_dir/sol-confidential-success.json" \
      "rejects:$wrong_line:$output_dir/sol-confidential-wrong-amount.json"; do
      label="${pair%%:*}"
      rest="${pair#*:}"
      line="${rest%%:*}"
      output="${rest#*:}"

      log "• regenerating bundles for the '$label' test"
      load_bundles
      mix test.json "$test_file:$line" --include integration --output "$output" || status=1
      log "  -> $output"

      if [ "$label" = "settles" ]; then
        log "• cooling down ${cooldown}s for the devnet sendTransaction rate limit"
        sleep "$cooldown"
      fi
    done
    exit "$status"
    ;;

  *)
    log "usage: $0 {setup|secrets|status|bundles|bundles-json|confidential [OUTPUT_DIR]|test [mix args…]}"
    exit 64
    ;;
esac
