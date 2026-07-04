# CLAUDE.md — `kai-scheduler` chart (Phase 5)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §5 / §10 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** our scheduling *config* — the Queue hierarchy (`scheduling.run.ai/v2`) and the two
PriorityClasses. The **KAI engine itself is upstream** and off by default
(`upstream.install: false`): mirror/clone it, or vendor as a subchart and `helm dependency
build`. This chart must render standalone in a disconnected cluster either way.

**Does NOT own:** pod wiring (`schedulerName`, queue labels, priorityClassName → applied in
`minimax-dynamo`) · Grove/LWS controllers (doc component #8 — installed out of band from mirrored
manifests; KAI's pod-grouper *detects* their groups, nothing here deploys them).

## The one rule this chart exists to enforce

**One GPU quota brain.** Every GPU pod names `kai-scheduler`, every GPU pod carries a queue
label, and *nothing else* manages GPU quota on this cluster — no Kueue, no ClusterQueue, no
Run:ai quota project pointed at these nodes. Two quota brains don't fail loudly; they fail as
unexplained Pending pods and phantom capacity.

## Why each configuration is what it is

- **Queue tree `org → {serving-interactive, serving-batch, aux-cpu}`.** Semantics that make
  "more developers + full utilization" real:
  - `serving-interactive` `{quota: 64, limit: 96, ovqw: 3}` — **quota is the guaranteed floor =
    your SLO capacity**; limit allows bursting above it; the high over-quota weight wins
    contention for idle GPUs. Keep quota/limit in **multiples of the gang size**
    (`multinode.nodeCount × 8`) or a "fitting" quota still can't fit a whole gang.
  - `serving-batch` `{quota: 0, limit: -1, ovqw: 1}` — a **pure scavenger**: guaranteed nothing,
    allowed everything idle. When interactive scales up, KAI **reclaims batch gangs
    atomically** — whole EP groups, never partial, because a half-evicted EP16 group is 16
    wedged GPUs.
  - `aux-cpu` `{quota: 0, limit: 0}` — soaks leftover *cores* on GPU nodes (embedders,
    rerankers, evals) while being structurally unable to touch GPU quota.
- **Priorities 100/50/10** order preemption between queues; the **PriorityClass values**
  (1000000 interactive, 100000 batch) order it between pods and stay far below system-critical
  classes. Batch's lower class is what makes it *preemptible* — that's a feature, not a risk.
- **`upstream.install: false` + the commented pass-through block** — when you do vendor the
  engine, enable **bin-packing and network-topology-aware placement** in its values so EP gangs
  land on fabric-adjacent nodes (same leaf / rail group) instead of scattering across the
  fabric. Scattered gangs turn every EP all-to-all into cross-leaf traffic.

## Cross-layer invariants this chart carries (§10)
One quota brain (no Kueue/Run:ai here — and no GIE EPP router-side, the *other* single-brain
rule) · queue names + PriorityClass names ↔ `minimax-dynamo` values (`queues.*`,
`priorityClasses.*`) · quotas in multiples of gang size ↔ DGD `multinode.nodeCount`.

## Gate 5 (do not proceed past failure)
2-node dummy gang with only 1 node free → **both** pods Pending with a gang message, zero bound
(no partial placement) · free a node → both bind in one cycle · fill with batch, submit
interactive → batch gang evicted **whole**, interactive binds.
