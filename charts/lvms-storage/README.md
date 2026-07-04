# lvms-storage — Phase 4

Local NVMe storage for the two tiers this platform needs: the **KVBM disk tier** (cold KV / parked sessions) and, optionally, the **staged model weights** LV.

## Why it matters

KVBM's cold tier is where parked sessions live and where the DRAM tier spills — it must be a real, fast, `fallocate`-capable filesystem or session park/resume (Gate 6) fails. The two jobs are deliberately separate LVs so KVBM churn and weight storage never fight for the same thin pool.

## What it deploys

- **LVMS operator** — Subscription + OperatorGroup.
- **`LVMCluster`** with a `kvcache` device class (default, xfs) and an optional disabled `models` class.

## Prerequisites & position

After sriov-rails, before kai-scheduler. GDS (`nvidia-fs` from [gpu-operator](../gpu-operator)) plus xfs + O_DIRECT is what lets NIXL/KVBM move NVMe→HBM without a CPU bounce.

## How to use

```bash
../install.sh lvms-storage
helm template lvms-storage       # inspect the LVMCluster device classes
```

Set the real NVMe `paths` (pin by-path) before installing — the defaults are placeholders.

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `roleLabel` | `gpu-hpc` | Device classes provisioned on GPU nodes only |
| `lvmCluster.deviceClasses[kvcache].fstype` | `xfs` | **REQUIRED** — KVBM disk tier uses `fallocate()`. §10 |
| `…[kvcache].paths` | placeholder | Pin **by-path**; ideally drives on **both** sockets so socket-1 writes don't cross the UPI |
| `…[kvcache].thinPool.sizePercent` | `90` | Headroom for thin metadata + recovery (a 100% pool that fills is a node incident) |
| `…[kvcache].thinPool.overprovisionRatio` | `1` | Removes overcommit risk (not thin metadata cost). Escape hatch if it hurts: striped thick LVs via LSO |
| `…[models].enabled` | `false` | Off by default — model-staging uses a hostPath. Enable only to manage the models LV as a PVC |

**Honest constraint:** LVMS only produces **thin** pools — the "thick, striped" ideal isn't available here. Accept thin + `ratio=1` and benchmark; if Gate-4 fio/gdsio shows the overhead hurts, fall back to striped thick LVs via MachineConfig + the Local Storage Operator. **Decide on Gate-4 numbers, not principle.**

## Gate 4 (do not proceed past failure)

`fio` 1M sequential read on a test PVC ≈ aggregate of member NVMe · `gdsio` shows the GDS path **active** (not compat/bounce mode) · `fallocate -l 1G` succeeds on the mounted fs · thin-pool `data%` visible in monitoring.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance. The PVC **size** (≥ `DYN_KVBM_DISK_CACHE_GB`) lives in [glm51-dynamo](../glm51-dynamo) — grep both when resizing. §10
