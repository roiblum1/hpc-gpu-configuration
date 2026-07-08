# CLAUDE.md — `node-foundation` chart (Phase 1)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and
[glm51-openshift-deployment.md](../../glm51-openshift-deployment.md) §1 / §10 stay authoritative.
**BIOS + NIC firmware (out-of-band half of this layer) live in [BIOS.md](BIOS.md).**
**Running on HyperShift/HCP instead of standalone? Delivery mapping in [HYPERSHIFT.md](HYPERSHIFT.md).**
**Per-parameter deep dive (what/default/why/failure mode for every knob): [PARAMETERS.md](PARAMETERS.md).**

## Scope — what this chart owns (and does not)

**Owns:** the host layer — `MachineConfigPool` (gpu-hpc), `PerformanceProfile`, child `Tuned`
profile, CRI-O memlock MachineConfig, RoCE QoS systemd MachineConfig (`roce-qos.sh`).

**Does NOT own:** BIOS/`mlxconfig` (→ [BIOS.md](BIOS.md), applied out of band) · VF creation and
NADs (→ `sriov-rails`) · pod-side NCCL/UCX env and the RuntimeClass *consumption*
(→ `glm51-dynamo`; this chart *causes* the `performance-gpu-hpc` RuntimeClass to exist).

Rollout reality: every MachineConfig change here **reboots the pool node by node**. Batch changes;
don't iterate one sysctl at a time on a live fleet.

## Why each configuration is what it is

### MachineConfigPool `gpu-hpc`
Isolates kernel/tuning rollouts from the rest of the fleet and enables per-hardware-generation
pools later. The role label `node-role.kubernetes.io/gpu-hpc` is the §10 node-selection invariant
every other chart keys on.

### PerformanceProfile
- **`reserved: 0-7,56-63` — 8 cores per socket, on BOTH sockets deliberately.** Housekeeping
  (kubelet, CRI-O, IRQs) needs a NUMA-local home on each socket so rail-NIC IRQ steering and
  per-NUMA memory reservation stay local. Reserving one socket's worth would force socket-1 NIC
  IRQs to cross the UPI. Cpusets assume SMT off (112 logical); with SMT on they must be
  sibling-pair-complete or `full-pcpus-only` rejects the GPU pods.
- **`topologyPolicy: best-effort`, NOT `single-numa-node`.** Worker pods are full-node
  (8 GPU + 8 VF + integer CPUs) and span both sockets *by definition* — `single-numa-node` and
  `restricted` would reject them at admission. Intra-pod NUMA correctness is delegated to the
  runtime (NCCL/UCX pin per-GPU/per-NIC locally). Do not "fix" this to a stricter policy.
- **Hugepages 16×1G — small on purpose.** KVBM's host tier is CUDA *pinned* memory, not
  hugetlbfs. Reserving "the size of the DRAM tier" in hugepages steals the RAM the tier needs.
  Grow only if something measurably consumes hugetlbfs.
- **Kernel args** (each enforces one latency/DMA property): `iommu=pt` (full IOMMU translation
  taxes GDR) · `intel_iommu=on` (SR-IOV needs the IOMMU; use `amd_iommu=on` on EPYC) ·
  `numa_balancing=disable` (auto-NUMA migration fights static pinning) · `skew_tick=1`
  (de-synchronize per-CPU ticks) · `tsc=reliable` (skip clocksource watchdog) ·
  `nowatchdog`+`nosoftlockup` (no watchdog IPIs on isolated cores) · `pcie_aspm=off` (ASPM exit
  latency spikes GDR/NVMe) · `rcu_nocb_poll` (poll offloaded RCU instead of IPI-ing isolated
  cores) · `intel_idle.max_cstate=1`+`processor.max_cstate=1` (kernel-side enforcement of the
  BIOS C-state policy — drop if idle power outweighs ITL jitter).
  **Never add** `isolcpus`/`nohz_full`/`rcu_nocbs`/hugepages args by hand — NTO generates them
  from the cpusets; duplicates drift silently.
- **`globallyDisableIrqLoadBalancing: false`.** The per-pod half lives in `glm51-dynamo`:
  `runtimeClassName: performance-gpu-hpc` + `irq-load-balancing.crio.io`/`cpu-quota.crio.io`
  disable annotations (§3.3 low-latency contract). `true` would pin *all* IRQs to reserved cores
  globally; `false` + per-pod opt-out keeps non-GPU pods schedulable normally. Remove one side of
  the contract and IRQ isolation silently degrades — §10 row.

