# Changelog

Completed roadmap tasks. For upcoming work, see [ROADMAP.md](ROADMAP.md).

---

## [Unreleased]

### Phase 1: Core Protocol

#### Task 1: Challenge Module
**Completed** | [D:4/B:10/U:10 → Eff:2.5]

**What was done:**
- `MPP.Challenge` struct with all 9 spec fields (id, realm, method, intent, request, description, digest, expires, opaque)
- `create/2` computes HMAC-SHA256 challenge ID from 7 pipe-delimited positional slots
- `verify/2` recomputes HMAC and uses `Plug.Crypto.secure_compare/2` for constant-time comparison
- Base64url encoding without padding for challenge IDs
- Optional fields use empty string in HMAC input (fixed slot positions)

#### Task 3: Receipt Module
**Completed** | [D:2/B:8/U:8 → Eff:4.0]

**What was done:**
- `MPP.Receipt` struct with status (always "success"), method, timestamp, reference, external_id
- `new/1` with defaults for status and RFC 3339 timestamp
- `encode/1` / `decode/1` for base64url JSON serialization (Payment-Receipt header format)
- camelCase JSON keys per spec (`externalId`)

#### Task 5: Errors Module
**Completed** | [D:2/B:7/U:7 → Eff:3.5]

**What was done:**
- `MPP.Errors` with 9 RFC 9457 Problem Detail types (expanded from spec's original 7 — added `:invalid_payload` and `:bad_request`)
- `new/2` creates typed errors, `to_map/1` and `to_json/1` render RFC 9457 JSON bodies
- All URIs under `https://paymentauth.org/problems/` base
- Appropriate HTTP status codes (402 for payment errors, 400 for request errors)

#### Task 6: Charge Request Schema
**Completed** | [D:2/B:8/U:8 → Eff:4.0]

**What was done:**
- `MPP.Intents.Charge` struct with amount (string), currency (lowercase), recipient, description, external_id, method_details
- `new/1` with validation (amount must be string, currency normalized to lowercase)
- `to_request/1` / `from_request/1` for camelCase JSON conversion per spec
- "Intent = Schema" design — all payment methods share this structure

#### Code Review Fixes
- Fixed `Challenge.create/2` `@doc` — removed incorrect "or map" from parameter description (only keyword lists accepted)
- Simplified `Receipt.new/1` — removed unnecessary `then` wrapper around `struct!`
- Added `TODO(Task 7)` to `Intents.Charge` — amount string not validated as numeric, deferred to Method behaviour

---

## [0.0.1] - 2026-03-24

### Added

- Initial release with project scaffold
- Project scaffold with Plug and Jason dependencies
