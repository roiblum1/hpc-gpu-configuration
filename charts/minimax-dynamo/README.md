# minimax-dynamo — Phase 6 (env/h100-4x-ib)

MiniMax M2.7 + **MTP** speculative decoding on **4× DGX H100 over InfiniBand** — the 8-node design halved — served as one `DynamoGraphDeployment`: a KV-router Frontend plus **2 wide-EP worker gangs of 2 nodes each** (Grove `multinode`). This chart is the Dynamo + Grove translation of the LeaderWorkerSet design in [minimax-m27-dflash-design.md](../../minimax-m27-dflash-design.md) (original manifest kept at [reference/minimax-m27-dflash-lws.yaml](../../reference/minimax-m27-dflash-lws.yaml)). **DFlash is used only in the 8-node environment** — here it stays wired but off.

## The topology in one paragraph

M2.7 (230B total / 10B active MoE, 256 experts) fits on one 8×H100 node — multi-node is a *throughput optimization*, not a requirement. Inside each node: TP8 on NVLink. Across the 2 nodes of a gang: DP2 + `--enable-expert-parallel` ⇒ experts sharded **EP16-wide**, MoE all-to-all over IB via **DeepEP**; attention/KV stay node-local. Sharding experts 16-wide frees ~14–15 GB HBM per GPU, which becomes KV cache ⇒ more concurrent sequences at daytime peak. A node loss kills exactly **one** gang; the other serves at **50%** — at N=2 gangs this is the environment where the islands fallback (25% blast radius) is most worth benchmarking against wide-EP. Escape hatch (design §1): set `worker.replicas: 4`, `nodeCount: 1`, `dataParallel: 1` — 4 single-node islands, zero re-architecture.

## LWS → Dynamo + Grove mapping

| LWS original | This chart |
|---|---|
| `LeaderWorkerSet` `size: 2`, `replicas: 4` | `MinimaxWorker` with `multinode.nodeCount: 2`, `replicas: 4` (Grove gang) |
| `RecreateGroupOnPodRestart` | Grove/DGD atomic gang recreate — a half-alive EP group can never heal |
| Leader `Service` selecting `role: leader` | The Dynamo **Frontend (KV router)** — an upgrade, and the one-router rule holds |
| `exclusive-topology` annotation | **KAI network-topology-aware placement** (enable in [kai-scheduler](../kai-scheduler) upstream values) |
| `--headless`, `--data-parallel-address/-start-rank/-size-local`, rpc port | **Dropped** — the operator/Grove injects leader address + rank wiring |
| `--host/--port`, `--served-model-name`, `--api-server-count` | Belong to the Frontend now |
| `rollingUpdate maxUnavailable: 1` + leader PDB `minAvailable: 3` | `pdb.maxUnavailable: 1` on worker pods; roll one gang at a time stays the operational rule |
| `IPC_LOCK` capability | Covered by node-foundation's CRI-O `memlock=-1` MachineConfig |

## What it deploys

- **One DGD** — `Frontend` (KV router, infra nodes) + `MinimaxWorker` (2 gangs × 2 nodes, full-node pods: 8 GPUs + 8 IB rail VFs + integer CPUs).
- **PDB** on the worker pods (one drain at a time).
- The `llm-serving` namespace.

**No batch DGD**: `disable_by_batch_size: 32` self-manages the day/night pattern — speculation active at night (small batches), silently off at peak, when wide-EP's KV headroom carries throughput instead (design §6).

## Prerequisites & position

Needs node-foundation (RuntimeClass, `roceQos` disabled on this branch), gpu-operator (incl. GDRCopy/peermem for DeepEP's IBGDA path), **user-provided IB rail NADs** (the `sriov-rails` chart is not used), lvms-storage (models LV), cert-manager, kai-scheduler. Weights staged by model-staging: the base model only (MTP needs no draft artifact).

## How to use

```bash
../install.sh minimax-dynamo
helm template minimax-dynamo                                 # inspect the DGD + PDB
helm template minimax-dynamo --set speculative.method=dflash # DFlash rendering (requires staging the draft)
```

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `worker.replicas` / `nodeCount` | `2` / `2` | 2 gangs × 2 nodes = all 4 DGX H100; each gang gang-scheduled by KAI |
| `worker.tensorParallel` / `dataParallel` | `8` / `2` | TP8 on NVLink per node; DP2 + EP ⇒ EP16 across the gang over IB |
| `speculative.method` | `mtp` | **MTP by default** (native heads, zero artifacts). DFlash stays wired — flip the value + stage the z-lab draft (8-node env's method) |
| `speculative.mtpNumSpeculativeTokens` | `3` | MTP K; `numSpeculativeTokens: 8` applies only when `method: dflash` |
| `speculative.disableByBatchSize` | `32` | The diurnal self-management knob — verify the key name on your vLLM build |
| `fabric.ncclIbHca` | `mlx5_0..7` | **Compute rails only** — a storage HCA on this list puts NCCL QPs on the storage fabric |
| `fabric.ncclIbTimeout` / `RetryCnt` | `22` / `13` | Deliberately generous: a link flap stalls the gang instead of killing it |
| `rails.nads` / `rails.resources` | `ib-rail1..8` / `rdma/ib: 8` | Your NAD names and device-plugin resource(s) — rails are user-provided |
| `worker.resources` | 8 GPU / 96 CPU / 1500Gi | Full-node, Guaranteed QoS → exclusive pcpus (112 logical − 16 reserved) |
| `worker.startupProbe.failureThreshold` | `160` | ~40 min budget for weight load + CUDA graph capture — don't tighten |
| `runtimeClassName` | `performance-gpu-hpc` | Low-latency pod contract — tracks node-foundation's profile name. §10 |
| `pdb.maxUnavailable` | `1` | One node (= one gang) disruptible at a time |

Note what is *absent* vs main: no `NCCL_IB_TC`/GID index (RoCE-only), no UCX/NIXL env (no disaggregation), no KVBM.

## Gate 6 (do not proceed past failure)

Validation ladder first (design §7): single node TP8 no spec → single node + MTP → 2-node gang DP+EP no spec → full config. Then: `genai-perf` meets TTFT/ITL · DeepEP all-to-all clean under load (dispatch p99 on the dashboard) · MTP acceptance ≥ threshold at night-shape traffic, auto-disables at peak-shape · node kill: exactly one gang dies, service continues at 50%, gang rejoins when the node returns · `numastat`: engine memory on both sockets.

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance. [../../ENVIRONMENT.md](../../ENVIRONMENT.md) — the full branch delta.
