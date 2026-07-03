# CLAUDE.md — `glm51-dynamo` chart (Phase 6)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §6 / §10 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** the two `DynamoGraphDeployment`s (interactive lane + optional batch lane) and the
serving namespace. **Config only** — the Dynamo *platform* (operator + etcd + NATS) is upstream,
off by default (`upstream.install: false`); mirror/clone it and pin **etcd/NATS to infra nodes,
never GPU nodes** (a GPU-node drain must not take the discovery/event plane down with the
capacity).

**Does NOT own:** VFs/NADs (→ `sriov-rails`) · host QoS + RuntimeClass existence
(→ `node-foundation`) · queues/PriorityClasses (→ `kai-scheduler`) · the front door
(→ `gateway-tenancy` — and it must NOT pick endpoints; see below).

## Why each configuration is what it is

- **`frontend.routerMode: kv` — THE inference router (single-brain rule #2).** KV/prefix-aware
  routing is where cache-hit GPU-time savings come from. Nothing may sit in front of it doing
  endpoint picking (no GIE EPP): two routers disagree about placement and the KV-locality signal
  dies. Frontends are CPU pods on **infra** nodes — they must not burn GPU-node reserved cores.
- **Prefill: H200 / FP8 / TP8 / chunked prefill.** Prefill is compute-bound — H200 FP8 FLOPs are
  well matched; TP8 stays intra-node so NVLink carries it and the fabric doesn't. Chunk size is
  the TTFT-fairness knob on 200K contexts — tune at Gate 6 with mixed-length traffic.
- **Decode: Blackwell / NVFP4 / TP1 × DP16 (wide-EP).** Decode is memory-bandwidth-bound —
  Blackwell HBM + NVFP4 maximizes KV residency and tokens/s; 256 experts shard cleanly (EP16 →
  16 experts/GPU). `nodeCount: 2` makes each replica a **Grove gang KAI schedules atomically**.
  **A B300 pool is a separate DGD release** — an EP group runs at its slowest member's step
  time; never mix B200/B300 in one group.
- **KVBM on prefill only (`connector: kvbm`), decode keeps CUDA graphs.** KVBM + TRT-LLM
  currently disables CUDA graphs, which matter most on the decode hot loop; disagg offload is
  anchored on prefill anyway (compute KV → NIXL to decode → write-through to DRAM/NVMe).
  Revisit when the limitation lifts (§10 row).
- **KVBM sizing is a write-through invariant:** GPU-KV ≤ `cpuCacheGb` (1024) ≤ `diskCacheGb`
  (2048), pod `memory` (1800Gi) ≥ CPU tier + runtime headroom, `diskPvc.size` (2200Gi) ≥ disk
  tier. Violate the ordering and the cache misconfigures silently. `initTimeoutSecs: 1200`
  because pinning ~1 TB takes minutes — the default timeout kills workers mid-init.
- **Per-pod ephemeral PVC for the disk tier** (generic ephemeral volume): LVMS is node-local
  WaitForFirstConsumer — a shared RWO PVC cannot serve replicas > 1. One PVC per worker, born
  and dying with it, on its node.
- **Full-node resources: integer `cpu: "96"` → Guaranteed QoS → exclusive pcpus** from the
  static CPU manager. All 8 rails + all 8 GPUs per worker — see the alignment section below for
  why this *is* the GPU↔NIC alignment mechanism.
- **Low-latency pod contract:** `runtimeClassName: performance-gpu-hpc` (hard reference to the
  NTO-generated class — rename the PerformanceProfile and this value must follow) +
  `irq-load-balancing.crio.io`/`cpu-quota.crio.io: "disable"` annotations. This is the per-pod
  half of `globallyDisableIrqLoadBalancing: false`; remove one side and IRQ isolation silently
  degrades (§10 row).
- **Fabric env (`glm51.fabricEnv` helper):** `NCCL_IB_TC`/`UCX_IB_TRAFFIC_CLASS` = **106** and
  GID index = **3** must equal `node-foundation`'s host QoS or NCCL/UCX silently ride the lossy
  queue; NCCL carries EP/TP collectives, **UCX carries NIXL KV transfers** — both must agree.
  `NCCL_SOCKET_IFNAME=eth0` keeps the control path on the pod net, never on rails.
  `NCCL_CROSS_NIC=0` assumes the rail map holds.
- **MTP (`speculativeTokens: 1`) on interactive decode only; batch lane MTP OFF** — at high
  batch, verification overhead beats batching gains. Alert on acceptance rate (§8).
- **Batch lane = a second, smaller DGD** — same model, same weights LV; only scheduling identity
  (queue `serving-batch`, preemptible class) and engine tuning differ. It exists to be evicted.

## How GPU↔NIC alignment actually works (read before "fixing" it)

Kubernetes can only align devices at **NUMA-node granularity**: the device plugins report each
GPU's and each VF's NUMA affinity, and Topology Manager intersects the hints at admission. It
can put a GPU and a VF *on the same socket*; it **cannot** express "GPU 3 must get rail 3's VF" —
that pairing is invisible to the kubelet API.

This design gets exact pairing anyway, by construction:

1. **The pod takes the whole node** — all 8 GPUs + all 8 rail VFs in one netns. Allocation-time
   pairing becomes a non-question: everything is in the pod.
2. **Inside the pod, NCCL/UCX walk the PCIe topology** (sysfs) and pick, per GPU, the *closest*
   NIC — the rail NIC behind the same PCIe switch (PIX distance). GPU n ↔ NIC n emerges from
   hardware distance, not from configuration. `NCCL_CROSS_NIC=0` forbids falling back to a
   farther NIC, and per-rail L3 segments make cross-rail traffic unroutable anyway.
3. **Evidence, not hope:** `nvidia-smi topo -m` must show PIX per pair (Gate 2 — depends on BIOS
   ACS-off), and `NCCL_DEBUG=INFO` at Gate 3 must show rail-aligned GDRDMA paths.

If you ever run **1-GPU pods** (`nvidia.com/gpu: 1` + one rail resource): best-effort TM may not
even keep GPU and VF on the same socket, and nothing guarantees the *paired* rail. Options, in
order of preference: don't (full-node is the serving contract here) · a separate pool with
`single-numa-node` TM for socket-level alignment (never on the serving pool — it would reject
full-node pods) · exact pairing needs **DRA** (GA in OCP 4.21+/K8s 1.34) with device-attribute
selectors — the §10 "DRA migration path" row keeps rail pool names 1:1 with future
ResourceClaims for exactly this.

## Gate 6 (do not proceed past failure)
`genai-perf` sweep meets TTFT/ITL per lane · disagg verified (NIXL counters move; decode never
prefilling long prompts) · session park/resume: resume TTFT ≪ initial prefill, KVBM onboard
counters account for it · `numastat -p <engine pid>`: pinned CPU tier split across **both**
sockets (piled on socket 0 = runtime thread pinning is wrong → socket-1 GPUs pay UPI latency).
