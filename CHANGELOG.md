# Changelog

All notable changes to this project will be documented in this file.

Per-task history (acceptance criteria, scoring, decision notes) lives in `roadmap/tasks.toml` — query with `rmap show <id>` or read `roadmap/data.json`. This file is curated release notes only.

---

## [Unreleased]

## [0.12.0] — 2026-08-02

### Security — aggregate budgets for Tempo fee sponsorship

Tempo fee sponsorship now enforces configurable aggregate in-flight fee and
reservation ceilings across concurrent requests. Reservations are tracked
atomically through preparation, broadcast, and receipt confirmation, with
conservative expiry and optional bounded receipt reconciliation. Capacity
responses remain payable HTTP 402 / MCP payment-required responses and include
retry timing without exposing configured limits.

**Breaking:** Every Tempo configuration that enables local or hosted fee
sponsorship must now explicitly select an atomic `"store"` implementing
`MPP.Tempo.Store.update/3`. Configurations that relied on the app-started default
store now fail validation at initialization. Single-node deployments can select
`MPP.Tempo.ConCacheStore`; horizontally scaled deployments must select one shared
atomic backend for every node sponsoring the same wallet. Hosted sponsorship
must also provide a stable, non-empty `"sponsor_budget_id"` shared by every
endpoint for that wallet.

## [0.11.0] — 2026-07-31

### Changed — CI runs `mix ci`, and the security audit can no longer pass vacuously

`.github/workflows/ci.yml` invokes the `mix ci` (= `mix precommit.full`) alias
instead of a hand-maintained step list, so CI and local dev share one gate
definition. Three properties of that gate needed shoring up before the shared
definition was trustworthy:

- **`deps.audit` runs last.** mix_audit signals a finding with `System.stop(1)`,
  which is asynchronous — it returns, the alias proceeds, and the concurrent VM
  shutdown truncates the next step. Exit status was always non-zero, but the log
  showed an aborted dialyzer instead of the vulnerability report.
- **`deps.audit.gated` proves the mirror was populated.** `MixAudit.Repo` discards
  its clone/pull exit status, so a failed sync yields zero advisories and a
  passing report. The freshness prover catches that on the developer host but is
  a host script that skips on CI — precisely where a rate-limited clone would
  have produced a green "No vulnerabilities found." over nothing. The gate now
  also rejects a `MIX_AUDIT_ADVISORY_PATH` that diverges from `MixAudit.Repo`'s
  hardcoded path (the prover honours the variable; the audit does not), and fails
  if `cowboy` enters `mix.lock` while `.mix_audit_ignore` still ignores
  GHSA-w4f7-4cxr-rv3c — `--ignore-file` takes advisory IDs only, never a package
  scope, and that advisory is genuine for cowboy `< 2.16.0`.
- **`reach.check` is pinned to `--path lib`.** Reach auto-discovers roots via
  `*/lib` + `*/src` wildcards, which picks up gitignored sibling checkouts
  (`mpp-docs-fork/src`) that don't exist on a runner. With `smells: [strict: true]`
  now gating, an unpinned scope would have graded different file sets locally and
  in CI.

Host-script skips also print via `IO.puts` rather than `Mix.shell().info/1`,
which `dialyzer.json --quiet` had silenced for the remainder of the run, and the
"is this runnable" guard is an executable-bit check rather than `File.exists?/1`
(true for directories and non-executable files, which raised an opaque
`ErlangError :enoent`).

### Changed — `{:descripex, "~> 0.11"}` → `{:descripex, "~> 0.12.0"}`

descripex 0.12.0 changed `short_name` in `describe/1` output from an atom to a
string — a consumer-visible contract change shipped at a *minor* bump, which the
old two-segment `~> 0.11` (`>= 0.11.0 and < 1.0.0`) would have absorbed on any
fresh resolution. The requirement is now three-segment (`< 0.13.0`); a 0.x
package that breaks on minor earns the tighter form, and the cap gets raised
deliberately after reading its release notes.

mpp does not read `short_name` — nothing in `lib/` or `test/` references it, and
the full suite (1061 tests) is green against descripex 0.12.0 with no code
change. The break is in the *bound*, not the behaviour. This release was already
a minor for other reasons, so the narrowing costs no extra version step.

### Changed — self-caps removed; `styler` 1.11.0 → 1.12.2

