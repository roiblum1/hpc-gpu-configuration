# Environment: `env/h200-2x-roce` — 2× HGX H200, RoCEv2

This branch adapts `main` (GLM-5.1 disaggregated, H200 prefill + Blackwell decode, XE9680 fleet)
to a **2-node HGX H200** environment. This file is the delta record — the architecture document
([glm51-openshift-deployment.md](glm51-openshift-deployment.md)) still describes the general
design; where this file and the doc disagree, **this environment follows this file**.

## The one structural change: aggregated, not disaggregated

There are no Blackwell nodes, so the prefill/decode split cannot exist. Instead:

- **Each H200 node = one complete TP8 FP8 replica** (prefill + decode in the same engine).
  GLM-5.1 FP8 ≈ 754 GB on 8×141 = 1128 GB HBM → ~250–300 GB left for KV at 0.9 utilization.
- The **Dynamo KV-aware router** fronts both replicas (still the one and only inference router).
- **Survivability:** lose a node → the other replica keeps serving at 50% capacity. This is the
  reason aggregated beats a 2-node disaggregated 1-prefill + 1-decode split, where either node's
  loss stops serving entirely.
- **KVBM is off by default** (`worker.kvbm.enabled: false`): KVBM currently disables CUDA
  graphs, and in the aggregated shape the decode hot loop runs in the same engine — main could
  afford KVBM only because it lived on prefill-only workers. Enable it only if session
  park/resume is worth trading decode ITL for.
- **MTP (1 head) stays on the interactive lane**; the batch lane (second, preemptible DGD)
  keeps MTP off. Both lanes are single-node gangs now.

## Delta from `main`, chart by chart

| Chart | Change |
|-------|--------|
| `model-staging` | Stages **FP8 only** (`glm-5.1-fp8`) — NVFP4 has no consumer without Blackwell |
| `glm51-dynamo` | `prefill:`/`decode:` → single `worker:` block (2 replicas × 1 node, TP8, FP8, MTP 1); KVBM off by default (toggle documented); single `sku.worker: h200` |
| `kai-scheduler` | Interactive quota/limit **16/16** (whole env = 2×8 GPUs, gang size 8) |
| `install.sh` | `sriov-rails` row commented out (rails are user-provided, applied out of band — Gate 3 still must be run against them); Gate 6 text reworded for the aggregated shape |
| `node-foundation`, `gpu-operator`, `lvms-storage`, `cert-manager`, `gateway-tenancy`, `observability` | **Unchanged** — the RoCE host QoS, BIOS checklist, and observability stack carry over as-is |
| `sriov-rails` | **Untouched and unused** — rail policies/NADs come from the user's own templated RoCE config |

## What still applies unchanged

The gate-per-phase discipline, the §10 invariant matrix (RoCE DSCP 26 / TC 106 / GID 3, CNP
48/6, MTU 9000, reserved CPUs `0-7,56-63`, low-latency pod contract, one quota brain, one
router), BIOS.md, and the full-node pod pattern (8 GPUs + 8 rail VFs + integer CPUs). Note the
rails carry **no serving traffic** in the aggregated shape (TP8 rides NVLink; no NIXL) — they
stay attached for fleet parity and future multi-node work; set `rails: []` in `glm51-dynamo`
to detach.
