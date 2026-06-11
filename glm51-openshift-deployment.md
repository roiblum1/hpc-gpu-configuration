# GLM-5.1 Serving Platform on OpenShift 4.20 — Unified Deployment Architecture

**Scope:** Disconnected, bare-metal OpenShift 4.20 (K8s 1.33). Dell XE9680-class HGX nodes (H200 / B200 / B300), 8 GPUs + 8 RoCEv2 rail NICs per node, dual-socket, 2–4 TB DDR5, local NVMe.
**Goal:** GLM-5.1 (754B MoE / 40B active, 256+1 experts, hybrid DSA attention, 1 MTP head, ~202K context) served disaggregated via Dynamo, gang-scheduled by KAI, with KV tiering across HBM → pinned DRAM → LVMS NVMe, consumed by many developers through a Gateway-API front door.

This document is ordered as a build sequence. Each phase ends with a **validation gate** — do not proceed past a failed gate; every later layer silently absorbs the damage of an earlier one (a wrong PCIe ACS setting shows up three layers later as "Dynamo is slow").

---

## 0. Reference architecture

```
                        ┌─────────────────────────────────────────────┐
 Developers ──HTTPS──►  │  Gateway API (Istio-based, OCP 4.20 GA)     │
 (IDE, agents, CI)      │  AuthPolicy + RateLimitPolicy (Kuadrant)    │
                        └──────────────────┬──────────────────────────┘
                                           │ HTTPRoute
                        ┌──────────────────▼──────────────────────────┐
                        │  Dynamo Frontend (CPU pods, infra/reserved) │
                        │  OpenAI-compat · KV-aware router · tokenize │
                        └───────┬──────────────────────────┬──────────┘
                          NATS/etcd control plane     NIXL (RoCE rails)
                        ┌───────▼──────────┐    ┌──────────▼───────────┐
                        │ PREFILL pool      │    │ DECODE pool          │
                        │ H200, TP8, FP8    │───►│ B200/B300, NVFP4     │
                        │ chunked prefill   │ KV │ wide-EP (DP-attn)    │
                        │ KVBM: DRAM+NVMe   │    │ MTP spec-decode      │
                        └───────┬──────────┘    └──────────┬───────────┘
                                │      KAI Scheduler (gangs, queues,
                                │      bin-packing, reclaim)
                        ┌───────▼──────────────────────────▼───────────┐
                        │ Node foundation: PerformanceProfile (CPU/    │
                        │ NUMA/IRQ), SR-IOV rail VFs, GPU Operator     │
                        │ (DMA-BUF GDR, GDS), LVMS NVMe, RoCE QoS      │
                        └──────────────────────────────────────────────┘
```

**Component inventory (what gets installed, in order):**

| # | Component | Delivery | Namespace |
|---|-----------|----------|-----------|
| 1 | Node Feature Discovery | OLM (Red Hat) | `openshift-nfd` |
| 2 | Node Tuning Operator | built-in | `openshift-cluster-node-tuning-operator` |
| 3 | SR-IOV Network Operator | OLM (Red Hat) | `openshift-sriov-network-operator` |
| 4 | NVIDIA GPU Operator | OLM (certified) | `nvidia-gpu-operator` |
| 5 | LVM Storage (LVMS) | OLM (Red Hat) | `openshift-storage` |
| 6 | cert-manager | OLM (Red Hat) | `cert-manager-operator` |
| 7 | KAI Scheduler | Helm (mirrored) | `kai-scheduler` |
| 8 | Grove + LeaderWorkerSet | Helm/manifests (mirrored) | `grove-system` / `lws-system` |
| 9 | Dynamo platform (operator, etcd, NATS) | Helm (mirrored) | `dynamo-system` |
| 10 | Gateway API impl (OSSM3/Istio) + Kuadrant (RH Connectivity Link) | OLM | `openshift-ingress` / `kuadrant-system` |
| 11 | Monitoring add-ons (DCGM SM, SR-IOV metrics exporter, dashboards) | manifests | `openshift-monitoring` (UWM) |

---

## Phase 0 — Disconnected prerequisites

Mirror **everything** before touching the cluster. The painful items are not the operators (oc-mirror handles those) but the Helm-delivered stack and the model itself.

**oc-mirror (operator catalogs):** `nfd`, `sriov-network-operator`, `gpu-operator-certified`, `lvms-operator`, `openshift-cert-manager-operator`, `servicemeshoperator3`, `rhcl-operator` (Kuadrant). Pin exact channels/versions; record them — every YAML below assumes a pinned version.

**Helm charts + images (mirror to your registry, keep digests):**
- `kai-scheduler` (scheduler, pod-grouper, binder, queue-controller images)
- `dynamo-platform` (dynamo-operator, NATS, etcd) and `dynamo` runtime images: frontend, `vllm-runtime`, `trtllm-runtime` — these are large (~20–40 GB each); mirror once, reference by digest
- `grove` and/or `leaderworkerset` controller images
- benchmark/validation images: `nccl-tests`, `perftest` (ib_write_bw), `fio`, `gdsio`, `genai-perf`

**Model weights — do not serve 754 GB through image pulls.** You already know your CRI-O layer-extraction lock serializes large pulls. Stage weights once per node instead:
1. Carve a dedicated `models` LV (Phase 4) on local NVMe, separate from the KV-cache LV.
2. Pre-stage via a DaemonSet job that rsyncs from an in-cluster artifact store (or OCI artifact + `skopeo copy` to a local dir) to `/var/lib/models/glm-5.1-{fp8,nvfp4}`.
3. Workers mount it `hostPath`/local-PV read-only. Pod restarts cost zero pull time.

