# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Environment branch `env/h200-2x-roce`** — 2× HGX H200, RoCEv2, GLM-5.1 FP8 **aggregated**
> (no Blackwell → no disaggregation; `sriov-rails` unused, rails are user-provided). Read
> [ENVIRONMENT.md](ENVIRONMENT.md) before editing — where it and the architecture doc disagree,
> this environment follows ENVIRONMENT.md.

## What this repository is

This repo holds **two co-dependent deliverables** for serving **GLM-5.1** (754B MoE / 40B active) on **disconnected, bare-metal OpenShift 4.20** (K8s 1.33), on Dell XE9680-class HGX nodes (H200 / B200 / B300, 8 GPUs + 8 RoCEv2 rail NICs each):

1. [glm51-openshift-deployment.md](glm51-openshift-deployment.md) — the **architecture document**: the prose rationale, the ordered build sequence, the validation gates, and the cross-layer invariants. This is the source of truth.
2. [charts/](charts/) — a **Helm chart set that implements the document**, one chart per phase/subject. The chart YAML must stay faithful to the doc; the doc is authoritative when they disagree.

The two move together: a change to a load-bearing value (see "Editing rules") must land in **both** the document and the relevant chart's `values.yaml`. The YAML/bash blocks *inside the document* are still illustrative; the runnable manifests live in `charts/`.

## Commands

There is no application build/test. The only tooling is Helm rendering, run from `charts/`:

```bash
helm lint <chart>                  # e.g. helm lint glm51-dynamo
helm template <chart>              # render manifests to inspect what would apply
helm template <chart> | helm lint --strict -   # tighter check
./install.sh                       # print the ordered phase plan + per-gate reminders, then install all (pausing at each gate)
./install.sh <chart>               # install one chart and print its gate
```

