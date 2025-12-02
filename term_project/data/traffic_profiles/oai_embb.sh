#!/usr/bin/env bash
# Benign eMBB traffic generator for OAI NR (40 MHz n78, μ=1; 0.5 ms TTI; C=106 PRBs)
# - Three UEs request randomized eMBB rates between 5–30 Mbps
# - Active UE count per slice is randomized (0–3), with "0" rare
# - Default runtime = 30 minutes
# - At end: copy /tmp/prb_log.txt and /tmp/prb_features_ai.csv to the run dir
#           and build the per-slot feature table with oran_build_feature_set.py
#
# NOTE: Minimal changes vs. prior version:
#   * Re-exec with sudo if needed, then run user-space calls with: sudo -E -u "$SUDO_USER"
#   * Precreate logs/results as the local user
#   * Run feature builder as the local user (uses user's Python env)

set -Eeuo pipefail

# --- Require sudo for netns and /tmp PRB log handling (same pattern as DoS) ---
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi
RUN_USER="${SUDO_USER:-$(id -u -n)}"

AS_USER=(sudo -H -u "$RUN_USER")
as_user() { sudo -H -u "$RUN_USER" bash -lc "$*"; }

# ------------------------ Defaults ------------------------
DN_CONTAINER="oai-ext-dn"          # same as DoS driver
PORT=5201
PRB_LOG="/tmp/prb_log.txt"
PRB_FEAT="/tmp/prb_features_ai.csv"

DURATION_SEC=1800           # 30 minutes
SLICE_SEC=5                 # traffic slice length; each slice re-randomizes active UEs and rates
MIN_Mbps=5
MAX_Mbps=30
UE1_IP=""
UE2_IP=""
UE3_IP=""
PORT_BASE=5201             # retained (not used by exact DoS client call)
RESULTS_ROOT="./results"
BUILDER="./oran_build_feature_set.py"   # path to oran_build_feature_set.py
CAPACITY_PRB=106
TTI_SEC=0.0005             # μ=1 (0.5 ms)
SEED=""                    # optional RNG seed for reproducibility
SSH_USER=""                # unused; kept for parity
SSH_KEY=""                 # unused; kept for parity
IPERF_BIN="${IPERF_BIN:-iperf3}"

# Probability mass for number of active UEs per slice (must sum ~1.0):
#   p0 (rare idle), p1 (solo), p2 (two UEs), p3 (all three)
P0=0.05
P1=0.25
P2=0.35
P3=0.35

# --------------------- Helpers & parsing ------------------
log()  { printf "[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }
die()  { printf "[ERROR] %s\n" "$*" >&2; exit 2; }

usage() {
  cat <<EOF
Usage: $0 [options]
  --ue1 IP                UE1 IP address (optional; auto-discover if omitted)
  --ue2 IP                UE2 IP address (optional; auto-discover if omitted)
  --ue3 IP                UE3 IP address (optional; auto-discover if omitted)
  --duration SEC          Total run duration (default: ${DURATION_SEC})
  --slice SEC             Slice length in seconds (default: ${SLICE_SEC})
  --min-mbps N            Minimum requested rate per active UE (default: ${MIN_Mbps})
  --max-mbps N            Maximum requested rate per active UE (default: ${MAX_Mbps})
  --results DIR           Root results directory (default: ${RESULTS_ROOT})
  --builder PATH          Path to oran_build_feature_set.py (default: ${BUILDER})
  --iperf PATH            iperf3 binary (default from \$IPERF_BIN or 'iperf3')
  --p0 F --p1 F --p2 F --p3 F   Probabilities for 0/1/2/3 active UEs (default: 0.05/0.25/0.35/0.35)
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ue1|--ue1-ip) UE1_IP="$2"; shift 2;;
    --ue2|--ue2-ip) UE2_IP="$2"; shift 2;;
    --ue3|--ue3-ip) UE3_IP="$2"; shift 2;;
    --duration) DURATION_SEC="$2"; shift 2;;
    --slice) SLICE_SEC="$2"; shift 2;;
    --min-mbps) MIN_Mbps="$2"; shift 2;;
    --max-mbps) MAX_Mbps="$2"; shift 2;;
    --results) RESULTS_ROOT="$2"; shift 2;;
    --builder) BUILDER="$2"; shift 2;;
    --iperf) IPERF_BIN="$2"; shift 2;;
    --p0) P0="$2"; shift 2;;
    --p1) P1="$2"; shift 2;;
    --p2) P2="$2"; shift 2;;
    --p3) P3="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