`{:styler, "~> 1.11.0"}` and `{:ex_ast, "~> 0.12.0"}` were three-segment
self-caps blocking their own minor lines for no reason beyond how the bounds
were written. Both dev/test only, so no effect on the published package. styler
now resolves 1.12.2; ex_ast resolves 0.12.10 because `reach 2.8.2` declares
`ex_ast ~> 0.12.0`. That transitive requirement is a choice rather than a wall —
`override: true` gets past it, as cartouche does — but the override is
unmeasured here: ex_ast 0.13.0 changed pattern-matching semantics (map patterns
became subset matching) and reach's smell checks are built on those patterns, so
it could quietly report fewer findings. `req` resolves to 0.7.2.

styler 1.12 rewrote 19 lines of time arithmetic, `DateTime.add(dt, n, :second)`
→ `DateTime.shift(dt, second: n)` (normalised to `minute:`/`hour:` where the
literal allowed). These are **not** unconditionally equivalent — `shift/2` is
calendar-aware and re-resolves the time zone, so on a DST zone it can differ
from absolute-time addition. Every call site in `MPP.Expires` and `MPP.Plug`
starts from `DateTime.utc_now/0`, and UTC has no DST, so the rewrite is safe
here. Worth stating explicitly because the *tests* were rewritten the same way,
which means a green suite alone would not have proven it.

### Changed — dependency floors raised so the req 0.7 lift actually lands

- `{:onchain, "~> 0.10"}` → `{:onchain, "~> 0.11"}` and
  `{:onchain_tempo, "~> 0.7"}` → `{:onchain_tempo, "~> 0.8"}`. Those are the
  releases that carry `cartouche ~> 0.6`, which is what lifts cartouche's
  transitive `req < 0.7` cap. The previous two-segment bounds already
  *permitted* the new versions but did not *require* them — and a lockfile entry
  that still satisfies its bound is never re-resolved, so a consumer sitting on
  onchain 0.10.0 would have gone on resolving cartouche 0.5.x, and therefore
  req 0.6.x, through any number of `mix deps.get` runs. Raising the floors
  invalidates the stale entries so the upgrade happens without anyone having to
  know to run `mix deps.update`.
- `{:descripex, "~> 0.9"}` → `{:descripex, "~> 0.11"}`, matching what cartouche
  0.6 already forces.

Resolves to onchain 0.11.0, onchain_tempo 0.8.0, cartouche 0.6.0,
descripex 0.11.0, req 0.7.1. Compiles `--warnings-as-errors` clean; 1061 offline
tests pass (2 doctests, 13 properties).

**Session intent schema.** Added `MPP.Intents.Session` — pay-as-you-go / metered session request schema parallel to `MPP.Intents.Charge`, with `new/1` validation, camelCase `to_request/1` / `from_request/1` matching mpp-rs `SessionRequest` (`unitType`, `suggestedDeposit`, `methodDetails`; transient `decimals` / `external_id` stripped from wire — mpp-rs session has no `externalId`). `MPP.Method` callbacks now accept `MPP.Method.intent()` (`Charge.t() | Session.t()`).

**MCP server transport adapter (Task 32b).** `MPP.Mcp` is now a mountable server-side transport, not just constants and helpers: `MPP.Mcp.init/1` accepts the same endpoint options as `MPP.Plug`, and `MPP.Mcp.call/3` runs a JSON-RPC request through payment verification before invoking the handler — reading the credential from `params._meta["org.paymentauth/credential"]`, emitting `-32042` payment-required / `-32602` malformed-credential / `-32043` verification-failed errors with challenges and RFC 9457 problem details (mppx `mcpErrorCode` parity), and attaching the receipt (+ `challengeId`) to `result._meta` on success. Challenge generation is shared with `MPP.Plug`, so both transports emit byte-identical challenges from the same config.

**Credential replay dedup shared across transports (`MPP.Replay`).** The plug-level credential single-use dedup (key `mpp:credential:<challenge-id>:<payload-hash>`, Tempo carve-out, atomic `check_and_mark/2` only — GHSA-w8j7-7qc3-5f24) moved to an internal `MPP.Replay` module used by both `MPP.Plug` and the MCP transport, so a verified MCP credential cannot be replayed across JSON-RPC requests for store-backed methods.

