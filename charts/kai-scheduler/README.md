# kai-scheduler — Phase 5

Our KAI scheduling **config**: the queue hierarchy and the two PriorityClasses that make gang scheduling, guaranteed SLO capacity, and reclaimable batch scavenging work. The KAI engine itself is upstream.

## Why it matters

Multi-node EP groups must schedule **all-or-nothing** — a half-placed EP16 group is 16 wedged GPUs. KAI's atomic gangs + queues are what make "full utilization *and* SLO capacity" real: interactive gets a guaranteed floor, batch soaks the idle troughs and is reclaimed whole when interactive scales up. And there must be exactly **one** GPU quota brain — a second one fails silently as unexplained Pending pods.

## What it deploys

- **Queue hierarchy** (`scheduling.run.ai/v2`): `org → {serving-interactive, serving-batch, aux-cpu}`.
- **Two PriorityClasses**: `serving-critical` (interactive), `serving-batch` (preemptible).

The **KAI engine is upstream and off by default** (`upstream.install: false`) — mirror/clone it, or vendor as a subchart (`helm dependency build`). This chart renders standalone regardless.

## Prerequisites & position

After lvms-storage (and cert-manager), before glm51-dynamo. Grove/LWS controllers (doc component #8) are installed out of band from mirrored manifests — KAI's pod-grouper *detects* their groups; nothing here deploys them.

## How to use

```bash
../install.sh kai-scheduler
helm template kai-scheduler      # inspect the queues + priority classes
```

To bring up the engine: mirror/clone it, set `upstream.install: true`, enable bin-packing + network-topology placement in its pass-through values, then `helm dependency build`.

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `upstream.install` | `false` | Off for disconnected — mirror the engine first |
| `queues.interactive.gpu` | `{quota: 64, limit: 96, overQuotaWeight: 3}` | **Quota = guaranteed SLO floor**; limit allows bursting; high weight wins idle GPUs. Keep in multiples of gang size |
| `queues.batch.gpu` | `{quota: 0, limit: -1, overQuotaWeight: 1}` | Pure scavenger: guaranteed nothing, allowed everything idle, reclaimed **whole** |
| `queues.aux.gpu` | `{quota: 0, limit: 0}` | CPU/RAM-only (embedders, evals) — structurally can't touch GPU quota |
| `priorityClasses.interactive.value` | `1000000` | Orders preemption between pods; batch's lower value makes it preemptible |
| `priorityClasses.batch.value` | `100000` | The preemptible class for the batch lane |

## The one rule this chart enforces

**One GPU quota brain.** Every GPU pod names `kai-scheduler` + carries a queue label; no Kueue, no ClusterQueue, no Run:ai quota project pointed at these nodes. §10

## Gate 5 (do not proceed past failure)

2-node dummy gang with only 1 node free → **both** pods Pending with a gang message, zero bound · free a node → both bind in one cycle · fill with batch, submit interactive → batch gang evicted **whole**.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance. Queue/PriorityClass names must match [glm51-dynamo](../glm51-dynamo) values.
