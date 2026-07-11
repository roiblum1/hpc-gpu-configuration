# Graph Report - .  (2026-07-11)

## Corpus Check
- Corpus is ~44,025 words - fits in a single context window. You may not need a graph.

## Summary
- 244 nodes · 426 edges · 21 communities (10 shown, 11 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 20 edges (avg confidence: 0.85)
- Token cost: 0 input · 418,417 output

## Community Hubs (Navigation)
- GLM-5.1 Core Entities & Cross-Layer Invariants
- Per-Chart CLAUDE.md Design Rationale
- Node Foundation Tuning Parameters
- SR-IOV Rail Routing & Research Citations
- GPU Operator, LVMS & Observability Config
- Model Staging Chart
- BIOS & NIC Firmware Checklist
- Observability Alerts
- Gateway Tenancy Chart
- verify-nodes.sh Script
- install.sh Script
- KAI Scheduler Queues & Priorities
- cert-manager Subscription & Values
- stage-weights.sh Script
- roce-qos.sh Script
- Observability Dashboards
- SR-IOV Operator Install
- Decode Pool Concept
- Gate 6 Validation
- Gate 2 Validation
- Gate 4 Validation

## God Nodes (most connected - your core abstractions)
1. `GLM-5.1 OpenShift Deployment Architecture Doc` - 35 edges
2. `Root CLAUDE.md` - 20 edges
3. `PARAMETERS.md — node-foundation parameter deep dive` - 19 edges
4. `BIOS + NIC firmware checklist (BIOS.md)` - 18 edges
5. `POC Performance Review` - 16 edges
6. `Node Performance and Tuning Configurations.md (beginner tables)` - 14 edges
7. `node-foundation values.yaml` - 14 edges
8. `HYPERSHIFT.md — NodePool delivery` - 12 edges
9. `node-foundation README.md` - 12 edges
10. `node-foundation CLAUDE.md (Phase 1)` - 11 edges

## Surprising Connections (you probably didn't know these)
- `Root CLAUDE.md` --references--> `Decision: hugepages kept small (16x1G) for KVBM pinned-memory tier`  [EXTRACTED]
  CLAUDE.md → glm51-openshift-deployment.md
- `Root CLAUDE.md` --references--> `node-foundation chart (Phase 1)`  [EXTRACTED]
  CLAUDE.md → README.md
- `Root CLAUDE.md` --references--> `Per-SKU pool mapping: prefill=H200/FP8/TP8, decode=B200/B300/NVFP4/wide-EP`  [EXTRACTED]
  CLAUDE.md → glm51-openshift-deployment.md
- `Root CLAUDE.md` --references--> `Rail map: GPU n <-> NIC n <-> socket`  [EXTRACTED]
  CLAUDE.md → glm51-openshift-deployment.md
- `Root CLAUDE.md` --references--> `Reserved CPUs 0-7,56-63 on both sockets`  [EXTRACTED]
  CLAUDE.md → glm51-openshift-deployment.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **RoCE QoS agreement across NCCL, UCX, host, and switch fabric** — roce_qos_triple, nccl, ucx, cisco_dscp24_convention [INFERRED 0.85]
- **Two single-brain design rules (quota + routing)** — one_gpu_quota_brain, kai_scheduler, one_inference_router, dynamo [INFERRED 0.85]
- **Gateway tenancy request flow: Gateway -> HTTPRoute -> AuthPolicy -> RateLimitPolicy** — charts_gateway_tenancy_templates_gateway, charts_gateway_tenancy_templates_httproutes, charts_gateway_tenancy_templates_authpolicy, charts_gateway_tenancy_templates_ratelimitpolicy [INFERRED 0.80]
- **KVBM Disk-Tier Data Path (GDS to xfs to KVBM ordering)** — charts_glm51_dynamo_claude_kvbm_tiering, charts_lvms_storage_claude_kvcache_device_class, charts_gpu_operator_claude_gds [INFERRED 0.85]
- **GPU-NIC Rail Alignment Stack (driver + pod contract + full-node placement)** — charts_glm51_dynamo_claude_gpu_nic_alignment, charts_glm51_dynamo_claude_low_latency_pod_contract, charts_gpu_operator_claude_open_kernel_modules [INFERRED 0.80]
- **GPU Operator Install Ordering (NFD then Subscription then ClusterPolicy)** — charts_gpu_operator_templates_nfd, charts_gpu_operator_templates_gpu_operator_subscription, charts_gpu_operator_templates_clusterpolicy [EXTRACTED 1.00]
- **gpu-hpc role label §10 invariant shared across charts** — charts_model_staging_claude_rolelabel_gpu_hpc, charts_node_foundation_parameters_pool_rolelabel, charts_node_foundation_templates_machineconfigpool_resource [INFERRED 0.85]
- **Three-layer C-state cap: BIOS policy -> boot kernel args -> tuned runtime** — charts_node_foundation_bios_cstates_limited, charts_node_foundation_parameters_kernel_args_additional, charts_node_foundation_parameters_tuned_sysctls [EXTRACTED 1.00]
- **RoCE QoS single-owner design: MachineConfig pins state, DCBX kept off so firmware can't override** — charts_node_foundation_claude_roce_qos_mc, charts_node_foundation_bios_dcbx_off, charts_node_foundation_bios_mlxconfig_nic_firmware [EXTRACTED 1.00]
- **Gate 3 validation bundle for RoCE rails** — charts_sriov_rails_gate3, charts_sriov_rails_roce_qos_triple, charts_sriov_rails_rdma_exclusive_mode, charts_sriov_rails_rail_map [INFERRED 0.80]
- **§10 cross-layer invariants formed by sriov-rails chart** — charts_sriov_rails_invariants, charts_sriov_rails_roce_qos_triple, charts_sriov_rails_rail_map, charts_sriov_rails_per_rail_blocks_rationale [INFERRED 0.85]
- **Observability signal set forming the planner control loop** — charts_observability_signal_set_control_loop, charts_observability_dynamofrontend_servicemonitor, charts_observability_roceexporter_servicemonitor, charts_observability_gate8_soak [INFERRED 0.75]

## Communities (21 total, 11 thin omitted)

### Community 0 - "GLM-5.1 Core Entities & Cross-Layer Invariants"
Cohesion: 0.08
Nodes (52): NVIDIA B200 GPU (decode pool, Blackwell), NVIDIA B300 GPU (decode pool, Blackwell), cert-manager operator, cert-manager Chart.yaml, cert-manager chart CLAUDE.md, cert-manager chart README.md, gateway-tenancy Chart.yaml, gateway-tenancy chart CLAUDE.md (+44 more)

### Community 1 - "Per-Chart CLAUDE.md Design Rationale"
Cohesion: 0.09
Nodes (37): cert-manager chart (external ref), gateway-tenancy chart (external ref), glm51-dynamo Chart.yaml, glm51-dynamo CLAUDE.md, Batch Lane (second DGD), DRA Migration Path (exact GPU-NIC pairing), Fabric Env (NCCL/UCX QoS helper), GPU-NIC Alignment by Construction (+29 more)

### Community 2 - "Node Foundation Tuning Parameters"
Cohesion: 0.19
Nodes (32): node-foundation Chart.yaml, CRI-O memlock MachineConfig, node-foundation CLAUDE.md (Phase 1), MachineConfigPool gpu-hpc rationale, PerformanceProfile design rationale, RoCE QoS MachineConfig (roce-qos.sh), Tuned child profile gpu-hpc-extras, NodePool spec.config / spec.tuningConfig ConfigMap mapping (+24 more)

### Community 3 - "SR-IOV Rail Routing & Research Citations"
Cohesion: 0.09
Nodes (30): Azure HPC blog — NCCL Performance Impact with PCIe Relaxed Ordering, Broadcom MI300X RoCE networking guide, 2-spine / 2-leaf rail-aligned topology, claude-deep-research.md — RoCEv2 design validation, sriov-rails chart CLAUDE.md, ECMP collapse breaking rail discipline, Gate 3 validation, GPUDirect RDMA ACS-off vs SR-IOV IOMMU-on tension (+22 more)

### Community 4 - "GPU Operator, LVMS & Observability Config"
Cohesion: 0.11
Nodes (23): gpu-operator Chart.yaml, DCGM Exporter + ServiceMonitor, gdrcopy (low-latency small-message D2H/H2D), NFD-before-GPU-Operator Ordering, usePrecompiled Driver Images (disconnected constraint), ClusterPolicy manifest, GPU Operator Subscription/OperatorGroup manifest, NFD Subscription/Instance manifest (+15 more)

### Community 5 - "Model Staging Chart"
Cohesion: 0.22
Nodes (14): model-staging Chart.yaml, Both quantizations staged on every node (FP8 + NVFP4), DaemonSet, not a Job (weight staging), model-staging CLAUDE.md (Phase 0), Gate 0 (model-staging), hostPath /var/lib/models (dedicated models LV), Idempotence + checksum verification (.staged marker, sha256sum.txt), Avoid pulling 754GB weights inside serving image (+6 more)

### Community 6 - "BIOS & NIC Firmware Checklist"
Cohesion: 0.18
Nodes (14): ACS Disabled on PCIe switches (GPU<->NIC), C-states Limited (C1 max policy), DCBX off / single QoS owner rationale, BIOS + NIC firmware checklist (BIOS.md), VT-d / AMD-Vi (IOMMU) Enabled, mlxconfig NIC firmware settings (SRIOV_EN, PCI_WR_ORDERING, LLDP, KEEP_ETH_LINK_UP), NPS=1 (EPYC), PCIe ASPM Disabled (BIOS) (+6 more)

### Community 7 - "Observability Alerts"
Cohesion: 0.22
Nodes (9): DynamoControlPlaneDown alert, InteractiveGangPending alert, KVCacheThinPoolNearFull alert, MTPAcceptanceCollapse alert, PrefixHitRateDrop alert, RoCEPFCPauseStorm alert, observability PrometheusRule template, observability ServiceMonitors template (+1 more)

### Community 8 - "Gateway Tenancy Chart"
Cohesion: 0.32
Nodes (8): gateway-tenancy AuthPolicy template, gateway-tenancy Gateway template, gateway-tenancy HTTPRoutes template, gateway-tenancy operators (OSSM3/Kuadrant) template, gateway-tenancy RateLimitPolicy template, gateway-tenancy values.yaml, Gateway API (Istio/OSSM3-based, OCP 4.20 GA), Kuadrant / RH Connectivity Link

### Community 11 - "KAI Scheduler Queues & Priorities"
Cohesion: 0.67
Nodes (3): kai-scheduler PriorityClasses template, kai-scheduler Queues template, kai-scheduler values.yaml

## Ambiguous Edges - Review These
- `ClusterPolicy manifest` → `NFD Subscription/Instance manifest`  [AMBIGUOUS]
  charts/gpu-operator/templates/clusterpolicy.yaml · relation: references
- `sriov-rails Chart.yaml` → `sriov-rails operator.yaml (Subscription/OperatorGroup)`  [AMBIGUOUS]
  charts/sriov-rails/templates/operator.yaml · relation: conceptually_related_to

## Knowledge Gaps
- **57 isolated node(s):** `stage-weights.sh script`, `roce-qos.sh script`, `verify-nodes.sh script`, `cert-manager Subscription template`, `cert-manager values.yaml` (+52 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `ClusterPolicy manifest` and `NFD Subscription/Instance manifest`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **What is the exact relationship between `sriov-rails Chart.yaml` and `sriov-rails operator.yaml (Subscription/OperatorGroup)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `sriov-rails chart CLAUDE.md` connect `SR-IOV Rail Routing & Research Citations` to `Per-Chart CLAUDE.md Design Rationale`?**
  _High betweenness centrality (0.057) - this node is a cross-community bridge._
- **Why does `glm51-dynamo Chart.yaml` connect `Per-Chart CLAUDE.md Design Rationale` to `SR-IOV Rail Routing & Research Citations`?**
  _High betweenness centrality (0.045) - this node is a cross-community bridge._
- **What connects `stage-weights.sh script`, `roce-qos.sh script`, `verify-nodes.sh script` to the rest of the system?**
  _62 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `GLM-5.1 Core Entities & Cross-Layer Invariants` be split into smaller, more focused modules?**
  _Cohesion score 0.08055152394775036 - nodes in this community are weakly interconnected._
- **Should `Per-Chart CLAUDE.md Design Rationale` be split into smaller, more focused modules?**
  _Cohesion score 0.08708708708708708 - nodes in this community are weakly interconnected._