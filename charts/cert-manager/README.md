# cert-manager — cross-cutting prerequisite

Just the cert-manager operator — nothing else, deliberately. Two later charts depend on it.

## Why it matters

The Dynamo operator's admission webhooks (Phase 6) **fail closed** without certificates, and the Gateway listener (Phase 7) needs TLS. cert-manager has two unrelated downstream consumers, so it lives as its own chart to make the install ordering explicit instead of hiding it inside one of them.

## What it deploys

- cert-manager operator **Subscription + OperatorGroup**. No Issuers or Certificates — consumers bring their own: [gateway-tenancy](../gateway-tenancy) renders a listener `Certificate` (if given an issuer), and the Dynamo operator consumes cert-manager directly.

## Prerequisites & position

Install **before [glm51-dynamo](../glm51-dynamo)** (webhook certs) and before gateway-tenancy's optional listener `Certificate`. It has **no gate of its own** — its "gate" is the Dynamo webhooks coming up in Phase 6.

## How to use

```bash
../install.sh cert-manager
helm template cert-manager
```

## Values

| Value | Default | What it does |
|-------|---------|--------------|
| `namespace` | `cert-manager-operator` | Operator install namespace |
| `subscription.channel` | `stable-v1` | The operator's supported channel (not `stable`) — pin per Phase 0 |
| `subscription.source` | `redhat-operators` | **Point at your mirrored CatalogSource** in a disconnected cluster — the default is a placeholder |

## See also

[CLAUDE.md](CLAUDE.md) — why this is its own chart.
