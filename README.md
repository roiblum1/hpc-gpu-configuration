# MiniMax M2.7 on OpenShift 4.20 — Helm charts (env/h100-4x-ib)

> **Environment branch `env/h100-4x-ib` — 4× DGX H100, InfiniBand, MiniMax M2.7 + MTP.**
> The 8-node design halved: one Dynamo DGD with 2 wide-EP worker gangs of 2 nodes each (TP8 on
> NVLink, DP2 + EP16 via DeepEP over IB). Speculative decoding = **MTP** (native heads —
> DFlash is the 8-node environment's method). SR-IOV rails are user-provided (the
> `sriov-rails` chart is not used). Full delta: [ENVIRONMENT.md](ENVIRONMENT.md).

This branch serves **MiniMax M2.7** (230B MoE / 10B active) on **disconnected, bare-metal OpenShift 4.20** (K8s 1.33), on 4× DGX H100 nodes (8 GPUs + 8 InfiniBand rail NICs each). It holds:

1. [glm51-openshift-deployment.md](glm51-openshift-deployment.md) — the **architecture document** for the phase/gate build discipline and cross-layer invariants (written for the GLM/RoCE mainline; this branch's deltas live in [ENVIRONMENT.md](ENVIRONMENT.md)).
2. [minimax-m27-dflash-design.md](minimax-m27-dflash-design.md) — this branch's **serving design record**: topology, memory math, survivability, DFlash (original LWS manifest kept in [reference/](reference/)).
3. [charts/](charts/) — the **Helm chart set**, one chart per phase/subject.

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
| 0 | Model staging | [`model-staging`](charts/model-staging) | DaemonSet that pre-stages the MiniMax M2.7 weights to local NVMe (no DFlash draft — MTP env) |
| 1 | Kernel tuning / node foundation | [`node-foundation`](charts/node-foundation) | MachineConfigPool, PerformanceProfile, Tuned, CRI-O memlock MC (RoCE QoS MC **disabled** — IB fabric) |
| 2 | GPU | [`gpu-operator`](charts/gpu-operator) | NFD + GPU Operator subscriptions, NodeFeatureDiscovery, ClusterPolicy |
| 3 | IB rails (networking) | [`sriov-rails`](charts/sriov-rails) | **Not used on this branch** — IB rail NADs come from the user's own templated config (Gate 3 still applies to them) |
| 4 | Storage | [`lvms-storage`](charts/lvms-storage) | LVMS operator, LVMCluster (kvcache + models device classes) |
| — | Certificates (cross-cutting prereq) | [`cert-manager`](charts/cert-manager) | cert-manager operator subscription |
| 5 | Scheduling | [`kai-scheduler`](charts/kai-scheduler) | KAI upstream (dependency), Queue hierarchy, PriorityClasses |
| 6 | Serving | [`minimax-dynamo`](charts/minimax-dynamo) | Dynamo platform (dependency), one DGD: KV-router Frontend + 2 wide-EP gangs, worker PDB |
| 7 | Front door / tenancy | [`gateway-tenancy`](charts/gateway-tenancy) | OSSM3 + Kuadrant subscriptions, Gateway, HTTPRoutes, AuthPolicy, RateLimitPolicy |
| 8 | Observability | [`observability`](charts/observability) | ServiceMonitors, PrometheusRule alerts, dashboards |

## Install order

`cert-manager` must exist before `minimax-dynamo` (Dynamo operator webhooks). `gpu-operator` needs NFD first (same chart, ordered). Everything else follows the phase numbering. [`charts/install.sh`](charts/install.sh) is a thin wrapper around `helm upgrade --install` with the right ordering and gate reminders.

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

`kai-scheduler` and `minimax-dynamo` ship **only our configuration** (queues, priority classes, the DynamoGraphDeployment) so they render and install **standalone** — no network or vendoring needed. The large upstream engines (the KAI scheduler itself; the Dynamo platform = operator + etcd + NATS) are installed **separately**, before our config:

- `git clone` / `helm pull` the upstream chart, mirror its images to your registry, and `helm install` it directly (pin etcd/NATS to infra nodes, enable KAI bin-packing/topology placement), **or**
- vendor it as a subchart: add a `dependencies:` stanza to the chart's `Chart.yaml` pointing at your mirror, drop the chart into `charts/<chart>/charts/`, and run `helm dependency build`.

The `upstream:` block in each `values.yaml` documents this and carries pass-through values for the vendored case. All operator images and both upstream charts must be mirrored per Phase 0. Every image/chart reference uses a `<your-registry>` / `<your-mirror>` placeholder — pin them and record the digests.

## Cross-layer invariants (§10 of the source doc)

Several values are repeated across charts and **must stay identical**. They are surfaced at the top of each chart's `values.yaml` with a `# §10` marker. Change them in one place and grep the others (`grep -rn "§10" charts/*/values.yaml`):

- **RoCE QoS triple (DSCP/TC/GID) — not applicable on this branch**: the fabric is InfiniBand; `roceQos` is disabled in `node-foundation` and the NCCL/UCX QoS env is deliberately absent from `minimax-dynamo`.
- **Node role label `gpu-hpc` + SKU label `gpu.hpc/sku: h100`** — `node-foundation`, `gpu-operator`, `lvms-storage`, `minimax-dynamo`, and the user-provided rail config.
- **Reserved CPUs `0-7,56-63`** — `node-foundation` only (consumed implicitly by `minimax-dynamo`'s integer `cpu: "96"` = 112 logical − 16 reserved).
- **Gang size 16 (2 nodes × 8 GPUs)** — `minimax-dynamo` `multinode.nodeCount` ↔ `kai-scheduler` quotas in multiples of 16.
- **Model dir names** — `model-staging.models[]` ↔ `minimax-dynamo.modelPaths` (`/models/minimax-m2.7`, `/models/minimax-m2.7-dflash`).
- **One quota brain (KAI) / one router (Dynamo KV router)** — do not add a second scheduler or an endpoint-picker in front of the Dynamo frontend.
- **Low-latency pod contract** — `minimax-dynamo` workers set `runtimeClassName: performance-gpu-hpc` (NTO generates it from `node-foundation`'s PerformanceProfile name) + `irq-load-balancing.crio.io`/`cpu-quota.crio.io` disable annotations. Rename the profile and the runtime class name must follow.

## What is *not* a chart

The BIOS checklist (Phase 1.5: ACS disabled, Max Read Request 4096, NPS=1, SNC off — see [charts/node-foundation/BIOS.md](charts/node-foundation/BIOS.md)) and the Phase 0 mirroring steps are out-of-band host/registry actions, not Kubernetes objects. They remain in the source document.
