# GLM-5.1 on OpenShift 4.20 — Helm charts

These charts implement [glm51-openshift-deployment.md](../glm51-openshift-deployment.md), split **one chart per subject**. Each chart is self-contained: where a subject needs an OLM operator, that operator's `Subscription`/`OperatorGroup` ships inside the same chart as the CRs it manages.

The document is an **ordered build sequence with validation gates** — *do not proceed past a failed gate*. The charts preserve that order. Install them in the sequence below and run each phase's gate (see the source doc) before moving on.

## Phase → chart map

| Phase | Subject | Chart | Key objects |
|-------|---------|-------|-------------|
| 0 | Model staging | [`model-staging`](model-staging) | DaemonSet that pre-stages FP8 + NVFP4 weights to local NVMe |
| 1 | Kernel tuning / node foundation | [`node-foundation`](node-foundation) | MachineConfigPool, PerformanceProfile, Tuned, CRI-O memlock MC, RoCE QoS systemd MC |
| 2 | GPU | [`gpu-operator`](gpu-operator) | NFD + GPU Operator subscriptions, NodeFeatureDiscovery, ClusterPolicy |
| 3 | RoCE rails (networking) | [`sriov-rails`](sriov-rails) | SR-IOV operator, 8× SriovNetworkNodePolicy, 8× SriovNetwork |
| 4 | Storage | [`lvms-storage`](lvms-storage) | LVMS operator, LVMCluster (kvcache + models device classes) |
| — | Certificates (cross-cutting prereq) | [`cert-manager`](cert-manager) | cert-manager operator subscription |
| 5 | Scheduling | [`kai-scheduler`](kai-scheduler) | KAI upstream (dependency), Queue hierarchy, PriorityClasses |
| 6 | Serving | [`glm51-dynamo`](glm51-dynamo) | Dynamo platform (dependency), DynamoGraphDeployment interactive + batch lanes |
| 7 | Front door / tenancy | [`gateway-tenancy`](gateway-tenancy) | OSSM3 + Kuadrant subscriptions, Gateway, HTTPRoutes, AuthPolicy, RateLimitPolicy |
| 8 | Observability | [`observability`](observability) | ServiceMonitors, PrometheusRule alerts, dashboards |

## Install order

`cert-manager` must exist before `glm51-dynamo` (Dynamo operator webhooks). `gpu-operator` needs NFD first (same chart, ordered). Everything else follows the phase numbering. See [`install.sh`](install.sh) for the exact sequence — it is a thin wrapper around `helm upgrade --install` with the right ordering and gate reminders.

```bash
./install.sh            # prints the ordered plan and the gate to run after each step
./install.sh node-foundation   # install a single chart
```

## The two upstream components (KAI, Dynamo)

`kai-scheduler` and `glm51-dynamo` only contain **our configuration** (queues, priority classes, the DynamoGraphDeployment). The large upstream engines are referenced as Helm **dependencies** and are **off by default** (`upstream.install: false`) because this is a disconnected environment:

- Mirror the upstream chart to your registry and set the OCI/repo URL + `upstream.install: true` in the chart's `values.yaml`, **or**
- `git clone` / `helm pull` the upstream chart into `charts/<chart>/charts/` and run `helm dependency build`.

Both upstream charts (and all operator images) must be mirrored per Phase 0. Every image/chart reference in these values uses a `<your-registry>` / `<your-mirror>` placeholder — pin them to your mirror and record the digests.

## Cross-layer invariants (§10 of the source doc)

Several values are repeated across charts and **must stay identical**. They are surfaced at the top of each chart's `values.yaml` with a `# §10` marker. Change them in one place and grep the others:

- **RoCE QoS: DSCP 26 / traffic-class 106 / GID index 3** — `node-foundation` (host), `sriov-rails` (VF), `glm51-dynamo` (NCCL/UCX env).
- **MTU 9000** — `node-foundation`, `sriov-rails`, `glm51-dynamo` NADs.
- **Node role label `gpu-hpc` + SKU label `gpu.hpc/sku`** — `node-foundation`, `gpu-operator`, `sriov-rails`, `lvms-storage`, `glm51-dynamo`.
- **Reserved CPUs `0-7,56-63`** — `node-foundation` only (consumed implicitly by pod integer CPU requests in `glm51-dynamo`).
- **KVBM ordering GPU-KV ≤ CPU_CACHE ≤ DISK_CACHE** — `glm51-dynamo` (envs + pod memory) and `lvms-storage` (PVC size).
- **One quota brain (KAI) / one router (Dynamo KV router)** — do not add a second scheduler or an endpoint-picker in front of the Dynamo frontend.

## What is *not* a chart

The BIOS checklist (Phase 1.5: ACS disabled, Max Read Request 4096, NPS=1, SNC off) and the Phase 0 mirroring steps are out-of-band host/registry actions, not Kubernetes objects. They remain in the source document.
