#!/usr/bin/env bash
# Ordered installer for the MiniMax M2.7 / OpenShift 4.20 chart set (env/h100-4x-ib).
# Mirrors the build sequence + validation gates in ../glm51-openshift-deployment.md
# (phase/gate discipline) and ../minimax-m27-dflash-design.md (this branch's serving design).
# Run a single chart:  ./install.sh node-foundation
# Run everything:      ./install.sh            (pauses for the gate after each phase)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# chart  release-namespace  "gate reminder"
# (namespace here is the release namespace for cluster-scoped objects; CRs target their own ns)
PLAN=(
  "model-staging|llm-serving|Gate 0: MiniMax weights staged + checksummed on every GPU node"
  "node-foundation|default|Gate 1: /proc/cmdline args, hugepages allocatable, tuned-adm active, ibstat all 8 compute rails Active (not Polling), rail IRQs on local reserved CPUs, kubeletconfig memoryManagerPolicy=Static, container ulimit -l unlimited"
  "gpu-operator|nvidia-gpu-operator|Gate 2: nvidia-smi topo -m shows PIX GPU<->NIC; lsmod nvidia(open)/nvidia_fs/gdrdrv (peermem/GDRCopy needed by DeepEP); DCGM in UWM Prometheus"
  # sriov-rails intentionally NOT in this plan: the IB rail NADs are user-provided
  # templated config, applied out of band. Gate 3 still MUST be run against those rails:
  #   Gate 3: ib_write_bw at rail line rate; nccl all_reduce at ref; 2-node alltoall clean;
  #           NCCL_DEBUG=INFO log shows rail-aligned GDRDMA
  "lvms-storage|openshift-storage|Gate 4: fio 1M seq read ~= aggregate NVMe; fallocate -l 1G succeeds"
  "cert-manager|cert-manager-operator|(prereq for Dynamo operator webhooks)"
  "kai-scheduler|kai-scheduler|Gate 5: 2-node dummy gang with 1 node free stays Pending (zero partial bind); free node -> both bind in one cycle"
  "minimax-dynamo|llm-serving|Gate 6: validation ladder (1-node no spec -> +MTP -> 2-node DP+EP no spec -> full config); TTFT/ITL met; DeepEP alltoall p99 clean; MTP acceptance >= threshold at night-shape and auto-disables at peak; node kill -> exactly one gang down, 50% keeps serving; numastat both sockets"
  "gateway-tenancy|kuadrant-system|Gate 7: no key->401; over budget->429; oversized output clamped; both hostnames reach the frontend"
  "observability|openshift-monitoring|Gate 8: 72h mixed-traffic soak; SLOs hold through one node drain (gang recreated whole); no IB link flaps/credit stalls; every alert demonstrated to fire once"
)

install_one() {
  local chart="$1" ns="$2"
  echo ">>> helm upgrade --install ${chart} ${HERE}/${chart} -n ${ns} --create-namespace"
  helm upgrade --install "${chart}" "${HERE}/${chart}" -n "${ns}" --create-namespace
}

if [[ $# -ge 1 ]]; then
  for row in "${PLAN[@]}"; do
    IFS='|' read -r chart ns gate <<<"$row"
    if [[ "$chart" == "$1" ]]; then install_one "$chart" "$ns"; echo "    GATE -> $gate"; exit 0; fi
  done
  echo "unknown chart: $1"; exit 1
fi

echo "Ordered install plan (run the gate after each before continuing):"
for row in "${PLAN[@]}"; do
  IFS='|' read -r chart ns gate <<<"$row"
  printf '  %-16s ns=%-32s %s\n' "$chart" "$ns" "$gate"
done
echo
read -r -p "Proceed installing all in order, pausing after each? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || exit 0

for row in "${PLAN[@]}"; do
  IFS='|' read -r chart ns gate <<<"$row"
  install_one "$chart" "$ns"
  echo "    GATE -> $gate"
  read -r -p "    Gate passed? Continue to next phase? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Stopping at ${chart} (do not proceed past a failed gate)."; exit 1; }
done
echo "All phases installed."