Mirror **both** quantizations: FP8 (prefill pool, H200) and NVFP4 (decode pool, Blackwell).

**Gate 0:** `oc adm release info` clean; all images resolvable by digest from a GPU node; weights staged and checksummed on every node.

---

## Phase 1 — Node foundation (MCP, PerformanceProfile, RoCE host config)

### 1.1 Dedicated MachineConfigPool

Isolate GPU nodes so kernel/tuning rollouts never touch the rest of the fleet, and so you can stage per-hardware-generation pools later:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: gpu-hpc
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker, gpu-hpc]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/gpu-hpc: ""
  paused: false
```

Label nodes `node-role.kubernetes.io/gpu-hpc=""` plus a hardware-generation label you will use for pool targeting: `gpu.hpc/sku: h200 | b200 | b300`.

### 1.2 PerformanceProfile (generates KubeletConfig + Tuned + MachineConfig coherently)

One profile per CPU SKU (core counts differ between H200/Intel and Blackwell/EPYC chassis — adjust the cpusets). Example for a 2×56-core node:

```yaml
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: gpu-hpc
spec:
  cpu:
    # 8 cores per socket reserved for kubelet/CRI-O/IRQ/housekeeping.
    # Keep BOTH sockets represented in reserved so per-NUMA memory
    # reservation and NIC IRQ steering stay local.
    reserved: "0-7,56-63"
    isolated: "8-55,64-111"
  numa:
    topologyPolicy: "best-effort"      # see decision note below
  memory: {}                            # NTO should set MemoryManager Static — verify generated KubeletConfig at Gate 1
  hugepages:
    defaultHugepagesSize: "1G"
    pages:
      - size: "1G"
        count: 16                       # SMALL on purpose — see refinement note below
  kubeletConfig: {}                     # NTO sets cpuManagerPolicy: static (full-pcpus-only),
                                        # memoryManagerPolicy: Static, topologyManager per .numa
  net:
    userLevelNetworking: false
  additionalKernelArgs:
    - "iommu=pt"                        # passthrough — full IOMMU translation taxes GPUDirect RDMA
    - "intel_iommu=on"                  # amd_iommu=on for EPYC Blackwell chassis
    - "numa_balancing=disable"          # kernel auto-NUMA migration fights static pinning
    - "skew_tick=1"
    - "tsc=reliable"
    - "nowatchdog"
    - "nosoftlockup"
  globallyDisableIrqLoadBalancing: false  # per-pod IRQ exclusion instead — see the runtime-class contract in 3.3
  nodeSelector:
    node-role.kubernetes.io/gpu-hpc: ""
  machineConfigPoolSelector:
    pools.operator.machineconfiguration.openshift.io/gpu-hpc: ""
```

**Two deliberate decisions encoded here — both refine what we discussed earlier:**

1. **`topologyPolicy: best-effort`, not `single-numa-node`.** The pod granularity in this design is **full-node** (one worker pod = 8 GPUs + 8 rail VFs), because TP8/EP workers span both sockets by definition. `single-numa-node` (and `restricted`) would reject these pods at admission. Intra-pod NUMA correctness is delegated downward: the kubelet still gives the pod exclusive full physical cores via static CPU manager, and the serving runtime (vLLM/TRT-LLM) plus UCX/NIXL pin threads and buffers per-GPU/per-NIC NUMA-locally. The SR-IOV pools in Phase 3 remain NUMA-scoped so the runtime *can* pick rail-local devices.
2. **Hugepages: small, not "size of the DRAM KV tier".** Refining my earlier suggestion: KVBM's host tier allocates **CUDA pinned (page-locked) memory**, not hugetlbfs — pre-reserving 1.5 TB of 1G hugepages would *steal* RAM from the very tier you're building. Reserve only what explicit hugetlbfs consumers need (DPDK-style tooling, some UCX configs); 16×1G is a safe starting allowance. Grow only if something measurably consumes them.

### 1.3 Sysctls and RDMA limits the profile does not cover

Child Tuned profile (inherits the NTO-generated one) on the same pool:

```yaml
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: gpu-hpc-extras
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: gpu-hpc-extras
      data: |
        [main]
        include=openshift-node-performance-gpu-hpc
        [sysctl]
        vm.swappiness=0
        vm.zone_reclaim_mode=0
        vm.max_map_count=1048576
        net.core.rmem_max=536870912
        net.core.wmem_max=536870912
        net.ipv4.tcp_rmem=4096 87380 268435456
        net.ipv4.tcp_wmem=4096 65536 268435456
        fs.aio-max-nr=1048576
        vm.min_free_kbytes=4194304
        [vm]
        transparent_hugepages=madvise
  recommend:
    - profile: gpu-hpc-extras
      priority: 19
      match:
        - label: node-role.kubernetes.io/gpu-hpc