### Tuned child profile (`gpu-hpc-extras`)
Inherits the NTO-generated profile (`include=openshift-node-performance-gpu-hpc` — the name is
derived from the PerformanceProfile name; rename one, rename both). Adds what the profile can't:
`vm.swappiness=0` (never swap under pinned-memory pressure) · `vm.zone_reclaim_mode=0` (no
NUMA-local reclaim stalls) · `vm.max_map_count` (large model mmaps) · net.core/tcp buffers
(control-plane + staging paths only — RDMA bypasses TCP) · `fs.aio-max-nr` (NVMe async I/O) ·
`vm.min_free_kbytes=4194304` (with ~1 TB pinned + 9000-MTU rings, atomic allocations fail under
reclaim pressure without a big free-page reserve) · ARP-flux trio `arp_ignore=1` /
`arp_announce=2` / `arp_filter=1` (multi-homed hardening: each NIC answers/sources ARP only
for its own address — host netns only; if user-provided rail NADs share a subnet, set the same
trio pod-side via the `tuning` CNI meta-plugin) · THP `madvise` (opt-in only).

### CRI-O memlock MachineConfig
`default_ulimits = ["memlock=-1:-1"]`. ibverbs memory registration inside containers dies at
CRI-O's default memlock limit — the failure surfaces three layers up as cryptic NCCL/UCX init
errors. §10 row (memlock unlimited).

### RoCE QoS MachineConfig (`roce-qos.sh`, systemd oneshot after network-online)
**ENV BRANCH env/h100-8x-ib: DISABLED (`roceQos.enabled: false`).** The rails are InfiniBand —
credit-based lossless, QoS is the fabric's job (SLs / subnet manager); there is no host
DSCP/PFC/ECN/CNP to pin. The description below is kept as the RoCE reference only.

Pins, per rail PF, identically, every boot: `--trust dscp` (classify on DSCP, not PCP) · PFC
vector with prio 3 lossless · traffic class **106** = DSCP 26 + ECT bits (the ECN half NCCL/UCX
must match — §10 triple) · `cma_roce_tos` (RDMA-CM connections get the same TOS) · **CNP marking**
DSCP 48 / prio 6 (`roce_np`) · **DCQCN NP/RP enables on prio 3** (this *is* host-side "ECN
activation"; the switch does the WRED/ECN marking) · global pause off (`ethtool -A`) so link-level
pause can't fight PFC · MTU 9000.

**PFC/ECN answer in one line:** yes, all host-side PFC/ECN/DCQCN config is MachineConfig — this
one. The switch half (WRED thresholds, PFC on the same class, CNP queue strict-priority) is out of
band and must mirror these values. LLDP/DCBX: keep DCBX **off** in NIC firmware so the switch
cannot override this script — rationale in [BIOS.md](BIOS.md).

## Cross-layer invariants this chart carries (§10)
Role label `gpu-hpc` · reserved CPUs `0-7,56-63` · (RoCE DSCP/TC/CNP rows not applicable —
IB fabric, `roceQos` disabled) · hugepages small · memlock unlimited · RuntimeClass name
`performance-gpu-hpc` (NTO derives it from the profile name; `minimax-dynamo` hard-references it).

## Gate 1 (do not proceed past failure)
Node-side checks are automated: `SSH_KEY=... USER_SSH=... PREFIX=<node-prefix>
scripts/verify-nodes.sh` (its expected-value variables mirror `values.yaml` — keep in sync).
`verify-nodes.sh generate` derives the reserved/isolated cpusets from the nodes' real
topology (8-cores-per-socket rule, SMT-sibling-complete) — run it to seed a new SKU's values.
Full gate:
`/proc/cmdline` shows all args · hugepages + allocatable CPU correct · `tuned-adm active` shows
the child profile · `ibstat` shows all 8 compute rails **Active** (a `Polling` rail = dead gang
member later) · generated KubeletConfig shows `memoryManagerPolicy: Static` (verify, don't
assume) · `/proc/interrupts` shows rail-NIC IRQs on local-socket reserved cores · container
`ulimit -l` → unlimited · after Phase 2: `nvidia-smi topo -m` PIX per GPU↔NIC pair.
