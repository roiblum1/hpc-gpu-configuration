# node-foundation — Phase 1

The host layer for the `gpu-hpc` pool: CPU/NUMA/IRQ isolation, kernel tuning, hugepages, RDMA memlock. Everything a GPU worker pod needs from the operating system before it can run at line rate. **On this branch (`env/h100-8x-ib`) the RoCE QoS MachineConfig is disabled** — the rails are InfiniBand (credit-based lossless; QoS is the subnet manager's job).

## Why it matters

This is the layer whose mistakes surface three phases later as "Dynamo is slow." A wrong reserved-CPU set puts NIC IRQs across the UPI; a missing memlock limit breaks ibverbs registration inside pods; a host DSCP that doesn't match the switch silently rides RDMA on the lossy queue. Get this right and every layer above inherits a clean foundation.

## What it deploys

- **MachineConfigPool** `gpu-hpc` — isolates kernel/tuning rollouts to GPU nodes.
- **PerformanceProfile** — reserved/isolated cpusets, `best-effort` NUMA policy, small hugepages, kernel args; NTO generates the KubeletConfig + Tuned + the `performance-gpu-hpc` RuntimeClass from it.
- **Child Tuned profile** — sysctls the profile doesn't cover (`vm.min_free_kbytes`, swappiness, buffers).
- **CRI-O memlock MachineConfig** — `memlock=-1:-1` so RDMA registration works in containers.
- **RoCE QoS MachineConfig** — **not rendered on this branch** (`roceQos.enabled: false`, IB fabric); [roce-qos.sh](files/roce-qos.sh) stays as the RoCE reference.

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
| `performanceProfile.additionalKernelArgs` | see values | IOMMU passthrough, NUMA-balancing off, C-state/ASPM/RCU latency args. **Never** hand-add isolcpus/nohz_full — NTO generates them |
| `performanceProfile.globallyDisableIrqLoadBalancing` | `false` | Per-pod IRQ exclusion instead (the `minimax-dynamo` RuntimeClass contract). §10 |
| `crioMemlock.enabled` | `true` | memlock unlimited for ibverbs (this covers the LWS manifest's `IPC_LOCK`). §10 |
| `roceQos.enabled` | **`false`** | IB fabric — no host DSCP/PFC/ECN/CNP; the remaining `roceQos.*` values are the dormant RoCE reference |

## PFC / ECN / LLDP, in one place

**Not on InfiniBand.** PFC/ECN/DCQCN/DCBX are RoCE machinery (making lossy Ethernet lossless); IB is lossless by credit-based flow control, and its QoS lives in the fabric (SLs / subnet manager). That is why `roceQos.enabled: false` here and why the mlxconfig DCBX rows in [BIOS.md](BIOS.md) don't apply to IB-mode CX-7s. The QoS gate check is replaced by: `ibstat` shows all compute rails **Active**.

## Gate 1 (do not proceed past failure)

Automate the node-side half with [scripts/verify-nodes.sh](scripts/verify-nodes.sh) — SSHes into every matching node and checks lscpu/SMT, cmdline, hugepages, the generated kubelet config, the tuned sysctls, and the CRI-O drop-ins (RuntimeClass + memlock):

```bash
SSH_KEY=~/.ssh/id_rsa USER_SSH=core PREFIX=h100 ./scripts/verify-nodes.sh
```

Full gate: `/proc/cmdline` shows all args · hugepages + allocatable CPU correct · `tuned-adm active` shows the child profile · `ibstat` shows all 8 compute rails **Active** (not `Polling`) · generated KubeletConfig shows `memoryManagerPolicy: Static` · `/proc/interrupts` shows rail-NIC IRQs on local-socket reserved cores · container `ulimit -l` → unlimited · (after Phase 2) `nvidia-smi topo -m` PIX per GPU↔NIC pair.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance · [BIOS.md](BIOS.md) — the out-of-band BIOS + `mlxconfig` firmware half of this layer · [HYPERSHIFT.md](HYPERSHIFT.md) — delivering this layer via `NodePool` on Hosted Control Planes.
