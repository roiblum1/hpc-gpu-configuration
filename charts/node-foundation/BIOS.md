# BIOS + NIC firmware checklist — `gpu-hpc` nodes (Phase 1.5)

> **ENV BRANCH env/h100-8x-ib (DGX H100, InfiniBand):** the server-BIOS table applies as-is
> (DGX BIOS menus differ from Dell iDRAC — verify by *effect*, as stated below). In the NIC
> firmware section, the **RoCE/DCBX rows do not apply** to IB-mode ConnectX-7s (`LINK_TYPE_P1=IB`;
> there is no DSCP trust or DCBX to disable on IB) — the SR-IOV/VF and PCIe rows still do.

Out-of-band host configuration that **no chart can deliver** — it lives here (next to the chart
that owns the host layer) so it travels with `node-foundation`, but it is applied via
iDRAC/racadm/BIOS setup and `mlxconfig`, never as a Kubernetes object. Verify each item with the
listed **evidence** on a rebooted node, per chassis SKU — menu names shift between BIOS versions,
the setting's *effect* is what you verify. Record a golden per-SKU config and re-verify after
**every firmware update** (firmware updates silently reset settings more often than vendors admit).

## Server BIOS (Dell XE9680-class)

| Setting | Value | Why | Evidence |
|---|---|---|---|
| ACS (Access Control Services) | **Disabled** on PCIe switches between GPU↔NIC pairs | ACS forces P2P DMA through the root complex — GPUDirect RDMA bandwidth halves | `nvidia-smi topo -m` shows **PIX/PXB** (not NODE/SYS) per GPU↔rail-NIC pair |
| VT-d / AMD-Vi (IOMMU) | **Enabled** | SR-IOV requires it; `iommu=pt` (kernel args) keeps DMA translation out of the hot path | `dmesg \| grep -i iommu` shows passthrough |
| SR-IOV global enable | **Enabled** | VF creation fails without it — surfaces 3 layers up as "device plugin reports 0 rails" | `sriovnetworknodestates` shows VFs |
| Sub-NUMA Clustering (SNC, Intel) | **Off** | SNC multiplies NUMA nodes and breaks the "1 socket = 1 NUMA = 4 GPUs + 4 rails" model everything here assumes | `lscpu \| grep NUMA` → exactly 2 nodes |
| NPS (EPYC chassis) | **NPS=1** unless measured otherwise | Same reason as SNC — one NUMA per socket | `lscpu` → 2 NUMA nodes |
| PCIe Max Read Request Size | **4096** | Larger DMA reads for GDR/GDS streaming transfers | `lspci -vvv -s <nic> \| grep MaxReadReq` |
| PCIe ASPM | **Disabled** | Link power-state exit latency spikes RDMA/NVMe tails (also enforced by `pcie_aspm=off` kernel arg — belt and suspenders) | `lspci -vvv \| grep ASPM` → Disabled |
| System Profile / power | **Performance** (no OS-controlled power saving) | Deterministic clocks; pairs with the C-state kernel args | `turbostat` shows stable freq; `tuned-adm active` |
| C-states | **Limited per latency policy** (C1 max is the usual answer) | Deep C-state wake latency lands in ITL tails; kernel args in `values.yaml` enforce the same policy from the OS side | `cpupower idle-info` |
| SMT / Hyper-Threading | **Decide per SKU and record it** | The chart's cpusets assume 112 logical CPUs = SMT off. If SMT stays on, `reserved`/`isolated` must contain complete sibling pairs or `full-pcpus-only` rejects GPU pods | `lscpu -e` sibling map matches cpusets |

Optional alternative to BIOS MRRS: kernel arg `pci=pcie_bus_perf` sets MPS/MRRS along each PCIe
path. We prefer pinning in BIOS/`mlxconfig` — one owner per setting; don't enable both and let
them fight.

## NIC firmware (`mlxconfig`, per rail PF — persists across reboots, applies after cold reset)

```bash
mlxconfig -d <pf-pci> set SRIOV_EN=1 NUM_OF_VFS=1        # match sriov-rails numVfs
mlxconfig -d <pf-pci> set ADVANCED_PCI_SETTINGS=1
mlxconfig -d <pf-pci> set PCI_WR_ORDERING=1              # relaxed ordering — pairs with NCCL_IB_PCI_RELAXED_ORDERING=1 (§3.4)
mlxconfig -d <pf-pci> set LLDP_NB_DCBX_P1=0 LLDP_NB_DCBX_P2=0   # DCBX OFF — see below
mlxconfig -d <pf-pci> set KEEP_ETH_LINK_UP_P1=1          # link stays up through host reboots — steadier switch counters
```

**Why DCBX off (the LLDP question):** LLDP carries two different things. *Discovery* LLDP
(neighbor info for the rail-map doc) is harmless — run it switch-side. *DCBX over LLDP* lets the
switch **push PFC/ETS/trust config onto the NIC**, overriding everything `roce-qos.sh` pins. This
design's whole QoS philosophy is *pin explicitly on both ends and verify with counters* (§1.4);
a NIC in DCBX-willing mode is a NIC whose QoS config changes when the fabric team changes a
template. Disable DCBX in firmware so the host config has exactly one owner: the MachineConfig.

## What lives where (don't blur these)

- **This file:** settings applied out-of-band (BIOS, iDRAC, `mlxconfig` firmware).
- **`values.yaml` kernel args:** the OS-side enforcement of the same latency policy.
- **`roce-qos.sh` (MachineConfig):** per-boot runtime NIC QoS — trust=dscp, PFC vector, DSCP/TC,
  CNP marking, DCQCN NP/RP enables, global pause off, MTU. ECN "activation" host-side *is* the
  DCQCN NP/RP enables plus the ECT bits in traffic class 106; the switch does the WRED/ECN
  *marking* (out of band, mirrors §1.4 conventions).

**Gate 1 evidence for this file:** `nvidia-smi topo -m` PIX per pair · `lscpu` 2 NUMA nodes ·
`lspci` MaxReadReq 4096 + ASPM Disabled · `mlxconfig -d <pf> query` shows the values above ·
`mlnx_qos -i <port>` shows trust=dscp + PFC prio 3 (proving DCBX didn't override).
