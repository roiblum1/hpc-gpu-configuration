# glm51-dynamo — Phase 6

The GLM-5.1 serving deployment itself: two `DynamoGraphDeployment`s (an interactive lane and an optional batch lane) running disaggregated prefill + decode with KV-aware routing, KVBM tiering, and the low-latency pod contract.

## Why it matters

This is where the whole stack becomes a served model. It encodes the load-bearing serving decisions — disaggregation (H200/FP8 prefill ↔ Blackwell/NVFP4 decode), KVBM on prefill so decode keeps CUDA graphs, the KVBM tier-size ordering, and the per-pod IRQ/RuntimeClass contract that keeps rail-NIC interrupts off the pinned cores. It's **config only**: the Dynamo platform (operator + etcd + NATS) is upstream.

## What it deploys

- **Interactive DGD** — Frontend (KV router, on infra nodes) + `GLM51Prefill` (H200/FP8/TP8, KVBM) + `GLM51Decode` (Blackwell/NVFP4, wide-EP, CUDA graphs + MTP).
- **Batch DGD** (optional) — a smaller clone: same model + weights LV, queue `serving-batch`, preemptible, MTP off.
- The serving namespace.

The **Dynamo platform is upstream** and off by default (`upstream.install: false`) — pin etcd/NATS to **infra nodes, never GPU nodes**.

## Prerequisites & position

Last of the compute phases — needs node-foundation (RuntimeClass), gpu-operator, sriov-rails (rails), lvms-storage (KV PVC), cert-manager (Dynamo webhooks), and kai-scheduler (queues). The front door is Phase 7.

## How to use

```bash
../install.sh glm51-dynamo
helm template glm51-dynamo       # inspect both DGDs (interactive + batch)
```

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `frontend.routerMode` | `kv` | **THE** inference router (KV/prefix-aware). Nothing may endpoint-pick in front of it. §10 |
| `frontend.replicas` | `4` | CPU pods on **infra** nodes (never GPU-node reserved cores) |
| `prefill` | H200 / FP8 / TP8 / KVBM | Compute-bound pool; TP8 stays intra-node on NVLink; KVBM anchored here |
| `prefill.kvbm.cpuCacheGb` / `diskCacheGb` | `1024` / `2048` | KVBM tiers — ordering **GPU-KV ≤ CPU ≤ DISK** is a write-through invariant. §10 |
| `prefill.kvbm.initTimeoutSecs` | `1200` | Pinning ~1 TB takes minutes — default timeout would kill workers mid-init |
| `prefill.diskPvc.size` | `2200Gi` | Must be ≥ `diskCacheGb`; on the LVMS kvcache class. §10 |
| `decode` | Blackwell / NVFP4 / DP16 | Memory-bandwidth-bound; `nodeCount: 2` → each replica a Grove gang KAI schedules atomically |
| `decode.speculativeTokens` | `1` | One MTP head — **interactive only** (batch lane MTP off) |
| `runtimeClassName` | `performance-gpu-hpc` | Hard reference to the NTO-generated class — rename the PerformanceProfile and this must follow. §10 |
| `fabric.trafficClass` / `gidIndex` | `106` / `3` | NCCL/UCX must equal host QoS or they ride the lossy queue. §10 |
| `sku.prefill` / `sku.decode` | `h200` / `b200` | Node-label SKU mapping. A **B300 pool is a separate DGD release** — never mix in one EP group |
| `batchLane.enabled` | `true` | The preemptible second DGD |

## GPU↔NIC alignment (the common question)

Kubernetes can only align at **NUMA-node granularity** — device plugins report a GPU's and a VF's socket, and Topology Manager co-locates them per socket; "GPU 3 must get rail 3's VF" is inexpressible in the kubelet API. This design gets exact pairing anyway **by construction**: the pod takes the **whole node** (all 8 GPUs + 8 VFs), and inside it NCCL/UCX walk the PCIe topology and pick, per GPU, the closest NIC (same PCIe switch, PIX). `NCCL_CROSS_NIC=0` forbids fallback; per-rail L3 segments make cross-rail traffic unroutable. **A 1-GPU pod has no such guarantee** — that needs a `single-numa-node` pool (socket-level) or DRA with device-attribute selectors (exact). See [CLAUDE.md](CLAUDE.md) for the full treatment.

## Gate 6 (do not proceed past failure)

`genai-perf` sweep meets TTFT/ITL per lane · disagg verified (NIXL counters move; decode never prefilling long prompts) · session park/resume: resume TTFT ≪ initial prefill, KVBM onboard counters account for it · `numastat -p <engine pid>`: pinned CPU tier split across **both** sockets.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance (incl. the full GPU↔NIC alignment and KVBM/CUDA-graph rationale).