need "$IPERF_BIN"; need awk; need date; need shuf

# Validate probabilities (sum≈1.0)
awk_check=$(awk -v p0="$P0" -v p1="$P1" -v p2="$P2" -v p3="$P3" 'BEGIN{s=p0+p1+p2+p3; print (s>=0.999 && s<=1.001)?"OK":"BAD"}')
[[ "$awk_check" == "OK" ]] || die "p0+p1+p2+p3 must sum to 1 (got $(awk -v p0="$P0" -v p1="$P1" -v p2="$P2" -v p3="$P3" 'BEGIN{print p0+p1+p2+p3}'))."

# --------------------- Results dir ------------------------
RUN_TAG=$(date +%Y%m%d-%H%M%S)
RUN_DIR="${RESULTS_ROOT}/run-${RUN_TAG}"
as_user "mkdir -p '$RUN_DIR/logs' '$RUN_DIR/meta'"
log "Run directory: ${RUN_DIR}"

# Persist run parameters (write as invoking user)
as_user "cat > '$RUN_DIR/meta/params.env' <<PARAMS
DN_CONTAINER=${DN_CONTAINER}
PORT=${PORT}
PRB_LOG=${PRB_LOG}
UE1_IP=${UE1_IP}
UE2_IP=${UE2_IP}
UE3_IP=${UE3_IP}
DURATION_SEC=${DURATION_SEC}
SLICE_SEC=${SLICE_SEC}
MIN_Mbps=${MIN_Mbps}
MAX_Mbps=${MAX_Mbps}
P0=${P0}
P1=${P1}
P2=${P2}
P3=${P3}
PARAMS"

# ---------------- Dynamic IP discovery (same as DoS) -----
discover_ip() {
  ip -n "$1" -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}
[[ -z "$UE1_IP" ]] && UE1_IP=$(discover_ip ue1)
[[ -z "$UE2_IP" ]] && UE2_IP=$(discover_ip ue2)
[[ -z "$UE3_IP" ]] && UE3_IP=$(discover_ip ue3)

[[ -n "$UE1_IP" && -n "$UE2_IP" && -n "$UE3_IP" ]] || die "Could not auto-discover ue1/ue2/ue3 IPs; pass --ue1/--ue2/--ue3."
printf "[%s] UEs: UE1=%s UE2=%s UE3=%s\n" "$(date +'%F %T')" "$UE1_IP" "$UE2_IP" "$UE3_IP"

# ---------- Step 0: truncate PRB log files in place (no delete/rename) ----------
# Only truncate if they exist (preserves inode/fd), then ensure the CSV has headers.
if [[ -e "$PRB_LOG" ]];  then : > "$PRB_LOG";  else : > "$PRB_LOG";  fi
if [[ -e "$PRB_FEAT" ]]; then : > "$PRB_FEAT"; else : > "$PRB_FEAT"; fi
# Immediately restore the required header row for the features CSV.
# This MUST match the scheduler's fprintf header exactly.
printf '%s\n' \
'frame,slot,rnti,ue_idx,rbStart,rbSize,tda_id,tda_symbols,mcs,Qm,R,nLayers,tb_size,harq_pid,harq_round,wb_cqi,dl_bler_x1e3,ta_apply,ta_cmd,rlc_total_bytes,rlc_total_pdus' \
> "$PRB_FEAT"

# ---------------- netns server mgmt (exact DoS pattern) --
precreate_user() { as_user "install -D -m 0664 /dev/null '$1'"; }