```

**`vm.min_free_kbytes=4194304` (4 GiB)** — with ~1 TB of CUDA-pinned memory per prefill node plus 9000-MTU ring buffers, the default free-page reserve is too small: atomic allocations (NIC rings, driver) start failing under reclaim pressure. 2–4 GiB is the standard reserve for RDMA-heavy hosts of this size.

**Memlock for RDMA pods** — CRI-O's default memlock limit breaks ibverbs registration inside containers. Drop a CRI-O config via MachineConfig on the `gpu-hpc` pool:

```ini
# /etc/crio/crio.conf.d/99-rdma-memlock.conf
[crio.runtime]
default_ulimits = [ "memlock=-1:-1" ]
```

(Encode as a standard MachineConfig `storage.files` entry, role `gpu-hpc`.)

### 1.4 RoCE NIC host-side QoS (per boot, via MachineConfig systemd unit)

DCQCN is on by default on ConnectX-7; what you must pin explicitly is **trust mode, lossless priority, and CNP marking**, identically on every rail PF, matching the switch fabric:

```bash
# /usr/local/bin/roce-qos.sh  (systemd oneshot after network-online, role gpu-hpc)
for dev in $(ls /sys/class/infiniband/ | grep mlx5); do
  port=$(ls /sys/class/infiniband/$dev/device/net/ | head -1)
  mlnx_qos -i $port --trust dscp
  mlnx_qos -i $port --pfc 0,0,0,1,0,0,0,0          # lossless on priority 3
  echo 106 > /sys/class/infiniband/$dev/tc/1/traffic_class   # DSCP 26 + ECN
  cma_roce_tos -d $dev -t 106
  echo 48 > /sys/class/net/$port/ecn/roce_np/cnp_dscp        # CNP marking — DSCP 48
  echo 6  > /sys/class/net/$port/ecn/roce_np/cnp_802p_prio   # CNP egress priority 6
  echo 1  > /sys/class/net/$port/ecn/roce_np/enable/3        # DCQCN NP/RP enabled on the lossless prio
  echo 1  > /sys/class/net/$port/ecn/roce_rp/enable/3
  ethtool -A $port rx off tx off || true   # global pause off — PFC only ("not modified" exits nonzero)
  ip link set $port mtu 9000
done
```

Conventions used everywhere below (change once, change everywhere — see §10): **RoCE traffic DSCP 26 / priority 3 lossless; CNP DSCP 48 / priority 6; MTU 9000 end-to-end.** Switch side (PFC on prio 3, ECN/WRED thresholds, CNP queue strict-priority) must mirror this — it is the other half of the same configuration, not a separate concern.

### 1.5 BIOS checklist (per chassis SKU, verify with evidence, not assumption)

- **ACS disabled** on PCIe switches between GPU↔NIC pairs — otherwise P2P bounces through the root complex and GPUDirect RDMA bandwidth halves. Evidence: `nvidia-smi topo -m` must show **PIX/PXB** (not NODE/SYS) between each GPU and its rail NIC.
- PCIe **Max Read Request Size 4096**, relaxed ordering enabled on NICs (`mlxconfig` / BIOS).
- NPS=1 (EPYC chassis) unless you have a measured reason otherwise; Sub-NUMA Clustering **off** (Intel) — SNC multiplies NUMA nodes and breaks the "one socket = one NUMA = 4 GPUs + 4 rails" model the rest of this design assumes.
- Performance power profile, C-states limited per latency policy.
- **SMT: decide per chassis SKU and record it.** The 1.2 cpusets assume 112 logical CPUs (SMT off). If SMT stays on, `reserved`/`isolated` must contain complete sibling pairs — `full-pcpus-only` rejects GPU pods whose cpuset would split a physical core.

**Gate 1:** on a rebooted node: `cat /proc/cmdline` shows all args; `oc describe node` shows hugepages and correct allocatable CPU; `tuned-adm active` shows the child profile; `mlnx_qos -i <port>` shows trust=dscp + PFC prio3; `cat /sys/class/net/<pf>/ecn/roce_np/cnp_dscp` → 48 on every rail; the NTO-generated KubeletConfig shows `memoryManagerPolicy: Static` (verify the inference, don't assume it); `/proc/interrupts` shows each rail NIC's mlx5 completion-queue IRQs on its local-socket reserved cores (the measurable reason both sockets sit in `reserved`); `nvidia-smi topo -m` (after Phase 2) shows PIX per GPU/NIC pair; container can `ulimit -l` → unlimited.

---

## Phase 2 — NVIDIA GPU Operator

NFD first (default instance is fine), then GPU Operator with a ClusterPolicy tuned for this design. The non-default choices, and why:

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  driver:
    enabled: true
    useOpenKernelModules: true        # REQUIRED for DMA-BUF GPUDirect RDMA path
    usePrecompiled: true              # disconnected: precompiled/signed driver images
    repository: <your-registry>/nvidia
  gds:
    enabled: true                     # nvidia-fs module → GPUDirect Storage (NVMe→HBM, Phase 4/6)
  gdrcopy:
    enabled: true                     # low-latency small-message D2H/H2D — helps NIXL/KVBM
  toolkit: {enabled: true}
  devicePlugin:
    enabled: true
    config: {}                        # no time-slicing, no MIG — whole physical GPUs only
  mig:
    strategy: none
  dcgmExporter:
    enabled: true
    serviceMonitor: {enabled: true}
  daemonsets:
    tolerations:
      - {key: node-role.kubernetes.io/gpu-hpc, operator: Exists}
  nodeSelector:
    node-role.kubernetes.io/gpu-hpc: ""
```

- **`useOpenKernelModules: true`** is the load-bearing line: the open driver + DMA-BUF is the supported GPUDirect RDMA path on RHCOS 9 kernels and is what NIXL/NCCL will use for GPU↔NIC zero-copy. The legacy `nvidia-peermem` path is the fallback, not the target.
- **In-box `mlx5` driver vs DOCA-OFED:** start with the RHCOS in-box driver — it supports RoCEv2, SR-IOV and DMA-BUF GDR on current kernels, and is one less out-of-tree module in an air-gapped cluster. Bring in the NVIDIA Network Operator (DOCA driver container) only if you hit a feature gap (e.g., specific congestion-control telemetry or firmware tooling); if you do, it must roll out *before* the GPU driver DaemonSet on each node — order matters for the GDR symbol resolution.
- Persistence mode is handled by the operator; verify `nvidia-smi -q | grep Persistence` → Enabled.

