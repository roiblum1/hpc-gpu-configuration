#!/usr/bin/env bash
# RoCE rail host-side QoS — Phase 1.4. Pins trust mode, lossless priority, CNP marking
# identically on every rail PF. Must mirror the switch fabric (PFC prio, ECN/WRED, CNP queue).
# Templated by Helm: values come from node-foundation/values.yaml roceQos.* (§10 invariants).
set -euo pipefail

PFC_PRIO={{ .Values.roceQos.pfcPriority }}
TRAFFIC_CLASS={{ .Values.roceQos.trafficClass }}   # DSCP 26 + ECN
CNP_DSCP={{ .Values.roceQos.cnpDscp }}
CNP_PRIO={{ .Values.roceQos.cnpPriority }}
MTU={{ .Values.roceQos.mtu }}

# Build the 8-element PFC vector with the lossless bit set at PFC_PRIO (e.g. prio 3 -> 0,0,0,1,0,0,0,0)
pfc=""
for i in 0 1 2 3 4 5 6 7; do
  if [ "$i" -eq "$PFC_PRIO" ]; then pfc+="1,"; else pfc+="0,"; fi
done
pfc=${pfc%,}

for dev in $(ls /sys/class/infiniband/ | grep mlx5); do
  port=$(ls /sys/class/infiniband/$dev/device/net/ | head -1)
  mlnx_qos -i "$port" --trust dscp
  mlnx_qos -i "$port" --pfc "$pfc"
  echo "$TRAFFIC_CLASS" > /sys/class/infiniband/$dev/tc/1/traffic_class
  cma_roce_tos -d "$dev" -t "$TRAFFIC_CLASS"
  echo "$CNP_DSCP" > /sys/class/net/$port/ecn/roce_np/cnp_dscp       # CNP marking
  echo "$CNP_PRIO" > /sys/class/net/$port/ecn/roce_np/cnp_802p_prio  # CNP egress priority
  echo 1 > /sys/class/net/$port/ecn/roce_np/enable/$PFC_PRIO         # DCQCN NP/RP on the lossless prio
  echo 1 > /sys/class/net/$port/ecn/roce_rp/enable/$PFC_PRIO
  ethtool -A "$port" rx off tx off || true   # global pause off — PFC only ("not modified" exits nonzero)
  ip link set "$port" mtu "$MTU"
done
