# SR-IOV rail routing — design rationale ("why we did what we did")

This is the decision record for how the `sriov-rails` chart addresses and routes the RoCE rails.
Read it before changing `values.yaml` addressing or the `SriovNetwork`/`SriovNetworkNodePolicy`
templates. It explains, from first principles, the rail / ECMP / per-node-NAD reasoning behind a
design that otherwise looks like "why are there 24 of these?".

---

## 1. The physical setup

- Each server has **8 GPUs** and **8 NICs** — one NIC per GPU. A GPU+NIC pair is a **"rail"**
  (rail 0 = GPU0+NIC0 … rail 7 = GPU7+NIC7).
- Each NIC is cabled to a leaf switch over a **/31** point-to-point link: exactly two IPs, the NIC
  on one end, the leaf switch port on the other. The fabric is **routed (BGP)**, not L2.
- **Two leaf switches:** NICs 0–3 of every server → **leaf1**; NICs 4–7 → **leaf2**. This lines up
  with the CPU socket split (rails 0–3 = socket 0, rails 4–7 = socket 1).
- **Two spines** tie the leaves together (redundancy + scale-out). Rail-aligned traffic never
  needs them (see §7) — they carry cross-leaf and future leaf-to-leaf growth.

### Topology (2 spine / 2 leaf / 2 server × 8 GPU)

```
                       ┌──────────┐        ┌──────────┐
   SPINE               │  spine1  │        │  spine2  │     ties the leaves together;
   (redundancy,        └──┬────┬──┘        └──┬────┬──┘     redundancy + scale-out.
    scale-out;           │    └────────┐  ┌──┘    │        Every leaf uplinks to BOTH
    off the hot path)    │      ┌──────┼──┘       │        spines. Rail-aligned NCCL
                         │      │      └───────┐  │        never rides the spine.
                       ┌─┴──────┴─┐        ┌───┴──┴───┐
   LEAF  (L3 / BGP)    │  leaf1   │        │  leaf2   │     leaf1 owns rails 0–3,
                       │ rails    │        │ rails    │     leaf2 owns rails 4–7.
                       │  0–3     │        │  4–7     │
                       └──┬────┬──┘        └──┬────┬──┘
                          │    │  8 × /31      │    │       one /31 port-to-port link
                          │    │  per server   │    │       per NIC (NICn ── leaf port)
   ───────────────────────┼────┼──────────────┼────┼──────────────────────────────────
   ┌──────────────────────┴────┴──────────────┴────┴───────────────────────────────┐
   │ SERVER  (node0; node1 identical)                  2 sockets · 8 GPU · 8 NIC     │
   │                                                                                 │
   │      socket 0  ──▶ leaf1                  socket 1  ──▶ leaf2                    │
   │      GPU0  GPU1  GPU2  GPU3               GPU4  GPU5  GPU6  GPU7                 │
   │       │     │     │     │                  │     │     │     │                   │
   │      NIC0  NIC1  NIC2  NIC3               NIC4  NIC5  NIC6  NIC7                 │
   │      rail0 rail1 rail2 rail3              rail4 rail5 rail6 rail7                │
   │       └──────── NVLink mesh: all 8 GPUs talk in-node, full speed ───────┘       │
   └─────────────────────────────────────────────────────────────────────────────────┘

   node0.NIC0 and node1.NIC0 BOTH land on leaf1  →  rail0 ↔ rail0 stays on one leaf.
```

## 2. What the software wants — "rail discipline"

**NCCL** is the library the GPUs use to exchange data across servers. The rule a rail-optimized
cluster is built on:

> **GPU *n* sends only out its own NIC *n*, and talks only to GPU *n* on other servers.**

That is what `NCCL_CROSS_NIC=0` means. Rail *n* ↔ rail *n* is the clean, congestion-free path the
topology was cabled for. If GPU0's traffic ever leaves via NIC3, you get unpredictable congestion
and slowdowns. Keeping each GPU on its own NIC is **rail discipline**.

