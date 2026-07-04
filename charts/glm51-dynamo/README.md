# glm51-dynamo — Phase 6 (env/h200-2x-roce: aggregated)

The GLM-5.1 serving deployment for the **2× HGX H200** environment: two `DynamoGraphDeployment`s (an interactive lane and an optional batch lane) running **aggregated** single-node TP8/FP8 replicas behind the KV-aware router.

## Why aggregated here (the branch's structural change)

Main disaggregates (H200 prefill ↔ Blackwell decode); this environment has **no Blackwell nodes**, so each H200 node is one *complete* engine instead. GLM-5.1 FP8 (~754 GB) fits one node's 1128 GB HBM with ~250–300 GB left as KV. Two independent replicas mean **losing a node keeps 50% capacity serving** — a 1-prefill + 1-decode split would instead stop entirely on either node's loss. It's still **config only**: the Dynamo platform (operator + etcd + NATS) is upstream.

## What it deploys

- **Interactive DGD** — Frontend (KV router, on infra nodes) + `GLM51Worker` (2 replicas × 1 node, TP8, FP8, chunked prefill, 1 MTP head).
- **Batch DGD** (optional) — a smaller clone: same model + weights LV, queue `serving-batch`, preemptible, MTP off.
- The serving namespace.

The **Dynamo platform is upstream** and off by default (`upstream.install: false`) — pin etcd/NATS to **infra nodes, never GPU nodes**.

## Prerequisites & position

Last of the compute phases — needs node-foundation (RuntimeClass), gpu-operator, **user-provided rails** (the `sriov-rails` chart is not used on this branch), lvms-storage, cert-manager (Dynamo webhooks), and kai-scheduler (queues). The front door is Phase 7.

## How to use

```bash
../install.sh glm51-dynamo
helm template glm51-dynamo       # inspect both DGDs (interactive + batch)
```

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `frontend.routerMode` | `kv` | **THE** inference router (KV/prefix-aware). Nothing may endpoint-pick in front of it. §10 |
| `frontend.replicas` | `2` | CPU pods on **infra** nodes (never GPU-node reserved cores) |
| `worker.replicas` / `nodeCount` | `2` / `1` | One full node per replica — the whole environment; single-node gangs |
| `worker.tensorParallel` | `8` | TP8 stays intra-node on NVLink — the fabric carries no TP/EP |
| `worker.speculativeTokens` | `1` | One MTP head — **interactive only** (batch lane MTP off) |
| `worker.kvbm.enabled` | `false` | KVBM disables CUDA graphs, and here the decode hot loop shares the engine — enable only if session park/resume outweighs decode ITL. Tier ordering + PVC sizing rules (§10) apply when on |
| `rails` | `rail0..rail7` | NAD names from the **user-provided** rail config. Carry no serving traffic in this shape (kept for fleet parity); set `[]` to detach |
| `runtimeClassName` | `performance-gpu-hpc` | Hard reference to the NTO-generated class — rename the PerformanceProfile and this must follow. §10 |
| `fabric.trafficClass` / `gidIndex` | `106` / `3` | Must equal host QoS if rail traffic ever exists. §10 |
| `sku.worker` | `h200` | Single SKU — both nodes are H200 |
| `batchLane.enabled` | `true` | The preemptible second DGD (1 worker replica) |

## GPU↔NIC alignment (the common question)

Unchanged from main in mechanism: the pod takes the **whole node** (8 GPUs + 8 VFs) and NCCL/UCX walk the PCIe topology for exact pairing — but note that in the aggregated shape no serving traffic crosses the rails at all (TP8 is NVLink-internal, there is no NIXL path). See [CLAUDE.md](CLAUDE.md).

## Gate 6 (do not proceed past failure)

`genai-perf` sweep meets TTFT/ITL per lane · KV router spreads sessions with prefix locality across **both** replicas · node kill test: surviving replica keeps serving, router drains the dead one · `numastat -p <engine pid>`: engine memory split across **both** sockets.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance. [../../ENVIRONMENT.md](../../ENVIRONMENT.md) — the full branch delta.
