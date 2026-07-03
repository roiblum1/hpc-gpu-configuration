# CLAUDE.md — `cert-manager` chart (cross-cutting prerequisite)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) stays
authoritative.

## Scope — what this chart owns (and does not)

**Owns:** the cert-manager operator Subscription + OperatorGroup. Nothing else — deliberately.

**Does NOT own:** Issuers/Certificates. Consumers bring their own: `gateway-tenancy` renders a
listener `Certificate` (if you give it an issuer), and the Dynamo operator's webhooks consume
cert-manager directly.

## Why this exists as its own chart

- **Self-contained-operator convention, but with two unrelated consumers.** Every other operator
  ships inside the chart whose CRs it manages. cert-manager has **two** downstream subjects
  (Dynamo webhooks in Phase 6, Gateway TLS in Phase 7) — putting it inside either would create a
  hidden cross-chart dependency. A standalone chart makes the ordering explicit instead:
  `install.sh` places it **before `glm51-dynamo`** because the Dynamo operator's admission
  webhooks fail closed without certificates.
- **`channel: stable-v1`** — the operator's supported channel naming (not `stable`); pin and
  record per Phase 0.
- **`source: redhat-operators`** — as everywhere: this must point at your **mirrored**
  CatalogSource name in a disconnected cluster, not the public catalog. The default is a
  placeholder to make the requirement visible, not a working value.
- **No gate of its own** — it's a prerequisite, not a phase. Its "gate" is the Dynamo operator
  webhooks coming up in Phase 6 and the Gateway serving TLS in Phase 7.

## Cross-layer invariants this chart carries
Install order: before `glm51-dynamo` (webhook certs) and before `gateway-tenancy`'s optional
listener `Certificate`. Nothing else in §10 touches this chart.