`install.sh` is a thin `helm upgrade --install` wrapper that hard-codes the phase order and the Gate-N reminder for each chart. Use it (or the doc's "Deployment order recap") as the canonical sequence — never reorder.

## How the document is structured

It is written as an **ordered build sequence**, not a reference manual. Read and edit it in that frame:

- **Phase 0 → Phase 8**, each building on the prior. Phase 0 is disconnected/mirroring prerequisites; Phases 1–8 are node foundation → GPU Operator → SR-IOV RoCE rails → LVMS storage → KAI scheduler → Dynamo + GLM-5.1 → Gateway/tenancy → observability soak.
- **Every phase ends with a "Gate N" validation block.** The cardinal rule stated up front: *do not proceed past a failed gate* — an error at one layer surfaces as an unexplained symptom three layers later (e.g. a wrong PCIe ACS setting shows up as "Dynamo is slow"). Preserve this gate-per-phase discipline when adding content.
- **§10 "Cross-layer integration matrix"** is the document's source of truth for invariants. Each row is one value that multiple phases must agree on. The "Deployment order recap" at the end mirrors the phase sequence with the gate for each.

## How the charts are structured

`charts/` mirrors the phases, **one chart per subject** (model-staging, node-foundation, gpu-operator, sriov-rails, lvms-storage, cert-manager, kai-scheduler, glm51-dynamo, gateway-tenancy, observability). Conventions to preserve:

- **Every chart carries a scoped `CLAUDE.md`** — scope (owns / does-not-own), *why* each value is what it is, the §10 invariants it carries, and its gate. Read it before editing that chart; update it when you change a load-bearing value. Out-of-band host config lives in [charts/node-foundation/BIOS.md](charts/node-foundation/BIOS.md) (BIOS + `mlxconfig`); rail addressing/routing rationale in [charts/sriov-rails/ROUTING.md](charts/sriov-rails/ROUTING.md).
- **Self-contained operators.** Where a subject needs an OLM operator, that operator's `Subscription`/`OperatorGroup` ships *inside the same chart* as the CRs it manages — not in a separate "operators" chart.
- **`# §10` markers.** Every value that participates in a cross-layer invariant is tagged with a `# §10` comment at the top of its `values.yaml`. These are the chart-side mirror of the §10 matrix below. Treat them as a grep target: change one, `grep -rn "§10" charts/*/values.yaml`, and update every chart that shares the value.
- **The two upstream engines are *not* vendored.** `kai-scheduler` and `glm51-dynamo` ship **only our config** (queues/priority-classes; the DynamoGraphDeployments) so they render standalone. The big upstream charts (the KAI engine; the Dynamo platform = operator + etcd + NATS) are installed separately and are **off by default** (`upstream.install: false`) for disconnected installs — mirror/clone them, or vendor as a subchart (`dependencies:` → drop into `charts/<chart>/charts/` → `helm dependency build`). Every image/chart ref is a `<your-registry>` / `<your-mirror>` placeholder to be pinned per Phase 0.
- **Out of band, on purpose.** The BIOS checklist (Phase 1.5: ACS off, Max Read Request 4096, NPS=1, SNC off) and Phase 0 registry mirroring are host/registry actions, not K8s objects — they live in the document only, never as a chart.

## Editing rules that matter here

**The hard part of this repo is cross-layer consistency.** Many concrete values appear in several phases — and now in several charts — and *must* stay identical. If you change one, grep **both** the document and `charts/*/values.yaml` (`# §10` markers), update every occurrence, then check it against §10. The load-bearing shared values:

- **RoCE QoS triple: DSCP 26 / traffic class 106 / GID index 3 (RoCEv2).** Appears in the host `mlnx_qos`/`tc` config (1.4), `NCCL_IB_TC` + `NCCL_IB_GID_INDEX`, `UCX_IB_TRAFFIC_CLASS` + `UCX_IB_GID_INDEX` (3.4), and the switch fabric. NCCL (collectives) and UCX (NIXL KV transfers) must agree or one silently rides the lossy queue. The CNP side (DSCP 48 / priority 6, `roce_np` sysfs) is pinned in the same host script and must mirror the switch CNP queue.
- **MTU 9000 end-to-end** — NIC PF, `SriovNetworkNodePolicy.mtu`, pod NADs, switch.
- **Rail map: GPU n ↔ NIC n ↔ socket.** Rails 0–3 on socket 0, 4–7 on socket 1; assumes `NCCL_CROSS_NIC=0`; evidence is `nvidia-smi topo -m` showing PIX/PXB (not NODE/SYS).
- **Full-node pod granularity** — one worker pod = 8 GPUs + 8 rail VFs + integer CPUs (Guaranteed QoS). This is *why* `topologyPolicy: best-effort` is used instead of `single-numa-node` (which would reject these pods); intra-pod NUMA correctness is delegated to the runtime.
- **Low-latency pod contract** — GPU worker pods carry `runtimeClassName: performance-gpu-hpc` (NTO-generated from the PerformanceProfile name) plus `irq-load-balancing.crio.io`/`cpu-quota.crio.io: "disable"` annotations. This is the per-pod half of `globallyDisableIrqLoadBalancing: false` — remove one side and IRQ isolation silently degrades.
- **KVBM tier ordering: GPU-KV ≤ `DYN_KVBM_CPU_CACHE_GB` ≤ `DYN_KVBM_DISK_CACHE_GB`**, with pod memory ≥ CPU tier and LVMS PVC ≥ disk tier. Violating the ordering misconfigures the cache.
- **Reserved CPUs `0-7,56-63`** in the PerformanceProfile — kept on both sockets deliberately for per-NUMA memory + NIC IRQ steering.

**Two "single brain" rules** the design depends on — do not introduce anything that violates them:

1. **One GPU quota brain = KAI Scheduler.** No Kueue, no second ClusterQueue, no Run:ai quota project pointed at these nodes.
2. **One inference router = Dynamo's KV-aware router.** The Gateway layer does identity/budgets/lane selection only — it must not do endpoint picking (no GIE EPP in front of the Dynamo frontend).

**Per-SKU pool mapping** is fixed: prefill = H200 + FP8 + TP8; decode = B200/B300 + NVFP4 + wide-EP. Never mix B200 and B300 inside one EP group — in `glm51-dynamo` a B300 decode pool is a **separate DGD release**, not a tweak to the B200 values. The `gpu.hpc/sku` node label drives DGD nodeSelectors.

**Other design invariants worth knowing before you edit a phase:**
- KVBM lives on **prefill** workers (decode keeps CUDA graphs on) — because KVBM + TRT-LLM currently disables CUDA graphs, which matter most on the decode hot loop.
- etcd/NATS go on **infra/control nodes, never GPU nodes** — a node drain must not take the control plane down with the capacity.
- Hugepages are kept **small on purpose** (16×1G) — KVBM's host tier uses CUDA pinned memory, not hugetlbfs; large hugepage reservations would steal RAM from the tier being built.
- Rate-limit **tokens, not requests** at the Gateway — agentic traffic is wildly asymmetric.

When the document hedges (e.g. "flag names per your pinned version's recipe", LVMS thin-vs-thick, token-aware RHCL rate limiting), preserve that honesty — these are deliberate "decide on gate numbers, not principle" notes, not gaps to confidently fill in.
