# Environment: `env/h100-4x-ib` — 4× DGX H100, InfiniBand, MiniMax M2.7 (MTP)

This branch is the **8-node design halved**: it descends from `env/h100-8x-ib` (which adapts
`main` to MiniMax M2.7 on DGX H100 over InfiniBand) with a small delta. Governing documents:
[glm51-openshift-deployment.md](glm51-openshift-deployment.md) for the phase/gate build
discipline, [minimax-m27-dflash-design.md](minimax-m27-dflash-design.md) for the serving design
(original LWS manifest in [reference/](reference/)). Where they disagree with this file,
**this environment follows this file**.

## What this environment is

- **2 wide-EP gangs × 2 nodes = 4 DGX H100.** Same shape as the 8-node env: TP8 on NVLink per
  node, DP2 + `--enable-expert-parallel` ⇒ EP16 per gang, MoE all-to-all via DeepEP over IB.
- **MTP, not DFlash.** Speculative decoding uses the native MTP heads in the checkpoint
  (`speculative.method: mtp`, K=3) — **DFlash is used only in the 8-node environment.** The
  DFlash path stays fully wired in the chart; adopting it here is one value flip plus staging
  the `z-lab/MiniMax-M2.7-DFlash` mirror.
- **Blast radius at N=2 (design §5):** a node loss kills one gang → **50%** keeps serving, and
  the PDB (`maxUnavailable: 1`) blocks any voluntary drain while a gang is down. This is the
  environment where the single-node-islands fallback (`replicas: 4, nodeCount: 1,
  dataParallel: 1` → 25% blast radius) is most worth benchmarking against wide-EP.
- Fabric = InfiniBand: identical to the 8-node branch (`roceQos` disabled, no RoCE QoS env,
  RoCE exporter/PFC alert off, `ibstat` in Gate 1).

## Delta from `env/h100-8x-ib`

| Chart | Change |
|-------|--------|
| `minimax-dynamo` | `worker.replicas: 2` (was 4) · `speculative.method: mtp` (was dflash) |
| `model-staging` | Stages `minimax-m2.7` only — no DFlash draft |
| `kai-scheduler` | Interactive quota/limit **32/32** (whole env, multiples of gang size 16) |
| everything else | Identical to `env/h100-8x-ib` (see that branch's delta from `main` history) |

## Delta from `main` (inherited from env/h100-8x-ib)

Chart `minimax-dynamo` replaces `glm51-dynamo` (one DGD, Grove gangs, no KVBM/NIXL/batch lane) ·
model-staging stages MiniMax · node-foundation `roceQos.enabled: false` · gateway routes both
hostnames to `minimax-m27-frontend` in `llm-serving` · observability RoCE bits off ·
`sriov-rails` untouched and unused (user-provided IB rail NADs; Gate 3 still runs against them).
