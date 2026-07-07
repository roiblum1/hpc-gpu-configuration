#!/usr/bin/env bash
# verify-nodes.sh — Gate 1, node side. SSH into every <PREFIX> node and verify the
# node-foundation host layer actually landed: lscpu/SMT, kernel cmdline, hugepages,
# the NTO-generated kubelet config, the tuned-extras sysctls, and the CRI-O half
# (performance RuntimeClass drop-in, memlock, live container cpusets via crictl).
#
# Usage:
#   SSH_KEY=~/.ssh/id_rsa USER_SSH=core PREFIX=h200 ./verify-nodes.sh
# or edit the three variables below and run it plain. USER_SSH must have
# passwordless sudo (NOPASSWD) — everything remote runs under `sudo -n`.
#
# Exits non-zero if any check FAILs on any node. INFO lines are evidence for the
# eyeball checks (full lscpu, cpuset spot-checks), not pass/fail.

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
USER_SSH="${USER_SSH:-core}"
PREFIX="${PREFIX:-}"

# ---- Expected values — mirror charts/node-foundation/values.yaml. One place to ----
# ---- tweak per environment; keep in sync with the §10 rows.                    ----
RESERVED_CPUS="0-7,56-63"        # performanceProfile.cpu.reserved
ISOLATED_CPUS="8-55,64-111"      # performanceProfile.cpu.isolated
EXPECTED_CPUS="112"              # logical CPUs with SMT off (2x56-core)
HUGEPAGES_1G="16"                # performanceProfile.hugepages 1G page count
RUNTIME_CLASS="performance-gpu-hpc"  # NTO derives it from performanceProfile.name
TUNED_PROFILE="gpu-hpc-extras"       # tuned.name (child profile)
# performanceProfile.additionalKernelArgs — NTO-generated args (isolcpus/nohz_full/
# systemd.cpu_affinity/hugepages) are checked separately against the cpusets above.
KERNEL_ARGS="iommu=pt intel_iommu=on numa_balancing=disable skew_tick=1 tsc=reliable nowatchdog nosoftlockup pcie_aspm=off rcu_nocb_poll intel_idle.max_cstate=1 processor.max_cstate=1"

set -u -o pipefail

if [ -z "$PREFIX" ]; then
    echo "ERROR: PREFIX is empty — set PREFIX=<node-name-prefix> (e.g. PREFIX=h200)" >&2
    exit 2
fi
if [ ! -r "$SSH_KEY" ]; then
    echo "ERROR: SSH_KEY '$SSH_KEY' not readable" >&2
    exit 2
fi

NODES=$(oc get nodes -o wide --no-headers 2>/dev/null | awk -v p="$PREFIX" '$1 ~ p {print $1, $6}')
if [ -z "$NODES" ]; then
    echo "ERROR: no nodes matching '$PREFIX' (is oc logged in to the right cluster?)" >&2
    echo "       oc get nodes -o wide | grep $PREFIX  returned nothing." >&2
    exit 2
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)

# ---- Remote check block. Runs under `sudo -n bash -s` on each node.            ----
# ---- Args: reserved isolated hugepages runtime-class tuned-profile kargs cpus  ----
# (read -d '' instead of $(cat <<...): bash 3.2 — macOS — misparses case-`)` inside $())
read -r -d '' REMOTE_SCRIPT <<'REMOTE' || true
RESERVED_CPUS="$1"; ISOLATED_CPUS="$2"; HUGEPAGES_1G="$3"; RUNTIME_CLASS="$4"
TUNED_PROFILE="$5"; KERNEL_ARGS="$6"; EXPECTED_CPUS="$7"
FAILS=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
info() { printf '  INFO  %s\n' "$1"; }
check_eq() { # label actual expected
    if [ "$2" = "$3" ]; then pass "$1: $2"; else fail "$1: got '$2', expected '$3'"; fi
}

# Expand "0-7,56-63" into one CPU id per line (for overlap checks).
expand_cpulist() {
    echo "$1" | tr ',' '\n' | while IFS=- read -r a b; do
        seq "$a" "${b:-$a}"
    done
}

echo "== kernel: $(uname -r)"

echo "== 1. lscpu (SMT / topology)"
THREADS=$(lscpu | awk -F: '/^Thread\(s\) per core/ {gsub(/^[ \t]+/,"",$2); print $2}')
CPUS=$(lscpu    | awk -F: '/^CPU\(s\)/            {gsub(/^[ \t]+/,"",$2); print $2; exit}')
SOCKETS=$(lscpu | awk -F: '/^Socket\(s\)/          {gsub(/^[ \t]+/,"",$2); print $2}')
NUMAS=$(lscpu   | awk -F: '/^NUMA node\(s\)/       {gsub(/^[ \t]+/,"",$2); print $2}')
check_eq "Thread(s) per core (SMT off — cpusets assume it)" "$THREADS" "1"
check_eq "logical CPUs" "$CPUS" "$EXPECTED_CPUS"
info "sockets=$SOCKETS numa_nodes=$NUMAS"
lscpu | sed 's/^/        /'