## 3. How a packet actually picks a NIC (the part that's easy to miss)

"GPU0 uses NIC0" is **not** automatic. When data is addressed to some IP, the Linux kernel consults
its **routing table** — rules of the form *"to reach destination X, send out interface Y via
next-hop Z"* — and picks the NIC **by matching the destination address**. A route has:

- **`dst`** — which destination addresses it covers (e.g. `192.168.110.0/24`).
- **`gw`** — the next-hop neighbor to hand the packet to (for us: the leaf switch port on the /31).

So the routing table is what decides which rail a packet leaves by. Get it wrong and the GPU uses
the wrong NIC even though you "assigned" it one.

## 4. ECMP — and why it breaks rail discipline

**ECMP** ("Equal-Cost Multi-Path") is kernel behavior: *if two or more routes are equally good for
the same destination, the kernel load-balances (spreads) traffic across all of them.* Normally a
feature; for rail discipline a disaster. If the table has two valid ways to reach a destination —
one via NIC0, one via NIC1 — the kernel scatters GPU0's traffic across both. Traffic "leaks" onto
the wrong rail, breaking `NCCL_CROSS_NIC=0`.

**The rule we must enforce: for any destination, the routing table offers exactly ONE NIC. No ties.**

## 5. The twist that makes this critical here: full-node pods

In this project a GPU worker **pod takes the whole server** — all 8 GPUs and **all 8 NICs (VFs) in
one pod, sharing one routing table**. (A generic SR-IOV guide assuming "one NIC per pod" cannot have
this ambiguity — but we do.) With 8 NICs in one table it is easy to write rules where two NICs match
the same destination → ECMP → leak. So per-rail segmentation is **mandatory**, not optional.

## 6. Why per-leaf segmentation fails, per-rail works

**Per-leaf (one block for rails 0–3, one for 4–7) — WRONG.** It produces, in the single pod table:

```
to leaf1-block via NIC0 ┐
to leaf1-block via NIC1 │  4 equal routes, same dst → kernel ECMPs across NIC0–3
to leaf1-block via NIC2 │
to leaf1-block via NIC3 ┘
```

NCCL pins NIC0 for rail0, but route resolution may return NIC1/2/3 → cross-rail leak. Per-leaf just
shrinks the blast radius from 8 rails to 4; it does **not** fix it.

**Per-rail (a distinct block per rail) — RIGHT.**

```
to rail0-block via NIC0   ← only ONE route matches rail0-block
to rail1-block via NIC1
...
to rail7-block via NIC7
```

Every destination matches exactly one route → exactly one NIC → no ECMP. Rail discipline becomes a
hard property of the routing table.

## 7. The 2-leaf topology is fine — and we honor it in the address plan

Because rail *n* only talks to rail *n*, and rails 0–3 are all on leaf1 / 4–7 all on leaf2, **every
rail-aligned flow stays inside one leaf** (rail0↔rail0 never leaves leaf1). No spine/cross-leaf
routing is needed for the collective; cross-rail data uses NVLink + PXN inside the node. The
topology is healthy as-is.

We still respect "two leaves" — in the **numbering**, not the routing granularity. The 8 per-rail
`/24` blocks are grouped so rails 0–3 sit on leaf1 and 4–7 on leaf2:

