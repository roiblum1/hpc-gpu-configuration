# observability — Phase 8

The serving + fabric monitors, the §8 alert rules, and the "single goodput view" dashboard. These signals are also the **planner's inputs** — cut one and you cut a control loop, not just a graph.

## Why it matters

This is the phase that closes the loop and gates the whole build (the 72h soak). The signal set does double duty: TTFT/ITL feed the SLA planner; KV/prefix hit rate is tier-sizing feedback; per-rail RoCE counters detect fabric-QoS drift before it becomes a pause storm; gang pending/reclaim is capacity planning.

## What it deploys

- **ServiceMonitors** — `dynamoFrontend` (OpenAI-metrics + router stats) and `roceExporter` (per-rail NIC counters).
- **`PrometheusRule`** — the §8 alert minimums.
- **Dashboard ConfigMap** stub for the goodput view.

DCGM's exporter + ServiceMonitor are **not** here — they're created by [gpu-operator](../gpu-operator). Don't duplicate them (double-scraping skews `rate()`).

## Prerequisites & position

Last phase. Requires **User Workload Monitoring enabled** (cluster setting). See the honest gap below about the RoCE exporter.

## How to use

```bash
../install.sh observability
helm template observability      # inspect ServiceMonitors + PrometheusRule
```

## Values (highlights)

| Value | Default | What it does |
|-------|---------|--------------|
| `serviceMonitors.dynamoFrontend` | enabled, 15s | Scrapes the frontend metrics + router stats in `glm-serving` |
| `serviceMonitors.roceExporter` | enabled, 30s | Per-rail NIC counters (`out_of_buffer`, CNPs, PFC pause) — see gap below |
| `alerts.gangPendingSeconds` | `300` | Interactive gangs Pending this long = quota/capacity drift |
| `alerts.thinPoolPercent` | `80` | kvcache thin-pool exhaustion is a node-level incident |
| `alerts.mtpAcceptanceMin` | `0.4` | Below this, MTP is pure verification overhead — turn it off |
| `alerts.prefixHitRateMin` | `0.3` | A drop = cache thrash (tiers undersized / router locality broken) |
| `alerts.pfcPauseSecondsPer5m` | `0.001` | Effectively "any sustained PFC pause is news" — ECN/WRED should regulate, PFC is the backstop |

Thresholds are declared **starting points** — tune at Gate 6/8 against measured traffic.

## Honest gap — the RoCE exporter is assumed, not shipped

The `roceExporter` ServiceMonitor targets `app: sriov-network-metrics-exporter`, but **no chart in this repo deploys that exporter.** Deploy it out of band (mirrored manifests) or enable the SR-IOV Network Operator's built-in metrics exporter, then make the labels match. Until then the fabric alerts are silently blind — the ServiceMonitor selects zero endpoints and Prometheus reports nothing, including no error.

## Gate 8 — the 72h soak (the build's exit gate)

Mixed-traffic soak with the batch lane saturating troughs; SLOs hold through a planner rescale **and** one deliberate node drain (gang rescheduled whole, sessions resume via KVBM); no fabric pause storms; every §8 alert demonstrated to **fire** at least once in a controlled test (an alert that has never fired is a hypothesis, not monitoring).

## See also

[CLAUDE.md](CLAUDE.md) — why-each-decision guidance.
