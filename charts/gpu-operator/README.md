# gpu-operator — Phase 2

NFD + the NVIDIA GPU Operator, configured for the GPUDirect RDMA / GPUDirect Storage data paths this design depends on — whole physical GPUs only, no MIG, no time-slicing.

## Why it matters

The GPU driver here is not generic: **open kernel modules + DMA-BUF** is the supported GPUDirect RDMA path on RHCOS 9, and it's what NIXL/NCCL use for GPU↔NIC zero-copy. Get the ClusterPolicy wrong (legacy modules, MIG on) and every KV transfer silently downgrades or a second notion of "a GPU" appears that fights KAI's quota.

## What it deploys

- **NFD** — Subscription + a default `NodeFeatureDiscovery` instance. In the same chart as the GPU Operator because NFD **must** reconcile first (it labels the nodes the operator selects on).
- **NVIDIA GPU Operator** — Subscription + a `ClusterPolicy` tuned for this design (open modules, precompiled driver, GDS, gdrcopy, DCGM exporter, no MIG).

## Prerequisites & position

After node-foundation (needs the `gpu-hpc` pool + kernel args), before sriov-rails. `nvidia-smi topo -m` showing PIX depends on the BIOS ACS-off setting from [../node-foundation/BIOS.md](../node-foundation/BIOS.md).

## How to use

```bash
../install.sh gpu-operator
helm template gpu-operator       # inspect the NFD instance + ClusterPolicy
```

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `roleLabel` | `gpu-hpc` | Operator DaemonSets follow exactly this pool. §10 |
| `nfd.enabled` / `nfd.instance.enabled` | `true` | NFD Subscription + default instance (must reconcile before the GPU Operator) |
| `clusterPolicy.driver.useOpenKernelModules` | `true` | **Load-bearing** — the DMA-BUF GPUDirect RDMA path for NIXL/NCCL. §10 |
| `clusterPolicy.driver.usePrecompiled` | `true` | Disconnected: signed precompiled driver images. Kernel-version-specific — mirror the matching image before every z-stream upgrade |
| `clusterPolicy.driver.repository` | `<your-registry>/nvidia` | Your mirrored driver registry |
| `clusterPolicy.gds` | `true` | `nvidia-fs` → GPUDirect Storage (NVMe→HBM), consumed in Phases 4/6 |
| `clusterPolicy.gdrcopy` | `true` | Low-latency small-message D2H/H2D — helps NIXL/KVBM |
| `clusterPolicy.migStrategy` | `none` | Whole GPUs only — sharing/quota is KAI's job, not MIG's. §10 |
| `clusterPolicy.dcgmExporter` | `true` | Per-pool saturation metrics + ServiceMonitor into UWM Prometheus |

**In-box `mlx5` vs DOCA driver:** this chart assumes the RHCOS in-box RDMA driver (supports RoCEv2 + SR-IOV + DMA-BUF GDR, one less out-of-tree module air-gapped). Add the NVIDIA Network Operator only on a proven feature gap — and if so, it must roll out **before** the GPU driver on each node.

## Gate 2 (do not proceed past failure)

`nvidia-smi topo -m` → NVLink mesh GPU↔GPU, **PIX** GPU↔rail-NIC · `lsmod` shows `nvidia` (open), `nvidia_fs`, `gdrdrv` · persistence Enabled · DCGM metrics in UWM Prometheus. (Module presence ≠ data path — the GDR path is proven at Gate 3 via `NCCL_DEBUG=INFO`.)

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance.
