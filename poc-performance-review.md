# Absolute Maximum Performance Optimization Review — GLM Inference POC on OpenShift 4.22 / K8s 1.35

> Review of a 2× Dell XE9680 (8× H200 + 8× ConnectX-6 @ 100G) rail-aligned RoCEv2 POC on OpenShift 4.22, against the `glm51-openshift-deployment.md` baseline design and current Cisco / NVIDIA / Red Hat documentation.

## Honesty notes before the analysis

- **Only the markdown architecture doc was attached** — no "Scaled HPC Cluster Architecture PDF" made it into the session. Share it and it can be reviewed separately.
- The POC specs (OCP 4.22 / K8s 1.35, CX-6 @ 100G, all-H200) **differ from the baseline doc's assumptions** (OCP 4.20, CX-7 @ 400G, B200/B300 decode) in ways that change several concrete numbers. Those deltas are called out throughout.

Verified load-bearing external facts:

- [DRA went GA in OpenShift 4.21](https://developers.redhat.com/articles/2026/03/25/dynamic-resource-allocation-goes-ga-red-hat-openshift-421-smarter-gpu).
- [OCP 4.22 (K8s 1.35) GA'd June 2026 with partitionable devices as Tech Preview and the DAS operator removed](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes).
- [Cisco's AI/ML blueprint classifies RoCE on **DSCP 24 (CS3)** and CNP on **DSCP 48 / qos-group 7**](https://www.cisco.com/c/en/us/td/docs/dcn/whitepapers/cisco-data-center-networking-blueprint-for-ai-ml-applications.html), WRED 150 KB / 3000 KB / 7%.
- [DRANET measured gains are up to 59.6% all_gather / 58.1% all_reduce busbw](https://github.com/kubernetes-sigs/dranet) — **versus topology-unaware allocation**.

---

## The three findings that matter most (read these even if you skip the rest)

### ① Your host DSCP convention and your "out of the box" Cisco fabric almost certainly disagree

The repo doc pins RoCE to **DSCP 26 (traffic class 106)**. Cisco's AI/ML blueprint — which is what Nexus Dashboard's plug-and-play RoCE templates implement — classifies RoCE into the no-drop queue on **DSCP 24 (CS3)**, CNP on DSCP 48. If your NICs mark 106/DSCP 26 and the fabric matches DSCP 24, your RDMA traffic **silently rides the lossy best-effort queue** — the exact failure mode §10 warns about, and it will look like "NCCL is flaky under load" three layers up.

**Fix:** dump the actual deployed policy (`show policy-map type qos`, `show class-map`) and pick one convention. If the fabric says DSCP 24, host traffic class becomes **98** (24×4 + ECN bits — the [DOCA RoCE doc](https://networking-docs.nvidia.com/doca/archive/3-4-0/rdma-over-converged-ethernet.md) confirms the ToS = DSCP×4 arithmetic), and `NCCL_IB_TC` / `UCX_IB_TRAFFIC_CLASS` / `cma_roce_tos` all move with it. Either value is fine; **disagreement is not.**

### ② Your per-NIC NAD implementation violates the doc's own "never per-node NADs" invariant

You said each NIC gets a `SriovNetwork` with its IP, gateway, and route — that's 16 NADs for 2 nodes and N×8 at scale. It works today only because placement is trivial with 2 nodes. Pods request networks *before* scheduling, so per-node NADs can't survive the big build.

The doc's §3.2 already encodes the fix for routed /31 fabrics: **one NAD per rail, BGP-unnumbered style — omit `gateway`, use on-link `routes`** so the per-node next hop drops out of the NAD entirely. **Prove that pattern on the POC now**; it's the single highest-value thing this POC can de-risk for the real cluster.

### ③ Nexus DLB mode vs ConnectX-6 ordering

Dynamic load balancing in **flowlet** mode is safe for RoCE. **Per-packet spraying is not safe on CX-6** — out-of-order RDMA placement support is a CX-7-generation capability, and CX-6 will take reordering as retransmits / perf collapse. Confirm which mode Nexus Dashboard enabled before trusting any benchmark number.

---

## Q1 — What you're doing right

- **Rail-per-segment L3 isolation with /31 point-to-points + BGP/ECMP** is exactly how Tier-1 AI fabrics are built, and it matches the doc's routed-fabric model. Strict per-rail segments naturally enforce `NCCL_CROSS_NIC=0` — cross-rail traffic *can't* route, so topology alignment is structural, not env-var-hopeful. Stronger than most shops manage.
- **`numVfs: 1`, 1:1 GPU:NIC, no MIG** — correct for whole-GPU serving, matches the doc's current values. Consequence to plan around: Gate-3-style validation pods can't coexist with serving pods on the same rail. Run fabric gates before serving occupies the node (or temporarily bump to 2 VFs during bring-up).
- **`trust: on` / `spoofChk: off` / RDMA VFs** — matches the repo. API accuracy note: the policy field is `isRdma: true` (not `rdmaenabled`), and `trust` / `spoofChk` are strings `"on"` / `"off"` on the `SriovNetwork`.
- **FE/BE separation via a dedicated bond + `dst` routes in the NAD** — right pattern; keeps the pod's default route on the frontend and pins RDMA/control-plane data onto rails without iptables heroics.
- **Local NVMe for KV, Dynamo + Grove for disagg + gangs** — right shape. Terminology check: "LVMO (Local Storage Operator)" conflates two operators — **LVMS** (dynamic LVM provisioning, thin pools — what the doc uses) and **LSO** (static local PVs — the doc's escape hatch if thin-pool overhead shows up in fio/gdsio). Decide which you're actually running; for KVBM's disk tier either works *only* with **xfs + fallocate**.
- **On SriovIBNetwork** (directive #2): irrelevant to you — `SriovIBNetwork` is for InfiniBand link-layer fabrics. Yours is Ethernet/RoCEv2, so `SriovNetwork` NADs are the correct and only path. The Multus/NAD "overhead" is pod-startup control-plane only; the datapath is kernel-bypass verbs on the VF — zero per-packet cost.

## Q2 — What to improve (and where the doc does/doesn't transfer)

The doc's *principles* transfer intact; three of its *assumptions* don't, and every derived number changes with them:

1. **CX-7 @ 400G → CX-6 @ 100G.** Gate 3's "≥370 Gb/s/rail" becomes **~96–97 Gb/s/rail** (`ib_write_bw --report_gbits`). Node-to-node aggregate is ~100 GB/s instead of ~400 GB/s, which directly stretches NIXL prefill→decode KV transfer: a ~50–100 GB KV set for a very long context is ~1 s of transfer even striped perfectly across 8 rails. Set your TTFT targets for the disagg path from *this* number, not the doc's.
2. **B200/NVFP4 decode → all-H200.** NVFP4 is Blackwell hardware; on H200 both pools run **FP8**, and the per-SKU pool split collapses. The doc's Stage A (vLLM on both pools, KVBM on prefill, CUDA graphs + MTP on decode) is *exactly* your POC — Stage B (TRT-LLM/NVFP4) doesn't exist for you until Blackwell arrives. With 2 nodes, disagg means 1 prefill node + 1 decode node (each holds full FP8 weights, TP8 — fits in 8×141 GB). That's the right POC config for *validating mechanics*, but also benchmark **aggregated mode** (one EP16 across both nodes) as a baseline — at 100G rails, disagg's win is not guaranteed at this scale, and knowing the crossover is real data for the big build.
3. **OCP 4.20 → 4.22.** The doc's "DRA waits for 4.21+, never TechPreviewNoUpgrade" hedge has *resolved*: DRA is GA on your platform. See Q3 on DRANET.

**Honest criticism of the doc's history:** as originally written it claimed CNP marking was pinned but its host script never actually set `cnp_dscp` / `cnp_802p_prio`, and it asserted "IRQs land on reserved CPUs" without the per-pod RuntimeClass + CRI-O annotation contract that delivers it. Both were found and fixed in the current revision (§1.4, §3.3) — but they're precisely the two things your POC hasn't implemented at all (see Q3).

## Q3 — Blind spots (things you're not doing at all)

**Host/OS layer — you described no NTO tuning whatsoever.** Apply the doc's Phase 1 to the POC essentially verbatim: dedicated MCP, PerformanceProfile (reserved cores on *both* sockets, `best-effort` topology policy, small hugepages), the child Tuned profile (`min_free_kbytes`, memlock CRI-O drop-in), and the RoCE QoS systemd unit — with the traffic-class value corrected per finding ①. Without the CRI-O memlock drop-in, ibverbs registration inside pods fails in ways that masquerade as NCCL bugs.

**The low-latency pod contract.** `runtimeClassName: performance-<profile>` + `irq-load-balancing.crio.io: "disable"` + `cpu-quota.crio.io: "disable"` on worker pods (§3.3 / §6.4). This is the mechanism that keeps rail-NIC IRQs off your pinned cores; `globallyDisableIrqLoadBalancing: false` alone does not do it.

**XE9680 BIOS (Intel chassis):** System Profile = Performance; **SNC off** (preserves "1 socket = 1 NUMA = 4 GPUs + 4 rails"); **VT-d on + SR-IOV global enable** (SR-IOV won't function otherwise) with `intel_iommu=on iommu=pt`; **ACS off** on the PCIe switches (evidence: `nvidia-smi topo -m` shows PIX/PXB GPU↔NIC, not NODE/SYS); MRRS 4096 + relaxed ordering via `mlxconfig`; ASPM off; decide SMT and keep cpusets sibling-aligned.

**NUMA Resources Operator:** skip it *for this design*. NRO + `single-numa-node` matters for sub-node pods; your inference pods are full-node (8 GPU + 8 VF) and would be **rejected** under single-numa-node. The doc's `best-effort` + runtime-internal pinning decision is correct for you. NRO becomes relevant only if you later run per-GPU pods needing hard GPU+NIC NUMA co-location.

**DRANET (the 60% question):** the [59.6% / 58.1% busbw gains](https://cloud.google.com/blog/products/networking/introducing-managed-dranet-in-google-kubernetes-engine) are measured against *topology-unaware* NIC allocation. Your 8 named SR-IOV pools + device-plugin NUMA affinity + full-node pods already capture most of that alignment — do **not** expect +60% on top of a correct rail design. The real DRANET/DRA value for you is operational (claim-based GPU+NIC co-allocation, CEL selectors) at the big-cluster stage. It's a kubernetes-sigs project, not Red Hat-supported; keep the SR-IOV operator as the supported path, pilot DRANET in a lab on 4.22, and keep rail pool names 1:1 with future ResourceClaim names (already a §10 row).

**Gang scheduling has a hole:** Grove *creates* PodGangs; something must *honor* them. On 2 nodes you won't notice; at scale, without KAI (or an equivalent gang-aware scheduler) you'll get partial placements and wedged EP groups. The doc's Phase 5 (KAI queues, quota, atomic reclaim) is missing from your stack entirely — the second-biggest thing to rehearse on the POC before the big build.

**Also missing:** model staging (don't pull 754 GB through CRI-O image layers — doc Phase 0), GDS (`nvidia-fs`) + gdrcopy + open kernel modules for the DMA-BUF GDR path, etcd/NATS pinned off GPU nodes, and per-rail observability (PFC/CNP/out_of_buffer counters exported — doc Phase 8).

## Q4 — What to watch for

- **DLB mode** (finding ③) — flowlet yes, per-packet no, on CX-6.
- **QoS drift**: "out of the box" fabric config is a moving target across Nexus Dashboard updates. Treat the switch policy as config-as-code; re-verify counters after every fabric change.
- **PFC storm/deadlock**: enable the PFC watchdog on the Nexus side; alert on pause duration (doc Phase 8's alert minimums).
- **Whereabouts/IPAM leaks** on ungraceful node loss (if you move off static IPAM); stale IPs block reschedules.
- **K8s 1.35 / OCP 4.22 specifics**: cgroup v2 only; [DAS operator removed, partitionable devices are TP](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes) — don't build on TP features in a cluster you can't recreate.
- **KVBM + CUDA graphs**: the doc's collision note is TRT-LLM-specific; verify the current status for your pinned vLLM before assuming decode keeps graphs with any KVBM involvement.
- **Two nodes lie to you**: bin-packing, reclaim, ECMP polarization, and incast all behave qualitatively differently at 2 nodes. Mark every POC conclusion that's scale-sensitive.

## Q5 — How to prove it worked

Run the doc's gates with rescaled numbers, as pods through the real device-plugin path:

| Check | Tool | Pass looks like |
|---|---|---|
| Per-rail RDMA | `ib_write_bw --report_gbits -x <gid>` pod↔pod | ~96–97 Gb/s per rail, all 8 rails |
| Lossless verified | `ethtool -S` / `rdma statistic` + `show queuing interface` | ECN marks present, CNPs sent/handled moving, **zero** `out_of_buffer`, no PFC storms |
| QoS agreement (①) | switch per-queue counters during `alltoall_perf` | traffic lands in the no-drop queue, not best-effort |
| Collectives | `all_reduce_perf` / `alltoall_perf`, 2-node, 8 rails | ≥ ~85–90% of 8×100G aggregate; single-node at NVLink reference |
| GDR engaged | `NCCL_DEBUG=INFO` | log shows `via GDRDMA` / DMA-BUF — `lsmod` proves presence, not the path |
| IRQ/NUMA contract | `/proc/interrupts`, `numastat -p` | rail IRQs on local-socket reserved cores; pinned KV tier split across sockets |
| Storage | `fio` 1M seq + `gdsio` | ≈ aggregate NVMe; GDS active, not bounce mode |
| End-to-end | `aiperf` / genai-perf sweep + park/resume test | TTFT/ITL per lane vs *100G-derived* targets; NIXL counters account for transfers |
| Gang semantics | 2-node gang with 1 node free | zero partial binds; whole-gang eviction on preemption |

## Q6 — Reading list

**Fabric:** [Cisco Data Center Networking Blueprint for AI/ML](https://www.cisco.com/c/en/us/td/docs/dcn/whitepapers/cisco-data-center-networking-blueprint-for-ai-ml-applications.html) (the DSCP 24/48, WRED 150K/3000K/7% reference) and its [Validated Design](https://www.cisco.com/c/en/us/td/docs/dcn/whitepapers/cvd-for-data-center-networking-blueprint-for-ai.html); [Nexus 9000 for AI white paper](https://www.cisco.com/c/en/us/products/collateral/networking/cloud-networking-switches/nexus-9000-switches/nexus-9000-ai-networking-wp.html); [NVIDIA DOCA RoCE](https://networking-docs.nvidia.com/doca/archive/3-4-0/rdma-over-converged-ethernet.md) + NVIDIA's DCQCN/ECN community docs; NCCL env-var reference + nccl-tests README.

**Platform:** Red Hat low-latency tuning (PerformanceProfile) docs; SR-IOV Network Operator docs; [DRA GA in OCP 4.21](https://developers.redhat.com/articles/2026/03/25/dynamic-resource-allocation-goes-ga-red-hat-openshift-421-smarter-gpu) + [OCP 4.22 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes); LVMS vs LSO docs; oc-mirror v2.

**Scheduling/serving:** [DRANET](https://github.com/kubernetes-sigs/dranet) + [GKE managed DRANET](https://cloud.google.com/blog/products/networking/introducing-managed-dranet-in-google-kubernetes-engine); NVIDIA Dynamo docs (disagg, KVBM, planner, Grove); KAI Scheduler docs; vLLM distributed/EP + GLM recipes; NVIDIA GPUDirect RDMA (DMA-BUF) and GDS docs; Dell XE9680 AI tuning white paper.

---

## Sources

- [Cisco AI/ML blueprint](https://www.cisco.com/c/en/us/td/docs/dcn/whitepapers/cisco-data-center-networking-blueprint-for-ai-ml-applications.html)
- [OCP 4.22 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes)
- [DRA GA in OpenShift 4.21](https://developers.redhat.com/articles/2026/03/25/dynamic-resource-allocation-goes-ga-red-hat-openshift-421-smarter-gpu)
- [DRANET repo](https://github.com/kubernetes-sigs/dranet)
- [GKE managed DRANET](https://cloud.google.com/blog/products/networking/introducing-managed-dranet-in-google-kubernetes-engine)
- [NVIDIA DOCA RoCE](https://networking-docs.nvidia.com/doca/archive/3-4-0/rdma-over-converged-ethernet.md)
