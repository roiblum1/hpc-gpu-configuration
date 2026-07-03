# CLAUDE.md — `gateway-tenancy` chart (Phase 7)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §7 / §10 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** the front door — OSSM3 + RHCL (Kuadrant) Subscriptions, `Gateway`, two `HTTPRoute`s,
`AuthPolicy`, `RateLimitPolicy`, optional listener `Certificate`.

**Does NOT own:** endpoint selection (→ Dynamo's KV router — the point of this chart is to *not*
do that) · API keys themselves (Secrets you create, labelled `llm-apikeys`) · cert-manager
(→ its chart; needed only if `tls.certificate.enabled`).

## The one rule this chart exists to enforce

**One inference router (single-brain rule #2).** This layer does **identity, budgets, and lane
selection only**. Dynamo's KV-aware router picks endpoints. Do not add GIE `InferencePool`/EPP
or any load-balancing smarter than "hand the request to the right frontend Service" — two brains
disagreeing about placement destroys KV-locality routing.

## Why each configuration is what it is

- **Lane selection by hostname** (`llm.` interactive / `llm-batch.` batch), not by header or
  path: Gateway API policies attach naturally per-route/per-hostname, clients can't
  accidentally lane-hop, and the batch lane can be firewalled/budgeted independently. Each
  HTTPRoute backends the matching Dynamo **frontend** Service (`glm51-frontend` /
  `glm51-batch-frontend` — names must track the DGD names in `glm51-dynamo`).
- **`gatewayClassName: openshift-default`** — OCP 4.20 GA Gateway API (Istio/OSSM3-based); the
  OSSM3 subscription in this chart is what provides it. No OperatorGroup for it:
  `openshift-operators` already has a global one (a second OperatorGroup in a namespace breaks
  OLM resolution).
- **AuthPolicy = API key per team** (Secrets labelled with `apiKeySelectorLabel`): key → tenant
  identity is what the rate limits key on. Deliberately boring — identity federation can layer
  on later without touching the lane/budget model.
- **RateLimitPolicy limits TOKENS, not requests** (`tokenAware: true`): agentic traffic is
  wildly asymmetric — one request can be 200 tokens or 100K. Request-rate limiting either
  starves agents or lets one tenant eat the decode pool. **Honest hedge:** token-aware limiting
  landed in recent RHCL releases — if your mirrored version lacks it, set `tokenAware: false`
  (request-rate fallback) and enforce a hard `max_tokens` cap at the frontend, reconciling
  budgets from usage logs. The Kuadrant CR apiVersions track your mirrored RHCL bundle — adjust
  group/version to match it, don't "upgrade" them speculatively.
- **Interactive lane clamps `max_tokens`** (enforced at frontend defaults, not left to
  clients): a single 131K-output generation is a decode-pool DoS. Batch/agent lane gets the
  large budgets — it's preemptible, so it pays for them.
- **TLS:** bring your own Secret (`certificateRef`) or let the chart render a cert-manager
  `Certificate` (set an issuer). Terminate at the Gateway; the mesh behind it is cluster-internal.

## Cross-layer invariants this chart carries (§10)
No endpoint picking in front of the Dynamo frontend (single-brain #2) · backend Service names ↔
`glm51-dynamo` DGD/frontend naming · hostnames ↔ tenant docs/clients · token budgets ↔ §8
per-tenant observability (budgets you can't measure are budgets you can't enforce).

## Gate 7 (do not proceed past failure)
No key → 401 · tenant over budget → 429 **with rate-limit headers** · interactive request
attempting 131K output → clamped · both hostnames reach their respective DGD frontends (verify
with a marker request per lane, not just DNS).
