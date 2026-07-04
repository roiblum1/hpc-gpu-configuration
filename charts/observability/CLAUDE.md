# CLAUDE.md — `observability` chart (Phase 8)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §8 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** the serving + fabric ServiceMonitors, the §8 alert rules (`PrometheusRule`), and the
"single goodput view" dashboard ConfigMap stub.

**Does NOT own:** the DCGM exporter + its ServiceMonitor (→ created by the GPU Operator in
`gpu-operator` — do **not** duplicate it here, double-scraping skews rate() queries) · User
Workload Monitoring itself (cluster setting — prerequisite, enable it before installing) · **the
RoCE metrics exporter** (see the honest gap below).

## Why each configuration is what it is

- **The signal set is the planner's input, not just ops eyes.** TTFT/ITL per lane feed the SLA
  planner; prefix/KV hit rate + KVBM offload/onboard rates are the tier-sizing feedback loop;
  expert-load skew tells you which GPUs *and rails* run hot (hot experts = hot rails); per-rail
  RoCE counters are the fabric-QoS drift detector; gang pending/reclaim is capacity planning.
  Cut a signal and you cut a control loop, not a chart.
- **Alert thresholds are declared starting points** — tune at Gate 6/8 against measured
  traffic, don't treat them as vendor truth:
  - `pfcPauseSecondsPer5m: 0.001` — effectively "any sustained PFC pause is news": pause storms
    during all-to-all mean the ECN/WRED early-warning layer is mis-tuned (PFC should be the
    backstop, not the regulator).
  - `thinPoolPercent: 80` — kvcache thin-pool exhaustion is a node-level incident (§4); 80%
    leaves reaction time.
  - `mtpAcceptanceMin: 0.4` — below threshold, speculative decoding is pure verification
    overhead; turn MTP off rather than serve it degraded.
  - `prefixHitRateMin: 0.3` — a hit-rate drop means cache thrash: tiers undersized or router
    locality broken.
  - `gangPendingSeconds: 300` — interactive gangs Pending this long means quota/capacity drift,
    not scheduling noise.
- **`dynamoFrontend` monitor** scrapes the frontend's OpenAI-metrics + router stats in
  `llm-serving` — on this branch that includes the **spec-decode acceptance** signal
  (`mtpAcceptanceMin` watches MTP here; DFlash is the 8-node env) and DeepEP dispatch latency,
  the two numbers that decide whether the wide-EP topology earns its keep (design §7).
- **`roceExporter` is DISABLED on this branch** (IB fabric — no PFC/CNP counters exist; the
  PFC-pause alert renders only when the exporter is enabled). IB fabric health is watched out
  of band (UFM / subnet manager); `ibstat` all-rails-Active is Gate 1's check.

## Honest gap — the RoCE exporter is assumed, not shipped

The `roceExporter` ServiceMonitor targets `app: sriov-network-metrics-exporter`, but **no chart
in this repo deploys that exporter**. Deploy it out of band (mirrored manifests), or enable the
SR-IOV Network Operator's built-in metrics-exporter feature if your operator version ships it —
then make the labels here match. Until then, the fabric alerts are silently blind: the
ServiceMonitor selects zero endpoints and Prometheus reports nothing, including no error.

## Cross-layer invariants this chart carries
Scrape labels ↔ what `minimax-dynamo`/exporters actually expose (a renamed port kills a control
loop silently) · alert thresholds ↔ §8 minimums · DCGM ownership stays in `gpu-operator`.

## Gate 8 — the 72h soak (the whole build's exit gate)
Mixed-traffic soak with the batch lane saturating troughs; SLOs hold through a planner rescale
**and** one deliberate node drain (gang rescheduled whole, sessions resume via KVBM); no fabric
pause storms; every §8 alert demonstrated to *fire* at least once in a controlled test — an
alert that has never fired is a hypothesis, not monitoring.