echo "== 2. /proc/cmdline (PerformanceProfile kernel args)"
CMDLINE=$(cat /proc/cmdline)
for arg in $KERNEL_ARGS; do
    if echo "$CMDLINE" | grep -qw -- "$arg"; then pass "$arg"; else fail "$arg missing from cmdline"; fi
done
# NTO-generated from the cpusets — never hand-written:
if echo "$CMDLINE" | grep -q "nohz_full=$ISOLATED_CPUS"; then
    pass "nohz_full=$ISOLATED_CPUS (NTO-generated)"
else fail "nohz_full=$ISOLATED_CPUS not in cmdline"; fi
ISOLCPUS=$(echo "$CMDLINE" | grep -o 'isolcpus=[^ ]*' || true)
case "$ISOLCPUS" in
    *"$ISOLATED_CPUS"*) pass "isolcpus contains $ISOLATED_CPUS ($ISOLCPUS)";;
    *)                  fail "isolcpus wrong: '$ISOLCPUS' (expected to contain $ISOLATED_CPUS)";;
esac
if echo "$CMDLINE" | grep -q 'systemd.cpu_affinity='; then
    pass "systemd.cpu_affinity present (NTO-generated)"
else fail "systemd.cpu_affinity missing"; fi
info "hugepage args: $(echo "$CMDLINE" | grep -o '[a-z_]*hugepages[a-z=0-9G]*' | tr '\n' ' ')"

echo "== 3. hugepages (1G)"
NR=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo MISSING)
check_eq "1G hugepages" "$NR" "$HUGEPAGES_1G"
for n in /sys/devices/system/node/node[0-9]*; do
    info "$(basename "$n"): $(cat "$n/hugepages/hugepages-1048576kB/nr_hugepages" 2>/dev/null || echo '?') x 1G"
done

echo "== 4. kubelet config (NTO-generated from the PerformanceProfile — no manual KubeletConfig)"
KCONF=/etc/kubernetes/kubelet.conf
if [ -r "$KCONF" ]; then
    grab() { grep -o "\"$1\": *\"[^\"]*\"" "$KCONF" | head -1 | sed 's/.*: *"\(.*\)"/\1/'; }
    check_eq "cpuManagerPolicy"      "$(grab cpuManagerPolicy)"      "static"
    check_eq "memoryManagerPolicy"   "$(grab memoryManagerPolicy)"   "Static"
    check_eq "topologyManagerPolicy" "$(grab topologyManagerPolicy)" "best-effort"
    check_eq "reservedSystemCPUs"    "$(grab reservedSystemCPUs)"    "$RESERVED_CPUS"
    if grep -q 'full-pcpus-only' "$KCONF"; then pass "cpuManagerPolicyOptions: full-pcpus-only"; else fail "full-pcpus-only not set"; fi
    if grep -q 'reservedMemory' "$KCONF"; then info "reservedMemory present (per-NUMA reservation)"; else info "reservedMemory NOT present — check the generated KubeletConfig"; fi
else
    fail "$KCONF not readable — cannot verify the generated kubelet config"
fi

echo "== 5. tuned-extras sysctls (the child Tuned profile $TUNED_PROFILE)"
check_sysctl() { # key expected
    ACT=$(sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//')
    EXP=$(echo "$2" | tr -s '[:space:]' ' ')
    check_eq "$1" "$ACT" "$EXP"
}
check_sysctl vm.swappiness          "0"
check_sysctl vm.zone_reclaim_mode   "0"
check_sysctl vm.max_map_count       "1048576"
check_sysctl net.core.rmem_max      "536870912"
check_sysctl net.core.wmem_max      "536870912"
check_sysctl net.ipv4.tcp_rmem      "4096 87380 268435456"
check_sysctl net.ipv4.tcp_wmem      "4096 65536 268435456"
check_sysctl fs.aio-max-nr          "1048576"
check_sysctl vm.min_free_kbytes     "4194304"
THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
case "$THP" in
    *"[madvise]"*) pass "transparent_hugepage: $THP";;
    *)             fail "transparent_hugepage: '$THP', expected [madvise]";;
esac
for f in /etc/tuned/active_profile /var/lib/ocp-tuned/active_profile; do
    [ -r "$f" ] && info "$f: $(cat "$f") (expect it to include $TUNED_PROFILE)"
done

