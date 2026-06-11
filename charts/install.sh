#!/usr/bin/env bash
# Ordered installer for the GLM-5.1 / OpenShift 4.20 chart set.
# Mirrors the build sequence + validation gates in ../glm51-openshift-deployment.md.
# Run a single chart:  ./install.sh node-foundation
# Run everything:      ./install.sh            (pauses for the gate after each phase)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# chart  release-namespace  "gate reminder"
# (namespace here is the release namespace for cluster-scoped objects; CRs target their own ns)
PLAN=(
  "model-staging|glm-serving|Gate 0: weights staged + checksummed on every GPU node"
  "node-foundation|default|Gate 1: /proc/cmdline args, hugepages allocatable, tuned-adm active, mlnx_qos trust=dscp+PFC prio3, cnp_dscp=48, rail IRQs on local reserved CPUs, kubeletconfig memoryManagerPolicy=Static, container ulimit -l unlimited"
  "gpu-operator|nvidia-gpu-operator|Gate 2: nvidia-smi topo -m shows PIX GPU<->NIC; lsmod nvidia(open)/nvidia_fs/gdrdrv; DCGM in UWM Prometheus"
  "sriov-rails|openshift-sriov-network-operator|Gate 3: ib_write_bw >=370Gb/s/rail; nccl all_reduce at ref; 2-node alltoall clean, zero PFC pause/out_of_buffer; NCCL_DEBUG=INFO log shows GDRDMA"
  "lvms-storage|openshift-storage|Gate 4: fio 1M seq read ~= aggregate NVMe; gdsio shows GDS active; fallocate -l 1G succeeds"
  "cert-manager|cert-manager-operator|(prereq for Dynamo operator webhooks)"
  "kai-scheduler|kai-scheduler|Gate 5: 2-node LWS with 1 node free stays Pending (zero partial bind); free node -> both bind; batch gang evicted whole on interactive submit"
  "glm51-dynamo|glm-serving|Gate 6: genai-perf meets TTFT/ITL per lane; NIXL disagg counters move; 100K session park/resume TTFT is small fraction of initial; numastat: pinned tier on both sockets"
  "gateway-tenancy|kuadrant-system|Gate 7: no key->401; over budget->429; 131K output clamped; both lanes reach their DGDs"
  "observability|openshift-monitoring|Gate 8: 72h mixed-traffic soak; SLOs hold through planner rescale + one node drain; no fabric pause storms"
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