**Gate 2:** `nvidia-smi topo -m` → NV18/NVLink mesh between GPUs, **PIX** between each GPU and its rail NIC; `lsmod` shows `nvidia` (open), `nvidia_fs`, `gdrdrv`; DCGM metrics visible in UWM Prometheus.

---

## Phase 3 — RoCE rail exposure: SR-IOV pools (the DRA stand-in)

As agreed: structured DRA waits for OCP 4.21+ (beta gates = `TechPreviewNoUpgrade` = no upgrades on 4.20). The supported equivalent today is **one NUMA-scoped SR-IOV pool per rail**, with Topology Manager providing count-level alignment and the runtime providing fine alignment. Design the pool naming now so each pool maps 1:1 onto a future DRA ResourceClaim.

### 3.1 One SriovNetworkNodePolicy per rail (×8)

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rail0
  namespace: openshift-sriov-network-operator
spec:
  resourceName: rail0                  # → openshift.io/rail0
  nodeSelector:
    node-role.kubernetes.io/gpu-hpc: ""
  priority: 90
  numVfs: 2                            # serving needs 1 VF/rail/pod; 2nd VF = headroom for debug/validation pods
  nicSelector:
    pfNames: ["ens1f0np0"]             # the physical PF cabled as rail 0 — per-SKU naming, keep a rail map doc
  deviceType: netdevice                # NOT vfio — kernel netdev + RDMA
  isRdma: true
  linkType: eth
  mtu: 9000
```

Repeat for `rail1..rail7`. Rails 0–3 live on socket 0, 4–7 on socket 1 (verify per chassis: `cat /sys/class/net/<pf>/device/numa_node`). The device plugin reports each pool's NUMA affinity to the kubelet automatically — that is what keeps Topology Manager (even `best-effort`) honest and what a future DRA migration will read as device attributes.

### 3.2 One SriovNetwork (NAD) per rail

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rail0
  namespace: openshift-sriov-network-operator
spec:
  resourceName: rail0
  networkNamespace: glm-serving
  trust: "on"                  # several RoCE-on-VF recipes need VF trust for DSCP/QoS egress — verify at Gate 3
  spoofChk: "off"
  ipam: |
    {"type": "whereabouts", "range": "172.16.0.0/24"}   # one /24 per rail, mirrors the fabric's per-rail subnets
  metaPlugins: ""
```

Whereabouts allocations leak when nodes die ungracefully (gang evictions, drains): verify your CNI version runs the whereabouts ip-reconciler cron, or stale IPs in a rail /24 will eventually block reschedules.

### 3.3 How worker pods consume the rails (full-node pod pattern)

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: rail0,rail1,rail2,rail3,rail4,rail5,rail6,rail7
    irq-load-balancing.crio.io: "disable"   # keep device IRQs off this pod's exclusive cores
    cpu-quota.crio.io: "disable"            # no CFS throttling artifacts on the hot loop
spec:
  runtimeClassName: performance-gpu-hpc     # NTO generates performance-<profile name> from Phase 1.2
  containers:
    - resources:
        limits:
          nvidia.com/gpu: 8
          openshift.io/rail0: "1"
          openshift.io/rail1: "1"
          # ... rail2..rail7 ...
          cpu: "96"                    # integer → Guaranteed QoS → exclusive pcpus from static CPU manager
          memory: 1600Gi               # sized to leave room for KVBM pinned tier + OS, see §6.4
          hugepages-1Gi: 0Gi
