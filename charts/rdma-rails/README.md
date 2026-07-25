# rdma-rails — Phase 3

The RDMA rail NICs, configured on the **host** with NMState (`NodeNetworkConfigurationPolicy`).
**Replaces the old `sriov-rails` chart.** One chart, one `mode` switch, for both InfiniBand and RoCE.

## Why this replaces SR-IOV

GPU worker pods run **`hostNetwork: true`** (whole-GPU, no MIG). A hostNetwork pod already sees every
host NIC and its RDMA device, and `NCCL_IB_HCA` picks the ones for its GPUs — so there are **no VFs
and no NADs to attach**. All that's left is bringing the physical NICs up on the host, which is what
NMState does. SR-IOV's whole job (slice NICs into VFs, publish them as `openshift.io/railN`) is
therefore unnecessary here.

**The OFED driver stays.** NMState does not install RDMA kernel modules — keep the **NVIDIA Network
Operator** (`NicClusterPolicy.ofedDriver`) running for that. See [CLAUDE.md](CLAUDE.md) for the
three-layer split (driver / host-config / pod-contract).

## What it deploys

- **Kubernetes NMState Operator** Subscription + OperatorGroup + the `NMState` instance CR (deploys
  the nmstate-handler DaemonSet).
- **`mode: infiniband`** → one `NodeNetworkConfigurationPolicy` **per NIC** (`infiniband.nicList`),
  cluster-wide via the role label: `type: infiniband`, `state: up`, `mtu`, `infiniband.mode`. **No IP.**
  With `pkey` set, the policy also creates the IPoIB partition child `<nic>.<pkey-hex>` (e.g.
  `ibp24s0.8001`) and puts the MTU/mode there — that child is the rail interface.
- **`mode: roce`** → one `NodeNetworkConfigurationPolicy` **per (node, NIC)**, `nodeSelector` by
  hostname: `type: ethernet`, static `ipv4.address`, `mtu`, and **one route per NIC** per dst prefix.

## How to use

```bash
helm template rdma-rails --set mode=infiniband     # inspect the per-NIC IB policies (no IP)
helm template rdma-rails --set mode=roce           # inspect the per-node×NIC RoCE policies + routes
helm lint rdma-rails
```

**IB — add a NIC:** append to `infiniband.nicList`. **RoCE — add a node:** append to `roce.nodes[]`
with its per-NIC `{name, ip, gateway, routes}`. Addresses are **illustrative** — set from your
fabric plan.

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `mode` | `infiniband` | `infiniband` \| `roce` — selects which NNCP template renders |
| `roleLabel` | `gpu-hpc` | Node selector (IB mode) — must match node-foundation. §10 |
| `operator.*` | NMState op | Kubernetes NMState Operator Subscription + namespace `openshift-nmstate` |
| `infiniband.mtu` | `4092` | IB/IPoIB MTU — set to your fabric's value. §10 |
| `infiniband.ibMode` | `datagram` | `datagram` \| `connected` |
| `infiniband.pkey` | `null` | IB partition key, **quoted** (`"0x8001"`). `null` = unpartitioned. §10 |
| `infiniband.nicList[]` | `ibp24s0`, `ibp64s0` | The IB HCAs to bring up (no IP). Plain name inherits `pkey`, or `{name: …, pkey: "0x8002"}` to override |
| `roce.mtu` | `9000` | Host NIC MTU — must match switch + pods. §10 |
| `roce.nodes[]` | worker-0/1 | Per-node, per-NIC `{name, ip, gateway, routes[]}` — **illustrative** |

**One route per NIC (RoCE):** each rail NIC carries exactly one `destination` via its own gateway, so
the host routing table offers one NIC per remote prefix → deterministic NIC → `NCCL_CROSS_NIC=0`
holds. Never add a per-NIC default route (that's N-way ECMP). This is the old ROUTING.md rule, now
enforced host-side.

## Not owned here

Host RoCE QoS (DSCP 26 / TC 106 / CNP, PFC) → `node-foundation/roce-qos.sh` · OFED driver → NVIDIA
Network Operator · pod `hostNetwork`/`NCCL_IB_HCA` → `glm51-dynamo` · switch fabric → out of band.

## Gate 3 (do not proceed past failure)

`oc get nncp` all `Available` and every `oc get nnce` `SuccessfullyConfigured` per node · `ibstat` /
`ibv_devinfo` ports Active at the expected MTU · in a `hostNetwork` pod `NCCL_IB_HCA` sees the rail
NICs, `ib_write_bw`/`ib_send_bw` pass per NIC, `NCCL_DEBUG=INFO` shows GDRDMA and **no cross-rail** ·
**partitioned IB only:** the `<nic>.<pkey>` child exists (`ip link`) and the pkey matches the subnet
manager (`cat /sys/class/net/<nic>/device/infiniband/*/ports/1/pkeys/*`) ·
**RoCE only:** `ip route` = exactly one route per rail, `show_gids` index 3 = RoCEv2 IPv4, DSCP/PFC
counters increment on the switch.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance and the three-layer split.
