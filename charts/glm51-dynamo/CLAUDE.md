# CLAUDE.md — `glm51-dynamo` chart (Phase 6, env/h200-2x-roce: aggregated)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md), the deployment
doc §6 / §10, and this branch's [ENVIRONMENT.md](../../ENVIRONMENT.md) stay authoritative —
where the doc's disaggregated design and ENVIRONMENT.md disagree, this branch follows
ENVIRONMENT.md.

## Scope — what this chart owns (and does not)

**Owns:** the two `DynamoGraphDeployment`s (interactive lane + optional batch lane) and the
serving namespace. **Config only** — the Dynamo *platform* (operator + etcd + NATS) is upstream,
off by default (`upstream.install: false`); mirror/clone it and pin **etcd/NATS to infra nodes,
never GPU nodes**.

**Does NOT own:** VFs/NADs (**user-provided** on this branch — the `sriov-rails` chart is
unused) · host QoS + RuntimeClass existence (→ `node-foundation`) · queues/PriorityClasses
(→ `kai-scheduler`) · the front door (→ `gateway-tenancy` — and it must NOT pick endpoints).

## The branch's structural decision: aggregated, not disaggregated

This environment is **2× HGX H200 — no Blackwell decode pool**, so main's prefill/decode split
cannot exist. Each node is one complete TP8/FP8 engine:

- **Memory math:** GLM-5.1 FP8 ≈ 754 GB; one node = 8×141 = 1128 GB HBM → ~250–300 GB KV at
  0.9 utilization. Tight but serviceable; watch `gpu_cache_usage_perc` at Gate 6.
- **Survivability is why aggregated wins at N=2:** two independent replicas degrade to 50% on a
  node loss; a 1-prefill + 1-decode split stops entirely on *either* node's loss, for no
  redundancy gain.
- **No NIXL, no disagg transfer:** TP8 rides NVLink inside the node; the rails carry no serving
  traffic. They stay attached (full-node pattern, 8 GPUs + 8 VFs) for fleet parity and any
  future multi-node work — `rails: []` detaches them, and the templates guard the annotation.

## Why each configuration is what it is

- **`frontend.routerMode: kv` — THE inference router (single-brain rule #2).** Unchanged from
  main; with 2 replicas the KV/prefix-locality routing is still what makes session reuse pay.
  Frontends are CPU pods on **infra** nodes.
- **`worker.kvbm.enabled: false` — the aggregated-shape trade.** KVBM + TRT-LLM currently
  disables CUDA graphs. Main anchors KVBM on *prefill-only* workers so decode keeps its graphs;
  here decode shares the engine, so enabling KVBM taxes the decode hot loop directly. Default
  off; enable only if session park/resume is worth the ITL cost. When on, the §10 rules still
  bind: GPU-KV ≤ `cpuCacheGb` ≤ `diskCacheGb`, pod memory ≥ CPU tier, `diskPvc.size` ≥ disk
  tier, and the ephemeral per-pod PVC pattern (LVMS is node-local WaitForFirstConsumer).
- **MTP (`speculativeTokens: 1`) on interactive only; batch lane MTP OFF** — at high batch,
  verification overhead beats batching gains. Alert on acceptance rate (§8).
- **Full-node resources: integer `cpu: "96"` → Guaranteed QoS → exclusive pcpus.** Unchanged.
- **Low-latency pod contract:** `runtimeClassName: performance-gpu-hpc` + the CRI-O
  IRQ/cpu-quota disable annotations — the per-pod half of
  `globallyDisableIrqLoadBalancing: false`. Unchanged (§10 row).
- **Fabric env kept although idle:** the NCCL/UCX QoS env (TC 106 / GID 3) must stay equal to
  host QoS so that *if* rail traffic ever exists it rides the lossless queue. Costless when
  unused; silently wrong if dropped and later needed.
- **Batch lane = a second, smaller DGD** — same model, same weights LV; only scheduling
  identity (queue `serving-batch`, preemptible class) and engine tuning differ. It exists to be
  evicted. With interactive quota = the whole env (16), batch only ever runs when interactive
  is scaled down — that is intended.

## GPU↔NIC alignment

Mechanism unchanged from main (whole-node pod → NCCL/UCX walk PCIe topology → PIX pairing,
`NCCL_CROSS_NIC=0`), but in this shape it is a dormant property: no serving traffic crosses the
rails. Evidence requirements (Gate 2 `nvidia-smi topo -m` PIX) still apply — they validate the
platform, not this workload.

## Gate 6 (do not proceed past failure)

`genai-perf` sweep meets TTFT/ITL per lane · KV router shows prefix-locality spread across both
replicas · node kill test: surviving replica keeps serving while the router drains the dead one ·
`numastat -p <engine pid>`: engine memory split across **both** sockets (piled on socket 0 =
runtime thread pinning is wrong → socket-1 GPUs pay UPI latency).