```

**The runtime-class lines are the second half of `globallyDisableIrqLoadBalancing: false` (1.2).** With `false`, managed (MSI-X) IRQs already avoid isolated cores, but other device IRQs can still land on the pod's pinned CPUs; the NTO-generated `performance-<profile>` RuntimeClass plus `irq-load-balancing.crio.io: "disable"` is the supported per-pod opt-out that actually delivers "device IRQs on reserved CPUs", and `cpu-quota.crio.io: "disable"` removes CFS throttling artifacts from the decode hot loop. The same runtime class also honors `cpu-c-states.crio.io: "disable"` and `cpu-freq-governor.crio.io: "performance"` — leave those off initially (disabling deep C-states across 96 isolated cores costs power and thermal headroom) and decide on Gate-6 ITL-jitter numbers, not principle.

### 3.4 Collective/transfer library environment (baked into worker pod env)

```bash
NCCL_SOCKET_IFNAME=eth0                 # control path on pod net, never on rails
NCCL_IB_HCA=mlx5                        # all rail RDMA devices
NCCL_IB_GID_INDEX=3                     # RoCEv2 (IPv4-mapped)
NCCL_IB_TC=106                          # DSCP 26 → matches Phase 1.4 / switch QoS
NCCL_IB_QPS_PER_CONNECTION=4
NCCL_IB_PCI_RELAXED_ORDERING=1          # 1.5 enables RO on the NICs; this asks NCCL to use it (flag per pinned version)
NCCL_CROSS_NIC=0                        # rail-aligned: GPU n talks via NIC n
UCX_TLS=rc,cuda_copy,cuda_ipc           # NIXL uses UCX — this governs KV transfers
UCX_NET_DEVICES=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1
UCX_IB_GID_INDEX=3
UCX_IB_TRAFFIC_CLASS=106
```

NCCL carries EP all-to-all and TP collectives; **UCX carries NIXL KV transfers (prefill→decode and KVBM tier moves)** — both must agree on GID index and traffic class or one of them silently rides the lossy queue.

**Gate 3 (run as pods, through the real device plugin path — not from the host):**
- `ib_write_bw` pod↔pod per rail: ≥ ~370 Gb/s per 400G rail.
- `nccl-tests all_reduce_perf` single node (NVLink): bus BW at vendor reference for the SKU.
- 2-node `all_reduce` and **`alltoall_perf`** (the EP-shaped collective) over 8 rails: near line-rate aggregate, **zero** PFC pause storms / `out_of_buffer` increments on switch and NIC counters during the run.
- one nccl-tests pass with `NCCL_DEBUG=INFO`: the log must show GPUDirect RDMA actually engaged (`via GDRDMA`, DMA-BUF path) — Gate 2's `lsmod` proves module presence, not the data path.

---

## Phase 4 — Storage: LVMS for the NVMe tiers

Two LVs per node, different jobs:

| LV | Purpose | Consumer |
|----|---------|----------|
| `vg-nvme/kv` | KVBM G3 (cold KV / parked sessions) | decode+prefill workers via local PVC |
| `vg-nvme/models` | staged model weights (Phase 0) | read-only hostPath/local PV |

```yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: gpu-nvme
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: kvcache
        default: true
        fstype: xfs                    # REQUIRED: KVBM disk tier uses fallocate(); xfs supports it
        deviceSelector:
          paths:
            - /dev/disk/by-path/pci-0000:.._nvme-1   # pin by-path, per socket — see NUMA note
            - /dev/disk/by-path/pci-0000:.._nvme-2
        thinPoolConfig:
          name: kv-thin
          sizePercent: 90
          overprovisionRatio: 1        # honest reality: LVMS provisions thin pools;
                                       # ratio=1 removes overcommit risk but not thin metadata cost
        nodeSelector:
          nodeSelectorTerms:
            - matchExpressions:
                - {key: node-role.kubernetes.io/gpu-hpc, operator: Exists}
```

**Honest constraint + escape hatch:** LVMS manages thin pools — the "thick, striped" ideal from our earlier discussion is not what it produces. Options, in order of effort: (a) accept thin with `overprovisionRatio: 1` and benchmark — for KVBM's large sequential block I/O the thin metadata overhead is often acceptable; (b) if fio/gdsio shows it isn't, create striped thick LVs out-of-band via a MachineConfig-managed script and expose them with the Local Storage Operator instead. Decide on Gate-4 numbers, not on principle.

**NUMA note:** NVMe drives have PCIe sockets too. If a node's drives are all on socket 0, decode workers' G3 writes from socket-1 GPUs cross UPI. Where the chassis allows, build the KV LV from drives on both sockets; otherwise accept it and let DRAM (G2) absorb the hot path — NVMe is the *cold* tier by design.

**GDS:** with `nvidia-fs` loaded (Phase 2) and xfs + O_DIRECT, NIXL/KVBM can move NVMe→HBM without bouncing through the CPU. Validate with `gdsio`; enable in the runtime container (`--use-nixl-gds` style flag in the Dynamo runtime images).

**Gate 4:** `fio` 1M sequential read on a test PVC ≈ aggregate of member NVMe; `gdsio` shows GDS path active (not compat/bounce mode); `fallocate -l 1G` succeeds on the mounted fs.

---

## Phase 5 — KAI Scheduler: gangs, queues, one quota brain

Install via mirrored Helm chart. Three things must be true: (1) every GPU pod names `kai-scheduler`, (2) every GPU pod carries a queue label, (3) **nothing else** manages GPU quota on this cluster — no Kueue, no ClusterQueue, no Run:ai quota project pointed at these nodes. One brain.

### 5.1 Queue hierarchy

```yaml
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: org}
spec:
  resources:
    gpu: {quota: -1, limit: -1, overQuotaWeight: 1}
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: serving-interactive}
spec:
  parentQueue: org
  priority: 100
  resources:
    gpu: {quota: 64, limit: 96, overQuotaWeight: 3}   # guaranteed floor = your SLO capacity
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: serving-batch}
spec:
  parentQueue: org
  priority: 50
  resources:
    gpu: {quota: 0, limit: -1, overQuotaWeight: 1}    # pure scavenger: soaks idle GPUs, fully reclaimable
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: aux-cpu}
spec:
  parentQueue: org
  priority: 10
  resources:
    gpu: {quota: 0, limit: 0}                          # CPU/RAM-only: embedders, rerankers, eval harnesses
```

The semantics that make "more developers + full utilization" real: `serving-batch` runs **over-quota** on whatever the interactive pool isn't using (nights, troughs); when interactive scales up, KAI **reclaims** batch gangs *atomically* (whole EP groups, never partial — a half-evicted EP16 group is 16 wedged GPUs). `aux-cpu` soaks leftover cores on GPU nodes without ever touching GPU quota.

### 5.2 Pod wiring (applied via Dynamo's pod template overrides in Phase 6)

```yaml
metadata:
  labels:
    kai.scheduler/queue: serving-interactive
spec:
  schedulerName: kai-scheduler
  priorityClassName: serving-critical      # PriorityClass; batch lane gets a preemptible class
