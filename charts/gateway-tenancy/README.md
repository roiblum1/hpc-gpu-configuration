# gateway-tenancy — Phase 7

The front door: a Gateway API entrypoint with per-team API-key auth and **token-based** rate limiting, routing each lane to its Dynamo frontend. Identity, budgets, and lane selection only — **never** endpoint picking.

## Why it matters

Dynamo's KV-aware router is the one inference router; this layer must not become a second one (two routers disagreeing about placement kills KV-locality). What it *does* own is tenancy and fairness — and the load-bearing detail there is **limit tokens, not requests**: agentic traffic is wildly asymmetric, so request-rate limiting either starves agents or lets one tenant eat the decode pool.

## What it deploys

- **`Gateway`** (`openshift-default` class, Istio/OSSM3-based) with interactive + batch HTTPS listeners.
- **Two `HTTPRoute`s** — lane selection by hostname to the matching Dynamo frontend Service.
- **`AuthPolicy`** — API key per team (Secrets labelled `llm-apikeys` → tenant identity).
- **`RateLimitPolicy`** — token-aware, per tenant.
- Optional listener **`Certificate`** (cert-manager).
- OSSM3 + RHCL (Kuadrant) Subscriptions.

## Prerequisites & position

After glm51-dynamo (needs the frontend Services). Needs [cert-manager](../cert-manager) if `tls.certificate.enabled`. API-key Secrets (labelled `llm-apikeys`) are created out of band.

## How to use

```bash
../install.sh gateway-tenancy
helm template gateway-tenancy    # inspect Gateway, routes, Auth/RateLimit policies
```

Set real hostnames and (if not BYO-secret) an issuer before installing.

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `gateway.gatewayClassName` | `openshift-default` | OCP 4.20 GA Gateway API (OSSM3 provides it) |
| `gateway.hostnameInteractive` / `…Batch` | `llm.` / `llm-batch.` | Lane selection **by hostname** — trivial policy attachment, no accidental lane-hop |
| `gateway.tls.certificate.enabled` | `true` | Render a cert-manager `Certificate` (set an issuer) or BYO secret via `certificateRef` |
| `routes.*.backendService` | `glm51-frontend` / `glm51-batch-frontend` | Must track the DGD frontend names in glm51-dynamo |
| `tenancy.authPolicy.apiKeySelectorLabel` | `llm-apikeys` | Secrets with this label hold per-team keys → tenant identity |
| `tenancy.rateLimit.tokenAware` | `true` | **Limit tokens, not requests.** If your RHCL lacks it, set `false` → request-rate + hard `max_tokens` cap at the frontend |
| `tenancy.rateLimit.interactiveTokensPerMin` / `batchTokensPerMin` | `200000` / `2000000` | Per-lane token budgets |

The Kuadrant CR apiVersions track your mirrored RHCL bundle — adjust group/version to match, don't upgrade them speculatively. Interactive lane also clamps `max_tokens` at the frontend (a single 131K-output generation is a decode-pool DoS); the batch lane gets the large, preemptible budgets.

## The one rule this chart enforces

**One inference router.** No GIE `InferencePool`/EPP or any endpoint-picking in front of the Dynamo frontend. §10

## Gate 7 (do not proceed past failure)

No key → 401 · tenant over budget → 429 **with rate-limit headers** · interactive request attempting 131K output → clamped · both hostnames reach their respective DGD frontends (verify with a marker request per lane).

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance.
