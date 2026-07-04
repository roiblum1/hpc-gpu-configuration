# CLAUDE.md — `minimax-dynamo` chart (Phase 6, env/h100-4x-ib)

> **This branch = the 8-node design halved:** 2 gangs × 2 nodes on 4 DGX H100, and
> **MTP instead of DFlash** (DFlash is used only in the 8-node environment; it stays wired
> behind `speculative.method`). Blast radius at N=2: a node loss = 50% of capacity — the
> islands fallback (25%) is most worth benchmarking *here*.

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md), this branch's
[ENVIRONMENT.md](../../ENVIRONMENT.md), and the design record
[minimax-m27-dflash-design.md](../../minimax-m27-dflash-design.md) stay authoritative. The
original LWS manifest this chart translates lives at
[reference/minimax-m27-dflash-lws.yaml](../../reference/minimax-m27-dflash-lws.yaml) — when in
doubt about intent, read the design doc, not the manifest.

## Scope — what this chart owns (and does not)

**Owns:** the one `DynamoGraphDeployment` (Frontend + 2 wide-EP worker gangs), the worker PDB,
and the `llm-serving` namespace. **Config only** — the Dynamo *platform* (operator + etcd +
NATS) is upstream, off by default (`upstream.install: false`); pin **etcd/NATS to infra nodes,
never GPU nodes**.

**Does NOT own:** IB rail NADs (**user-provided** on this branch — `sriov-rails` unused) · host
tuning + RuntimeClass existence (→ `node-foundation`, with `roceQos` disabled) ·
queues/PriorityClasses (→ `kai-scheduler`) · the front door (→ `gateway-tenancy`) · the DFlash
draft artifact (→ `model-staging` stages the `z-lab/MiniMax-M2.7-DFlash` mirror).

## Why the topology is 2 gangs × 2 nodes (design §1 — don't "simplify" it either way)

M2.7 fits on one node, so wide-EP must earn its complexity: sharding 256 experts EP16-wide
frees ~14–15 GB HBM/GPU → KV cache → daytime concurrency. One giant EP32 group is rejected
(node loss = total outage); 4 islands is the *fallback*, not the default (IB carries nothing,
less KV headroom). The escape hatch is deliberately cheap: `replicas: 4, nodeCount: 1,
dataParallel: 1` lands on the island layout with zero re-architecture — that is *why* the
chart keeps the gang machinery even though islands wouldn't need it. Settle the choice by
measurement: wide-EP must buy enough peak throughput to beat the better blast radius (§5) —
and at N=2 gangs (50% loss per node event vs 25% for islands) the bar is *higher* than in
the 8-node environment.

## Why each configuration is what it is

- **`multinode.nodeCount: 2` — the Grove gang IS the LWS group.** KAI schedules it atomically
  (a half-placed EP16 group is 16 wedged GPUs) and recreates it whole on member death — the
  LWS `RecreateGroupOnPodRestart` semantics: a half-alive NCCL/DeepEP communicator never heals.
- **Frontend (routerMode kv) replaces the LWS leader Service** — and is strictly better: the
  plain Service only dropped dead groups from Endpoints; the KV router also does prefix-aware
  placement. Single-brain rule #2 unchanged: nothing endpoint-picks in front of it.
- **Fabric-adjacency moved from LWS `exclusive-topology` to KAI** network-topology-aware
  placement (upstream pass-through in `kai-scheduler` values). Without it, a gang split across
  leaves pays a spine hop on every MoE all-to-all.
- **Three transports; don't conflate them (design §3):** TP8 on NVLink (never the NIC) · EP
  all-to-all on DeepEP/NVSHMEM-IBGDA over the 8 CX-7 rails (needs peermem/DMA-BUF + GDRCopy
  from gpu-operator) · bootstrap/DP-RPC on the pod net (`NCCL_SOCKET_IFNAME=eth0`).
  `ncclIbHca` lists **compute rails only** — a storage HCA on that list silently puts NCCL QPs
  on the storage fabric.
- **No `NCCL_IB_TC` / GID index, no UCX/NIXL env, no KVBM** — the first two are RoCE QoS knobs
  (IB QoS is fabric SLs / subnet manager), the rest exist only for disaggregation, which this
  design doesn't do. Do not "restore" them from main.
- **`NCCL_IB_TIMEOUT=22` / `RETRY_CNT=13` — deliberately generous:** with EP spanning nodes, a
  transient link flap stalls the gang instead of aborting the communicator (= killing it).
  Tail latency during a flap is the accepted price of gang survival.
- **MTP default (`speculative.method: mtp`, K=3)** — native heads in the checkpoint, zero
  extra VRAM, no draft artifact to stage. **DFlash belongs to the 8-node environment**; it
  stays fully wired here (flip the method + stage the z-lab draft via model-staging) so
  adopting it later is a one-value change. `disable_by_batch_size: 32` makes day/night
  self-managing — speculation at night, raw batching at peak; wide-EP and speculation are
  complementary across the diurnal cycle, not redundant. Alert on acceptance rate (§8):
  below threshold, speculation is pure verification overhead.
- **NUMA (design §4):** `single-numa-node` is mathematically impossible for full-node pods —
  alignment here means each worker's memory/RDMA buffers stay on its GPU's socket. Guaranteed
  QoS + static CPU manager + NCCL/DeepEP walking PCIe topology capture most of it;
  node-foundation keeps `topologyPolicy: best-effort` with reserved cores on both sockets.
  Evidence: `numastat` split across both sockets at Gate 6.
- **`IPC_LOCK` from the LWS manifest is intentionally absent** — node-foundation's CRI-O
  `memlock=-1` MachineConfig covers RDMA registration repo-wide (§10 row). Don't add both.
- **PDB `maxUnavailable: 1` on worker pods** ≈ the LWS leader PDB's intent at pod granularity:
  one node (= one gang, recreate semantics) voluntarily disruptible at a time; a broken gang
  blocks further drains. **Caveat:** relies on the operator/Grove propagating
  `app.kubernetes.io/name=minimax-m27` to pods — verify on the rendered pods before trusting
  a drain to it.
- **First start is tens of minutes** (weight load + CUDA graph capture) — `startupProbe`
  budget 160×15s. Don't tighten; don't "fix" a slow first start by shrinking it.

## Cross-layer invariants this chart carries (§10)

RuntimeClass name ↔ node-foundation profile · queue/PriorityClass names ↔ `kai-scheduler` ·
`modelPaths` dirs ↔ `model-staging.models[]` names · quota multiples of gang size (16) ·
one quota brain / one router · rails.resources ↔ the user rail pools' device-plugin names.

## Gate 6 (do not proceed past failure)

Climb the validation ladder (design §7) — single node TP8 no spec → +MTP → 2-node gang DP+EP
no spec → full config; when something breaks, the ladder names the layer. Then: TTFT/ITL met ·
DeepEP dispatch p99 clean · acceptance ≥ threshold at night-shape, auto-disable at peak-shape ·
node kill = exactly one gang down, 75% serving, auto-rejoin · `numastat` on both sockets.
Wire `spec_decode_num_accepted_tokens_total` + DeepEP dispatch latency into the dashboard —
those two numbers decide whether this topology earns its keep.
