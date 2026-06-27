# CLAUDE.md — `sriov-rails` chart (Phase 3)

Scoped guidance for **this chart only**. The repo-root [CLAUDE.md](../../CLAUDE.md) and
[glm51-openshift-deployment.md](../../glm51-openshift-deployment.md) §3 / §10 stay authoritative.
**The full addressing/routing rationale lives in [ROUTING.md](ROUTING.md) — read it before touching
the IP plan or the IPAM templates.**

## Scope — what this chart owns (and does not)

**Owns:** the SR-IOV RoCE rails — `SriovNetworkNodePolicy` (creates the VFs), `SriovNetwork` (the NAD
+ IPAM pods consume), `SriovNetworkPoolConfig` (`rdmaMode: exclusive`), and the SR-IOV Network
Operator `Subscription` + `OperatorGroup`.

**Does NOT own** (don't pull these in here):
- Host RoCE QoS (DSCP/PFC/CNP, `mlnx_qos`, `ethtool -A`) → `node-foundation` (`roce-qos.sh`).
- Switch fabric / BGP config → out of band, document only.
- Pod env (`NCCL_IB_*`, `UCX_IB_*`) and rail NAD annotations → `glm51-dynamo`.

This chart delivers **RDMA-capable VFs with the right MTU/QoS posture and per-rail routing**; the
marking lives host-side and the fabric routing lives switch-side.

## The model: routed BGP, port-to-port — NOT L2

- Each rail is a **numbered /31 point-to-point link** from one GPU NIC to **one leaf switch port**.
  No shared L2 subnet, no broadcast domain spanning nodes.
- `numVfs: 1` — every pod takes a **whole GPU (no MIG)** and pods are **full-node** (8 GPU + 8 rail
  VFs in one netns / one routing table). Don't raise without a MIG/partitioning reason.
- `deviceType: netdevice` + `isRdma: true` (NOT `vfio`) — kernel netdev + RDMA for RoCEv2.
- **2-leaf fabric:** rails 0–3 → leaf1, rails 4–7 → leaf2 (matches the socket split). Rail-aligned
  traffic (rail n ↔ rail n) stays inside one leaf; no cross-leaf routing needed.

## Object count (this reversed — read carefully)

- **`SriovNetworkNodePolicy`: 8 (one per rail), cluster-wide.** Creates the VF pool
  `openshift.io/<rail>` on every node via `nodeSelector`. Carries no IP.
- **`SriovNetwork` (NAD): N nodes × 8 rails.** One NAD **per node-link** (`rail0-node0`,
  `rail0-node1`, …) because each node's /31 + gw is **unique per link** and a NAD holds a fixed
  static address. This is **correct** for a per-link /31 fabric — see [ROUTING.md §8](ROUTING.md).
- **`SriovNetworkPoolConfig`: 1**, `rdmaMode: exclusive`.

The earlier "never make per-node NADs" warning was about per-node **`resourceName`** (which fragments
the VF pool). Per-node **NADs that share one `resourceName` per rail** are the right way to carry
per-link /31 addresses — the pool stays unified, only the address/gw differ per node.

**Pod contract:** the pod on node *N* must attach *that node's* NADs (`rail*-nodeN`) so it gets the
/31 + gw matching node *N*'s wiring. Natural here (one full-node pod per node).

## values.yaml shape

- `rails[]` — per-rail **hardware** (`pf`, `socket`, `leaf`) + the rail's cluster-wide remote
  **`block`** (the /24). Drives the 8 policies and supplies each NAD's route `dst`.
- `nodes[]` — per-node **`host`** (the VF's /31) + **`gw`** (the /31 peer / leaf port). Drives the
  N×8 NADs. Add one entry per node.

The route is always **static**: `addresses:[{address: host}]`, `routes:[{dst: rail.block, gw}]` —
`routes` at the **top level** of the ipam dict (sibling of `addresses`), never nested in the address.

## Why per-rail blocks, not one shared block or one per leaf

A single shared `dst` (or one per leaf) puts **multiple equal routes for the same destination** in
the full-node pod's one routing table → the kernel **ECMP-collapses** and scatters a rail's traffic
across the wrong NICs, breaking `NCCL_CROSS_NIC=0`. A **distinct /24 per rail** gives each VF exactly
one route → deterministic NIC selection. Group the /24s under a /22 per leaf for clean BGP summaries
(in-pod granularity and fabric summarization are different axes). Full derivation in [ROUTING.md].

> 8 NADs total (instead of N×8) would require a fabric redesign — anycast gateway per rail or
> BGP-unnumbered + Whereabouts pool. Not our model; we keep numbered /31 + per-node NADs.

## Cross-layer invariants this chart carries (must match elsewhere — see §10)

- **MTU 9000** — host PF, `policy.mtu` here, pod NADs, switch (leaf ≥9216).
- **VF `trust: on`, `spoofChk: off`** — so the VF honors DSCP/QoS egress marking; verify at Gate 3.
- **`rdmaMode: exclusive`** — each pod gets its own RDMA device + GID table (per-rail GID isolation).
- **RoCE QoS triple DSCP 26 / TC 106 / GID index 3** — set host-side (`node-foundation`) and pod-side
  (`glm51-dynamo`; NCCL gets the full TOS byte `NCCL_IB_TC=106`, not bare 26). This chart only needs
  the VFs RDMA-capable so the marking survives.
- **Rail map GPU n ↔ NIC n ↔ socket / leaf:** rails 0–3 socket 0 / leaf1, 4–7 socket 1 / leaf2.
  `pf` is per-SKU — verify with `cat /sys/class/net/<pf>/device/numa_node`.

## Gate 3 (do not proceed past failure)

In a pod: `ip route` shows exactly one route per rail (no duplicate dst); `show_gids` index 3 =
RoCEv2 IPv4; `ib_write_bw`/`ib_send_bw` pass per rail; DSCP/PFC counters increment on the switch;
`nvidia-smi topo -m` shows **PIX** per GPU↔NIC pair; `NCCL_DEBUG=INFO` shows **no cross-rail** comms.