# kill only iperf3 servers within each netns (root-only)
kill_ns_iperf_servers() {
  local ns="$1" p
  for p in $(ip netns pids "$ns" 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE '(^| )iperf3( |$)'; then
      if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q ' -s '; then
        kill -9 "$p" 2>/dev/null || true
      fi
    fi
  done
}

kill_ns_iperf_servers ue1
kill_ns_iperf_servers ue2
kill_ns_iperf_servers ue3

precreate_user "${RUN_DIR}/ue1_server.log"
ip netns exec ue1 ${IPERF_BIN} -s -B "${UE1_IP}" -p "${PORT}" -i 1 \
  > "${RUN_DIR}/ue1_server.log" 2>&1 & echo $! > "${RUN_DIR}/ue1.pid"
precreate_user "${RUN_DIR}/ue2_server.log"
ip netns exec ue2 ${IPERF_BIN} -s -B "${UE2_IP}" -p "${PORT}" -i 1 \
  > "${RUN_DIR}/ue2_server.log" 2>&1 & echo $! > "${RUN_DIR}/ue2.pid"
precreate_user "${RUN_DIR}/ue3_server.log"
ip netns exec ue3 ${IPERF_BIN} -s -B "${UE3_IP}" -p "${PORT}" -i 1 \
  > "${RUN_DIR}/ue3_server.log" 2>&1 & echo $! > "${RUN_DIR}/ue3.pid"
sleep 1

cleanup() {
  [[ -f "$RUN_DIR/ue1.pid" ]] && kill "$(cat "$RUN_DIR/ue1.pid")" 2>/dev/null || true
  [[ -f "$RUN_DIR/ue2.pid" ]] && kill "$(cat "$RUN_DIR/ue2.pid")" 2>/dev/null || true
  [[ -f "$RUN_DIR/ue3.pid" ]] && kill "$(cat "$RUN_DIR/ue3.pid")" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------- Preflight probes (1s @ 1M) --------------
for n in 1 2 3; do
  UE_IP_VAR="UE${n}_IP"; UE_IP="${!UE_IP_VAR}"
  precreate_user "${RUN_DIR}/preflight_ue${n}.json"
  precreate_user "${RUN_DIR}/preflight_ue${n}.err"
  # EXACT client structure; run as invoking user so files are user-owned.
  as_user "docker exec '${DN_CONTAINER}' bash -lc '${IPERF_BIN} -c ${UE_IP} -p ${PORT} -t 1 -u -b 1M -J' \
           > '$RUN_DIR/preflight_ue${n}.json' 2> '$RUN_DIR/preflight_ue${n}.err'" || {
    echo "ERROR: Preflight to UE${n} (${UE_IP}:${PORT}) failed from ${DN_CONTAINER}"
    exit 1
  }
done
# Client structure mirrors DoS; server structure mirrors DoS.

# --------------- Random utilities -------------------------
u01() {
  if [[ -n "$SEED" ]]; then
    local val; val=$(awk -v seed="$SEED" 'BEGIN{srand(seed + systime()); printf "%.9f\n", rand()}'); echo "$val"
  else
    awk 'BEGIN{srand(); printf "%.9f\n", rand()}'
  fi
}
pick_active_count() {
  local x; x=$(u01)
  awk -v x="$x" -v p0="$P0" -v p1="$P1" -v p2="$P2" -v p3="$P3" \
      'BEGIN{ if (x < p0) print 0; else if (x < p0+p1) print 1; else if (x < p0+p1+p2) print 2; else print 3; }'
}
pick_rate() { shuf -i "${MIN_Mbps}-${MAX_Mbps}" -n 1; }
choose_k_ues() {
  local k="$1"
  if (( k == 0 )); then echo ""; return; fi
  printf "UE1\nUE2\nUE3\n" | shuf -n "$k" | xargs
}
ue_ip() { case "$1" in UE1) echo "$UE1_IP";; UE2) echo "$UE2_IP";; UE3) echo "$UE3_IP";; esac; }

