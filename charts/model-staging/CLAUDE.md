# CLAUDE.md — `model-staging` chart (Phase 0)

Scoped guidance for **this chart only**. Repo-root [CLAUDE.md](../../CLAUDE.md) and the
deployment doc §0 stay authoritative.

## Scope — what this chart owns (and does not)

**Owns:** the per-node weight staging DaemonSet + its templated script
([files/stage-weights.sh](files/stage-weights.sh)) and ConfigMap.

**Does NOT own:** the `models` LV / filesystem it writes into (→ `lvms-storage` optional class,
or an out-of-band LV) · consumption of the weights (→ `minimax-dynamo` mounts
`hostPath: /var/lib/models` read-only) · registry mirroring itself (Phase 0, out of band).

## Why each configuration is what it is

- **DaemonSet, not a Job.** Staging is a *node property*, not a task: every current **and
  future** GPU node must hold the weights before a worker can start there. A DaemonSet
  reconciles new nodes automatically; a Job would need re-running on every scale-up. The pod
  stays Running (`sleep infinity`) after staging so its status doubles as per-node evidence.
- **Why not just pull weights inside the serving image:** a ~230 GB checkpoint through image
  pulls serializes on CRI-O's layer-extraction lock, and every pod restart — including every
  atomic gang recreate — pays the pull again. Staging once per node makes gang restarts cost
  **zero** pull time — this is the doc's "do not serve weights through image pulls" rule.
- **`hostPath: /var/lib/models`** — dedicated `models` LV, *separate from the KV-cache LV* so
  KVBM disk-tier churn and weight storage never compete for the same thin pool. Workers mount it
  read-only; the DaemonSet is the only writer.
- **`source.type: oci | rsync`** — OCI (skopeo from the mirror registry, referenced **by
  digest**) is the default because the mirror already exists for Phase 0; rsync is the escape
  hatch for an artifact server. Either way the transfer happens once per node.
- **Idempotence + verification:** a `.staged` marker skips re-copying on pod restart; if the
  model dir ships a `sha256sum.txt` (generate it at mirror time), the script verifies it on
  every (re)stage — that is Gate 0's "staged **and checksummed**" evidence. No manifest = loud
  warning, not silent pass.
- **Base model only** (`minimax-m2.7`) on this branch: the 4-node environment runs MTP (native
  heads in the checkpoint), so there is no DFlash draft to stage — adopting DFlash later means
  adding the z-lab mirror to `models[]` plus one value flip in `minimax-dynamo`. Directory
  names must match `minimax-dynamo`'s `modelPaths` (`/models/<name>`).
- **Tiny resources** (2 CPU / 4 Gi): the pod is I/O-bound; keep it schedulable on busy nodes and
  harmless on the reserved-CPU budget.

## Cross-layer invariants this chart carries
`roleLabel: gpu-hpc` (runs exactly on GPU nodes) · `hostPath` ↔ `minimax-dynamo.modelsHostPath` ·
model dir names ↔ `minimax-dynamo.modelPaths` · image + refs pinned by digest per Phase 0.

## Gate 0 (do not proceed past failure)
All images resolvable by digest from a GPU node; every DaemonSet pod Running with "all models
staged"; checksum verification passed (no `sha256sum.txt` warnings) on **every** node.