```

KAI's pod-grouper auto-detects Grove/LWS replicas and forms the PodGroup — the gang is the **whole multi-node EP group** (leader + workers), scheduled all-or-nothing with bin-packing, which is exactly the deadlock-avoidance discussed earlier. Enable the network-topology/bin-packing placement options in the chart values so EP groups land on fabric-adjacent nodes (same leaf/rail group) rather than scattering.

**Gate 5:** create a 2-node dummy LWS when only 1 node is free → both pods stay `Pending` with a gang message, **zero** pods bound (no partial placement); free a node → both bind in one cycle. Then verify reclaim: fill with batch, submit interactive → batch gang evicted whole.

---

## Phase 6 — Dynamo platform + GLM-5.1 deployment

### 6.1 Platform install

Mirrored `dynamo-platform` Helm chart → dynamo-operator + **etcd + NATS**. Pin these two to **infra/control nodes, never GPU nodes** (nodeSelector/tolerations in chart values): they are the discovery and event plane for routing and KVBM — colocating them with workers means a node drain takes the control plane down with the capacity. Give etcd an SSD-backed PVC and NATS JetStream persistence.

cert-manager must exist first (operator webhooks).

### 6.2 Fleet mapping (heterogeneity as a feature)

| Pool | Hardware | Precision | Parallelism | Why |
|------|----------|-----------|-------------|-----|
| **Prefill** | H200 (`gpu.hpc/sku: h200`) | FP8 | TP8 intra-node, chunked prefill | prefill is compute-bound; H200 FP8 FLOPs are well-matched; NVLink keeps TP off the fabric |
| **Decode** | B200/B300 (`gpu.hpc/sku: b200\|b300`) | **NVFP4** | TP1 × DP-attention × **wide-EP 16–32** across 2–4 nodes | decode is memory-bandwidth-bound; Blackwell HBM + NVFP4 maximizes KV residency and tokens/s; 256 experts shard cleanly (EP16→16 experts/GPU, EP32→8) |

Don't mix B200 and B300 **inside one EP group** — the group runs at the slowest member's step time. Pool them separately (two decode DGD components) and let the router weight them.

### 6.3 Backend strategy — and the KVBM/CUDA-graph collision

A real constraint that shapes the design: **KVBM with the TRT-LLM backend currently disables CUDA graphs** (and TRT-LLM needs `enable_partial_reuse: false` in `kv_connector_config` for good offload hit rates). CUDA graphs matter most on the **decode** hot loop. The clean resolution, which also matches how Dynamo structures disaggregated offload:

- **KVBM lives on the prefill workers** (that's where disagg offload is anchored anyway): prefill computes KV → serves decode via NIXL → write-through to DRAM/NVMe tiers for reuse and session parking.
- **Decode workers keep CUDA graphs on** and hold only their active-session KV in HBM. Parked-session restore re-enters through prefill's tiers (a fast onboard, not a recompute).

Rollout: **Stage A** — vLLM backend on both pools (one runtime to debug, full KVBM + MTP support). **Stage B** — move decode to TRT-LLM + NVFP4 once Stage A SLOs are baselined, and benchmark the delta.

### 6.4 DynamoGraphDeployment (shape; flag names per your pinned version's recipe)

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: glm51
  namespace: glm-serving
spec:
  services:
    Frontend:
      replicas: 4                          # CPU pods; OpenAI-compatible API + tokenizer + router
      extraPodSpec:
        nodeSelector: {node-role.kubernetes.io/infra: ""}
      mainContainer:
        args: ["--router-mode", "kv"]      # KV/prefix-aware routing — THE routing brain (see Phase 7)
        resources: {requests: {cpu: "16", memory: 64Gi}}

    GLM51Prefill:
      replicas: 4                          # 4 × (1 node TP8) to start; planner adjusts
      multinode: {nodeCount: 1}
      extraPodSpec:
        schedulerName: kai-scheduler
        runtimeClassName: performance-gpu-hpc   # low-latency pod contract — see 3.3
        nodeSelector: {gpu.hpc/sku: h200}
      labels: {kai.scheduler/queue: serving-interactive}
      annotations:
        k8s.v1.cni.cncf.io/networks: rail0,rail1,rail2,rail3,rail4,rail5,rail6,rail7
        irq-load-balancing.crio.io: "disable"
        cpu-quota.crio.io: "disable"
      envs:
        - {name: DYN_KVBM_CPU_CACHE_GB,  value: "1024"}   # pinned DRAM tier — see sizing below
        - {name: DYN_KVBM_DISK_CACHE_GB, value: "2048"}   # on the LVMS kvcache PVC
        - {name: DYN_KVBM_LEADER_WORKER_INIT_TIMEOUT_SECS, value: "1200"}  # pinning 1TB takes minutes
      mainContainer:
        args: ["--model", "/models/glm-5.1-fp8",
               "--tensor-parallel-size", "8",
               "--enable-expert-parallel",
               "--kv-cache-dtype", "fp8",
               "--max-model-len", "202752",
               "--enable-chunked-prefill",
               "--connector", "kvbm",
               "--is-prefill-worker"]
        resources:
          limits: {nvidia.com/gpu: 8, openshift.io/rail0: "1", ... , cpu: "96", memory: 1800Gi}
        volumeMounts:
          - {name: models, mountPath: /models, readOnly: true}
          - {name: kvdisk, mountPath: /kvbm-disk}

    GLM51Decode:
      replicas: 2                          # 2 EP16 groups = 4 Blackwell nodes
      multinode: {nodeCount: 2}            # Grove gang: 2 nodes/replica — KAI schedules atomically
      extraPodSpec:
        schedulerName: kai-scheduler
        runtimeClassName: performance-gpu-hpc   # low-latency pod contract — see 3.3
        nodeSelector: {gpu.hpc/sku: b200}
      labels: {kai.scheduler/queue: serving-interactive}
      annotations:
        k8s.v1.cni.cncf.io/networks: rail0,...,rail7
        irq-load-balancing.crio.io: "disable"
        cpu-quota.crio.io: "disable"
      mainContainer:
        args: ["--model", "/models/glm-5.1-nvfp4",
               "--tensor-parallel-size", "1",
               "--data-parallel-size", "16",          # DP attention; EP = DP×TP = 16
               "--enable-expert-parallel",
               "--kv-cache-dtype", "fp8",
               "--max-model-len", "202752",
               "--speculative-config", "<MTP per recipe: 1 speculative token>"]
        resources: {limits: {nvidia.com/gpu: 8, openshift.io/rail0..7: "1", cpu: "96", memory: 1200Gi}}
```