**Stripe Connect settlement options (Task 52).** `MPP.Methods.Stripe` accepts an optional server-only `"connect"` map in `method_config` — destination charges (`transfer_data` destination/amount), direct charges (`stripe_account` → `Stripe-Account` header), application-fee splits (`application_fee_amount`), plus `on_behalf_of` and `transfer_group` — validated against the charge amount before PaymentIntent creation and never serialized into the public 402 challenge, matching mppx (`validateConnectSettlement` / `createWithSecretKey`).

**Audit hardening on the above (dual-reviewer pass).** Stripe PaymentIntent requests now pin `Stripe-Version: 2026-02-25.preview` (required for SPT private preview; mppx `stripePreviewVersion` parity) and reject a non-string Connect `transfer_group` cleanly instead of raising at request time. The MCP transport treats non-map JSON-RPC `params` (arrays, explicit null) as carrying no credential instead of crashing; its client helpers `payment_required?/1` and `extract_challenges/1` now also accept the full JSON-RPC response envelope (mppx `paymentRequiredData` parity); and a replayed MCP credential emits the same `[:mpp, :verify, :start]`/`:fail` telemetry as the HTTP path. `MPP.Replay` rejects a credential whose payload the JCS subset cannot canonicalize (e.g. floats) as `malformed-credential` instead of leaking a `FunctionClauseError` — also fixing the pre-existing crash on the HTTP path for store-backed methods.

## [0.10.0] - 2026-07-08

**Internal refactor — shared-helper de-duplication and `MPP.Headers` split (no runtime behavior change; the Accept-Payment API move below is the one breaking surface).** Extracted copy-pasted internal helpers into three small modules: `MPP.Hex` (`strip_0x/1`, `hex_string?/1`), `MPP.Methods.Shared` (`require_config/3`, `check_receipt_status/1`, `parse_charge_amount/1`), and `MPP.Codec` (`decode_base64_json/1`), removing the duplication across the payment-method and wire-format modules. The 900-line `MPP.Headers` was split: the `Accept-Payment` parse/format/rank algorithm moved to its own `MPP.AcceptPayment` module, and the byte-level multi-scheme boundary state machine moved to an internal `MPP.Headers.SchemeSplitter`, leaving `MPP.Headers` focused on the challenge/credential/receipt wire format.

**Breaking (moved API) — `Accept-Payment` functions relocated to `MPP.AcceptPayment`.** The four public functions moved out of `MPP.Headers` and were renamed to drop the now-redundant suffix: `MPP.Headers.parse_accept_payment/1` → `MPP.AcceptPayment.parse/1`, `apply_accept_payment_header/3` → `apply_header/3`, `format_accept_payment/1` → `format/1`, `rank_by_accept_payment/2,3` → `rank/2,3`. Behavior is identical; the progressive-discovery key moves from `MPP.describe(:headers)` to `MPP.describe(:accept_payment)`. Update any direct callers to the new module.

**Parse-time input validation for challenges (reference-SDK parity).** `MPP.Headers.parse_challenge/1` and the echoed-challenge decode paths (`MPP.Credential.decode/1`, `MPP.Mcp`) now validate challenge field shapes at parse time instead of deferring to a downstream mismatch, via a shared `MPP.Challenge.validate_fields/1`: `id` must be non-empty, `method` must match the spec ABNF `payment-method-id = 1*LOWERALPHA` (lowercase ASCII letters only — following mpp-rs; mppx's looser `[a-z0-9:_-]` regex diverges from the spec), `request` must base64url-decode to a JSON object, and `digest` (when present) must start with `sha-256=`. The header/credential paths return distinct error atoms (`:empty_id`, `:invalid_method`, `:invalid_request`, `:invalid_digest`); the MCP transport keeps its coarse `:invalid_challenge`. `MPP.Verifier` now reports a malformed (non-ISO-8601) `expires` as a `credential_mismatch` distinct from an actual `payment_expired`, and `MPP.JCS.canonicalize/1` raises `ArgumentError` on a non-string map key per its RFC 8785 contract. Raw wire bytes are never altered — validation only inspects shape, so HMAC binding is unaffected.

Tempo dedup stores now support per-store key prefixes for shared-cache tenancy. Pass `key_prefix: "tenant:"` in `{MPP.Tempo.ConCacheStore, opts}` to namespace backing keys while preserving the no-prefix default.

**Audit hardening on the above (dual-reviewer pass).** `MPP.Credential.decode/1` now also rejects a non-string optional field (`description`/`digest`/`expires`/`opaque` in the echoed challenge, or the top-level `source`) with `:invalid_optional_field` — previously such a credential decoded successfully and crashed the verifier downstream (HMAC input join / ISO-8601 parse) on attacker-supplied wire bytes; mppx (`z.optional(z.string())`) and mpp-rs (serde `Option<String>`) both reject these shapes at deserialization. `MPP.Mcp`'s JCS pre-check now rejects non-string map keys in a native `request` so they surface as `:invalid_challenge` instead of leaking the new `MPP.JCS.canonicalize/1` raise. `MPP.Plug.init/1` raises at boot when a configured `method_name/0` falls outside the spec ABNF `1*LOWERALPHA` — such a config would emit challenges that no compliant client (including this library's own parse paths) can parse.

