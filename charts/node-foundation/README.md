# node-foundation — Phase 1

The host layer for the `gpu-hpc` pool: CPU/NUMA/IRQ isolation, kernel tuning, hugepages, RDMA memlock, and per-boot RoCE NIC QoS. Everything a GPU worker pod needs from the operating system before it can run at line rate.

## Why it matters

This is the layer whose mistakes surface three phases later as "Dynamo is slow." A wrong reserved-CPU set puts NIC IRQs across the UPI; a missing memlock limit breaks ibverbs registration inside pods; a host DSCP that doesn't match the switch silently rides RDMA on the lossy queue. Get this right and every layer above inherits a clean foundation.

## What it deploys

- **MachineConfigPool** `gpu-hpc` — isolates kernel/tuning rollouts to GPU nodes.
- **PerformanceProfile** — reserved/isolated cpusets, `best-effort` NUMA policy, small hugepages, kernel args; NTO generates the KubeletConfig + Tuned + the `performance-gpu-hpc` RuntimeClass from it.
- **Child Tuned profile** — sysctls the profile doesn't cover (`vm.min_free_kbytes`, swappiness, buffers).
- **CRI-O memlock MachineConfig** — `memlock=-1:-1` so RDMA registration works in containers.
- **RoCE QoS MachineConfig** — [roce-qos.sh](files/roce-qos.sh) systemd oneshot pinning trust/PFC/DSCP/CNP/DCQCN/MTU per rail PF, every boot.

> **Every change here reboots the pool node by node.** Batch changes; don't iterate one sysctl at a time on a live fleet.

## Prerequisites & position

Runs after model-staging, before gpu-operator. Also requires the **out-of-band** BIOS + NIC-firmware settings in [BIOS.md](BIOS.md) — no chart can deliver those, and Gate 1 depends on them (e.g. ACS-off → `nvidia-smi topo -m` PIX).

## How to use

```bash
../install.sh node-foundation
helm template node-foundation    # inspect PerformanceProfile, Tuned, and the embedded roce-qos.sh
```

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `pool.roleLabel` | `gpu-hpc` | The node-selection invariant every other chart keys on. §10 |
| `performanceProfile.cpu.reserved` | `0-7,56-63` | 8 cores/socket on **both** sockets — NUMA-local housekeeping + NIC IRQ steering. Assumes SMT off. §10 |
| `performanceProfile.numa.topologyPolicy` | `best-effort` | **Not** `single-numa-node` — full-node pods span both sockets and would be rejected otherwise |
| `performanceProfile.hugepages` | 16×1G | Small on purpose — KVBM uses CUDA pinned memory, not hugetlbfs |
| `performanceProfile.additionalKernelArgs` | see values | Only args NTO doesn't generate: NUMA-balancing off, ASPM off, RCU poll, C-state caps. IOMMU/tsc/watchdog/skew_tick come from NTO (realTime hint + vendor include) — see [PARAMETERS.md](PARAMETERS.md) §4 |
| `performanceProfile.globallyDisableIrqLoadBalancing` | `false` | Per-pod IRQ exclusion instead (the `glm51-dynamo` RuntimeClass contract). §10 |
| `crioMemlock.enabled` | `true` | memlock unlimited for ibverbs. §10 |
| `roceQos.trafficClass` | `106` | DSCP 26 + ECN. Must match switch + pod env. §10 |
| `roceQos.cnpDscp` / `cnpPriority` | `48` / `6` | CNP marking — switch CNP queue mirrors this. §10 |
| `roceQos.pfcPriority` / `mtu` | `3` / `9000` | Lossless priority; MTU end-to-end. §10 |

## PFC / ECN / LLDP, in one place

**All host-side PFC/ECN/DCQCN is this chart's RoCE QoS MachineConfig** — trust=dscp, the PFC prio-3 vector, TC 106 (DSCP 26 + ECT bits), CNP DSCP 48/prio 6, the DCQCN NP/RP enables (that pair *is* host-side "ECN activation"), global pause off, MTU 9000. The switch does the WRED/ECN *marking* (out of band, must mirror these). **Keep DCBX-over-LLDP off in NIC firmware** ([BIOS.md](BIOS.md)) so this MachineConfig is the single owner of the NIC's QoS.

## Gate 1 (do not proceed past failure)

Automate the node-side half with [scripts/verify-nodes.sh](scripts/verify-nodes.sh) — SSHes into every matching node and checks lscpu/SMT, cmdline, hugepages, the generated kubelet config, the tuned sysctls, and the CRI-O drop-ins (RuntimeClass + memlock):

```bash
SSH_KEY=~/.ssh/id_rsa USER_SSH=core PREFIX=h200 ./scripts/verify-nodes.sh
```

On a new SKU (or when the lscpu/cpuset checks fail), run `./scripts/verify-nodes.sh generate` first — it reads each node's real topology and prints the `reserved`/`isolated` cpusets (8 cores/socket, SMT-sibling-complete) plus the script variables to paste. Failures on cmdline/sysctl/CRI-O checks mean the layer isn't applied at all (on HyperShift see [HYPERSHIFT.md](HYPERSHIFT.md)), not that the values are wrong.

Full gate: `/proc/cmdline` shows all args · hugepages + allocatable CPU correct · `tuned-adm active` shows the child profile · `mlnx_qos` shows trust=dscp + PFC prio 3 · `cnp_dscp` = 48 on every rail · generated KubeletConfig shows `memoryManagerPolicy: Static` · `/proc/interrupts` shows rail-NIC IRQs on local-socket reserved cores · container `ulimit -l` → unlimited · (after Phase 2) `nvidia-smi topo -m` PIX per GPU↔NIC pair.

## See also

[PARAMETERS.md](PARAMETERS.md) — deep dive on every parameter (what/default/why/failure mode) · [CLAUDE.md](CLAUDE.md) — why-each-decision guidance · [BIOS.md](BIOS.md) — the out-of-band BIOS + `mlxconfig` firmware half of this layer · [HYPERSHIFT.md](HYPERSHIFT.md) — delivering this layer via `NodePool` on Hosted Control Planes.