**Configuration notes that make this actually work:**

- **KVBM sizing is a write-through invariant:** GPU-KV ≤ `CPU_CACHE_GB` ≤ `DISK_CACHE_GB`, per worker. Violating the ordering misconfigures the cache. Sizing chain: pod `memory` limit ≥ CPU_CACHE + runtime + tokenizer headroom; node RAM ≥ pod memory + reserved-CPU housekeeping; LVMS PVC ≥ DISK_CACHE. Start CPU tier at ~50% of node DRAM and grow with measured hit rates — pinned memory is invisible to OOM heuristics until it isn't.
- **MTP:** one MTP head in the checkpoint → `num_speculative_tokens: 1`. Enable on the **interactive decode pool only**; leave it off the batch lane (verification overhead beats batching gains at high batch). Export and alert on acceptance rate.
- **Chunked prefill chunk size** is your TTFT-fairness knob on 200K contexts: smaller chunks = better interleaving for short requests sharing the prefill pool, at some throughput cost. Tune at Gate 6 with mixed-length traffic, not synthetics of one shape.
- **Hybrid-attention dividend:** measure actual KV bytes/token on your build (linear-attention layers hold constant state, not per-token KV) and re-derive max concurrent sessions + all tier sizes from the measured number. Every sizing default in vendor docs assumes dense attention and will be pessimistic here.
- **Planner:** start with static 4P:2×EP16D, run the SLA profiling job against real traffic mixes, then enable the SLA planner with your TTFT/ITL targets so P:D ratio follows the prefill-heavy-morning / decode-heavy-afternoon cycle. Planner scaling events create/destroy gangs — which is exactly why KAI's atomic gang semantics (Phase 5) are load-bearing.
- **Batch lane = second, smaller DGD** (or scaled-down clone): queue `serving-batch`, preemptible PriorityClass, MTP off, aggressive max batch. Same model, same weights LV — only scheduling identity and engine tuning differ.

**Gate 6:** `genai-perf` concurrency sweep meets TTFT/ITL targets per lane; disagg verified (NIXL transfer counters move, decode never prefilling long prompts); **session-park test**: 100K-token session → idle 10 min → resume; resume TTFT must be a small fraction of initial prefill and KVBM onboard counters must account for it; **NUMA evidence**: on a loaded prefill worker, `numastat -p <engine pid>` shows the pinned CPU tier split across both sockets — if it piles onto socket 0, runtime thread pinning is wrong and socket-1 GPUs pay UPI latency on every tier access.

---

## Phase 7 — Front door: Gateway API, tenancy, fairness

**One routing brain rule:** Dynamo's KV-aware router *is* the inference router. The Gateway layer above it does identity, budgets, and lane selection — it must **not** do endpoint picking. (Adopt GIE `InferencePool` + EPP later if/when multiple heterogeneous model pools sit behind one endpoint; running EPP and Dynamo's router simultaneously gives you two brains disagreeing about placement.)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: llm-gw, namespace: openshift-ingress}
spec:
  gatewayClassName: openshift-default          # OCP 4.20 GA Gateway API (Istio-based)
  listeners:
    - {name: https, port: 443, protocol: HTTPS, hostname: "llm.apps.<cluster>",
       tls: {mode: Terminate, certificateRefs: [{name: llm-tls}]}}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: glm51-interactive, namespace: glm-serving}
spec:
  parentRefs: [{name: llm-gw, namespace: openshift-ingress}]
  hostnames: ["llm.apps.<cluster>"]
  rules:
    - matches: [{path: {type: PathPrefix, value: /v1}}]
      backendRefs: [{name: glm51-frontend, port: 8000}]
