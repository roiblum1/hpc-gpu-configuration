# GLM-5.1 on OpenShift 4.20 — Helm charts

> **Environment branch `env/h200-2x-roce` — 2× HGX H200, RoCEv2, GLM-5.1 FP8 aggregated.**
> No Blackwell decode pool exists here, so main's disaggregation is replaced by **2 aggregated
> single-node TP8 replicas** behind the Dynamo KV router. SR-IOV rails are user-provided
> (the `sriov-rails` chart is not used). Full delta from `main`: [ENVIRONMENT.md](ENVIRONMENT.md).

This repo serves **GLM-5.1** (754B MoE / 40B active) disaggregated on **disconnected, bare-metal OpenShift 4.20** (K8s 1.33), on Dell XE9680-class HGX nodes (H200 / B200 / B300; 8 GPUs + 8 RoCEv2 rail NICs each). It holds two co-dependent deliverables:

1. [glm51-openshift-deployment.md](glm51-openshift-deployment.md) — the **architecture document**: prose rationale, the ordered build sequence, the validation gates, and the cross-layer invariants. **Source of truth.**
2. [charts/](charts/) — a **Helm chart set that implements the document**, one chart per phase/subject.

The document is an **ordered build sequence with validation gates** — *do not proceed past a failed gate*. The charts preserve that order. Install them in the sequence below and run each phase's gate (see the source doc) before moving on.

## Each chart is documented three ways

| File | Audience | Answers |
|------|----------|---------|
| `charts/<chart>/README.md` | operators | what it is, how to install it, what the values do, why it matters |
| `charts/<chart>/CLAUDE.md` | Claude Code / maintainers | *why* each value is what it is; the §10 invariants it carries; its gate |
| `charts/<chart>/values.yaml` | both | the knobs, each `# §10`-tagged where it participates in a cross-layer invariant |

Out-of-band host config that is **not** a chart: [charts/node-foundation/BIOS.md](charts/node-foundation/BIOS.md) (BIOS + `mlxconfig` firmware) and the rail addressing/routing rationale in [charts/sriov-rails/ROUTING.md](charts/sriov-rails/ROUTING.md).

## Phase → chart map

| Phase | Subject | Chart | Key objects |
|-------|---------|-------|-------------|
| 0 | Model staging | [`model-staging`](charts/model-staging) | DaemonSet that pre-stages the FP8 weights to local NVMe (FP8 only on this branch) |
| 1 | Kernel tuning / node foundation | [`node-foundation`](charts/node-foundation) | MachineConfigPool, PerformanceProfile, Tuned, CRI-O memlock MC, RoCE QoS systemd MC |
| 2 | GPU | [`gpu-operator`](charts/gpu-operator) | NFD + GPU Operator subscriptions, NodeFeatureDiscovery, ClusterPolicy |
| 3 | RoCE rails (networking) | [`sriov-rails`](charts/sriov-rails) | **Not used on this branch** — rails come from the user's own templated config (Gate 3 still applies to them) |
| 4 | Storage | [`lvms-storage`](charts/lvms-storage) | LVMS operator, LVMCluster (kvcache + models device classes) |
| — | Certificates (cross-cutting prereq) | [`cert-manager`](charts/cert-manager) | cert-manager operator subscription |
| 5 | Scheduling | [`kai-scheduler`](charts/kai-scheduler) | KAI upstream (dependency), Queue hierarchy, PriorityClasses |
| 6 | Serving | [`glm51-dynamo`](charts/glm51-dynamo) | Dynamo platform (dependency), DynamoGraphDeployment interactive + batch lanes |
| 7 | Front door / tenancy | [`gateway-tenancy`](charts/gateway-tenancy) | OSSM3 + Kuadrant subscriptions, Gateway, HTTPRoutes, AuthPolicy, RateLimitPolicy |
| 8 | Observability | [`observability`](charts/observability) | ServiceMonitors, PrometheusRule alerts, dashboards |

## Install order

`cert-manager` must exist before `glm51-dynamo` (Dynamo operator webhooks). `gpu-operator` needs NFD first (same chart, ordered). Everything else follows the phase numbering. [`charts/install.sh`](charts/install.sh) is a thin wrapper around `helm upgrade --install` with the right ordering and gate reminders.

```bash
charts/install.sh                 # print the ordered plan + the gate to run after each step, then install all
charts/install.sh node-foundation # install a single chart and print its gate
```

Render/inspect without installing (run from `charts/`):

```bash
helm lint <chart>                              # e.g. helm lint glm51-dynamo
helm template <chart>                          # render manifests to inspect what would apply
helm template <chart> | helm lint --strict -   # tighter check
```

## The two upstream components (KAI, Dynamo)

`kai-scheduler` and `glm51-dynamo` ship **only our configuration** (queues, priority classes, the DynamoGraphDeployments) so they render and install **standalone** — no network or vendoring needed. The large upstream engines (the KAI scheduler itself; the Dynamo platform = operator + etcd + NATS) are installed **separately**, before our config:

- `git clone` / `helm pull` the upstream chart, mirror its images to your registry, and `helm install` it directly (pin etcd/NATS to infra nodes, enable KAI bin-packing/topology placement), **or**
- vendor it as a subchart: add a `dependencies:` stanza to the chart's `Chart.yaml` pointing at your mirror, drop the chart into `charts/<chart>/charts/`, and run `helm dependency build`.

The `upstream:` block in each `values.yaml` documents this and carries pass-through values for the vendored case. All operator images and both upstream charts must be mirrored per Phase 0. Every image/chart reference uses a `<your-registry>` / `<your-mirror>` placeholder — pin them and record the digests.

## Cross-layer invariants (§10 of the source doc)

Several values are repeated across charts and **must stay identical**. They are surfaced at the top of each chart's `values.yaml` with a `# §10` marker. Change them in one place and grep the others (`grep -rn "§10" charts/*/values.yaml`):

- **RoCE QoS: DSCP 26 / traffic-class 106 / GID index 3, CNP DSCP 48 / prio 6** — `node-foundation` (host), `sriov-rails` (VF), `glm51-dynamo` (NCCL/UCX env), switch fabric (PFC/ECN + CNP queue).
- **MTU 9000** — `node-foundation`, `sriov-rails`, `glm51-dynamo` NADs.
- **Node role label `gpu-hpc` + SKU label `gpu.hpc/sku`** — `node-foundation`, `gpu-operator`, `sriov-rails`, `lvms-storage`, `glm51-dynamo`.
- **Reserved CPUs `0-7,56-63`** — `node-foundation` only (consumed implicitly by pod integer CPU requests in `glm51-dynamo`).
- **KVBM ordering GPU-KV ≤ CPU_CACHE ≤ DISK_CACHE** — `glm51-dynamo` (envs + pod memory) and `lvms-storage` (PVC size).
- **One quota brain (KAI) / one router (Dynamo KV router)** — do not add a second scheduler or an endpoint-picker in front of the Dynamo frontend.
- **Low-latency pod contract** — `glm51-dynamo` workers set `runtimeClassName: performance-gpu-hpc` (NTO generates it from `node-foundation`'s PerformanceProfile name) + `irq-load-balancing.crio.io`/`cpu-quota.crio.io` disable annotations. Rename the profile and the runtime class name must follow.

## What is *not* a chart

The BIOS checklist (Phase 1.5: ACS disabled, Max Read Request 4096, NPS=1, SNC off — see [charts/node-foundation/BIOS.md](charts/node-foundation/BIOS.md)) and the Phase 0 mirroring steps are out-of-band host/registry actions, not Kubernetes objects. They remain in the source document.
