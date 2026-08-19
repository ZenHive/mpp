# Security Policy

## Supported Versions

MPP is pre-1.0 and under active development. Security fixes are applied to the
latest released `0.x` version on Hex and the `main` branch.

| Version | Supported          |
| ------- | ------------------ |
| 0.10.x  | :white_check_mark: |
| < 0.10  | :x:                |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Report privately through **GitHub Private Vulnerability Reporting**: open the
[Security tab](https://github.com/ZenHive/mpp/security) and click
**"Report a vulnerability"**. This keeps the report private and lets us
collaborate on a fix and a coordinated disclosure.

Please include, where applicable:

- The affected module, version, or commit.
- A description of the vulnerability and its impact.
- Steps to reproduce, a proof-of-concept, or a failing test.
- Any suggested remediation.

### In scope

MPP is payment-authentication middleware — bugs in this surface can authorize
unpaid access, accept forged payments, or corrupt signed payloads. We take the
following especially seriously:

- HMAC challenge binding and verification (`MPP.Challenge`, `MPP.Verifier`) —
  challenge forgery, constant-time-comparison bypass, realm/expiry/request-match gaps.
- Credential parsing and challenge-echo validation (`MPP.Credential`).
- Payment-method verification (`MPP.Methods.Stripe`, `MPP.Methods.Tempo`,
  `MPP.Methods.EVM`, `MPP.Methods.Solana`, `MPP.Methods.NearIntents`) —
  accepting an unconfirmed, underpaid, or replayed payment.
- Wire-format and canonicalization (`MPP.JCS`, `MPP.BodyDigest`, `MPP.Headers`,
  `MPP.Receipt`) — encoding/canonicalization mismatches that break cross-SDK HMAC interop.
- Fee-payer gas-economics policy (`MPP.Methods.Tempo.FeePayerPolicy`) — sponsor
  gas-draining via unbounded client gas fields before co-sign.
- Transaction dedup / replay handling (`MPP.Tempo.Store` implementations).

### Out of scope

- Vulnerabilities in upstream dependencies (`onchain`, `onchain_tempo`, `req`,
  `plug`) — report those to their respective projects, though we welcome a heads-up.
- Issues requiring a malicious local environment or a compromised developer machine.
- The bundled demo (`MPP.Demo.*`, `mix mpp.demo`) — it is a toy server, not a
  production surface.

## What to Expect

- **Acknowledgement** within 5 business days.
- An assessment and, if confirmed, a target timeline for a fix.
- Credit in the release notes / advisory once a fix ships, unless you prefer to
  remain anonymous.

We follow coordinated disclosure: please give us a reasonable window to release
a fix before any public discussion.
