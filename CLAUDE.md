# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is a **documentation repository**, not a software project. It contains a single deliverable:

- [glm51-openshift-deployment.md](glm51-openshift-deployment.md) — the unified deployment architecture for serving **GLM-5.1** (754B MoE / 40B active) on **disconnected, bare-metal OpenShift 4.20** (K8s 1.33), on Dell XE9680-class HGX nodes (H200 / B200 / B300, 8 GPUs + 8 RoCEv2 rail NICs each).

There is **no build, lint, or test step** — the YAML/bash blocks inside the document are illustrative manifests and scripts, not a runnable project. "Working in this repo" means editing, extending, or fact-checking this architecture document. Validate changes by reading, not by running tooling.

## How the document is structured

It is written as an **ordered build sequence**, not a reference manual. Read and edit it in that frame:

- **Phase 0 → Phase 8**, each building on the prior. Phase 0 is disconnected/mirroring prerequisites; Phases 1–8 are node foundation → GPU Operator → SR-IOV RoCE rails → LVMS storage → KAI scheduler → Dynamo + GLM-5.1 → Gateway/tenancy → observability soak.
- **Every phase ends with a "Gate N" validation block.** The cardinal rule stated up front: *do not proceed past a failed gate* — an error at one layer surfaces as an unexplained symptom three layers later (e.g. a wrong PCIe ACS setting shows up as "Dynamo is slow"). Preserve this gate-per-phase discipline when adding content.
- **§10 "Cross-layer integration matrix"** is the document's source of truth for invariants. Each row is one value that multiple phases must agree on. The "Deployment order recap" at the end mirrors the phase sequence with the gate for each.

## Editing rules that matter here

**The hard part of this document is cross-layer consistency.** Many concrete values appear in several phases and *must* stay identical. If you change one, grep the whole document and update every occurrence, then check it against §10. The load-bearing shared values:

- **RoCE QoS triple: DSCP 26 / traffic class 106 / GID index 3 (RoCEv2).** Appears in the host `mlnx_qos`/`tc` config (1.4), `NCCL_IB_TC` + `NCCL_IB_GID_INDEX`, `UCX_IB_TRAFFIC_CLASS` + `UCX_IB_GID_INDEX` (3.4), and the switch fabric. NCCL (collectives) and UCX (NIXL KV transfers) must agree or one silently rides the lossy queue.
- **MTU 9000 end-to-end** — NIC PF, `SriovNetworkNodePolicy.mtu`, pod NADs, switch.
- **Rail map: GPU n ↔ NIC n ↔ socket.** Rails 0–3 on socket 0, 4–7 on socket 1; assumes `NCCL_CROSS_NIC=0`; evidence is `nvidia-smi topo -m` showing PIX/PXB (not NODE/SYS).
- **Full-node pod granularity** — one worker pod = 8 GPUs + 8 rail VFs + integer CPUs (Guaranteed QoS). This is *why* `topologyPolicy: best-effort` is used instead of `single-numa-node` (which would reject these pods); intra-pod NUMA correctness is delegated to the runtime.
- **KVBM tier ordering: GPU-KV ≤ `DYN_KVBM_CPU_CACHE_GB` ≤ `DYN_KVBM_DISK_CACHE_GB`**, with pod memory ≥ CPU tier and LVMS PVC ≥ disk tier. Violating the ordering misconfigures the cache.
- **Reserved CPUs `0-7,56-63`** in the PerformanceProfile — kept on both sockets deliberately for per-NUMA memory + NIC IRQ steering.

**Two "single brain" rules** the design depends on — do not introduce anything that violates them:

1. **One GPU quota brain = KAI Scheduler.** No Kueue, no second ClusterQueue, no Run:ai quota project pointed at these nodes.
2. **One inference router = Dynamo's KV-aware router.** The Gateway layer does identity/budgets/lane selection only — it must not do endpoint picking (no GIE EPP in front of the Dynamo frontend).

**Per-SKU pool mapping** is fixed: prefill = H200 + FP8 + TP8; decode = B200/B300 + NVFP4 + wide-EP. Never mix B200 and B300 inside one EP group. The `gpu.hpc/sku` node label drives DGD nodeSelectors.

**Other design invariants worth knowing before you edit a phase:**
- KVBM lives on **prefill** workers (decode keeps CUDA graphs on) — because KVBM + TRT-LLM currently disables CUDA graphs, which matter most on the decode hot loop.
- etcd/NATS go on **infra/control nodes, never GPU nodes** — a node drain must not take the control plane down with the capacity.
- Hugepages are kept **small on purpose** (16×1G) — KVBM's host tier uses CUDA pinned memory, not hugetlbfs; large hugepage reservations would steal RAM from the tier being built.
- Rate-limit **tokens, not requests** at the Gateway — agentic traffic is wildly asymmetric.

When the document hedges (e.g. "flag names per your pinned version's recipe", LVMS thin-vs-thick, token-aware RHCL rate limiting), preserve that honesty — these are deliberate "decide on gate numbers, not principle" notes, not gaps to confidently fill in.