echo "== 6. CRI-O (RuntimeClass drop-in, memlock, live cpusets)"
if grep -rqs "crio\.runtime\.runtimes\.$RUNTIME_CLASS" /etc/crio/crio.conf.d/; then
    pass "crio drop-in defines runtime '$RUNTIME_CLASS' (NTO-generated)"
else
    fail "no crio.conf.d drop-in for runtime '$RUNTIME_CLASS'"
fi
MEMLOCK=$(grep -rhs 'memlock=' /etc/crio/crio.conf.d/ | head -1)
case "$MEMLOCK" in
    *"memlock=-1:-1"*) pass "crio default_ulimits memlock=-1:-1";;
    *)                 fail "crio memlock ulimit missing/wrong: '${MEMLOCK:-<none>}'";;
esac
if command -v crictl >/dev/null 2>&1; then
    info "crictl runtime handlers: $(crictl info 2>/dev/null | grep -o "\"$RUNTIME_CLASS\"" | head -1 || echo "not visible via crictl info (older CRI — drop-in above is authoritative)")"
    # Spot-check: a running container's cpuset must not overlap the reserved set.
    FOUND_CPUSET=""
    for cid in $(crictl ps -q 2>/dev/null | head -10); do
        CSET=$(crictl inspect "$cid" 2>/dev/null | grep -o '"cpus": *"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/')
        if [ -n "$CSET" ]; then FOUND_CPUSET="$CSET"; FOUND_CID="$cid"; break; fi
    done
    if [ -n "$FOUND_CPUSET" ]; then
        OVERLAP=$(comm -12 <(expand_cpulist "$FOUND_CPUSET" | sort -u) \
                           <(expand_cpulist "$RESERVED_CPUS" | sort -u) | tr '\n' ',')
        if [ -n "$OVERLAP" ]; then
            info "container ${FOUND_CID:0:12} cpuset $FOUND_CPUSET OVERLAPS reserved ($OVERLAP) — pinned pod on housekeeping cores, investigate"
        else
            info "container ${FOUND_CID:0:12} cpuset $FOUND_CPUSET — no overlap with reserved $RESERVED_CPUS"
        fi
    else
        info "no running container with an explicit cpuset (node idle) — spot-check skipped"
    fi
else
    info "crictl not found in sudo PATH — skipped live-container checks"
fi

echo "== 7. PID 1 affinity (systemd.cpu_affinity applied)"
PID1=$(awk '/^Cpus_allowed_list/ {print $2}' /proc/1/status)
check_eq "PID 1 Cpus_allowed_list" "$PID1" "$RESERVED_CPUS"

echo "NODE_SUMMARY fails=$FAILS"
exit 0
REMOTE

TOTAL_FAILS=0
UNREACHABLE=0
SUMMARY=""

while read -r NODE IP; do
    echo
    echo "########## $NODE ($IP) ##########"
    OUT=$(ssh "${SSH_OPTS[@]}" "$USER_SSH@$IP" sudo -n bash -s -- \
          "$(printf '%q %q %q %q %q %q %q' "$RESERVED_CPUS" "$ISOLATED_CPUS" "$HUGEPAGES_1G" \
                    "$RUNTIME_CLASS" "$TUNED_PROFILE" "$KERNEL_ARGS" "$EXPECTED_CPUS")" \
          <<<"$REMOTE_SCRIPT" 2>&1)
    RC=$?
    echo "$OUT"
    if [ $RC -ne 0 ] || ! echo "$OUT" | grep -q 'NODE_SUMMARY'; then
        echo "  ERROR: ssh/sudo failed on $NODE (rc=$RC) — is $USER_SSH NOPASSWD-sudo and the key right?"
        UNREACHABLE=$((UNREACHABLE+1))
        SUMMARY="$SUMMARY
  $NODE: UNREACHABLE"
        continue
    fi
    NF=$(echo "$OUT" | awk -F= '/^NODE_SUMMARY/ {print $2}')
    TOTAL_FAILS=$((TOTAL_FAILS+NF))
    SUMMARY="$SUMMARY
  $NODE: $NF failed"
done <<<"$NODES"

echo
echo "================= fleet summary (PREFIX=$PREFIX) ================="
echo "$SUMMARY"
if [ "$TOTAL_FAILS" -eq 0 ] && [ "$UNREACHABLE" -eq 0 ]; then
    echo "Gate 1 node-side: all checks passed. (Fabric-side checks — QoS/ibstat, /proc/interrupts IRQ homes, in-pod ulimit -l, nvidia-smi topo — remain per the gate text.)"
    exit 0
else
    echo "Gate 1 node-side: $TOTAL_FAILS check(s) failed, $UNREACHABLE node(s) unreachable. Do not proceed past a failed gate."
    exit 1
fi
