# CLAUDE.md — `gpu-operator` chart (Phase 2)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §2 / §10 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** NFD (Subscription + default `NodeFeatureDiscovery` instance) and the NVIDIA GPU
Operator (Subscription + `ClusterPolicy`). Both in one chart because NFD **must** reconcile
first — its labels are what the GPU Operator selects nodes on — and the ordering is a property
of this subject, not of the install script.

**Does NOT own:** the RDMA NIC driver (in-box `mlx5` from RHCOS — see below) · rail VFs
(→ `sriov-rails`) · DCGM *dashboards/alerts* (→ `observability`; the DCGM exporter +
ServiceMonitor themselves are created here by the operator).

## Why each configuration is what it is

- **`useOpenKernelModules: true` — the load-bearing line of the whole phase.** The open GPU
  driver + **DMA-BUF** is the supported GPUDirect RDMA path on RHCOS 9 kernels; it is what
  NIXL/NCCL use for GPU↔NIC zero-copy. The legacy `nvidia-peermem` path is the fallback, not the
  target. Turning this off silently downgrades every KV transfer.
- **`usePrecompiled: true`** — disconnected clusters can't build drivers at install time.
  Consequence to plan for: precompiled driver images are **kernel-version-specific**, so every
  OCP z-stream that bumps the RHCOS kernel needs the matching driver image mirrored *before* the
  cluster upgrade, or the driver DaemonSet wedges on the new kernel.
- **`gds: true`** (`nvidia-fs` module) — GPUDirect Storage: NVMe→HBM DMA without a CPU bounce.
  Consumed in Phase 4 (gdsio gate) and Phase 6 (KVBM disk tier / NIXL GDS flag).
- **`gdrcopy: true`** — low-latency small-message D2H/H2D copies; helps NIXL/KVBM metadata and
  small-tensor paths where full RDMA setup would dominate.
- **`migStrategy: none`, no time-slicing.** Whole physical GPUs only. Sharing/quota is KAI's job
  (one quota brain, §10) — slicing GPUs here would create a second, conflicting notion of "a
  GPU". Do not enable MIG for "utilization" reasons; use the batch queue for that.
- **DCGM exporter + ServiceMonitor: on** — DCGM is the per-pool saturation signal (§8) and the
  planner's GPU-side input. Metrics land in UWM Prometheus.
- **Tolerations + `nodeSelector` on the role label** — operator DaemonSets must follow exactly
  the `gpu-hpc` pool; §10 node-selection invariant.
- **In-box `mlx5` vs DOCA driver (deliberate omission):** we start on the RHCOS in-box driver —
  it supports RoCEv2, SR-IOV, and DMA-BUF GDR on current kernels, and it's one less out-of-tree
  module in an air-gapped cluster. Bring in the NVIDIA Network Operator only on a proven feature
  gap, and if you do, it must roll out **before** the GPU driver on each node (GDR symbol
  resolution order).

## Cross-layer invariants this chart carries (§10)
Role label `gpu-hpc` · open-modules/DMA-BUF ↔ NIXL/NCCL GDR path · `nvidia-smi topo -m` PIX
evidence depends on BIOS ACS-off ([../node-foundation/BIOS.md](../node-foundation/BIOS.md)) ·
whole-GPU-only ↔ KAI as the single quota brain.

## Gate 2 (do not proceed past failure)
`nvidia-smi topo -m` → NVLink mesh GPU↔GPU, **PIX** GPU↔rail-NIC · `lsmod` shows `nvidia` (open),
`nvidia_fs`, `gdrdrv` · persistence mode Enabled · DCGM metrics visible in UWM Prometheus.
Module presence ≠ data path: the GDR *path* is proven at Gate 3 (`NCCL_DEBUG=INFO` → GDRDMA).
