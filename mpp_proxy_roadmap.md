# mpp_proxy Roadmap

**Vision:** Standalone MPP payment gateway — wrap any API, monetize it with crypto or Stripe, zero application code required. The fastest path from "I have an API key" to "agents are paying me per-call."

**Depends on:** [ZenHive/mpp](https://github.com/ZenHive/mpp) (Elixir MPP library)

**Reference implementations:** mppx `src/proxy/` (TypeScript), mpp-rs `src/proxy/` (Rust)

---

## Why a Separate Package

The proxy is a **product** (payment gateway), not a library feature. `mpp` provides protocol types, Plug middleware, and payment methods — building blocks for developers integrating payments into their own apps. `mpp_proxy` targets a different user: someone who wants to monetize API access without writing Elixir.

**The BEAM advantage:** A payment proxy is a long-running, concurrent, stateful network service — exactly what OTP was built for. Lightweight processes for thousands of concurrent upstream connections, per-connection fault isolation, hot code upgrades for pricing changes without downtime, built-in observability via `:telemetry`.

---

## Architecture

```
Client request
    → MppProxy (Plug.Router)
        → match route via MppProxy.Config
        → free route?  → forward with injected auth
        → paid route?  → MPP.Plug handles 402 challenge/verify
                        → forward with receipt header on success
    → Upstream service (OpenAI, Anthropic, custom API, etc.)
```

### Module Map

```
MppProxy                   — Plug.Router: route matching, 402 gating, upstream forwarding
MppProxy.Service           — Service definition struct (id, base_url, auth, routes)
MppProxy.Route             — Route definition (method, path pattern, free/paid config)
MppProxy.Config            — Service list + match_route/2 for request→service+route resolution
MppProxy.Upstream          — Req-based upstream forwarding with auth injection + header sanitization
MppProxy.Discovery         — llms.txt + OpenAPI 3.1.0 generation from service configs
MppProxy.Services.OpenAI   — Pre-built: Bearer token auth, api.openai.com base URL
MppProxy.Services.Anthropic — Pre-built: x-api-key header, api.anthropic.com base URL
MppProxy.Services.Stripe   — Pre-built: HTTP Basic auth, api.stripe.com base URL
```

### User-facing API

```elixir
# In a Phoenix router
forward "/proxy", MppProxy,
  secret_key: "mpp-secret",
  services: [
    MppProxy.Services.openai(
      api_key: "sk-...",
      routes: %{
        {"GET", "/v1/models"} => :free,
        {"POST", "/v1/chat/completions"} => {MPP.Methods.Tempo, amount: "50000", currency: "0x..."}
      }
    )
  ]

# Standalone mode
# mix mpp_proxy.server --config config/proxy.exs --port 4402
```

### Config file (standalone mode)

```elixir
# config/proxy.exs — evaluated Elixir, can read env vars
[
  secret_key: System.fetch_env!("MPP_SECRET_KEY"),
  port: 4402,
  services: [
    MppProxy.Services.openai(
      api_key: System.fetch_env!("OPENAI_API_KEY"),
      routes: %{
        {"GET", "/v1/models"} => :free,
        {"POST", "/v1/chat/completions"} => {MPP.Methods.Tempo,
          amount: "50000",
          currency: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
          chain_id: 4217,
          recipient: System.fetch_env!("RECIPIENT_ADDRESS")
        }
      }
    ),
    MppProxy.Services.anthropic(
      api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
      routes: %{
        {"POST", "/v1/messages"} => {MPP.Methods.Stripe,
          amount: "5",
          currency: "usd",
          stripe_secret_key: System.fetch_env!("STRIPE_SECRET_KEY")
        }
      }
    )
  ]
]
```

---

## 🎯 Current Focus

Start here. Phase 1 can be built immediately — `mpp` Phases 1-8 provide everything needed.

---

## Phase 1: Core Proxy

### Task 1: Service and Route Configuration

[D:2/B:8/U:9 → Eff:4.25] 🎯

Define the data model for proxy services and routes. `MppProxy.Service` struct holds id, title, description, base_url, auth config, and a map of routes. `MppProxy.Route` defines HTTP method, path pattern (with `:param` wildcards), and endpoint config (free or paid with method module + pricing opts). `MppProxy.Config` holds a list of services and provides `match_route/2` to parse an incoming request path (`/{service_id}/upstream/path`) into the matched service, route, and upstream path.

Add auth helper functions: `bearer/1` (Authorization: Bearer), `api_key/2` (custom header name + value), `basic/1` (HTTP Basic). These return config structs used by the upstream forwarder.

Cross-reference: mpp-rs `proxy/service.rs` for Route/Service/Endpoint types, mppx `proxy/Service.ts` for `Service.from()`.

Success criteria:
- [ ] `MppProxy.Service` struct with id, base_url, auth, routes
- [ ] `MppProxy.Route` with method, path pattern, free/paid config
- [ ] `MppProxy.Config.match_route/2` parses `/{service_id}/path` correctly
- [ ] Wildcard path segments (`:param`) match any value
- [ ] Auth helpers: bearer, api_key, basic
- [ ] Unit tests for route matching edge cases

### Task 2: Proxy Plug and Upstream Forwarding

[D:5/B:9/U:9 → Eff:1.8] 🎯 — Depends on Task 1

Build `MppProxy` as a `Plug.Router` that ties routing, 402 gating, and upstream forwarding together:
1. Match incoming request via `MppProxy.Config.match_route/2`
2. Free routes: forward to upstream with injected auth headers
3. Paid routes: run `MPP.Plug` for 402 challenge/verify, forward on success with receipt header
4. Return upstream response to client

`MppProxy.Upstream` handles HTTP forwarding via Req — header sanitization (strip hop-by-hop, inject auth, pass content-type), request body forwarding, error responses when upstream is down (timeout, connection refused, 5xx).

Cross-reference: mppx `proxy/Proxy.ts` for request flow, mppx `proxy/internal/Headers.ts` for header sanitization.

Success criteria:
- [ ] Free routes forward with auth injection, no 402
- [ ] Paid routes run 402 flow, forward on success with receipt header
- [ ] Header sanitization (hop-by-hop stripped, auth injected)
- [ ] Request body forwarded correctly
- [ ] Error handling: upstream timeout, connection refused, 5xx
- [ ] Integration test: proxy in front of `mix mpp.demo` server

### Task 3: Pre-built Service Adapters

[D:2/B:7/U:8 → Eff:3.75] 🎯 — Depends on Task 1

Add `MppProxy.Services.openai/1`, `MppProxy.Services.anthropic/1`, `MppProxy.Services.stripe/1`. Each returns a configured `MppProxy.Service` with the correct auth pattern and base URL, taking only `api_key` and `routes` as required opts. These are convenience functions — users can always build `MppProxy.Service` structs directly for custom APIs.

Cross-reference: mppx `proxy/services/openai.ts`, `anthropic.ts`, `stripe.ts` for auth patterns.

Success criteria:
- [ ] `openai/1` sets Bearer auth + api.openai.com
- [ ] `anthropic/1` sets x-api-key header + api.anthropic.com
- [ ] `stripe/1` sets Basic auth (base64) + api.stripe.com
- [ ] Custom service via raw `MppProxy.Service` struct works identically
- [ ] Unit tests for each adapter

---

## Phase 2: Discovery and Standalone

### Task 4: Agent Discovery Endpoints

[D:3/B:8/U:8 → Eff:2.67] 🎯 — Depends on Task 1 (generation), Task 2 (serving)

`MppProxy.Discovery` generates two formats from service config:

1. **llms.txt** — Markdown listing services, endpoints, pricing, payment methods. Agents parse this to find what's available and what it costs.
2. **OpenAPI 3.1.0** — JSON with paths for all routes. Paid routes include `x-payment-info` extension (method, amount, currency). Free routes are standard OpenAPI paths.

Generation functions are pure (config in → document out). The proxy Plug serves them at `GET /llms.txt` and `GET /openapi.json`.

Cross-reference: mppx `proxy/Proxy.ts` OpenAPI/llms.txt generation, mpp-rs `proxy/service.rs` `serialize_services()` and `to_llms_txt()`.

Success criteria:
- [ ] `GET /llms.txt` returns Markdown service directory
- [ ] `GET /openapi.json` returns OpenAPI 3.1.0 with `x-payment-info` on paid routes
- [ ] Generation functions are pure and independently testable
- [ ] Unit tests with known service configs → expected output

### Task 5: Standalone Mix Task

[D:3/B:8/U:9 → Eff:2.83] 🎯 — Depends on Task 2

`mix mpp_proxy.server` boots Bandit with the proxy Plug from an Elixir config file. Same pattern as `mix mpp.demo` in the `mpp` package. Config file is evaluated Elixir (supports `System.fetch_env!/1`).

```bash
mix mpp_proxy.server --config config/proxy.exs --port 4402
```

Success criteria:
- [ ] Boots standalone proxy from config file
- [ ] `--port` and `--config` flags work
- [ ] Config file supports `System.fetch_env!/1` for secrets
- [ ] Clean error messages for missing config, invalid services, port conflicts
- [ ] Startup banner shows services, routes, and pricing

---

## Phase 3: Production Hardening

### Task 6: Telemetry and Observability

[D:3/B:7/U:7 → Eff:2.33] 🎯

Add `:telemetry` events for proxy operations: request received, route matched, payment required (402 sent), payment verified, upstream forwarded, upstream response received, upstream error. Include measurements (duration, upstream latency) and metadata (service_id, route, payment method, amount). Enable standard `:telemetry_metrics` integration.

Success criteria:
- [ ] Telemetry events for full request lifecycle
- [ ] Duration and latency measurements
- [ ] Service/route/method metadata on all events
- [ ] Example telemetry handler in docs

### Task 7: Rate Limiting and Back-Pressure

[D:4/B:6/U:6 → Eff:1.5] 📋

Per-service and per-route rate limiting. Back-pressure when upstream is slow (don't queue unbounded requests). Consider using `api_toolkit`'s `InboundLimiter` and `RateLimiter` if the dependency is acceptable, or implement a lightweight version.

Success criteria:
- [ ] Per-service concurrent request limits
- [ ] Per-route rate limiting (requests/minute)
- [ ] Back-pressure when upstream response time exceeds threshold
- [ ] 429 responses with Retry-After header

### Task 8: Hot Configuration Reload

[D:4/B:7/U:6 → Eff:1.63] 📋

Reload proxy config (services, routes, pricing) without restarting the server. Watch config file for changes or accept a signal/endpoint. New requests use new config; in-flight requests complete with old config.

Success criteria:
- [ ] Config reload via SIGHUP or admin endpoint
- [ ] In-flight requests unaffected by reload
- [ ] New pricing applies to new requests immediately
- [ ] Startup banner reprints on reload

---

## Phase 4: Ecosystem

### Task 9: Docker Image

[D:2/B:6/U:7 → Eff:3.25] 🎯

Multi-stage Dockerfile producing a minimal OTP release image. Mount config file as volume. Environment variables for secrets.

```bash
docker run -v ./proxy.exs:/config/proxy.exs \
  -e OPENAI_API_KEY=sk-... \
  -e MPP_SECRET_KEY=secret \
  -p 4402:4402 \
  zenhive/mpp-proxy --config /config/proxy.exs
```

Success criteria:
- [ ] Multi-stage build, minimal image size
- [ ] Config file mounted as volume
- [ ] Env vars for secrets
- [ ] Health check endpoint

### Task 10: Documentation and Examples

[D:2/B:7/U:8 → Eff:3.75] 🎯

README with quickstart (5-minute path from zero to running proxy), example configs for common setups (OpenAI + Tempo, Anthropic + Stripe, custom API), architecture diagram, deployment guide (Docker, fly.io, Heroku).

Success criteria:
- [ ] 5-minute quickstart in README
- [ ] Example configs for 3+ common setups
- [ ] Deployment guides for Docker and at least one cloud platform
- [ ] HexDocs with llms.txt

---

## References

| Resource | What |
|----------|------|
| [ZenHive/mpp](https://github.com/ZenHive/mpp) | Elixir MPP library (dependency) |
| mppx `src/proxy/` | TypeScript proxy reference (full implementation) |
| mpp-rs `src/proxy/` | Rust proxy reference (declarative routing layer) |
| [MPP Spec](https://github.com/tempoxyz/mpp-specs) | IETF draft — core protocol |
| [Stripe MPP Blog](https://stripe.com/blog/machine-payments-protocol) | Stripe's agent commerce vision |
