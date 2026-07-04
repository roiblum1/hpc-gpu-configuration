# Environment: `env/h100-8x-ib` — 8× DGX H100, InfiniBand, MiniMax M2.7 + DFlash

This branch adapts `main` (GLM-5.1 disaggregated, H200 + Blackwell, RoCEv2) to **8× DGX H100
over InfiniBand serving MiniMax M2.7 with DFlash speculative decoding**. Two documents govern
it: [glm51-openshift-deployment.md](glm51-openshift-deployment.md) keeps the phase/gate build
discipline and host-layer rationale, and
[minimax-m27-dflash-design.md](minimax-m27-dflash-design.md) is the serving design record
(the original LWS manifest is kept at
[reference/minimax-m27-dflash-lws.yaml](reference/minimax-m27-dflash-lws.yaml)). Where they
disagree with this file, **this environment follows this file**.

## The two structural changes

**1. Model + topology.** MiniMax M2.7 (230B MoE / 10B active, 256 experts) served as **4 wide-EP
gangs × 2 nodes** (= all 8 DGX H100): TP8 on NVLink inside each node; DP2 +
`--enable-expert-parallel` across the gang ⇒ experts EP16-wide, MoE all-to-all over IB via
DeepEP. **DFlash** is the day-one speculative method (draft: `z-lab/MiniMax-M2.7-DFlash`,
mirrored + staged); `disable_by_batch_size: 32` self-manages the day/night pattern, so there is
**no batch DGD**. A node loss kills exactly one gang → 75% keeps serving. Implemented by
[charts/minimax-dynamo](charts/minimax-dynamo) (a Dynamo + Grove translation of the LWS design:
`multinode.nodeCount: 2` = the gang; the Dynamo KV router replaces the plain leader Service; KAI
network-topology placement replaces `exclusive-topology`).

**2. Fabric = InfiniBand.** IB is credit-based lossless — the whole RoCE QoS layer disappears:
`roceQos.enabled: false` in node-foundation (no host DSCP/PFC/ECN/CNP), no `NCCL_IB_TC`/GID
env in the serving chart, RoCE exporter + PFC alert disabled in observability. Fabric QoS/health
is the subnet manager's job; Gate 1 gains `ibstat` all-rails-Active, and the mlxconfig
DCBX/RoCE rows in [charts/node-foundation/BIOS.md](charts/node-foundation/BIOS.md) don't apply
to IB-mode CX-7s.

## Delta from `main`, chart by chart

| Chart | Change |
|-------|--------|
| `minimax-dynamo` (was `glm51-dynamo`) | Full rewrite: one DGD (KV-router Frontend + `MinimaxWorker` 4 gangs × 2 nodes), DFlash spec-config (MTP one-value fallback), IB fabric env, worker PDB (`maxUnavailable: 1`), no KVBM/NIXL/batch lane |
| `model-staging` | Stages `minimax-m2.7` + `minimax-m2.7-dflash` (z-lab mirror, by digest) |
| `node-foundation` | `roceQos.enabled: false` — everything else unchanged (DGX H100 = 2×56-core, SMT off ⇒ the cpusets fit as-is) |
| `kai-scheduler` | Interactive quota/limit **64/64** (whole env, multiples of gang size 16). Enable network-topology-aware placement when vendoring the engine — it replaces the LWS `exclusive-topology` annotation |
| `gateway-tenancy` | Both hostnames → the single `minimax-m27-frontend`; serving namespace `llm-serving` |
| `observability` | `servingNamespace: llm-serving`; RoCE exporter + PFC alert off (IB); acceptance alert now watches DFlash |
| `install.sh` | `minimax-dynamo` row + IB gate texts; `sriov-rails` commented out (user-provided rails — Gate 3 still runs against them) |
| `gpu-operator`, `lvms-storage`, `cert-manager` | **Unchanged** (GDRCopy/peermem from gpu-operator are load-bearing here — DeepEP's IBGDA path needs them) |
| `sriov-rails` | **Untouched and unused** — IB rail policies/NADs come from the user's own templated config |

## What still applies unchanged

Gate-per-phase discipline · full-node pod pattern (8 GPUs + 8 rail VFs + integer CPUs,
Guaranteed QoS) · low-latency pod contract (`performance-gpu-hpc` + CRI-O annotations) ·
reserved CPUs `0-7,56-63` · CRI-O memlock=-1 (this is why the LWS manifest's `IPC_LOCK` is not
in the chart) · one quota brain / one router · hugepages small · etcd/NATS on infra nodes.

## The escape hatch (design §1 — keep it cheap)

If spec decode + multi-node DP+EP misbehave on the pinned vLLM build:
`worker.replicas: 8, nodeCount: 1, dataParallel: 1` ⇒ 8 single-node islands, zero
re-architecture. Wide-EP must buy > ~15% peak throughput to justify its worse blast radius
(25% vs 12.5% per node loss) — settle it by measurement at Gate 6/8.
