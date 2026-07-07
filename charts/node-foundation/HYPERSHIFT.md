# HYPERSHIFT.md — delivering the node-foundation layer via `NodePool`

How to implement **this chart's host config** on **HyperShift / Hosted Control Planes (HCP)**
instead of standalone OpenShift. Same physical outcome on the node — different delivery
mechanism. Companion to [CLAUDE.md](CLAUDE.md) (why each value) and [BIOS.md](BIOS.md)
(the out-of-band half, unchanged either way).

> YAML below is illustrative, per repo convention. Exact ConfigMap key names and
> PerformanceProfile support level follow **your pinned HyperShift/OCP version's docs** —
> verify against them before applying.

## What changes under HCP

Hosted clusters have **no Machine Config Operator and no MachineConfigPool**. Node
configuration is declared on the **management cluster**, as ConfigMaps in the hosted
cluster's namespace (e.g. `clusters`), referenced from the `NodePool`:

- `NodePool.spec.config` — ConfigMaps wrapping **MachineConfig** (also KubeletConfig /
  ContainerRuntimeConfig) objects, data key **`config`**.
- `NodePool.spec.tuningConfig` — ConfigMaps wrapping **Tuned** or **PerformanceProfile**
  objects, data key **`tuning`**.

**The NodePool *is* the pool.** Everything this chart scopes with the MCP + role-label
selector is scoped instead by *which NodePool references the ConfigMap*.

## Mapping: chart object → NodePool delivery

| This chart (standalone) | Under HyperShift |
|---|---|
| `MachineConfigPool gpu-hpc` | A dedicated `NodePool` per hardware SKU (Agent platform on bare metal). No CR to translate — the NodePool replaces it. |
| `PerformanceProfile gpu-hpc` | Same manifest, wrapped in a ConfigMap (key `tuning`), referenced in `spec.tuningConfig`. **One PerformanceProfile ConfigMap per NodePool, max.** Its `nodeSelector`/`machineConfigPoolSelector` are ignored — scoping is the NodePool reference. |
| `Tuned gpu-hpc-extras` | Second `spec.tuningConfig` ConfigMap (multiple Tuneds are allowed). The `include=openshift-node-performance-gpu-hpc` chain works the same — the hosted NTO still generates the parent profile from the PerformanceProfile. |
| CRI-O memlock MachineConfig | Butane-render the same `.bu` source ([butanes-mc/](butanes-mc/)) to a MachineConfig, wrap in a ConfigMap (key `config`), reference in `spec.config`. |
| RoCE QoS MachineConfig | Same as memlock. (On IB environments this is disabled anyway — see the env branch's values.) |
| KubeletConfig | **Still not needed.** The hosted NTO generates it from the PerformanceProfile for that NodePool — same answer as standalone: hand-writing one would duplicate/conflict with the generated cpuManager/memoryManager/topologyManager settings. |

## Illustrative manifests (management cluster, hosted cluster's namespace)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: perfprofile-gpu-hpc
  namespace: clusters
data:
  tuning: |
    apiVersion: performance.openshift.io/v2
    kind: PerformanceProfile
    metadata:
      name: gpu-hpc
    spec:
      # identical spec to templates/performanceprofile.yaml — cpu.reserved/isolated,
      # numa best-effort, 16x1G hugepages, additionalKernelArgs,
      # globallyDisableIrqLoadBalancing: false. Selectors omitted (ignored under HCP).
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tuned-gpu-hpc-extras
  namespace: clusters
data:
  tuning: |
    # identical to templates/tuned-extras.yaml (the child profile with the sysctls)
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mc-crio-memlock
  namespace: clusters
data:
  config: |
    # butane-rendered MachineConfig from butanes-mc/machineconfig-crio-memlock.bu
---
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: gpu-hpc-h200            # one NodePool per SKU, like one MCP/release per SKU
  namespace: clusters
spec:
  clusterName: <hosted-cluster>
  replicas: <n>
  platform:
    type: Agent                 # bare metal
  management:
    upgradeType: InPlace        # Replace would re-provision bare-metal hosts per change
  config:
    - name: mc-crio-memlock
    # - name: mc-roce-qos       # RoCE environments only
  tuningConfig:
    - name: perfprofile-gpu-hpc
    - name: tuned-gpu-hpc-extras
  nodeLabels:
    gpu.hpc/pool: gpu-hpc       # see "role label" gotcha below
```

## Gotchas

- **The `performance-gpu-hpc` RuntimeClass is still created — in the hosted cluster.**
  The §10 name (derived from the PerformanceProfile name) is unchanged, so the serving
  chart's `runtimeClassName` reference and the whole low-latency pod contract keep working.
- **The §10 role label needs a decision.** `node-role.kubernetes.io/*` keys may not
  propagate via `spec.nodeLabels` (NodeRestriction guards kubelet self-labeling). Either
  switch the invariant to a non-role key (e.g. `gpu.hpc/pool`, as above) — and update
  **every** chart that keys on `node-role.kubernetes.io/gpu-hpc` (grep the §10 markers) —
  or apply the role label in a post-join step. Decide once; don't mix.
- **The Tuned `recommend.match` label** must be one that actually lands on hosted nodes
  (same decision as above — this chart's template matches the role label).
- **Rollout semantics differ.** No MCP node-by-node drain/reboot; NodePool config changes
  roll per its `management` policy. With `InPlace` on bare metal, still batch changes —
  the "don't iterate one sysctl at a time" rule holds.
- **Disconnected:** the HyperShift operator + hosted control plane images are one more
  thing to mirror in Phase 0.

## Gate 1 is unchanged

The node-side artifacts (cmdline, hugepages, generated kubelet config, sysctls, CRI-O
drop-ins) are identical, so [scripts/verify-nodes.sh](scripts/verify-nodes.sh) works as-is —
run it with `oc` logged in to the **hosted** cluster (that's where the nodes are), SSH
reachability permitting. The fabric-side and in-pod gate items also carry over verbatim.

## What does not change

[BIOS.md](BIOS.md) (out-of-band host firmware) · `sriov-rails` (user-provided, out of
band on env branches) · the pod-side low-latency contract in the serving chart · the §10
values themselves — only their delivery vehicle changes.