## [0.9.0] - 2026-07-08

**Security (fee-payer intrinsic-gas hardening — closes an open item in the published gas-drain family).** `MPP.Methods.Tempo.FeePayerPolicy` now rejects two non-canonical shapes in the client-signed `0x76` envelope before the server co-signs, matching mppx #602 (`fix-fee-payer-intrinsic-gas`): (1) any call carrying a nonzero native `value`, and (2) non-canonical calldata for the recognized TIP-20 / stablecoin-DEX calls (`transfer`, `approve`, `transferWithMemo`, `swapExactAmountOut`) — trailing padding or non-canonical high-order bytes that raise the transaction's *intrinsic* gas (16 gas per byte, paid by the sponsor) without changing the decoded payment intent. Both are siblings of the already-published gas-draining advisories (GHSA-vv77-66rf-pm86, GHSA-vj8p-hp9x-gh47, GHSA-qpxh-ff8m-c62v) that the existing price/access-list ceilings did not cover, and which pre-broadcast `eth_simulateV1` cannot catch (padded calldata still executes successfully, it just costs more). Safe-by-default: honest clients emit canonical, zero-value calls, so existing `fee_payer: true` deployments are protected without config changes. Unrecognized selectors are left to the separate call-scope gate. mpp-rs does not implement this check (its fee-payer path uses a different inline-envelope architecture).

## [0.8.0] - 2026-07-08

**Security (presenter-identity binding — closes the GHSA-34g7-vx6g-82mq residual).** New opt-in Tempo `method_config` key `"require_presenter_binding"`: when `true`, `type="hash"` and `type="transaction"` credentials must carry a `"presenterSignature"` — an EIP-712 signature over the same `Proof` typed data the `type="proof"` path uses (MPP domain v3, `{account, challengeId, realm}`) — produced by the transfer sender's wallet or one of its authorized access keys. This closes the advisory's documented residual: dedup on the hash/transaction paths is keyed on the tx hash alone, so a third party who observed a settled transfer could race its hash against their own fresh challenge; with binding enabled the presenter must prove control of the sender address (hash path: the credential's `source` DID is required and must match the matched transfer's `from`; transaction path: the account is the sender recovered from the signed 0x76 transaction, and a `source`, when present, must agree). The requirement is advertised to clients as `"presenterBinding": true` in the 402 challenge's method details, and a supplied `presenterSignature` is verified even when the flag is off. Off by default for interoperability: neither mpp-rs nor mppx binds the presenter on the hash path (both default the expected sender to the receipt's `from` — mpp-rs `verify_hash`, mppx `Charge.ts` hash branch), so this is a deliberate hardening extension beyond the reference SDKs.

## [0.7.0] - 2026-07-08

