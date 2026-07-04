# model-staging — Phase 0

Pre-stages the MiniMax M2.7 weights onto every GPU node's local NVMe **before** any serving pod starts, so worker startup and restarts cost **zero** pull time. (No DFlash draft on this branch — the 4-node environment runs MTP.)

## Why it matters

A ~230 GB checkpoint pulled through container images serializes on CRI-O's layer-extraction lock, and every pod restart — including every atomic gang recreate after a node event — pays the pull again. Staging once per node — as a node property, not a task — makes gang restarts instant and keeps the weights off the image path entirely. This is the doc's *"do not serve weights through image pulls"* rule.

## What it deploys

- A **DaemonSet** running the templated [files/stage-weights.sh](files/stage-weights.sh) on every `gpu-hpc` node, plus its ConfigMap.
- The pod stages each model to `hostPath/<name>`, writes a `.staged` marker (so restarts re-verify instead of re-copy), verifies `sha256sum.txt` if present, then holds `Running` so its status doubles as per-node evidence.

## Prerequisites & position

Runs **first** (before/independent of node-foundation). Needs the `models` LV present on each node (from [lvms-storage](../lvms-storage) or an out-of-band LV) and the mirror registry reachable. Consumed later by [minimax-dynamo](../minimax-dynamo), which mounts `hostPath` read-only.

## How to use

```bash
../install.sh model-staging      # or: helm upgrade --install model-staging . -n glm-serving --create-namespace
helm template model-staging      # inspect the rendered DaemonSet + script
```

## Values

| Value | Default | What it does |
|-------|---------|--------------|
| `roleLabel` | `gpu-hpc` | Node selector — runs exactly on GPU nodes. §10 |
| `hostPath` | `/var/lib/models` | Dedicated `models` LV, **separate** from the KV-cache LV. Must match `minimax-dynamo.modelsHostPath` |
| `image` | `<your-registry>/tools/skopeo:latest` | Image with `skopeo` (+ `rsync`), from your mirror |
| `source.type` | `oci` | `oci` (skopeo from mirror, by digest) or `rsync` (artifact server) |
| `source.registry` / `source.rsyncBase` | placeholder | Where staged weights come from |
| `models[]` | `minimax-m2.7` | Dir names — must match `minimax-dynamo.modelPaths`; refs pinned **by digest** |
| `resources` | 2 CPU / 4 Gi | I/O-bound; kept small so it stays schedulable and harmless to the reserved-CPU budget |

**Base model only** (`env/h100-4x-ib`): MTP uses the native heads in the checkpoint — no draft artifact. If this environment ever adopts DFlash, add the [z-lab/MiniMax-M2.7-DFlash](https://huggingface.co/z-lab/MiniMax-M2.7-DFlash) mirror to `models[]` and flip `speculative.method` in minimax-dynamo.

## Gate 0 (do not proceed past failure)

All images resolvable by digest from a GPU node; every DaemonSet pod `Running` with "all models staged"; checksum verification passed (no `sha256sum.txt` warnings) on **every** node.

## See also

[CLAUDE.md](CLAUDE.md) — the why-each-decision guidance.