TOTAL_SLICES=$(( (DURATION_SEC + SLICE_SEC - 1) / SLICE_SEC ))
printf "[%s] Benign eMBB generation for %ss in %s slices of %ss (rates %s-%s Mbps).\n" \
  "$(date +'%F %T')" "$DURATION_SEC" "$TOTAL_SLICES" "$SLICE_SEC" "$MIN_Mbps" "$MAX_Mbps"

as_user "echo 'slice_idx,start_epoch,active_count,UE,rate_Mbps' > '$RUN_DIR/meta/slice_plan.csv'"

# ---------------- eMBB slices (EXACT client call) --------
for (( s=0; s<TOTAL_SLICES; s++ )); do
  slice_start=$(date +%s)
  k=$(pick_active_count)
  read -r -a UE_LIST <<< "$(choose_k_ues "$k")"

  pids=()
  for ue in "${UE_LIST[@]:-}"; do
    rate=$(pick_rate)
    ip=$(ue_ip "$ue")
    as_user "echo '${s},${slice_start},${k},${ue},${rate}' >> '$RUN_DIR/meta/slice_plan.csv'"

    # EXACT iperf CLIENT STRUCTURE from DoS; ONLY -b and -t vary here:
    # docker exec "${DN_CONTAINER}" bash -lc "iperf3 -J -c ${UE_IP} -p ${PORT} -i 1 -t <secs> -u -b <rate>M -P 1"
    as_user "docker exec '${DN_CONTAINER}' bash -lc '${IPERF_BIN} -J -c ${ip} -p ${PORT} -i 1 -t ${SLICE_SEC} -u -b ${rate}M -P 1' \
             > '$RUN_DIR/logs/${ue}_slice${s}.json' 2> '$RUN_DIR/logs/${ue}_slice${s}.err'" &
    pids+=($!)
  done

  if (( ${#pids[@]} > 0 )); then
    wait "${pids[@]}" || true
  else
    sleep "${SLICE_SEC}"
    as_user "echo '${s},${slice_start},0,NA,0' >> '$RUN_DIR/meta/slice_plan.csv'"
  fi
done

printf "[%s] Traffic generation completed.\n" "$(date +'%F %T')"

# ---------------- Collect scheduler logs ------------------
if [[ -f "$PRB_LOG" ]]; then
  install -D -m 0644 "$PRB_LOG" "${RUN_DIR}/prb_log.txt"
  chown "$RUN_USER":"$RUN_USER" "${RUN_DIR}/prb_log.txt"
else
  echo "[WARN] $PRB_LOG not found; did you enable scheduler logging?"
fi

if [[ -f "$PRB_FEAT"  ]]; then
  install -D -m 0644 "$PRB_FEAT" "${RUN_DIR}/prb_features_ai.csv"
  chown "$RUN_USER":"$RUN_USER" "${RUN_DIR}/prb_features_ai.csv"
else
  echo "[WARN] $PRB_FEAT not found; did you enable features CSV logging?"
fi

# -------------- Build the per-slot feature set ------------
if [[ -f "$BUILDER" && -f "${RUN_DIR}/prb_log.txt" && -f "${RUN_DIR}/prb_features_ai.csv" ]]; then
  # Copy builder as user, then run builder as user to use user's Python env (NumPy, etc.)
  as_user "install -D -m 0644 '$BUILDER' '$RUN_DIR/$(basename "$BUILDER")'"
  as_user "cd '$RUN_DIR' && python3 '$(basename "$BUILDER")' \
            --features prb_features_ai.csv \
            --log prb_log.txt \
            --out prb_tti_evidence_ai.csv \
            --capacity '${CAPACITY_PRB}' \
            --tti-ms '${TTI_SEC}'"
  echo "[INFO] Feature table written: ${RUN_DIR}/prb_tti_evidence_ai.csv"
else
  echo "[WARN] Missing builder or inputs; skipping feature build."
fi

# Final safeguard: ensure everything in the run dir is owned by the invoking user
chown -R "$RUN_USER":"$RUN_USER" "$RUN_DIR"

printf "[%s] Done. Run directory: %s\n" "$(date +'%F %T')" "$RUN_DIR"


printf "[%s] Done. Run directory: %s\n" "$(date +'%F %T')" "$RUN_DIR"