| rail | leaf | per-rail block (the pod's route `dst`) | leaf summary (BGP) |
|---|---|---|---|
| rail0 | leaf1 | `192.168.110.0/24` | `192.168.110.0/23` + `192.168.112.0/23` |
| rail1 | leaf1 | `192.168.111.0/24` | (rail0–3 = two /23s) |
| rail2 | leaf1 | `192.168.112.0/24` | |
| rail3 | leaf1 | `192.168.113.0/24` | |
| rail4 | leaf2 | `192.168.114.0/24` | `192.168.114.0/23` + `192.168.116.0/23` |
| rail5 | leaf2 | `192.168.115.0/24` | (rail4–7 = two /23s) |
| rail6 | leaf2 | `192.168.116.0/24` | |
| rail7 | leaf2 | `192.168.117.0/24` | |

### Why two /23s, not one /22 (subnetting in one rule)

A prefix can only summarize /24s that sit on **its own power-of-two boundary**:

```
/24 = 1 × /24
/23 = 2 × /24  — the pair must START ON AN EVEN third octet:  .110+.111, .112+.113, ...
/22 = 4 × /24  — the four must START ON A MULTIPLE OF 4:       .108-.111, .112-.115, ...
```

leaf1 owns `.110 .111 .112 .113` = two even-aligned pairs = `192.168.110.0/23` + `192.168.112.0/23`.
It can't be a single /22: the nearest /22 boundaries are `.108-.111` and `.112-.115`, so a written
`192.168.110.0/22` actually means `.108-.111` — it would **drop rail2 (.112) and rail3 (.113)**.
leaf2 (`.114-.117`) is the same story → two /23s. To collapse a leaf into **one** /22, renumber its
four /24s to a multiple-of-4 start (leaf1 `.108-.111`, leaf2 `.112-.115`).

> ⚠️ The danger is silent: trust a wrong `/22` and do `aggregate-address … summary-only` on the leaf
> and the dropped rails get **blackholed** — looks like a RoCE failure, is really a BGP summary bug.

In-pod: 8 per-rail routes → deterministic. On the fabric: summarize per leaf (two /23s as numbered,
one /22 if renumbered) or just advertise the eight /24s — at this node count it's free. The route
`dst` is **always** the per-rail /24, never the summary. Address layout and routing granularity are
different axes; they don't conflict.

### Full address plan (node × rail) — illustrative

This is what the chart renders from `values.yaml` (verified against `helm template`). Read it as: the
**VF IP** and **GW** are unique **per node-link**; the route **`dst` is the same per rail** from every
node (it is that rail's whole /24). The NAD object is named `rail<N>-node<M>`. Pattern here: node *M*'s
VF = `.(2M+1)`, GW = `.(2M)` (node0 → `.1`/`.0`, node1 → `.3`/`.2`, node2 → `.5`/`.4`, …).

| Node | Rail (GPU) | Leaf | VF IP (`/31`) | GW (leaf port) | Route `dst` |
|---|---|---|---|---|---|
| node0 | rail0 (GPU0) | leaf1 | `192.168.110.1/31` | `192.168.110.0` | `192.168.110.0/24` |
| node0 | rail1 (GPU1) | leaf1 | `192.168.111.1/31` | `192.168.111.0` | `192.168.111.0/24` |
| node0 | rail2 (GPU2) | leaf1 | `192.168.112.1/31` | `192.168.112.0` | `192.168.112.0/24` |
| node0 | rail3 (GPU3) | leaf1 | `192.168.113.1/31` | `192.168.113.0` | `192.168.113.0/24` |
| node0 | rail4 (GPU4) | leaf2 | `192.168.114.1/31` | `192.168.114.0` | `192.168.114.0/24` |
| node0 | rail5 (GPU5) | leaf2 | `192.168.115.1/31` | `192.168.115.0` | `192.168.115.0/24` |
| node0 | rail6 (GPU6) | leaf2 | `192.168.116.1/31` | `192.168.116.0` | `192.168.116.0/24` |
| node0 | rail7 (GPU7) | leaf2 | `192.168.117.1/31` | `192.168.117.0` | `192.168.117.0/24` |
| node1 | rail0 (GPU0) | leaf1 | `192.168.110.3/31` | `192.168.110.2` | `192.168.110.0/24` |
| node1 | rail1 (GPU1) | leaf1 | `192.168.111.3/31` | `192.168.111.2` | `192.168.111.0/24` |
| node1 | rail2 (GPU2) | leaf1 | `192.168.112.3/31` | `192.168.112.2` | `192.168.112.0/24` |
| node1 | rail3 (GPU3) | leaf1 | `192.168.113.3/31` | `192.168.113.2` | `192.168.113.0/24` |
| node1 | rail4 (GPU4) | leaf2 | `192.168.114.3/31` | `192.168.114.2` | `192.168.114.0/24` |
| node1 | rail5 (GPU5) | leaf2 | `192.168.115.3/31` | `192.168.115.2` | `192.168.115.0/24` |
| node1 | rail6 (GPU6) | leaf2 | `192.168.116.3/31` | `192.168.116.2` | `192.168.116.0/24` |
| node1 | rail7 (GPU7) | leaf2 | `192.168.117.3/31` | `192.168.117.2` | `192.168.117.0/24` |

Adding **node2** = 8 more rows with VF `.5`/GW `.4` per rail (`dst` unchanged). The `dst` column
repeating down each rail is the whole point — it's what keeps every node's rail *n* pointed at the
same remote block, out NIC *n*.

## 8. Why there are N × 8 SriovNetwork objects (per-node NADs)

A `SriovNetwork` is a **cluster-wide** NAD and its `static` IPAM holds **one fixed address + gw**.
But each node's rail0 link is a **different /31 with a different gw** (node0's NIC0 is cabled to a
different leaf port than node1's NIC0). One fixed-value NAD cannot represent two different /31s, so
we need **one NAD per node-link**: `rail0-node0`, `rail0-node1`, … → **N nodes × 8 rails**. With a
per-link numbered /31 fabric this is correct, not a smell (and CR count is explicitly not a concern
here — performance is). What stays flat:

- **`SriovNetworkNodePolicy` is per-rail (8 total)** — it only *creates the VFs* and carries no IP,
  so one policy per rail builds that rail's VF pool (`openshift.io/rail0`) on every node.
- All `rail0-nodeN` NADs share `resourceName: rail0` (one VF pool).

**Pod contract:** the pod on node *N* must attach *that node's* NADs (`rail*-nodeN`), so it gets the
/31 + gw that physically matches node *N*'s wiring. Natural here because pods are one-per-node
(full-node). Attaching the wrong node's NAD gives a valid-looking IP wired to the wrong leaf port.

> **Could it be 8 NADs total instead of N×8?** Only by changing the fabric: a shared subnet per rail
> with an **anycast gateway** (same gw IP on every leaf) or **BGP-unnumbered** links, then a
> Whereabouts pool per rail. That removes the per-link gw, so one NAD per rail serves all nodes. It
> is a fabric L3 redesign, not a chart change, and it is **not** our current model. We keep numbered
> /31 + per-node NADs because the fabric is built that way and it is the validated high-performance
> routed model.

## 9. Chart shape (how `values.yaml` maps to objects)

- `rails[]` — per-rail **hardware** (`pf`, `socket`, `leaf`) + the rail's cluster-wide remote
  **`block`** (the /24). Drives the **8** `SriovNetworkNodePolicy` and supplies each NAD's route
  `dst`.
- `nodes[]` — per-node **`host`** (the VF's /31) and **`gw`** (the /31 peer). Drives the **N×8**
  `SriovNetwork` NADs (`<rail>-<node>`). The `dst` comes from the matching `rails[].block`, so the
  remote block is per-rail (same from every node) while `host`/`gw` are per-node-link.

Rendered IPAM (e.g. `rail0-node0` / `rail0-node1`), matching the hand-written target:

```json
{ "type": "static",
  "addresses": [ { "address": "192.168.110.1/31" } ],
  "routes":    [ { "dst": "192.168.110.0/24", "gw": "192.168.110.0" } ] }   // node0

{ "type": "static",
  "addresses": [ { "address": "192.168.110.3/31" } ],
  "routes":    [ { "dst": "192.168.110.0/24", "gw": "192.168.110.2" } ] }   // node1, same block
```

## 10. What the deep-research validation confirmed (kept as-is)

- **Routed /31 + leaf-port gateway** — correct; the standard eBGP "AI/ML routed fabric" model
  (NVIDIA Spectrum-X, Cisco, Broadcom MI300X /31 designs).
- **Static IPAM** beats Whereabouts here — we want fixed, known per-link addresses, not a dynamic
  pool.
- **QoS: traffic-class 106 = DSCP 26 (AF31) + ECN-capable bit** — canonical RoCEv2, not a bug. Give
  NCCL the **full TOS byte** (`NCCL_IB_TC=106`), not the bare DSCP 26. CNP = DSCP 48. GID index 3 =
  RoCEv2/IPv4 on mlx5 (verify inside the pod; NCCL ≥2.21 can auto-select with `-1`).
- **MTU 9000 end-to-end** (VF, pod, every leaf port at ≥9216). One mismatched hop kills PFC and
  tanks throughput.
- **RDMA `exclusive` mode** (`SriovNetworkPoolConfig.rdmaMode: exclusive`) — highest-priority
  correctness item: each pod gets its own isolated RDMA device + GID table. Added in this chart.

### Out of band (host/switch/BIOS — not chart objects)
- ECN/DCQCN as primary congestion control; PFC tuned as a per-hop safety net (ECN/WRED thresholds
  *below* the PFC threshold); CNP (DSCP 48) to a strict-priority, never-dropped queue. NIC half is
  in `node-foundation/roce-qos.sh`; switch half is the fabric team's.
- **GPUDirect RDMA**: confirm `nvidia-smi topo -m` shows **PIX** per GPU↔NIC pair; ACS **off** on
  the GPU↔NIC PCIe path *while* IOMMU stays **on** for SR-IOV (reconcile via NIC **ATS** or
  path-specific ACS disable — on XE9680 you may need a boot-time `setpci` to clear OS-visible ACS);
  PCIe relaxed ordering on; `nvidia-peermem`/DMA-BUF loaded.

## 11. Deliberate non-goals / FAQ

**Q: Add a broad `/16` (or default) catch-all so a GPU can reach GPUs on *other* rails?**
No. The full-node pod already holds **all 8 per-rail /24 routes** (one per NAD), so every rail's
subnet is already reachable — each via its own correct NIC. And cross-rail GPU traffic doesn't ride
an IP route at all: NCCL with `NCCL_CROSS_NIC=0` moves it over **NVLink + PXN** (GPU0→GPU3 *inside*
the node via NVLink, then the inter-node hop stays same-rail). A `/16` via every rail's gw would put
**8 equal routes** for everything-not-in-a-/24 into the one pod table → **8-way ECMP**, the exact
failure §6 removes, for **zero benefit** (real endpoints are all inside the /24s). If a GPU genuinely
can't reach a peer, PXN isn't engaging — fix that (`NCCL_DEBUG=INFO`, `nvidia-smi topo -m`), don't
add a /16.

**Keep rail-to-rail BGP-routable on the fabric.** Do *not* "enforce" rail isolation by filtering
rail-to-rail on the leaves. Isolation is achieved by the **per-rail routes inside the pod** (§6), not
by breaking fabric reachability — PXN's same-rail hops and any control traffic still need the fabric
to forward normally. Blocking it on the switch just creates blackholes.

**Per-VF source/policy routing is a deliberate non-goal.** For the genuine cross-NIC corner case we
rely on PXN, *not* fragile per-VF `ip rule` source-based routing inside the pod. If you ever think you
need it, treat it as a signal that PXN/topology detection is broken, not as the fix.

## 12. Validation (Gate 3)

1. In a pod, `ip route` shows **exactly one** route per rail (no duplicate dst via multiple NICs).
2. `show_gids` / `ibv_devinfo -v` inside the pod: index 3 = RoCEv2 IPv4.
3. `ib_write_bw` / `ib_send_bw` pass per rail; DSCP/PFC counters increment on the switch under load.
4. `NCCL_DEBUG=INFO` shows **no cross-rail** communication; `all_reduce_perf` / `alltoall` busbw at
   expected line rate.
