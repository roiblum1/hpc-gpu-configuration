# CLAUDE.md — `rdma-rails` chart (Phase 3)

Scoped guidance for **this chart only**. The repo-root [CLAUDE.md](../../CLAUDE.md) and
[glm51-openshift-deployment.md](../../glm51-openshift-deployment.md) §3 / §10 stay authoritative.
This chart **replaces the old `sriov-rails` chart** — same phase, different mechanism.

## Why this exists (read before "putting the VFs back")

GPU worker pods run **`hostNetwork: true`** (whole-GPU, no MIG). A hostNetwork pod shares the host
netns, so it sees **every host NIC and its RDMA device directly** — `NCCL_IB_HCA` (set in
`glm51-dynamo`) picks the NICs for the pod's GPUs. With hostNetwork there is **nothing to attach**:
no VFs, no `SriovNetwork` NADs, no Macvlan/IPoIB, no rdma-shared-device-plugin. The only remaining
job is bringing the **physical NICs** up on the host — which is exactly what NMState does. That is
the whole reason SR-IOV is gone here.

## The three-layer split (do not conflate)

| Layer | Provides | Where |
|---|---|---|
| OFED driver | The kernel modules that make a NIC RDMA-capable (`mlx5_ib`, `nvidia_peermem`, …) | **NVIDIA Network Operator — separate chart/concern, NOT here** |
| Host NIC config | interface type, MTU, IP, routes | **this chart (NMState NNCPs)** |
| Pod contract | `hostNetwork: true`, `NCCL_IB_HCA`, `UCX_NET_DEVICES` | `glm51-dynamo` |

NMState does **not** install drivers. Keep the NVIDIA Network Operator running for the OFED driver.

## Scope — what this chart owns (and does not)

**Owns:** the Kubernetes **NMState Operator** (`Subscription` + `OperatorGroup`), the `NMState`
instance CR (deploys the nmstate-handler), and the per-NIC **`NodeNetworkConfigurationPolicy`**
objects that configure the rail NICs on the host.

**Does NOT own:**
- OFED / RDMA kernel driver → **NVIDIA Network Operator** (`NicClusterPolicy.ofedDriver`). Untouched.
- Host RoCE QoS (DSCP/PFC/CNP, `mlnx_qos`, `ethtool -A`) → `node-foundation` (`roce-qos.sh`).
  NMState does **not** configure DCB/PFC — the QoS triple still lives host-side there.
- Pod `hostNetwork`/`NCCL_IB_HCA`/`UCX_NET_DEVICES` env → `glm51-dynamo`.
- Switch fabric / BGP → out of band, document only.

## `mode` — one chart, two fabrics

- **`mode: infiniband`** → `templates/nncp-infiniband.yaml`. One NNCP **per NIC** in
  `infiniband.nicList`, cluster-wide via the role label (nicList is identical on identical nodes).
  Sets `type: infiniband`, `state: up`, `mtu`, `infiniband.mode`. **No IP** — NCCL uses IB verbs;
  addressing is by GID/LID, not IPv4. Partitioning via `pkey` — see below.
- **`mode: roce`** → `templates/nncp-roce.yaml`. One NNCP **per (node, NIC)**, `nodeSelector` by
  `kubernetes.io/hostname` (each node's rail NIC has a unique IP). Sets `type: ethernet`, static
  `ipv4.address`, `mtu`, and **exactly one route per NIC** per dst prefix via that rail's gateway.

## IB partitioning (`pkey`) — why it renders two interfaces

nmstate does not model a partition as a field on the HCA; it models it as an **IPoIB child
interface** carrying `infiniband.base-iface` + `infiniband.pkey`. So the template branches:

- **`pkey: null`** (unpartitioned / default partition) → one interface: the base HCA with
  `mtu` + `mode`.
- **`pkey` set** → two interfaces: the base HCA brought **up plain**, plus the child
  `<nic>.<pkey-hex>` (e.g. `ibp24s0.8001` — kernel naming, 4-digit lowercase hex, no `0x`) carrying
  `mtu` + `mode` + `base-iface` + `pkey`. The child is the rail interface.

Set it chart-wide (`infiniband.pkey`) or per NIC via the mapping form of a `nicList` entry
(`{name: ibp64s0, pkey: "0x8002"}`); a plain string entry inherits the chart value.

**Quote the pkey.** Unquoted `0x8001` is parsed by YAML as the integer `32769`. The template
normalizes an int back to `0x%04x` defensively, but quoting is what you should write.

> **Cross-layer:** the pkey must match the partition your subnet manager assigns these ports. It
> also has a pod-side half — native IB verbs select a partition by pkey index, so if the fabric is
> partitioned, confirm the workload's IB partition matches at Gate 3 rather than assuming the
> default. Getting this wrong looks like "the link is up but no traffic passes."

## The ECMP rule survives (RoCE)

The old `sriov-rails/ROUTING.md` core rule still holds, now enforced in the **host** routing table
instead of NAD IPAM: **one route per NIC**. Each rail NIC carries one `destination` via its own
`next-hop-address`, so the host offers exactly one NIC per remote prefix → deterministic NIC
selection → `NCCL_CROSS_NIC=0` is a hard property. **Never add a per-NIC default route** (0.0.0.0/0)
— N default routes across N rails = N-way ECMP, the exact failure the per-rail design removes.

## Cross-layer invariants this chart carries (§10)

- **MTU** — now set **authoritatively on the host NIC by NMState** (`infiniband.mtu` / `roce.mtu`),
  where the SR-IOV chart set it on the VF. Must still match switch (leaf ≥9216) and pods. RoCE =
  9000; IB link/IPoIB MTU differs (set to your fabric's value).
- **RoCE QoS triple DSCP 26 / TC 106 / GID 3** — unchanged, host-side in `node-foundation`
  (`roce-qos.sh`) and pod-side in `glm51-dynamo`. This chart only brings the NIC up.
- **Rail map GPU n ↔ NIC n ↔ socket / leaf** — the NIC names in `nicList` / `roce.nodes[].nics[]`
  must be socket-correct; verify with `cat /sys/class/net/<nic>/device/numa_node`.
- **IB `pkey`** (partitioned fabrics only) — must match the partition the subnet manager assigns
  these ports, and the workload's IB partition on the pod side. See the partitioning section above.

## Operator ordering caveat

The `NMState` instance CR and the NNCPs depend on CRDs the `Subscription` installs, and the handler
must be running before NNCPs reconcile. Helm does not await OLM, so on a cold install apply the
operator first (or re-run the idempotent `helm upgrade --install`) — the Phase-3 gate covers this.
Do not proceed to Gate 3 until `oc get nmstate nmstate` shows the handler up and every `nnce` is
`SuccessfullyConfigured`.

## Gate 3 (do not proceed past failure)

`oc get nncp` all `Available` and every `oc get nnce` (enactment) `SuccessfullyConfigured` per node;
`ibstat` / `ibv_devinfo` ports **Active** with the expected MTU; in a `hostNetwork` pod `NCCL_IB_HCA`
sees the rail NICs, `ib_write_bw` / `ib_send_bw` pass per NIC, `NCCL_DEBUG=INFO` shows **GDRDMA** and
**no cross-rail** comms. **RoCE only:** `ip route` shows exactly one route per rail (no duplicate
dst), `show_gids` index 3 = RoCEv2 IPv4, DSCP/PFC counters increment on the switch under load.
