# CLAUDE.md — `lvms-storage` chart (Phase 4)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §4 / §10 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** the LVMS operator (Subscription + OperatorGroup) and the `LVMCluster` with the
`kvcache` device class (+ optional `models` class).

**Does NOT own:** GDS / `nvidia-fs` (→ `gpu-operator`; this chart only provides the xfs +
O_DIRECT filesystem GDS needs) · the PVC sizing (→ `glm51-dynamo` `prefill.diskPvc` — the §10
KVBM ordering lives there) · weight staging content (→ `model-staging`).

## Why each configuration is what it is

- **Two LVs, two jobs, never one.** `kvcache` (KVBM G3 disk tier — hot churn, fallocate-heavy)
  and `models` (staged weights — write-once read-many). Sharing one pool means KVBM churn and
  weight storage fight for the same space and the same thin-metadata budget.
- **`fstype: xfs` — REQUIRED, not a preference.** KVBM's disk tier allocates with `fallocate()`;
  xfs supports it properly. This is a §10 row — changing it breaks the KVBM disk tier at
  runtime, not at install.
- **`paths` pinned by-path, per socket.** NVMe drives are PCIe devices with a socket too. Pin
  by-path (stable across reboots, unlike /dev/nvmeX) and, where the chassis allows, build the
  kvcache LV from drives on **both** sockets so socket-1 decode/prefill writes don't cross the
  UPI. If all drives sit on one socket, accept it — NVMe is the *cold* tier by design; DRAM (G2)
  absorbs the hot path.
- **`thinPool.overprovisionRatio: 1` — the honest-constraint setting.** LVMS only produces thin
  pools; the "thick, striped" ideal isn't available here. `ratio=1` removes overcommit *risk*
  but not thin *metadata cost*. The escape hatch (doc §4): if Gate-4 fio/gdsio shows thin
  overhead hurting, create striped thick LVs out-of-band (MachineConfig script) and expose them
  with the Local Storage Operator instead. **Decide on Gate-4 numbers, not on principle.**
- **`sizePercent: 90`** — headroom for thin-pool metadata and recovery operations; a 100% pool
  that fills is a node-level incident (the §8 thin-pool alert exists for exactly this).
- **`models` class disabled by default** — `model-staging` defaults to a hostPath on an LV you
  manage; enable this class only if you prefer LVMS to manage that LV as a PVC. Don't run both
  paths at once.
- **Why WaitForFirstConsumer matters downstream:** LVMS storage is node-local. `glm51-dynamo`
  uses **generic ephemeral volumes** (one PVC per worker pod, bound on the pod's node) — a
  shared RWO PVC cannot serve replicas>1 across nodes. That design constraint originates here.

## Cross-layer invariants this chart carries (§10)
xfs + fallocate on the KV disk tier · LVMS PVC size ≥ `DYN_KVBM_DISK_CACHE_GB` (enforced in
`glm51-dynamo` values — grep both when resizing) · role label `gpu-hpc` node selector.

## Gate 4 (do not proceed past failure)
`fio` 1M sequential read on a test PVC ≈ aggregate of member NVMe · `gdsio` shows the GDS path
**active** (not compat/bounce mode) · `fallocate -l 1G` succeeds on the mounted fs · thin-pool
`data%` visible in monitoring (the §8 alert has a signal to watch).