**Security (Accept-Payment DoS cap — mpp-rs #299 parity).** `MPP.Headers.parse_accept_payment/1` and `apply_accept_payment_header/3` now ignore an `Accept-Payment` header larger than 16 KiB (`@max_token_len`) before splitting, extending the credential/receipt/challenge-request token cap to the fourth client-supplied parse surface. Oversized headers are treated as malformed (spec MAY-ignore): parsing returns `[]` and offer ranking is a no-op.

**Security (replay protection on by default — issue #7).** Dedup stores are now **on by default** across all three layers (`MPP.Plug` credential store, `MPP.Methods.Tempo`, `MPP.Methods.EVM`). When no `:store` / `"store"` is configured, the app-started `MPP.Tempo.ConCacheStore` is used automatically, so a fresh install rejects replays out of the box instead of silently allowing them — matching the reference SDKs (mpp-rs `store: Some(MemoryStore::new())` in `server/tempo.rs`; mppx `Store.from(store ?? Store.memory())` in `tempo/server/Charge.ts`). The `:mpp` application is now started (via `mod: {MPP.Application, []}` in `mix.exs`) to supervise that default store.

**Security (atomic dedup contract required — GHSA-w8j7-7qc3-5f24 residual).** A configured store MUST now implement the atomic `check_and_mark/2`; `check_and_mark/2` is a required `MPP.Tempo.Store` callback and a store lacking it is rejected at `Plug.init` / `validate_config!` with an `ArgumentError`. The previous non-atomic `get/1`+`put/2` fallback — which left a TOCTOU replay window for custom get/put-only stores — has been removed. The built-in `ConCacheStore` (atomic via ConCache row isolation) and both reference SDKs (mpp-rs `put_if_absent` fails closed on `AtomicUnsupported`; mppx atomic `update`) already meet this contract.

**Breaking changes (0.7.0):**
- Replay protection defaults to ON. Deployments that relied on the previous stateless (no-dedup) default must set `store: false` (Plug opt) / `"store" => false` (method_config) to explicitly opt out. `store: nil`/absent now means "use the default store," not "no dedup."
- Custom stores implementing only `get/1` + `put/2` are rejected at init — add an atomic `check_and_mark/2`, or use `store: false` to disable dedup.
- The `:mpp` application now starts a supervised process (the default `ConCacheStore`). A static Tempo `"memo"` combined with `store: false` is rejected (a static memo still requires single-use enforcement).

## [0.6.4] - 2026-07-07

**Security (Tempo static-memo hardening — GHSA-34g7-vx6g-82mq).** A static `"memo"` in the Tempo `method_config` now requires a dedup `"store"` to be configured — `MPP.Plug` raises `ArgumentError` at init otherwise. A static memo pins attribution independently of the per-challenge nonce, so the dedup store provides the single-use guarantee for that configuration, matching the reference Rust SDK's store-on-by-default backstop. Routes using the default per-challenge attribution (no static memo) are unaffected. Configure `MPP.Tempo.ConCacheStore` (or `{MPP.Tempo.ConCacheStore, opts}`) in your supervision tree, or omit the static memo.

## [0.6.3] - 2026-07-06

**Security (EVM payment-proof single-use — GHSA-vp5h-xh25-44wf).** `MPP.Methods.EVM` gains an optional `"store"` config (an `MPP.Tempo.Store` module, or `{MPP.Tempo.ConCacheStore, opts}`) that makes each on-chain transaction hash single-use, closing a payment-proof replay gap: the method previously matched a settled transfer only by `token`/`to`/`amount` with no single-use binding, and the generic `MPP.Plug` store keys on the per-402 `challenge.id`, so one settled transaction could satisfy repeated charges on a static-price route. The tx hash is now checked before on-chain verification and atomically committed (`check_and_mark/2`, with a non-atomic `put/2` fallback) after — keyed on the canonical (lowercased) hash rather than the challenge id, mirroring the Tempo `type="hash"` path. Store misconfiguration is rejected at init via `validate_config!`. Configure a store with a TTL ≥ your challenge expiry; residual per-challenge on-chain attribution is provided by the EIP-3009 authorization path (roadmap).

Dependency updates. Transitive: `plug 1.20.1 → 1.20.2`, `cowlib 2.17.1 → 2.18.0`, `hpax 1.0.3 → 1.0.4`, `makeup 1.2.1 → 1.2.2`; dev-only `ex_ast 0.12.5 → 0.12.7`.

## [0.6.2] - 2026-06-30

Protocol utilities. Added `MPP.Expires` for ISO 8601 challenge-expiration helpers and `MPP.DID.evm_did/2` for `did:pkh:eip155` credential-source identifiers.

Security. `MPP.Plug` now accepts an optional shared replay store for generic credential deduplication across non-Tempo methods, using the existing `MPP.Tempo.Store` interface and atomic `check_and_mark/2` when available.

**Security (Tempo + Stripe hardening — Task 46).** Tempo gains EIP-712 proof v3 credentials (`MPP.Methods.Tempo.Proof`, `type="proof"`) with wallet-bound signatures, optional store dedup, and zero-amount enforcement. Fee-payer co-signing now rejects fee tokens outside a per-chain allowlist (`FeePayerPolicy.default_allowed_fee_tokens/1`, overridable via `fee_payer_allowed_fee_tokens`). `MPP.DID.parse_evm_did/1` validates hash-credential `did:pkh` sources. `MPP.Methods.Tempo.SessionReceipt` adds optional `externalId` (PaymentWitness parity). Stripe rejects credential `externalId` values that disagree with the route request (mppx #537).

**Security (Tempo proof access keys — Task 69).** Zero-amount Tempo proof verification now accepts active delegated access-key signatures through the Tempo AccountKeychain path when the direct signer is not the root wallet, and rejects stale or revoked access keys.

**Security (Tempo hosted fee payer — Task 68).** Tempo charge verification can delegate fee-payer co-signing to a hosted `eth_fillTransaction` endpoint via `fee_payer_url`, matching mppx `fillHostedFeePayerTransaction`. Returned `feeToken` values are checked against the same sponsor allowlist as local co-signing before broadcast.

## [0.6.1] - 2026-06-29

**Security (Tempo hash-credential dedup).** The `type="hash"` credential path now commits its dedup mark through the store's atomic `check_and_mark/2` — the same primitive the `type="transaction"` path already uses — matching the reference SDKs (mpp-rs `Store::put_if_absent`, mppx atomic `markHashUsed`). The mark still happens only after successful on-chain verification, so a transient receipt-RPC failure does not burn a legitimate hash; stores that do not implement `check_and_mark/2` keep the documented best-effort fallback.

**Security hardening parity.** Verifier/Plug now issue expiring challenges by default, fail closed on missing/invalid expiration, require echoed `digest`/`opaque` values to match endpoint configuration, and MCP clients recognize payment-required result metadata via `org.paymentauth/payment-required`. Tempo validates declared payer source against the matched transfer sender and chain, verifies challenge-bound attribution metadata on unconfigured memo transfers, and provider/RPC/store failure details are sanitized before becoming public 402 responses. **Breaking:** credentials for newly-issued challenges must echo valid expiration data, and Tempo no-static-memo routes now require challenge-bound attribution metadata.

Development tooling. The dev baseline now pins Elixir `1.20.2-otp-29`, adds `ex_slop` and `reach` to `mix precommit.full`, refreshes the generated agent instructions, and includes MCP config for Cursor/Codex/Grok agents. Tempo's unsupported-`eth_simulateV1` degraded-mode log is now a warning so missing node support is visible during operations.

## [0.6.0] - 2026-06-24

**CI / security scaffolding.** The repo gains GitHub Actions CI — previously it had none. A base **CI** workflow gates every push/PR to `development`/`main` with the full check stack (format, `--warnings-as-errors` compile, Credo strict, Doctor, Sobelow, tests at a 95% coverage floor, Dialyzer), mirroring `mix precommit.full`; an **Integration** workflow runs the credential-gated `:integration` suite nightly (and on PR / manual dispatch), flunking loudly when secrets are absent rather than reporting a green 0-test run. A **Code Scanning** workflow uploads Sobelow findings to the Security tab as SARIF (CodeQL has no Elixir support), plus a Dependabot config (weekly Hex + Actions updates) and an expanded `SECURITY.md` scope. Elixir/OTP are pinned via `.tool-versions` so CI never drifts from local `mix format` output.

**Security (Tempo fee-payer gas draining).** When the server acts as fee payer it now validates the client-signed `0x76` envelope's gas economics **before** co-signing, closing two reported gas-draining vectors (GHSA-vv77-66rf-pm86, GHSA-qpxh-ff8m-c62v): unbounded `max_fee_per_gas`/`max_priority_fee_per_gas` and access-list padding. A new `MPP.Methods.Tempo.FeePayerPolicy` bounds `gas_limit`, `max_fee_per_gas`, `max_priority_fee_per_gas`, the `gas × max_fee_per_gas` total-fee budget, and rejects non-empty access lists. Cross-checking against the mppx and mpp-rs reference SDKs surfaced a further defense both enforce that we were missing — folded in here: the sponsored transaction must use the expiring nonce key and declare a `valid_before` that is in the future and within `max_validity_window_seconds` (default 15 min), so a client cannot hold a co-signed sponsorship broadcastable far into the future. All ceilings (gas economics + validity window) default to the reference-SDK values (per-chain; Moderato gets a higher priority-fee ceiling) and are overridable via `method_config["fee_payer_policy"]`. Safe-by-default — existing `fee_payer: true` deployments are protected without config changes. Complementing this static policy, the server now **pre-simulates the full co-signed sponsored transaction** via `eth_simulateV1` before broadcasting — on both the synchronous and optimistic paths: a transaction that would revert on-chain is rejected before the sponsor commits any gas, a node without `eth_simulateV1` (JSON-RPC -32601) degrades gracefully, and any other RPC error fails closed. This covers the residual class that static gas bounds cannot — a `gas_limit` set too low to complete execution. The `onchain_tempo` floor is raised to `~> 0.7` (lock 0.7.0) for the sender-recovery + `Onchain.Tempo.RPC.simulate/3` primitives `MPP.Methods.Tempo` calls directly; the reference SDKs name the method `tempo_simulateV1`, but Tempo deploys the AA-aware EVM-standard `eth_simulateV1` (both mainnet and Moderato return -32601 for the former).

Dependency updates. Runtime: `req ~> 0.5.17` → `~> 0.6.1` (cascades transitive `finch ~> 0.17` → `~> 0.21/0.22`; MPP uses only the stable `Req.request/2` + `Req.Response`/`Req.Request` surface, no code changes). Dev/test JS tooling moved as a set now that quickbeam relaxed its constraints: `quickbeam 0.10.5` → `0.10.15`, `oxc ~> 0.13.0` → `~> 0.15.1`, `npm ~> 0.6.1` → `~> 0.7.4`; `ex_unit_json ~> 0.4.3` → `~> 0.5.0`; dev-only `bandit ~> 1.11.1` → `~> 1.12.0`.

On-chain stack advanced to the onchain-0.10 line: `descripex ~> 0.7.0` → `~> 0.9`, `onchain ~> 0.7.0` → `~> 0.10`, `onchain_tempo ~> 0.2.2` → `~> 0.7` (the `onchain` bump is what moves `MPP.Methods.EVM` onto the `Onchain.RPC` surface). This required moving the whole ZenHive on-chain family together — descripex 0.8/0.9 add spec-derived JSON Schema and are additive, but descripex **0.9.1** was cut alongside to fix a `safe_convert` crash (it only rescued `ArgumentError`, so real-world specs like Cartouche's `%{required(non_neg_integer()) => <<_::256>>}` aborted the manifest/`describe` build with an uncaught `CaseClauseError`). The lock resolves the family at `descripex 0.11.0`, `cartouche 0.5.0`, `onchain 0.10.0`, `onchain_tempo 0.7.0` (cartouche 0.5 carries the `descripex ~> 0.11` floor). Compile clean under `--warnings-as-errors`; offline tests green against the full updated chain, integration suite green.

## [0.5.1] - 2026-06-09

Dependency updates. Bumped the onchain stack to the 0.7.0 line: `onchain ~> 0.5.4` → `~> 0.7.0`, `onchain_tempo ~> 0.2.1` → `~> 0.2.2`, `descripex ~> 0.6.0` → `~> 0.7.0`. onchain 0.7.0 cascades a major `decimal` `2.4.1` → `3.1.1` jump (transitive only — MPP has no direct `Decimal` use) and pulls `cartouche 0.2.2`. Dev-tool `doctor` advanced `~> 0.22` → `~> 0.23` (0.23 requires `decimal ~> 3.1`, unblocked by the jump). No library code changes — compile clean under `--warnings-as-errors`, 601 offline tests green.

## [0.5.0] - 2026-05-15

Tempo session-receipt support and a client-side HTTP transport. Tempo integration tests now use `Onchain.Tempo.Faucet` for per-test fresh wallets instead of hardcoded keys, removing nonce coupling and unblocking a future move to async tests. `MPP.Client.Transport` behaviour with an HTTP implementation lands as the client-side counterpart to server-side `MPP.Method`, exposing a `select_challenge/2` helper that Task 33c (Req plugin) and Task 33d (MCP) will reuse. Dependency floors tightened: `onchain ~> 0.5`, `onchain_tempo ~> 0.2`. A second cross-SDK gap pass added Tasks 36–42 (Stellar Charge, Accept-Payment, EVM `credentialTypes`/Permit2/EIP-3009, Tempo SessionReceipt, OpenAPI discovery) to the roadmap.

## [0.4.0] - 2026-04-18

The first cross-SDK gap pass with substance. `MPP.Verifier` extracts the verification pipeline (HMAC, realm, expiry, request match, method.verify) out of `MPP.Plug` into a transport-neutral module, so MCP and future transports share the same correctness gate. `MPP.JCS` implements the RFC 8785 subset MPP needs for cross-SDK HMAC interop. The MCP transport (`MPP.Mcp`) lands with -32042/-32043 error codes and the `org.paymentauth/credential` + `org.paymentauth/receipt` `_meta` keys. Client-side gets `MPP.Client.PaymentProvider` behaviour and `MultiProvider` first-match dispatch. Protocol utilities fill in: `MPP.Headers.parse_challenges/1` (multi-challenge `WWW-Authenticate` parsing), `MPP.BodyDigest`, `MPP.Amount` (parse_units / with_base_units / parse_dollar_amount). Eight new RFC 9457 session error types added under `paymentauth.org/problems/session/`. EVM integration tests against Sepolia validate real RPC round-trips for both ERC-20 and native-ETH paths.

**Breaking:** `MPP.Amount.parse_dollar_amount/2` now requires callers to supply `decimals` explicitly (previously a single-arg form inferred it from currency). Neither mppx nor mpp-rs maintain a currency-to-decimals table; implicit inference was a correctness risk.

**Scope decision:** proxy/gateway functionality scoped out to a separate `mpp_proxy` package. The `mpp` library focuses on protocol correctness; the BEAM-native payment gateway is a separate product surface.

Dependency bumps: quickbeam 0.8.1 → 0.10.0, oxc 0.5.4 → 0.7.2, ex_dna 1.2.2 → 1.3.0, credo back to hex `~> 1.7` (upstream shipped the Elixir 1.20-rc multi-line sigil fix).

## [0.3.0] - 2026-04-03

Generic EVM payment method and the `onchain_tempo` extraction. `MPP.Methods.EVM` verifies hash-only credentials on any EVM chain (Ethereum, Base, Polygon, Arbitrum, …) — ERC-20 transfers via Transfer event log parsing, native ETH via tx value/recipient matching. Tempo chain primitives moved out of MPP into the standalone `onchain_tempo` Hex package; MPP delegates chain ops and keeps only the payment-protocol surface (dedup store, eth_call simulation, RFC 9457 error wrapping). `mix mpp.demo` ships an interactive Bandit server on port 4402 with a toy `demo-token` method and a pre-computed valid credential in the startup banner — zero-friction first experience. Read-only live-protocol integration tests against `mpp.dev/api/ping/paid` validate parser compatibility with the reference server. `MPP.Tempo.Store` moduledoc gained deployment-topology guidance (`ConCacheStore` for single-node / sticky routing; shared backend otherwise, with `fly-replay` as a worked example).

## [0.2.0] - 2026-03-28

The Tempo payment method (`MPP.Methods.Tempo`) — on-chain TIP-20 transfer verification with both `type="hash"` (client-broadcast) and `type="transaction"` (server-broadcast) credential paths. `transferWithMemo(address,uint256,bytes32)` matching enforced when `methodDetails.memo` is configured. Server-side fee sponsorship via 0x78 domain signing with whitelisted call-scope validation matching mppx's four allowed selector patterns. Optimistic broadcast mode (`wait_for_confirmation: false`) simulates the payment call via `eth_call`, broadcasts asynchronously, and returns an optimistic receipt without waiting for inclusion. `MPP.Tempo.Store` behaviour adds pluggable replay protection with `get`/`put` + optional atomic `check_and_mark/2`; built-in `MPP.Tempo.ConCacheStore` provides ETS-backed TTL dedup. `MPP.Plug`'s `:methods` option enables multi-method 402 endpoints with per-method pricing. All public functions gain Descripex `api()` annotations with `MPP.describe/0-2` progressive discovery and `mix mpp.manifest` for JSON API contract export. Bug fixes covered the TransferWithMemo `memo` indexed-topic discovery (via real Moderato receipts), v-value normalization for ox/tempo SDK interop, hash-path dedup ordering to avoid burning hashes on transient RPC failures, and crash protection in post-broadcast store paths.

## [0.1.0] - 2026-03-25

First public release. Core protocol — HMAC-SHA256-bound Challenge, Credential, Receipt, Headers (WWW-Authenticate / Authorization / Payment-Receipt), and RFC 9457 problem types under `paymentauth.org/problems/`. `MPP.Methods.Stripe` verifies PaymentIntents via SPT with idempotency, analytics metadata, and `Req.Test` mockability. `MPP.Plug` mounts in any Phoenix or Plug router with per-route pricing and explicit credential configuration — no `Application.get_env`, no ENV fallback.
