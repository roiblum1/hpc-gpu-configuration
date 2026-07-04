# sriov-rails — Phase 3

The 8 RoCEv2 rail NICs, exposed as SR-IOV VFs with the right MTU/QoS posture and **per-rail routing** for a numbered point-to-point BGP fabric. This is the DRA stand-in on OCP 4.20.

## Why it matters

The rails carry NIXL KV transfers (prefill→decode) and NCCL EP/TP collectives. If a rail's VF isn't RDMA-capable, or its route is ambiguous, or its trust mode is wrong, traffic silently rides the wrong NIC or the lossy queue — and NCCL "gets flaky under load." The rail-per-segment L3 design makes GPU n ↔ NIC n alignment *structural* (cross-rail traffic can't route).

> **Read [ROUTING.md](ROUTING.md) before touching the IP plan or IPAM templates** — it explains the /31, per-rail-block, per-node-NAD, and ECMP reasoning in full.

## What it deploys

- **8× `SriovNetworkNodePolicy`** (one per rail, cluster-wide) — creates the VF pool `openshift.io/<rail>` on every matching node.
- **N×8 `SriovNetwork`** (NADs) — one per node-link, carrying that node's /31 host address, gateway (the leaf port), and per-rail route.
- **`SriovNetworkPoolConfig`** — `rdmaMode: exclusive`.
- SR-IOV Network Operator Subscription + OperatorGroup.

## The object-count model (read carefully)

- **Policies: 8 total.** `pf`/`socket`/`leaf` are identical on every node, so one policy per rail creates that rail's VFs on **all** nodes (keyed by `resourceName`, not by node).
- **NADs: N nodes × 8 rails.** Each node's rail link is a unique /31 with a unique gateway, and a NAD holds a fixed static address — so you need one NAD per node-link (`rail0-node0`, `rail0-node1`, …), all sharing `resourceName=<rail>` (one VF pool). The pod on node *N* attaches *that node's* NADs. This per-node-NAD pattern is **correct** for a numbered /31 fabric — the "never per-node NADs" warning was about per-node `resourceName`, which fragments the pool.

## How to use

```bash
../install.sh sriov-rails
helm template sriov-rails         # inspect the 8 policies + N×8 NADs
```

**Add a node:** append an entry to `nodes[]` with its 8 rail `{host, gw}` /31 endpoints. **Add a hardware generation** with different PF names: add one extra policy per generation reusing the same `resourceName`.

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `roleLabel` | `gpu-hpc` | Node selector — must match node-foundation. §10 |
| `mtu` | `9000` | Must match host PF + switch + pod NADs. §10 |
| `vf.trust` / `vf.spoofChk` | `on` / `off` | So the VF honors DSCP/QoS egress marking — verify at Gate 3. §10 |
| `rdma.mode` | `exclusive` | Each pod gets its own RDMA device + GID table (per-rail GID isolation). §10 |
| `numVfs` | `1` | Whole-GPU, full-node pods → exactly 1 VF/rail/pod, no spare |
| `rails[]` | 8 rails | Per-rail `pf` / `socket` / `leaf` + cluster-wide `block` (/24 route dst). Rails 0–3 → socket0/leaf1, 4–7 → socket1/leaf2 |
| `nodes[]` | node0, node1 | Per-node /31 endpoints (`host` = VF address, `gw` = leaf port). One entry per node — **addresses are illustrative**, set from your fabric plan |

**Why per-rail /24 blocks** (not one shared block): a shared route dst puts multiple equal routes in the full-node pod's one routing table → the kernel ECMP-collapses and scatters a rail's traffic across the wrong NICs, breaking `NCCL_CROSS_NIC=0`. A distinct /24 per rail gives each VF exactly one deterministic route. Group under /23 per leaf for clean BGP summaries.

## Gate 3 (do not proceed past failure)

In a pod: `ip route` shows exactly one route per rail (no duplicate dst) · `show_gids` index 3 = RoCEv2 IPv4 · `ib_write_bw`/`ib_send_bw` pass per rail · DSCP/PFC counters increment on the switch · `nvidia-smi topo -m` shows PIX per GPU↔NIC pair · `NCCL_DEBUG=INFO` shows **no cross-rail** comms and GDRDMA engaged.

## See also

[ROUTING.md](ROUTING.md) — full addressing/routing derivation · [CLAUDE.md](CLAUDE.md) — why-each-decision guidance.