```

Batch lane: second hostname (`llm-batch.apps.<cluster>`) → batch frontend. Lane selection by hostname keeps policy attachment trivial.

**Tenancy via Kuadrant (RH Connectivity Link):** `AuthPolicy` on the Gateway (API key per team/service, key → tenant identity), `RateLimitPolicy` per route keyed on tenant. Critical detail for LLM traffic: limit **tokens, not requests** — agentic requests are wildly asymmetric. Use the token-aware rate limit policy if your mirrored RHCL version ships it (it landed in recent releases — verify); otherwise enforce request-rate + a hard `max_tokens` cap per lane at the frontend and reconcile budgets from usage logs.

**Per-lane request policy (enforced at frontend defaults, not left to clients):** interactive — thinking-mode off by default, `max_tokens` capped (a single 131K-output generation is a decode-pool DoS); batch/agent lane — thinking allowed, large output budgets, preemptible.

**Gate 7:** no key → 401; tenant over budget → 429 with rate-limit headers; interactive request attempting 131K output → clamped; both lanes reachable and hitting their respective DGDs.

---

## Phase 8 — Observability: close the loop

Extend the RDMA dashboard into a single goodput view — these are also the planner's inputs:

| Signal | Source | Why it matters |
|--------|--------|----------------|
| TTFT / ITL / throughput per lane & tenant | Dynamo frontend metrics | the SLO; planner input |
| Prefix/KV hit rate; KVBM offload/onboard rates per tier | Dynamo router + KVBM metrics | every hit = GPU time returned; tier sizing feedback |
| MTP acceptance rate | engine metrics | below ~threshold it's pure overhead — alert |
| Expert load skew across EP ranks | engine/EP metrics | hot experts = hot GPUs + hot rails |
| Per-rail RoCE: throughput, `out_of_buffer`, CNPs sent/handled, PFC pause duration | NIC counters (ethtool/rdma stats → your exporter) + sriov-network-metrics-exporter | pause storms during all-to-all = fabric QoS drift |
| GPU: SM occupancy, HBM used, NVLink BW | DCGM | per-pool saturation |
| Thin-pool data% on `kvcache` | LVMS/topolvm metrics | thin pool exhaustion is a node-level incident |
| Gang pending time, reclaim events | KAI metrics | queue starvation / capacity planning |

Alert minimums: PFC pause storm, MTP acceptance collapse, prefix-hit-rate drop (cache thrash), thin pool >80%, gang Pending >N min in `serving-interactive`, etcd/NATS health.

**Gate 8 (soak):** 72h mixed-traffic soak with the batch lane saturating troughs; SLOs hold during planner rescale and during one deliberate node drain (gang rescheduled whole, sessions resume via KVBM, no fabric pause storms).

---

## 10. Cross-layer integration matrix — the contracts that keep it coherent

Each row is one value that multiple layers must agree on. When something is "mysteriously slow," audit this table first.

| Invariant | Must match in |
|-----------|---------------|
| **MTU 9000** | NIC PF (Phase 1.4) · `SriovNetworkNodePolicy.mtu` · switch fabric · pod NADs |
| **DSCP 26 / TC 106 / GID index 3 (RoCEv2)** | `mlnx_qos`/tc files (1.4) · switch PFC/ECN config · `NCCL_IB_TC`+`NCCL_IB_GID_INDEX` · `UCX_IB_TRAFFIC_CLASS`+`UCX_IB_GID_INDEX` · CNP DSCP 48/prio 6 (`roce_np` ↔ switch CNP queue) |
| **Rail map (GPU n ↔ NIC n ↔ socket)** | physical cabling doc · `pfNames` per rail policy · `NCCL_CROSS_NIC=0` assumption · `nvidia-smi topo -m` evidence |
| **Full-node pod granularity** | `topologyPolicy: best-effort` · pod requests = 8 GPU + 8 VFs + integer CPUs · runtime-internal NUMA pinning |
| **Low-latency pod contract** | NTO-generated `runtimeClassName: performance-gpu-hpc` · `irq-load-balancing.crio.io`/`cpu-quota.crio.io` disable annotations (3.3/6.4) · `globallyDisableIrqLoadBalancing: false` relies on this per-pod opt-out |
| **Reserved CPUs (0-7,56-63)** | PerformanceProfile · IRQ affinity (managed_irq) · *nothing else* scheduled there — frontends live on infra nodes, aux pods float on the isolated shared pool |
| **Hugepages stay small** | PerformanceProfile count · KVBM uses CUDA-pinned regular pages — DRAM must remain free for it |
| **memlock unlimited** | CRI-O drop-in (1.3) · RDMA registration in every worker · KVBM pinned tier |
| **KVBM ordering: GPU-KV ≤ CPU_CACHE_GB ≤ DISK_CACHE_GB** | engine `free_gpu_memory_fraction` · `DYN_KVBM_*` envs · pod memory limit · node RAM · LVMS PVC size |
| **xfs + fallocate on KV disk tier** | LVMCluster `fstype` · KVBM disk tier requirement |
| **Gang size = EP group = `multinode.nodeCount`** | DGD spec · Grove/LWS replica shape · KAI queue quotas in multiples of group size · planner scale step |
| **One GPU quota brain (KAI), one inference router (Dynamo KV router)** | no Kueue/Run:ai quota on these nodes · no GIE EPP endpoint-picking in front of the frontend |
| **Per-SKU pools** | node labels `gpu.hpc/sku` · DGD nodeSelectors · FP8↔H200, NVFP4↔Blackwell · no mixed-SKU EP groups |
| **KVBM ↔ CUDA graphs (TRT-LLM)** | KVBM on prefill workers · decode keeps graphs · revisit when the limitation lifts |
| **DRA migration path** | rail pool names ↔ future ResourceClaim names · adopt at OCP 4.21+ (DRA GA in K8s 1.34), never via TechPreviewNoUpgrade on 4.20 |
| **etcd/NATS placement** | infra nodes only · Dynamo discovery + KVBM depend on them |

---

## Deployment order recap

`0` mirror + stage weights → `1` MCP/PerformanceProfile/RoCE host QoS/BIOS (**gate: cmdline, PIX topology, lossless counters**) → `2` GPU Operator (**gate: DMA-BUF GDR, GDS modules**) → `3` SR-IOV rails (**gate: ib_write_bw + alltoall clean**) → `4` LVMS (**gate: fio/gdsio**) → `5` KAI (**gate: atomic gang + reclaim**) → `6` Dynamo + GLM-5.1 (**gate: SLO sweep + park/resume**) → `7` Gateway + tenancy (**gate: auth/limits**) → `8` 72h soak.
